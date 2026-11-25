# Claude Code 通知钩子。
# - SessionStart：记下会话所在的窗口（当时的前台窗口），供之后的通知指明要切回哪里。不发通知、不出声。
# - Stop / Notification：通知只静默写入 Windows 通知中心（不弹 Windows 横幅），由「岛仔」灵动岛显示横幅；
#   通知的 launch 属性带上目标窗口，岛仔据此在右侧留下常驻入口。提示音由本脚本播放。
# 由 ~/.claude/settings.json 的 hooks 以 powershell.exe -File 方式调用，stdin 是事件 JSON。
# 本文件含中文，必须保持「UTF-8 带 BOM」编码，否则 Windows PowerShell 5.1 会按 GBK 读成乱码。
$ErrorActionPreference = 'Stop'

# stdin 按 UTF-8 显式解码，避免中文在 GBK 控制台代码页下乱码。
$ms = New-Object System.IO.MemoryStream
[Console]::OpenStandardInput().CopyTo($ms)
$raw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
$h = $null
if ($raw) { try { $h = $raw | ConvertFrom-Json } catch { } }

function Get-Prop($o, [string]$name) {
    if ($null -ne $o -and ($o.PSObject.Properties.Name -contains $name)) { return [string]$o.$name }
    return ''
}
function Clean([string]$s, [int]$max) {
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt $max) { $s = $s.Substring(0, $max) + '...' }
    return $s
}

# ---- 会话窗口登记表：%LOCALAPPDATA%\ClaudeCodeNotify\sessions.json，会话 ID -> 窗口句柄 ----
$mapDir  = Join-Path $env:LOCALAPPDATA 'ClaudeCodeNotify'
$mapPath = Join-Path $mapDir 'sessions.json'

function Read-SessionMap {
    $map = @{}
    if (Test-Path -LiteralPath $mapPath) {
        try {
            $json = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json) { foreach ($p in $json.PSObject.Properties) { $map[$p.Name] = $p.Value } }
        } catch { }
    }
    return $map
}
function Add-WindowNative {
    if (-not ('ClaudeCodeNotify.Native' -as [type])) {
        Add-Type -Namespace ClaudeCodeNotify -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
'@
    }
}
function Save-SessionWindow {
    param([string]$sessionId)
    if (-not $sessionId) { return }
    Add-WindowNative
    $window = [ClaudeCodeNotify.Native]::GetForegroundWindow()
    if ($window -eq [IntPtr]::Zero) { return }
    # 统一记根窗口（GA_ROOT = 2），岛仔比较前台时用同一种取法。
    $root = [ClaudeCodeNotify.Native]::GetAncestor($window, 2)
    if ($root -ne [IntPtr]::Zero) { $window = $root }
    $map = Read-SessionMap
    $keep = @{}
    $cutoff = (Get-Date).AddDays(-30)
    foreach ($key in @($map.Keys)) {
        $at = $null
        try { $at = [datetime]::Parse([string]$map[$key].at) } catch { }
        if ($at -and $at -gt $cutoff) { $keep[$key] = $map[$key] }
    }
    $keep[$sessionId] = @{ window = [long]$window; at = (Get-Date).ToString('o') }
    try {
        [void](New-Item -ItemType Directory -Force -Path $mapDir)
        $json = $keep | ConvertTo-Json -Depth 4 -Compress
        $tmp = $mapPath + '.' + $PID + '.tmp'
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $mapPath -Force
    } catch { }
}
function Find-TerminalWindow {
    param([int]$ProcessId)
    # 只认 Windows Terminal 自己的顶层窗口类。.NET 的 MainWindowHandle 不可靠：会挑中输入法状态栏之类的临时窗口。
    if (-not ('ClaudeCodeNotify.Terminal' -as [type])) {
        Add-Type -Namespace ClaudeCodeNotify -Name Terminal -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
public delegate bool EnumWindowsProc(IntPtr h, IntPtr lp);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
public static IntPtr Find(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr lp) {
        uint id; GetWindowThreadProcessId(h, out id);
        if (id != pid || !IsWindowVisible(h) || GetWindow(h, 4) != IntPtr.Zero) return true;
        System.Text.StringBuilder c = new System.Text.StringBuilder(128); GetClassName(h, c, 128);
        if (c.ToString() == "CASCADIA_HOSTING_WINDOW_CLASS" && found == IntPtr.Zero) found = h;
        return true;
    }, IntPtr.Zero);
    return found;
}
'@
    }
    return [ClaudeCodeNotify.Terminal]::Find([uint32]$ProcessId)
}
function Find-SessionWindow {
    param([string]$sessionId)
    if ($sessionId) {
        $entry = (Read-SessionMap)[$sessionId]
        if ($entry -and [long]$entry.window -gt 0) { return [long]$entry.window }
    }
    # 没有登记（例如会话启动早于本钩子）：沿父进程链找 Windows Terminal 的窗口。
    # 同一个终端进程开着多个窗口时，这里取 Z 序最靠上的那个，无法区分是哪一个；正常情况下靠会话启动时的登记。
    $p = $PID
    for ($i = 0; $i -lt 8; $i++) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
        if (-not $proc -or -not $proc.ParentProcessId -or $proc.ParentProcessId -eq $p) { break }
        $p = $proc.ParentProcessId
        $parent = Get-Process -Id $p -ErrorAction SilentlyContinue
        if ($parent -and $parent.ProcessName -eq 'WindowsTerminal') {
            $terminal = Find-TerminalWindow ([int]$p)
            if ($terminal -ne [IntPtr]::Zero) { return [long]$terminal }
        }
    }
    return 0
}

$event  = Get-Prop $h 'hook_event_name'
if ($event -eq 'SessionStart') { Save-SessionWindow (Get-Prop $h 'session_id'); exit 0 }

$type   = Get-Prop $h 'notification_type'
$stamp  = Get-Date -Format 'HH:mm:ss'
$cwd    = Get-Prop $h 'cwd'
$where  = ''
if ($cwd) { $where = Clean (Split-Path $cwd -Leaf) 40 }
$head   = 'Claude Code'
$detail = ''
$sound  = 'Asterisk'

switch ($event) {
    'Stop' {
        $head   = 'Claude Code · 执行完成'
        $detail = Get-Prop $h 'last_assistant_message'
        $bg = @()
        if ($null -ne $h -and ($h.PSObject.Properties.Name -contains 'background_tasks') -and $null -ne $h.background_tasks) {
            $bg = @($h.background_tasks)
        }
        if ($bg.Count -gt 0) { $head = 'Claude Code · 本轮结束（仍有 ' + $bg.Count + ' 个后台任务在跑）' }
    }
    'Notification' {
        $sound  = 'Exclamation'
        $detail = Get-Prop $h 'message'
        if ($type -eq 'permission_prompt') { $head = 'Claude Code · 需要确认' }
        elseif ($type -eq 'idle_prompt') { $head = 'Claude Code · 等待输入' }
        else { $head = 'Claude Code · 需要注意' }
    }
    default {
        $head   = 'Claude Code · ' + $event
        $detail = Get-Prop $h 'message'
    }
}
$detail = Clean $detail 140
if (-not $detail) { $detail = '需要你看一眼' }

# 同一 tag 的通知会被新的替换，通知中心只留最新一条；时间戳保证岛仔不会把它当成重复内容。
# 小岛上的横幅只有一行，所以消息正文放最前，目录和时间放后面。
$title = $head
$body  = $detail
if ($where) { $body = $body + ' · ' + $where }
$body = $body + ' · ' + $stamp
$tag   = 'ccstop'
if ($event -eq 'Notification') { $tag = 'ccnote' }

# 通知带上目标窗口：岛仔据此在右侧留下常驻入口，点击切回这个窗口。查不到就不带，行为与没有入口时相同。
# 两种载体都带上：launch 属性（实测通知中心交回的对象读不到它）和正文末尾的标记（岛仔识别后会从显示里剔除）。
$focus = Find-SessionWindow (Get-Prop $h 'session_id')
$launch = ''
$textFocus = ''
if ($focus -gt 0) {
    $launch = ' launch="daozai-focus:' + $focus + ':Claude Code"'
    $textFocus = '<text>daozai-focus:' + $focus + ':Claude Code</text>'
}

# 用 ToastGeneric 模板：岛仔只读取这个模板里的文字。
$xmlText = '<toast' + $launch + ' duration="short"><visual><binding template="ToastGeneric"><text>' +
    [System.Security.SecurityElement]::Escape($title) + '</text><text>' +
    [System.Security.SecurityElement]::Escape($body) + '</text>' + $textFocus + '</binding></visual></toast>'

try {
    # 借用 Windows PowerShell 自己的应用标识发通知，岛仔上显示的来源是「Windows PowerShell」。
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($xmlText)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    $toast.Tag = $tag
    $toast.Group = 'ClaudeCode'
    # 只进通知中心（供灵动岛读取），不弹 Windows 横幅。
    $toast.SuppressPopup = $true
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
} catch { }

# 横幅被抑制后系统不再响铃，提示音在这里播放；等它播完再退出，否则会被掐断。
try { [System.Media.SystemSounds]::$sound.Play() } catch { }
Start-Sleep -Milliseconds 900
exit 0
