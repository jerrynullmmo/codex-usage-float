"""Explicitly enabled, read-only YonshoreAPI account query. Never sends model requests."""
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
import json
import time
import urllib.request
import urllib.error
import ctypes
from ctypes import wintypes

ORIGIN='https://api.yonshore.com'
MESSAGES=dict(key='请在设置中连接 YonshoreAPI',credential='无法读取系统凭据，请重新连接',
 authentication='API Key 无效、过期或不可用，请重新连接',forbidden='账户或密钥访问受限，请检查权限/IP 限制',
 limited='查询过于频繁，稍后自动重试',unavailable='暂时无法连接 YonshoreAPI',response='账单响应无效，未更新金额',changing='账户正在结算，稍后重新获取一致余额')
class AccountError(Exception):
    def __init__(self,code):self.code=code;super().__init__(MESSAGES[code])

def normalize_key(raw):
    key=raw.strip()
    if not key.startswith('sk-') or not 16<=len(key)<=512 or not all(32<ord(c)<127 for c in key):raise AccountError('key')
    return key

@dataclass(frozen=True)
class Wallet:
    available: Decimal
    spent: Decimal

def money(value):return '—' if value is None else f'${value:,.2f}'

def decode(raw,kind):
    try:
        if len(raw)>65536:raise ValueError()
        d=json.loads(raw,parse_float=Decimal,parse_int=Decimal)
        field,expected=('total_usage','list') if kind=='usage' else ('hard_limit_usd','billing_subscription')
        n=d[field]
        if d.get('object')!=expected or not isinstance(n,Decimal):raise ValueError()
        if kind!='usage':n*=100
        if not n.is_finite() or n!=n.to_integral_value() or abs(n)>9007199254740991 or (kind=='usage' and n<0):raise ValueError()
        return n
    except (ValueError,TypeError,KeyError,AttributeError,InvalidOperation):raise AccountError('response') from None

def read_wallet(get):
    for _ in range(2):
        before=decode(get('usage'),'usage');budget=decode(get('subscription'),'subscription');after=decode(get('usage'),'usage')
        if before==after:return Wallet((budget-after)/100,after/100)
    raise AccountError('changing')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):return None

def fetch(key):
    key=normalize_key(key)
    opener=urllib.request.build_opener(NoRedirect)
    def get(endpoint):
        request=urllib.request.Request(ORIGIN+'/v1/dashboard/billing/'+endpoint,
            headers={'Authorization':'Bearer '+key,'Accept':'application/json','User-Agent':'AI-Usage-Float'},method='GET')
        try:
            with opener.open(request,timeout=12) as r:
                if r.status!=200 or r.headers.get_content_type()!='application/json':raise AccountError('response')
                raw=r.read(65537)
                if len(raw)>65536:raise AccountError('response')
                return raw
        except urllib.error.HTTPError as e:
            raise AccountError({401:'authentication',403:'forbidden',451:'forbidden',429:'limited'}.get(e.code,'unavailable' if e.code>=500 else 'response')) from None
        except (OSError,urllib.error.URLError):raise AccountError('unavailable') from None
    return read_wallet(get)

class AccountState:
    def __init__(self):self.wallet=None;self.updated=None;self.error=None;self.loading=False
    def accept(self,wallet=None,error=None):
        self.loading=False
        if error:self.error=str(error)
        else:self.wallet=wallet;self.updated=time.time();self.error=None
    @property
    def status(self):
        if self.error:return self.error+(' · 显示上次成功结果' if self.wallet else '')
        if self.loading and self.wallet is None:return '正在查询账户…'
        if self.updated:return f'账户范围 · {max(0,int(time.time()-self.updated))} 秒前更新'
        return '未连接 · 设置中添加 API Key'

class Credential(ctypes.Structure):
    _fields_=[('Flags',wintypes.DWORD),('Type',wintypes.DWORD),('TargetName',wintypes.LPWSTR),('Comment',wintypes.LPWSTR),
      ('LastWritten',wintypes.FILETIME),('CredentialBlobSize',wintypes.DWORD),('CredentialBlob',ctypes.POINTER(ctypes.c_ubyte)),
      ('Persist',wintypes.DWORD),('AttributeCount',wintypes.DWORD),('Attributes',ctypes.c_void_p),('TargetAlias',wintypes.LPWSTR),('UserName',wintypes.LPWSTR)]

class SecretStore:
    def __init__(self,target='AI Usage Float/YonshoreAPI'):
        self.target=target;self.lib=ctypes.WinDLL('advapi32',use_last_error=True)
        self.lib.CredReadW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,ctypes.POINTER(ctypes.POINTER(Credential))];self.lib.CredReadW.restype=wintypes.BOOL
        self.lib.CredWriteW.argtypes=[ctypes.POINTER(Credential),wintypes.DWORD];self.lib.CredWriteW.restype=wintypes.BOOL
        self.lib.CredDeleteW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD];self.lib.CredDeleteW.restype=wintypes.BOOL
        self.lib.CredFree.argtypes=[ctypes.c_void_p]
    def load(self):
        ptr=ctypes.POINTER(Credential)()
        if not self.lib.CredReadW(self.target,1,0,ctypes.byref(ptr)):raise AccountError('key' if ctypes.get_last_error()==1168 else 'credential')
        try:
            if ptr.contents.CredentialBlobSize>512:raise AccountError('credential')
            return normalize_key(ctypes.string_at(ptr.contents.CredentialBlob,ptr.contents.CredentialBlobSize).decode('utf-8'))
        finally:self.lib.CredFree(ptr)
    def save(self,raw):
        data=normalize_key(raw).encode('utf-8');blob=(ctypes.c_ubyte*len(data)).from_buffer_copy(data)
        value=Credential(Type=1,TargetName=self.target,Comment='YonshoreAPI account usage',CredentialBlobSize=len(data),CredentialBlob=blob,Persist=2,UserName='API Key')
        try:
            if not self.lib.CredWriteW(ctypes.byref(value),0):raise AccountError('credential')
        finally:ctypes.memset(blob,0,len(data))
    def remove(self):
        if not self.lib.CredDeleteW(self.target,1,0) and ctypes.get_last_error()!=1168:raise AccountError('credential')
