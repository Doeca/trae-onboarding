import secrets
import string
import time

from .core import (BASE, Business, Enterprise, Halt, Mailbox, Network, Unknown,
                   capacity, emit, find_member, identity)


class Service:
    def __init__(self, store, admin, magpie, poll_seconds=15, mail_timeout=180, watch=False,
                 network_retries=3, sleeper=time.sleep, clock=time.time, gateway=None):
        self.store, self.admin, self.magpie = store, admin, magpie
        self.poll_seconds, self.mail_timeout = poll_seconds, mail_timeout
        self.watch, self.network_retries = watch, network_retries
        self.sleep, self.clock = sleeper, clock
        self.state = store.load()
        self.gateway = gateway
        self.mail = Mailbox()

    def save(self):
        self.store.save(self.state)

    def mark(self, task, phase, **fields):
        task.update(fields)
        task['phase'] = phase
        self.save()
        emit('member_progress', task_id=task['id'], phase=phase)

    def snapshot(self):
        info = self.admin.info()
        user = identity(info, self.admin.email, self.state.get('tenant_id'))
        if user.get('RoleID') not in (1, 2):
            raise Halt('administrator_role_not_confirmed')
        if self.state['tenant_id'] is None:
            self.state['tenant_id'] = str(user['TenantID'])
            self.save()
        root, departments = self.admin.departments()
        rows = self.admin.members(departments)
        return root, departments, rows, capacity(info, rows, self.state['members'])

    def new_task(self, root):
        suffix = secrets.token_hex(8)
        task = {'id': suffix, 'email': 'apitest' + suffix + '@nimail.cn',
                'password': 'Aa9!' + ''.join(secrets.choice(string.ascii_letters + string.digits + '!@#$%_-') for _ in range(24)),
                'department_id': root, 'phase': 'PREPARED', 'created_at': self.clock()}
        self.state['members'].append(task)
        self.save()
        return task

    def verify_invited(self, task, row):
        if row.get('RoleID') != 3 or row.get('AccountType') != 1:
            raise Halt('invited_member_type_mismatch')
        if task.get('uid') and str(row['UserID']) != task['uid']:
            raise Halt('invited_user_id_changed')
        task['uid'] = str(row['UserID'])

    def reconcile(self, task, rows):
        row = find_member(rows, task['email'])
        if row:
            self.verify_invited(task, row)
            if row.get('UserStatus') == 1 and row.get('JoiningTime'):
                client = Enterprise(task['email'], task['password'])
                identity(client.info(), task['email'], self.state['tenant_id'], task['uid'], active=True)
                if task['phase'] not in ('ACTIVE', 'MAGPIE_STARTED', 'TOKEN_ISSUING', 'REFRESH_ISSUED',
                                          'TOKEN_EXCHANGING', 'TOKEN_READY', 'COMPLETE'):
                    self.mark(task, 'ACTIVE')
            elif task['phase'] in ('INVITE_SUBMITTING', 'MAILBOX_READY', 'PREPARED'):
                self.mark(task, 'INVITED', invite_at=self.clock())
            return row
        if task['phase'] not in ('PREPARED', 'MAILBOX_READY'):
            raise Halt('upstream_member_absent_reconcile_manually')
        return None

    def advance(self, task, departments, rows):
        self.reconcile(task, rows)
        phase = task['phase']
        if phase == 'COMPLETE':
            return
        if phase == 'PREPARED':
            self.mail.apply(task['email'])
            self.mark(task, 'MAILBOX_READY')
        if task['phase'] == 'MAILBOX_READY':
            # Capacity may have changed since the task was reserved. Do not exceed upstream quota.
            _, current_departments, current_rows, seats = self.snapshot()
            if task['department_id'] not in current_departments:
                raise Halt('selected_department_disappeared')
            if find_member(current_rows, task['email']):
                self.reconcile(task, current_rows)
            else:
                if seats['reserved_occupied'] + seats['pending'] > seats['total']:
                    raise Halt('full_capacity_changed')
                self.mark(task, 'INVITE_SUBMITTING')
                try:
                    b = self.admin.request('/trae/gtm/tob/api/v1/account/member/create',
                                           {'Members': [{'Email': task['email'], 'Name': 'API Test ' + task['id'][:8],
                                                         'RoleID': 3, 'AccountType': 1,
                                                         'DepartmentIDs': [task['department_id']]}], 'SendInvite': True})
                except (Unknown, Business):
                    # A restart never blindly resends this invite.
                    fresh = self.admin.members(current_departments)
                    self.reconcile(task, fresh)
                    if task['phase'] == 'INVITE_SUBMITTING':
                        raise Halt('invitation_requires_reconciliation')
                else:
                    fresh = self.admin.members(current_departments)
                    self.reconcile(task, fresh)
                    if b.get('SuccessCount') != 1 or b.get('Failures') != [] or task['phase'] == 'INVITE_SUBMITTING':
                        raise Halt('invitation_requires_reconciliation')
        if task['phase'] == 'INVITED':
            # Bounded episode: do not generate replacement members when the inbox fails.
            started = task.setdefault('mail_wait_started', self.clock())
            self.save()
            reader = Enterprise(task['email'], task['password'])
            while self.clock() - started < self.mail_timeout:
                if self.clock() - task.get('mail_renewed_at', 0) > 240:
                    self.mail.apply(task['email'])
                    task['mail_renewed_at'] = self.clock()
                    self.save()
                for code in self.mail.codes(task['email']):
                    b = reader.request('/trae/gtm/tob/api/v1/account/get_code_info',
                                       {'CodeType': 1, 'LinkCode': code}, safe=True)
                    data = b.get('Data', {})
                    if data.get('Email', '').lower() != task['email'] or str(data.get('TenantID')) != self.state['tenant_id'] or data.get('AccountType') != 1:
                        raise Halt('invitation_identity_mismatch')
                    self.mark(task, 'INVITE_VERIFIED', invite_code=code)
                    break
                if task['phase'] == 'INVITE_VERIFIED':
                    break
                self.sleep(min(self.poll_seconds, max(0, self.mail_timeout - (self.clock() - started))))
            if task['phase'] == 'INVITED':
                raise Halt('invitation_mail_timeout')
        if task['phase'] == 'INVITE_VERIFIED':
            member = Enterprise(task['email'], task['password'])
            self.mark(task, 'REGISTER_SUBMITTING')
            b = member.request('/trae/gtm/tob/api/v1/account/register',
                               {'Email': task['email'], 'Password': task['password'], 'Name': '',
                                'SendEmailType': 1, 'Code': task['invite_code']})
            if b.get('Data') is not True or b.get('AccountType') != 1:
                raise Halt('registration_not_confirmed')
            member.authenticated = True
            identity(member.info(), task['email'], self.state['tenant_id'], task['uid'], active=True)
            self.mark(task, 'ACTIVE')
        if task['phase'] == 'REGISTER_SUBMITTING':
            raise Halt('registration_outcome_unknown_do_not_repeat')
        if task['phase'] in ('INVITE_SUBMITTING', 'MAILBOX_READY', 'PREPARED'):
            raise Halt('invitation_not_confirmed')
        if task['phase'] not in ('ACTIVE', 'MAGPIE_STARTED', 'TOKEN_ISSUING', 'REFRESH_ISSUED',
                                  'TOKEN_EXCHANGING', 'TOKEN_READY'):
            raise Halt('unexpected_member_phase')
        # Reconcile a previous host save before issuing another login.
        if task.get('credentials'):
            saved = self.magpie.reconcile(task['credentials'])
            if saved:
                self.mark(task, 'COMPLETE', magpie=saved)
                return
        self.mark(task, 'MAGPIE_STARTED')

        def issue(query):
            did = query.get('device_id', [None])[0]
            if not did or query.get('x_device_id', [None])[0] != did:
                raise Halt('native_device_context_invalid')
            from urllib.parse import urlencode
            member = Enterprise(task['email'], task['password'])
            member.session.headers['Referer'] = BASE + '/authorization?' + urlencode(query, doseq=True)
            info = member.info()
            identity(info, task['email'], self.state['tenant_id'], task['uid'], active=True)
            self.mark(task, 'TOKEN_ISSUING')
            initial = member.request('/cloudide/api/v3/trae/oauth/GetRefreshToken',
                                     {'DID': did, 'SourceType': 5}).get('Data', {})
            if not initial.get('RefreshToken'):
                raise Halt('refresh_issuance_failed')
            self.mark(task, 'REFRESH_ISSUED', initial_refresh=initial)
            self.mark(task, 'TOKEN_EXCHANGING')
            pair = member.request('/cloudide/api/v3/trae/oauth/ExchangeToken',
                                  {'RefreshToken': initial['RefreshToken']}).get('Data', {})
            if not pair.get('Token') or not pair.get('RefreshToken'):
                raise Halt('token_pair_missing')
            if any(type(pair.get(k)) not in (int, float) or pair[k] <= self.clock() * 1000
                   for k in ('TokenExpireAt', 'RefreshExpireAt')):
                raise Halt('token_expiry_invalid')
            self.mark(task, 'TOKEN_READY', credentials=pair, credential_version=task.get('credential_version', 0) + 1)
            return {'initial_refresh': initial, 'credentials': pair, 'identity': info}

        saved = self.magpie.login(issue)
        self.mark(task, 'COMPLETE', magpie=saved)

    def run(self):
        transient = 0
        while True:
            try:
                self.state['status'] = 'RUNNING'
                root, departments, rows, seats = self.snapshot()
                emit('capacity', **seats)
                task = next((t for t in self.state['members'] if t['phase'] != 'COMPLETE'), None)
                if task is None and seats['available'] > 0:
                    task = self.new_task(root)
                if task:
                    self.advance(task, departments, rows)
                    transient = 0
                    self.sleep(self.poll_seconds)
                    continue
                if seats['active'] < seats['total']:
                    # Existing invitations/inactive accounts may belong to someone else's mailbox.
                    raise Halt('remaining_full_seats_reserved_or_inactive_requires_manual_action')
                self.state['status'] = 'PUBLISHING_MODELS'
                self.state['model_publication'] = {'status': 'PENDING'}
                self.save()
                try:
                    publication = self.magpie.publish_models()
                except Exception:
                    self.state['model_publication'] = {'status': 'FAILED'}
                    self.save()
                    raise
                self.state['model_publication'] = {'status': 'COMPLETE', **publication}
                if self.gateway is not None:
                    self.state['status'] = 'CONFIGURING_GATEWAY'
                    self.save()
                    self.gateway.finish(self.state, self.save)
                self.state['status'] = 'FULL'
                self.state.pop('reason', None)
                self.save()
                emit('trae_cn_models_enabled', **publication)
                emit('all_full_seats_occupied', total=seats['total'], completed_tasks=sum(t['phase'] == 'COMPLETE' for t in self.state['members']))
                if not self.watch:
                    return
                transient = 0
                self.sleep(self.poll_seconds)
            except Network:
                transient += 1
                if transient > self.network_retries or not self.admin.probe():
                    raise Halt('network_retry_budget_exhausted') from None
                emit('network_retry', attempt=transient)
                self.sleep(self.poll_seconds)
