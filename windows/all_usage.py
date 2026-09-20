"""All local sessions, including archived tasks and children, counted once per source/id."""
import json
import hashlib
import time
from pathlib import Path
import pricing
from usage_core import Catalog, FIELDS, MAX_INT, blank, now_iso, codex_log


def summary(entries=(), cache=None, issues=(), updated=None):
    cache=cache or {}; total=dict.fromkeys(FIELDS); missing=dict.fromkeys(FIELDS,0)
    result=dict(total=total,missing=missing,cost=pricing.cost(),count=0,loaded=0,issues=list(issues),updatedAt=updated)
    seen=set()
    for e in entries:
        key=e['source']+':'+e['id']
        if key in seen:continue
        seen.add(key);result['count']+=1;row=cache.get(key)
        if row is not None:result['loaded']+=1
        result['cost']=pricing.plus(result['cost'],row['cost'] if row else pricing.unknown('历史尚未全部读取'))
        for k in FIELDS:
            n=(row.get('tokens') or {}).get(k) if row else None
            if n is not None and 0 <= (total[k] or 0)+n <= MAX_INT:total[k]=(total[k] or 0)+n
            else:missing[k]+=1
    if issues:
        result['cost']=pricing.plus(result['cost'],pricing.unknown('部分数据源无法读取'))
        for k in FIELDS:missing[k]+=1
    if not result['count']:result['cost']=pricing.unknown('未找到已接入的本地记录')
    return result


def value(s,key):
    n=s['total'].get(key)
    return '—' if n is None else f'{n:,}'+(' + ?' if s['missing'].get(key,0) else '')


def token_label(s):
    i,o=s['total']['input'],s['total']['output']
    if i is None or o is None or i+o>MAX_INT:return '—'
    return f'{i+o:,}'+(' + ?' if s['missing']['input']+s['missing']['output'] else '')


def status(s):
    if not s['count'] and s['updatedAt'] is None:return '正在读取本机历史…'
    return f"正在汇总 {s['loaded']} / {s['count']} 条记录" if s['loaded']<s['count'] else f"已汇总 {s['count']} 条记录 · 含归档与子代理"


class AllUsageReader:
    def __init__(self,catalog=None,cache_path=None):
        self.catalog=catalog or Catalog();self.cache_path=cache_path;self.cache={}
        self.entries=[];self.pending=[];self.current=None;self.refreshed=float('-inf');self.issues=[];self.updated=None;self.dirty=False;self.last_saved=float('-inf')
        if cache_path:
            try:
                if cache_path.stat().st_size<=20*1024*1024:
                    data=json.loads(cache_path.read_text(encoding='utf-8'))
                    if isinstance(data,dict):self.cache=data
            except (OSError,ValueError):pass
        self.price_stamp=hashlib.sha256(json.dumps(pricing.BOOK.document,sort_keys=True).encode()).hexdigest()
    def key(self,e):return e['source']+':'+e['id']
    def signature(self,e):
        def stamp(p):
            try:
                s=Path(p).stat();return f'{s.st_size}|{s.st_mtime_ns}|{s.st_ino}'
            except OSError:return 'missing'
        return e['path']+'|'+stamp(e['path'])+('|' + stamp(e['path']+'-wal') if e['source']=='opencode' else '')+'|'+self.price_stamp
    def poll(self,force=False):
        if self.current is None and not self.pending and (force or time.monotonic()-self.refreshed>=30):
            self.refreshed=time.monotonic();self.issues=[]
            try:
                found=self.catalog.tasks(all_history=True,strict=True)
                self.entries=list({self.key(e):e for e in found}.values())
                self.cache={self.key(e):self.cache[self.key(e)] for e in self.entries if self.key(e) in self.cache}
                self.pending=[e for e in self.entries if self.cache.get(self.key(e),{}).get('signature')!=self.signature(e)]
                for e in self.pending:self.cache.pop(self.key(e),None)
                self.dirty=True
            except (OSError,ValueError,RuntimeError) as e:self.issues=['部分数据源无法读取，汇总范围待核']
        deadline=time.monotonic()+.15
        while time.monotonic()<deadline:
            if self.current is None:
                if not self.pending:break
                e=self.pending.pop(0)
                if e['source']=='codex':self.current=(e,pricing.CostLogReader(e['path']))
                else:
                    before=self.signature(e);s=self.catalog.snapshot(e,False)
                    self.cache[self.key(e)]=dict(signature=before,tokens=s['total'],cost=s.get('costTotal') or pricing.unknown('缺少费用记录'))
                    self.dirty=True;continue
            e,reader=self.current;before=self.signature(e);reader.poll()
            try:more=reader.offset<reader.path.stat().st_size
            except OSError:more=False
            if more:break
            s=codex_log(e['path'])
            self.cache[self.key(e)]=dict(signature=before,tokens=s['total'] if not s['error'] else None,cost=reader.value('total'))
            self.current=None;self.dirty=True
        if self.dirty and ((self.current is None and not self.pending) or time.monotonic()-self.last_saved>=5):
            self.dirty=False;self.last_saved=time.monotonic()
            if self.current is None and not self.pending:self.updated=now_iso()
            if self.cache_path:
                try:
                    self.cache_path.parent.mkdir(parents=True,exist_ok=True)
                    temp=self.cache_path.with_suffix('.tmp');temp.write_text(json.dumps(self.cache,ensure_ascii=False),encoding='utf-8');temp.replace(self.cache_path)
                except OSError:pass
        return summary(self.entries,self.cache,self.issues,self.updated)
