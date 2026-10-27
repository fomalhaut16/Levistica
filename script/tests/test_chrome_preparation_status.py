import copy
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock

spec=importlib.util.spec_from_file_location('chrome_status_test',Path(__file__).parents[1]/'public-chrome-memory.py')
chrome=importlib.util.module_from_spec(spec)
spec.loader.exec_module(chrome)


class ChromePreparationStatusTests(unittest.TestCase):
    def fixture(self, seconds=60):
        clock=[0]
        state={'identities':{1:{'executable':'app','started':'root'},2:{'executable':'renderer','started':'child'}},
               'services':[],'exited_descendant_pids':[]}
        values=Mock(side_effect=AssertionError('Status must never read numeric memory'))
        sampler=chrome.memory.Sampler(1,lambda deadline:copy.deepcopy(state),
            lambda deadline:{'available':True,'powerSource':'ac','memoryPressureLevel':1},values,
            clock=lambda:clock[0],role_for=lambda pid,root,snapshot:'UI' if pid==root else 'Renderer',content_role='Renderer')
        for now in range(0,seconds+1,5):clock[0]=now;sampler.tick()
        return sampler,clock,state,values

    def reply(self,sampler,requests=0,verify=None,stage='capture',packet=None):
        return chrome.preparation_reply(packet or {'phase':'status','runID':'owned'},stage,'owned',sampler,requests,verify or Mock())

    def test_ready_requires_current_verification_and_never_reads_memory(self):
        sampler,clock,state,values=self.fixture()
        verify=Mock()
        result,count=self.reply(sampler,verify=verify)
        self.assertTrue(result['readyForCapture'])
        self.assertTrue(result['attributionVerified'])
        self.assertEqual(result['stableSeconds'],60)
        self.assertEqual(result['memorySamplesTaken'],0)
        self.assertEqual(count,1)
        self.assertEqual(verify.call_count,2)
        values.assert_not_called()

    def test_thirty_seconds_is_not_capture_ready(self):
        sampler,clock,state,values=self.fixture(30)
        result,count=self.reply(sampler)
        self.assertFalse(result['readyForCapture'])
        self.assertEqual(result['stableSeconds'],30)
        self.assertEqual(count,1)
        values.assert_not_called()

    def test_confirmed_exit_resets_status_and_requires_a_whole_new_window(self):
        sampler,clock,state,values=self.fixture()
        original=sampler.read_attribution
        clock[0]=65
        sampler.read_attribution=lambda deadline:(_ for _ in ()).throw(chrome.m.ConfirmedExitedChromeDescendants([2]))
        result,count=self.reply(sampler)
        self.assertFalse(result['readyForCapture'])
        self.assertFalse(result['attributionVerified'])
        self.assertIsNone(sampler.baseline)
        sampler.read_attribution=original
        for now in range(70,126,5):clock[0]=now;sampler.tick()
        self.assertFalse(self.reply(sampler,requests=count)[0]['readyForCapture'])
        clock[0]=130
        self.assertTrue(self.reply(sampler,requests=count+1)[0]['readyForCapture'])
        values.assert_not_called()

    def test_wrong_trial_extra_fields_and_post_capture_stages_abort(self):
        sampler,clock,state,values=self.fixture()
        for stage,packet in [('after',{'phase':'status','runID':'owned'}),('commit',{'phase':'status','runID':'owned'}),
                             ('capture',{'phase':'status','runID':'another'}),('capture',{'phase':'status','runID':'owned','capture':True})]:
            with self.subTest(stage=stage,packet=packet):
                verify=Mock()
                with self.assertRaises(ValueError):self.reply(sampler,verify=verify,stage=stage,packet=packet)
                verify.assert_not_called()
        values.assert_not_called()

    def test_thirteenth_request_cannot_extend_preparation(self):
        sampler,clock,state,values=self.fixture()
        count=0
        for _ in range(12):_,count=self.reply(sampler,requests=count)
        with self.assertRaisesRegex(ValueError,'request limit'):self.reply(sampler,requests=count)
        values.assert_not_called()

    def test_owner_and_attribution_failures_remain_fatal(self):
        for after_snapshot in [False,True]:
            sampler,clock,state,values=self.fixture()
            verify=Mock(side_effect=[None,ValueError('owner changed')] if after_snapshot else ValueError('owner changed'))
            with self.assertRaises(ValueError):self.reply(sampler,verify=verify)
            values.assert_not_called()
        sampler,clock,state,values=self.fixture()
        sampler.read_attribution=lambda deadline:(_ for _ in ()).throw(ValueError('unverified domain'))
        with self.assertRaises(ValueError):self.reply(sampler)
        values.assert_not_called()

    def test_stale_or_already_sampled_state_is_not_ready(self):
        sampler,clock,state,values=self.fixture()
        def delayed():clock[0]+=6
        calls=[0]
        def verify_delayed():
            calls[0]+=1
            if calls[0]==2:delayed()
        self.assertFalse(self.reply(sampler,verify=verify_delayed)[0]['readyForCapture'])
        sampler,clock,state,values=self.fixture()
        sampler.attempts=1
        sampler.sample={'valid':False}
        self.assertFalse(self.reply(sampler)[0]['readyForCapture'])
        values.assert_not_called()
