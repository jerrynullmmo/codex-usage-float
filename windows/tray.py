"""Small Win32 notification-area entry; no focus changes or background service."""
import ctypes
from ctypes import wintypes

class NotifyData(ctypes.Structure):
    _fields_=[('cbSize',wintypes.DWORD),('hWnd',wintypes.HWND),('uID',wintypes.UINT),('uFlags',wintypes.UINT),
              ('uCallbackMessage',wintypes.UINT),('hIcon',wintypes.HANDLE),('szTip',wintypes.WCHAR*128),
              ('dwState',wintypes.DWORD),('dwStateMask',wintypes.DWORD),('szInfo',wintypes.WCHAR*256),
              ('uVersion',wintypes.UINT),('szInfoTitle',wintypes.WCHAR*64),('dwInfoFlags',wintypes.DWORD),
              ('guidItem',ctypes.c_byte*16),('hBalloonIcon',wintypes.HANDLE)]

class Tray:
    def __init__(self,root,hwnd,callback):
        self.root=root;self.hwnd=hwnd;self.callback=callback
        self.user=ctypes.WinDLL('user32',use_last_error=True);self.shell=ctypes.WinDLL('shell32',use_last_error=True)
        self.user.LoadIconW.argtypes=[wintypes.HINSTANCE,ctypes.c_void_p];self.user.LoadIconW.restype=wintypes.HANDLE
        self.user.SetWindowLongPtrW.argtypes=[wintypes.HWND,ctypes.c_int,ctypes.c_ssize_t];self.user.SetWindowLongPtrW.restype=ctypes.c_ssize_t
        self.user.CallWindowProcW.argtypes=[ctypes.c_void_p,wintypes.HWND,wintypes.UINT,wintypes.WPARAM,wintypes.LPARAM];self.user.CallWindowProcW.restype=ctypes.c_ssize_t
        self.shell.Shell_NotifyIconW.argtypes=[wintypes.DWORD,ctypes.POINTER(NotifyData)];self.shell.Shell_NotifyIconW.restype=wintypes.BOOL
        self.data=NotifyData();self.data.cbSize=ctypes.sizeof(NotifyData);self.data.hWnd=hwnd;self.data.uID=1
        self.data.uFlags=1|2|4;self.data.uCallbackMessage=0x8001;self.data.hIcon=self.user.LoadIconW(None,32512)
        self.data.szTip='AI Usage Float - 点击打开设置';self.data.uVersion=0
        self.restart=self.user.RegisterWindowMessageW('TaskbarCreated')
        self.proc=ctypes.WINFUNCTYPE(ctypes.c_ssize_t,wintypes.HWND,wintypes.UINT,wintypes.WPARAM,wintypes.LPARAM)(self.message)
        self.old=self.user.SetWindowLongPtrW(hwnd,-4,ctypes.cast(self.proc,ctypes.c_void_p).value)
        self.added=self.add()
    def add(self):
        ok=bool(self.shell.Shell_NotifyIconW(0,ctypes.byref(self.data)))
        if ok:self.shell.Shell_NotifyIconW(4,ctypes.byref(self.data))
        return ok
    def message(self,hwnd,msg,wparam,lparam):
        if msg==self.restart:self.root.after(0,self.add)
        if msg==0x8001 and lparam in (0x0202,0x0205):self.root.after(0,self.callback)
        return self.user.CallWindowProcW(ctypes.c_void_p(self.old),hwnd,msg,wparam,lparam)
    def close(self):
        self.shell.Shell_NotifyIconW(2,ctypes.byref(self.data))
        self.user.SetWindowLongPtrW(self.hwnd,-4,self.old)
