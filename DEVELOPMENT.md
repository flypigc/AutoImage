# Development Notes

This file documents maintenance rules for the workflow scripts. User-facing usage belongs in `README.md` and `README.zh-CN.md`.

## Structure

- `Start-CodexWorkflow.ps1`: interactive menu and settings UI; the Chat menu launches the native Codex TUI in the current terminal for interactive single conversations and keeps the archived single-prompt workflow as a second option
- `Invoke-CodexCliAsk.ps1`: single prompt, prompt file, prompt list, and single image execution
- `Start-CodexConversation.ps1`: grouped multi-turn conversation runner
- `Start-CodexImageBatch.ps1`: controlled-concurrency image batch runner
- `WorkflowCommon.psm1`: shared path, encoding, slug, Codex CLI, index, timeout, and cleanup helpers
- `WorkflowProgressUi.ps1`: PowerShell progress rendering helpers
- `cli-progress-bridge.js`: optional Node terminal progress bridge
- `tools/Check-Workflow.ps1`: lightweight repository check
- `tools/Invoke-WorkflowTests.ps1`: Pester test launcher with a fallback path
- `tools/Clean-SmokeRuns.ps1`: smoke-run cleanup helper
- `tests/Workflow.Tests.ps1`: focused tests for shared workflow behavior

## Shared Module Rules

Put cross-script behavior in `WorkflowCommon.psm1` when it is used by two or more scripts. Current shared concerns:

- workflow-root relative path resolution
- relative display paths
- UTF-8 no-BOM writes
- slug generation
- prompt segmentation
- Codex command discovery
- Codex execution
- per-run timeout handling
- JSONL run-index appends
- cleanup target validation
- output directory size stats

Keep workflow-specific logic in the entry script that owns it. For example, image API retry behavior stays in `Invoke-CodexCliAsk.ps1` unless another script needs it.

## Codex CLI Invocation

The preferred execution path calls the `codex` command directly through `Invoke-CodexCliExec`.

`Get-CodexCliPaths` still attempts to discover the underlying `node.exe` and `codex.js` as a fallback, but scripts must not depend on the wrapper script format for normal operation. This keeps the workflow more tolerant of Codex CLI packaging changes.

Prompts are passed as command arguments, and stdin is closed immediately after process start. This avoids non-interactive menu runs hanging while Codex waits for more stdin.

`-TimeoutSeconds` is forwarded from the interactive menu and batch runners to the shared process launcher. Timeout exit code is `124`; the launcher terminates the process tree before returning.

Interactive single conversations intentionally use the native `codex` TUI instead of reimplementing Codex's terminal UI in PowerShell. Launch it in the current terminal with `codex -C <workspace>` and return to the workflow menu after the Codex process exits. Only pass workflow text API environment overrides or an explicit workflow text model when the user configured those values. Keep the archived single-prompt path separate because it owns run directories, summaries, console logs, and `runs/index.jsonl` entries.

Workflow settings must not provide default text model, image model, profile, API key, or Base URL overrides. Leave API profile fields empty so Codex CLI and Codex auth/config remain the source of truth unless the user explicitly fills a workflow setting.

API fallback profiles live in `TextApiProfiles` and `ImageApiProfiles`. Primary and fallback profiles share `Name`, `ApiKey`, `BaseUrl`, and `Model`; switch only for transient connection-like failures, timeouts, rate limits, and 5xx responses. Do not hide deterministic model or authentication errors.

## Output Layout

New defaults write to:

```text
runs\
  index.jsonl
  text\
  images\
```

Legacy directories are still recognized:

- `codex_cli_runs`
- `pic`

Do not automatically move or delete legacy outputs in code changes. Users may have references to those paths.

`runs\index.jsonl` is append-only JSONL. Writes are guarded by a named mutex so concurrent image-batch children do not interleave lines. Add fields conservatively; consumers should tolerate missing fields from older runs.

Conversation batches persist `conversation_state.json` in the conversation output directory. State is updated after each successful prompt and group summary so failed runs can resume without replaying completed prompts.

Prompt-list batches persist `prompt_batch_state.json` and validate the source SHA-256 before resuming. Conversation state version 2 records a content hash, group prompt counts, and total operations; resume should use the saved `conversation.txt` snapshot and must reject mismatched content.

Image batches persist `batch_state.json`. Foreground and background modes both run the same concurrency-limited scheduler. A background launch detaches only the scheduler process; it must not fan out every image job at once. State transitions are `running`, `cancel_requested`, `canceled`, `failed`, and `completed`, and partial failure must produce a non-zero exit code.

## Cleanup Safety

Cleanup is intentionally narrow. `Invoke-CleanHistoryAction` and `tools/Clean-SmokeRuns.ps1` only accept targets under these workflow-owned roots:

- `runs`
- `codex_cli_runs`
- `pic`

Before deleting, interactive cleanup prints the target path, file count, and size. Cleanup must never target drive roots, the workflow root itself, or arbitrary paths outside the workflow directory.

## Local Files

`.gitignore` excludes:

- `runs/`
- `codex_cli_runs/`
- `pic/`
- `node_modules/`
- `Start-CodexWorkflow.config.json`
- `*.log`

Do not commit local settings, generated images, prompt run logs, or API keys.

## Checks

Run:

```powershell
npm run check
npm run test
npm run smoke:progress
npm run clean:smoke
```

`npm run check` parses all PowerShell scripts, verifies required project files, and runs workflow tests. It does not call Codex or external APIs.

`npm run test` invokes Pester when installed. If Pester is unavailable, the launcher runs a minimal fallback assertion set for the shared module.

`npm run smoke:progress` feeds sample JSONL events into `cli-progress-bridge.js`.

`npm run clean:smoke` removes output directories with `smoke` in the name under workflow-owned output roots only.

## Release Checklist

1. Run `npm run check`.
2. Run `npm run smoke:progress`.
3. Start the menu once with `powershell -ExecutionPolicy Bypass -File .\Start-CodexWorkflow.ps1`.
4. Confirm defaults point to `runs\text` and `runs\images`.
5. Confirm conversation resume offers an incomplete `conversation_state.json` when one exists.
6. Confirm no generated output or local config is staged.
