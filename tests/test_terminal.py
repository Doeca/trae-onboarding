import io
import os
import unittest
from unittest.mock import Mock, patch

from onboarding.core import Halt
from onboarding.terminal import SecretTerminal
from onboarding.__main__ import main


class TerminalTests(unittest.TestCase):
    def test_bridge_blocks_before_opening_terminal_or_admin_login(self):
        with patch.dict(os.environ, {'LARK_CHANNEL': '1'}), \
                patch('builtins.open') as opened, patch('onboarding.__main__.Enterprise') as admin, \
                patch('sys.stdout', new_callable=io.StringIO) as output:
            code = main(['run', '--yes-fill-full-seats', '--accept-disposable-mailbox'])
        self.assertEqual(code, 1)
        opened.assert_not_called()
        admin.assert_not_called()
        self.assertIn('gateway_output_requires_local_terminal_not_bridge', output.getvalue())

    def test_secret_only_written_to_controlling_terminal(self):
        tty = Mock()
        tty.isatty.return_value = True
        with patch.dict(os.environ, {}, clear=True), patch('builtins.open', return_value=tty), \
                patch('sys.stdout', new_callable=io.StringIO) as output:
            with SecretTerminal() as terminal:
                terminal.show('http://127.0.0.1:3425/v1', 'offline-key')
        self.assertIn('offline-key', tty.write.call_args.args[0])
        self.assertNotIn('offline-key', output.getvalue())
        tty.close.assert_called_once()

    def test_status_never_serializes_gateway_secret_or_address(self):
        store = Mock()
        store.locked.return_value.__enter__ = Mock()
        store.locked.return_value.__exit__ = Mock(return_value=False)
        store.load.return_value = {'status': 'FULL', 'members': [],
                                   'gateway': {'status': 'COMPLETE', 'secret': 'do-not-print',
                                               'url': 'https://private.example/v1'}}
        with patch('onboarding.__main__.Store', return_value=store), \
                patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(main(['status']), 0)
        self.assertIn('gateway_status', output.getvalue())
        self.assertNotIn('do-not-print', output.getvalue())
        self.assertNotIn('private.example', output.getvalue())

    def test_noninteractive_fails_without_leak(self):
        with patch.dict(os.environ, {}, clear=True), patch('builtins.open', side_effect=OSError('sensitive')):
            with self.assertRaisesRegex(Halt, '^gateway_output_requires_local_terminal$'):
                with SecretTerminal():
                    self.fail('must not open')


if __name__ == '__main__':
    unittest.main()
