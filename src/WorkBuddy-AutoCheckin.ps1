<#
.SYNOPSIS
    WorkBuddy 每日自动签到小工具
.DESCRIPTION
    自动打开 WorkBuddy 的「Buddy 加油站」，用 Windows 自带 OCR 识别界面文字，
    定位「签到领积分」入口和「立即领取」按钮并模拟点击。
    已经签到时直接输出“今日已签到”，不会重复点击。
    无需安装任何第三方依赖（需要 Windows 10/11 + 简体中文 OCR 语言包）。
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\WorkBuddy-AutoCheckin.ps1 -DryRun
    只截图识别，不点击，检查工具能否正常工作。
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\WorkBuddy-AutoCheckin.ps1
    正常运行：打开 WorkBuddy 并自动签到。
#>
[CmdletBinding()]
param(
    # WorkBuddy 主程序路径
    [string]$WorkBuddyExe = "$env:LOCALAPPDATA\Programs\WorkBuddy\WorkBuddy.exe",
    # 日志文件路径，默认放在脚本同目录
    [string]$LogFile = "",
    # 头像坐标配置文件（校准后保存），默认放在脚本同目录
    [string]$ConfigFile = "",
    # 启动 WorkBuddy 后等待主窗口出现的秒数
    [int]$StartupTimeoutSec = 40,
    # 只识别不点击，用于测试
    [switch]$DryRun,
    # 保存调试截图到脚本同目录 debug\ 下
    [switch]$SaveScreens,
    # 校准模式：点击一次 WorkBuddy 左下角用户头像，保存坐标后退出
    [switch]$Calibrate
)

$ErrorActionPreference = "Stop"

if (-not $LogFile) {
    $LogFile = Join-Path $PSScriptRoot "workbuddy-checkin.log"
}
if (-not $ConfigFile) {
    $ConfigFile = Join-Path $PSScriptRoot "workbuddy-config.json"
}
$DebugDir = Join-Path $PSScriptRoot "debug"
if ($SaveScreens -and -not (Test-Path $DebugDir)) {
    New-Item -ItemType Directory -Path $DebugDir -Force | Out-Null
}
# ---------- Win32 API ----------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WbWin32 {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, int dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
}
"@

[void][WbWin32]::SetProcessDPIAware()

# ---------- 日志 ----------
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
}

# ---------- 屏幕截图 + Windows OCR ----------
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await-WinRt {
    param($WinRtTask, $ResultType)
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    return $netTask.Result
}

$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Storage.FileAccessMode, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapPixelFormat, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapAlphaMode, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]

function Get-OcrLines {
    param([string]$ImagePath)
    $file = Await-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($ImagePath)) ([Windows.Storage.StorageFile])
    $stream = Await-WinRt ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Await-WinRt ($decoder.GetSoftwareBitmapAsync([Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8, [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied)) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new("zh-Hans-CN"))
    if (-not $engine) {
        throw "系统没有可用的简体中文 OCR 引擎，请安装简体中文语言包"
    }
    $result = Await-WinRt ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
    $lines = New-Object System.Collections.ArrayList
    foreach ($line in $result.Lines) {
        $minX = [double]::MaxValue; $minY = [double]::MaxValue
        $maxX = [double]::MinValue; $maxY = [double]::MinValue
        foreach ($w in $line.Words) {
            $r = $w.BoundingRect
            if ($r.X -lt $minX) { $minX = $r.X }
            if ($r.Y -lt $minY) { $minY = $r.Y }
            if (($r.X + $r.Width) -gt $maxX) { $maxX = $r.X + $r.Width }
            if (($r.Y + $r.Height) -gt $maxY) { $maxY = $r.Y + $r.Height }
        }
        [void]$lines.Add([pscustomobject]@{
            Text = ($line.Text -replace "\s+", "")
            X = [math]::Round($minX)
            Y = [math]::Round($minY)
            W = [math]::Round($maxX - $minX)
            H = [math]::Round($maxY - $minY)
        })
    }
    return ,$lines
}

function Save-Screenshot {
    param([string]$Path)
    $sw = [WbWin32]::GetSystemMetrics(0)
    $sh = [WbWin32]::GetSystemMetrics(1)
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap($sw, $sh)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
    return $Path
}

function Get-ScreenOcrLines {
    $shot = Join-Path $env:TEMP ("wb-checkin-{0}.png" -f (Get-Date -Format "yyyyMMddHHmmssfff"))
    Save-Screenshot $shot | Out-Null
    try {
        $lines = Get-OcrLines $shot
        if ($SaveScreens) {
            Copy-Item $shot (Join-Path $DebugDir (Split-Path $shot -Leaf)) -Force
        }
        return ,$lines
    } finally {
        Remove-Item $shot -Force -ErrorAction SilentlyContinue
    }
}

function Find-OcrLine {
    param($Lines, [string]$Pattern)
    foreach ($line in $Lines) {
        if ($line.Text -match $Pattern) {
            return $line
        }
    }
    return $null
}

function Click-OcrLine {
    param($Line)
    $cx = [int]($Line.X + $Line.W / 2)
    $cy = [int]($Line.Y + $Line.H / 2)
    Write-Log "点击 ($cx, $cy) <- $($Line.Text)"
    Click-Point $cx $cy
}

function Click-Point {
    param([int]$X, [int]$Y)
    [void][WbWin32]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 150
    [WbWin32]::mouse_event(0x0002, 0, 0, 0, 0)  # LEFT DOWN
    Start-Sleep -Milliseconds 80
    [WbWin32]::mouse_event(0x0004, 0, 0, 0, 0)  # LEFT UP
    Start-Sleep -Milliseconds 200
}

function Assert-WorkBuddyWindow {
    $proc = Get-Process -Name "WorkBuddy" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object -First 1

    if (-not $proc) {
        if ($DryRun) {
            throw "WorkBuddy 没有主窗口（请先手动打开），DryRun 模式下不会自动启动"
        }
        if (-not (Test-Path $WorkBuddyExe)) {
            throw "找不到 WorkBuddy 程序: $WorkBuddyExe，请用 -WorkBuddyExe 指定路径"
        }
        Write-Log "启动 WorkBuddy: $WorkBuddyExe"
        Start-Process -FilePath $WorkBuddyExe | Out-Null
        $deadline = (Get-Date).AddSeconds($StartupTimeoutSec)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 1
            $proc = Get-Process -Name "WorkBuddy" -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne 0 } |
                Select-Object -First 1
            if ($proc) { break }
        }
        if (-not $proc) {
            throw "WorkBuddy 启动后 $StartupTimeoutSec 秒内没有出现主窗口"
        }
    }

    $hwnd = $proc.MainWindowHandle
    if ([WbWin32]::IsIconic($hwnd)) {
        [void][WbWin32]::ShowWindow($hwnd, 9)  # SW_RESTORE
    }
    [void][WbWin32]::ShowWindow($hwnd, 3)      # SW_MAXIMIZE
    Start-Sleep -Milliseconds 500
    [void](Assert-Foreground $hwnd)
    return $hwnd
}

function Assert-Foreground {
    param($Hwnd)
    for ($i = 1; $i -le 4; $i++) {
        if ([WbWin32]::GetForegroundWindow() -eq $Hwnd) { return $true }
        [void][WbWin32]::BringWindowToTop($Hwnd)
        [WbWin32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)   # Alt down（解除前台锁定）
        Start-Sleep -Milliseconds 60
        [WbWin32]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)   # Alt up
        Start-Sleep -Milliseconds 60
        [void][WbWin32]::SetForegroundWindow($Hwnd)
        Start-Sleep -Milliseconds 500
    }
    return ([WbWin32]::GetForegroundWindow() -eq $Hwnd)
}

function Get-AvatarPoint {
    param($Hwnd)
    if (Test-Path $ConfigFile) {
        try {
            $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            if ($cfg.avatarX -and $cfg.avatarY) {
                return @{ X = [int]$cfg.avatarX; Y = [int]$cfg.avatarY }
            }
        }
        catch {
            Write-Log "读取配置失败，改用默认位置: $_" "WARN"
        }
    }
    $r = New-Object WbWin32+RECT
    [void][WbWin32]::GetWindowRect($Hwnd, [ref]$r)
    return @{ X = $r.Left + 111; Y = $r.Bottom - 69 }
}

function Save-CalibrationPoint {
    param([string]$KeyX, [string]$KeyY, [int]$X, [int]$Y)
    $cfg = @{}
    if (Test-Path $ConfigFile) {
        try {
            $raw = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $raw.PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value }
        }
        catch {
            Write-Log "读取配置失败，将覆盖: $_" "WARN"
        }
    }
    $cfg[$KeyX] = $X
    $cfg[$KeyY] = $Y
    $cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Log "已保存坐标 ($X, $Y) -> $ConfigFile" "OK"
}

function Wait-CalibrationClick {
    Write-Log "请把鼠标移到「用户头像」上并点击（15 秒内）"
    Write-Host "等待点击... (15 秒超时)"
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if (([WbWin32]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0) {
            while ((([WbWin32]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0) -and ((Get-Date) -lt $deadline)) {
                Start-Sleep -Milliseconds 50
            }
            Start-Sleep -Milliseconds 120
            $pt = New-Object WbWin32+POINT
            [void][WbWin32]::GetCursorPos([ref]$pt)
            return @{ X = $pt.X; Y = $pt.Y }
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Invoke-AvatarCalibration {
    Write-Log "桌面端校准："
    $pt = Wait-CalibrationClick
    if ($pt) {
        Save-CalibrationPoint -KeyX "avatarX" -KeyY "avatarY" -X $pt.X -Y $pt.Y
        return $true
    }
    Write-Log "桌面端校准超时，未获取到点击" "WARN"
    return $false
}

function Get-CheckinState {
    param($Lines)
    $claim = Find-OcrLine $Lines "立即[领領]取|马上[领領]取|去[领領]取|待[领領]取|[领領]取\s*[\d,]+\s*积分"
    if ($claim) { return @{ Status = "claim"; Line = $claim } }
    $done = Find-OcrLine $Lines "今日已[领領]|[领領]取成功|签到成功|已签到|已[领領]\s*\d+\s*天"
    if ($done) { return @{ Status = "done"; Line = $done } }
    $entry = Find-OcrLine $Lines "签到[领領]积分|去签到"
    if ($entry) { return @{ Status = "entry"; Line = $entry } }
    $login = Find-OcrLine $Lines "^登录$|^微信登录$|^扫码登录$|^手机号登录$|^手机验证码登录$|^其他登录方式$|^邮箱登录$"
    if ($login) { return @{ Status = "login"; Line = $login } }
    return @{ Status = "none"; Line = $null }
}

function Complete-Checkin {
    param($State)
    if ($State.Status -eq "login") {
        Write-Log "检测到「$($State.Line.Text)」，请先在 WorkBuddy 客户端登录后再签到" "WARN"
        Write-Log "=== 结果: [桌面端] 未登录，签到失败 ===" "WARN"
        exit 1
    }
    if ($State.Status -eq "claim") {
        if ($DryRun) {
            Write-Log "检测到可签到按钮「$($State.Line.Text)」（DryRun，不点击）" "OK"
            Write-Log "=== 结果: [桌面端] 可签到 ===" "OK"
            exit 0
        }
        Write-Log "找到签到按钮「$($State.Line.Text)」，开始点击..."
        Click-OcrLine $State.Line
        Start-Sleep -Seconds 3
        $verifyLines = Get-ScreenOcrLines
        if (Find-OcrLine $verifyLines "今日已[领領]|[领領]取成功|签到成功|已签到|已[领領]\s*\d+\s*天") {
            Write-Log "=== 结果: [桌面端] 签到成功 ===" "OK"
            exit 0
        }
        Write-Log "点击后未在界面确认到签到成功，请用 -SaveScreens 查看截图或手动确认" "WARN"
        exit 1
    }
    if ($State.Status -eq "done") {
        Write-Log "检测到「$($State.Line.Text)」，今日已完成签到" "OK"
        Write-Log "=== 结果: [桌面端] 今日已签到 ===" "OK"
        exit 0
    }
    if ($State.Status -eq "entry") {
        if ($DryRun) {
            Write-Log "检测到签到入口「$($State.Line.Text)」（DryRun，不点击）" "OK"
            Write-Log "=== 结果: [桌面端] 入口可见，可签到 ===" "OK"
            exit 0
        }
        Write-Log "点击签到入口「$($State.Line.Text)」..."
        Click-OcrLine $State.Line
        Start-Sleep -Seconds 4
        $panelState = Get-CheckinState (Get-ScreenOcrLines)
        if ($panelState.Status -eq "none" -or $panelState.Status -eq "entry") {
            Write-Log "打开签到面板后仍未找到签到按钮，请用 -SaveScreens 查看截图" "WARN"
            exit 1
        }
        Complete-Checkin $panelState
    }
    Write-Log "未识别到签到相关元素，请确认 WorkBuddy 窗口未被遮挡、屏幕未锁屏" "WARN"
    Write-Log "若头像位置不对，可先运行: .\WorkBuddy-AutoCheckin.ps1 -Calibrate" "WARN"
    exit 1
}

# ---------- 主流程 ----------
try {
    if ($Calibrate) {
        Write-Log "=== WorkBuddy 桌面端头像坐标校准 ==="
        [void](Assert-WorkBuddyWindow)
        [void](Invoke-AvatarCalibration)
        Write-Log "=== 校准结束 ===" "OK"
        exit 0
    }
    Write-Log "=== WorkBuddy 自动签到开始（桌面端）==="

        $hwnd = Assert-WorkBuddyWindow
        $state = Get-CheckinState (Get-ScreenOcrLines)

        if ($state.Status -eq "none") {
            if ($DryRun) {
                Write-Log "当前界面未识别到签到元素（DryRun，不点头像）" "WARN"
                Write-Log "真实运行时将自动点击左下角用户头像展开签到入口" "WARN"
                exit 0
            }
            $pt = Get-AvatarPoint $hwnd
            $avatarOk = $false
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                Write-Log "尝试 $attempt/3 点击用户头像 ($($pt.X), $($pt.Y))..."
                [void](Assert-Foreground $hwnd)
                Click-Point $pt.X $pt.Y
                Start-Sleep -Seconds 2
                $state = Get-CheckinState (Get-ScreenOcrLines)
                if ($state.Status -ne "none") {
                    $avatarOk = $true
                    break
                }
            }
            if (-not $avatarOk) {
                Write-Log "点击头像后仍未识别到签到入口，请用 -Calibrate 校准头像坐标" "WARN"
                exit 1
            }
        }

    Complete-Checkin $state
}
catch {
    Write-Log "执行失败: $_" "ERROR"
    exit 1
}
