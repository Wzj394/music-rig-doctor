<#
.SYNOPSIS
    开机自启用：启动 Voicemeeter → 等引擎就绪 → 套用 preset → 写日志。

.DESCRIPTION
    为什么需要这个：Voicemeeter 会持久化"上次退出时的状态"，
    但那不一定是你要的那套 —— 强杀进程、断电、或者上次调试到一半，
    重启后拿到的就是那个半成品状态。

    把 preset 变成开机动作之后，配置就变成了**文件**：
    可以进 git、可以 diff、可以分享，而不是"我记得上次怎么点的"。

.PARAMETER Preset
    preset JSON 路径。默认 ../presets/lecture.json

.PARAMETER WaitSeconds
    最多等多少秒让引擎就绪。慢机器可以调大。

.PARAMETER LogFile
    日志路径。默认仓库根目录的 autostart.log

.PARAMETER NoLaunch
    不主动启动 Voicemeeter，只等它自己出现（当它已经有独立的启动项时用这个）。

.EXAMPLE
    pwsh -File tools/vm-autostart.ps1 -Preset presets/lecture.json

.NOTES
    退出码：0 成功 / 2 引擎没等到 / 4 preset 应用后验证不符
#>
[CmdletBinding()]
param(
    [string]$Preset,
    [int]$WaitSeconds = 90,
    [string]$LogFile,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

# ⚠️ PowerShell 5.1 的坑：$PSScriptRoot 在 param() 的默认值里是空的，
#    必须在脚本体里才拿得到。所以默认值在这里补，不能写在 param 里。
if (-not $PSBoundParameters.ContainsKey('Preset')) {
    $Preset = Join-Path $PSScriptRoot '..\presets\lecture.json'
}
if (-not $PSBoundParameters.ContainsKey('LogFile')) {
    $LogFile = Join-Path $PSScriptRoot '..\autostart.log'
}
$Preset = [System.IO.Path]::GetFullPath($Preset)
$LogFile = [System.IO.Path]::GetFullPath($LogFile)

function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

Write-Log "===== 开机自启开始 ====="
Write-Log "preset = $Preset"

if (-not (Test-Path $Preset)) {
    Write-Log "✕ 找不到 preset：$Preset"
    exit 4
}

# ---------- 1. 确保 Voicemeeter 在跑 ---------------------------------------
. (Join-Path $PSScriptRoot '_vmlib.ps1')

$running = Test-VoicemeeterProcess
if (-not $running -and -not $NoLaunch) {
    $exe = $null
    foreach ($c in @(
        (Join-Path ${env:ProgramFiles(x86)} 'VB\Voicemeeter\voicemeeterpro.exe'),
        'C:\Program Files (x86)\VB\Voicemeeter\voicemeeterpro.exe',
        'C:\Program Files (x86)\VB\Voicemeeter\voicemeeter.exe'
    )) { if ($c -and (Test-Path $c)) { $exe = $c; break } }

    if (-not $exe) {
        Write-Log '✕ 找不到 voicemeeterpro.exe'
        exit 2
    }
    Write-Log "启动 $exe"
    Start-Process $exe
}

# ---------- 2. 等引擎就绪 ---------------------------------------------------
# 开机时音频服务可能还没起，所以这里必须轮询而不是死等固定秒数
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$ready = $false
$attempt = 0
while ((Get-Date) -lt $deadline) {
    $attempt++
    if (-not (Test-VoicemeeterProcess)) {
        Start-Sleep -Seconds 1
        continue
    }
    if (Connect-Voicemeeter) {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 1
}

if (-not $ready) {
    Write-Log "✕ 等了 $WaitSeconds 秒，Voicemeeter 引擎仍未就绪（尝试 $attempt 次）"
    Disconnect-Voicemeeter
    exit 2
}
Write-Log "✅ 引擎就绪（第 $attempt 次尝试）"
Disconnect-Voicemeeter

# ---------- 3. 套用 preset --------------------------------------------------
# 直接复用 vm-route.ps1：它自带"写 → 等 → 读回 → 比对"
$routeScript = Join-Path $PSScriptRoot 'vm-route.ps1'
$out = & $routeScript -Preset $Preset 2>&1 | Out-String
$code = $LASTEXITCODE

foreach ($line in ($out -split "`r?`n")) {
    if ($line.Trim()) { Write-Log "  $line" }
}

if ($code -eq 0) {
    Write-Log '✅ preset 已应用并验证通过'
} else {
    Write-Log "✕ preset 应用后验证不符（退出码 $code）"
}
Write-Log '===== 开机自启结束 ====='
exit $code
