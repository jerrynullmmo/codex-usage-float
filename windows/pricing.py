"""Offline model-token price estimates, not a provider bill or subscription charge."""
from pathlib import Path
import datetime as dt
import json
import math
import os
import sys

CUSTOM = Path(os.environ.get('APPDATA', str(Path.home()))) / 'AI Usage Float/pricing.json'
BUNDLED = Path(getattr(sys, '_MEIPASS', Path(__file__).parent)) / 'prices.json'

def cost(usd=0., complete=True, reasons=(), models=()):
    return dict(usd=usd, complete=complete, reasons=list(reasons), models=list(models))
def unknown(reason): return cost(complete=False, reasons=[reason])
def plus(a, b):
    value = a['usd'] + b['usd']
    if not math.isfinite(value): return unknown('费用数值溢出')
    return cost(value, a['complete'] and b['complete'], sorted(set(a['reasons'] + b['reasons'])), sorted(set(a['models'] + b['models'])))
def label(value):
    if not value or not value['complete'] and not value['usd']: return '—'
    return ("<$0.0001" if 0<value["usd"]<.0001 else f"${value['usd']:.4f}") + ('' if value['complete'] else ' + ?')
def timestamp(value):
    try:
        d=dt.datetime.fromisoformat(value.replace('Z','+00:00'))
        return d.timestamp() if d.tzinfo else None
    except (ValueError,TypeError,AttributeError,OverflowError): return None

class PriceBook:
    def __init__(self, path=None):
        local=Path(path) if path else CUSTOM
        self.custom=local.exists();self.document=None
        try:
            p=local if self.custom else BUNDLED
            if p.stat().st_size>1024*1024: return
            d=json.loads(p.read_text(encoding='utf-8'))
            if d['schemaVersion']!=1 or d['currency']!='USD' or not isinstance(d['verifiedAt'],str):return
            identities=set()
            for row in d['models']:
                if not row['provider'] or not row['model'] or not row['source'].startswith('https://'):return
                for rates in [row['rates']]+([row['longRates']] if row.get('longRates') is not None else []):
                    if len(rates)!=4 or rates[0] is None or rates[3] is None:return
                    if any(v is not None and (type(v) not in (int,float) or not math.isfinite(v) or v<0) for v in rates):return
                if (row.get('longRates') is None)!=(row.get('threshold') is None):return
                if row.get('threshold') is not None and (type(row['threshold']) is not int or row['threshold']<=0):return
                for model in [row['model']]+row['aliases']:
                    key=(row['provider'],model)
                    if key in identities:return
                    identities.add(key)
            self.document=d
        except (OSError,ValueError,TypeError,KeyError,AttributeError):pass
    @property
    def title(self):return ('自定义价目' if self.custom else '官方价目')+' · '+(self.document or {}).get('verifiedAt','无效')
    def quote(self,tokens,model,provider=None):
        if not self.document:return unknown('价目文件缺失或无效')
        if not model:return unknown('记录未提供模型名称')
        provider='google' if provider=='google-generative-ai' else provider
        known=any(r['provider']==provider for r in self.document['models'])
        matches=[r for r in self.document['models'] if (not known or r['provider']==provider) and model in [r['model']]+r['aliases']]
        if len(matches)!=1:return unknown('价格未知：'+str(model))
        row=matches[0];t=tokens or {};i,o,c=t.get('input'),t.get('output'),t.get('cached')
        if any(type(v) is not int or v<0 or v>2**63-1 for v in (i,o,c)) or c>i:return unknown('缺少或不一致的计费 Token')
        r=row['longRates'] if row.get('threshold') is not None and i>row['threshold'] else row['rates']
        w=t.get('written');w=(0 if r[2]==r[0] else -1) if w is None else w
        if type(w) is not int or w<0 or w>i-c:return unknown('缺少或不一致的缓存写入量')
        parts=[i-c-w,c,w,o];value=0.
        for n,rate in zip(parts,r):
            if n:
                if rate is None:return unknown('该模型未公布此计费项')
                value+=n*rate/1_000_000
        return cost(value,models=[row['provider']+'/'+row['model']]) if math.isfinite(value) else unknown('费用数值溢出')
BOOK=PriceBook()

class CostLedger:
    def __init__(self,book=BOOK):
        self.book=book;self.total=cost();self.round=unknown('尚无本轮记录');self.last=unknown('尚无最近调用')
        self.model=None;self.previous=dict.fromkeys(('input','output','cached','written'),0);self.points=[];self.dropped=None
    def since(self,boundary):
        if boundary is None:return unknown('缺少主任务时间边界')
        if self.dropped is not None and boundary<=self.dropped:return unknown('本轮费用超出保留的历史范围')
        result=cost()
        for stamp,value in self.points:
            if stamp>=boundary:result=plus(result,value)
        return result
    def consume(self,d):
        p=d.get('payload') or {}
        if d.get('type')=='turn_context':self.model=p.get('model');return
        if d.get('type')!='event_msg':return
        if p.get('type')=='task_started':self.round=cost();self.last=unknown('尚无最近调用');self.model=None;return
        info=p.get('info') or {}
        if p.get('type')!='token_count' or not isinstance(info.get('total_token_usage'),dict):return
        def normalize(v):return dict(zip(('input','output','cached','written'),(v.get(k) for k in ('input_tokens','output_tokens','cached_input_tokens','cache_write_input_tokens'))))
        nxt=normalize(info['total_token_usage'])
        if nxt==self.previous:return
        delta={k:nxt[k]-self.previous[k] if type(nxt[k]) is int and type(self.previous[k]) is int and nxt[k]>=self.previous[k] else None for k in nxt}
        recent=normalize(info['last_token_usage']) if isinstance(info.get('last_token_usage'),dict) else None
        self.last=self.book.quote(recent,self.model)
        value=self.last if recent is not None and delta==recent else unknown('调用明细与累计增量不一致')
        self.total=plus(self.total,value);self.round=plus(self.round,value);self.previous=nxt
        stamp=timestamp(d.get('timestamp'))
        if stamp is not None:self.points.append((stamp,value))
        else:self.dropped=float('inf')
        if len(self.points)>8192:
            self.dropped=max(self.dropped or float('-inf'),self.points[-8193][0]);self.points=self.points[-8192:]

class CostLogReader:
    def __init__(self,path):
        self.path=Path(path);self.offset=0;self.identity=None;self.buffer=b'';self.dropping=False;self.ledger=CostLedger();self.ready=False
    def poll(self):
        self.ready=False
        try:
            stat=self.path.stat();identity=(stat.st_dev,stat.st_ino)
            if self.identity!=identity or stat.st_size<self.offset:
                self.offset=0;self.buffer=b'';self.dropping=False;self.ledger=CostLedger();self.identity=identity
            with self.path.open('rb') as f:f.seek(self.offset);data=f.read(8*1024*1024)
            self.offset+=len(data)
            for i,chunk in enumerate(data.split(b'\n')):
                if i:
                    if not self.dropping and (b'"event_msg"' in self.buffer or b'"turn_context"' in self.buffer):
                        try:self.ledger.consume(json.loads(self.buffer))
                        except (ValueError,TypeError,AttributeError):pass
                    self.buffer=b'';self.dropping=False
                if not self.dropping:
                    self.buffer+=chunk
                    if len(self.buffer)>2*1024*1024:self.buffer=b'';self.dropping=True
            self.ready=self.offset==stat.st_size and not self.buffer and not self.dropping
        except OSError:pass
        return self
    def value(self,key):return getattr(self.ledger,key) if self.ready else unknown('正在回溯费用或记录不可读')
    def since(self,boundary):return self.ledger.since(boundary) if self.ready else unknown('正在回溯子代理费用')
