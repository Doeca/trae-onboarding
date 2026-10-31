import copy
import io
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

from onboarding.core import Halt
from onboarding.gateway import GatewaySetup, base_url


class API:
    def __init__(self):
        self.keys = [{'id': 'other', 'name': 'existing', 'models': ['other/*']}]
        self.settings = {'gateway': 'http://127.0.0.1:3425', 'theme': 'dark'}
        self.calls = []
        self.secrets = {}
        self.lost_add = False
        self.lost_scope = False

    def __call__(self, path, body=None):
        self.calls.append((path, copy.deepcopy(body)))
        if path == 'settings':
            return copy.deepcopy(self.settings)
        if path == 'caller-keys':
            return {'keys': copy.deepcopy(self.keys)}
        if path == 'caller-keys/add-key':
            self.keys.append({'id': 'ours', 'name': body['name'], 'models': []})
            self.secrets['ours'] = body['secret']
            if self.lost_add:
                raise RuntimeError('uncertain add')
        elif path == 'caller-keys/copy-key':
            return {'secret': self.secrets[body['key']]}
        elif path == 'caller-keys/models-key':
            if self.lost_scope:
                raise RuntimeError('uncertain restriction')
            self.keys[-1]['models'] = body['models']
        elif path == 'settings/lan':
            self.settings['lan'] = body['on']
        else:
            raise AssertionError(path)
        return {'keys': copy.deepcopy(self.keys)}


class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.api = API()
        self.terminal = Mock()
        self.setup = GatewaySetup(Mock(config=Path('/offline/config')), self.terminal)
        self.state = {}
        self.saved = []
        self.context = patch('onboarding.gateway.LocalModelAPI')
        self.factory = self.context.start()
        self.addCleanup(self.context.stop)
        self.factory.return_value.__enter__.return_value = self.api

    def save(self):
        self.saved.append(copy.deepcopy(self.state))

    def test_key_checkpoint_scope_preservation_and_terminal_only(self):
        other = copy.deepcopy(self.api.keys[0])
        with patch('sys.stdout', new_callable=io.StringIO) as output:
            self.setup.finish(self.state, self.save)
            self.setup.finish(self.state, self.save)
        record = self.state['gateway']
        self.assertEqual(record['status'], 'COMPLETE')
        self.assertIn('secret', self.saved[0]['gateway'])
        self.assertTrue(any(s['gateway'].get('create_started') for s in self.saved))
        self.assertEqual(self.api.keys[0], other)
        self.assertEqual(self.api.keys[-1]['models'], ['trae-cn/*'])
        self.assertEqual(sum(p == 'caller-keys/add-key' for p, _ in self.api.calls), 1)
        self.terminal.show.assert_called_once()
        self.assertNotIn(record['secret'], output.getvalue())
        self.assertNotIn('settings/lan', [p for p, _ in self.api.calls])

    def test_lost_add_response_reconciles_without_duplicate(self):
        self.api.lost_add = True
        with self.assertRaises(RuntimeError):
            self.setup.finish(self.state, self.save)
        self.terminal.show.assert_not_called()
        self.assertEqual(self.state['gateway']['status'], 'FAILED')
        self.api.lost_add = False
        self.setup.finish(self.state, self.save)
        self.assertEqual(sum(p == 'caller-keys/add-key' for p, _ in self.api.calls), 1)

    def test_unknown_absent_key_not_blindly_recreated(self):
        self.api.lost_add = True
        with self.assertRaises(RuntimeError):
            self.setup.finish(self.state, self.save)
        self.api.keys.pop()
        with self.assertRaisesRegex(Halt, 'unknown_outcome'):
            self.setup.finish(self.state, self.save)
        self.assertEqual(sum(p == 'caller-keys/add-key' for p, _ in self.api.calls), 1)

    def test_scope_failure_never_reveals_secret_or_enables_lan(self):
        self.setup.lan = True
        self.api.lost_scope = True
        with self.assertRaises(RuntimeError):
            self.setup.finish(self.state, self.save)
        self.terminal.show.assert_not_called()
        self.assertFalse(self.api.settings.get('lan'))
        self.api.lost_scope = False
        self.setup.finish(self.state, self.save)
        self.assertTrue(self.api.settings['lan'])
        self.assertEqual(self.api.settings['theme'], 'dark')

    def test_existing_rotated_key_and_config_mismatch_stop(self):
        self.setup.finish(self.state, self.save)
        self.api.secrets['ours'] = 'different'
        with self.assertRaisesRegex(Halt, 'identity_mismatch'):
            self.setup.finish(self.state, self.save)
        self.state['gateway']['config'] = '/different'
        with self.assertRaisesRegex(Halt, 'config_mismatch'):
            self.setup.finish(self.state, self.save)

    def test_disabled_key_not_silently_reenabled(self):
        self.setup.finish(self.state, self.save)
        self.api.keys[-1]['off'] = True
        with self.assertRaisesRegex(Halt, 'disabled'):
            self.setup.finish(self.state, self.save)

    def test_address_validation(self):
        self.assertEqual(base_url('https://gateway.example/v1/'), 'https://gateway.example/v1')
        self.assertEqual(base_url('http://127.0.0.1:3425'), 'http://127.0.0.1:3425/v1')
        for value in ('http://u:p@example', 'http://example/?key=secret', 'http://example/\n',
                      'file:///tmp/key', 'http://example/path', 'http://example:0', None):
            with self.subTest(value=value), self.assertRaises(Halt):
                base_url(value)


if __name__ == '__main__':
    unittest.main()
