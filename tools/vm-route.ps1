<#
.SYNOPSIS
    按 preset 写入 Voicemeeter 路由，写完自动读回验证。

.DESCRIPTION
    这是这个仓库里唯一会**改东西**的工具（除非加 -DryRun）。

    流程固定为：读 → 写 → 等 → 再读 → 比对。
    任何一项不符，打印 MISMATCH 并以非零退出码结束 —— 因为
    「写了但没生效」是这个软件最容易骗人的地方（见 PITFALLS 坑 1）。

.PARAMETER Preset
    preset JSON 的路径。见 presets/ 目录。

.PARAMETER DryRun
    只计算要改什么，不真的写。

.PARAMETER Json
    输出机器可读的 JSON 结果（给 Agent 用）。

.EXAMPLE
    pwsh -File tools/vm-route.ps1 -Preset presets/lecture.json

.EXAMPLE
    pwsh -File tools/vm-route.ps1 -Preset presets/lecture.json -DryRun

.NOTES
    退出码：0 全部验证通过 / 2 Voicemeeter 没运行 / 4 有项目验证不符
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Preset,
    [switch]$DryRun,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_vmlib.ps1')

function Out-Line([string]$s) { if (-not $Json) { Write-Host $s } }

# ---------- 载入 preset -----------------------------------------------------
if (-not (Test-Path $Preset)) { throw "找不到 preset: $Preset" }
$cfg = Get-Content $Preset -Raw -Encoding UTF8 | ConvertFrom-Json

Out-Line "preset: $($cfg.name) —— $($cfg.description)"

# ---------- 连上引擎 --------------------------------------------------------
if (-not (Test-VoicemeeterProcess)) {
    if ($Json) { [pscustomobject]@{ ok = $false; error = 'Voicemeeter 没在运行' } | ConvertTo-Json -Compress }
    else { Write-Host '✕ Voicemeeter 没在运行' -ForegroundColor Red }
    exit 2
}
if (-not (Connect-Voicemeeter)) {
    if ($Json) { [pscustomobject]@{ ok = $false; error = '远程 API 无响应' } | ConvertTo-Json -Compress }
    else { Write-Host '✕ 远程 API 无响应' -ForegroundColor Red }
    exit 3
}

try {
    Sync-VmParameters
    $stripCount = Get-VmStripCount
    $busCount = Get-VmBusCount
    $hwCount = Get-VmHardwareInputCount

    # ---------- 读出通道清单（用于匹配）--------------------------------
    # ★ 硬件/虚拟按固定布局划分，不看 device.name 是否为空
    #   （没接设备的硬件输入 device.name 也是空，会被误判成虚拟输入）
    $strips = @()
    for ($i = 0; $i -lt $stripCount; $i++) {
        $dev = Get-VmString "Strip[$i].device.name"
        $strips += [pscustomobject]@{
            index  = $i
            device = $dev
            kind   = if ($i -lt $hwCount) { 'hardware' } else { 'virtual' }
        }
    }

    # ---------- 把 role 解析成通道下标 ----------------------------------
    $roleToIndex = @{}
    $used = @{}
    foreach ($role in $cfg.match.PSObject.Properties) {
        $roleName = $role.Name
        $m = $role.Value
        $pool = $strips
        if ($m.kind) { $pool = @($pool | Where-Object { $_.kind -eq $m.kind }) }
        if ($m.deviceContains) { $pool = @($pool | Where-Object { $_.device -like "*$($m.deviceContains)*" }) }

        $pick = $null
        $wantIdx = 0
        if ($null -ne $m.index) { $wantIdx = [int]$m.index }
        if ($pool.Count -gt $wantIdx) { $pick = $pool[$wantIdx] }

        if ($null -eq $pick) {
            Out-Line "  ⚠️ 角色 '$roleName' 没匹配到通道（kind=$($m.kind) index=$wantIdx）—— 跳过"
        } else {
            $roleToIndex[$roleName] = $pick.index
            $used[$pick.index] = $true
            Out-Line ("  角色 '{0}' → Strip[{1}] {2}" -f $roleName, $pick.index, $(if ($pick.device) { $pick.device } else { '(虚拟输入)' }))
        }
    }

    # ---------- 算出每个通道的目标值 ------------------------------------
    $targets = @{}
    for ($i = 0; $i -lt $stripCount; $i++) {
        $targets[$i] = @{ A1 = 0.0; A2 = 0.0; A3 = 0.0; B1 = 0.0; B2 = 0.0; Mono = 0.0 }
    }

    foreach ($roleName in $roleToIndex.Keys) {
        $idx = $roleToIndex[$roleName]
        $route = $cfg.routes.$roleName
        if ($null -eq $route) { continue }
        foreach ($btn in @('A1', 'A2', 'A3', 'B1', 'B2', 'Mono')) {
            if ($null -ne $route.$btn) { $targets[$idx][$btn] = [double]$route.$btn }
        }
    }

    # 未匹配的通道套用 _other
    if ($null -ne $cfg.routes._other) {
        foreach ($i in 0..($stripCount - 1)) {
            if ($used.ContainsKey($i)) { continue }
            foreach ($btn in @('A1', 'A2', 'A3', 'B1', 'B2', 'Mono')) {
                if ($null -ne $cfg.routes._other.$btn) { $targets[$i][$btn] = [double]$cfg.routes._other.$btn }
            }
        }
    }

    # ---------- 写 ------------------------------------------------------
    Out-Line ''
    Out-Line '写入:'
    $changes = @()
    foreach ($i in 0..($stripCount - 1)) {
        foreach ($btn in @('A1', 'A2', 'A3', 'B1', 'B2', 'Mono')) {
            $cur = Get-VmFloat "Strip[$i].$btn"
            $want = $targets[$i][$btn]
            if ($null -eq $cur) { continue }
            if ([math]::Abs($cur - $want) -gt 0.001) {
                $changes += [pscustomobject]@{ param = "Strip[$i].$btn"; from = $cur; to = $want }
                if (-not $DryRun) { Set-VmFloat "Strip[$i].$btn" $want | Out-Null }
                Out-Line ("  Strip[{0}].{1}  {2} → {3}" -f $i, $btn, $cur, $want)
            }
        }
    }

    # 总线 mono
    if ($null -ne $cfg.buses.mono) {
        for ($i = 0; $i -lt $busCount; $i++) {
            $cur = Get-VmFloat "Bus[$i].Mono"
            if ($null -eq $cur) { continue }
            if ([math]::Abs($cur - [double]$cfg.buses.mono) -gt 0.001) {
                $changes += [pscustomobject]@{ param = "Bus[$i].Mono"; from = $cur; to = [double]$cfg.buses.mono }
                if (-not $DryRun) { Set-VmFloat "Bus[$i].Mono" ([double]$cfg.buses.mono) | Out-Null }
                Out-Line ("  Bus[{0}].Mono  {1} → {2}" -f $i, $cur, $cfg.buses.mono)
            }
        }
    }

    if ($changes.Count -eq 0) { Out-Line '  （已经是目标状态，无需改动）' }

    if ($DryRun) {
        Out-Line ''
        Out-Line 'DryRun：没有真的写入。'
        $res = [pscustomobject]@{ ok = $true; dryRun = $true; preset = $cfg.name; changes = $changes }
        if ($Json) { $res | ConvertTo-Json -Depth 5 -Compress }
        exit 0
    }

    # ---------- 等缓存稳定，再读回来验证（★ 坑 1）-----------------------
    Out-Line ''
    Out-Line '验证:'
    Sync-VmParameters

    $mismatches = @()
    foreach ($i in 0..($stripCount - 1)) {
        foreach ($btn in @('A1', 'A2', 'A3', 'B1', 'B2', 'Mono')) {
            $want = $targets[$i][$btn]
            $got = Get-VmFloat "Strip[$i].$btn"
            if ($null -eq $got) { continue }
            if ([math]::Abs($got - $want) -gt 0.001) {
                $mismatches += [pscustomobject]@{ param = "Strip[$i].$btn"; expected = $want; actual = $got }
            }
        }
    }
    for ($i = 0; $i -lt $busCount; $i++) {
        if ($null -eq $cfg.buses.mono) { break }
        $want = [double]$cfg.buses.mono
        $got = Get-VmFloat "Bus[$i].Mono"
        if ($null -eq $got) { continue }
        if ([math]::Abs($got - $want) -gt 0.001) {
            $mismatches += [pscustomobject]@{ param = "Bus[$i].Mono"; expected = $want; actual = $got }
        }
    }

    if ($mismatches.Count -eq 0) {
        Out-Line '  ✅ 全部符合目标状态'
        $res = [pscustomobject]@{ ok = $true; preset = $cfg.name; changes = $changes; mismatches = @() }
        if ($Json) { $res | ConvertTo-Json -Depth 5 -Compress }
        exit 0
    } else {
        foreach ($m in $mismatches) {
            Out-Line ("  ✕ {0}  期望={1} 实际={2}" -f $m.param, $m.expected, $m.actual) 
        }
        $res = [pscustomobject]@{ ok = $false; preset = $cfg.name; changes = $changes; mismatches = $mismatches }
        if ($Json) { $res | ConvertTo-Json -Depth 5 -Compress }
        exit 4
    }
}
finally {
    Disconnect-Voicemeeter
}
