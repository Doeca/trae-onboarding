"""Durable native gateway key setup; no daemon installation or model calls."""
import secrets
from urllib.parse import urlsplit

from .core import Halt, emit
from .models import LocalModelAPI


SCOPE = ['trae-cn/*']


def base_url(value):
    try:
        url = urlsplit(value)
        if (url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password
                or url.query or url.fragment or url.path not in ('', '/', '/v1', '/v1/')
                or any(ord(c) < 33 or ord(c) > 126 for c in value)):
            raise ValueError
        if url.port is not None and not 1 <= url.port <= 65535:
            raise ValueError
        return value.rstrip('/') if url.path.rstrip('/') == '/v1' else value.rstrip('/') + '/v1'
    except (TypeError, ValueError):
        raise Halt('gateway_url_invalid') from None


def keys_of(document):
    if not isinstance(document, dict) or not isinstance(document.get('keys'), list):
        raise Halt('gateway_keys_response_invalid')
    if any(not isinstance(k, dict) or not k.get('id') or not isinstance(k.get('name'), str)
           for k in document['keys']):
        raise Halt('gateway_keys_response_invalid')
    return document['keys']


class GatewaySetup:
    def __init__(self, adapter, terminal, lan=False, url=None):
        self.adapter, self.terminal = adapter, terminal
        self.lan = lan
        self.url = base_url(url) if url else None
        self.last_shown = None

    def configure(self, api, record, save):
        settings = api('settings')
        if not isinstance(settings, dict) or type(settings.get('lan', False)) is not bool:
            raise Halt('gateway_settings_response_invalid')
        # Prefer the effective native URL, not a guessed host or client-side path.
        url = self.url or base_url(settings.get('gateway'))
        keys = keys_of(api('caller-keys'))
        matches = [k for k in keys if k['name'] == record['name']]
        if len(matches) > 1:
            raise Halt('gateway_key_ambiguous')
        if not matches:
            if record.get('id'):
                raise Halt('gateway_key_removed_requires_manual_action')
            if record.get('create_started'):
                raise Halt('gateway_key_unknown_outcome_requires_reconciliation')
            record['create_started'] = True
            save()
            api('caller-keys/add-key', {'name': record['name'], 'secret': record['secret']})
            matches = [k for k in keys_of(api('caller-keys')) if k['name'] == record['name']]
        if len(matches) != 1 or (record.get('id') and matches[0]['id'] != record['id']):
            raise Halt('gateway_key_not_confirmed')
        key = matches[0]
        record['id'] = key['id']
        save()
        # Only copy our journal-owned key, never a preexisting unrelated key.
        copied = api('caller-keys/copy-key', {'key': key['id']})
        if not isinstance(copied, dict) or copied.get('secret') != record['secret']:
            raise Halt('gateway_key_identity_mismatch')
        if key.get('off'):
            raise Halt('gateway_key_disabled_requires_manual_action')
        if key.get('models') != SCOPE:
            api('caller-keys/models-key', {'key': key['id'], 'models': SCOPE})
        after = keys_of(api('caller-keys'))
        current = [k for k in after if k['id'] == key['id']]
        if len(current) != 1 or current[0].get('models') != SCOPE or current[0].get('off'):
            raise Halt('gateway_key_scope_not_confirmed')
        # Other client keys and restrictions must not be edited by this step.
        fields = ('id', 'name', 'off', 'models', 'accounts')
        fingerprint = lambda rows: {k['id']: {f: k.get(f) for f in fields}
                                    for k in rows if k['id'] != key['id']}
        if fingerprint(keys) != fingerprint(after):
            raise Halt('gateway_other_keys_changed')
        # Only expose the listener after our new key has its final restrictions.
        if self.lan and not settings.get('lan', False):
            api('settings/lan', {'on': True})
            settings = api('settings')
            if settings.get('lan') is not True:
                raise Halt('gateway_sharing_not_confirmed')
        return url, settings.get('lan', False)

    def finish(self, state, save):
        config = str(self.adapter.config.resolve())
        record = state.get('gateway')
        if record is None:
            record = {'name': 'trae-onboarding-' + secrets.token_hex(10),
                      'secret': 'mp-' + secrets.token_urlsafe(36), 'config': config}
            state['gateway'] = record
        if record.get('config') != config:
            raise Halt('gateway_config_mismatch')
        record['status'] = 'PENDING'
        save()
        try:
            with LocalModelAPI(self.adapter) as api:
                url, shared = self.configure(api, record, save)
            record.update(status='COMPLETE', url=url, shared=shared)
            save()
            marker = (record['id'], url, shared)
            if self.last_shown != marker:
                self.terminal.show(url, record['secret'], shared=shared)
                self.last_shown = marker
            emit('gateway_configured', shared=shared, service_started=False, key_scope=SCOPE)
        except Exception:
            record['status'] = 'FAILED'
            save()
            raise
