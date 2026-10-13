#!/usr/bin/env python3
"""Exercise the real bundled RAOP helper + Swift FIFO/audio integration over loopback.
No Apple account, phone or persisted receiver preference is needed.
"""
import argparse
import math
import os
import signal
from pathlib import Path
import re
import socket
import struct
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, default=ROOT / 'build/airplay-helper/arm64/shairport-sync')
    parser.add_argument('--codec', choices=['PCM', 'ALAC'], default='PCM')
    args = parser.parse_args()
    process = subprocess.Popen([ROOT / 'build/airplay-probe', args.helper, args.codec], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    output = []
    def collect():
        for line in process.stdout:
            output.append(line)
            print(line, end='', flush=True)
    thread = threading.Thread(target=collect, daemon=True); thread.start()
    stop = threading.Event()
    timing = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); timing.bind(('127.0.0.1', 0)); timing.settimeout(.2)
    control = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); control.bind(('127.0.0.1', 0))
    audio = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    def ntp():
        now = time.monotonic()
        return struct.pack('!II', int(now), int((now % 1) * 2**32))
    def timing_server():
        while not stop.is_set():
            try:
                request, sender = timing.recvfrom(128)
                if len(request) >= 32 and request[1] == 0xd2:
                    timing.sendto(bytes([0x80, 0xd3, 0, 7]) + bytes(4) + request[24:32] + ntp() + ntp(), sender)
            except socket.timeout: pass
    threading.Thread(target=timing_server, daemon=True).start()
    client = None
    try:
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if process.poll() is not None: raise RuntimeError(process.stderr.read())
            if any('RECEIVER_READY' in line for line in output):
                try: client = socket.create_connection(('127.0.0.1', 5099), timeout=1); break
                except OSError: pass
            time.sleep(.05)
        if client is None: raise RuntimeError('Receiver did not open its RTSP port')
        client.settimeout(5)
        sequence = 0
        def rtsp(method, headers=None, body=b''):
            nonlocal sequence
            sequence += 1
            fields = {'CSeq': str(sequence), 'User-Agent':'HelixReceiverProbe/1.0', 'Content-Length':str(len(body)), **(headers or {})}
            request = f'{method} rtsp://127.0.0.1/test RTSP/1.0\r\n' + ''.join(f'{key}: {value}\r\n' for key, value in fields.items()) + '\r\n'
            client.sendall(request.encode() + body)
            response = b''
            while b'\r\n\r\n' not in response: response += client.recv(4096)
            header, payload = response.split(b'\r\n\r\n', 1)
            text = header.decode()
            length = re.search(r'Content-Length: (\d+)', text, re.I)
            while length and len(payload) < int(length[1]): payload += client.recv(4096)
            if not text.startswith('RTSP/1.0 200'): raise RuntimeError(text)
            return text
        rtsp('OPTIONS')
        sdp = b'v=0\r\no=iTunes 1 0 IN IP4 127.0.0.1\r\ns=Probe\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 0 RTP/AVP 96\r\na=rtpmap:96 L16/44100/2\r\n'
        if args.codec == 'ALAC':
            sdp = sdp.replace(b'L16/44100/2', b'AppleLossless') + b'a=fmtp:96 352 0 16 40 10 14 2 255 0 0 44100\r\n'
        rtsp('ANNOUNCE', {'Content-Type':'application/sdp', 'X-Apple-Client-Name':'Helix test source'}, sdp)
        response = rtsp('SETUP', {'Transport':f'RTP/AVP/UDP;unicast;mode=record;control_port={control.getsockname()[1]};timing_port={timing.getsockname()[1]}'})
        audio_port = int(re.search(r'server_port=(\d+)', response)[1])
        control_port = int(re.search(r'control_port=(\d+)', response)[1])
        timestamp = 1000000
        rtsp('RECORD', {'Range':'npt=0-', 'RTP-Info':f'seq=1;rtptime={timestamp}'})
        def dmap(code, value):
            data = value.encode(); return code.encode() + struct.pack('!I', len(data)) + data
        metadata = dmap('minm', 'Receiver integration') + dmap('asar', 'Loopback sender') + dmap('asal', 'Test album')
        rtsp('SET_PARAMETER', {'Content-Type':'application/x-dmap-tagged', 'RTP-Info':f'rtptime={timestamp}'}, b'mlcl' + struct.pack('!I',len(metadata)) + metadata)
        rtsp('SET_PARAMETER', {'Content-Type':'text/parameters'}, f'volume: -30.0\r\nprogress: {timestamp}/{timestamp}/{timestamp+441000}\r\n'.encode())
        start = time.monotonic()
        for sequence in range(1, 1100):
            if process.poll() is not None: break
            frame = (timestamp + (sequence-1)*352) & 0xffffffff
            if sequence % 20 == 1:
                # RTP frame at sender time and the corresponding frame after 2s latency.
                control.sendto(struct.pack('!BBHI', 0x80, 0xd4, 7, (frame-88200)&0xffffffff) + ntp() + struct.pack('!I',frame), ('127.0.0.1',control_port))
            pcm = b''.join(struct.pack('!hh', int(1000*math.sin((sequence*352+i)*2*math.pi*440/44100)), int(1000*math.sin((sequence*352+i)*2*math.pi*440/44100))) for i in range(352))
            if args.codec == 'ALAC':
                # An ALAC uncompressed CPE frame still uses the ALAC transport
                # and decoder, with exactly 352 stereo S16 samples.
                bits = '001' + '0000' + '0'*12 + '1' + '00' + '1' + f'{352:032b}'
                bits += ''.join(f'{byte:08b}' for byte in pcm) + '111'
                bits += '0' * (-len(bits) % 8)
                pcm = int(bits, 2).to_bytes(len(bits)//8, 'big')
            audio.sendto(struct.pack('!BBHII',0x80,0x60,sequence,frame,1) + pcm, ('127.0.0.1',audio_port))
            time.sleep(max(0,start+sequence*352/44100-time.monotonic()))
        process.wait(timeout=25)
        thread.join(timeout=1)
        if process.returncode != 0: raise RuntimeError(process.stderr.read())
        assert any('LIVE_AUDIO_OUTPUT' in line for line in output), 'No native audio output'
        assert any(f'LIVE_FORMAT: {args.codec}' in line for line in output), 'Actual input codec is not displayed accurately'
        print(f'PASS: RTSP negotiation, {args.codec} codec accuracy, title metadata, FIFO delivery, AVAudioEngine output')
    finally:
        stop.set()
        # A failed assertion in the native probe must not leave a test child.
        try: os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        if client: client.close()
        timing.close(); control.close(); audio.close()
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()

if __name__ == '__main__':
    main()
