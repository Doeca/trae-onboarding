"""Offline native adapter tests. No installed CLI, live login, or upstream API."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

from onboarding import magpie
from onboarding.magpie import NativeMagpie, NativeMagpieError


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = {
    "initial_refresh": {"RefreshToken": "initial-only", "RefreshExpireAt": 1900000000000},
    "credentials": {"Token": "access-rotated", "RefreshToken": "refresh-rotated",
                    "TokenExpireAt": 1800000000000, "RefreshExpireAt": 1950000000000},
    "identity": {"HostInfo": {"Api": magpie.ENTERPRISE_ORIGIN,
                              "Console": magpie.ENTERPRISE_ORIGIN,
                              "Core": magpie.ENTERPRISE_ORIGIN},
                 "Data": {"UserInfo": {"Scope": "enterprise", "UserID": "123", "TenantID": "456"},
                          "IsAllowLogin": True, "IsSetTenant": True}},
}

# This process impersonates only the local native CLI protocol. It receives
# no API credentials and can bind/connect only to its ephemeral loopback port.
FAKE_CLI = r'''
import http.server, json, os, pathlib, signal, subprocess, sys, time, urllib.parse
root = pathlib.Path.cwd()
mode = (root / 'mode').read_text()
if mode == 'missing':
    print('import error https://secret.invalid/?token=DO_NOT_LOG', flush=True)
    sys.exit(1)
if mode == 'overflow':
    sys.stdout.write('x' * 2100000); sys.stdout.flush(); time.sleep(10)
if mode != 'unguarded':
    pathlib.Path(os.environ['NATIVE_MAGPIE_GUARD_MARKER']).write_text(os.environ['NATIVE_MAGPIE_GUARD_NONCE'])
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        (root / 'received.json').write_text(json.dumps(q))
        credentials = json.loads(q['userJwt'][0])
        auth = {'type': 'oauth', 'access': credentials['Token'], 'refresh': credentials['RefreshToken'],
                'uid': '', 'account': {'IsAllowLogin': True}, 'deviceId': 'native-device'}
        if mode == 'wrong_pair': auth['refresh'] = q['refreshToken'][0]
        if mode == 'mapped': auth.update(uid='123', account={'TenantID':'456'})
        if mode != 'no_save':
            p = pathlib.Path(os.environ['XDG_CONFIG_HOME']) / 'magpie/plugin-auth.json'
            data = json.loads(p.read_text()) if p.exists() else {}
            data['trae-cn#fresh'] = auth
            p.write_text(json.dumps(data))
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
q = {'device_id': 'native-device', 'x_device_id': 'native-device', 'machine_id': 'native-machine',
     'login_trace_id': 'native-trace', 'auth_callback_url': f'http://127.0.0.1:{server.server_port}/authorize'}
url = 'https://www.trae.cn/authorization?' + urllib.parse.urlencode(q)
# Exercise streaming URL boundaries: do not recognize incomplete URLs.
sys.stdout.write(url[:80]); sys.stdout.flush(); time.sleep(.03)
print(url[80:], flush=True)
if mode in ('timeout', 'descendant'):
    if mode == 'descendant':
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        (root / 'child.pid').write_text(str(child.pid))
    time.sleep(60)
server.handle_request()
server.server_close()
sys.exit(4 if mode == 'nonzero' else 0)
'''


class NativeMagpieTests(unittest.TestCase):
    def setUp(self):
        (ROOT / 'tmp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='test-native-', dir=ROOT / 'tmp')
        self.directory = Path(self.temp.name)
        self.asset_cache = self.directory / 'runtime-source'
        manifest = []
        for relative, _, mode in magpie.RUNTIME_ASSETS:
            asset = self.asset_cache / relative
            asset.parent.mkdir(parents=True, exist_ok=True)
            asset.write_bytes(('offline fake asset ' + relative).encode())
            manifest.append((relative, hashlib.sha256(asset.read_bytes()).hexdigest(), mode))
        (self.asset_cache / 'sessions.json').write_text('must never copy')
        self.runtime_patches = [patch.object(magpie, 'RUNTIME_CACHE', self.asset_cache),
                                patch.object(magpie, 'RUNTIME_ASSETS', tuple(manifest))]
        for patcher in self.runtime_patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        self.plugin = self.directory / 'original.mjs'
        self.plugin.write_text('export const TraeCNAuthPlugin = {}; export const TraeGlobalAuthPlugin = {};\n')
        self.script = self.directory / 'fake_cli.py'
        self.script.write_text(textwrap.dedent(FAKE_CLI))
        self.adapter = NativeMagpie(self.directory / 'isolated', self.plugin, timeout=3)
        self.adapter.root.mkdir()
        self.real_popen = subprocess.Popen

    def tearDown(self):
        self.temp.cleanup()

    def run_login(self, mode='ok', issue=None):
        (self.adapter.root / 'mode').write_text(mode)
        def fake_popen(command, **kwargs):
            self.assertEqual(command, ['/fake/magpie', 'plugin', 'login', 'trae-cn'])
            return self.real_popen([sys.executable, '-I', str(self.script)], **kwargs)
        with patch.object(magpie.shutil, 'which', return_value='/fake/magpie'), \
                patch.object(magpie.subprocess, 'Popen', side_effect=fake_popen):
            return self.adapter.login(issue or (lambda q: FIXTURE))

    def test_callback_preserves_captured_shapes_and_rotated_pair(self):
        seen = []
        def issue(query):
            seen.append(query)
            return FIXTURE
        result = self.run_login(issue=issue)
        self.assertEqual(seen[0]['device_id'], ['native-device'])
        self.assertEqual(seen[0]['login_trace_id'], ['native-trace'])
        received = json.loads((self.adapter.root / 'received.json').read_text())
        self.assertEqual(json.loads(received['userInfo'][0]), FIXTURE['identity']['Data'])
        self.assertEqual(json.loads(received['userJwt'][0]), FIXTURE['credentials'])
        self.assertEqual(received['refreshToken'], ['initial-only'])
        self.assertEqual(received['data'], ['initial-only'])
        self.assertEqual(received['refreshExpireAt'], ['1900000000000'])
        self.assertNotIn('authHost', received)
        self.assertEqual(result['account_key'], 'trae-cn#fresh')
        self.assertFalse(result['uid_present'])
        self.assertFalse(result['tenant_matches'])
        self.assertNotIn('access-rotated', json.dumps(result))
        self.assertNotIn('refresh-rotated', json.dumps(result))
        self.assertEqual(self.adapter.reconcile(FIXTURE['credentials'])['account_key'], 'trae-cn#fresh')

    def test_identity_flags_do_not_require_mapping(self):
        result = self.run_login('mapped')
        self.assertTrue(result['uid_matches'])
        self.assertTrue(result['tenant_matches'])

    def test_nonzero_exit_is_failure_but_reconcile_finds_saved_pair(self):
        with self.assertRaisesRegex(NativeMagpieError, '^native_cli_failed$'):
            self.run_login('nonzero')
        self.assertIsNotNone(self.adapter.reconcile(FIXTURE['credentials']))

    def test_http_200_without_pair_is_not_success(self):
        for mode in ('no_save', 'wrong_pair'):
            with self.subTest(mode=mode), self.assertRaisesRegex(NativeMagpieError, '^native_auth_not_saved$'):
                self.run_login(mode)
            self.assertIsNone(self.adapter.reconcile(FIXTURE['credentials']))

    def test_existing_matching_pair_is_not_new_login(self):
        self.run_login()
        with self.assertRaisesRegex(NativeMagpieError, '^native_credentials_preexisting$'):
            self.run_login()

    def test_existing_unrelated_auth_is_not_success(self):
        self.adapter._prepare()
        self.adapter.auth_file.write_text(json.dumps({'trae-cn': {'type': 'oauth', 'access': 'old', 'refresh': 'old'}}))
        with self.assertRaisesRegex(NativeMagpieError, '^native_auth_not_saved$'):
            self.run_login('no_save')

    def test_missing_guard_never_calls_issuer(self):
        def issue(_):
            self.fail('issuer called without guard')
        with self.assertRaisesRegex(NativeMagpieError, '^native_guard_not_loaded$'):
            self.run_login('unguarded', issue)

    def test_output_and_import_failures_never_leak_raw_diagnostics(self):
        with self.assertRaisesRegex(NativeMagpieError, '^native_login_url_missing$'):
            self.run_login('missing')
        with self.assertRaisesRegex(NativeMagpieError, '^native_output_limit$'):
            self.run_login('overflow')

    def test_timeout_terminates_process_group(self):
        self.adapter.timeout = .4
        with self.assertRaisesRegex(NativeMagpieError, '^native_login_timeout$'):
            self.run_login('descendant')
        pid = int((self.adapter.root / 'child.pid').read_text())
        stat = Path(f'/proc/{pid}/stat')
        # An orphan may briefly be a zombie until the container init reaps it.
        if stat.exists():
            self.assertEqual(stat.read_text().split()[2], 'Z')
        self.assertIsNone(self.adapter._proc)

    def test_issuer_error_is_sanitized(self):
        def issue(_):
            raise ValueError('secret credentials and URL')
        with self.assertRaisesRegex(NativeMagpieError, '^native_issuance_failed$'):
            self.run_login(issue=issue)

    def test_query_cannot_redirect_callback(self):
        def issue(query):
            query['auth_callback_url'][0] = 'https://external.invalid/'
            return FIXTURE
        self.assertEqual(self.run_login(issue=issue)['account_key'], 'trae-cn#fresh')

    def test_callback_validation(self):
        from urllib.parse import urlencode
        for callback in ('http://localhost:123/authorize', 'https://127.0.0.1:123/authorize',
                         'http://127.0.0.1:123/other', 'http://u@127.0.0.1:123/authorize',
                         'http://127.0.0.1:123/authorize?extra=1', 'http://127.0.0.1/authorize'):
            query = {'device_id': 'x', 'x_device_id': 'x', 'login_trace_id': 't', 'auth_callback_url': callback}
            with self.subTest(callback=callback), self.assertRaisesRegex(NativeMagpieError, '^native_session_invalid$'):
                NativeMagpie._query('https://www.trae.cn/authorization?' + urlencode(query))

    def test_isolation_rejects_real_directory_and_symlink_escape(self):
        with self.assertRaisesRegex(NativeMagpieError, '^native_config_not_isolated$'):
            NativeMagpie(Path.home() / '.config/magpie', self.plugin)
        outside = self.directory / 'other'
        outside.mkdir()
        (self.adapter.root / 'config').symlink_to(outside)
        with self.assertRaises(NativeMagpieError):
            self.adapter._prepare()
        self.assertEqual(list(outside.iterdir()), [])

    def test_unmanaged_config_and_auth_symlink_rejected(self):
        (self.adapter.root / 'config').mkdir()
        with self.assertRaisesRegex(NativeMagpieError, '^native_config_unmanaged$'):
            self.adapter._prepare()
        (self.adapter.root / 'config').rmdir()
        self.adapter._prepare()
        self.adapter.auth_file.symlink_to(self.plugin)
        with self.assertRaisesRegex(NativeMagpieError, '^native_artifact_not_isolated$'):
            self.adapter.reconcile(FIXTURE['credentials'])

    def test_environment_and_wrapper_are_isolated(self):
        original = self.plugin.read_bytes()
        with patch.dict(os.environ, {'MAGPIE_CONFIG_DIR': '/real', 'NODE_OPTIONS': '--import secret',
                                     'UPSTREAM_TOKEN': 'secret', 'HTTP_PROXY': 'http://secret',
                                     'LARK_CHANNEL': 'bridge', 'LARK_CHANNEL_CHAT_ID': 'chat',
                                     'LARKSUITE_CLI_CONFIG_DIR': '/bridge-config'}):
            env = self.adapter._prepare()
        self.assertNotIn('MAGPIE_CONFIG_DIR', env)
        self.assertNotIn('UPSTREAM_TOKEN', env)
        self.assertNotIn('HTTP_PROXY', env)
        self.assertEqual(env['NODE_OPTIONS'], '')
        self.assertEqual(env['LARK_CHANNEL'], 'bridge')
        self.assertEqual(env['LARK_CHANNEL_CHAT_ID'], 'chat')
        self.assertEqual(env['LARKSUITE_CLI_CONFIG_DIR'], '/bridge-config')
        self.assertEqual(env['MAGPIE_BUN'], str(self.adapter.root / 'cache/magpie' / magpie.RUNTIME_ASSETS[0][0]))
        copied = {str(p.relative_to(self.adapter.root / 'cache/magpie'))
                  for p in (self.adapter.root / 'cache/magpie').rglob('*') if p.is_file()}
        self.assertEqual(copied, {entry[0] for entry in magpie.RUNTIME_ASSETS})
        self.assertEqual(env['HOME'], str(self.adapter.root / 'home'))
        self.assertEqual(env['XDG_CONFIG_HOME'], str(self.adapter.root / 'config'))
        self.assertEqual(self.plugin.read_bytes(), original)
        wrapper = (self.adapter.root / 'guarded-plugin/index.mjs').read_text()
        self.assertLess(wrapper.index('network_guard.mjs'), wrapper.index('await import'))
        self.assertEqual((self.adapter.root / 'bin/xdg-open').read_text(), '#!/bin/sh\nexit 0\n')

    def test_runtime_mismatch_or_missing_fails_before_process(self):
        asset = self.asset_cache / magpie.RUNTIME_ASSETS[0][0]
        asset.write_text('tampered')
        with patch.object(magpie.subprocess, 'Popen') as process:
            with self.assertRaisesRegex(NativeMagpieError, '^native_runtime_integrity_failed$'):
                self.adapter.login(lambda _: FIXTURE)
            process.assert_not_called()
        asset.unlink()
        with self.assertRaisesRegex(NativeMagpieError, '^native_runtime_missing$'):
            self.adapter._prepare()
        self.assertFalse(list(self.adapter.root.rglob('*.copy')))

    def test_runtime_existing_copy_is_verified(self):
        self.adapter._prepare()
        destination = self.adapter.root / 'cache/magpie' / magpie.RUNTIME_ASSETS[0][0]
        destination.write_text('tampered copied runtime')
        with self.assertRaisesRegex(NativeMagpieError, '^native_runtime_integrity_failed$'):
            self.adapter._prepare()

    def test_enterprise_hostinfo_is_required(self):
        query = {'login_trace_id': ['native-trace']}
        for key in ('Api', 'Console', 'Core'):
            for host in ('https://www.trae.cn', 'http://console.enterprise.trae.cn',
                         'https://console.enterprise.trae.cn.evil.invalid',
                         'https://console.enterprise.trae.cn/path'):
                fixture = copy.deepcopy(FIXTURE)
                fixture['identity']['HostInfo'][key] = host
                with self.subTest(key=key, host=host), self.assertRaisesRegex(
                        NativeMagpieError, '^native_callback_payload_invalid$'):
                    self.adapter._payload(query, fixture)

    def test_reconcile_is_exact_and_rejects_ambiguous(self):
        self.adapter._prepare()
        self.assertIsNone(self.adapter.reconcile(FIXTURE['credentials']))
        auth = {'type': 'oauth', 'access': 'access-rotated', 'refresh': 'refresh-rotated'}
        self.adapter.auth_file.write_text(json.dumps({'other-provider': auth}))
        self.assertIsNone(self.adapter.reconcile(FIXTURE['credentials']))
        self.adapter.auth_file.write_text(json.dumps({'trae-cn': auth, 'trae-cn#duplicate': auth}))
        with self.assertRaisesRegex(NativeMagpieError, '^native_auth_ambiguous$'):
            self.adapter.reconcile(FIXTURE['credentials'])

    @unittest.skipUnless(shutil.which('node'), 'Node needed for offline JS guard test')
    def test_wrapper_blocks_every_fetch_before_original_import(self):
        # Any successful fetch here would fail the test; no request is made.
        self.plugin.write_text('''
let blocked = false;
try { await fetch('http://127.0.0.1:1/never-contact'); }
catch (e) { blocked = e.message === 'native_login_fetch_blocked'; }
if (!blocked) throw new Error('guard failed');
export const TraeCNAuthPlugin = {guarded:true};
export const TraeGlobalAuthPlugin = {};
''')
        env = self.adapter._prepare()
        wrapper = self.adapter.root / 'guarded-plugin/index.mjs'
        result = subprocess.run([shutil.which('node'), str(wrapper)], cwd=self.adapter.root,
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.adapter._guard_marker.read_text(), self.adapter._nonce)
        self.assertEqual(result.stdout, b'')


class BunGuardRegressionTests(unittest.TestCase):
    @unittest.skipUnless(Path('/root/.cache/magpie/bun/1.4.4/magpie-bun').is_file(), 'Pinned Bun unavailable')
    def test_guard_loads_on_real_bun_and_blocks_fetch(self):
        # Only load the guard: no CLI login, plugin, or real network request.
        with tempfile.TemporaryDirectory(prefix='test-bun-guard-', dir=ROOT / 'tmp') as directory:
            marker = Path(directory) / 'guard-loaded'
            env = os.environ.copy()
            env.update(NATIVE_MAGPIE_GUARD_MARKER=str(marker), NATIVE_MAGPIE_GUARD_NONCE='offline-nonce')
            guard = (ROOT / 'onboarding/network_guard.mjs').as_uri()
            code = ('await import(' + json.dumps(guard) + '); '
                    'globalThis.fetch = async () => { throw new Error("guard-overwritten"); }; '
                    'let blocked=false; try { await fetch("http://127.0.0.1:1/not-sent"); } '
                    'catch(e) { blocked=e.message === "native_login_fetch_blocked"; } '
                    'if (!blocked) process.exit(1);')
            p = subprocess.run(['/root/.cache/magpie/bun/1.4.4/magpie-bun', '-e', code],
                               env=env, capture_output=True, timeout=10)
            self.assertEqual(p.returncode, 0)
            self.assertEqual(marker.read_text(), 'offline-nonce')


if __name__ == '__main__':
    unittest.main()
