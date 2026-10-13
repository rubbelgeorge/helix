#!/usr/bin/env python3
"""Build Helix. The app contains only its own code, the remote web UI and
the AirPlay helper; it ships no Apple code and no wrapper. Playback needs a
wrapper-v2 instance that the user runs themselves."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--airplay', type=Path, default=ROOT / 'build/airplay-helper', help='Output of tools/build-airplay.py')
    parser.add_argument('--arch', choices=('universal', 'arm64', 'x86_64'), default='universal')
    parser.add_argument('--output', type=Path, help='Output .app path')
    parser.add_argument('--zip', action='store_true', help='Create a transferable ZIP beside the app')
    args = parser.parse_args()
    architectures = ['arm64', 'x86_64'] if args.arch == 'universal' else [args.arch]
    helpers = args.airplay.resolve()
    for architecture in architectures:
        if not (helpers / architecture / 'shairport-sync').is_file():
            sys.exit(f'Missing AirPlay helper for {architecture}. Run: python3 tools/build-airplay.py')
    remote = ROOT / 'Remote/dist'
    if not (remote / 'index.html').is_file():
        sys.exit('Missing remote frontend. Run npm ci && npm run build in Remote/.')

    app_destination = (args.output or ROOT / 'build/Helix.app').resolve()
    if app_destination.suffix != '.app' or app_destination.parent == Path('/'):
        sys.exit('The output must be an .app path inside an output directory.')
    app = ROOT / 'build/package-staging' / args.arch / 'Helix.app'
    if app.exists(): shutil.rmtree(app)
    executable = app / 'Contents/MacOS/Helix'
    resources = app / 'Contents/Resources'
    executable.parent.mkdir(parents=True)
    resources.mkdir(parents=True)

    sources = sorted((ROOT / 'client').glob('*.swift'))
    slices = []
    for architecture in architectures:
        binary = ROOT / 'build' / f'client-{architecture}'
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-target', f'{architecture}-apple-macos15.0',
                        '-module-cache-path', str(ROOT / 'build/module-cache'), '-parse-as-library',
                        *map(str, sources), '-o', str(binary)], check=True)
        slices.append(binary)
    if len(slices) == 2:
        subprocess.run(['xcrun', 'lipo', '-create', *map(str, slices), '-output', str(executable)], check=True)
    else:
        shutil.copy2(slices[0], executable)

    for architecture in architectures:
        source = helpers / architecture
        helper_arch = subprocess.check_output(['xcrun', 'lipo', '-archs', str(source / 'shairport-sync')], text=True).strip()
        if helper_arch != architecture: sys.exit(f'Wrong AirPlay helper architecture: {helper_arch}')
        subprocess.run(['codesign', '--verify', '--strict', str(source / 'shairport-sync')], check=True)
        shutil.copytree(source, resources / 'AirPlay' / architecture)
    shutil.copy2(ROOT / 'Runtime/AppIcon.icns', resources / 'AppIcon.icns')
    shutil.copytree(remote, resources / 'Remote')
    if (ROOT / 'LICENSE').is_file(): shutil.copy2(ROOT / 'LICENSE', resources / 'LICENSE')

    info = {
        'CFBundleExecutable': 'Helix', 'CFBundleIdentifier': 'dev.helixplayer.helix',
        'CFBundleName': 'Helix', 'CFBundleDisplayName': 'Helix', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '0.6.0', 'CFBundleVersion': '6', 'LSMinimumSystemVersion': '15.0',
        'CFBundleIconFile': 'AppIcon', 'NSHumanReadableCopyright': 'Helix',
        'LSRequiresNativeExecution': True,
        'LSApplicationCategoryType': 'public.app-category.music', 'NSHighResolutionCapable': True,
        'NSLocalNetworkUsageDescription': 'Verbindet sich mit deinem wrapper-v2, empfängt AirPlay-Audio und erlaubt die Steuerung über die HTTP-Fernbedienung im gleichen Netzwerk.',
        'NSBonjourServices': ['_raop._tcp'],
        'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
    }
    with (app / 'Contents/Info.plist').open('wb') as handle:
        plistlib.dump(info, handle)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)

    app_destination.parent.mkdir(parents=True, exist_ok=True)
    if app_destination.exists(): shutil.rmtree(app_destination)
    shutil.move(str(app), app_destination)
    print(f'Built: {app_destination}')
    if args.zip:
        archive = app_destination.with_suffix('.zip')
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app_destination), str(archive)], check=True)
        print(f'ZIP: {archive}')


if __name__ == '__main__':
    main()
