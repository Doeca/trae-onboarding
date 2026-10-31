import copy
import unittest
from unittest.mock import Mock, patch

from onboarding.service import Service
from onboarding.core import BASE


class StoreFake:
    def __init__(self):
        self.state = {'version': 1, 'tenant_id': None, 'members': [], 'status': 'READY'}
        self.writes = []

    def load(self):
        return copy.deepcopy(self.state)

    def save(self, state):
        self.state = copy.deepcopy(state)
        self.writes.append(copy.deepcopy(state))


class World:
    def __init__(self):
        self.rows = []
        self.invites = self.registers = self.magpie_logins = 0

    def client(self, email, password):
        return ClientFake(self, email, password)


class ClientFake:
    def __init__(self, world, email, password):
        self.world, self.email, self.password = world, email, password
        self.session = Mock(headers={})
        self.authenticated = True

    def info(self):
        if self.email == 'admin@example.test':
            user = {'Email': self.email, 'TenantID': 'tenant', 'UserID': 'admin', 'RoleID': 1}
        else:
            user = next(r['UserInfo'] for r in self.world.rows if r['UserInfo']['Email'] == self.email)
        active = sum(bool(r['UserInfo']['JoiningTime']) for r in self.world.rows)
        return {'Data': {'UserInfo': dict(user), 'IsAllowLogin': True},
                'HostInfo': {'Api': BASE, 'Console': BASE, 'Core': BASE},
                'AccountQuotaSummary': {'Full': {'TotalQuota': 2, 'OccupiedCount': active, 'ActiveCount': active}}}

    def departments(self):
        return 'root', ['root']

    def members(self, _departments):
        return copy.deepcopy(self.world.rows)

    def request(self, path, body, **kwargs):
        if path.endswith('/member/create'):
            self.world.invites += 1
            member = body['Members'][0]
            assert member['AccountType'] == 1
            self.world.rows.append({'UserInfo': {**member, 'UserID': str(self.world.invites),
                                                 'TenantID': 'tenant', 'JoiningTime': 0,
                                                 'UserStatus': 2, 'Scope': 'saas'}})
            return {'SuccessCount': 1, 'Failures': []}
        if path.endswith('/get_code_info'):
            return {'Data': {'Email': self.email, 'TenantID': 'tenant', 'AccountType': 1}}
        if path.endswith('/register'):
            self.world.registers += 1
            row = next(r['UserInfo'] for r in self.world.rows if r['UserInfo']['Email'] == self.email)
            row.update(JoiningTime=123, UserStatus=1)
            return {'Data': True, 'AccountType': 1}
        if path.endswith('/GetRefreshToken'):
            return {'Data': {'RefreshToken': 'initial-' + self.email, 'RefreshExpireAt': 9999999999999}}
        if path.endswith('/ExchangeToken'):
            return {'Data': {'Token': 'access-' + self.email, 'RefreshToken': 'rotated-' + self.email,
                             'TokenExpireAt': 9999999999999, 'RefreshExpireAt': 9999999999999}}
        raise AssertionError('Unexpected fake endpoint')


class NativeFake:
    def __init__(self, world):
        self.world = world

    def reconcile(self, credentials):
        return None

    def publish_models(self):
        assert self.world.magpie_logins == 2
        assert self.world.registers == 2
        return {'provider': 'trae-cn', 'model_count': 6}

    def login(self, issue):
        self.world.magpie_logins += 1
        payload = issue({'device_id': ['123'], 'x_device_id': ['123']})
        assert payload['credentials']['RefreshToken'].startswith('rotated-')
        assert 'UserInfo' in payload['identity']['Data']
        return {'account_key': 'trae-cn#' + str(self.world.magpie_logins), 'guarded': True}


class FlowTests(unittest.TestCase):
    def test_two_seats_complete_serially(self):
        world, store = World(), StoreFake()
        with patch('onboarding.service.Enterprise', world.client), patch('onboarding.service.emit'):
            service = Service(store, world.client('admin@example.test', 'fake'), NativeFake(world), sleeper=Mock())
            service.mail = Mock()
            service.mail.codes.return_value = ['offline-invite']
            service.run()
        self.assertEqual((world.invites, world.registers, world.magpie_logins), (2, 2, 2))
        self.assertEqual(store.state['status'], 'FULL')
        self.assertTrue(all(t['phase'] == 'COMPLETE' for t in store.state['members']))
        self.assertEqual(len(store.state['members']), 2)
        self.assertTrue(any(s['members'] and s['members'][0]['phase'] == 'REGISTER_SUBMITTING' for s in store.writes))
        self.assertTrue(any(s['members'] and s['members'][0]['phase'] == 'TOKEN_READY' for s in store.writes))

    def test_publication_failure_resumes_without_new_accounts(self):
        world, store = World(), StoreFake()
        native = NativeFake(world)
        with patch('onboarding.service.Enterprise', world.client), patch('onboarding.service.emit'):
            service = Service(store, world.client('admin@example.test', 'fake'), native, sleeper=Mock())
            service.mail = Mock()
            service.mail.codes.return_value = ['offline-invite']
            with patch.object(native, 'publish_models', side_effect=RuntimeError('offline failure')):
                with self.assertRaises(RuntimeError):
                    service.run()
            self.assertEqual(store.state['model_publication']['status'], 'FAILED')
            self.assertNotEqual(store.state['status'], 'FULL')
            self.assertTrue(all(t['phase'] == 'COMPLETE' for t in store.state['members']))
            resumed = Service(store, service.admin, native, sleeper=Mock())
            resumed.run()
            resumed.run()
        self.assertEqual((world.invites, world.registers, world.magpie_logins), (2, 2, 2))
        self.assertEqual(store.state['model_publication']['status'], 'COMPLETE')
        self.assertEqual(store.state['status'], 'FULL')

    def test_gateway_runs_last_and_failure_does_not_repeat_accounts(self):
        world, store = World(), StoreFake()
        gateway = Mock()
        def fail(state, save):
            self.assertEqual(world.magpie_logins, 2)
            self.assertEqual(state['model_publication']['status'], 'COMPLETE')
            self.assertTrue(all(t['phase'] == 'COMPLETE' for t in state['members']))
            raise RuntimeError('gateway failure')
        gateway.finish.side_effect = fail
        with patch('onboarding.service.Enterprise', world.client), patch('onboarding.service.emit'):
            service = Service(store, world.client('admin@example.test', 'fake'), NativeFake(world),
                              sleeper=Mock(), gateway=gateway)
            service.mail = Mock()
            service.mail.codes.return_value = ['offline-invite']
            with self.assertRaises(RuntimeError):
                service.run()
            self.assertEqual(store.state['status'], 'CONFIGURING_GATEWAY')
            gateway.finish.side_effect = None
            resumed = Service(store, service.admin, NativeFake(world), sleeper=Mock(), gateway=gateway)
            resumed.run()
        self.assertEqual((world.invites, world.registers, world.magpie_logins), (2, 2, 2))
        self.assertEqual(gateway.finish.call_count, 2)
        self.assertEqual(store.state['status'], 'FULL')

    def test_magpie_failure_preserves_activation_and_stops_new_members(self):
        world, store = World(), StoreFake()
        native = Mock()
        native.reconcile.return_value = None
        native.login.side_effect = RuntimeError('fake native error')
        with patch('onboarding.service.Enterprise', world.client), patch('onboarding.service.emit'):
            service = Service(store, world.client('admin@example.test', 'fake'), native, sleeper=Mock())
            service.mail = Mock()
            service.mail.codes.return_value = ['offline-invite']
            with self.assertRaises(RuntimeError):
                service.run()
        self.assertEqual((world.invites, world.registers), (1, 1))
        self.assertTrue(world.rows[0]['UserInfo']['JoiningTime'])
        self.assertEqual(store.state['members'][0]['phase'], 'MAGPIE_STARTED')


if __name__ == '__main__':
    unittest.main()
