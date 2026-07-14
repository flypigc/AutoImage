# Codex CLI Workflow Toolkit

[简体中文](./README.zh-CN.md)

Windows PowerShell scripts for running Codex from the terminal, saving outputs, batching prompts, running grouped conversations, and generating images through an OpenAI-compatible Images API.

## Requirements

- Windows PowerShell
- Node.js 18 or newer
- `codex` available on `PATH`
- A configured Codex login or local Codex auth
- `OPENAI_API_KEY` for image generation, unless available from Codex auth
- A running local OpenAI-compatible proxy if you use one

## Start

Install the terminal progress dependencies once:

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

## Interactive Menu

The menu includes:

- Chat
- Batch
- Images
- Stats
- Settings

The main screen uses a vertical Main navigation pane on the left and a live menu tree on the right. Moving `Up/Down` in the left pane changes the main section and redraws the right pane immediately; no Enter press is needed to reveal its submenu. `Right` or `Tab` moves into the tree. In the tree, `Enter` toggles a group or runs a leaf, `Right` expands a group, and `Left` collapses a group or selects its parent. At the tree root, `Left`, `Shift+Tab`, or `Esc` returns to Main. Menu labels do not show numeric prefixes.

The screen is divided into Main, current-menu, and Current regions. The right title contains only the selected menu name. Text/image API profiles and image-generation options can be expanded or collapsed independently. On narrow terminals the panes stack vertically, but Main remains a vertical list and the selected tree row stays visible.

The Chat menu has two modes:

- `Codex` starts the real Codex TUI in the current terminal for the configured workspace, so the single-conversation experience has the same interface, slash commands, resume picker, model controls, approval flow, and tool behavior as running `codex` directly. Exit Codex to return to the workflow menu.
- `Single prompt run` keeps the workflow's archived one-shot execution path and writes prompt, assistant answer, logs, summary, and run-index entries under `runs\text`.

Single prompt runs can set a run name, override the model for one run, disable persistent archiving, and open the summary on completion. The Batch tab provides single prompt files, prompt lists, and grouped conversations. Prompt-list batches support parse-only preflight, continue/stop failure policies, and checkpoint resume through `prompt_batch_state.json`.

In the workflow single-prompt composer:

- `Enter` sends
- `Shift+Enter`, `Ctrl+Enter`, or `Ctrl+J` inserts a newline
- `Esc` exits
- `Ctrl+Z` returns to the previous menu

The Stats screen remains a single htop-style report containing the overview, type totals, model totals, and recent runs. While open, it monitors `runs\index.jsonl` and refreshes automatically; press `R` to refresh immediately. Section bands and extra spacing separate the report, while fixed-width cells and two-column gaps keep values aligned. Tables automatically reduce columns on narrow terminals; generic task progress rendering is unchanged. The default workspace is the repository-local `cache` directory.

## Command Line

Single prompt:

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-CodexCliAsk.ps1 -Prompt "Summarize this folder."
```

Single prompt with timeout:

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-CodexCliAsk.ps1 `
  -Prompt "Summarize this folder." `
  -TimeoutSeconds 300
```

Exit code `124` means the run timed out and the process tree was terminated.

Prompt list batch:

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-CodexCliAsk.ps1 -PromptListFile .\prompts.md
```

Grouped conversation batch:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-CodexConversation.ps1 -ConversationFile .\conversation_example.txt
```

Resume an incomplete conversation batch:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-CodexConversation.ps1 `
  -ConversationFile .\conversation_example.txt `
  -ResumeStatePath .\runs\text\<run>\conversation_state.json
```

Single image:

```powershell
powershell -ExecutionPolicy Bypass -File .\Invoke-CodexCliAsk.ps1 `
  -Prompt "A neon fox in a rainy city" `
  -GenerateImage `
  -Model gpt-image-2 `
  -ImageOutputPath .\runs\images\fox.png
```

Image batch:

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

Image batches treat local images embedded in each Markdown segment as reference images for that segment. Both `![alt](./ref.png)` and `<img src="./ref.png">` are supported. Relative paths resolve from the prompt Markdown file directory. PNG, JPEG, and WebP are supported, with up to 16 reference images per segment. Segments with reference images use the image edits endpoint.

Foreground and background image batches use the same concurrency-limited scheduler, so `MaxConcurrency` applies in both modes. Each batch writes `batch_state.json`; the Images tab can retry only failed jobs or request cancellation of a running background batch. A foreground batch returns a non-zero exit code when any job fails.

## Input Formats

Prompt lists and image batches use `---` as a separator:

```text
Prompt A
---
Prompt B
```

Conversation files use:

- `---` to continue the same conversation
- `------` to end the current group and start a new conversation
- two consecutive soft separators also end the current group

## Outputs

New outputs are grouped under `runs`:

```text
runs\
  index.jsonl
  text\
  images\
```

Text and conversation runs:

```text
runs\text\<timestamp>_<name>\
```

Image batches:

```text
runs\images\<yyyyMMdd_HHmmss>\
```

`runs\index.jsonl` receives one JSON object per completed text, image, or conversation step. Entries include status, exit code, timestamps, model, and relative run directory when available.

Legacy directories `codex_cli_runs` and `pic` are still usable when passed explicitly, but new defaults write to `runs`.

## Settings

The Settings menu can save language, text and image API profiles, default paths, concurrency, retry defaults, separate Codex, per-request image, and total image-task timeouts, and whether image batches wait in the terminal. Primary and fallback API profiles are edited through the same form fields: `Name`, `ApiKey`, `BaseUrl`, and `Model`. Empty values leave Codex CLI and Codex auth/config as the source of truth unless you explicitly set an override here.

Text and image API settings support the same structure for primary and fallback profiles. The primary API is tried first, then fallback profiles are tried in configured order for connection-like failures, timeouts, rate limits, and 5xx responses. When multiple image API profiles are configured, image batches assign each job a different first-choice profile in round-robin order, so multiple Base URLs / API keys can share concurrent load; each job still falls back to the remaining profiles on failure. API tests check `/v1/models`, whether the configured model is listed, common balance/usage endpoints when available, and a minimal text model invocation. Image tests do not generate an image to avoid billing.

Image generation settings can set aspect ratio, size, quality, output format, compression quality, and moderation/risk level. `Auto` leaves the field out of the image API request.

Local settings are stored in `Start-CodexWorkflow.config.json`, which is ignored by git. Use `Start-CodexWorkflow.config.example.json` as the schema reference. Prefer environment variables or Codex auth for API keys.

## Checks

```powershell
npm run check
npm run test
npm run smoke:progress
npm run clean:smoke
```

Development notes are in [DEVELOPMENT.md](./DEVELOPMENT.md).
