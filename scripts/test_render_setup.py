import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('renderer', Path(__file__).with_name('render-setup.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class RenderTests(unittest.TestCase):
    def setUp(self):
        self.source = (Path(__file__).parents[1] / 'payload/setup.ps1').read_text(encoding='utf-8-sig')
        self.config = dict(tailscaleAuthKey='tskey-auth-' + 'x' * 32,
            publicKey='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB test',
            expectedTailnet='example.ts.net', logEndpoints=[])

    def render(self):
        return module.render(self.source, self.config, 'a' * 64, 'b' * 64)

    def test_comment_quote_remains_literal(self):
        self.config['publicKey'] += " '; throw 'injection"
        self.assertIn("test ''; throw ''injection'", self.render())

    def test_endpoint_quote_remains_literal(self):
        self.config['logEndpoints'] = ["https://example.com/a'b/events"]
        self.assertIn("'https://example.com/a''b/events'", self.render())

    def test_reject_executable_or_plaintext_inputs(self):
        for field, value in [('tailscaleAuthKey', "tskey-auth-' ; throw 'bad"),
                             ('expectedTailnet', "example.ts.net';exit;#"),
                             ('publicKey', self.config['publicKey']+'\ncommand'),
                             ('logEndpoints', ['http://example.com/events']),
                             ('logEndpoints', ['https://user:pass@example.com/events'])]:
            with self.subTest(field=field):
                original = self.config[field]; self.config[field] = value
                with self.assertRaises(ValueError): self.render()
                self.config[field] = original

    def test_markers_are_not_reinterpreted_in_input(self):
        self.config['publicKey'] += ' __EXPECTED_TAILNET__'
        self.assertIn('test __EXPECTED_TAILNET__', self.render())

if __name__ == '__main__':
    unittest.main()
