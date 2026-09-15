using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Automation;
class FocusProbe {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    static List<string> titles = new List<string>();
    static int budget = 80;
    static Stopwatch watch = Stopwatch.StartNew();
    static void Visit(AutomationElement element, int depth) {
        if (element == null || depth > 8 || --budget <= 0 || watch.ElapsedMilliseconds > 500) return;
        if (element.Current.ControlType == ControlType.Document) {
            // Only document title; never descend into conversation text or embedded content.
            titles.Add(element.Current.Name); return;
        }
        var walker = TreeWalker.ControlViewWalker;
        for (var child = walker.GetFirstChild(element); child != null; child = walker.GetNextSibling(child)) {
            Visit(child,depth+1);
            if (budget <= 0 || watch.ElapsedMilliseconds > 500) break;
        }
    }
    static void Main() {
        var hwnd = GetForegroundWindow(); uint pid; GetWindowThreadProcessId(hwnd,out pid);
        string process = "";
        try { process = Process.GetProcessById((int)pid).ProcessName; } catch {}
        var title = new StringBuilder(1024); GetWindowText(hwnd,title,title.Capacity);
        titles.Add(title.ToString());
        // UI Automation is used only for Codex; multiple document names are not accepted.
        if (process.Equals("Codex",StringComparison.OrdinalIgnoreCase) || process.Equals("ChatGPT",StringComparison.OrdinalIgnoreCase)) {
            try {
                var docs = titles; titles = new List<string>();
                Visit(AutomationElement.FromHandle(hwnd),0);
                if (titles.Count == 1 && budget > 0 && watch.ElapsedMilliseconds <= 500) docs.Add(titles[0]);
                titles = docs;
            } catch { titles.Clear(); }
        }
        Console.OutputEncoding = Encoding.UTF8;
        Console.Write(new JavaScriptSerializer().Serialize(new { process=process, titles=titles, hwnd=hwnd.ToInt64() }));
    }
}
