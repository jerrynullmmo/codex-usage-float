"""Read-only usage providers. No network, credentials, model calls or app-control operations."""
from __future__ import annotations
from contextlib import contextmanager
import datetime as dt
import math
import json
import os
from pathlib import Path
import re
import sqlite3
from pricing import BOOK, CostLogReader, cost, plus, unknown

FIELDS = ('input', 'output', 'cached', 'written', 'reasoning')
ZERO = dict.fromkeys(FIELDS, 0)
UNKNOWN = dict.fromkeys(FIELDS)
MAX_INT = 2**63 - 1

def number(value):
    return value if type(value) is int and 0 <= value <= MAX_INT else None

def counters(value):
    return {k: number((value or {}).get(k)) for k in FIELDS}

def add(a, b):
    return {k: number(a[k] + b[k]) if a.get(k) is not None and b.get(k) is not None else None for k in FIELDS}

def subtract(a, b):
    return {k: number(a[k] - b[k]) if a.get(k) is not None and b.get(k) is not None else None for k in FIELDS}

def date(value):
    try:
        parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        return parsed.timestamp() if parsed.tzinfo else None
    except (ValueError, TypeError, AttributeError, OverflowError):
        return None

def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat()

def fresh(value):
    timestamp = date(value)
    return timestamp is not None and -5 <= dt.datetime.now(dt.timezone.utc).timestamp() - timestamp <= 15

@contextmanager
def database(path):
    db = sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True, timeout=.15)
    db.row_factory = sqlite3.Row
    try: yield db
    finally: db.close()

def rows(db, sql, params=()):
    result = db.execute(sql, params).fetchmany(50001)
    if len(result) > 50000:
        raise ValueError('记录超过读取上限')
    return [dict(r) for r in result]

def blank(source):
    return dict(sourceName=source, total=None, round=None, last=None, windows=[], members=[],
                running=False, updatedAt=None, quotaUpdatedAt=None, plan=None, error=None, scopeNote='')

def codex_tokens(value):
    return {k: number(value.get(raw)) for k, raw in zip(FIELDS, (
        'input_tokens', 'output_tokens', 'cached_input_tokens', 'cache_write_input_tokens', 'reasoning_output_tokens'))}

def codex_log(path):
    out = blank('Codex'); points = []; baseline = None; partial = False
    try:
        with open(path, 'rb') as f:
            size = f.seek(0, 2); start = max(0, size - 8 * 1024 * 1024); f.seek(start)
            partial = start > 0
            if partial: f.readline()
            data = f.read(8 * 1024 * 1024)
        for line in data.splitlines(keepends=True):
            if not line.endswith(b'\n') or len(line) > 2 * 1024 * 1024 or b'"event_msg"' not in line:
                continue
            try: d = json.loads(line)
            except (ValueError, UnicodeDecodeError): continue
            if d.get('type') != 'event_msg': continue
            p = d.get('payload') or {}; kind = p.get('type')
            if kind == 'task_started':
                baseline = out['total'] or (None if partial else ZERO)
                out['turnStartedAt'] = d.get('timestamp'); out['last'] = None; out['running'] = True
            elif kind in ('task_complete', 'task_aborted', 'turn_aborted'):
                out['running'] = False
            elif kind == 'token_count':
                info = p.get('info') or {}
                if isinstance(info.get('total_token_usage'), dict):
                    out['total'] = codex_tokens(info['total_token_usage'])
                    stamp = date(d.get('timestamp'))
                    if stamp is not None:
                        if not points or points[-1][1] != out['total']: points.append((stamp, out['total']))
                    else: partial = True
                if isinstance(info.get('last_token_usage'), dict): out['last'] = codex_tokens(info['last_token_usage'])
                if info: out['updatedAt'] = d.get('timestamp')
                limits = p.get('rate_limits') or {}
                if limits and limits.get('limit_id', 'codex') == 'codex':
                    out['windows'] = []
                    for key in ('primary', 'secondary'):
                        w = limits.get(key) or {}; used = w.get('used_percent')
                        if isinstance(used, (int, float)) and 0 <= used <= 100:
                            out['windows'].append(dict(used=used, minutes=w.get('window_minutes', 0), resets=w.get('resets_at')))
                    out['plan'] = limits.get('plan_type'); out['quotaUpdatedAt'] = d.get('timestamp')
        if out['total'] is not None and baseline is not None:
            out['round'] = subtract(out['total'], baseline)
    except (OSError, ValueError, TypeError): out['error'] = '无法读取任务记录'
    out['_points'] = points; out['_partial'] = partial
    return out

def since(snapshot, boundary):
    if boundary is None or snapshot['error']: return None
    earlier = [value for time, value in snapshot['_points'] if time < boundary]
    baseline = earlier[-1] if earlier else (None if snapshot['_partial'] else ZERO)
    total = snapshot['total'] or (None if snapshot['_partial'] else ZERO)
    return subtract(total, baseline) if total is not None and baseline is not None else None

def codex_family(task, include_children=True, cost_readers=None):
    readers = cost_readers if cost_readers is not None else {}
    def priced(path):
        r=readers.setdefault(path,CostLogReader(path)).poll()
        result=codex_log(path)
        for k in ('total','round','last'):result['cost'+k.title()]=r.value(k)
        return result
    root = priced(task['path'])
    if not include_children: return root
    try:
        with database(task['database']) as db:
            family = rows(db, '''WITH RECURSIVE family(id) AS (SELECT ? UNION
                SELECT e.child_thread_id FROM thread_spawn_edges e JOIN family f ON e.parent_thread_id=f.id)
                SELECT f.id,COALESCE(NULLIF(t.name,''),t.title,f.id) AS title,COALESCE(t.rollout_path,'') AS path
                FROM family f LEFT JOIN threads t ON f.id=t.id''', (task['id'],))
        total = root['total'] if not root['error'] else None
        current = root['round'] if not root['error'] else None
        root['members'] = [dict(id=task['id'], title=task['title'], total=total, round=current, error=root['error'],costTotal=root.get('costTotal'),costRound=root.get('costRound'))]
        boundary = date(root.get('turnStartedAt'))
        for member in family:
            if member['id'] == task['id']: continue
            child = priced(member['path']); ct = child['total'] if not child['error'] else None; cr = since(child, boundary)
            root['members'].append(dict(id=member['id'], title=member['title'], total=ct, round=cr, error=child['error'],costTotal=child['costTotal'],costRound=readers[member['path']].since(boundary)))
            root['costTotal']=plus(root['costTotal'],child['costTotal']);root['costRound']=plus(root['costRound'],readers[member['path']].since(boundary))
            total = add(total or UNKNOWN, ct or UNKNOWN); current = add(current or UNKNOWN, cr or UNKNOWN)
            root['running'] |= child['running']
            if (date(child['updatedAt']) or 0) > (date(root['updatedAt']) or 0): root['updatedAt'] = child['updatedAt']
        root['total'] = total; root['round'] = current
        root['scopeNote'] = f'含 {len(family)-1} 个子代理；最近调用仅指主任务。'
        if any(m['total'] is None or m['error'] for m in root['members']): root['error'] = '任务记录缺失，完整合计未知（—）'
    except (sqlite3.Error, OSError, ValueError): root['error'] = '无法读取子代理关系，当前仅显示主任务'
    return root

def opencode_tokens(value):
    cache = value.get('cache') or {}
    result = counters(dict(input=value.get('input'), output=value.get('output'), cached=cache.get('read'),
                           written=cache.get('write'), reasoning=value.get('reasoning')))
    for target, parts in [('input', ('input', 'cached', 'written')), ('output', ('output', 'reasoning'))]:
        values = [result[p] for p in parts]
        result[target] = number(sum(values)) if all(v is not None for v in values) else None
    return result

def opencode_family(task, include_children=True):
    out = blank('OpenCode')
    try:
        with database(task['path']) as db:
            db.execute('BEGIN')
            sessions = rows(db, '''WITH RECURSIVE family(id) AS (SELECT ? UNION
                SELECT s.id FROM session s JOIN family f ON s.parent_id=f.id)
                SELECT s.id,s.title FROM session s JOIN family f ON s.id=f.id''' if include_children else
                'SELECT id,title FROM session WHERE id=?', (task['id'],))
            messages = {s['id']: rows(db, '''SELECT id,json_extract(data,'$.role') AS role,
                json_extract(data,'$.tokens') AS tokens,json_extract(data,'$.time.created') AS created,
                json_extract(data,'$.modelID') AS model,json_extract(data,'$.providerID') AS provider,
                json_extract(data,'$.time.completed') AS completed,json_extract(data,'$.parentID') AS parent
                FROM message WHERE session_id=? ORDER BY time_created,id''', (s['id'],)) for s in sessions}
        if task['id'] not in messages: raise ValueError('任务不存在')
        users = [m for m in messages[task['id']] if m['role'] == 'user']; user = users[-1] if users else {}
        boundary = user.get('created'); total = dict(ZERO); current = dict(ZERO)
        out['costTotal']=cost();out['costRound']=cost() if boundary is not None else unknown('缺少本轮边界')
        for session in sessions:
            own = dict(ZERO); turn = dict(ZERO);own_cost=cost();round_cost=cost()
            for m in messages[session['id']]:
                if m['role'] != 'assistant': continue
                value = opencode_tokens(json.loads(m['tokens'])) if m['tokens'] else dict(UNKNOWN)
                own = add(own, value)
                priced=BOOK.quote(value,m.get("model"),m.get("provider"));own_cost=plus(own_cost,priced)
                if session['id'] == task['id']:
                    inside = m['parent'] == user.get('id') if m['parent'] is not None and user else None
                    if inside is not False: out['last'] = value if inside else None;out['costLast']=priced if inside else unknown('缺少最近调用边界')
                else:
                    inside = m['created'] >= boundary if m['created'] is not None and boundary is not None else None
                if inside is None: turn = dict(UNKNOWN);round_cost=plus(round_cost,unknown("缺少本轮边界"))
                elif inside: turn = add(turn, value);round_cost=plus(round_cost,priced)
                if inside and m['completed'] is None: out['running'] = True
                stamp = m['completed'] or m['created']
                if stamp and stamp / 1000 > (date(out['updatedAt']) or 0):
                    out['updatedAt'] = dt.datetime.fromtimestamp(stamp / 1000, dt.timezone.utc).isoformat()
            out['members'].append(dict(id=session['id'], title=session['title'], total=own, round=turn if boundary is not None else None,costTotal=own_cost,costRound=round_cost))
            out["costTotal"]=plus(out["costTotal"],own_cost);out["costRound"]=plus(out["costRound"],round_cost)
            total = add(total, own); current = add(current, turn)
        out['total'] = total; out['round'] = current if boundary is not None else None
        out['scopeNote'] = f'含 {len(sessions)-1} 个子代理；最近调用仅指主任务。'
    except (sqlite3.Error, OSError, ValueError, TypeError): out['error'] = '无法完整读取 OpenCode 计量记录'
    return out

def read_bridge(path):
    try:
        if Path(path).stat().st_size > 1024 * 1024: return None
        doc = json.loads(Path(path).read_text(encoding='utf-8'))
        if not isinstance(doc, dict): return None
        if not isinstance(doc.get('id'),str) or not isinstance(doc.get('name'),str): return None
        if doc.get('schemaVersion') != 1 or not re.fullmatch('[a-z0-9-]+', doc.get('id', '')) or not doc.get('name'): return None
        if date(doc.get('updatedAt')) is None or not (doc.get('bundleIDs') or doc.get('processNames')): return None
        for key in ('bundleIDs','processNames'):
            if not isinstance(doc.get(key,[] if key=='processNames' else None),list) or any(not isinstance(n,str) or not n for n in doc.get(key,[])): return None
        sessions = doc['sessions']
        if not isinstance(sessions,list) or any(not isinstance(s,dict) or not isinstance(s.get('id'),str) or not isinstance(s.get('title'),str) or (s.get('parentID') is not None and not isinstance(s['parentID'],str)) for s in sessions): return None
        ids = {s['id'] for s in sessions}
        if len(sessions) > 1000 or len(ids) != len(sessions) or '' in ids: return None
        if any(s.get('parentID') and s['parentID'] not in ids for s in sessions): return None
        if any(p in ('com.openai.codex','ai.opencode.desktop') for p in doc.get('bundleIDs', [])): return None
        for session in sessions:
            calls=session.get('calls')
            if calls is not None:
                if not isinstance(calls,list) or len(calls)>5000:return None
                ids=set()
                for call in calls:
                    if not isinstance(call,dict) or not isinstance(call.get('id'),str) or not call['id'] or call['id'] in ids:return None
                    ids.add(call['id'])
                    if not isinstance(call.get('model'),str) or not call['model'] or date(call.get('createdAt')) is None or not isinstance(call.get('tokens'),dict):return None
                    if call.get('provider') is not None and not isinstance(call['provider'],str):return None
                    if any(v is not None and number(v) is None for v in call['tokens'].values()):return None
            for key in ('total','round','last'):
                if session.get(key) is not None and not isinstance(session[key],dict): return None
                for value in (session.get(key) or {}).values():
                    if value is not None and number(value) is None: return None
        quota = doc.get('quota') or {}
        if not isinstance(quota,dict): return None
        if quota:
            if date(quota.get('updatedAt')) is None or not isinstance(quota.get('windows',[]),list) or len(quota.get('windows', [])) > 2: return None
            for w in quota.get('windows', []):
                if not isinstance(w,dict): return None
                if w.get('resets') is not None and (not isinstance(w['resets'],(int,float)) or not math.isfinite(w['resets'])): return None
                if not isinstance(w.get('used'), (int,float)) or not 0 <= w['used'] <= 100 or type(w.get('minutes')) is not int or w['minutes'] <= 0: return None
        return doc
    except (OSError, ValueError, TypeError, KeyError): return None

def bridge_costs(session,boundary):
    calls=session.get('calls')
    if calls is None:return (unknown('接入程序未提供逐次调用'),)*3
    total=cost();current=cost() if boundary is not None else unknown('缺少主任务时间边界');summed=dict(ZERO)
    for call in calls:
        value=BOOK.quote(counters(call['tokens']),call['model'],call.get('provider'));total=plus(total,value)
        summed=add(summed,counters(call['tokens']))
        if boundary is not None and date(call['createdAt'])>=boundary:current=plus(current,value)
    if session.get('callsComplete') is not True or any(summed[k]!=(session.get('total') or {}).get(k) for k in ('input','output','cached','written')):
        total=plus(total,unknown('逐次调用未覆盖完整用量'));current=plus(current,unknown('逐次调用未覆盖完整用量'))
    latest=max(calls,key=lambda c:date(c['createdAt'])) if calls else None
    recent=BOOK.quote(counters(latest['tokens']),latest['model'],latest.get('provider')) if latest and session.get('callsComplete') is True and counters(session.get('last'))==counters(latest['tokens']) else unknown('接入记录未确认最近调用')
    return total,current,recent

def bridge_snapshot(task, include_children=True):
    out = blank('外部接入'); doc = read_bridge(task['path'])
    if not doc or 'bridge:' + doc['id'] != task['source']:
        out['error'] = '接入文件无效'; return out
    sessions = {s['id']: s for s in doc['sessions']}; root = sessions.get(task['id'])
    if root is None: out['error'] = '所选任务已移除'; return out
    ids = {root['id']}
    if include_children:
        while True:
            old = len(ids); ids.update(s['id'] for s in sessions.values() if s.get('parentID') in ids)
            if old == len(ids): break
    total = dict(ZERO); current = dict(ZERO); boundary = date(root.get('roundStartedAt'))
    out['costTotal']=cost();out['costRound']=cost();out['costLast']=bridge_costs(root,boundary)[2]
    for sid in ids:
        s = sessions[sid]; own = counters(s.get('total')); turn = counters(s.get('round')) if boundary is not None and date(s.get('roundStartedAt')) == boundary else dict(UNKNOWN)
        total = add(total, own); current = add(current, turn)
        priced=bridge_costs(s,boundary)
        out['costTotal']=plus(out['costTotal'],priced[0]);out['costRound']=plus(out['costRound'],priced[1])
        out['members'].append(dict(id=sid, title=s['title'], total=own, round=turn,costTotal=priced[0],costRound=priced[1]))
        out['running'] |= bool(s.get('running'))
    out.update(sourceName=doc['name'], total=total, round=current if boundary is not None else None,
               last=counters(root.get('last')), updatedAt=root.get('updatedAt') or doc['updatedAt'],
               scopeNote=f"含 {len(ids)-1} 个子代理；最近调用仅指主任务。")
    quota = doc.get('quota') or {}; out.update(windows=quota.get('windows', []), plan=quota.get('plan'), quotaUpdatedAt=quota.get('updatedAt'))
    if include_children and doc.get('childrenComplete') is not True:
        out['costTotal']=plus(out['costTotal'],unknown('子代理完整性未确认'));out['costRound']=plus(out['costRound'],unknown('子代理完整性未确认'))
        out.update(total=None, round=None, error='接入程序未确认子代理完整性')
    if not fresh(doc['updatedAt']): out['error'] = '接入数据超过 15 秒未更新'
    return out

class Catalog:
    def __init__(self, home=None, adapter_dir=None):
        self.home = Path(home or Path.home())
        self.cost_readers = {}; self.cost_root = None
        self.adapter_dir = Path(adapter_dir or Path(os.environ.get('APPDATA', self.home)) / 'AI Usage Float/adapters')
    def bridges(self):
        pairs = [(p,d) for p in sorted(self.adapter_dir.glob('*.json'))[:32] if (d := read_bridge(p))]
        return [(p,d) for p,d in pairs if sum(x['id'] == d['id'] for _,x in pairs) == 1]
    def tasks(self, source=None):
        result = []
        if source in (None,'codex'):
            paths = [p for p in (self.home/'.codex').glob('state_*.sqlite') if re.fullmatch(r'state_\d+\.sqlite', p.name)]
            if paths:
                path = max(paths, key=lambda p:int(re.search(r'\d+', p.name)[0]))
                try:
                    with database(path) as db:
                        for r in rows(db,"SELECT id,COALESCE(NULLIF(name,''),title) AS title,rollout_path AS path FROM threads WHERE archived=0 AND (agent_path IS NULL OR agent_path='/root') ORDER BY updated_at DESC LIMIT 40"):
                            result.append(dict(r,source='codex',database=str(path)))
                except (sqlite3.Error,OSError): pass
        if source in (None,'opencode'):
            path = self.home/'.local/share/opencode/opencode.db'
            if path.exists():
                try:
                    with database(path) as db:
                        for r in rows(db,'SELECT id,title FROM session WHERE parent_id IS NULL AND time_archived IS NULL ORDER BY time_updated DESC LIMIT 40'):
                            result.append(dict(r,source='opencode',path=str(path)))
                except (sqlite3.Error,OSError): pass
        for path, doc in self.bridges():
            if source is not None and source != 'bridge:' + doc['id']: continue
            result.extend(dict(id=s['id'],title=s['title'],source='bridge:'+doc['id'],path=str(path)) for s in doc['sessions'] if not s.get('parentID'))
        return result
    def exact_tasks(self, source, titles):
        # Selection searches all history; the recent-task menu is not a uniqueness index.
        titles = list(titles)[:8]
        if not titles: return []
        params = ','.join('?' for _ in titles)
        try:
            if source == 'codex':
                paths = [p for p in (self.home/'.codex').glob('state_*.sqlite') if re.fullmatch(r'state_\d+\.sqlite',p.name)]
                if not paths:return []
                path = max(paths,key=lambda p:int(re.search(r'\d+',p.name)[0]))
                with database(path) as db:
                    matches = rows(db,"SELECT id,COALESCE(NULLIF(name,''),title) AS title,rollout_path AS path FROM threads WHERE COALESCE(NULLIF(name,''),title) IN ("+params+") LIMIT 2",titles)
                return [dict(r,source='codex',database=str(path)) for r in matches]
            path = self.home/'.local/share/opencode/opencode.db'
            with database(path) as db:matches=rows(db,'SELECT id,title FROM session WHERE title IN ('+params+') LIMIT 2',titles)
            return [dict(r,source='opencode',path=str(path)) for r in matches]
        except (sqlite3.Error,OSError,ValueError):return []
    def focus(self, process, titles):
        name = Path(process).stem.lower()
        native = 'codex' if name in ('codex','chatgpt') else 'opencode' if name == 'opencode' else None
        if native:
            titles = {t for t in titles if t and t.lower() not in ('codex','chatgpt','opencode')}
            matches = self.exact_tasks(native,titles)
            return matches[0] if len(matches) == 1 else None
        matches = [(p,d) for p,d in self.bridges() if name in [Path(n).stem.lower() for n in d.get('processNames',[])]]
        if len(matches) != 1: return None
        p,d = matches[0]
        if not fresh(d['updatedAt']): return None
        s = next((s for s in d['sessions'] if s['id'] == d.get('activeSessionID')),None)
        return dict(id=s['id'],title=s['title'],source='bridge:'+d['id'],path=str(p)) if s else None
    def snapshot(self, task, include_children=True):
        if task['source']=='codex':
            if self.cost_root != task['id']:self.cost_readers={};self.cost_root=task['id']
            return codex_family(task,include_children,self.cost_readers)
        reader = {'codex':codex_family,'opencode':opencode_family}.get(task['source'],bridge_snapshot)
        return reader(task,include_children)


def same_focus(before, after):
    return bool(before.get('hwnd')) and before.get('hwnd') == after.get('hwnd') and before.get('process') == after.get('process') and before.get('titles') == after.get('titles')


def same_task(before, after):
    def key(task):return tuple(task.get(k) for k in ('source','id','path')) if task else None
    return key(before) == key(after)
