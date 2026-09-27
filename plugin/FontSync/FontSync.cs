// FontSync: an AffinityPluginLoader plugin that keeps the fonts listed in a
// text file (AI_FONTS_LIST, one Unix path per line) loaded into Affinity.
//
// Affinity rebuilds its font list from GDI when it receives WM_FONTCHANGE.
// Under Wine the GDI font table is per process, so fonts registered from
// outside (registry, windows\Fonts, AddFontResource in another process) are
// invisible to a running Affinity. This plugin runs inside Affinity: it adds
// and removes the listed fonts with AddFontResourceEx/RemoveFontResourceEx and
// then broadcasts WM_FONTCHANGE, so changes show up without a restart.
//
// Written in C# 5 so it builds with the csc.exe of .NET Framework 4.8.
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using AffinityPluginLoader;

[assembly: AssemblyTitle("FontSync")]
[assembly: AssemblyProduct("FontSync")]
[assembly: AssemblyDescription("Loads the fonts enabled in Affinity Infinity and applies changes live")]
[assembly: AssemblyCompany("Affinity Infinity")]
[assembly: AssemblyVersion("0.1.0")]

namespace AffinityInfinity.FontSync
{
    public class FontSyncPlugin : AffinityPlugin
    {
        const string ListEnv = "AI_FONTS_LIST";
        const int PollMs = 1000;
        const uint WM_FONTCHANGE = 0x001D;
        static readonly IntPtr HWND_BROADCAST = (IntPtr)0xffff;

        [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
        static extern int AddFontResourceExW(string path, uint flags, IntPtr reserved);

        [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
        static extern bool RemoveFontResourceExW(string path, uint flags, IntPtr reserved);

        [DllImport("user32.dll")]
        static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);

        // Loaded fonts: Windows path -> file modification time when it was added.
        readonly Dictionary<string, DateTime> loaded = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);
        readonly object gate = new object();
        IPluginContext context;
        string listPath;
        DateTime listWrite = DateTime.MinValue;

        public override void OnLoad(IPluginContext ctx)
        {
            context = ctx;
            string unixPath = Environment.GetEnvironmentVariable(ListEnv);
            if (string.IsNullOrEmpty(unixPath))
            {
                context.Log(ListEnv + " is not set; nothing to do");
                return;
            }
            listPath = ToWindowsPath(unixPath);
            context.Log("watching " + listPath);
            // Affinity has not built its font list yet, so no notification is needed.
            Sync(false);
            Thread watcher = new Thread(Watch);
            watcher.IsBackground = true;
            watcher.Name = "FontSync";
            watcher.Start();
        }

        void Watch()
        {
            for (;;)
            {
                Thread.Sleep(PollMs);
                try
                {
                    Sync(true);
                }
                catch (Exception e)
                {
                    context.LogError("sync failed", e);
                }
            }
        }

        void Sync(bool notify)
        {
            lock (gate)
            {
                DateTime write = File.Exists(listPath) ? File.GetLastWriteTimeUtc(listPath) : DateTime.MinValue;
                bool listChanged = write != listWrite;
                listWrite = write;

                Dictionary<string, DateTime> wanted = listChanged ? ReadList() : null;
                if (listChanged)
                    context.Log("font list: " + wanted.Count + " fonts");
                bool changed = false;

                foreach (string path in new List<string>(loaded.Keys))
                {
                    DateTime mtime = FileTime(path);
                    bool keep = listChanged ? wanted.ContainsKey(path) : mtime != DateTime.MinValue;
                    if (keep && mtime == loaded[path])
                        continue;
                    // Removed from the list, deleted, or rebuilt in place (re-added below).
                    RemoveFontResourceExW(path, 0, IntPtr.Zero);
                    loaded.Remove(path);
                    changed = true;
                    context.Log("removed " + path);
                    if (keep && !listChanged)
                        Add(path, mtime);
                }

                if (listChanged)
                {
                    foreach (KeyValuePair<string, DateTime> font in wanted)
                    {
                        if (!loaded.ContainsKey(font.Key) && Add(font.Key, font.Value))
                            changed = true;
                    }
                }

                if (changed && notify)
                    PostMessageW(HWND_BROADCAST, WM_FONTCHANGE, IntPtr.Zero, IntPtr.Zero);
            }
        }

        bool Add(string path, DateTime mtime)
        {
            int faces = AddFontResourceExW(path, 0, IntPtr.Zero);
            if (faces == 0)
            {
                context.LogWarning("could not load " + path);
                return false;
            }
            loaded[path] = mtime;
            context.Log("added " + path + " (" + faces + " faces)");
            return true;
        }

        Dictionary<string, DateTime> ReadList()
        {
            Dictionary<string, DateTime> fonts = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);
            if (!File.Exists(listPath))
                return fonts;
            foreach (string raw in File.ReadAllLines(listPath))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#"))
                    continue;
                string path = ToWindowsPath(line);
                DateTime mtime = FileTime(path);
                if (mtime != DateTime.MinValue)
                    fonts[path] = mtime;
            }
            return fonts;
        }

        static DateTime FileTime(string path)
        {
            return File.Exists(path) ? File.GetLastWriteTimeUtc(path) : DateTime.MinValue;
        }

        // Wine maps the Unix root to drive Z:.
        static string ToWindowsPath(string unixPath)
        {
            return unixPath.StartsWith("/") ? "Z:" + unixPath.Replace('/', '\\') : unixPath;
        }
    }
}
