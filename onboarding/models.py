"""Provider-only model publication through Magpie's native loopback API."""
import copy
import http.cookiejar
import json
import os
import secrets
import shutil
import signal
import socket
import subprocess
import time
import urllib.request

from .magpie import NativeMagpieError


PROVIDER = 'trae-cn'
DEFAULTS = {'fallback': [], 'contexts': {}, 'outputs': {}, 'compacts': {}, 'proxy': '',
            'accountProxies': {}, 'maxConcurrency': None, 'queueLimit': 0, 'queueWait': 0,
            'maxRPM': 0, 'priceRate': 0, 'pinUpstream': False}


def target(document):
    if not isinstance(document, dict) or not isinstance(document.get('providers'), list):
        raise NativeMagpieError('model_provider_response_invalid')
    matches = [p for p in document['providers'] if p.get('id') == PROVIDER]
    if len(matches) != 1 or not isinstance(matches[0].get('models'), list):
        raise NativeMagpieError('model_provider_missing')
    return matches[0]


def eligible(provider):
    models = provider['models']
    if any(not isinstance(m, dict) or not isinstance(m.get('id'), str) or not m['id'] for m in models):
        raise NativeMagpieError('model_catalog_invalid')
    result = list(dict.fromkeys(m['id'] for m in models if not m.get('noAPI')))
    if not result:
        raise NativeMagpieError('model_catalog_empty')
    return result


def save_body(provider):
    # Match the installed subscription editor's Save contract. Omitted routing
    # and modelPrefs mean unchanged, as in the editor; no account edits are made.
    chosen = provider.get('chosen', [])
    if not isinstance(chosen, list) or any(not isinstance(m, str) for m in chosen):
        raise NativeMagpieError('model_selection_invalid')
    body = {k: copy.deepcopy(provider.get(k, default)) for k, default in DEFAULTS.items()}
    body.update(id=PROVIDER, models=list(dict.fromkeys(chosen + eligible(provider))),
                noModels=False, unlisted=False)
    if provider.get('carriesCompaction'):
        body['nativeCompaction'] = bool(provider.get('nativeCompaction'))
    return body


def selections(document):
    return {p['id']: {k: copy.deepcopy(p.get(k)) for k in ('chosen', 'noModels', 'unlisted')}
            for p in document['providers'] if p['id'] != PROVIDER}


def publish(api):
    before = api('providers')
    provider = target(before)
    body = save_body(provider)
    state = api('state')
    settings = copy.deepcopy(state.get('settings'))
    # Re-read before writing: do not knowingly clobber a simultaneous edit.
    if api('providers') != before or api('state').get('settings') != settings:
        raise NativeMagpieError('model_settings_changed_before_save')
    needed = (set(body['models']) != set(provider.get('chosen', []))
              or provider.get('noModels', False) or provider.get('unlisted', False)
              or not all(m.get('on') for m in provider['models'] if not m.get('noAPI')))
    if needed:
        api('provider/save', body)
    after = api('providers')
    current = target(after)
    ids = eligible(current)
    if (not set(ids).issubset(set(current.get('chosen', [])))
            or current.get('noModels') or current.get('unlisted')
            or not all(m.get('on') for m in current['models'] if not m.get('noAPI'))):
        raise NativeMagpieError('model_publication_not_confirmed')
    if (selections(before) != selections(after) or api('state').get('settings') != settings
            or any(current.get(k, default) != provider.get(k, default) for k, default in DEFAULTS.items())
            or any(current.get(k) != provider.get(k) for k in ('routing', 'affinity', 'sink', 'nativeCompaction'))):
        raise NativeMagpieError('model_unrelated_settings_changed')
    return {'provider': PROVIDER, 'model_count': len(ids), 'models': ids,
            'changed': bool(needed), 'agent_filters_preserved': True}


class LocalModelAPI:
    """Short-lived native web API, never opens or automates a browser."""
    def __init__(self, adapter):
        self.adapter = adapter
        self.process = None

    def __enter__(self):
        executable = shutil.which('magpie')
        if not executable:
            raise NativeMagpieError('native_cli_missing')
        env = self.adapter._prepare()
        # Login disables account discovery, which also hides plugin providers
        # from the management API. This child needs the existing provider list.
        env.pop('MAGPIE_NO_ACCOUNTS', None)
        env['MAGPIE_WEB_KEY'] = secrets.token_urlsafe(32)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        self.base = f'http://127.0.0.1:{port}'
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                         urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.process = subprocess.Popen([executable, 'web', '--no-open', '--addr', f'127.0.0.1:{port}'],
                                        cwd=self.adapter.root, env=env, stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                        start_new_session=True)
        try:
            deadline = time.monotonic() + self.adapter.timeout
            while time.monotonic() < deadline and self.process.poll() is None:
                try:
                    with self.opener.open(self.base + '/?k=' + env['MAGPIE_WEB_KEY'], timeout=2) as response:
                        response.read(1024)
                    return self
                except Exception:
                    time.sleep(.2)
            raise NativeMagpieError('model_api_start_timeout')
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __call__(self, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base + '/api/' + path, data=data,
                                         headers={'Content-Type': 'application/json', 'Origin': self.base})
        try:
            with self.opener.open(request, timeout=20) as response:
                raw = response.read(8_000_001)
                if len(raw) > 8_000_000:
                    raise ValueError
                result = json.loads(raw)
                if isinstance(result, dict) and result.get('error'):
                    raise ValueError
                return result
        except Exception:
            # Mutations are not blindly repeated. Next run reads selection first.
            raise NativeMagpieError('model_api_request_failed') from None

    def __exit__(self, *_):
        if self.process:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=3)
            except ProcessLookupError:
                self.process.wait(timeout=3)


def publish_models(adapter):
    with LocalModelAPI(adapter) as api:
        result = publish(api)
    result['storage'] = 'default' if hasattr(adapter, 'default_config') else 'isolated'
    return result
