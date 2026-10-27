#!/usr/bin/env python3
"""Build Horizon's iOS game, then optionally sign and install on a selected device."""
import argparse
import datetime
import getpass
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import shlex
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = 'dev.horizon.game'


def run(*args, capture=False, env=None):
    # Never echo command arguments: security receives passwords as arguments.
    result = subprocess.run([str(a) for a in args], check=True, env=env,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    return result.stdout if capture else None


def archive(app, destination):
    """Stage an IPA and atomically replace the output only when zip succeeds."""
    with tempfile.TemporaryDirectory(prefix='ipa-', dir=destination.parent) as tmp:
        stage = Path(tmp)
        payload = stage / 'Payload'
        payload.mkdir()
        shutil.copytree(app, payload / app.name, symlinks=True)
        zipped = stage / 'output.ipa'
        subprocess.run(['/usr/bin/zip', '-qry', str(zipped), 'Payload'],
                       cwd=stage, check=True)
        os.replace(zipped, destination)
    print(f'Saved {destination}', flush=True)


def build(output):
    for tool in ('cargo', 'xcodegen', 'xcodebuild', 'xcrun'):
        if not shutil.which(tool):
            raise RuntimeError(f'Missing {tool}; install Rust, Xcode and XcodeGen first.')
    env = os.environ.copy()
    env.update(IPHONEOS_DEPLOYMENT_TARGET='16.0',
               CARGO_PROFILE_RELEASE_CODEGEN_UNITS='16', CARGO_PROFILE_RELEASE_LTO='false',
               CARGO_TARGET_DIR=str(ROOT / 'target'))
    print('Building the Rust game for iOS…', flush=True)
    run('cargo', 'build', '--manifest-path', ROOT / 'Cargo.toml', '--release', '--locked',
        '--target', 'aarch64-apple-ios', '-p', 'horizon-client', '--bin', 'horizon-client',
        '--no-default-features', '--features', 'audio', env=env)
    run('xcodegen', 'generate', '--spec', ROOT / 'packaging/ios/project.yml')
    env['HORIZON_GAME_PREBUILT'] = '1'
    print('Building the app and Swift launcher…', flush=True)
    run('xcodebuild', '-project', ROOT / 'packaging/ios/HorizonIOS.xcodeproj',
        '-scheme', 'Horizon game', '-configuration', 'Release', '-sdk', 'iphoneos',
        '-destination', 'generic/platform=iOS', '-derivedDataPath', output / 'DerivedData',
        'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=',
        f'CONFIGURATION_BUILD_DIR={output / "products"}', 'build', env=env)
    app = output / 'products/HorizonGame.app'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != BUNDLE_ID:
        raise RuntimeError('Built app has an unexpected bundle ID.')
    if not (app / 'Frameworks/HorizonLauncherKit.framework/HorizonLauncherKit').is_file():
        raise RuntimeError('The app is missing its Swift launcher.')
    archive(app, output / 'Horizon-game-unsigned.ipa')
    return app


def device_rows(data):
    rows = []
    for device in data['result']['devices']:
        props = device.get('properties', {})
        hardware = props.get('hardware', device.get('hardwareProperties', {}))
        state = props.get('state', device.get('deviceProperties', {}))
        connection = props.get('connection', device.get('connectionProperties', {}))
        if hardware.get('reality') != 'physical' or hardware.get('platform') != 'iOS':
            continue
        status = connection.get('state', connection.get('tunnelState', 'unknown'))
        rows.append({'id': device['identifier'], 'udid': hardware.get('udid', ''),
                     'name': state.get('name', 'iOS device'), 'status': status})
    return rows


def select_device(requested=None):
    with tempfile.TemporaryDirectory(prefix='horizon-devices-') as tmp:
        path = Path(tmp) / 'devices.json'
        run('xcrun', 'devicectl', 'list', 'devices', '--timeout', '30', '--json-output', path)
        rows = device_rows(json.loads(path.read_text()))
    if not rows:
        raise RuntimeError('No paired iOS devices found. Connect, unlock and trust a device in Xcode.')
    print('\nPhysical iOS devices (including paired devices currently disconnected):')
    for i, row in enumerate(rows, 1):
        print(f"  {i}. {row['name']} — connection: {row['status']} — {row['udid']}")
    if requested:
        matches = [r for r in rows if requested in (r['id'], r['udid'], r['name'])]
        if len(matches) != 1:
            raise RuntimeError('--device must match exactly one listed device.')
        return matches[0]
    while True:
        choice = input('Select device number (Enter to cancel): ').strip()
        if not choice:
            return None
        if choice.isdigit() and 1 <= int(choice) <= len(rows):
            return rows[int(choice) - 1]
        print('Choose one of the listed numbers.')


def one_file(folder, pattern):
    files = sorted(folder.glob(pattern))
    if len(files) != 1:
        raise RuntimeError(f'Expected one {pattern} in {folder}; found {len(files)}.')
    return files[0]


def read_profile(path):
    # OpenSSL also decodes profiles on hosts where security cms fails to decode them.
    return plistlib.loads(run('openssl', 'smime', '-verify', '-noverify', '-inform', 'der',
                             '-in', path, capture=True))


def entitlements(profile, bundle_id):
    supplied = profile['Entitlements']
    app_id = supplied['application-identifier']
    prefix, pattern = app_id.split('.', 1)
    if '*' in pattern:
        candidate = f'{prefix}.{bundle_id}'
        if not app_id.endswith('*') or not candidate.startswith(app_id[:-1]):
            raise RuntimeError('Bundle ID outside the selected wildcard profile.')
        app_id = candidate
    elif pattern != bundle_id:
        print('Using shared explicit profile: preserving its application-identifier '
              f'and the installation bundle ID {bundle_id}.', flush=True)
    result = {'application-identifier': app_id,
              'com.apple.developer.team-identifier': supplied['com.apple.developer.team-identifier'],
              'get-task-allow': bool(supplied.get('get-task-allow', False))}
    if any(group == app_id or (group.endswith('*') and app_id.startswith(group[:-1]))
           for group in supplied.get('keychain-access-groups', [])):
        result['keychain-access-groups'] = [app_id]
    return result


def sign_install(app, output, cert_dir, device):
    profile_path = one_file(cert_dir, '*.mobileprovision')
    p12 = one_file(cert_dir, '*.p12')
    profile = read_profile(profile_path)
    if profile['ExpirationDate'] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
        raise RuntimeError('The provisioning profile has expired.')
    registered = [udid.lower() for udid in profile.get('ProvisionedDevices', [])]
    if not profile.get('ProvisionsAllDevices') and device['udid'].lower() not in registered:
        print('No automatic UDID match; using the selected cert pair and testing device acceptance.', flush=True)
    signed_entitlements = entitlements(profile, BUNDLE_ID)
    password = os.environ.get('HORIZON_IOS_P12_PASSWORD')
    if password is None:
        note = p12.with_suffix('.rtf')
        if note.exists():
            password = run('textutil', '-convert', 'txt', '-stdout', note, capture=True).decode().strip()
        else:
            password = getpass.getpass('Certificate password (empty if none): ')
    with tempfile.TemporaryDirectory(prefix='horizon-sign-') as tmp:
        stage = Path(tmp)
        keychain = stage / 'signing.keychain-db'
        key_password = secrets.token_urlsafe(32)
        original_search = shlex.split(run('security', 'list-keychains', '-d', 'user', capture=True).decode())
        try:
            run('security', 'create-keychain', '-p', key_password, keychain, capture=True)
            run('security', 'list-keychains', '-d', 'user', '-s', *original_search, capture=True)
            run('security', 'set-keychain-settings', '-lut', '600', keychain, capture=True)
            run('security', 'unlock-keychain', '-p', key_password, keychain, capture=True)
            run('security', 'import', p12, '-k', keychain, '-P', password,
                '-T', '/usr/bin/codesign', capture=True)
            run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
                '-s', '-k', key_password, keychain, capture=True)
            identities = run('security', 'find-identity', '-v', '-p', 'codesigning',
                             keychain, capture=True).decode()
            fingerprints = [hashlib.sha1(c).hexdigest().upper() for c in profile['DeveloperCertificates']]
            identity = next((f for f in fingerprints if f in identities), None)
            if not identity:
                raise RuntimeError('The certificate does not match the profile or is not a valid signing identity.')
            signed = stage / app.name
            shutil.copytree(app, signed, symlinks=True)
            shutil.copyfile(profile_path, signed / 'embedded.mobileprovision')
            entitlement_path = stage / 'entitlements.plist'
            entitlement_path.write_bytes(plistlib.dumps(signed_entitlements))
            nested = list(signed.rglob('*.framework')) + list(signed.rglob('*.dylib'))
            for binary in sorted(nested, key=lambda p: len(p.parts), reverse=True):
                run('codesign', '--force', '--sign', identity, '--keychain', keychain,
                    '--timestamp=none', '--generate-entitlement-der', binary)
            run('codesign', '--force', '--sign', identity, '--keychain', keychain,
                '--timestamp=none', '--generate-entitlement-der', '--identifier', BUNDLE_ID,
                '--entitlements', entitlement_path, signed)
            run('codesign', '--verify', '--deep', '--strict', signed)
            actual = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', signed, capture=True))
            if actual != signed_entitlements:
                raise RuntimeError('Signed entitlements differ from requested entitlements.')
            archive(signed, output / 'Horizon-game-signed.ipa')
            run('xcrun', 'devicectl', 'device', 'install', 'app', '--device', device['id'],
                signed, '--timeout', '120')
            print(f"Installed Horizon on {device['name']}.")
        finally:
            try:
                if keychain.exists():
                    run('security', 'delete-keychain', keychain, capture=True)
            finally:
                run('security', 'list-keychains', '-d', 'user', '-s', *original_search, capture=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--unsigned-only', action='store_true', help='Build and save without prompting')
    parser.add_argument('--install', action='store_true', help='Proceed to device selection without prompting')
    parser.add_argument('--device', help='Device UDID, CoreDevice ID or exact name (requires --install)')
    parser.add_argument('--skip-build', action='store_true', help='Use the existing app in output/products')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/ios')
    parser.add_argument('--cert-dir', type=Path, default=ROOT / 'cert')
    args = parser.parse_args()
    if args.unsigned_only and args.install:
        parser.error('--unsigned-only and --install are mutually exclusive')
    if args.device and not args.install:
        parser.error('--device requires --install')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    app = output / 'products/HorizonGame.app' if args.skip_build else build(output)
    if args.skip_build:
        if not app.is_dir():
            raise RuntimeError(f'No existing app at {app}; run without --skip-build.')
        if plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier'] != BUNDLE_ID:
            raise RuntimeError('Existing app has an unexpected bundle ID.')
        archive(app, output / 'Horizon-game-unsigned.ipa')
    if args.unsigned_only:
        return
    if not args.install:
        if not sys.stdin.isatty():
            print('No interactive terminal; unsigned IPA saved. Use --install to install.')
            return
        if input('Sign and install on an iOS device? [y/N] ').strip().lower() not in ('y', 'yes'):
            return
    device = select_device(args.device)
    if device:
        sign_install(app, output, args.cert_dir.resolve(), device)


def interrupted(signum, frame):
    raise KeyboardInterrupt


if __name__ == '__main__':
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        print('\nCancelled; any saved IPA is retained.', file=sys.stderr)
        sys.exit(130)
    except subprocess.CalledProcessError as exc:
        # Avoid CalledProcessError's repr, which exposes password-bearing argv.
        print(f'Command {Path(exc.cmd[0]).name} failed (exit {exc.returncode}).', file=sys.stderr)
        sys.exit(1)
    except (RuntimeError, OSError, ValueError) as exc:
        print(f'Error: {exc}', file=sys.stderr)
        sys.exit(1)
