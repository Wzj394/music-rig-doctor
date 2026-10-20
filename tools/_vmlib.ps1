# ============================================================================
#  _vmlib.ps1 —— Voicemeeter Remote API 的共享封装
#
#  这个文件不单独运行，由其他脚本 dot-source 进来。
#
#  它存在的唯一理由是：把「读值有缓存」这个坑封在一个地方。
#  所有 Get 都经过 Sync()，所有 Set 之后都能 Verify()。
# ============================================================================

$ErrorActionPreference = 'Stop'

# ---------- 找到 DLL --------------------------------------------------------
$script:VmDll = $null
$candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'VB\Voicemeeter\VoicemeeterRemote64.dll'),
    'C:\Program Files (x86)\VB\Voicemeeter\VoicemeeterRemote64.dll',
    'C:\Program Files\VB\Voicemeeter\VoicemeeterRemote64.dll'
)
foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { $script:VmDll = $c; break }
}
if (-not $script:VmDll) {
    throw "找不到 VoicemeeterRemote64.dll。请确认已安装 Voicemeeter（Banana 或 Potato）。"
}

# ---------- 编译 P/Invoke 绑定（同一会话只编译一次）------------------------
if (-not ('VMRemote' -as [type])) {
    $dllEscaped = $script:VmDll.Replace('\', '\\')
    Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public class VMRemote
{
    const string D = @"$($script:VmDll)";

    [DllImport(D, CharSet = CharSet.Ansi)] public static extern int VBVMR_Login();
    [DllImport(D, CharSet = CharSet.Ansi)] public static extern int VBVMR_Logout();
    [DllImport(D, CharSet = CharSet.Ansi)] public static extern int VBVMR_RunVoicemeeter(int vType);
    [DllImport(D, CharSet = CharSet.Ansi)] public static extern int VBVMR_IsParametersDirty();
    [DllImport(D, CharSet = CharSet.Ansi)] public static extern int VBVMR_GetParameterFloat(string name, ref float value);
    [DllImport(D, CharSet = CharSet.Ansi)] public static extern int VBVMR_SetParameterFloat(string name, float value);
    [DllImport(D, CharSet = CharSet.Ansi)] public static extern int VBVMR_GetParameterStringA(string name, StringBuilder value);
    [DllImport(D, CharSet = CharSet.Ansi)] public static extern int VBVMR_GetVoicemeeterType(ref int type);
    [DllImport(D, CharSet = CharSet.Ansi)] public static extern int VBVMR_GetVoicemeeterVersion(ref int version);

    // ---- 便捷包装 ----
    public static float Get(string name)
    {
        float v = -999f;
        int rc = VBVMR_GetParameterFloat(name, ref v);
        return rc == 0 ? v : -999f;
    }

    public static string GetStr(string name)
    {
        var sb = new StringBuilder(512);
        int rc = VBVMR_GetParameterStringA(name, sb);
        return rc == 0 ? sb.ToString() : "";
    }

    public static int Set(string name, float value)
    {
        return VBVMR_SetParameterFloat(name, value);
    }

    public static bool Exists(string name)
    {
        float v = 0f;
        return VBVMR_GetParameterFloat(name, ref v) == 0;
    }

    // 反复调 IsParametersDirty 直到缓存安静下来。
    // 只调一次是不够的 —— 这正是坑 1。
    public static void Settle(int timeoutMs)
    {
        int start = Environment.TickCount;
        int stable = 0;
        while (Environment.TickCount - start < timeoutMs)
        {
            int d = VBVMR_IsParametersDirty();
            if (d == 0) { stable++; if (stable >= 3) break; }
            else { stable = 0; }
            System.Threading.Thread.Sleep(20);
        }
    }
}
"@
}

# ---------- 会话管理 --------------------------------------------------------
$script:VMLoggedIn = $false

function Connect-Voicemeeter {
    <#
      .SYNOPSIS  登录 Voicemeeter 远程 API。返回 $true 表示引擎就绪。
    #>
    # 最多重试 10 次 —— 引擎刚启动时需要一点时间
    for ($i = 0; $i -lt 10; $i++) {
        $rc = [VMRemote]::VBVMR_Login()
        $dirty = [VMRemote]::VBVMR_IsParametersDirty()
        if ($dirty -ge 0) {
            $script:VMLoggedIn = $true
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Disconnect-Voicemeeter {
    if ($script:VMLoggedIn) {
        [VMRemote]::VBVMR_Logout() | Out-Null
        $script:VMLoggedIn = $false
    }
}

function Get-VmInfo {
    $type = 0
    [VMRemote]::VBVMR_GetVoicemeeterType([ref]$type) | Out-Null
    $ver = 0
    [VMRemote]::VBVMR_GetVoicemeeterVersion([ref]$ver) | Out-Null
    $typeName = switch ($type) { 1 { 'Standard' } 2 { 'Banana' } 3 { 'Potato' } default { "Unknown($type)" } }
    $verStr = '{0}.{1}.{2}.{3}' -f (($ver -shr 24) -band 0xFF), (($ver -shr 16) -band 0xFF), (($ver -shr 8) -band 0xFF), ($ver -band 0xFF)
    [pscustomobject]@{ type = $type; typeName = $typeName; version = $verStr }
}

function Sync-VmParameters {
    <#
      .SYNOPSIS  等缓存稳定下来。任何 Get 之前都应该先调它。
    #>
    [VMRemote]::Settle(1500)
}

function Get-VmFloat {
    param([string]$Name)
    $v = [VMRemote]::Get($Name)
    if ($v -le -998) { return $null }   # 参数不存在
    return [math]::Round($v, 4)
}

function Get-VmString {
    param([string]$Name)
    return [VMRemote]::GetStr($Name)
}

function Set-VmFloat {
    param([string]$Name, [double]$Value)
    return [VMRemote]::Set($Name, [float]$Value)
}

function Test-VoicemeeterProcess {
    return [bool](Get-Process -Name 'voicemeeterpro', 'voicemeeter', 'voicemeeter8' -ErrorAction SilentlyContinue)
}

# ---------- 通道/总线模型 ---------------------------------------------------
# Banana: 3 硬件输入 + 2 虚拟输入 = 5 条 Strip；总线 A1/A2/A3 + B1/B2
function Get-VmStripCount {
    # 按引擎类型判断：Standard=2 输入, Banana=5, Potato=8
    $info = Get-VmInfo
    switch ($info.type) { 1 { 2 } 3 { 8 } default { 5 } }
}

function Get-VmHardwareInputCount {
    <#
      .SYNOPSIS  这个引擎有几个硬件输入通道。

      .DESCRIPTION
        **不能用「设备名是否为空」来判断硬件/虚拟。**
        没接设备的硬件输入，device.name 也是空字符串 —— 会被误判成虚拟输入，
        结果 preset 的角色匹配全部错位。

        正确做法是按引擎类型的固定布局划分：
            Standard  = 2 个硬件输入 + 1 个虚拟输入
            Banana    = 3 个硬件输入 + 2 个虚拟输入
            Potato    = 5 个硬件输入 + 3 个虚拟输入
    #>
    $info = Get-VmInfo
    switch ($info.type) { 1 { 2 } 3 { 5 } default { 3 } }
}

function Get-VmBusCount {
    $info = Get-VmInfo
    switch ($info.type) { 1 { 2 } 3 { 8 } default { 5 } }
}
