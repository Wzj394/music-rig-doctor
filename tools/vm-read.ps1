<#
.SYNOPSIS
    读出 Voicemeeter 的**真实**状态，输出 JSON。

.DESCRIPTION
    只读，不修改任何东西。

    为什么需要这个工具：Voicemeeter 的界面上按钮亮不亮，和引擎里的真实值
    可能不一致；而 API 的读值又有缓存。这个脚本会先用 Settle() 把缓存刷干净
    再读，所以拿到的值和引擎一致。

.PARAMETER AutoStart
    Voicemeeter 没运行就顺手启动它。

.PARAMETER Pretty
    输出带缩进的 JSON（人看方便）。

.EXAMPLE
    pwsh -File tools/vm-read.ps1 -Pretty

.EXAMPLE
    # 给 Agent 用：取某个通道的 A1
    $s = pwsh -File tools/vm-read.ps1 | ConvertFrom-Json
    $s.strips[0].A1

.NOTES
    退出码：0 成功 / 2 Voicemeeter 没运行 / 3 引擎无响应
#>
[CmdletBinding()]
param(
    [switch]$AutoStart,
    [switch]$Pretty
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_vmlib.ps1')

function Write-Json($obj) {
    if ($Pretty) { $obj | ConvertTo-Json -Depth 6 }
    else { $obj | ConvertTo-Json -Depth 6 -Compress }
}

# ---------- Voicemeeter 在跑吗 ---------------------------------------------
if (-not (Test-VoicemeeterProcess)) {
    if ($AutoStart) {
        $exe = $null
        foreach ($c in @(
            (Join-Path ${env:ProgramFiles(x86)} 'VB\Voicemeeter\voicemeeterpro.exe'),
            'C:\Program Files (x86)\VB\Voicemeeter\voicemeeterpro.exe',
            'C:\Program Files (x86)\VB\Voicemeeter\voicemeeter.exe'
        )) { if ($c -and (Test-Path $c)) { $exe = $c; break } }

        if (-not $exe) {
            Write-Json ([pscustomobject]@{ ok = $false; running = $false; error = '找不到 voicemeeterpro.exe' })
            exit 2
        }
        Write-Verbose "启动 $exe"
        Start-Process $exe
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            if (Test-VoicemeeterProcess) { break }
        }
    } else {
        Write-Json ([pscustomobject]@{
            ok      = $false
            running = $false
            hint    = 'Voicemeeter 没在运行。加 -AutoStart 可自动启动。'
        })
        exit 2
    }
}

# ---------- 连上引擎 --------------------------------------------------------
if (-not (Connect-Voicemeeter)) {
    Write-Json ([pscustomobject]@{
        ok      = $false
        running = $true
        error   = 'Voicemeeter 进程在，但远程 API 无响应（引擎可能还在初始化）'
    })
    exit 3
}

try {
    # ★ 坑 1：读之前必须把缓存刷干净
    Sync-VmParameters

    $info = Get-VmInfo
    $stripCount = Get-VmStripCount
    $busCount = Get-VmBusCount
    $hwCount = Get-VmHardwareInputCount

    # ---------- 通道 --------------------------------------------------------
    $strips = @()
    $hwSeen = 0
    $virtSeen = 0
    for ($i = 0; $i -lt $stripCount; $i++) {
        $dev = Get-VmString "Strip[$i].device.name"
        # ★ 硬件/虚拟按固定布局划分，不看 device.name 是否为空（见 _vmlib.ps1 的说明）
        $isHw = ($i -lt $hwCount)
        $lbl = Get-VmString "Strip[$i].Label"
        if (-not $lbl) {
            if ($isHw) { $hwSeen++; $lbl = "input$hwSeen" } else { $virtSeen++; $lbl = "virtual$virtSeen" }
        }

        $strips += [pscustomobject]@{
            index  = $i
            label  = $lbl
            device = $dev
            kind   = if ($isHw) { 'hardware' } else { 'virtual' }
            A1     = Get-VmFloat "Strip[$i].A1"
            A2     = Get-VmFloat "Strip[$i].A2"
            A3     = Get-VmFloat "Strip[$i].A3"
            B1     = Get-VmFloat "Strip[$i].B1"
            B2     = Get-VmFloat "Strip[$i].B2"
            Mono   = Get-VmFloat "Strip[$i].Mono"
            Mute   = Get-VmFloat "Strip[$i].Mute"
            Gain   = Get-VmFloat "Strip[$i].Gain"
        }
    }

    # ---------- 总线 --------------------------------------------------------
    $buses = @()
    for ($i = 0; $i -lt $busCount; $i++) {
        $dev = Get-VmString "Bus[$i].Device.name"
        $buses += [pscustomobject]@{
            index  = $i
            device = $dev
            mono   = Get-VmFloat "Bus[$i].Mono"
            mute   = Get-VmFloat "Bus[$i].Mute"
            gain   = Get-VmFloat "Bus[$i].Gain"
        }
    }

    # ---------- 汇总 --------------------------------------------------------
    $out = [pscustomobject]@{
        ok          = $true
        running     = $true
        voicemeeter = $info
        strips      = $strips
        buses       = $buses
        summary     = [pscustomobject]@{
            hardwareInputs = @($strips | Where-Object { $_.kind -eq 'hardware' }).Count
            virtualInputs  = @($strips | Where-Object { $_.kind -eq 'virtual' }).Count
            mainDevice     = ($buses | Where-Object { $_.index -eq 0 }).device
            feedsA1        = @($strips | Where-Object { $_.A1 -eq 1 }).Count
            feedsB1        = @($strips | Where-Object { $_.B1 -eq 1 }).Count
        }
    }

    Write-Json $out
    exit 0
}
finally {
    Disconnect-Voicemeeter
}
