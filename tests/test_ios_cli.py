"""Portable checks for the iOS packaging helper."""
import datetime
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location('ios_cli', Path(__file__).resolve().parents[1] / 'tools/ios.py')
ios = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ios)


class IOSCliTests(unittest.TestCase):
    def test_only_physical_ios_devices_and_both_xcode_formats(self):
        hardware = {'platform': 'iOS', 'reality': 'physical', 'udid': 'phone'}
        data = {'result': {'devices': [
            {'identifier': 'old', 'hardwareProperties': hardware,
             'deviceProperties': {'name': 'Old'}, 'connectionProperties': {'tunnelState': 'connected'}},
            {'identifier': 'new', 'properties': {'hardware': hardware, 'state': {'name': 'New'},
                                               'connection': {'state': 'disconnected'}}},
            {'identifier': 'sim', 'hardwareProperties': dict(hardware, reality='simulated')},
        ]}}
        rows = ios.device_rows(data)
        self.assertEqual([r['id'] for r in rows], ['old', 'new'])
        self.assertEqual(rows[1]['status'], 'disconnected')

    def test_shared_profile_preserves_app_identifier_without_extra_capabilities(self):
        profile = {'TeamIdentifier': ['TEAM'], 'Entitlements': {
            'application-identifier': 'PREFIX.some.other.app', 'get-task-allow': True,
            'com.apple.developer.team-identifier': 'TEAM', 'keychain-access-groups': ['PREFIX.*'],
            'com.apple.developer.healthkit': True}}
        result = ios.entitlements(profile, ios.BUNDLE_ID)
        self.assertEqual(result['application-identifier'], 'PREFIX.some.other.app')
        self.assertEqual(result['com.apple.developer.team-identifier'], 'TEAM')
        self.assertEqual(result['keychain-access-groups'], ['PREFIX.some.other.app'])
        self.assertNotIn('com.apple.developer.healthkit', result)

    def test_wildcard_is_expanded_only_within_authorized_prefix(self):
        profile = {'Entitlements': {'application-identifier': 'TEAM.dev.horizon.*',
                                  'com.apple.developer.team-identifier': 'TEAM'}}
        self.assertEqual(ios.entitlements(profile, ios.BUNDLE_ID)['application-identifier'],
                         'TEAM.dev.horizon.game')
        with self.assertRaisesRegex(RuntimeError, 'outside'):
            ios.entitlements(profile, 'another.app')

    def test_expired_profile_fails_before_importing_credentials(self):
        profile = {'ExpirationDate': datetime.datetime(2000, 1, 1)}
        with patch.object(ios, 'one_file', return_value=Path('unused')), \
                patch.object(ios, 'read_profile', return_value=profile), \
                patch.object(ios, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'expired'):
                ios.sign_install(Path('unused'), Path('unused'), Path('unused'), {})
            run.assert_not_called()

    def test_ipa_preserves_executable_and_bundle_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / 'HorizonGame.app'
            app.mkdir()
            binary = app / 'Horizon'
            binary.write_bytes(b'binary')
            binary.chmod(0o755)
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': ios.BUNDLE_ID}))
            dest = root / 'test.ipa'
            ios.archive(app, dest)
            with zipfile.ZipFile(dest) as archive:
                info = archive.getinfo('Payload/HorizonGame.app/Horizon')
                self.assertTrue((info.external_attr >> 16) & 0o111)
                self.assertEqual(archive.read(info), b'binary')
            self.assertFalse((app / 'embedded.mobileprovision').exists())


if __name__ == '__main__':
    unittest.main()
