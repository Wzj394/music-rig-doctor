# music-rig-doctor

> **Diagnose and fix a music production audio chain: USB interface → Voicemeeter → DAW → meeting/OBS.**
> Includes the pitfalls nobody documents, and CLI tools an AI agent can drive.

**音乐制作 / 直播 / 录课的音频链路体检工具，外加一份没人告诉过你的踩坑清单。**

---

## 你是不是遇到了这些

- 敲麦克风有**回声**，拧声卡的 MIX 旋钮也没用
- 腾讯会议 / Zoom 里，**你自己听得见，对面听不见你**
- 延迟大得没法边弹边听
- **只有左边音箱响**，或者声音是扁的
- 改了 Voicemeeter 的路由，**读回来还是旧值**
- 一放 REAPER，某个采样器插件弹窗说「采样率变了，请重启」
- **重启电脑后，昨天配好的一切全没了**

这些我们全踩过，一条一条写在 [PITFALLS.md](PITFALLS.md) 里。

---

## 这个仓库是什么

```
一套可验证的音频链路配置方法
    + 三个能读、能写、能体检的工具
    + 一份踩坑清单
```

## 这个仓库不是什么

```
✗ 不是 Voicemeeter 教程（官方有文档）
✗ 不是 DAW 教程
✗ 不能替你做判断 —— 它只负责把真实状态读出来给你看
```

**为什么值得存在：** 这些坑单独搜，每条都要花一晚上。放在一起，就能互相解释。

---

## 目标链路

```
                    ┌──────────────────────┐
   声卡输入  ──ASIO──▶│      Voicemeeter      │
   (麦克风/乐器)      │                       │
                    │  ┌── A1 ──▶ 声卡输出 ──▶ 你的耳机/音箱
   DAW 输出 ──ASIO──▶│  │                    │
                    │  └── B1 ──▶ 虚拟输出 ──▶ 会议 / OBS / 直播
   系统声音 ──WDM───▶│                       │
                    └──────────────────────┘
```

**一句话记住：**

> **A1 是给你自己听的，B1 是给别人听的。**
> **所有"听不见 / 听得见但对面听不见"的问题，都是这两条总线接错了。**

---

## 快速开始

### 1. 先体检，别急着改

```powershell
pwsh -File tools/vm-doctor.ps1
```

它会读**引擎里的真实状态**（不是界面显示的状态），然后报告：

```
· Voicemeeter 是否在运行
· A1 绑定的是哪个硬件设备
· 每个通道的 A1 / B1 / Mono
· 采样率是否和声卡一致
· 有没有"单声道只在一边"的通道
```

### 2. 按场景套用预设

```powershell
# 录课/直播：麦克风只录不听，DAW 又听又录
pwsh -File tools/vm-route.ps1 -Preset presets/lecture.json

# 编曲：只听自己，全部关掉对外输出
pwsh -File tools/vm-route.ps1 -Preset presets/compose.json
```

**每个写入动作之后都会自动读回验证** —— 因为 Voicemeeter 的读值是缓存的，不验证等于没写。

### 3. 出问题了查清单

[PITFALLS.md](PITFALLS.md) —— 八条技术坑 + 两条「人的坑」，每条都是「现象 / 原因 / 解法 / 怎么验证」。

---

## 工具

| 工具 | 作用 | 会不会改东西 |
|---|---|---|
| `tools/vm-read.ps1` | 读出所有通道/总线的真实值，输出 JSON | 只读 |
| `tools/vm-route.ps1` | 按 preset 写路由，写完自动读回验证 | 会写 |
| `tools/vm-doctor.ps1` | 体检：运行状态、设备绑定、采样率、路由一致性 | 只读 |
| `tools/vm-autostart.ps1` | 开机用：启动引擎 → 等就绪 → 套用预设 → 写日志 | 会写 |

### 开机自动套用预设

**为什么需要：**Voicemeeter 会持久化「上次退出时的状态」，
但那不一定是你要的那套 —— 强杀进程、断电、或者上次调试到一半，
重启后拿到的就是那个半成品状态。

**把 preset 变成开机动作之后，配置就变成了文件（可以 diff、可以分享、可以回滚）：**

```powershell
# 先手动确认能跑
pwsh -File tools/vm-autostart.ps1 -Preset presets/lecture.json

# 再看 autostart.log：引擎就绪 → preset 已应用并验证通过
```

**装成开机自动跑（不需要管理员权限）** —— 在启动文件夹放一个 `.vbs`：

```vbs
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""<仓库路径>\tools\vm-autostart.ps1""", 0, False
```

```
启动文件夹：Win+R → shell:startup
```

> 别用计划任务（要管理员权限），也别用 .cmd（会闪黑框）。

### 给 Agent 的用法

**三个工具都输出 JSON，且不需要交互。** Agent 直接调就行：

```powershell
# 1. 先看现在是什么状态
$state = pwsh -File tools/vm-read.ps1 | ConvertFrom-Json

# 2. 判断哪里不对
if ($state.strips[0].A1 -eq 1) {
    # 麦克风在监听自己 → 这就是回声的来源
    pwsh -File tools/vm-route.ps1 -Preset presets/lecture.json
}
```

**为什么不做 MCP server：**

> Voicemeeter 只有 Windows，API 就是一个 DLL。
> 包一层 MCP 要装、要配、要维护，而 CLI 任何 Agent 都能调。
> 等真有人需要，再加薄包装 —— **接口能脚本化才是本质，MCP 只是可选的外壳。**

**工具依赖：** PowerShell 5.1+ / pwsh 7+，Windows，已安装 Voicemeeter。
调用的 DLL 是 `VoicemeeterRemote64.dll`，随 Voicemeeter 一起装。

---

## 范围

**第一版只做 Voicemeeter + 声卡。** 这是所有问题的交汇点。

**Roadmap（欢迎 PR）：**

```
□ OBS：obs-websocket 控制场景与录制（音频源去重已写进 PITFALLS 坑 8）
□ REAPER：读取 asio_driver / buffer / 采样率，检查输入监听
□ 会议软件：切换麦克风设备的自动化（目前只能手动）
□ VBAN：用 UDP 文本协议替代 DLL 调用（可以跨机器）
□ Linux/macOS：PipeWire / BlackHole 的等价方案
```

---

## 目录

```
README.md          你正在看的
PITFALLS.md        ★ 踩坑清单（最有价值的部分）
tools/
  _vmlib.ps1       共享的 API 封装（含 dirty flag 处理）
  vm-read.ps1      读真实状态
  vm-route.ps1     写路由 + 读回验证
  vm-doctor.ps1    体检
  vm-autostart.ps1 开机自动套用预设
presets/
  lecture.json     录课/直播
  compose.json     编曲
docs/
  chain.md         链路详解：为什么必须这样接
```

---

## 一句话原则

> **看不见的状态，等于不存在的状态。**
>
> Voicemeeter 的界面会骗你（按钮看着亮了、读值却是缓存）。
> 所以这个仓库里的每个工具，都先读、再写、再读回来验证。

---

## License

MIT
