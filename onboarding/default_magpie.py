"""Explicitly authorized native login in the user's normal Magpie configuration.

Only the login child receives a fetch guard; installed plugins and their
registration remain unchanged. Subsequent normal Magpie use is NOT guarded.
"""
import json
import os
from pathlib import Path
import shlex

from .magpie import NativeMagpie, NativeMagpieError


class DefaultMagpie(NativeMagpie):
    def __init__(self, work_root, plugin_path, timeout=120):
        super().__init__(work_root, plugin_path, timeout)
        self.default_home = Path.home()
        self.default_config_home = Path(os.environ.get('XDG_CONFIG_HOME', str(self.default_home / '.config'))).resolve()
        self.default_config = self.default_config_home / 'magpie'
        self.default_auth = self.default_config / 'plugin-auth.json'
        if not self.default_config.is_dir() or self.default_auth.is_symlink():
            raise NativeMagpieError('default_config_missing_or_unsafe')
        self.config = self.default_config
        self.auth_file = self.default_auth

    def _safe_path(self, path):
        if Path(path).absolute() == self.default_auth.absolute():
            if path.is_symlink() or path.resolve() != path.absolute():
                raise NativeMagpieError('default_auth_symlink_not_allowed')
            return path
        return super()._safe_path(path)

    def _prepare(self):
        # Parent builds only test work artifacts, never writes the real plugins.json.
        self.config = self.root / 'config' / 'magpie'
        self.auth_file = self.config / 'plugin-auth.json'
        try:
            env = super()._prepare()
        finally:
            self.config = self.default_config
            self.auth_file = self.default_auth
        registry = self.default_config / 'plugins.json'
        try:
            plugins = json.loads(registry.read_text()).get('plugins', [])
            if not any('opencode-trae-auth' in str(p.get('spec', '')) for p in plugins):
                raise ValueError
        except Exception:
            raise NativeMagpieError('default_trae_plugin_not_registered') from None
        runtime = env['MAGPIE_BUN']
        guard = Path(__file__).with_name('network_guard.mjs').resolve()
        launcher = self.root / 'bin' / 'guarded-native-bun'
        # Explicit run --preload works on pinned Bun; BUN_OPTIONS preload does not.
        # This is a runtime launcher, not a replacement login/host implementation.
        script = ('#!/bin/sh\n'
                  'if [ "$1" = "run" ]; then\n'
                  '  shift\n'
                  '  exec ' + shlex.quote(runtime) + ' run --preload ' + shlex.quote(str(guard)) + ' "$@"\n'
                  'fi\nexec ' + shlex.quote(runtime) + ' "$@"\n')
        self._write(launcher, script, 0o700)
        env.update(HOME=str(self.default_home), XDG_CONFIG_HOME=str(self.default_config_home),
                   MAGPIE_BUN=str(launcher))
        return env

    def login(self, issue):
        before = self._read_auth()
        other = {k: v for k, v in before.items() if k != 'trae-cn' and not k.startswith('trae-cn#')}
        result = super().login(issue)
        after = self._read_auth()
        if any(after.get(k) != v for k, v in other.items()):
            raise NativeMagpieError('other_accounts_changed_during_default_login')
        result['storage'] = 'default'
        return result
