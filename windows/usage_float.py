"""Windows floating UI. Native NOACTIVATE windows keep typing focus in the user's app."""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from types import SimpleNamespace
import tkinter as tk
import pricing
import all_usage
from usage_core import Catalog, FIELDS, blank, date, same_focus, same_task

LABELS = dict(input='输入',output='输出',cached='缓存读取',written='缓存写入',reasoning='推理输出')
COLORS = dict(mint='#76deba',blue='#75b0ff',rose='#f592ba')

def formatted(value):
    return '—' if value is None else f'{value:,}'

def resource(name):
    return Path(getattr(sys,'_MEIPASS',Path(__file__).parent))/name

def quick_focus():
    user=ctypes.WinDLL('user32',use_last_error=True);kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    user.GetForegroundWindow.restype=wintypes.HWND
    user.GetWindowTextW.argtypes=[wintypes.HWND,wintypes.LPWSTR,ctypes.c_int]
    user.GetWindowThreadProcessId.argtypes=[wintypes.HWND,ctypes.POINTER(wintypes.DWORD)]
    kernel.OpenProcess.argtypes=[wintypes.DWORD,wintypes.BOOL,wintypes.DWORD];kernel.OpenProcess.restype=wintypes.HANDLE
    kernel.QueryFullProcessImageNameW.argtypes=[wintypes.HANDLE,wintypes.DWORD,wintypes.LPWSTR,ctypes.POINTER(wintypes.DWORD)]
    kernel.CloseHandle.argtypes=[wintypes.HANDLE]
    hwnd=user.GetForegroundWindow();title=ctypes.create_unicode_buffer(1024);user.GetWindowTextW(hwnd,title,1024)
    pid=wintypes.DWORD();user.GetWindowThreadProcessId(hwnd,ctypes.byref(pid));handle=kernel.OpenProcess(0x1000,False,pid.value)
    name=''
    if handle:
        try:
            path=ctypes.create_unicode_buffer(32768);size=wintypes.DWORD(len(path))
            if kernel.QueryFullProcessImageNameW(handle,0,path,ctypes.byref(size)):name=Path(path.value).stem
        finally:kernel.CloseHandle(handle)
    return dict(process=name,titles=[title.value],hwnd=int(hwnd or 0))

def probe():
    basic=quick_focus()
    # Ordinary desktop use needs no helper process. Only Codex requires a document-title probe.
    if basic['process'].lower() not in ('codex','chatgpt'):return basic
    try:
        output=subprocess.check_output([str(resource('FocusProbe.exe'))],timeout=1.2,creationflags=0x08000000)
        return json.loads(output.decode('utf-8-sig'))
    except (OSError,ValueError,subprocess.SubprocessError):return basic

class FloatApp:
    def __init__(self, test=False):
        self.test = test
        self.folder = Path(os.environ['APPDATA'])/'AI Usage Float'
        self.catalog = Catalog(adapter_dir=self.folder/'adapters')
        try: self.settings = json.loads((self.folder/'settings.json').read_text(encoding='utf-8'))
        except (OSError,ValueError): self.settings = {}
        if not isinstance(self.settings,dict): self.settings={}
        self.root = tk.Tk(); self.root.withdraw(); self.root.overrideredirect(True); self.root.attributes('-topmost',True)
        self.root.title('AI Usage Float')
        self.canvas = tk.Canvas(self.root,highlightthickness=0,bg='#141a1f',width=160,height=36)
        self.canvas.pack(fill='both',expand=True)
        self.root.update_idletasks()
        self.user32 = ctypes.WinDLL('user32',use_last_error=True)
        self.user32.GetForegroundWindow.restype = wintypes.HWND
        self.user32.GetParent.argtypes = [wintypes.HWND]; self.user32.GetParent.restype = wintypes.HWND
        self.user32.GetWindowLongPtrW.argtypes = [wintypes.HWND,ctypes.c_int]; self.user32.GetWindowLongPtrW.restype = ctypes.c_ssize_t
        self.user32.SetWindowLongPtrW.argtypes = [wintypes.HWND,ctypes.c_int,ctypes.c_ssize_t]; self.user32.SetWindowLongPtrW.restype = ctypes.c_ssize_t
        self.user32.SetWindowPos.argtypes = [wintypes.HWND,wintypes.HWND,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_uint]
        self.hwnd = self.user32.GetParent(self.root.winfo_id()) or self.root.winfo_id()
        style = self.user32.GetWindowLongPtrW(self.hwnd,-20)
        self.user32.SetWindowLongPtrW(self.hwnd,-20,style | 0x08000000 | 0x00000080) # NOACTIVATE | TOOLWINDOW
        self.anchor = (self.settings.get('x',self.root.winfo_screenwidth()-190),self.settings.get('y',self.root.winfo_screenheight()-210))
        self.expanded=False; self.pinned=False; self.visible=False; self.inside_since=None; self.outside_since=None
        self.selected=None; self.snapshot=blank('AI'); self.generation=0; self.auto=self.settings.get('autoFollow',True)
        if not self.auto and isinstance(self.settings.get('selection'),dict):
            wanted=self.settings['selection'];self.selected=next((t for t in self.catalog.tasks(wanted.get('source')) if t['id']==wanted.get('id')),None)
        self.include_children=self.settings.get('includeSubagents',True); self.hidden=False; self.menu_open=False; self.tray_visible=False
        self.executor=ThreadPoolExecutor(max_workers=1); self.future=None; self.last_poll=0; self.last_read=0; self.last_key=None
        self.all_usage=all_usage.summary()
        self.all_reader=all_usage.AllUsageReader(Catalog(adapter_dir=self.folder/'adapters'),self.folder/'all-usage-cache.json')
        self.all_executor=ThreadPoolExecutor(max_workers=1);self.all_future=None;self.last_all=0
        self.drag=None; self.dragged=False
        self.canvas.bind('<ButtonPress-1>',self.press); self.canvas.bind('<B1-Motion>',self.move); self.canvas.bind('<ButtonRelease-1>',self.release)
        self.canvas.bind('<Button-3>',self.menu)
        self.root.protocol('WM_DELETE_WINDOW',self.quit)
        from tray import Tray
        self.tray=Tray(self.root,self.hwnd,self.tray_menu)
        if not self.tray.added:self.tray_visible=True;self.show(True)
        self.draw()
        # UI tests supply a controlled clock; a real hover timer must not overwrite it.
        if not self.test:self.root.after(100,self.tick)
    def save(self):
        if self.test: return
        self.settings.update(x=self.anchor[0],y=self.anchor[1],autoFollow=self.auto,includeSubagents=self.include_children)
        if self.selected:self.settings['selection']={k:self.selected[k] for k in ('source','id')}
        self.folder.mkdir(parents=True,exist_ok=True)
        target=self.folder/'settings.json'; temp=target.with_suffix('.tmp')
        temp.write_text(json.dumps(self.settings,ensure_ascii=False),encoding='utf-8'); temp.replace(target)
    @property
    def overview(self):return self.settings.get('overview',True)
    @property
    def notes_expanded(self):return self.settings.get('notesExpanded',False)
    def detail_height(self):return (390 if self.overview else 444)+27*len([k for k in self.settings.get('metrics',list(FIELDS)) if k in FIELDS])+(100 if self.notes_expanded else 0)
    def geometry(self):
        width,height = (480,self.detail_height()) if self.expanded else (160,36)
        x=max(0,min(self.anchor[0],self.root.winfo_screenwidth()-width))
        y=max(0,min(self.anchor[1],self.root.winfo_screenheight()-height-40))
        self.root.geometry(f'{width}x{height}+{x}+{y}')
        self.user32.SetWindowPos(self.hwnd,ctypes.c_void_p(-1),x,y,width,height,0x0010) # SWP_NOACTIVATE
    def show(self,visible):
        if visible==self.visible: return
        self.visible=visible
        if visible:
            self.geometry(); self.root.deiconify()
            self.user32.SetWindowPos(self.hwnd,ctypes.c_void_p(-1),0,0,0,0,0x0010|0x0001|0x0002|0x0040)
        else: self.root.withdraw()
    def expand(self,value):
        if value==self.expanded:return
        self.expanded=value; self.geometry(); self.draw()
    def hover(self,inside,now):
        if self.pinned: self.expand(True); return
        if inside:
            self.outside_since=None
            if self.inside_since is None:self.inside_since=now
            if now-self.inside_since>=.3:self.expand(True)
        else:
            self.inside_since=None
            if self.outside_since is None:self.outside_since=now
            if now-self.outside_since>=.5:self.expand(False)
    def read(self,generation,selected,auto,include_children):
        focus=probe() if auto else None
        task=self.catalog.focus(focus['process'],focus['titles']) if auto else selected
        snapshot=self.catalog.snapshot(task,include_children) if task else blank('AI')
        if auto:
            after=probe()
            after_task=self.catalog.focus(after['process'],after['titles'])
            if not same_focus(focus,after) or not same_task(task,after_task):task=None;snapshot=blank('AI')
            focus=after
        return generation,task,snapshot,focus
    def accept(self,result):
        generation,task,snapshot,focus=result
        if generation != self.generation:return False
        if focus is not None and int(self.user32.GetForegroundWindow() or 0) != focus.get('hwnd'):
            self.selected=None;self.snapshot=blank('AI');self.show(False);return False
        self.selected=task; self.snapshot=snapshot
        name=(focus or {}).get('process','').lower()
        supported = name in ('codex','chatgpt','opencode') or any(name in [Path(n).stem.lower() for n in d.get('processNames',[])] for _,d in self.catalog.bridges())
        self.show(not self.hidden and (self.test or not self.auto or supported or self.menu_open or self.tray_visible))
        self.draw(); return True
    def tick(self):
        if self.all_future and self.all_future.done():
            try:self.all_usage=self.all_future.result();self.draw()
            except Exception:self.all_usage['issues']=['暂时无法读取全部用量']
            self.all_future=None
        if not self.test and self.all_future is None and time.monotonic()-self.last_all>=.5:
            self.last_all=time.monotonic();self.all_future=self.all_executor.submit(self.all_reader.poll)
        if self.future and self.future.done():
            try:self.accept(self.future.result())
            except Exception:self.snapshot=blank('AI');self.snapshot['error']='暂时无法读取用量';self.draw()
            self.future=None
        now=time.monotonic()
        if not self.test and not self.menu_open and self.future is None and now-self.last_poll>=1:
            self.last_poll=now
            self.future=self.executor.submit(self.read,self.generation,self.selected,self.auto,self.include_children)
        if self.visible and not self.menu_open and not self.drag:
            x,y=self.root.winfo_pointerxy();inside=self.root.winfo_rootx()<=x<self.root.winfo_rootx()+self.root.winfo_width() and self.root.winfo_rooty()<=y<self.root.winfo_rooty()+self.root.winfo_height()
            self.hover(inside,now)
        self.root.after(100,self.tick)
    def draw(self):
        c=self.canvas;c.delete('all');accent=COLORS.get(self.settings.get('accent','mint'),COLORS['mint'])
        def text(x,y,value,size=10,color='#99a7b2',anchor='nw'):
            c.create_text(x,y,text=value,font=('Microsoft YaHei UI',size),fill=color,anchor=anchor)
        if not self.expanded:
            c.create_oval(12,14,19,21,fill=accent,outline='')
            if self.auto and not self.selected: label='待识别对话'
            elif self.settings.get('compact')=='cost':label=pricing.label(self.snapshot.get('costTotal'))
            elif self.settings.get('compact','quota')=='quota':
                valid=[w for w in self.snapshot['windows'] if (w.get('resets') or float('inf'))>time.time()]
                label=f"额度 {min(100-w['used'] for w in valid):.0f}%" if valid else '额度待更新'
                if valid and time.time()-(date(self.snapshot.get('quotaUpdatedAt')) or 0)>300:label+='·旧'
            else:
                key=self.settings.get('compact','input');v=(self.snapshot.get('total') or {}).get(key)
                label=('累计入 ' if key=='input' else '累计出 ')+(formatted(v) if v is None or v<1000 else f'{v/1000:.1f}k')
            text(27,7,label,11,'#ffffff');return
        text(18,15,('AI' if self.overview else self.snapshot['sourceName'])+' 用量',15,'#ffffff');text(336,19,'已固定' if self.pinned else '点击固定',10,accent);text(420,19,'设置',10,accent)
        for x,label,active in [(16,'全部累计',self.overview),(248,'当前对话',not self.overview)]:
            c.create_rectangle(x,52,x+216,82,fill='#273139' if active else '#20262b',outline='')
            text(x+70,57,label,10,accent if active else '#99a7b2')
        if self.overview:
            text(18,99,'本机全部已接入记录',12,'#ffffff')
            text(18,125,all_usage.status(self.all_usage),10)
            text(18,158,'总 Token',11)
            text(462,154,all_usage.token_label(self.all_usage),17,accent,'ne')
            y=197
        else:
            c.create_rectangle(16,94,464,150,fill='#20262b',outline='')
            title=(self.selected or {}).get('title','等待识别当前对话')
            text(26,102,title[:44],11,'#ffffff')
            text(26,126,'自动跟随 · 仅确认当前任务后显示' if self.auto else '手动选择 · 已暂停自动跟随',9,accent)
            quota=self.snapshot['windows']; text(18,165,'套餐快照'+(' · '+self.snapshot['plan'] if self.snapshot.get('plan') else ''),10)
            y=191
            if not quota:text(18,y,'暂无套餐额度记录',11)
            else:
                for w in quota[:2]:
                    expired=w.get('resets') and w['resets']<=time.time();minutes=w.get('minutes',0)
                    label='每周' if minutes==10080 else f'{minutes//60} 小时' if minutes%60==0 else f'{minutes} 分钟'
                    text(18,y,label+'额度',11);text(458,y,'待更新' if expired else f"剩余 {max(0,100-w['used']):.0f}%",12,accent,'ne');y+=24
            y=251
        text(18,y,'TOKEN',9)
        if self.overview:text(462,y,'全部对话累计',9,anchor='ne')
        else:
            text(260,y,'任务合计',9,anchor='ne');text(360,y,'本轮',9,anchor='ne');text(462,y,'主任务最近',9,anchor='ne')
        y+=28
        metrics=self.settings.get('metrics',list(FIELDS))
        for k in metrics:
            if k not in FIELDS:continue
            text(18,y,LABELS[k],10)
            if self.overview:text(462,y,all_usage.value(self.all_usage,k),11,'#ffffff','ne')
            else:
                for key,x in [('total',260),('round',360),('last',462)]:text(x,y,formatted((self.snapshot.get(key) or {}).get(k)),10,'#ffffff','ne')
            y+=27
        total=(self.all_usage['total'] if self.overview else self.snapshot.get('total')) or {}
        rate=total.get('cached')/total['input']*100 if total.get('input') and total.get('cached') is not None and total['cached']<=total['input'] else None
        if self.overview and (self.all_usage['missing']['input'] or self.all_usage['missing']['cached']):rate=None
        text(18,y,'合计缓存命中',10);text(462,y,'—' if rate is None else f'{rate:.1f}%',10,anchor='ne');y+=32
        text(18,y,'API 估算 USD',10,accent)
        if self.overview:text(462,y,pricing.label(self.all_usage['cost']),12,accent,'ne')
        else:
            for key,x in [('costTotal',260),('costRound',360),('costLast',462)]:text(x,y,pricing.label(self.snapshot.get(key)),10,accent,'ne')
        y+=28
        text(18,y,'仅本机记录 · 未同步设备与已删除历史不在内' if self.overview else '官方 API 参考估算 · 非实际扣费',9);y+=26
        self.notes_y=y
        text(18,y,'▾ 收起说明' if self.notes_expanded else '▸ 展开说明',10,accent);y+=32
        if self.notes_expanded:
            for line in [pricing.BOOK.title+' · Standard 参考价','非实际扣费；+ ? 表示仅已知部分；明细见设置。','总 Token = 输入 + 输出；缓存、推理已包含。','— 表示未知；0 为上报值。每个任务只计一次。','按会话记录累计；分叉继承的历史可能重叠。' if self.overview else self.snapshot['scopeNote'][:48]]:
                text(18,y,line,9);y+=20
        status=(self.all_usage['issues'] or [all_usage.status(self.all_usage)])[0] if self.overview else self.snapshot['error'] or ('任务执行中' if self.snapshot['running'] else '等待下一轮')
        text(18,y,status[:48],9,accent);y+=22
        stamp=date(self.all_usage.get('updatedAt') if self.overview else self.snapshot.get('updatedAt'))
        text(462,y,'未上报' if stamp is None else f'{max(0,int(time.time()-stamp))} 秒前更新',8,anchor='ne')
    def press(self,event):
        if self.expanded and 52<=event.y<=82:
            self.preference('overview',event.x<240);return
        if self.expanded and self.notes_y<=event.y<=self.notes_y+26 and event.x<150:
            self.preference('notesExpanded',not self.notes_expanded);return
        if self.expanded and event.y<50 and event.x>=400:self.menu(event);return
        self.drag=(event.x_root,event.y_root,self.anchor);self.dragged=False
    def move(self,event):
        if not self.drag:return
        x,y,origin=self.drag
        if abs(event.x_root-x)+abs(event.y_root-y)>3:
            self.dragged=True;self.anchor=(origin[0]+event.x_root-x,origin[1]+event.y_root-y);self.geometry()
    def release(self,event):
        if not self.drag:return
        self.drag=None
        if self.dragged:self.save()
        else:self.pinned=not self.pinned;self.expand(self.pinned)
    def select(self,task):
        self.generation+=1;self.auto=False;self.selected=task;self.snapshot=blank('AI');self.last_poll=0;self.save();self.draw()
    def tray_menu(self):
        self.hidden=False;self.tray_visible=True;self.show(True)
        x,y=self.root.winfo_pointerxy();self.menu(SimpleNamespace(x_root=x,y_root=y))
    def menu(self,event):
        menu=tk.Menu(self.root,tearoff=False)
        def auto():
            self.auto=not self.auto;self.generation+=1;self.selected=None;self.snapshot=blank('AI');self.save();self.draw()
        menu.add_checkbutton(label='自动跟随当前对话',command=auto,variable=tk.BooleanVar(value=self.auto))
        def children():
            self.include_children=not self.include_children;self.generation+=1;self.last_poll=0;self.save()
        menu.add_checkbutton(label='汇总全部子代理',command=children,variable=tk.BooleanVar(value=self.include_children))
        def hide():self.hidden=True;self.tray_visible=False;self.show(False)
        menu.add_command(label='隐藏浮窗（从托盘恢复）',command=hide)
        tasks=tk.Menu(menu,tearoff=False)
        for task in self.catalog.tasks():tasks.add_command(label=f"[{task['source']}] {task['title'][:32]}",command=lambda t=task:self.select(t))
        menu.add_cascade(label='手动选择任务',menu=tasks)
        members=tk.Menu(menu,tearoff=False)
        for member in self.snapshot.get('members',[]):
            sub=tk.Menu(members,tearoff=False)
            for k in FIELDS:sub.add_command(label=f"{LABELS[k]}：{formatted((member.get('total') or {}).get(k))} · 本轮 {formatted((member.get('round') or {}).get(k))}",state='disabled')
            members.add_cascade(label=member['title'][:32],menu=sub)
        menu.add_cascade(label='查看各任务明细',menu=members)
        prices=tk.Menu(menu,tearoff=False)
        prices.add_command(label='全部累计：'+pricing.label(self.all_usage['cost']),state='disabled')
        for reason in self.all_usage['cost'].get('reasons',[]):prices.add_command(label=reason,state='disabled')
        for key,title in [('costTotal','任务合计'),('costRound','本轮'),('costLast','最近调用')]:
            value=self.snapshot.get(key)
            prices.add_command(label=title+'：'+pricing.label(value),state='disabled')
            for reason in (value or {}).get('reasons',[]):prices.add_command(label=reason,state='disabled')
        prices.add_command(label='Standard/全球；Claude写入5分钟；DeepSeek峰价',state='disabled')
        prices.add_command(label='不含工具、搜索、媒体、存储、税费及套餐扣费',state='disabled')
        prices.add_command(label='查看内置价目与来源',command=lambda:os.startfile(pricing.BUNDLED))
        def custom_prices():
            pricing.CUSTOM.parent.mkdir(parents=True,exist_ok=True)
            if not pricing.CUSTOM.exists():pricing.CUSTOM.write_bytes(pricing.BUNDLED.read_bytes())
            os.startfile(pricing.CUSTOM)
        prices.add_command(label='编辑自定义价目（重启生效）',command=custom_prices)
        menu.add_cascade(label='API 费用明细与价目',menu=prices)
        compact=tk.Menu(menu,tearoff=False)
        for key,label in [('quota','套餐剩余比例'),('input','累计输入'),('output','累计输出'),('cost','API 估算费用')]:
            compact.add_command(label=label,command=lambda k=key:self.preference('compact',k))
        menu.add_cascade(label='浮标显示内容',menu=compact)
        metrics=tk.Menu(menu,tearoff=False)
        for key in FIELDS:
            active=self.settings.get('metrics',list(FIELDS))
            def toggle(k=key):
                values=list(self.settings.get('metrics',list(FIELDS)))
                if k in values:values.remove(k)
                else:values.append(k)
                self.preference('metrics',values)
            metrics.add_checkbutton(label=LABELS[key],command=toggle,variable=tk.BooleanVar(value=key in active))
        menu.add_cascade(label='详情指标（重新勾选排到末尾）',menu=metrics)
        colors=tk.Menu(menu,tearoff=False)
        for key,label in [('mint','薄荷绿'),('blue','晴空蓝'),('rose','玫瑰粉')]:colors.add_command(label=label,command=lambda k=key:self.preference('accent',k))
        menu.add_cascade(label='强调颜色',menu=colors)
        def folder():self.catalog.adapter_dir.mkdir(parents=True,exist_ok=True);os.startfile(self.catalog.adapter_dir)
        menu.add_command(label='打开软件接入目录',command=folder);menu.add_separator();menu.add_command(label='退出用量浮窗',command=self.quit)
        self.menu_open=True
        try:menu.tk_popup(event.x_root,event.y_root)
        finally:menu.grab_release();self.menu_open=False;self.outside_since=time.monotonic()
    def preference(self,key,value):self.settings[key]=value;self.save();self.geometry();self.draw()
    def quit(self):self.tray.close();self.executor.shutdown(wait=False,cancel_futures=True);self.all_executor.shutdown(wait=False,cancel_futures=True);self.root.destroy()
    def ui_test(self,output):
        before=self.user32.GetForegroundWindow();checks={}
        self.show(True);self.root.update()
        style=self.user32.GetWindowLongPtrW(self.hwnd,-20)
        checks['noactivate_style']=bool(style&0x08000000)
        checks['tray_registered']=self.tray.added
        self.hover(True,0);checks['hover_delay']=not self.expanded
        self.hover(True,.31);self.root.update();checks['hover_expands']=self.expanded
        checks['foreground_unchanged']=before==self.user32.GetForegroundWindow()
        self.hover(False,.4);checks['leave_delay']=self.expanded
        self.hover(False,.91);checks['leave_collapses']=not self.expanded
        self.pinned=True;self.hover(False,2);checks['pin_expands']=self.expanded
        old=self.generation;self.generation+=1
        checks['late_result_rejected']=not self.accept((old,None,blank('AI'),None))
        checks['interactive_desktop']=bool(before)
        checks['packaged_price_catalog_loaded']=pricing.BOOK.document is not None and len(pricing.BOOK.document['models'])==50
        self.preference('overview',True);self.preference('notesExpanded',False)
        h=self.detail_height();checks['all_tab_rendered']=any(self.canvas.itemcget(i,'text')=='本机全部已接入记录' for i in self.canvas.find_all() if self.canvas.type(i)=='text')
        self.press(SimpleNamespace(x=30,y=self.notes_y+5));checks['notes_expand']=self.notes_expanded and self.detail_height()==h+100
        self.release(None);checks['notes_dont_toggle_pin']=self.pinned
        self.press(SimpleNamespace(x=30,y=self.notes_y+5));checks['notes_collapse']=not self.notes_expanded and self.detail_height()==h
        self.press(SimpleNamespace(x=300,y=65));checks['task_tab_preserved']=not self.overview
        self.snapshot['costTotal']=pricing.cost(1.2345);self.draw()
        checks['cost_row_rendered']=any(self.canvas.itemcget(i,'text')=='$1.2345' for i in self.canvas.find_all() if self.canvas.type(i)=='text')
        Path(output).write_text(json.dumps(checks,indent=2),encoding='utf-8')
        self.quit();return all(checks.values())

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--snapshot');parser.add_argument('--source',default='codex');parser.add_argument('--ui-test');parser.add_argument('--output');parser.add_argument('--list',action='store_true')
    args=parser.parse_args();catalog=Catalog()
    if args.list:print(json.dumps(catalog.tasks(),ensure_ascii=False));return
    if args.snapshot:
        task=next((t for t in catalog.tasks(args.source) if t['id']==args.snapshot),None)
        if not task:raise SystemExit('本地任务不存在')
        result=catalog.snapshot(task);result={k:v for k,v in result.items() if not k.startswith('_')}
        data=json.dumps(result,ensure_ascii=False,indent=2)
        if args.output:Path(args.output).write_text(data,encoding='utf-8')
        elif sys.stdout:print(data)
        return
    if sys.platform!='win32':raise SystemExit('此浮窗客户端需要 Windows；macOS 请使用原生 AppKit 版本。')
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    kernel.CreateMutexW.argtypes=[ctypes.c_void_p,wintypes.BOOL,wintypes.LPCWSTR];kernel.CreateMutexW.restype=wintypes.HANDLE
    mutex=kernel.CreateMutexW(None,False,'Local\\AIUsageFloat')
    if not args.ui_test and ctypes.get_last_error()==183:return
    app=FloatApp(test=bool(args.ui_test))
    if args.ui_test:raise SystemExit(0 if app.ui_test(args.ui_test) else 1)
    app.root.mainloop()

if __name__=='__main__':main()
