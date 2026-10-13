#!/usr/bin/env python3
"""Build a self-contained native Shairport Sync helper (no Homebrew at runtime)."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'build/airplay'
SOURCES = WORK / 'shairport-sync'
UPSTREAM = 'https://github.com/mikebrady/shairport-sync.git'
REVISION = '01078ad15d4da06dffba0c5f15ffeaf9146a2a2a'
ARCHIVES = {
    "m4-1.4.20.tar.gz": ("https://ftp.gnu.org/gnu/m4/m4-1.4.20.tar.gz", "6ac4fc31ce440debe63987c2ebbf9d7b6634e67a7c3279257dc7361de8bdb3ef"),
    'openssl-3.5.9.tar.gz': ('https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz', '603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a'),
    'ffmpeg-8.0.3.tar.xz': ('https://ffmpeg.org/releases/ffmpeg-8.0.3.tar.xz', '6136812ea6d4e68bdba27e33c2a94382711cdf4f8602ffef056ff792bd6f9818'),
    'autoconf-2.72.tar.gz': ('https://ftp.gnu.org/gnu/autoconf/autoconf-2.72.tar.gz', 'afb181a76e1ee72832f6581c0eddf8df032b83e2e0239ef79ebedc4467d92d6e'),
    'automake-1.17.tar.gz': ('https://ftp.gnu.org/gnu/automake/automake-1.17.tar.gz', '397767d4db3018dd4440825b60c64258b636eaf6bf99ac8b0897f06c89310acd'),
    'libconfig-1.7.3.tar.gz': ('https://github.com/hyperrealm/libconfig/releases/download/v1.7.3/libconfig-1.7.3.tar.gz', '545166d6cac037744381d1e9cc5a5405094e7bfad16a411699bcff40bbb31ee7'),
    'popt-1.19.tar.gz': ('https://ftp.osuosl.org/pub/rpm/popt/releases/popt-1.x/popt-1.19.tar.gz', 'c25a4838fc8e4c1c8aacb8bd620edb3084a3d63bf8987fdad3ca2758c63240f9'),
}


def run(args, cwd, env=None):
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)


def unpack(name, destination):
    archive = WORK / 'downloads' / name
    if not archive.exists():
        archive.parent.mkdir(parents=True, exist_ok=True)
        run(['curl', '-fL', '--retry', '2', ARCHIVES[name][0], '-o', archive], ROOT)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVES[name][1]:
        raise SystemExit(f'Checksum mismatch: {archive}')
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as handle:
        handle.extractall(destination, filter='data')
        return destination / handle.getnames()[0].split('/')[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=['arm64', 'x86_64', 'universal'], default='universal')
    args = parser.parse_args()
    if not SOURCES.exists():
        WORK.mkdir(parents=True, exist_ok=True)
        run(['git', 'clone', '--quiet', UPSTREAM, SOURCES], ROOT)
        run(['git', 'checkout', '--quiet', REVISION], SOURCES)
    if subprocess.check_output(['git', '-C', str(SOURCES), 'rev-parse', 'HEAD'], text=True).strip() != REVISION:
        raise SystemExit('The Shairport Sync checkout differs from the audited revision.')
    WORK.mkdir(parents=True, exist_ok=True)
    tools = WORK / 'tools'
    env = dict(os.environ, ACLOCAL_PATH='/opt/homebrew/share/aclocal:/usr/local/share/aclocal', PATH=f'{tools}/bin:' + os.environ['PATH'])
    for name, executable in [('m4-1.4.20.tar.gz', 'm4'), ('autoconf-2.72.tar.gz', 'autoconf'), ('automake-1.17.tar.gz', 'automake')]:
        if not (tools / 'bin' / executable).exists():
            source = unpack(name, WORK / 'tools-src')
            run(['./configure', f'--prefix={tools}'], source, env)
            run(['make', '-j8'], source, env)
            run(['make', 'install'], source, env)
    helper_source = WORK / 'shairport-src'
    if not helper_source.exists():
        helper_source.mkdir()
        archive = subprocess.check_output(['git', '-C', str(SOURCES), 'archive', '--format=tar', REVISION])
        import io
        with tarfile.open(fileobj=io.BytesIO(archive)) as handle:
            handle.extractall(helper_source, filter='data')
        # Upstream's classic metadata hardcodes ALAC, even for incoming PCM.
        # Report the negotiated input parameters, independently of stdout PCM.
        path = helper_source / 'player.c'
        code = path.read_text()
        old = 'send_ssnc_stream_description("AirPlay", "ALAC/44100/S16/2");'
        replacement = '''char input_description[128];
              snprintf(input_description, sizeof(input_description), "%s/%u/S%u/%u",
                       conn->stream.type == ast_apple_lossless ? "ALAC" : "PCM",
                       conn->input_rate, conn->input_bit_depth, conn->input_num_channels);
              send_ssnc_stream_description("AirPlay", input_description);'''
        if code.count(old) != 1:
            raise SystemExit('Shairport metadata patch no longer matches.')
        path.write_text(code.replace(old, replacement))
        # Announce a valid audio session before RECORD/audio starts, so takeover
        # also cancels an Apple Music title still being prepared.
        path = helper_source / 'rtsp.c'
        code = path.read_text()
        old = 'if ((resp->respcode == 200) && (conn->stream.type != ast_unknown)) {'
        if code.count(old) != 1:
            raise SystemExit('Shairport session patch no longer matches.')
        path.write_text(code.replace(old, old + '''
#ifdef CONFIG_METADATA
      send_ssnc_metadata('conn', NULL, 0, 1);
#endif'''))
        run(['autoreconf', '-fi'], helper_source, env)
    # Upstream 5.5.1 overwrites BOTH configuration and CLI ports after parsing.
    # Preserve explicit ports so macOS's built-in receiver on 5000 can coexist.
    path = helper_source / 'shairport.c'
    code = path.read_text()
    if 'if (config.port == 0) config.port = 5000;' not in code:
        if code.count('config.port = 5000;') != 2 or code.count('config.port = 7000;') != 1:
            raise SystemExit('Shairport port patch no longer matches.')
        code = code.replace('config.port = 5000;', 'if (config.port == 0) config.port = 5000;')
        code = code.replace('config.port = 7000;', 'if (config.port == 0) config.port = 7000;')
        path.write_text(code)
    # Classic PCM shares the S16 stereo resampler layout with ALAC, but needs
    # its own decoder and truthful input metadata. Upstream's FFmpeg path
    # otherwise always selects ALAC for classic packets, including PCM.
    path = helper_source / 'player.c'
    code = path.read_text()
    old = "send_ssnc_metadata('sdsc', get_ssrc_name(ssrc), strlen(get_ssrc_name(ssrc)), 1);"
    if old in code:
        code = code.replace(old, """char description[128];
    snprintf(description, sizeof(description), "%s/%u/S%u/%u",
             conn->stream.type == ast_uncompressed ? "PCM" : "ALAC",
             conn->input_rate, conn->input_bit_depth, conn->input_num_channels);
    send_ssnc_metadata('sdsc', description, strlen(description), 1);""")
        code = code.replace('avcodec_find_decoder(AV_CODEC_ID_ALAC);',
                            'avcodec_find_decoder(conn->stream.type == ast_uncompressed ? AV_CODEC_ID_PCM_S16BE : AV_CODEC_ID_ALAC);')
        code = code.replace('if ((ssrc == ALAC_48000_S24_2) || (ssrc == ALAC_44100_S16_2)) {',
                            'if (conn->stream.type != ast_uncompressed && ((ssrc == ALAC_48000_S24_2) || (ssrc == ALAC_44100_S16_2))) {')
        code = code.replace('if (avcodec_open2(conn->codec_context, conn->codec, NULL) < 0) {', """if (conn->stream.type == ast_uncompressed) {
          conn->codec_context->sample_rate = 44100;
          conn->codec_context->bits_per_coded_sample = 16;
          av_channel_layout_default(&conn->codec_context->ch_layout, 2);
        }
        if (avcodec_open2(conn->codec_context, conn->codec, NULL) < 0) {""")
        path.write_text(code)
    # A receiver must not survive a crashed/killed GUI and keep its port held.
    path = helper_source / 'shairport.c'
    code = path.read_text()
    if 'am_parent_watchdog' not in code:
        signature = 'int main(int argc, char **argv) {'
        if code.count(signature) != 1:
            raise SystemExit('Shairport parent-lifetime patch no longer matches.')
        watchdog = """static pid_t am_parent_pid;
static void *am_parent_watchdog(void *unused) {
  (void)unused;
  sigset_t term;
  sigemptyset(&term); sigaddset(&term, SIGTERM);
  pthread_sigmask(SIG_BLOCK, &term, NULL);
  while (getppid() == am_parent_pid && am_parent_pid > 1) sleep(1);
  kill(getpid(), SIGTERM);
  sleep(2);
  kill(getpid(), SIGKILL);
  return NULL;
}

"""
        code = code.replace(signature, watchdog + signature + """
  am_parent_pid = getppid();
  pthread_t am_watchdog;
  if (pthread_create(&am_watchdog, NULL, am_parent_watchdog, NULL) == 0)
    pthread_detach(am_watchdog);
""")
        path.write_text(code)
    path = helper_source / 'shairport.c'
    code = path.read_text().replace('  (void)unused;\n  while (getppid()', '  (void)unused;\n  sigset_t term;\n  sigemptyset(&term); sigaddset(&term, SIGTERM);\n  pthread_sigmask(SIG_BLOCK, &term, NULL);\n  while (getppid()').replace('  kill(getpid(), SIGTERM);\n  return NULL;', '  kill(getpid(), SIGTERM);\n  sleep(2);\n  kill(getpid(), SIGKILL);\n  return NULL;')
    path.write_text(code)
    architectures = ['arm64', 'x86_64'] if args.arch == 'universal' else [args.arch]
    for arch in architectures:
        prefix = WORK / arch / 'prefix'
        build = WORK / arch
        build.mkdir(exist_ok=True)
        flags = f'-O2 -arch {arch} -mmacosx-version-min=15.0'
        native_env = dict(env, CC='clang', CXX='clang++', CFLAGS=flags, CXXFLAGS=flags,
                          LDFLAGS=f'-arch {arch} -mmacosx-version-min=15.0',
                          PKG_CONFIG_PATH=str(prefix / 'lib/pkgconfig'))
        for name, library, options in [
            ('libconfig-1.7.3.tar.gz', 'libconfig.a', ['--disable-cxx', '--disable-examples']),
            ('popt-1.19.tar.gz', 'libpopt.a', ['--disable-nls']),
        ]:
            if not (prefix / 'lib' / library).exists():
                source = unpack(name, build / 'deps')
                run(['./configure', f'--prefix={prefix}', '--disable-shared', '--enable-static', *options], source, native_env)
                run(['make', '-j8'], source, native_env)
                run(['make', 'install'], source, native_env)
        if not (prefix / 'lib/libcrypto.a').exists():
            source = unpack('openssl-3.5.9.tar.gz', build / 'deps')
            run(['perl', 'Configure', 'darwin64-arm64-cc' if arch == 'arm64' else 'darwin64-x86_64-cc',
                 'no-shared', 'no-tests', f'--prefix={prefix}', '-mmacosx-version-min=15.0'], source, native_env)
            run(['make', '-j8', 'build_libs'], source, native_env)
            run(['make', 'install_dev'], source, native_env)
        if not (prefix / 'lib/libavcodec.a').exists():
            source = unpack('ffmpeg-8.0.3.tar.xz', build / 'deps')
            run(['./configure', f'--prefix={prefix}', '--cc=clang', f'--arch={arch}', '--target-os=darwin',
                 '--enable-cross-compile', '--disable-everything', '--disable-autodetect', '--disable-programs',
                 '--disable-doc', '--disable-shared', '--enable-static', '--disable-x86asm',
                 '--enable-decoder=alac,aac,pcm_s16be', '--enable-swresample',
                 f'--extra-cflags={flags}', f'--extra-ldflags={flags}'], source, native_env)
            run(['make', '-j8'], source, native_env)
            run(['make', 'install'], source, native_env)
        output = ROOT / f'build/airplay-helper/{arch}/shairport-sync'
        output.parent.mkdir(parents=True, exist_ok=True)
        helper_build = build / 'helper'
        helper_build.mkdir(exist_ok=True)
        # Static pkg-config flags also include transitive system dependencies.
        static_env = dict(native_env, PKG_CONFIG='pkg-config --static')
        run([helper_source / 'configure', '--with-os=darwin', '--with-stdout', '--with-dns_sd',
             '--with-metadata', '--with-ssl=openssl', '--with-ffmpeg', '--without-libdaemon',
             '--with-configfiles=no', f'--prefix={prefix}'], helper_build, static_env)
        run(['make', '-j8'], helper_build, static_env)
        shutil.copy2(helper_build / 'shairport-sync', output)
        run(['strip', '-x', output], ROOT)
        run(['codesign', '--force', '--sign', '-', output], ROOT)
        dependencies = subprocess.check_output(['otool', '-L', str(output)], text=True)
        if '/opt/' in dependencies or '/usr/local/' in dependencies or str(WORK) in dependencies:
            raise SystemExit(f'Non-system runtime dependency: {dependencies}')
        licenses = output.parent / 'Licenses'
        licenses.mkdir(exist_ok=True)
        for name, path in [('shairport-sync', helper_source / 'LICENSES'),
                           ('libconfig', build / 'deps/libconfig-1.7.3/COPYING.LIB'),
                           ('popt', build / 'deps/popt-1.19/COPYING'),
                           ('openssl', build / 'deps/openssl-3.5.9/LICENSE.txt'),
                           ('ffmpeg', build / 'deps/ffmpeg-8.0.3/COPYING.LGPLv2.1')]:
            if path.is_dir(): shutil.copytree(path, licenses / name, dirs_exist_ok=True)
            else: shutil.copy2(path, licenses / f'{name}.txt')
        (output.parent / 'BUILD.txt').write_text(f'Shairport Sync {REVISION}\nClassic AirPlay, FFmpeg ALAC decoder, stdout S16/44100/2.\nInput-format/session metadata, explicit-port fix classic PCM decoder fix and parent lifetime watchdog applied by tools/build-airplay.py.\n')
        print(f'Built AirPlay helper: {output}', flush=True)

if __name__ == '__main__':
    main()
