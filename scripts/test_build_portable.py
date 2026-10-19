import base64
import hashlib
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('portable', Path(__file__).with_name('build-portable.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PortableTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='portable-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.payloads = self.root / 'payloads'
        self.payloads.mkdir()
        self.pins = {}
        for index, name in enumerate(module.PINS):
            data = ('SYNTHETIC-NOT-AN-INSTALLER-' + str(index)).encode()
            (self.payloads / name).write_bytes(data)
            self.pins[name] = hashlib.sha256(data).hexdigest()
        self.config = dict(tailscaleAuthKey='tskey-auth-' + 'x' * 32,
                           publicKey='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB test',
                           expectedTailnet='example.ts.net', logEndpoints=[], compatibilityMode=True)

    def build(self, name, update=False):
        with patch.dict(module.PINS, self.pins, clear=True):
            return module.build(self.config, self.payloads, self.root / name, update)

    def test_full_zip_has_complete_runtime_and_manifest(self):
        digest = self.build('full.zip')
        self.assertEqual(digest, hashlib.sha256((self.root / 'full.zip').read_bytes()).hexdigest())
        with zipfile.ZipFile(self.root / 'full.zip') as archive:
            for name in (*module.SCRIPTS, 'setup.ps1', 'SHA256SUMS.txt', *self.pins):
                self.assertIn('Friend-Migration-SSH/' + name, archive.namelist())
            setup = archive.read('Friend-Migration-SSH/setup.ps1').decode('utf-8-sig')
            self.assertIn('$CompatibilityMode = $true', setup)
            self.assertNotIn('__TAILSCALE_AUTH_KEY__', setup)
            self.assertIsNone(archive.testzip())

    def test_update_contains_all_scripts_but_no_installers(self):
        self.build('update.zip', True)
        with zipfile.ZipFile(self.root / 'update.zip') as archive:
            for name in (*module.SCRIPTS, 'setup.ps1', 'SHA256SUMS.txt'):
                self.assertIn(name, archive.namelist())
            self.assertFalse(any(name.endswith('.msi') for name in archive.namelist()))
            manifest = archive.read('SHA256SUMS.txt').decode()
            for name in self.pins:
                self.assertIn(name, manifest)

    def test_refuses_overwrite(self):
        (self.root / 'existing.zip').write_bytes(b'keep')
        with self.assertRaises(ValueError):
            self.build('existing.zip')
        self.assertEqual((self.root / 'existing.zip').read_bytes(), b'keep')

    def test_corrupt_payload_does_not_produce_output(self):
        (self.payloads / next(iter(self.pins))).write_bytes(b'corrupt')
        with self.assertRaises(ValueError):
            self.build('bad.zip')
        self.assertFalse((self.root / 'bad.zip').exists())

    def test_malformed_key_does_not_produce_output(self):
        algorithm = b'ssh-ed25519'
        wire = struct.pack('>I', len(algorithm)) + algorithm + b'X'
        self.config['publicKey'] = 'ssh-ed25519 ' + base64.b64encode(wire).decode()
        with self.assertRaises(ValueError):
            self.build('bad-key.zip')
        self.assertFalse((self.root / 'bad-key.zip').exists())


if __name__ == '__main__':
    unittest.main()
