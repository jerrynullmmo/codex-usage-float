import unittest,json
from decimal import Decimal
from unittest.mock import patch
import urllib.error
from yonshore_account import *

class AccountTests(unittest.TestCase):
    def encoded(self,kind,value):return json.dumps(dict(object='list' if kind=='usage' else 'billing_subscription',**{'total_usage' if kind=='usage' else 'hard_limit_usd':value})).encode()
    def test_exact_money(self):
        calls=[]
        def get(k):calls.append(k);return self.encoded(k,456 if k=='usage' else 16.9)
        self.assertEqual(read_wallet(get),Wallet(Decimal('12.34'),Decimal('4.56')));self.assertEqual(calls,['usage','subscription','usage'])
    def test_concurrent_settlement(self):
        raw=[self.encoded(k,v) for k,v in [('usage',456),('subscription',16.9),('usage',457),('usage',457),('subscription',16.9),('usage',457)]]
        self.assertEqual(read_wallet(lambda _:raw.pop(0)).available,Decimal('12.33'))
    def test_busy_does_not_invent_balance(self):
        raw=[self.encoded(k,v) for k,v in [('usage',1),('subscription',1),('usage',2),('usage',2),('subscription',1),('usage',3)]]
        with self.assertRaises(AccountError) as error:read_wallet(lambda _:raw.pop(0))
        self.assertEqual(error.exception.code,'changing')
    def test_invalid_response(self):
        for raw in [b'{}',b'{"error":{"message":"secret"}}',b'null',b'[]',self.encoded('usage',True),self.encoded('usage','123'),self.encoded('usage',-1),self.encoded('usage',.01),self.encoded('usage',9007199254740992)]:
            with self.assertRaises(AccountError):decode(raw,'usage')
        with self.assertRaises(AccountError):decode(self.encoded('subscription',12.345),'subscription')
    def test_no_secret_in_errors(self):
        class Opener:
            def open(self,req,timeout):raise urllib.error.HTTPError(req.full_url,401,'sk-secret-must-not-leak',{},None)
        with patch('urllib.request.build_opener',return_value=Opener()):
            with self.assertRaises(AccountError) as e:fetch('sk-synthetic-test-key')
        self.assertNotIn('secret',str(e.exception));self.assertEqual(e.exception.code,'authentication')
    def test_stale_is_marked(self):
        state=AccountState();wallet=Wallet(Decimal(1),Decimal(2));state.accept(wallet);state.accept(error=AccountError('unavailable'))
        self.assertEqual(state.wallet,wallet);self.assertIn('上次成功',state.status)
        self.assertIsNone(AccountState().wallet)
    def test_redirect_denied(self):self.assertIsNone(NoRedirect().redirect_request(None,None,302,'',{},'https://other.invalid'))
    def test_key_validation(self):
        for key in ['short','sk-bad\r\nAuthorization','sk-contains a space','sk-'+'x'*600]:
            with self.assertRaises(AccountError):normalize_key(key)
        self.assertEqual(normalize_key(' sk-synthetic-valid-key '),'sk-synthetic-valid-key')
    def test_request_is_read_only_fixed_origin(self):
        requests=[]
        class Response:
            status=200
            headers=type('Headers',(),{'get_content_type':lambda _:'application/json'})()
            def __init__(self,endpoint):self.endpoint=endpoint
            def __enter__(self):return self
            def __exit__(self,*_):pass
            def read(self,limit):return b'{"object":"list","total_usage":100}' if self.endpoint=='usage' else b'{"object":"billing_subscription","hard_limit_usd":2}'
        class Opener:
            def open(self,r,timeout):requests.append(r);return Response(r.full_url.rsplit('/',1)[1])
        with patch('urllib.request.build_opener',return_value=Opener()):self.assertEqual(fetch('sk-synthetic-valid-key').available,1)
        self.assertTrue(all(r.method=='GET' and r.full_url.startswith(ORIGIN+'/v1/dashboard/billing/') and 'sk-' not in r.full_url for r in requests))
