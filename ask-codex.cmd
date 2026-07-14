@echo off
setlocal
if /I "%~1"=="--quick" goto quick
if /I "%~1"=="-q" goto quick

powershell.exe -ExecutionPolicy Bypass -File "%~dp0Start-CodexWorkflow.ps1"
exit /b %ERRORLEVEL%

:quick
set /p CODEX_PROMPT=Input prompt for Codex CLI:
if "%CODEX_PROMPT%"=="" (
  echo Prompt is empty.
  exit /b 1
)

powershell.exe -ExecutionPolicy Bypass -File "%~dp0Invoke-CodexCliAsk.ps1" -Prompt "%CODEX_PROMPT%"
exit /b %ERRORLEVEL%
