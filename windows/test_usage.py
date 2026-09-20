import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from usage_core import *

class Accounting(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.home=Path(self.temp.name)
    def tearDown(self):self.temp.cleanup()
    def event(self,kind,time='2026-09-15T00:00:00Z',**payload):
        return json.dumps(dict(type='event_msg',timestamp=time,payload=dict(type=kind,**payload)))+'\n'
    def count(self,n,time='2026-09-15T01:00:00Z'):
        t=dict(input_tokens=n,output_tokens=n//10,cached_input_tokens=n//2,reasoning_output_tokens=0)
        return self.event('token_count',time,info=dict(total_token_usage=t,last_token_usage=t))
    def family(self):
        folder=self.home/'.codex';folder.mkdir();db=folder/'state_5.sqlite';c=sqlite3.connect(db)
        c.executescript('CREATE TABLE threads(id TEXT,name TEXT,title TEXT,rollout_path TEXT,archived INTEGER,agent_path TEXT,updated_at INTEGER); CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT,status TEXT);')
        root=folder/'root.log';child=folder/'child.log'
        root.write_text(self.count(100,'2026-09-14T00:00:00Z')+self.event('task_started')+self.count(400),encoding='utf-8')
        child.write_text(self.count(200,'2026-09-14T00:00:00Z')+self.event('task_started')+self.count(350)+self.event('task_started')+self.count(500)+self.count(500),encoding='utf-8')
        c.execute('INSERT INTO threads VALUES(?,?,?,?,0,?,1)',('root','Root','Root',str(root),'/root'))
        c.execute('INSERT INTO threads VALUES(?,?,?,?,1,?,1)',('child','Child','Child',str(child),'/root/child'))
        c.executescript("INSERT INTO thread_spawn_edges VALUES('root','child','closed'),('child','root','open');");c.commit();c.close()
        return Catalog(home=self.home).tasks()[0]
    def test_duplicate_cumulative(self):
        task=self.family();s=codex_family(task)
        self.assertEqual(s['total']['input'],900);self.assertEqual(len(s['members']),2)
    def test_all_followups_same_root_boundary(self):self.assertEqual(codex_family(self.family())['round']['input'],600)
    def test_root_last_call(self):self.assertEqual(codex_family(self.family())['last']['input'],400)
    def test_root_only(self):self.assertEqual(codex_family(self.family(),False)['total']['input'],400)
    def test_missing_child(self):
        task=self.family();(self.home/'.codex/child.log').unlink();s=codex_family(task)
        self.assertIsNone(s['total']['input']);self.assertTrue(s['error'])
    def test_missing_root(self):
        task=self.family();Path(task['path']).unlink();s=codex_family(task)
        self.assertIsNone(s['total']['input']);self.assertTrue(s['error'])
    def test_unknown_write(self):self.assertIsNone(codex_family(self.family())['total']['written'])
    def test_focus_unknown_clears(self):
        self.family();c=Catalog(home=self.home)
        self.assertIsNone(c.focus('Codex',['ChatGPT']));self.assertIsNone(c.focus('Codex',['Unknown']))
    def test_focus_exact(self):self.family();self.assertEqual(Catalog(home=self.home).focus('Codex',['Root'])['id'],'root')
    def test_archived_duplicate_title_rejected(self):
        task=self.family();c=sqlite3.connect(task['database'])
        c.execute("INSERT INTO threads VALUES('old','Root','Root','missing',1,'/root',0)");c.commit();c.close()
        self.assertIsNone(Catalog(home=self.home).focus('Codex',['Root']))
    def test_changed_app_result_rejected(self):
        a=dict(hwnd=1,process='Codex',titles=['Root'])
        self.assertFalse(same_focus(a,dict(hwnd=2,process='Other',titles=['Root'])))
        self.assertFalse(same_focus(a,dict(hwnd=1,process='Codex',titles=['Other task'])))
        self.assertTrue(same_focus(a,dict(a)))
    def test_negative_delta(self):self.assertIsNone(subtract(dict(ZERO,input=1),dict(ZERO,input=2))['input'])
    def test_overflow(self):self.assertIsNone(add(dict(ZERO,input=MAX_INT),dict(ZERO,input=1))['input'])
    def test_normalize_opencode(self):
        t=opencode_tokens(dict(input=3860,output=77,reasoning=17,cache=dict(read=8192,write=0)))
        self.assertEqual(t['input'],12052);self.assertEqual(t['output'],94)
    def test_opencode_family_and_unknown_time(self):
        p=self.home/'oc.db';c=sqlite3.connect(p);c.executescript('CREATE TABLE session(id TEXT,title TEXT,parent_id TEXT);CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,data TEXT);INSERT INTO session VALUES("r","root",NULL),("c","child","r");')
        t=dict(input=100,output=10,reasoning=5,cache=dict(read=20,write=30))
        messages=[('u','r',dict(role='user',time=dict(created=100))),('a','r',dict(role='assistant',parentID='u',time=dict(created=110,completed=120),tokens=t)),('b','c',dict(role='assistant',time=dict(created=115,completed=125),tokens=t))]
        for i,s,d in messages:c.execute('INSERT INTO message VALUES(?,?,1,?)',(i,s,json.dumps(d)))
        c.commit();task=dict(id='r',source='opencode',path=str(p));out=opencode_family(task)
        self.assertEqual(out['total']['input'],300);self.assertEqual(out['round']['input'],300)
        c.execute("UPDATE message SET data=json_remove(data,'$.time.created') WHERE id='b'");c.commit()
        self.assertIsNone(opencode_family(task)['round']['input']);c.close()
    def bridge(self):
        p=self.home/'bridge.json';stamp=now_iso()
        d=dict(schemaVersion=1,id='example',name='Example',bundleIDs=[],processNames=['Example.exe'],updatedAt=stamp,activeSessionID='r',childrenComplete=True,sessions=[dict(id='r',title='R',total=dict(input=100),round=dict(input=30),roundStartedAt=stamp),dict(id='c',title='C',parentID='r',total=dict(input=50),round=dict(input=20),roundStartedAt=stamp)])
        p.write_text(json.dumps(d));return p,d
    def test_bridge_fresh_focus(self):
        p,d=self.bridge();self.assertEqual(Catalog(adapter_dir=self.home).focus('Example.exe',[])['id'],'r')
    def test_bridge_totals(self):
        p,d=self.bridge();s=bridge_snapshot(dict(path=str(p),source='bridge:example',id='r'))
        self.assertEqual(s['total']['input'],150);self.assertEqual(s['round']['input'],50)
    def test_bridge_switch_and_expiry(self):
        p,d=self.bridge();d['activeSessionID']='c';p.write_text(json.dumps(d));cat=Catalog(adapter_dir=self.home)
        self.assertEqual(cat.focus('Example',[])['id'],'c');d['updatedAt']='2000-01-01T00:00:00Z';p.write_text(json.dumps(d));self.assertIsNone(cat.focus('Example',[]))
    def test_bridge_same_window_changed_task_rejected(self):
        p,d=self.bridge();cat=Catalog(adapter_dir=self.home)
        before=cat.focus('Example.exe',['Static title'])
        d['activeSessionID']='c';p.write_text(json.dumps(d))
        after=cat.focus('Example.exe',['Static title'])
        self.assertFalse(same_task(before,after));self.assertTrue(same_task(after,after))
    def test_bridge_complete_required(self):
        p,d=self.bridge();d['childrenComplete']=False;p.write_text(json.dumps(d));self.assertIsNone(bridge_snapshot(dict(path=str(p),source='bridge:example',id='r'))['total'])
    def test_bridge_rejects_duplicate(self):
        p,d=self.bridge();d['sessions'].append(d['sessions'][0]);p.write_text(json.dumps(d));self.assertIsNone(read_bridge(p))
    def test_bridge_rejects_negative(self):
        p,d=self.bridge();d['sessions'][0]['total']['input']=-1;p.write_text(json.dumps(d));self.assertIsNone(read_bridge(p))
    def test_bridge_unknown_round(self):
        p,d=self.bridge();d['sessions'][1]['roundStartedAt']='2000-01-01T00:00:00Z';p.write_text(json.dumps(d));self.assertIsNone(bridge_snapshot(dict(path=str(p),source='bridge:example',id='r'))['round']['input'])

if __name__=='__main__':unittest.main()

class PricingTests(unittest.TestCase):
    def test_multi_provider_prices_and_boundaries(self):
        from pricing import BOOK
        value=dict(input=100000,output=1000,cached=60000,written=10000,reasoning=800)
        for model,expected in [('gpt-6-astra',.535),('claude-sonnet-5',.107),('gemini-2.5-flash',.0163),('deepseek-flash',.01356)]:
            with self.subTest(model=model):
                result=BOOK.quote(value,model);self.assertTrue(result['complete']);self.assertAlmostEqual(result['usd'],expected)
        self.assertFalse(BOOK.quote(value,'unknown-model')['complete'])
        self.assertFalse(BOOK.quote(value,'gpt-6-astra','anthropic')['complete'])
        self.assertFalse(BOOK.quote(dict(input=100,output=1,cached=10),'gpt-6-astra')['complete'])
        self.assertTrue(BOOK.quote(dict(input=100,output=1,cached=10),'gpt-4.1')['complete'])
        self.assertFalse(BOOK.quote(dict(input=100,output=1,cached=90,written=20),'gpt-6-astra')['complete'])
        self.assertAlmostEqual(BOOK.quote(dict(input=300000,output=1000,cached=0,written=0),'gpt-6-astra')['usd'],6.075)
    def test_incremental_mixed_model_replay(self):
        from pricing import CostLogReader,plus,unknown,cost,label
        import tempfile
        def event(kind,payload):return json.dumps(dict(type=kind,timestamp='2026-09-20T10:00:00Z',payload=payload))+'\n'
        def count(total,last):return event('event_msg',dict(type='token_count',info=dict(total_token_usage=total,last_token_usage=last)))
        one=dict(input_tokens=100000,output_tokens=1000,cached_input_tokens=60000,cache_write_input_tokens=10000)
        two={k:v*2 for k,v in one.items()}
        started=event('event_msg',dict(type='task_started'))
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'log.jsonl'
            p.write_text(started+event('turn_context',dict(model='gpt-6-astra'))+count(one,one))
            reader=CostLogReader(p).poll();self.assertAlmostEqual(reader.value('total')['usd'],.535)
            with p.open('a') as f:f.write(count(one,one)+started+event('turn_context',dict(model='claude-sonnet-5'))+count(two,one))
            reader.poll();self.assertAlmostEqual(reader.value('total')['usd'],.642);self.assertAlmostEqual(reader.value('round')['usd'],.107)
            self.assertEqual(len(reader.value('total')['models']),2)
            p.write_text(started+event('turn_context',dict(model='gpt-6-astra'))+count(one,one))
            reader.poll();self.assertAlmostEqual(reader.value('total')['usd'],.535)
        self.assertIn(' + ?',label(plus(cost(1),unknown('missing'))))
    def test_bridge_mixed_model_and_missing_coverage(self):
        from usage_core import bridge_costs,date
        value=dict(input=100000,output=1000,cached=60000,written=10000,reasoning=0)
        calls=[dict(id='a',model='gpt-6-astra',createdAt='2026-09-20T09:00:00Z',tokens=value),dict(id='b',model='claude-sonnet-5',createdAt='2026-09-20T11:00:00Z',tokens=value)]
        s=dict(calls=calls,callsComplete=True,total={k:v*2 for k,v in value.items()})
        total,current,last=bridge_costs(s,date('2026-09-20T10:00:00Z'))
        self.assertTrue(total['complete']);self.assertAlmostEqual(total['usd'],.642);self.assertAlmostEqual(current['usd'],.107)
        s['callsComplete']=False
        self.assertFalse(bridge_costs(s,date('2026-09-20T10:00:00Z'))[0]['complete'])
