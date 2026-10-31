import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import Mock, patch

import requests

from onboarding.core import (BASE, Business, Halt, HTTP, Network, Store, TMP, Unknown,
                             capacity, find_member, identity)
from onboarding.service import Service


def quota(total=4, occupied=2, active=None):
    return {'AccountQuotaSummary': {'Full': {'TotalQuota': total, 'OccupiedCount': occupied,
                                            'ActiveCount': occupied if active is None else active}}}


def row(email='a@example.test', uid='1', joined=0, status=2):
    return {'UserInfo': {'Email': email, 'UserID': uid, 'JoiningTime': joined, 'UserStatus': status,
                         'RoleID': 3, 'AccountType': 1}}


class CapacityTests(unittest.TestCase):
    def test_pending_and_local_reservations_not_double_counted(self):
        tasks = [{'phase': 'INVITED', 'email': 'a@example.test'}, {'phase': 'PREPARED', 'email': 'b@example.test'}]
        value = capacity(quota(), [row()], tasks)
        self.assertEqual((value['pending'], value['available']), (2, 0))

    def test_active_accounts_not_pending(self):
        value = capacity(quota(), [row(joined=123, status=1)], [{'phase': 'ACTIVE', 'email': 'a@example.test'}])
        self.assertEqual(value['available'], 2)

    def test_lagging_quota_uses_confirmed_members(self):
        rows = [row(email=f'{i}@example.test', uid=str(i), joined=123, status=1) for i in range(4)]
        self.assertEqual(capacity(quota(occupied=2), rows, [])['available'], 0)

    def test_work_seats_do_not_fill_full(self):
        r = row()
        r['UserInfo']['AccountType'] = 2
        self.assertEqual(capacity(quota(), [r], [])['available'], 2)

    def test_unknown_quota_stops(self):
        with self.assertRaises(Halt):
            capacity({'AccountQuotaSummary': {}}, [], [])

    def test_boolean_quota_rejected(self):
        with self.assertRaises(Halt):
            capacity(quota(total=True, occupied=0), [], [])

    def test_activation_must_be_known(self):
        r = row()
        del r['UserInfo']['JoiningTime']
        with self.assertRaises(Halt):
            capacity(quota(), [r], [])

    def test_duplicate_email_stops(self):
        with self.assertRaises(Halt):
            find_member([row(), row(uid='2')], 'a@example.test')

    def test_wrong_tenant_stops(self):
        info = {'Data': {'UserInfo': {'Email': 'a', 'TenantID': '1', 'UserID': '2'}}}
        with self.assertRaises(Halt):
            identity(info, 'a', tenant='3')


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.api = HTTP(BASE)
        self.api.session = Mock()
        self.api.probe = Mock(return_value=True)

    def response(self, body, status=200):
        response = Mock(status_code=status)
        response.json.return_value = body
        return response

    def test_http_200_business_failure(self):
        self.api.session.request.return_value = self.response({'code': 30011})
        with self.assertRaises(Business):
            self.api.request('/read', {}, safe=True)
        self.assertEqual(self.api.session.request.call_count, 1)

    def test_safe_network_retry_probes_first(self):
        self.api.session.request.side_effect = [requests.Timeout(), self.response({'code': 0})]
        self.assertEqual(self.api.request('/read', {}, safe=True)['code'], 0)
        self.api.probe.assert_called_once()
        self.assertEqual(self.api.session.request.call_count, 2)

    def test_mutation_timeout_never_retried(self):
        self.api.session.request.side_effect = requests.Timeout()
        with self.assertRaises(Unknown):
            self.api.request('/create', {})
        self.assertEqual(self.api.session.request.call_count, 1)
        self.api.probe.assert_not_called()

    def test_retry_budget_bounded(self):
        self.api.session.request.side_effect = requests.Timeout()
        with self.assertRaises(Network):
            self.api.request('/read', {}, safe=True)
        self.assertEqual(self.api.session.request.call_count, 2)

    def test_bad_json_mutation_is_uncertain(self):
        response = self.response({})
        response.json.side_effect = ValueError()
        self.api.session.request.return_value = response
        with self.assertRaises(Unknown):
            self.api.request('/register', {})


@unittest.skipUnless(shutil.which('gpg'), 'GPG unavailable')
class StoreTests(unittest.TestCase):
    def setUp(self):
        TMP.mkdir(exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='test-storage-', dir=TMP))

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_encrypted_roundtrip(self):
        store = Store(self.root / 'state')
        with store.locked():
            state = store.load()
            state['members'] = [{'password': 'offline-secret'}]
            store.save(state)
            self.assertNotIn(b'offline-secret', store.path.read_bytes())
            self.assertEqual(store.load()['members'][0]['password'], 'offline-secret')

    def test_missing_key_never_silently_recreated(self):
        store = Store(self.root / 'state')
        with store.locked():
            store.save(store.load())
        store.key.unlink()
        with self.assertRaises(Halt):
            with store.locked():
                pass

    def test_path_outside_tmp_rejected(self):
        with self.assertRaises(Halt):
            Store(Path.home() / 'production-config')


class ServiceTests(unittest.TestCase):
    def service(self, tasks=None):
        store = Mock()
        store.load.return_value = {'version': 1, 'tenant_id': '1', 'status': 'READY', 'members': tasks or []}
        service = Service(store, Mock(), Mock(), sleeper=Mock())
        service.magpie.publish_models.return_value = {'provider': 'trae-cn', 'model_count': 2}
        return service

    def test_unknown_invitation_not_resent(self):
        task = {'email': 'a@example.test', 'phase': 'INVITE_SUBMITTING'}
        service = self.service([task])
        with self.assertRaises(Halt):
            service.reconcile(task, [])
        service.admin.request.assert_not_called()

    def test_restart_finds_invited_member(self):
        task = {'id': 'a', 'email': 'a@example.test', 'phase': 'INVITE_SUBMITTING'}
        service = self.service([task])
        service.reconcile(task, [row()])
        self.assertEqual(task['phase'], 'INVITED')
        self.assertEqual(task['uid'], '1')
        service.admin.request.assert_not_called()

    def test_host_save_reconciled_before_new_login(self):
        task = {'id': 'a', 'email': 'a@example.test', 'phase': 'TOKEN_READY', 'credentials': {'Token': 't'}}
        service = self.service([task])
        service.reconcile = Mock()
        service.magpie.reconcile.return_value = {'account_key': 'trae-cn#test'}
        service.advance(task, [], [])
        self.assertEqual(task['phase'], 'COMPLETE')
        service.magpie.login.assert_not_called()

    def test_full_stops_without_create(self):
        service = self.service()
        service.snapshot = Mock(return_value=('root', [], [], {'total': 4, 'occupied': 4, 'active': 4, 'available': 0, 'pending': 0}))
        service.new_task = Mock()
        service.run()
        self.assertEqual(service.state['status'], 'FULL')
        self.assertEqual(service.state['model_publication']['status'], 'COMPLETE')
        service.magpie.publish_models.assert_called_once_with()
        service.new_task.assert_not_called()

    def test_inactive_full_not_reported_as_success(self):
        service = self.service()
        service.snapshot = Mock(return_value=('root', [], [], {'total': 4, 'occupied': 4, 'active': 3, 'available': 0, 'pending': 0}))
        with self.assertRaises(Halt):
            service.run()

    def test_watch_detects_future_capacity_without_spinning(self):
        service = self.service()
        service.watch = True
        service.snapshot = Mock(return_value=('root', [], [], {'total': 4, 'occupied': 4, 'active': 4, 'available': 0, 'pending': 0}))
        service.sleep.side_effect = KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            service.run()
        service.sleep.assert_called_once_with(15)

    def test_existing_task_runs_before_new_capacity(self):
        task = {'phase': 'ACTIVE'}
        service = self.service([task])
        service.snapshot = Mock(return_value=('root', [], [], {'total': 4, 'occupied': 2, 'active': 2, 'available': 2, 'pending': 0}))
        service.advance = Mock(side_effect=KeyboardInterrupt())
        service.new_task = Mock()
        with self.assertRaises(KeyboardInterrupt):
            service.run()
        service.advance.assert_called_once_with(task, [], [])
        service.new_task.assert_not_called()


if __name__ == '__main__':
    unittest.main()
