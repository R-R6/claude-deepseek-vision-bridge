# Claude DeepSeek Vision Bridge

让 Claude Code 在使用纯文本 DeepSeek 上游时，也能直接处理粘贴图片、截图和本地图片路径。

工作流程：图片先交给视觉模型生成文字描述，DeepSeek 再基于文字继续回答。项目同时提供：

- `src/vision-bridge.js`：透明处理 Claude Code/CC Switch 请求中的图片块。
- `src/vision.js`：Agent 已拿到本地图片路径或远程 URL 时的手动后备入口。
- `src/vision-client.js`：两种入口共用的视觉 API 客户端。

## 项目来源与独立性

本项目的“让纯文本模型调用另一视觉模型看图”这一工作流，受 [asuojun/claude-vision-skill](https://github.com/asuojun/claude-vision-skill) 启发，核对时参考的上游提交为 `19ec87bd76053abe35cf94b42955b25062d65c7b`。

上游本地副本当时没有发现 LICENSE 文件，因此本仓库没有复制或再发布上游 `vision.js`。本仓库的视觉客户端、透明桥、启动脚本和测试均为独立实现。准确说法是：这是一个受上游工作流启发、但源码独立开发的新项目，而不是上游项目的镜像或官方分支。

本仓库代码采用 MIT 许可证，见 [LICENSE](LICENSE)。本说明不是法律意见；如果以后引入上游源码，应先确认上游最新许可证或取得作者授权。

## 不下载仓库，直接让其他 AI 安装

将下面整段话复制给 Claude Code、Codex 或其他能够访问 GitHub、执行命令和修改本机配置的 AI。把尖括号占位符替换为自己的信息；不要把真实 API Key 发到公开聊天、截图或 Git 仓库。

```text
请全局安装并配置 Claude DeepSeek Vision Bridge：
https://github.com/R-R6/claude-deepseek-vision-bridge

请先完整阅读仓库 README，再执行安装，不要直接照猜配置。

我的目标：在 Claude Code 使用纯文本 DeepSeek 模型时，可以直接粘贴图片并识别；如果给出本地图片路径，也可以调用全局 Vision Skill。

视觉服务配置：
- 模型：阶跃星辰 Step 3.7 Flash
- Model ID：step-3.7-flash
- Base URL：https://api.stepfun.com/v1
- API Key：<我的完整 StepFun API Key>

文本模型路由：
- 我使用 CC Switch 管理 Claude Code 路由。
- 原始 DeepSeek 上游 Base URL：<修改 CC Switch 前的真实上游地址>
- Vision Bridge 本地端口：15720

请按下面顺序替我完成：
1. 检查 Node.js 18+、Claude Code、CC Switch、15720/15721 端口和现有配置。
2. 备份 Claude Code 配置与 CC Switch 当前供应商配置；不要删除或覆盖无关配置。
3. 将桥安装到 %USERPROFILE%\.claude\bridge，将 Vision Skill 安装到 %USERPROFILE%\.claude\skills\vision。
4. 通过用户级环境变量配置 VISION_API_KEY、VISION_BASE_URL、VISION_MODEL、UPSTREAM 和 BRIDGE_PORT；不要把 API Key 写进源码、README、日志、CC Switch 备注或 Git。
5. 先运行仓库离线测试，再启动桥并检查 http://127.0.0.1:15720/health。
6. 把 CC Switch 当前 DeepSeek 供应商的目标地址改为 http://127.0.0.1:15720；UPSTREAM 必须保留修改前的真实地址，防止形成循环代理。
7. 验证无图片文本请求、Claude Code 直接粘贴图片、本地图片路径三种场景。
8. 每一步展示实际命令结果和验证证据；失败时保留原配置并说明具体失败层，不要声称“已完成”却没有测试。
9. 全部通过后，让我立刻在 Claude Code 中粘贴一张图片做最终测试。

如果我没有提供真实 DeepSeek 上游地址或完整 API Key，请先只向我询问缺少的值，不要编造。
```

示例中的 `*****************8` 只能用于展示 Key 的尾号，不能完成真实安装。实际配置时应由用户私下提供完整 Key，或者先在本机设置 `VISION_API_KEY`，再让 AI 读取“是否已配置”而不是回显它。

## 手动安装（Windows）

需要 Node.js 18+。克隆仓库后，在仓库根目录执行：

```powershell
$bridgeDir = Join-Path $env:USERPROFILE ".claude\bridge"
$skillDir = Join-Path $env:USERPROFILE ".claude\skills\vision"
New-Item -ItemType Directory -Force -Path $bridgeDir, $skillDir | Out-Null
Copy-Item .\src\vision-bridge.js, .\src\vision-client.js, .\src\start-vision-bridge.ps1 -Destination $bridgeDir
Copy-Item .\src\vision.js, .\src\vision-client.js -Destination $skillDir
Copy-Item .\src\SKILL.md.template -Destination (Join-Path $skillDir "SKILL.md")
```

设置用户级环境变量：

```powershell
[Environment]::SetEnvironmentVariable("VISION_API_KEY", "<StepFun API Key>", "User")
[Environment]::SetEnvironmentVariable("VISION_BASE_URL", "https://api.stepfun.com/v1", "User")
[Environment]::SetEnvironmentVariable("VISION_MODEL", "step-3.7-flash", "User")
[Environment]::SetEnvironmentVariable("UPSTREAM", "<原始 DeepSeek 供应商 Base URL>", "User")
[Environment]::SetEnvironmentVariable("BRIDGE_PORT", "15720", "User")
[Environment]::SetEnvironmentVariable("BRIDGE_MAX_VISION_JOBS", "16", "User")
```

完全退出并重新打开终端、CC Switch 和 Claude Code，使进程继承新环境。然后启动并检查：

```powershell
& "$env:USERPROFILE\.claude\bridge\start-vision-bridge.ps1"
Invoke-RestMethod http://127.0.0.1:15720/health
```

最后把 CC Switch 当前供应商的目标地址改成 `http://127.0.0.1:15720`。

## 手动识图

```powershell
node "$env:USERPROFILE\.claude\skills\vision\vision.js" C:\Temp\screen.png "请读取图片中的关键文字"
node "$env:USERPROFILE\.claude\skills\vision\vision.js" --url https://example.com/image.png "请描述这张图"
```

## 安全边界

桥默认只监听 `127.0.0.1`。如果本机所有进程都可信，可以不设置桥令牌。共享电脑或更严格环境可设置 `BRIDGE_AUTH_TOKEN`，客户端请求必须携带 `x-bridge-token`；该请求头会在转发前删除。使用 CC Switch 前应先确认它是否支持注入自定义请求头。

图片会发送给 StepFun 或你配置的视觉服务。不要提交包含密码、令牌、私密代码或不应外传数据的截图。

默认每个请求最多转换 8 张图片，超过后返回 413；这是费用和资源保护上限，不影响一次粘贴单图或少量多图。视觉转换默认最多并发 2 个请求；同时最多接收 16 条含图任务，超过后返回 429 并提示稍后重试。Word、Excel 等文档继续由 Claude Code 的对应内置 Skill 处理，不会因为这个图片上限改走多模态 OCR。

若将 `BRIDGE_HOST` 改为局域网或其他非 loopback 地址，必须同时设置 `BRIDGE_AUTH_TOKEN`，否则桥会拒绝启动。

`VISION_BASE_URL` 和 `UPSTREAM` 默认要求使用 HTTPS；仅 loopback 的 HTTP 地址可用于本地服务和测试。设置 `ALLOW_INSECURE_HTTP=1` 可以显式允许远程 HTTP，但会明文传输凭据和图片，不建议在生产环境使用。

## 支持范围

- Anthropic Messages：`image`，支持 base64 和 URL source。
- OpenAI Chat Completions：`image_url`。
- 无图片请求直接透传，保留查询参数和流式响应。
- 不宣称支持 OpenAI Responses API 的 `input_image`。
- `UPSTREAM` 可以是域名根地址，也可以包含 `/v1` 等基础路径。

单次视觉调用和上游请求超时可通过 `VISION_TIMEOUT_MS`、`UPSTREAM_TIMEOUT_MS` 调整；视觉服务响应上限通过 `VISION_MAX_RESPONSE_BYTES` 调整；请求体、图片数量、视觉并发和任务总数上限分别通过 `BRIDGE_MAX_BODY_BYTES`、`BRIDGE_MAX_IMAGES`、`BRIDGE_MAX_CONCURRENT_VISION_REQUESTS`、`BRIDGE_MAX_VISION_JOBS` 调整。入站请求头、请求体、整条含图任务和 Keep-Alive 超时分别通过 `BRIDGE_HEADERS_TIMEOUT_MS`、`BRIDGE_BODY_TIMEOUT_MS`、`BRIDGE_TOTAL_REQUEST_TIMEOUT_MS`、`BRIDGE_KEEP_ALIVE_TIMEOUT_MS` 调整。

## 测试

```powershell
npm.cmd run check
npm.cmd test
```

测试使用本地 mock 服务，不访问 StepFun，不读取真实 API Key。覆盖图片转换、无图透传、`/v1` 路径、查询参数、chunked framing、可选桥认证和图片数量上限。
