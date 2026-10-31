import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from onboarding.default_magpie import DefaultMagpie
from onboarding.magpie import NativeMagpie
from onboarding.core import TMP


class DefaultConfigTests(unittest.TestCase):
    def test_prepare_preserves_normal_registration_and_auth(self):
        TMP.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='test-default-config-', dir=TMP) as temporary:
            root = Path(temporary)
            config = root / 'normal' / 'magpie'
            config.mkdir(parents=True)
            registry = config / 'plugins.json'
            registry.write_text(json.dumps({'plugins': [{'spec': '@magpie-community/opencode-trae-auth'}]}))
            auth = config / 'plugin-auth.json'
            auth.write_text(json.dumps({'other': {'type': 'oauth', 'access': 'offline'}}))
            before = registry.read_bytes(), auth.read_bytes()
            with patch.dict(os.environ, {'XDG_CONFIG_HOME': str(config.parent)}):
                adapter = DefaultMagpie(root / 'work', root / 'unused-plugin')
            def fake_prepare(instance):
                (instance.root / 'bin').mkdir(parents=True)
                self.assertNotEqual(instance.config, config)
                return {'MAGPIE_BUN': '/offline/runtime'}
            with patch.object(NativeMagpie, '_prepare', fake_prepare):
                env = adapter._prepare()
            self.assertEqual(Path(env['XDG_CONFIG_HOME']), config.parent)
            self.assertEqual(adapter.auth_file, auth)
            self.assertEqual(before, (registry.read_bytes(), auth.read_bytes()))
            self.assertEqual(adapter._read_auth()['other']['access'], 'offline')
            self.assertIn('run --preload', Path(env['MAGPIE_BUN']).read_text())


if __name__ == '__main__':
    unittest.main()
