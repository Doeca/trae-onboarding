import copy
import unittest
from unittest.mock import Mock, patch
from pathlib import Path

from onboarding.models import LocalModelAPI

from onboarding.magpie import NativeMagpieError
from onboarding.models import publish, save_body


class API:
    def __init__(self):
        self.document = {'providers': [
            {'id': 'trae-cn', 'chosen': ['m0'], 'noModels': True, 'unlisted': True,
             'models': [{'id': 'm' + str(i), 'on': False} for i in range(30)] +
                       [{'id': 'unsupported', 'noAPI': True, 'on': False}],
             'proxy': 'direct', 'accountProxies': {'member': 'direct'},
             'contexts': {'m0': 12345}, 'priceRate': 1.3, 'maxConcurrency': 2,
             'routing': 'rotate', 'nativeCompaction': True, 'carriesCompaction': True},
            {'id': 'other', 'chosen': ['only'], 'noModels': False, 'unlisted': True,
             'models': [{'id': 'only', 'on': True}, {'id': 'hidden', 'on': False}]}]}
        self.settings = {'visible': {'agent': ['other']}, 'onlyPicked': {'agent': True}}
        self.saves = []
        self.ignore = False
        self.fail_after_save = False

    def __call__(self, path, body=None):
        if path == 'providers':
            return copy.deepcopy(self.document)
        if path == 'state':
            return {'settings': copy.deepcopy(self.settings)}
        assert path == 'provider/save'
        self.saves.append(copy.deepcopy(body))
        if not self.ignore:
            p = self.document['providers'][0]
            p.update({k: v for k, v in body.items() if k != 'models'})
            p['chosen'] = body['models']
            for model in p['models']:
                model['on'] = model['id'] in body['models'] and not model.get('noAPI')
        if self.fail_after_save:
            raise NativeMagpieError('model_api_request_failed')
        return copy.deepcopy(self.document)


class PublicationTests(unittest.TestCase):
    def test_selects_all_over_automatic_limit_preserves_other_settings(self):
        api = API()
        other, settings = copy.deepcopy(api.document['providers'][1]), copy.deepcopy(api.settings)
        result = publish(api)
        self.assertEqual(result['model_count'], 30)
        self.assertEqual(api.saves[0]['proxy'], 'direct')
        self.assertEqual(api.saves[0]['contexts'], {'m0': 12345})
        self.assertEqual(api.saves[0]['maxConcurrency'], 2)
        self.assertTrue(api.saves[0]['nativeCompaction'])
        self.assertNotIn('routing', api.saves[0])
        self.assertNotIn('modelPrefs', api.saves[0])
        self.assertNotIn('unsupported', api.saves[0]['models'])
        self.assertEqual(api.document['providers'][1], other)
        self.assertEqual(api.settings, settings)
        self.assertFalse(publish(api)['changed'])
        self.assertEqual(len(api.saves), 1)

    def test_unknown_save_reconciles_before_retry(self):
        api = API()
        api.fail_after_save = True
        with self.assertRaises(NativeMagpieError):
            publish(api)
        api.fail_after_save = False
        self.assertFalse(publish(api)['changed'])
        self.assertEqual(len(api.saves), 1)

    def test_success_response_without_readback_fails(self):
        api = API()
        api.ignore = True
        with self.assertRaisesRegex(NativeMagpieError, 'model_publication_not_confirmed'):
            publish(api)

    def test_empty_catalog_does_not_mean_success(self):
        api = API()
        api.document['providers'][0]['models'] = []
        with self.assertRaisesRegex(NativeMagpieError, 'model_catalog_empty'):
            publish(api)
        self.assertEqual(api.saves, [])

    def test_management_child_uses_target_environment_and_is_closed(self):
        adapter = Mock(root=Path('/offline/work'), timeout=2)
        adapter._prepare.return_value = {'HOME': '/offline/home', 'XDG_CONFIG_HOME': '/offline/config',
                                        'MAGPIE_NO_ACCOUNTS': '1', 'LARK_CHANNEL': '1'}
        process = Mock(pid=123)
        process.poll.return_value = None
        with patch('onboarding.models.shutil.which', return_value='/offline/magpie'), \
                patch('onboarding.models.subprocess.Popen', return_value=process) as start, \
                patch('onboarding.models.urllib.request.build_opener') as opener, \
                patch('onboarding.models.os.killpg') as kill:
            with LocalModelAPI(adapter):
                env = start.call_args.kwargs['env']
                self.assertNotIn('MAGPIE_NO_ACCOUNTS', env)
                self.assertEqual(env['XDG_CONFIG_HOME'], '/offline/config')
                self.assertEqual(env['LARK_CHANNEL'], '1')
                self.assertIn('--no-open', start.call_args.args[0])
                self.assertIn('/?k=', opener.return_value.open.call_args.args[0])
            kill.assert_called_once()
            process.wait.assert_called_once()

    def test_existing_picks_are_not_discarded(self):
        api = API()
        p = api.document['providers'][0]
        p['chosen'] += ['unsupported', 'older']
        body = save_body(p)
        self.assertIn('unsupported', body['models'])
        self.assertIn('older', body['models'])

    def test_changed_unrelated_settings_fail_verification(self):
        api = API()
        def mutate(path, body=None):
            result = api(path, body)
            if path == 'provider/save':
                api.settings['visible'] = {}
            return result
        with self.assertRaisesRegex(NativeMagpieError, 'model_unrelated_settings_changed'):
            publish(mutate)


if __name__ == '__main__':
    unittest.main()
