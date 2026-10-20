import asyncio
import json
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock,Mock,patch

from backend.prompts import verification_answer
from backend.server import Backend


def challenge():
    return {'event':'prompt','kind':'twoFactor','promptId':7,'requestId':'synthetic-login',
            'detail':{'numbers':[{'id':3,'lastTwoDigits':'12'},{'id':8,'lastTwoDigits':'98'}]}}


class AnswerTests(unittest.TestCase):
    def test_only_six_ascii_digits_can_be_submitted(self):
        for value in ('','12345','1234567','abcdef','１２３４５６',123456,None):
            with self.assertRaisesRegex(ValueError,'six-digit'):
                verification_answer(challenge(),{'action':'submit','code':value})
        self.assertEqual(verification_answer(challenge(),{'action':'submit','code':'012345','password':'ignored'}),
                         {'action':'submit','code':'012345'})

    def test_sms_must_select_an_id_from_this_challenge(self):
        for identifier in (0,True,'3',3.0,None,100):
            with self.assertRaisesRegex(ValueError,'trusted phone'):
                verification_answer(challenge(),{'action':'sms','numberId':identifier})
        self.assertEqual(verification_answer(challenge(),{'action':'sms','numberId':8}),{'action':'sms','numberId':8})

    def test_missing_or_malformed_numbers_do_not_allow_sms(self):
        for detail in (None,{}, {'numbers':None},{'numbers':[None,{}]},{'numbers':'3'}):
            with self.assertRaisesRegex(ValueError,'trusted phone'):
                verification_answer({'kind':'twoFactor','detail':detail},{'action':'sms','numberId':3})

    def test_supported_delivery_actions_and_unknown_prompt_abort(self):
        for action in ('resend','devices','abort'):
            self.assertEqual(verification_answer(challenge(),{'action':action,'code':'ignored'}),{'action':action})
        self.assertEqual(verification_answer({'kind':'unknown'},{'action':'abort'}),{'action':'abort'})
        for answer in (None,{}, {'action':'unknown'}):
            with self.assertRaises(ValueError):verification_answer(challenge(),answer)


class PromptDispatchTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.events=[]
        self.backend=Backend(self.temporary.name,self.events.append)

    async def asyncTearDown(self):
        await self.backend.close();self.temporary.cleanup()

    async def test_expired_reply_does_not_start_a_new_engine(self):
        self.backend.ensure_native=AsyncMock()
        with self.assertRaisesRegex(ValueError,'has ended'):
            await self.backend.dispatch('prompt.reply',{'promptId':7,'answer':{'action':'abort'}})
        self.backend.ensure_native.assert_not_called()

    async def test_invalid_reply_preserves_the_prompt_and_valid_reply_is_single_use(self):
        self.backend.native_prompts[7]=challenge()
        process=SimpleNamespace(returncode=None,stdin=SimpleNamespace(write=Mock(),drain=AsyncMock()))
        with patch.object(self.backend,'native',process):
            with self.assertRaisesRegex(ValueError,'trusted phone'):
                await self.backend.dispatch('prompt.reply',{'promptId':7,'answer':{'action':'sms','numberId':99}})
            process.stdin.write.assert_not_called();self.assertIn(7,self.backend.native_prompts)
            await self.backend.dispatch('prompt.reply',{'promptId':7,'answer':{'action':'sms','numberId':8,'code':'discarded'}})
            sent=json.loads(process.stdin.write.call_args.args[0])
            self.assertEqual(sent,{'method':'prompt.reply','params':{'promptId':7,'answer':{'action':'sms','numberId':8}}})
            with self.assertRaisesRegex(ValueError,'has ended'):
                await self.backend.dispatch('prompt.reply',{'promptId':7,'answer':{'action':'abort'}})
            self.assertEqual(process.stdin.write.call_count,1)
        self.assertEqual(self.backend.records('jobs'),[])

    async def test_completion_closes_its_prompt_even_if_the_waiter_was_cancelled(self):
        stream=asyncio.StreamReader()
        stream.feed_data((json.dumps(challenge())+'\n'+json.dumps({'id':'synthetic-login','error':{'message':'Expired'}})+'\n').encode())
        stream.feed_eof()
        with patch.object(self.backend,'native',SimpleNamespace(stdout=stream)):
            await self.backend.read_native()
        self.assertEqual(self.backend.native_prompts,{})
        self.assertEqual([event for event in self.events if event['event']=='promptClosed'],[{'event':'promptClosed','promptId':7}])

    async def test_engine_exit_retires_prompt_and_account(self):
        self.backend.account={'email':'synthetic@example.invalid'}
        self.backend.native_prompts[7]=challenge()
        stream=asyncio.StreamReader();stream.feed_eof()
        with patch.object(self.backend,'native',SimpleNamespace(stdout=stream)):
            await self.backend.read_native()
        self.assertIsNone(self.backend.account)
        self.assertEqual(self.backend.native_prompts,{})
        self.assertEqual(self.events,[{'event':'promptClosed','promptId':7}])

    async def test_stale_reader_cannot_clear_replacement_account_or_prompt(self):
        stream=asyncio.StreamReader()
        stream.feed_data((json.dumps({'id':'new-request','result':{'unexpected':True}})+'\n').encode())
        stream.feed_eof()
        old=SimpleNamespace(stdout=stream)
        replacement=SimpleNamespace(stdout=asyncio.StreamReader())
        self.backend.account={'email':'new@example.invalid'}
        self.backend.native_prompts[7]=challenge()
        future=asyncio.get_running_loop().create_future();self.backend.native_pending['new-request']=future
        try:
            with patch.object(self.backend,'native',replacement):await self.backend.read_native(old)
            self.assertEqual(self.backend.account,{'email':'new@example.invalid'})
            self.assertIn(7,self.backend.native_prompts);self.assertFalse(future.done())
            self.assertEqual(self.events,[])
        finally:future.cancel();self.backend.native_pending.clear()
