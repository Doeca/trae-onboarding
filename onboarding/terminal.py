"""Secrets go only to the caller's controlling terminal, never JSONL logs."""
import os

from .core import Halt


class SecretTerminal:
    def __init__(self):
        self.stream = None

    def __enter__(self):
        if os.environ.get('LARK_CHANNEL'):
            raise Halt('gateway_output_requires_local_terminal_not_bridge')
        try:
            self.stream = open('/dev/tty', 'w', encoding='utf-8')
            if not self.stream.isatty():
                raise OSError
        except OSError:
            self.close()
            raise Halt('gateway_output_requires_local_terminal') from None
        return self

    def show(self, url, key, shared=False):
        if self.stream is None:
            raise Halt('gateway_output_requires_local_terminal')
        self.stream.write('\nMagpie gateway (sensitive; do not share terminal output)\n'
                          'Base URL: ' + url + '\nAPI key: ' + key + '\n'
                          'Key model scope: trae-cn/*\n'
                          + ('Shared gateway mode configured.\n' if shared else
                             'Local-only mode: loopback may trust clients without checking this key.\n')
                          + 'Configuration saved; gateway service must be running separately.\n')
        self.stream.flush()

    def close(self):
        if self.stream is not None:
            self.stream.close()
            self.stream = None

    def __exit__(self, *_):
        self.close()
