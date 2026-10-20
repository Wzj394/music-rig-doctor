<#
.SYNOPSIS
    音频链路体检。只读，不改任何设置。

.DESCRIPTION
    读引擎里的真实状态，然后按一组规则检查常见故障：

      · Voicemeeter 在不在跑
      · 主输出绑了哪个硬件设备
      · 硬件输入有没有接上
      · 有没有"双边监听"（回声的头号原因）
      · 有没有东西送给 B1（没有 = 会议/OBS 收不到）
      · 有没有东西送给 A1（没有 = 你自己听不到）
      · 总线是不是被压成单声道
      · 采样率是否读得到

.PARAMETER Json
    输出机器可读的 JSON。

.EXAMPLE
    pwsh -File tools/vm-doctor.ps1

.EXAMPLE
    # 给 Agent 用
    $d = pwsh -File tools/vm-doctor.ps1 -Json | ConvertFrom-Json
    $d.findings | Where-Object { $_.level -eq 'FAIL' }

.NOTES
    退出码：0 没有 FAIL / 1 有 FAIL / 2 Voicemeeter 没运行
#>
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_vmlib.ps1')

$findings = @()
function Add-Finding([string]$level, [string]$code, [string]$message, [string]$hint) {
    $script:findings += [pscustomobject]@{ level = $level; code = $code; message = $message; hint = $hint }
}
function Out-Line([string]$s) { if (-not $Json) { Write-Host $s } }

# ---------- 运行状态 --------------------------------------------------------
$procRunning = Test-VoicemeeterProcess
if (-not $procRunning) {
    $res = [pscustomobject]@{
        ok       = $false
        running  = $false
        findings = @([pscustomobject]@{
            level = 'FAIL'; code = 'VM_NOT_RUNNING'
            message = 'Voicemeeter 没在运行'
            hint = '启动 Voicemeeter（Banana / Potato）。它默认不会开机自启，建议做成启动项。'
        })
    }
    if ($Json) { $res | ConvertTo-Json -Depth 6 -Compress }
    else { Write-Host '✕ Voicemeeter 没在运行' -ForegroundColor Red; Write-Host '  它默认不会开机自启 —— 这可能是"昨天配好今天全没了"的原因。' -ForegroundColor Yellow }
    exit 2
}

if (-not (Connect-Voicemeeter)) {
    $res = [pscustomobject]@{
        ok = $false; running = $true
        findings = @([pscustomobject]@{ level = 'FAIL'; code = 'VM_NO_API'; message = '远程 API 无响应'; hint = '引擎可能还在初始化，等几秒再试。' })
    }
    if ($Json) { $res | ConvertTo-Json -Depth 6 -Compress } else { Write-Host '✕ 远程 API 无响应' -ForegroundColor Red }
    exit 1
}

try {
    Sync-VmParameters
    $info = Get-VmInfo
    $stripCount = Get-VmStripCount
    $busCount = Get-VmBusCount
    $hwCount = Get-VmHardwareInputCount

    # ★ 硬件/虚拟按固定布局划分，不看 device.name 是否为空
    $strips = @()
    for ($i = 0; $i -lt $stripCount; $i++) {
        $dev = Get-VmString "Strip[$i].device.name"
        $strips += [pscustomobject]@{
            index  = $i
            device = $dev
            kind   = if ($i -lt $hwCount) { 'hardware' } else { 'virtual' }
            A1 = Get-VmFloat "Strip[$i].A1"; B1 = Get-VmFloat "Strip[$i].B1"
            A2 = Get-VmFloat "Strip[$i].A2"; A3 = Get-VmFloat "Strip[$i].A3"
            B2 = Get-VmFloat "Strip[$i].B2"; Mono = Get-VmFloat "Strip[$i].Mono"
        }
    }
    $buses = @()
    for ($i = 0; $i -lt $busCount; $i++) {
        $buses += [pscustomobject]@{
            index = $i
            device = Get-VmString "Bus[$i].Device.name"
            mono = Get-VmFloat "Bus[$i].Mono"
        }
    }

    Out-Line ''
    Out-Line "Voicemeeter: $($info.typeName) $($info.version)"
    Out-Line ''

    # ---------- 检查 1：主输出设备 --------------------------------------
    $mainDev = ($buses | Where-Object { $_.index -eq 0 }).device
    if (-not $mainDev) {
        Add-Finding 'FAIL' 'NO_MAIN_DEVICE' 'A1 总线没有绑定硬件设备' '点 Voicemeeter 右上角 A1，选你的声卡（WDM 或 ASIO）。'
    } else {
        Add-Finding 'OK' 'MAIN_DEVICE' "A1 → $mainDev" ''
    }

    # ---------- 检查 2：硬件输入 ----------------------------------------
    $hw = @($strips | Where-Object { $_.kind -eq 'hardware' -and $_.device })
    if ($hw.Count -eq 0) {
        Add-Finding 'WARN' 'NO_HARDWARE_INPUT' '没有接上任何硬件输入' '麦克风/乐器没选设备，或声卡没连。'
    } else {
        Add-Finding 'OK' 'HARDWARE_INPUT' ("硬件输入: " + (($hw | ForEach-Object { "Strip[$($_.index)]=$($_.device)" }) -join ', ')) ''
    }

    # ---------- 检查 3：双边监听（回声的头号原因）------------------------
    # 硬件输入（通常是麦克风）如果 A1=1，说明软件在监听它。
    # 而声卡本身的 MIX 旋钮如果也在直通侧 —— 两路叠加 = 回声。
    $monitored = @($hw | Where-Object { $_.A1 -eq 1 })
    if ($monitored.Count -gt 0) {
        $names = ($monitored | ForEach-Object { "Strip[$($_.index)]" }) -join ', '
        Add-Finding 'WARN' 'DUAL_MONITOR_RISK' "$names 在监听自己（A1=1）" '如果声卡的 MIX 旋钮也在"直通"侧，同一路声音会走两条路、延迟不同 → 回声。必须二选一：要么关掉 A1 只留硬件直通，要么把 MIX 拧到 DAW 侧只留软件监听。'
    } else {
        Add-Finding 'OK' 'NO_SELF_MONITOR' '硬件输入都没有在软件侧监听自己' ''
    }

    # ---------- 检查 4：有没有东西送给 B1 -------------------------------
    $toB1 = @($strips | Where-Object { $_.B1 -eq 1 })
    if ($toB1.Count -eq 0) {
        Add-Finding 'FAIL' 'NOTHING_TO_B1' '没有任何通道送到 B1' '会议软件 / OBS / 直播读的都是 B1。B1 全空 = 对面听不到你，也录不到声音。'
    } else {
        Add-Finding 'OK' 'FEEDS_B1' ("送到 B1: " + (($toB1 | ForEach-Object { "Strip[$($_.index)]" }) -join ', ')) ''
    }

    # ---------- 检查 5：有没有东西送到 A1（你自己能不能听到）-----------
    $toA1 = @($strips | Where-Object { $_.A1 -eq 1 })
    if ($toA1.Count -eq 0) {
        Add-Finding 'FAIL' 'NOTHING_TO_A1' '没有任何通道送到 A1' '你自己会听不到任何声音。'
    } else {
        Add-Finding 'OK' 'FEEDS_A1' ("送到 A1: " + (($toA1 | ForEach-Object { "Strip[$($_.index)]" }) -join ', ')) ''
    }

    # ---------- 检查 6：总线单声道 --------------------------------------
    $monoBuses = @($buses | Where-Object { $_.mono -eq 1 })
    if ($monoBuses.Count -gt 0) {
        $names = ($monoBuses | ForEach-Object { "Bus[$($_.index)]" }) -join ', '
        Add-Finding 'WARN' 'BUS_MONO' "$names 被压成了单声道" '想要立体声就把总线上的 Mono 熄灭。注意：通道上的 Mono 和总线上的 Mono 是两回事。'
    } else {
        Add-Finding 'OK' 'STEREO_BUS' '总线都是立体声' ''
    }

    # ---------- 检查 7：B1 上有系统声音（通知音会漏）--------------------
    $virtualToB1 = @($strips | Where-Object { $_.kind -eq 'virtual' -and $_.B1 -eq 1 })
    if ($virtualToB1.Count -gt 1) {
        Add-Finding 'INFO' 'SYSTEM_SOUND_TO_B1' "有多条虚拟输入送到 B1（$($virtualToB1.Count) 条）" '如果其中一条承载 Windows 系统声音，微信/QQ 的通知音也会漏给参会者。介意的话关掉那条的 B1。'
    }

    # ---------- 汇总 ----------------------------------------------------
    $fails = @($findings | Where-Object { $_.level -eq 'FAIL' })
    $warns = @($findings | Where-Object { $_.level -eq 'WARN' })
    $oks = @($findings | Where-Object { $_.level -eq 'OK' })

    Out-Line ''
    foreach ($f in $findings) {
        $mark = switch ($f.level) { 'OK' { '✓' } 'FAIL' { '✕' } 'WARN' { '!' } default { 'i' } }
        Out-Line "  $mark  $($f.message)"
        if ($f.hint) { Out-Line "       → $($f.hint)" }
    }
    Out-Line ''
    Out-Line ("  结果：{0} 项正常 / {1} 项警告 / {2} 项失败" -f $oks.Count, $warns.Count, $fails.Count)

    if ($Json) {
        [pscustomobject]@{
            ok = ($fails.Count -eq 0)
            running = $true
            voicemeeter = $info
            strips = $strips
            buses = $buses
            findings = $findings
            summary = [pscustomobject]@{ ok = $oks.Count; warn = $warns.Count; fail = $fails.Count }
        } | ConvertTo-Json -Depth 6 -Compress
    }

    exit $(if ($fails.Count -gt 0) { 1 } else { 0 })
}
finally {
    Disconnect-Voicemeeter
}
