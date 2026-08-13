<p align="center">
  <img src="https://img.shields.io/badge/Node.js-18%2B-339933?logo=node.js&logoColor=white" alt="Node.js 18+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-22c55e" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/dependencies-0-0ea5e9" alt="Zero runtime dependencies">
</p>

<h1 align="center">Claude DeepSeek Vision Bridge</h1>

<p align="center">
  让使用纯文本 DeepSeek 的 Claude Code，也能直接识别粘贴图片、截图和本地图片。
</p>

<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="#给其他-ai-的一键安装指令">交给 AI 安装</a> ·
  <a href="#安全边界">安全边界</a> ·
  <a href="#故障排查">故障排查</a>
</p>

> 这是一个运行在本机的翻译层：它把请求中的图片交给视觉模型生成文字描述，再把文本化请求转发给原始 DeepSeek 上游。它不修改 DeepSeek 的模型能力，也不要求 CC Switch 把纯文本模型伪装成多模态模型。

## 它解决什么问题

当 CC Switch 将 Claude Code 路由到只接受文本的 DeepSeek 上游时，粘贴图片通常会导致请求被上游拒绝。这个桥只处理含图片的请求；无图片请求继续原样透传。

| 使用场景 | 入口 | 处理方式 |
| --- | --- | --- |
| Claude Code 直接粘贴图片或截图 | `vision-bridge.js` | 图片先由 StepFun Vision 描述，再转成文本发给 DeepSeek |
| Agent 已拿到本地图片路径或远程 URL | `vision.js` + Vision Skill | 手动调用视觉 API，返回文字描述 |
| Word、Excel 等文档 | Claude Code 对应内置 Skill | 继续走文档 Skill，不会被本桥改成 OCR 流程 |

```mermaid
flowchart LR
    CC["Claude Code"] -->|"ANTHROPIC_BASE_URL = 127.0.0.1:15721"| S["CC Switch local proxy"]
    S -->|"active provider target = 127.0.0.1:15720"| B["Vision Bridge"]
    B -->|"含图片请求"| V["StepFun<br/>Step 3.7 Flash"]
    V -->|"图片文字描述"| B
    B -->|"文本化请求"| D["原始 DeepSeek 上游"]
    B -->|"无图片请求原样透传"| D
```

## 快速开始

需要：Windows、Node.js 18+、Git（如果使用 `git clone`）、Claude Code、CC Switch，以及一个可以访问的 DeepSeek 文本上游地址。

1. 准备 StepFun 的视觉 API Key 和原始 DeepSeek 上游 Base URL。
2. 选择下面一种安装方式：让其他 AI 按 README 执行，或手动安装；安装器不会猜测或自动填写原始上游地址。
3. 按安装流程完成环境变量、桥启动、CC Switch 路由和开机启动配置。
4. 确认 `http://127.0.0.1:15720/health`、`15721` 和最终图片请求都正常。

### 给其他 AI 的一键安装指令

不需要先手动下载仓库。把下面完整内容复制给 Claude Code、Codex 或其他能够访问 GitHub、执行命令和修改本机配置的 AI。尖括号中的内容只在私聊中替换；不要把真实 API Key 发到公开聊天、截图或 Git 仓库。

> **网络环境提醒：** 如果你所在的电脑已开启 Clash 代理，请注意下面的完整安装指令包含代理地址。使用者和 AI 都应先确认这句话是否适合当前电脑，避免误用他人的本地代理端口。

<details>
<summary>展开并复制完整安装指令</summary>

```text
请在这台 Windows 电脑的当前用户范围内全局安装并配置 Claude DeepSeek Vision Bridge（不是 npm 全局包，也不是系统级安装）：
https://github.com/R-R6/claude-deepseek-vision-bridge

这台电脑可能已开启 Clash 代理，地址是 127.0.0.1:7897。先检查当前电脑是否确实能访问这个代理；只有确认地址可用且访问 GitHub、npm、pip 等外网资源失败时，才临时使用 http://127.0.0.1:7897 重试。不要假设其他电脑有这个代理，也不要把它写入持久化配置。

如果确实需要代理，给当前下载/测试命令临时设置 `HTTP_PROXY` 和 `HTTPS_PROXY` 即可；不要写入 Windows 用户环境变量、仓库文件、CC Switch 配置或启动脚本。下载成功后清除当前进程中的代理变量，再继续本机桥配置。

请先完整阅读这个仓库的 README，再执行安装。不要根据猜测修改配置。
这是一次本机配置任务，不要修改仓库源码、不要执行 `npm install`、不要创建 `.env` 文件、不要提交或推送 Git 更改。
请把仓库克隆到一个新的工作目录；如果目标目录已经存在，先检查其远程地址和工作区状态，不要删除或覆盖其中的用户文件。

我的目标：在 Claude Code 使用纯文本 DeepSeek 模型时，可以直接粘贴图片并识别；如果我提供本地图片路径或远程图片 URL，也可以调用全局 Vision Skill。

视觉服务配置：
- 模型：阶跃星辰 Step 3.7 Flash
- Model ID：step-3.7-flash
- Base URL：https://api.stepfun.com/v1
- API Key：我已在本机用户级环境变量 `VISION_API_KEY` 中配置（只能检查是否存在，不得读取或回显）
- 如果该变量不存在，请先向我索要 API Key；收到后只写入当前 Windows 用户级环境变量，不得在命令输出、日志、截图、源码、README、CC Switch 备注或 Git 中回显。
- 如果必须由我现场提供 API Key，请使用不回显输入的安全提示，不要把真实值拼进命令行参数、PowerShell 历史或聊天记录。
- 如果 `VISION_BASE_URL` 或 `VISION_MODEL` 缺失，可按上面的非敏感固定值写入当前 Windows 用户级环境变量；如果 `BRIDGE_HOST` 或 `BRIDGE_PORT` 缺失，使用 `127.0.0.1` 和 `15720`。这些变量写入后要刷新启动桥的进程环境。
- 默认个人电脑不要主动创建 `BRIDGE_AUTH_TOKEN`。如果这台电脑已经设置了它，不要删除或回显；必须同时确认 CC Switch 能为发往桥的请求注入 `x-bridge-token`，否则会出现 `401`。

文本模型路由：
- 我使用 CC Switch 管理 Claude Code 路由。
- 原始 DeepSeek 上游 Base URL：<修改 CC Switch 前的真实上游地址>
- Vision Bridge 本地地址：http://127.0.0.1:15720
- Claude Code 到 CC Switch 的本地代理地址应保持为 `http://127.0.0.1:15721`；不要把 Claude Code 的代理地址直接改成 `15720`。
- 只把 CC Switch 当前实际使用的 DeepSeek 供应商目标地址改为 `http://127.0.0.1:15720`，不要修改模型映射、`input_modalities` 或其他供应商。

请按下面顺序替我完成：
1. 先检查 `node --version`、`git --version`、Claude Code、CC Switch、用户级环境变量、`15720` 和 `15721` 端口。API Key 只能检查是否存在，不能读取或回显。
2. 确认我提供的 `<修改 CC Switch 前的真实上游地址>` 已经替换为真实地址。如果当前 CC Switch 已经指向 `127.0.0.1:15720`，不要猜测原始地址；从 CC Switch 的当前供应商配置、官方导出或我提供的备份中确认。没有真实地址就暂停并向我询问。
3. 使用 CC Switch 自带的导出/备份功能备份当前供应商配置；如需复制 `%USERPROFILE%\.cc-switch\cc-switch.db`，先确保 CC Switch（包括托盘进程）已完全退出，不要在数据库运行时写入或编辑它。备份 Claude Code 的 `%USERPROFILE%\.claude\settings.json`。备份放在仓库目录之外，不要删除或覆盖无关配置。
4. 检查 CC Switch 的“开机启动”已开启，并确认 Windows `CC Switch` 登录启动项确实存在。安装器只会包装已有的标准登录启动项，不会替用户创建 CC Switch 启动项。
5. 确认用户级环境变量 `VISION_API_KEY`、`VISION_BASE_URL`、`VISION_MODEL`、`UPSTREAM`、`BRIDGE_HOST` 和 `BRIDGE_PORT`。`UPSTREAM` 必须是修改前的真实 DeepSeek 地址，不能是 `127.0.0.1:15720`。如果变量缺失，先向我询问，不要编造。
6. 如果刚用 `[Environment]::SetEnvironmentVariable(..., "User")` 写入变量，不要直接在同一个旧 PowerShell 进程中启动桥：先退出并重新打开 PowerShell，或在不打印值的前提下把用户变量刷新到当前进程。未来 Windows 登录启动还需要重新登录或重启 Explorer 才能继承新变量。
7. 从仓库根目录运行 `npm.cmd run check` 和 `npm.cmd test`，再运行仓库提供的 Windows 安装脚本。安装器会把桥运行时、全局 Vision Skill 和登录启动入口安装到对应目录，并备份同名旧文件。
8. 必须检查安装器输出：应看到 `CC Switch startup now waits for the bridge health check`。如果输出 `No recognizable CC Switch startup entry was found`，不要宣称开机顺序已修复；先在 CC Switch 中开启开机启动，完全退出并重新打开 CC Switch，再检查 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，必要时重新运行安装器。安装器只识别名为 `CC Switch` 的标准用户登录启动项，不会接管任务计划程序、启动文件夹快捷方式或其他自定义启动器。
9. 检查 `http://127.0.0.1:15720/health`。健康响应必须包含 `ok=true`、`service=vision-bridge` 和当前受管版本；若设置了 `BRIDGE_AUTH_TOKEN`，请求必须带 `x-bridge-token`。如果已有旧版本桥进程占用 `15720`，只允许在命令行精确指向 `%USERPROFILE%\.claude\bridge\vision-bridge.js` 且确认是旧受管桥时停止它；不要按 `node.exe` 名称杀进程。
10. 在 CC Switch 中只修改当前实际 app 类型和活动 DeepSeek 供应商的目标地址为 `http://127.0.0.1:15720`。保留 Claude Code 到 CC Switch 的 `http://127.0.0.1:15721`，保留 `UPSTREAM` 的真实地址，不要形成循环代理。
11. 运行只读诊断脚本 `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\bridge\diagnose-vision-bridge.ps1"`，确认桥、`15721`、Claude Code 路由和用户配置均正常。该脚本不会编辑 SQLite，也不会显示密钥。验证一条无图片文本请求、Claude Code 直接粘贴图片，并在需要时验证本地图片路径的 Vision Skill。
12. 让我在 Claude Code 中完成最终粘贴图片测试；如果需要验证开机流程，先向我确认再重启 Windows。重启后登录并等待约 10-30 秒，再直接打开 Claude Code 验证无需手动命令即可识图；不要未经确认自动重启电脑。
13. 每一步展示实际命令结果和验证证据；失败时保留原配置并说明具体失败层，不要声称“已完成”却没有测试。

安装成功的硬性证据：
- `15720/health` 返回当前受管桥版本；
- `15721` 正在监听；
- Claude Code 的 `ANTHROPIC_BASE_URL` 仍指向 `http://127.0.0.1:15721`；
- CC Switch 活动供应商目标指向 `http://127.0.0.1:15720`；
- Windows `CC Switch` 登录启动项包含 `start-ccswitch-after-bridge.vbs`；
- 重启 Windows 后无需手动启动桥或重新修改路由。

如果我没有提供真实 DeepSeek 上游地址或完整 API Key，请先只向我询问缺少的值，不要编造。API Key 已经在本机用户级环境变量中配置时，只检查是否存在，绝对不要回显它。
```

如果 AI 遇到以下任一情况，应该暂停并报告，而不是猜测或强行覆盖：真实 `UPSTREAM` 不明、`15720`/`15721` 被未知进程占用、CC Switch 没有标准登录启动项、已配置 `BRIDGE_AUTH_TOKEN` 但 CC Switch 无法注入 `x-bridge-token`，或 CC Switch 更新后启动项指向了不存在的旧路径。AI 也不应为了“让测试通过”把 `UPSTREAM` 改成桥地址、关闭令牌、修改 `input_modalities` 或编辑 CC Switch 数据库。

### `15720` 端口冲突时的处理规则

如果检查发现 `15720` 已被占用，先只读确认占用者，不要直接杀进程，也不要马上换端口：

```powershell
$listener = Get-NetTCPConnection -State Listen -LocalPort 15720 -ErrorAction SilentlyContinue
$listener | Select-Object LocalAddress, LocalPort, OwningProcess
$listener | ForEach-Object {
    Get-CimInstance Win32_Process -Filter "ProcessId=$($_.OwningProcess)" |
        Select-Object ProcessId, Name, ExecutablePath
}
$healthHeaders = @{}
if (-not [string]::IsNullOrWhiteSpace($env:BRIDGE_AUTH_TOKEN)) {
    $healthHeaders["x-bridge-token"] = $env:BRIDGE_AUTH_TOKEN
}
Invoke-RestMethod -Uri "http://127.0.0.1:15720/health" -Headers $healthHeaders |
    Select-Object ok, service, version
```

- 如果 `http://127.0.0.1:15720/health` 返回本项目受管版本的健康响应，说明是已经运行的桥；复用它，不要再启动第二个桥。
- 如果端口由其他程序、未知版本的桥或不健康进程占用，保留原状并向我报告 PID、进程名和可执行文件路径；不要停止未知进程。
- 只有在确认占用者是本项目旧桥并得到明确授权后，才可以停止旧桥，再重新运行启动器。启动器本身也会拒绝接管不健康的占用端口。
- 如果必须换端口，先确认一个未占用端口，例如 `15730`，然后同时修改用户级 `BRIDGE_PORT` 和 CC Switch 当前供应商目标：

```powershell
[Environment]::SetEnvironmentVariable("BRIDGE_PORT", "15730", "User")
```

```text
CC Switch 目标地址： http://127.0.0.1:15730
UPSTREAM：          原始 DeepSeek 上游地址（不要改成桥地址）
```

换端口后必须重新打开启动器继承环境变量的进程、重启 CC Switch 和 Claude Code，并检查对应端口的 `/health`。不要只改其中一处，否则会出现网关连接错误。

如果是 `15721` 被占用，那个端口属于 CC Switch 本地代理，不要让桥改用 `15721`，也不要停止占用者。先确认 CC Switch 实际配置的代理端口，再在 Claude Code 的 `ANTHROPIC_BASE_URL`、诊断脚本参数和使用说明中统一该端口；桥的 `BRIDGE_PORT` 仍应与 CC Switch 的供应商目标端口分开。

</details>

这段指令不会替 AI 猜测缺失的上游地址，也不会要求把密钥写入仓库。更安全的做法是先在本机设置 `VISION_API_KEY`，然后让 AI 只检查“是否已配置”。

## Windows 登录后自动启动

桥通过当前用户的 Windows Startup 文件夹在**登录后**启动，不是系统服务，也不会在登录前运行。安装器只需要当前用户权限，不需要管理员权限；请在将要使用 Claude Code/CC Switch 的同一个 Windows 用户下运行，不要用另一个管理员账户或系统账户运行，否则 `%USERPROFILE%`、用户环境变量、Startup 文件夹和 `HKCU` 可能不属于实际使用者。

安装仓库后执行：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\src\install-vision-bridge.ps1
```

安装器会先验证并暂存全部源文件，再备份已有的桥文件、Vision Skill 和 `vision-bridge.vbs`，最后替换 Startup 入口。如果检测到当前用户注册表中名为 `CC Switch` 的标准登录启动项，安装器还会把这条启动命令包在桥健康检查之后；原始命令保存在 `%USERPROFILE%\.claude\bridge\cc-switch-startup.command`，备份清单位于 `%USERPROFILE%\.claude\bridge\backups\install-*\manifest.json`。它不会设置环境变量、读取或写入 API Key，也不会修改 CC Switch 数据库、供应商或路由。

安装完成后，启动器会检查当前进程环境中的 `UPSTREAM` 和 `VISION_API_KEY`，验证端口上是否是本项目的受管版本，并在启动后轮询 `/health`。缺少配置、端口被其他程序占用或桥进程启动失败时，错误会写入 `%USERPROFILE%\.claude\bridge\vision-bridge.err.log`。如果桥未健康，CC Switch 协调器不会启动 CC Switch，避免它先启动并产生 502/503；详情写入 `%USERPROFILE%\.claude\bridge\cc-switch-startup.log`。

桥启动成功只代表 `15720` 可用，不代表 CC Switch 路由已经正确。必须另外确认 `15721` 正在监听、Claude Code 仍使用 `15721`，并且 CC Switch 当前活动供应商的目标地址使用 `15720`。

设置用户级环境变量后，要退出并重新登录 Windows，或至少重新打开 Explorer、终端、CC Switch 和 Claude Code，使 Startup 启动器实际继承到这些变量。启动器不会从旧 PowerShell 会话或 CC Switch 数据库猜测 `UPSTREAM`。

查看重启后的分层状态：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\bridge\diagnose-vision-bridge.ps1"
```

如需卸载，只删除 Startup 中的 `vision-bridge.vbs` 和本项目安装的脚本/Skill；如果安装器接管过 CC Switch 登录启动项，先运行 `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\bridge\restore-ccswitch-startup.ps1"` 恢复原始命令。不要删除 `cc-switch-startup.command` 或 `backups`，直到确认原始 CC Switch 启动项已经恢复。要回滚桥文件，按照备份目录的 `manifest.json` 将对应文件恢复后，再启动原来的桥。

## 与 CC Switch 一起工作

使用 CC Switch 本地代理时，实际链路是：

```text
Claude Code / Claude Desktop
  -> CC Switch 127.0.0.1:15721
  -> 当前 app 类型和供应商的目标地址 127.0.0.1:15720
  -> UPSTREAM 中保存的真实文本上游
```

`15721` 是 CC Switch 代理，`15720` 才是本项目的桥。Claude Code 和 Claude Desktop 可能使用不同的 app 类型/供应商配置；请在 CC Switch 界面分别确认实际使用的配置，而不是只改一个看起来相同的供应商。目标地址优先使用 `http://127.0.0.1:15720`，不要写成 `localhost`，因为桥默认只绑定 IPv4 loopback。

CC Switch 自身是否随 Windows 登录启动仍是用户设置。安装器只会包装已经存在的名为 `CC Switch` 的登录启动命令，不会创建 CC Switch 启动项，也不会修改 CC Switch 的登录开关。如果 `15720` 健康但 `15721` 没有监听，检查 `cc-switch-startup.log`，确认桥健康后再手动启动 CC Switch；若两端口都正常但请求没有进入桥，检查当前 app 类型、活动供应商目标地址和 CC Switch 的媒体降级设置。

本项目不在启动时自动编辑 CC Switch 的 SQLite 数据库，也不改供应商、模型映射或路由。它只在安装阶段包装 Windows 注册表中已经存在的 CC Switch 登录启动命令；需要调整路由时先用 CC Switch 界面，并先备份其配置。

### 三个地址和一个上游变量

| 项目 | 默认值 | 应该放在哪里 | 作用 |
| --- | --- | --- | --- |
| CC Switch 本地代理 | `http://127.0.0.1:15721` | Claude Code 的 `ANTHROPIC_BASE_URL` | Claude Code 先连接 CC Switch |
| Vision Bridge 本地地址 | `http://127.0.0.1:15720` | CC Switch 当前活动供应商的目标地址 | CC Switch 把请求交给图片转换桥 |
| 原始文本上游 | 无固定值 | 用户环境变量 `UPSTREAM` | 桥把文本化请求转发到真正的 DeepSeek 服务 |
| 视觉服务 | `https://api.stepfun.com/v1` | 用户环境变量 `VISION_BASE_URL` | 桥/Skill 把图片发送到视觉模型 |

不要把这四个位置混用：`ANTHROPIC_BASE_URL` 不是 `UPSTREAM`，`UPSTREAM` 也不能写成本地桥地址；否则可能出现网关错误、自代理循环或图片请求绕过桥。

### CC Switch 更新后的检查

CC Switch 官方更新通常会替换程序文件，但更新器也可能重写登录启动项或改变安装路径。更新后请重新运行只读诊断脚本，并检查：

```powershell
$runValue = [string](Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "CC Switch" -ErrorAction SilentlyContinue).'CC Switch'
if ([string]::IsNullOrWhiteSpace($runValue)) {
    "CC Switch Run entry: missing"
} elseif ($runValue -match "start-ccswitch-after-bridge\.vbs") {
    "CC Switch Run entry: coordinated"
} else {
    "CC Switch Run entry: present but not coordinated"
}
"Coordinator file: {0}" -f (Test-Path -LiteralPath "$env:USERPROFILE\.claude\bridge\start-ccswitch-after-bridge.vbs")
```

如果 `CC Switch` 的登录启动项仍包含 `start-ccswitch-after-bridge.vbs`，通常只需确认新版本的 `cc-switch.exe` 能由备份命令启动。如果协调器仍在，但 `%USERPROFILE%\.claude\bridge\cc-switch-startup.command` 中的程序路径已不存在，不要让协调器继续调用失效路径：先手动启动真实存在的新版本 `cc-switch.exe`，在 CC Switch 中关闭再重新开启开机启动，让官方程序重新写入新的登录启动命令，然后重新运行安装器。只有当备份命令本身已知有效、且你确实要恢复旧启动方式时，才运行恢复脚本。如果启动项已被更新器改回原始命令、原始程序路径已变化，或启动项消失：

1. 在 CC Switch 中重新开启开机启动，并完全退出再重新打开 CC Switch。
2. 确认注册表中的 `CC Switch` 启动命令指向真实存在的新版程序。
3. 从本仓库重新运行 `install-vision-bridge.ps1`，让安装器重新备份当前启动命令并包装协调器。
4. 再运行 `diagnose-vision-bridge.ps1`，最后重启 Windows 验证。

如果需要恢复旧启动项，使用安装器复制到用户目录的脚本：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\bridge\restore-ccswitch-startup.ps1"
```

不要手动把更新后的 `cc-switch.exe` 路径猜写进 `cc-switch-startup.command`，不要修改 CC Switch 数据库。安装器每次运行都会创建新的备份目录；确认新启动链路正常前，不要删除旧备份。

## 手动安装（Windows）

### 1. 下载文件

```powershell
git clone https://github.com/R-R6/claude-deepseek-vision-bridge.git
Set-Location .\claude-deepseek-vision-bridge
```

如果没有 Git，可以下载 GitHub 的 ZIP 到新的工作目录并解压；不要为了本项目执行 `npm install`，项目没有运行时依赖。不要在已有用户工作目录中直接解压覆盖文件。

### 2. 配置环境变量

下面的变量写入当前 Windows 用户，不会进入 Git。尖括号是占位符，不能原样执行；如果 `VISION_API_KEY` 已经存在，不要覆盖它。`UPSTREAM` 必须填写改路由前的真实 DeepSeek 上游地址；不要把它写成桥自己的地址。仓库里的 `.env.example` 只是配置参考，本项目不会自动加载 `.env` 文件。

```powershell
[Environment]::SetEnvironmentVariable("VISION_BASE_URL", "https://api.stepfun.com/v1", "User")
[Environment]::SetEnvironmentVariable("VISION_MODEL", "step-3.7-flash", "User")
[Environment]::SetEnvironmentVariable("UPSTREAM", "<原始 DeepSeek 供应商 Base URL>", "User")
[Environment]::SetEnvironmentVariable("BRIDGE_HOST", "127.0.0.1", "User")
[Environment]::SetEnvironmentVariable("BRIDGE_PORT", "15720", "User")
```

如果 `VISION_API_KEY` 缺失，请单独使用不回显的安全输入设置它，不要把真实 Key 写进命令文本：

```powershell
$secureKey = Read-Host "StepFun API key" -AsSecureString
$keyPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
try {
    $keyPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPtr)
    [Environment]::SetEnvironmentVariable("VISION_API_KEY", $keyPlain, "User")
} finally {
    if ($keyPtr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPtr)
    }
    $keyPlain = $null
    $secureKey = $null
}
```

如果只缺少非敏感变量，可以按上面的固定值设置；如果缺少 `VISION_API_KEY` 或真实 `UPSTREAM`，先取得正确值，不要编造。然后先运行离线检查：

只检查用户级变量是否存在时，使用不会回显值的方式：

```powershell
foreach ($name in @("VISION_API_KEY", "VISION_BASE_URL", "VISION_MODEL", "UPSTREAM", "BRIDGE_HOST", "BRIDGE_PORT")) {
    $value = [Environment]::GetEnvironmentVariable($name, "User")
    "{0}={1}" -f $name, ($(if ([string]::IsNullOrWhiteSpace($value)) { "missing" } else { "present" }))
}
```

不要用 `Get-ChildItem Env:`、`$env:VISION_API_KEY` 或直接打印 `UPSTREAM` 来做这一步；它们可能把密钥或带凭据的 URL 写入终端记录。

```powershell
npm.cmd run check
npm.cmd test
```

### 3. 安装启动入口

确认环境变量已配置、当前 PowerShell 已刷新，并且离线检查已通过后，再运行安装器：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\src\install-vision-bridge.ps1
```

安装器会把桥、全局 Vision Skill 和 Windows 登录启动入口复制到当前用户目录，并备份已有文件。成功时应看到：

```text
Vision Bridge runtime and Vision Skill installed.
CC Switch startup now waits for the bridge health check
```

如果看到 `No recognizable CC Switch startup entry was found`，安装器没有接管 CC Switch 的启动顺序；先在 CC Switch 中开启开机启动，完全退出并重新打开，再重新运行安装器。

安装后完全退出并重新打开 PowerShell、CC Switch 和 Claude Code，使它们继承新的用户环境变量。然后启动并检查桥：

```powershell
& "$env:USERPROFILE\.claude\bridge\start-vision-bridge.ps1"

$healthHeaders = @{}
if ($env:BRIDGE_AUTH_TOKEN) {
    $healthHeaders["x-bridge-token"] = $env:BRIDGE_AUTH_TOKEN
}
Invoke-RestMethod -Uri "http://127.0.0.1:15720/health" -Headers $healthHeaders
```

如果 PowerShell 因执行策略阻止脚本，可先解除这个刚下载文件的标记，再重试：

```powershell
Unblock-File -LiteralPath "$env:USERPROFILE\.claude\bridge\start-vision-bridge.ps1"
```

正常结果应包含：

```text
ok      service       version
--      -------       -------
True    vision-bridge 0.2.1
```

### 4. 修改 CC Switch 路由

只修改当前 DeepSeek 供应商的目标地址：

```text
目标地址：  http://127.0.0.1:15720
UPSTREAM：  修改前的真实 DeepSeek Base URL
```

不要把 `UPSTREAM` 也改成本地桥地址，否则会形成自代理循环。只修改当前实际使用的 app 类型和活动供应商，不要修改 `input_modalities` 或其他供应商。修改后完全重启 Claude Code，并先测试一条无图片文本请求，再直接粘贴图片。

### 5. 重启验收

先运行只读诊断：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\bridge\diagnose-vision-bridge.ps1"
```

确认诊断通过后，先由使用者决定是否重启 Windows。重启后登录并等待约 10-30 秒，直接打开 Claude Code，不需要手动启动桥。若仍出现 gateway connection error，先看 `diagnose-vision-bridge.ps1`、`vision-bridge.err.log` 和 `cc-switch-startup.log`，不要先改模型映射。

## 手动识图

当 Agent 已经拿到图片路径或 URL，而不是 Claude Code 的原始粘贴请求时，可以直接调用后备入口：

```powershell
node "$env:USERPROFILE\.claude\skills\vision\vision.js" "C:\Temp\screen.png" "请读取图片中的关键文字"
node "$env:USERPROFILE\.claude\skills\vision\vision.js" --url "https://example.com/image.png" "请描述这张图"
```

## 配置参考

### 必要配置

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `VISION_API_KEY` | 无 | StepFun 或兼容视觉服务的 API Key；必须通过环境变量提供 |
| `VISION_BASE_URL` | `https://api.stepfun.com/v1` | 视觉服务 Base URL |
| `VISION_MODEL` | `step-3.7-flash` | 视觉模型 ID |
| `UPSTREAM` | 无 | 原始 DeepSeek 文本上游 Base URL |
| `BRIDGE_HOST` | `127.0.0.1` | 监听地址；改为非 loopback 时必须启用认证 |
| `BRIDGE_PORT` | `15720` | 本地桥端口 |
| `BRIDGE_AUTH_TOKEN` | 空 | 可选桥令牌；请求头为 `x-bridge-token` |

### 资源和超时限制

默认值是保守的本机起点：一次请求最多 8 张图片、最多 2 个视觉 API 并发、最多 16 条含图任务。它们不会限制 Claude Code 对 Word、Excel 等文档 Skill 的处理。

| 变量 | 默认值 | 作用 |
| --- | ---: | --- |
| `BRIDGE_MAX_IMAGES` | `8` | 单次请求最多转换的图片数量 |
| `BRIDGE_MAX_CONCURRENT_VISION_REQUESTS` | `2` | 同时运行的视觉 API 请求数 |
| `BRIDGE_MAX_VISION_JOBS` | `16` | 可检查请求、运行中或排队中的含图任务总数；超出返回 `429` |
| `BRIDGE_MAX_BODY_BYTES` | `26214400` | 入站请求体上限，约 25 MiB |
| `VISION_TIMEOUT_MS` | `120000` | 单次视觉 API 调用超时 |
| `UPSTREAM_TIMEOUT_MS` | `120000` | 原始文本上游请求超时 |
| `BRIDGE_TOTAL_REQUEST_TIMEOUT_MS` | `300000` | 整条含图请求（转换和上游转发）的总超时 |
| `VISION_MAX_RESPONSE_BYTES` | `2097152` | 视觉服务响应体上限，约 2 MiB |
| `BRIDGE_HEADERS_TIMEOUT_MS` | `30000` | 入站请求头超时 |
| `BRIDGE_BODY_TIMEOUT_MS` | `120000` | 入站请求体超时 |
| `BRIDGE_KEEP_ALIVE_TIMEOUT_MS` | `5000` | HTTP Keep-Alive 超时 |
| `BRIDGE_STARTUP_TIMEOUT_MS` | `30000` | Windows 启动器等待受管 `/health` 通过的最长时间，范围 `1000`-`120000` |
| `BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS` | `120000` | CC Switch 登录启动协调器等待桥健康的最长时间；超时不启动 CC Switch，范围 `1000`-`300000` |
| `ALLOW_INSECURE_HTTP` | `0` | 仅显式设为 `1` 时允许远程 HTTP；不建议使用 |

## 支持范围

- Anthropic Messages：`image`，支持 base64 和 URL source。
- OpenAI Chat Completions：`image_url`。
- 无图片请求直接透传，保留查询参数和流式响应。
- `UPSTREAM` 可以是域名根地址，也可以包含 `/v1` 等基础路径。
- 不宣称支持 OpenAI Responses API 的 `input_image`。

## 安全边界

- 桥默认只监听 `127.0.0.1`。这适用于本机进程均可信的个人电脑。
- 如果将 `BRIDGE_HOST` 改为局域网或其他非 loopback 地址，必须设置 `BRIDGE_AUTH_TOKEN`；否则桥会拒绝启动。
- 共享电脑上建议启用令牌，并确认 CC Switch 支持注入 `x-bridge-token`。令牌会在转发到上游前删除。
- 图片会发送给 StepFun 或你配置的视觉服务。不要提交包含密码、令牌、私密代码或不应外传数据的截图。
- `VISION_BASE_URL` 和 `UPSTREAM` 默认要求 HTTPS；只有 loopback HTTP 可用于本地服务和测试。`ALLOW_INSECURE_HTTP=1` 会明文传输凭据和图片，仅用于你明确接受风险的场景。
- 日志保存在 `%USERPROFILE%\.claude\bridge\vision-bridge.log` 和 `vision-bridge.err.log`，桥不会主动记录 API Key 或图片 base64。

## 故障排查

| 现象 | 先检查 |
| --- | --- |
| 启动时报 `UPSTREAM is not configured` | 重新打开终端，确认用户级 `UPSTREAM` 指向原始 DeepSeek 地址 |
| `/health` 返回 `401` | `BRIDGE_AUTH_TOKEN` 是否已配置；若已配置，健康请求必须带 `x-bridge-token`。不要为了通过检查删除已有令牌 |
| 粘贴图片仍返回 400 | Claude Code 的 `ANTHROPIC_BASE_URL` 是否为 `http://127.0.0.1:15721`；CC Switch 活动供应商目标是否为 `http://127.0.0.1:15720`；`UPSTREAM` 是否仍为真实上游；查看桥日志 |
| 返回 `413` | 请求体超过约 25 MiB，或单次图片数量超过 `BRIDGE_MAX_IMAGES` |
| 返回 `429` | 当前已有 16 条含图任务；稍后重试，或在确认费用和资源后调高 `BRIDGE_MAX_VISION_JOBS` |
| 本地图片路径无法识别 | 直接运行上面的 `vision.js` 命令，确认文件路径、API Key 和视觉服务 URL |
| Word/Excel 处理异常 | 这类任务应由 Claude Code 对应内置 Skill 处理，不是本桥的 OCR 入口 |
| 重启后出现 gateway connection error | 先运行 `diagnose-vision-bridge.ps1`：`15720` 不健康时修复 Startup/桥；`15721` 未监听时启动 CC Switch；两者都正常但请求绕过桥时检查当前 app 类型和供应商目标 |
| `15720` 端口被占用 | 先用 `Get-NetTCPConnection` 和 `Get-CimInstance Win32_Process` 确认 PID、进程路径，再请求健康检查；健康的受管桥直接复用，未知进程不要停止；换端口时同步修改 `BRIDGE_PORT` 和 CC Switch 目标 |

## 测试与开发

本项目无运行时依赖，要求 Node.js 18+。测试使用本地 mock 服务，不访问 StepFun，也不读取真实 API Key：

```powershell
npm.cmd run check
npm.cmd test
```

Smoke test 覆盖图片转换、无图透传、`/v1` 路径、查询参数、chunked framing、可选桥认证、图片数量上限、并发/排队、客户端断开、超时、HTTPS 校验和响应头过滤。Windows 启动脚本测试使用随机端口和临时带空格路径，覆盖认证健康检查、非桥占端口和启动超时，不触碰真实 `15720`/`15721`。

项目文件：

| 文件 | 用途 |
| --- | --- |
| `src/vision-bridge.js` | Claude Code/CC Switch 的本地透明桥 |
| `src/vision.js` | 本地图片路径或远程 URL 的手动识图入口 |
| `src/vision-client.js` | 两种入口共用的 OpenAI-compatible 视觉客户端 |
| `src/start-vision-bridge.ps1` | Windows 后台启动脚本 |
| `src/start-ccswitch-after-bridge.vbs` | 等待桥健康后再启动已存在的 CC Switch 登录命令 |
| `src/restore-ccswitch-startup.ps1` | 恢复安装器包装前的 CC Switch 登录命令 |
| `src/install-vision-bridge.ps1` | 暂存、备份并安装桥、Vision Skill 和 Startup 入口 |
| `src/diagnose-vision-bridge.ps1` | 只读检查桥、CC Switch 代理和 Claude Code 路由 |
| `src/SKILL.md.template` | 全局 Vision Skill 模板 |
| `test/bridge-smoke-test.js` | 无真实 API Key 的边界 smoke test |
| `test/startup-script-smoke-test.js` | Windows 启动器隔离 smoke test |

## 项目来源与许可证

本项目的“让纯文本模型调用另一视觉模型看图”这一工作流，受 [asuojun/claude-vision-skill](https://github.com/asuojun/claude-vision-skill) 启发，核对时参考的上游提交为 [`19ec87b`](https://github.com/asuojun/claude-vision-skill/commit/19ec87bd76053abe35cf94b42955b25062d65c7b)。

上游本地副本当时没有发现 LICENSE 文件，因此本仓库没有复制或再发布上游 `vision.js`。本仓库的视觉客户端、透明桥、启动脚本和测试均为独立实现；它不是上游项目的镜像、官方分支或官方产品。

本仓库代码采用 MIT 许可证，见 [LICENSE](LICENSE)。如果以后引入上游源码，应先确认上游最新许可证或取得作者授权。
