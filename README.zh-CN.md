# Codex CLI Auto

[English](./README.md)

## 运行要求

- Windows PowerShell
- Node.js 18 或更高版本
- `PATH` 中可用的 `codex` 命令
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

![eg](./assets/eg.jpg)

# 怎么用？

把提示词写道prompts.md  分隔用---
