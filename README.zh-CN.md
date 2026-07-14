# Codex CLI 工作流工具包

[English](./README.md)

这是一组 Windows PowerShell 脚本，用于在终端里调用 Codex、批量执行 prompt、运行多轮对话，以及通过 OpenAI 兼容图片接口生成图片。

## 运行要求

- Windows PowerShell
- Node.js 18 或更高版本
- `PATH` 中可用的 `codex` 命令
- 已完成 Codex 登录或本地 Codex 认证
- 图片生成需要 `OPENAI_API_KEY`，或 Codex 认证文件中已有可用密钥
- 如果使用本地 OpenAI 兼容代理，需要先启动代理服务

## 快速启动

首次使用先安装终端进度显示依赖：

```powershell
npm ci
```

PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-CodexWorkflow.ps1
```

CMD:

```cmd
ask-codex.cmd
```

## 交互菜单

主菜单包含:

- 对话
- 批处理
- 图片
- 统计
- 配置

主界面左侧是竖向“主导航”，右侧是实时展开的菜单树。在左栏按 `上下键` 切换主项时，右栏会立即更新，不需要按 Enter 才能看到子菜单；按 `右键` 或 `Tab` 进入菜单树。树中按 `Enter` 切换分组或执行叶子，按 `右键` 展开分组，按 `左键` 收起分组或回到父分组；没有父分组时，`左键`、`Shift+Tab` 或 `Esc` 返回主导航。菜单标签前不显示数字。

界面划分为“主导航、当前菜单、当前位置”三个区域。右侧标题只显示当前菜单名；文本/图片 API 和生成图片选项可在配置树中独立展开或收起。窄终端改为上下排列，但主导航仍是竖向列表，并保持当前树节点可见。

对话菜单包含两种模式:

- `Codex` 会在当前终端里为当前配置的工作区启动原生 Codex TUI，因此单对话界面、斜杠命令、恢复会话、模型控制、审批流程和工具行为都与直接运行 `codex` 一致。退出 Codex 后会返回工作流菜单。
- `单次 prompt 运行` 保留工作流原有的一次性执行和归档能力，会把 prompt、助手回复、日志、摘要和索引写入 `runs\text`。

单次 prompt 可以设置运行名称、临时模型覆盖、是否归档，以及完成后是否打开摘要。批处理标签提供单个 Prompt 文件、Prompt 列表和多轮对话三种入口。Prompt 列表支持仅解析预检、失败后继续或停止，并通过 `prompt_batch_state.json` 恢复未完成的批次。

工作流单次 prompt 输入框中:

- `Enter` 发送
- `Shift+Enter`、`Ctrl+Enter` 或 `Ctrl+J` 换行
- `Esc` 退出
- `Ctrl+Z` 返回上级菜单

统计界面保持单页 htop 报告，依次显示总览、类型汇总、模型汇总和最近运行。页面打开期间会监控 `runs\index.jsonl` 并自动刷新，按 `R` 可立即刷新。区块标题带和额外留白用于分隔内容，定宽单元格与双空格列间距保证数据对齐；终端较窄时自动精简列。通用任务进度条不受影响。默认工作区为仓库内的 `cache` 目录。

## 命令行用法

单条 prompt:

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-CodexCliAsk.ps1 -Prompt "Summarize this folder."
```

设置超时:

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-CodexCliAsk.ps1 `
  -Prompt "Summarize this folder." `
  -TimeoutSeconds 300
```

退出码 `124` 表示运行超时，脚本会终止对应的 Codex 进程树。

prompt 列表批处理:

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-CodexCliAsk.ps1 -PromptListFile .\prompts.md
```

多轮对话批处理:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-CodexConversation.ps1 -ConversationFile .\conversation_example.txt
```

恢复未完成的对话批处理:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-CodexConversation.ps1 `
  -ConversationFile .\conversation_example.txt `
  -ResumeStatePath .\runs\text\<run>\conversation_state.json
```

单张图片生成:

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-CodexCliAsk.ps1 `
  -Prompt "A neon fox in a rainy city" `
  -GenerateImage `
  -Model gpt-image-2 `
  -ImageOutputPath .\runs\images\fox.png
```

图片批处理:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-CodexImageBatch.ps1 `
  -PromptFile .\prompts.md `
  -Model gpt-image-2 `
  -MaxConcurrency 2 `
  -ImageMaxAttempts 6 `
  -ImageRetryBaseDelaySeconds 2 `
  -ImageRetryMaxDelaySeconds 20 `
  -Wait
```

图片批处理会把每个 Markdown 分段里的本地图片当作该分段的参考图，支持 `![说明](./ref.png)` 和 `<img src="./ref.png">`。相对路径按 prompt Markdown 文件所在目录解析，支持 PNG、JPEG 和 WebP；单个分段最多 16 张参考图。带参考图的任务会使用图片编辑接口。

前台和后台图片批处理使用同一套并发调度器，`MaxConcurrency` 在两种模式下都生效。每个批次写入 `batch_state.json`；图片标签可以只重跑失败任务，或请求取消仍在运行的后台批次。只要有图片任务失败，前台批处理就返回非零退出码。

## 输入格式

Prompt 列表和图片批处理使用 `---` 分段:

```text
Prompt A
---
Prompt B
```

对话文件中:

- `---` 表示继续同一轮对话
- `------` 表示结束当前分组，下一组新建对话
- 连续两个普通分隔线也会结束当前分组

## 输出结构

默认输出统一放到 `runs` 下:

```text
runs\
  index.jsonl
  text\
  images\
```

文本和对话结果:

```text
runs\text\<timestamp>_<name>\
```

图片批处理结果:

```text
runs\images\<yyyyMMdd_HHmmss>\
```

每次文本、图片或对话步骤完成后，脚本会向 `runs\index.jsonl` 追加一行 JSON，记录状态、退出码、时间、模型和相对输出目录等信息。

旧目录 `codex_cli_runs` 和 `pic` 仍可手动传参使用，但新的默认值不再写入旧目录。

## 配置

配置菜单可以保存:

- 语言
- 文本主 API 配置
- 文本备用 API 配置
- 图片主 API 配置
- 图片备用 API 配置
- 默认输出路径
- 批处理并发和重试参数
- Codex 单次运行超时时间
- 图片单次 HTTP 请求和整个图片任务的超时时间
- 图片批处理是否等待完成

本地配置文件为 `Start-CodexWorkflow.config.json`，已被 `.gitignore` 排除；字段结构可参考 `Start-CodexWorkflow.config.example.json`。API Key 建议使用环境变量或 Codex 登录配置，不建议长期写入本地配置文件。

文本和图片的主 API 与备用 API 使用同一套字段：`Name`、`ApiKey`、`BaseUrl`、`Model`。留空时不覆盖 Codex CLI，直接沿用 Codex 自己已有的配置；只有在这里显式填写时才作为覆盖值传入。

文本和图片都支持多套备用 API。主 API 优先，遇到连接异常、超时、限流或 5xx 错误时，会按备用配置 JSON 中的顺序切换。图片批处理配置了多套图片 API 时，会按任务轮询分配首选 API，从而用多个 Base URL / API Key 分摊并发；单个任务失败时仍会继续尝试其它 API。测试会检查 `/v1/models`、配置的模型是否可见、常见余额/用量接口，并对文本模型做一次最小调用。图片测试不会自动生图，避免产生费用。

API 配置 JSON 示例:

```json
[{"Name":"backup-1","ApiKey":"sk-...","BaseUrl":"https://api.example.com","Model":"gpt-5.5"}]
```

## 检查和维护命令

```powershell
npm run check
npm run test
npm run smoke:progress
npm run clean:smoke
```

开发维护说明见 [DEVELOPMENT.md](./DEVELOPMENT.md)。
