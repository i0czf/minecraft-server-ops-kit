#Requires -Version 5.1
# Capture Minecraft client window for spectator camera (player_view).
# Called by QQConsoleBridge. Do NOT use variable name $args (reserved).
param(
    [Parameter(Mandatory = $true)][string]$OutPng,
    [string]$OutMp4 = "",
    [string]$TitleMatch = "Minecraft",
    [int]$ClipSeconds = 4,
    [int]$SettleMs = 0,
    [int]$MaxWidth = 1280,
    [string]$ClientAreaOnly = "1"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$script:UseClientArea = ($ClientAreaOnly -ne "0" -and $ClientAreaOnly -ne "false")

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

public class PvCap {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr hInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int dwProcessId);
  [DllImport("user32.dll")] static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr hdcDest, int xDest, int yDest, int w, int h,
      IntPtr hdcSrc, int xSrc, int ySrc, int rop);
  [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr hdc);
  [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hdc);
  [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
  [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
  [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
  [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);

  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

  const int SRCCOPY = 0x00CC0020;
  const int SW_RESTORE = 9;
  const int SW_SHOW = 5;
  static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
  const uint SWP_NOMOVE = 0x0002;
  const uint SWP_NOSIZE = 0x0001;
  const uint SWP_SHOWWINDOW = 0x0040;

  public class Hit {
    public long Hwnd;
    public string Title;
    public string ClassName;
    public int W, H, L, T;
    public uint Pid;
    public bool Zoomed;
  }

  static PvCap() {
    try { SetProcessDPIAware(); } catch { }
  }

  public static List<Hit> FindWindows(string titlePattern) {
    var list = new List<Hit>();
    Regex rx = null;
    try {
      if (!string.IsNullOrWhiteSpace(titlePattern))
        rx = new Regex(titlePattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    } catch { rx = null; }

    EnumWindows((h, l) => {
      try {
        if (!IsWindowVisible(h) && !IsIconic(h)) return true;
        var tb = new StringBuilder(512);
        GetWindowText(h, tb, tb.Capacity);
        string title = tb.ToString();
        if (string.IsNullOrWhiteSpace(title)) return true;

        var cb = new StringBuilder(256);
        GetClassName(h, cb, cb.Capacity);
        string cls = cb.ToString();
        // ONLY GLFW game windows (never Notepad/Explorer whose path contains neoforge)
        if (!cls.Equals("GLFW30", StringComparison.OrdinalIgnoreCase)) return true;

        RECT r;
        if (!GetWindowRect(h, out r)) return true;
        int w = r.R - r.L, hh = r.B - r.T;
        bool sizeOk = (w >= 200 && hh >= 150) || IsIconic(h);
        if (!sizeOk) return true;

        bool titleHit = rx != null && rx.IsMatch(title);
        bool looksLikeMc = title.IndexOf("Minecraft", StringComparison.OrdinalIgnoreCase) >= 0
                        || title.IndexOf("NeoForge", StringComparison.OrdinalIgnoreCase) >= 0;
        bool glfwBig = (w >= 640 && hh >= 360) || IsIconic(h);
        if (!(titleHit || looksLikeMc || glfwBig)) return true;

        uint pid = 0;
        GetWindowThreadProcessId(h, out pid);
        list.Add(new Hit {
          Hwnd = h.ToInt64(), Title = title, ClassName = cls,
          W = w, H = hh, L = r.L, T = r.T, Pid = pid,
          Zoomed = IsZoomed(h)
        });
      } catch { }
      return true;
    }, IntPtr.Zero);

    list.Sort((a, b) => {
      int sa = Score(a), sb = Score(b);
      if (sa != sb) return sb.CompareTo(sa);
      return (b.W * b.H).CompareTo(a.W * a.H);
    });
    return list;
  }

  static int Score(Hit h) {
    int s = 0;
    string t = h.Title ?? "";
    if (t.IndexOf("NeoForge", StringComparison.OrdinalIgnoreCase) >= 0) s += 50;
    if (t.IndexOf("Minecraft", StringComparison.OrdinalIgnoreCase) >= 0) s += 40;
    if (h.Zoomed) s += 25;
    if (h.ClassName != null && h.ClassName.Equals("GLFW30", StringComparison.OrdinalIgnoreCase)) s += 30;
    if (h.W * h.H > 500000) s += 10;
    // Prefer multiplayer titles (CN/EN)
    if (t.IndexOf("Multiplayer", StringComparison.OrdinalIgnoreCase) >= 0) s += 15;
    if (t.Contains("多人")) s += 15;
    return s;
  }

  public static bool Focus(long hwndL) {
    IntPtr h = new IntPtr(hwndL);
    try { AllowSetForegroundWindow(-1); } catch { }
    if (IsIconic(h)) {
      ShowWindow(h, SW_RESTORE);
      System.Threading.Thread.Sleep(350);
    } else {
      ShowWindow(h, SW_SHOW);
    }
    // AttachThreadInput trick: otherwise SetForegroundWindow is often ignored
    IntPtr fg = GetForegroundWindow();
    uint cur = GetCurrentThreadId();
    uint fgPid, tgtPid;
    uint fgTid = GetWindowThreadProcessId(fg, out fgPid);
    uint tgtTid = GetWindowThreadProcessId(h, out tgtPid);
    try {
      if (fgTid != 0 && fgTid != cur) AttachThreadInput(cur, fgTid, true);
      if (tgtTid != 0 && tgtTid != cur) AttachThreadInput(cur, tgtTid, true);
      // ALT key trick unlocks foreground on modern Windows
      keybd_event(0x12, 0, 0, UIntPtr.Zero); // VK_MENU down
      keybd_event(0x12, 0, 2, UIntPtr.Zero); // VK_MENU up
      BringWindowToTop(h);
      SetForegroundWindow(h);
    } finally {
      if (tgtTid != 0 && tgtTid != cur) AttachThreadInput(cur, tgtTid, false);
      if (fgTid != 0 && fgTid != cur) AttachThreadInput(cur, fgTid, false);
    }
    System.Threading.Thread.Sleep(300);
    return GetForegroundWindow() == h || !IsIconic(h);
  }

  // clientAreaOnly: crop OS title bar / borders — only the game framebuffer region
  public static string Capture(long hwndL, string path, int maxW, bool clientAreaOnly) {
    IntPtr h = new IntPtr(hwndL);
    Bitmap bmp = null;
    bool topmost = false;
    try {
      Focus(hwndL);
      // Pin Minecraft above QQ/browser for the duration of the grab
      SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
      topmost = true;
      System.Threading.Thread.Sleep(350);

      int x, y, w, hh;
      if (!GetCaptureRect(h, clientAreaOnly, out x, out y, out w, out hh))
        return "GetCaptureRect failed";
      if (w < 64 || hh < 64)
        return "bad capture size " + w + "x" + hh;

      // BitBlt while TOPMOST — sees real game pixels (PrintWindow often fails on GLFW/OpenGL)
      bmp = CaptureScreenRegion(x, y, w, hh);
      if (bmp == null || IsMostlyBlack(bmp) || IsMostlyTitleBar(bmp)) {
        if (bmp != null) { bmp.Dispose(); bmp = null; }
        bmp = CapturePrintWindow(h, clientAreaOnly);
      }
      if (bmp == null)
        return "all capture methods failed";
      if (IsMostlyBlack(bmp))
        return "captured black frame (other virtual desktop / GPU blocked capture)";

      System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path));
      if (maxW > 0 && bmp.Width > maxW) {
        int nw = maxW;
        int nh = (int)Math.Round(bmp.Height * (maxW / (double)bmp.Width));
        using (var dst = new Bitmap(nw, nh, PixelFormat.Format32bppArgb))
        using (var g = Graphics.FromImage(dst)) {
          g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
          g.DrawImage(bmp, 0, 0, nw, nh);
          dst.Save(path, ImageFormat.Png);
        }
      } else {
        bmp.Save(path, ImageFormat.Png);
      }
      return null;
    } finally {
      if (topmost) {
        try {
          SetWindowPos(h, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        } catch { }
      }
      if (bmp != null) bmp.Dispose();
    }
  }

  public static bool GetCaptureRect(IntPtr h, bool clientAreaOnly, out int x, out int y, out int w, out int hh) {
    x = y = w = hh = 0;
    if (clientAreaOnly) {
      RECT cr;
      if (!GetClientRect(h, out cr)) return false;
      POINT pt; pt.X = 0; pt.Y = 0;
      if (!ClientToScreen(h, ref pt)) return false;
      x = pt.X; y = pt.Y;
      w = cr.R - cr.L; hh = cr.B - cr.T;
    } else {
      RECT wr;
      if (!GetWindowRect(h, out wr)) return false;
      x = wr.L; y = wr.T;
      w = wr.R - wr.L; hh = wr.B - wr.T;
    }
    // Clamp negative (maximized windows often report -6,-6 for chrome)
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { hh += y; y = 0; }
    if (w < 1 || hh < 1) return false;
    return true;
  }

  static Bitmap CaptureScreenRegion(int x, int y, int w, int h) {
    IntPtr hdcScreen = GetDC(IntPtr.Zero);
    if (hdcScreen == IntPtr.Zero) return null;
    IntPtr hdcMem = CreateCompatibleDC(hdcScreen);
    IntPtr hBmp = CreateCompatibleBitmap(hdcScreen, w, h);
    IntPtr old = SelectObject(hdcMem, hBmp);
    bool ok = BitBlt(hdcMem, 0, 0, w, h, hdcScreen, x, y, SRCCOPY);
    SelectObject(hdcMem, old);
    DeleteDC(hdcMem);
    ReleaseDC(IntPtr.Zero, hdcScreen);
    if (!ok) {
      DeleteObject(hBmp);
      return null;
    }
    Bitmap bmp = Image.FromHbitmap(hBmp);
    DeleteObject(hBmp);
    return bmp;
  }

  static Bitmap CapturePrintWindow(IntPtr h, bool clientAreaOnly) {
    RECT wr;
    if (!GetWindowRect(h, out wr)) return null;
    int ww = wr.R - wr.L, wh = wr.B - wr.T;
    if (ww < 10 || wh < 10) return null;
    using (var full = new Bitmap(ww, wh, PixelFormat.Format32bppArgb)) {
      using (var g = Graphics.FromImage(full)) {
        IntPtr hdc = g.GetHdc();
        try {
          // PW_RENDERFULLCONTENT = 2
          if (!PrintWindow(h, hdc, 2))
            PrintWindow(h, hdc, 0);
        } finally {
          g.ReleaseHdc(hdc);
        }
      }
      if (!clientAreaOnly)
        return (Bitmap)full.Clone();

      // Map client rect into window-bitmap coordinates
      POINT pt; pt.X = 0; pt.Y = 0;
      ClientToScreen(h, ref pt);
      RECT cr;
      GetClientRect(h, out cr);
      int cx = pt.X - wr.L;
      int cy = pt.Y - wr.T;
      int cw = cr.R - cr.L;
      int ch = cr.B - cr.T;
      if (cx < 0) cx = 0;
      if (cy < 0) cy = 0;
      if (cx + cw > ww) cw = ww - cx;
      if (cy + ch > wh) ch = wh - cy;
      if (cw < 64 || ch < 64)
        return (Bitmap)full.Clone();
      Rectangle crop = new Rectangle(cx, cy, cw, ch);
      return full.Clone(crop, PixelFormat.Format32bppArgb);
    }
  }

  static bool IsMostlyBlack(Bitmap bmp) {
    int step = Math.Max(1, Math.Min(bmp.Width, bmp.Height) / 32);
    int n = 0, dark = 0;
    for (int y = 0; y < bmp.Height; y += step)
      for (int x = 0; x < bmp.Width; x += step) {
        Color c = bmp.GetPixel(x, y);
        n++;
        if (c.R < 18 && c.G < 18 && c.B < 18) dark++;
      }
    return n > 0 && dark * 100 / n > 92;
  }

  // Detect "only title bar" mistake: top strip has UI gray/white, rest nearly empty/sky-uniform wrong crop
  static bool IsMostlyTitleBar(Bitmap bmp) {
    if (bmp.Height < 80) return true;
    if (bmp.Width > 400 && bmp.Height < 80) return true;
    return false;
  }

  // Heuristic: QQ / browser dark chrome often dominates when we accidentally capture the wrong layer
  static bool LooksLikeWrongApp(Bitmap bmp) {
    if (bmp == null || bmp.Width < 100) return false;
    // Sample corners: Minecraft grass/sky rarely has near-identical dark navy UI chrome in all 4 corners
    try {
      Color c0 = bmp.GetPixel(8, 8);
      Color c1 = bmp.GetPixel(bmp.Width - 9, 8);
      Color c2 = bmp.GetPixel(8, bmp.Height - 9);
      Color c3 = bmp.GetPixel(bmp.Width - 9, bmp.Height - 9);
      int darkCorners = 0;
      foreach (Color c in new Color[] { c0, c1, c2, c3 }) {
        // QQ dark theme ~ RGB 20-45
        if (c.R < 55 && c.G < 55 && c.B < 65 && Math.Abs(c.R - c.B) < 25) darkCorners++;
      }
      if (darkCorners >= 3) return true;
    } catch { }
    return false;
  }

  // Expose rect for ffmpeg
  public static string GetRectString(long hwndL, bool clientAreaOnly) {
    int x,y,w,h;
    if (!GetCaptureRect(new IntPtr(hwndL), clientAreaOnly, out x, out y, out w, out h))
      return null;
    if (w % 2 != 0) w--;
    if (h % 2 != 0) h--;
    return x + "," + y + "," + w + "," + h;
  }
}
"@

function Find-McWindow([string]$pattern) {
    $list = [PvCap]::FindWindows($pattern)
    if ($list -eq $null -or $list.Count -eq 0) {
        $procs = Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -match 'Minecraft' }
        foreach ($p in $procs) {
            return [pscustomobject]@{
                Hwnd  = [int64]$p.MainWindowHandle
                Title = $p.MainWindowTitle
            }
        }
        return $null
    }
    $best = $list[0]
    return [pscustomobject]@{
        Hwnd  = [int64]$best.Hwnd
        Title = [string]$best.Title
    }
}

function Find-Ffmpeg {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffmpeg.exe",
        "C:\ffmpeg\bin\ffmpeg.exe",
        "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe"
    )) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Record-Clip([object]$win, [string]$path, [int]$seconds, [bool]$clientArea) {
    $ff = Find-Ffmpeg
    if (-not $ff) { throw "ffmpeg not found" }
    $hwnd = [IntPtr][int64]$win.Hwnd
    # Pin game on top for the whole recording (gdigrab = desktop composite)
    Add-Type @"
using System; using System.Runtime.InteropServices;
public class PvTop {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int X, int Y, int cx, int cy, uint f);
  public static readonly IntPtr TOPMOST = new IntPtr(-1);
  public static readonly IntPtr NOTOPMOST = new IntPtr(-2);
  public const uint FLAGS = 0x0001 | 0x0002 | 0x0040; // NOSIZE|NOMOVE|SHOWWINDOW
}
"@ -ErrorAction SilentlyContinue
    [void][PvCap]::Focus([int64]$win.Hwnd)
    [void][PvTop]::SetWindowPos($hwnd, [PvTop]::TOPMOST, 0, 0, 0, 0, [PvTop]::FLAGS)
    try {
        Start-Sleep -Milliseconds 400
        $rect = [PvCap]::GetRectString([int64]$win.Hwnd, $clientArea)
        if (-not $rect) { throw "no rect for ffmpeg" }
        $parts = $rect.Split(',')
        $x = [int]$parts[0]; $y = [int]$parts[1]; $w = [int]$parts[2]; $h = [int]$parts[3]
        if ($w -gt 2560) { $w = 2560 }
        if ($h -gt 1440) { $h = 1440 }
        if ($w % 2 -ne 0) { $w-- }
        if ($h % 2 -ne 0) { $h-- }
        Write-Host "FFMPEG_RECT x=$x y=$y w=$w h=$h clientArea=$clientArea"
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        [void][PvCap]::Focus([int64]$win.Hwnd)
        $ffArgs = @(
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "gdigrab",
            "-framerate", "20",
            "-draw_mouse", "0",
            "-offset_x", "$x",
            "-offset_y", "$y",
            "-video_size", "${w}x${h}",
            "-t", "$seconds",
            "-i", "desktop",
            "-vf", "scale=min(960\,iw):-2",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "28",
            "-pix_fmt", "yuv420p",
            "-an",
            $path
        )
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & $ff @ffArgs 2>&1 | Out-Null
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        if ($code -ne 0 -or -not (Test-Path -LiteralPath $path)) {
            throw "ffmpeg failed exit=$code"
        }
    } finally {
        [void][PvTop]::SetWindowPos($hwnd, [PvTop]::NOTOPMOST, 0, 0, 0, 0, [PvTop]::FLAGS)
    }
}

# --- main ---
if ($SettleMs -gt 0) { Start-Sleep -Milliseconds $SettleMs }

Write-Host "SEARCH TitleMatch=$TitleMatch ClientAreaOnly=$($script:UseClientArea)"
$debugList = [PvCap]::FindWindows($TitleMatch)
Write-Host "FOUND count=$($debugList.Count)"
foreach ($d in $debugList) {
    Write-Host ("  hwnd={0} {1}x{2} zoomed={3} title={4}" -f $d.Hwnd, $d.W, $d.H, $d.Zoomed, $d.Title)
}

$win = Find-McWindow -pattern $TitleMatch
if (-not $win) {
    Write-Error "NO_MC_WINDOW TitleMatch=$TitleMatch. Keep the dedicated camera client window open."
    exit 2
}
Write-Host "USE hwnd=$($win.Hwnd) title=$($win.Title)"

try {
    $capErr = [PvCap]::Capture([int64]$win.Hwnd, $OutPng, $MaxWidth, $script:UseClientArea)
    if ($capErr) { throw $capErr }
    $sz = (Get-Item -LiteralPath $OutPng).Length
    if ($sz -lt 2000) { throw "png too small ($sz bytes)" }
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    try {
        $img = [System.Drawing.Image]::FromFile($OutPng)
        Write-Host "PNG_OK size=$sz dim=$($img.Width)x$($img.Height) title=$($win.Title)"
        $img.Dispose()
    } catch {
        Write-Host "PNG_OK size=$sz title=$($win.Title)"
    }
} catch {
    Write-Error "CAPTURE_FAIL $($_.Exception.Message)"
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($OutMp4) -and $ClipSeconds -gt 0) {
    try {
        Record-Clip -win $win -path $OutMp4 -seconds $ClipSeconds -clientArea $script:UseClientArea
        $vsz = (Get-Item -LiteralPath $OutMp4).Length
        Write-Host "MP4_OK size=$vsz seconds=$ClipSeconds"
    } catch {
        Write-Host "MP4_SKIP $($_.Exception.Message)"
    }
}

exit 0
