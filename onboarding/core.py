import contextlib
import fcntl
import html
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import tempfile
import time
import urllib.parse

import requests

BASE = 'https://console.enterprise.trae.cn'
MAIL_BASE = 'https://www.nimail.cn'
PROJECT = Path(__file__).resolve().parent.parent
TMP = PROJECT / 'tmp'
ATTRIBUTES = ['ent_sso', 'ent_cloud_identity_login', 'ent_wecom_login', 'ent_saml_login',
              'ent_security_repo_blacklist', 'ent_security_access_control', 'ent_content_security',
              'ent_custom_agent', 'allow_personal_mcp_in_team_agent', 'ent_enterprise_hooks',
              'ent_enterprise_skill', 'ent_open_platform', 'ent_knowledge_base', 'ent_custom_model_quota',
              'ent_department_management', 'ent_department_quota', 'ent_feishu_org_sync', 'ent_wecom_org_sync',
              'product_ide', 'product_plugin', 'product_cli', 'product_solo', 'model_embed_doubao',
              'model_embed_others', 'model_enterprise', 'model_customize', 'currency_pricing', 'ai_coding_cue',
              'ent_limit_usage_model', 'ent_mcp_whitelist', 'ent_command_blacklist', 'ent_ai_code_tracking',
              'enable_token_pool', 'work_account_grant_multiplier']


class Halt(Exception):
    """A sanitized business failure which needs attention, not a retry loop."""


class Network(Halt):
    pass


class Unknown(Halt):
    """A mutating request may have committed. Reconcile before any repeat."""


class Business(Halt):
    def __init__(self, code):
        self.code = code
        super().__init__('upstream_business_' + (str(code) if type(code) is int else 'unknown'))


def emit(event, **fields):
    print(json.dumps({'event': event, **fields}, ensure_ascii=False), flush=True)


def under_tmp(path):
    path = Path(path).expanduser().resolve()
    if path == TMP.resolve() or TMP.resolve() not in path.parents:
        raise Halt('state_must_be_inside_project_tmp')
    return path


def admin_settings(path):
    values = {}
    if Path(path).is_file():
        for line in Path(path).read_text().splitlines():
            line = line.strip()
            if line.startswith('export '):
                line = line[7:].strip()
            key, sep, value = line.partition('=')
            if sep and key.strip() in ('TRAE_ADMIN_ACCOUNT', 'TRAE_ADMIN_PASSWORD'):
                parts = shlex.split(value, comments=True)
                if len(parts) != 1:
                    raise Halt('invalid_admin_setting')
                values[key.strip()] = parts[0]
    for key in ('TRAE_ADMIN_ACCOUNT', 'TRAE_ADMIN_PASSWORD'):
        if os.environ.get(key):
            values[key] = os.environ[key]
        if not values.get(key):
            raise Halt('missing_admin_setting')
    return values['TRAE_ADMIN_ACCOUNT'], values['TRAE_ADMIN_PASSWORD']


def atomic_write(path, data):
    fd, temporary = tempfile.mkstemp(prefix='.write-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Store:
    """Encrypted journal, atomic writes, and one execution lock for the workspace."""
    def __init__(self, directory):
        self.directory = under_tmp(directory)
        self.path = self.directory / 'state.gpg'
        self.key = self.directory / 'keys' / 'state.key'
        self.home = self.directory / 'gpg'

    @contextlib.contextmanager
    def locked(self):
        os.umask(0o077)
        TMP.mkdir(mode=0o700, exist_ok=True)
        fd = os.open(TMP / 'onboarding.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Halt('another_onboarding_run_is_active') from None
            self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            self.key.parent.mkdir(mode=0o700, exist_ok=True)
            self.home.mkdir(mode=0o700, exist_ok=True)
            for p in (self.directory, self.key.parent, self.home):
                if p.is_symlink() or p.stat().st_mode & 0o077:
                    raise Halt('insecure_state_directory_permissions')
            if not self.key.exists():
                if self.path.exists():
                    raise Halt('encrypted_state_key_missing')
                fdkey = os.open(self.key, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fdkey, 'wb') as f:
                    f.write(secrets.token_hex(32).encode())
                    f.flush()
                    os.fsync(f.fileno())
            if self.key.is_symlink() or self.key.stat().st_mode & 0o077:
                raise Halt('insecure_key_permissions')
            yield self
        finally:
            os.close(fd)

    def crypt(self, data, decrypt=False):
        read_fd, write_fd = os.pipe()
        try:
            os.write(write_fd, self.key.read_bytes() + b'\n')
            os.close(write_fd)
            write_fd = None
            cmd = ['gpg', '--homedir', str(self.home), '--batch', '--yes', '--no-options',
                   '--pinentry-mode', 'loopback', '--passphrase-fd', str(read_fd),
                   '--output', '-', '--decrypt' if decrypt else '--symmetric']
            if not decrypt:
                cmd.extend(['--cipher-algo', 'AES256'])
            p = subprocess.run(cmd, input=data, capture_output=True, pass_fds=(read_fd,), timeout=30)
            if p.returncode:
                raise Halt('encrypted_storage_failed')
            return p.stdout
        finally:
            os.close(read_fd)
            if write_fd is not None:
                os.close(write_fd)

    def load(self):
        if not self.path.exists():
            return {'version': 1, 'tenant_id': None, 'members': [], 'status': 'READY'}
        if self.path.is_symlink():
            raise Halt('state_symlink_not_allowed')
        data = json.loads(self.crypt(self.path.read_bytes(), decrypt=True))
        if data.get('version') != 1 or not isinstance(data.get('members'), list):
            raise Halt('unsupported_state_version')
        return data

    def save(self, state):
        state['updated_at'] = int(time.time())
        atomic_write(self.path, self.crypt(json.dumps(state, ensure_ascii=False).encode()))


class HTTP:
    def __init__(self, base):
        self.base = base
        self.session = requests.Session()
        self.session.headers.update({'Accept': 'application/json', 'Origin': base, 'Referer': base + '/'})

    def probe(self):
        try:
            p = subprocess.run(['curl', '-4', '-sS', '--connect-timeout', '5', '--max-time', '10',
                                '-o', '/dev/null', '-w', '%{http_code}', self.base + '/'],
                               capture_output=True, timeout=15)
            return p.returncode == 0 and p.stdout in (b'200', b'301', b'302', b'307', b'308', b'404')
        except (OSError, subprocess.TimeoutExpired):
            return False

    def request(self, path, payload=None, safe=False, raw=False):
        for attempt in range(2 if safe else 1):
            try:
                args = {'timeout': (8, 20), 'allow_redirects': False}
                if payload is not None:
                    args['json' if self.base == BASE else 'data'] = payload
                response = self.session.request('GET' if payload is None else 'POST', self.base + path, **args)
            except requests.RequestException:
                if safe and attempt == 0 and self.probe():
                    continue
                raise (Network('network_unavailable') if safe else Unknown('request_outcome_unknown')) from None
            if response.status_code != 200:
                if response.status_code in (502, 503, 504) and safe and attempt == 0 and self.probe():
                    continue
                if response.status_code >= 500:
                    raise Network('upstream_unavailable') if safe else Unknown('request_outcome_unknown')
                raise Halt('upstream_http_' + str(response.status_code))
            if raw:
                return response.text
            try:
                body = response.json()
            except ValueError:
                raise Halt('non_json_response') if safe else Unknown('non_json_mutation_result') from None
            if not isinstance(body, dict):
                raise Halt('unexpected_response_shape') if safe else Unknown('unexpected_mutation_shape')
            if self.base == BASE and (type(body.get('code')) is not int or body['code'] != 0):
                raise Business(body.get('code'))
            if self.base == MAIL_BASE and body.get('success') not in ('true', True):
                raise Halt('mail_api_rejected')
            return body
        raise Network('network_unavailable')


class Enterprise(HTTP):
    def __init__(self, email, password):
        super().__init__(BASE)
        self.email, self.password = email, password
        self.authenticated = False

    def login(self):
        self.session.cookies.clear()
        b = self.request('/trae/gtm/tob/api/v1/account/login', {'Email': self.email, 'Password': self.password})
        if b.get('Data', {}).get('IsAllowLogin') is not True or not any(c.name == 'X-Cloudide-Tob-Session' for c in self.session.cookies):
            raise Halt('login_not_confirmed')
        self.authenticated = True

    def read(self, path, payload):
        if not self.authenticated:
            self.login()
        try:
            return self.request(path, payload, safe=True)
        except Business as error:
            if error.code != 30011:
                raise
            self.login()
            return self.request(path, payload, safe=True)

    def info(self):
        return self.read('/cloudide/api/v3/trae/GetUserInfo', {'Attributes': ATTRIBUTES})

    def departments(self):
        b = self.read('/trae/gtm/tob/api/v1/department/list', {'IncludeMemberCount': False, 'CountMode': 'subtree'})
        if not b.get('RootDepartmentID') or not isinstance(b.get('Departments'), list):
            raise Halt('department_shape_unknown')
        ids = {str(x['DepartmentID']) for x in b['Departments']}
        root = str(b['RootDepartmentID'])
        ids.add(root)
        return root, sorted(ids)

    def members(self, departments):
        members = {}
        for department in departments:
            for page in range(1, 1001):
                b = self.read('/trae/gtm/tob/api/v1/department/member_list',
                              {'DepartmentID': department, 'IncludeSubtree': False,
                               'Statuses': [1, 9, 2, 4, 3, 11], 'Page': page, 'PageSize': 10})
                if not isinstance(b.get('Data'), list) or type(b.get('Total')) is not int:
                    raise Halt('member_list_shape_unknown')
                for row in b['Data']:
                    user = row.get('UserInfo', {})
                    uid = user.get('UserID')
                    if uid is None:
                        raise Halt('member_id_missing')
                    members[str(uid)] = row
                if page * 10 >= b['Total']:
                    break
                if not b['Data']:
                    raise Halt('member_pagination_inconsistent')
            else:
                raise Halt('member_pagination_limit')
        return list(members.values())


def identity(info, email, tenant=None, uid=None, active=False):
    data = info.get('Data', {})
    user = data.get('UserInfo', {})
    if user.get('Email', '').lower() != email.lower() or not user.get('TenantID') or not user.get('UserID'):
        raise Halt('identity_mismatch')
    if tenant is not None and str(user['TenantID']) != str(tenant):
        raise Halt('tenant_mismatch')
    if uid is not None and str(user['UserID']) != str(uid):
        raise Halt('user_id_mismatch')
    if active and (user.get('AccountType') != 1 or user.get('RoleID') != 3 or user.get('UserStatus') != 1
                   or not user.get('JoiningTime') or data.get('IsAllowLogin') is not True):
        raise Halt('active_full_member_not_confirmed')
    return user


def find_member(rows, email):
    found = [r['UserInfo'] for r in rows if r.get('UserInfo', {}).get('Email', '').lower() == email.lower()]
    if len(found) > 1:
        raise Halt('duplicate_email_identity')
    return found[0] if found else None


def capacity(info, rows, managed):
    full = info.get('AccountQuotaSummary', {}).get('Full', {})
    total, occupied, active = full.get('TotalQuota'), full.get('OccupiedCount'), full.get('ActiveCount')
    if any(type(n) is not int for n in (total, occupied, active)) or not 0 <= active <= occupied <= total:
        raise Halt('full_capacity_unknown')
    # Unactivated invitations may not appear in OccupiedCount. Deduplicate across departments.
    pending = set()
    known = set()
    joined_ids = set()
    for row in rows:
        user = row['UserInfo']
        email = user.get('Email', '').lower()
        if not email:
            raise Halt('member_email_missing')
        known.add(email)
        if user.get('AccountType') == 1:
            if 'JoiningTime' not in user:
                raise Halt('member_activation_unknown')
            if not user['JoiningTime']:
                pending.add(email)
            else:
                joined_ids.add(str(user['UserID']))
    # Persisted unfinished work reserves a slot even before its upstream invitation is visible.
    for task in managed:
        if task['phase'] != 'COMPLETE' and task['email'].lower() not in known:
            pending.add(task['email'].lower())
    # Quota counters may lag a just-confirmed activation; use the more conservative count.
    reserved_occupied = max(occupied, len(joined_ids))
    return {'total': total, 'occupied': occupied, 'active': active, 'pending': len(pending),
            'reserved_occupied': reserved_occupied,
            'available': max(0, total - reserved_occupied - len(pending))}


class Mailbox(HTTP):
    def __init__(self):
        super().__init__(MAIL_BASE)

    def apply(self, email):
        b = self.request('/api/applymail', {'mail': email}, safe=True)
        if b.get('user') != email:
            raise Halt('mailbox_identity_mismatch')

    def codes(self, email):
        b = self.request('/api/getmails', {'mail': email, 'time': 0, '_': int(time.time() * 1000)}, safe=True)
        if b.get('to') != email or not isinstance(b.get('mail'), list):
            raise Halt('inbox_identity_mismatch')
        if len(b['mail']) > 100:
            raise Halt('inbox_message_limit')
        codes = []
        for mail in b['mail']:
            fid = str(mail.get('id', ''))
            if not fid:
                raise Halt('mail_id_missing')
            body = self.request('/api/raw-html/' + urllib.parse.quote(email, safe='@') + '/' + urllib.parse.quote(fid, safe=''), safe=True, raw=True)
            for link in re.findall(r'https://console\.enterprise\.trae\.cn/invite-email\?[^\s\"\'<>]+', html.unescape(body)):
                parsed = urllib.parse.urlsplit(link)
                values = urllib.parse.parse_qs(parsed.query).get('code', [])
                if parsed.hostname == 'console.enterprise.trae.cn' and parsed.path == '/invite-email' and len(values) == 1:
                    codes.append(values[0])
        return list(dict.fromkeys(codes))
