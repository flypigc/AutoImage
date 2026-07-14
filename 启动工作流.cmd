@echo off
setlocal
chcp 65001 >nul
set "SCRIPT_DIR=%~dp0"

if /I "%~1"=="--quick" goto quick
if /I "%~1"=="-q" goto quick

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Start-CodexWorkflow.ps1" -Language zh-CN
exit /b %ERRORLEVEL%

:quick
set /p "CODEX_PROMPT=Input prompt for Codex: "
if not defined CODEX_PROMPT (
  echo Prompt is empty.
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Invoke-CodexCliAsk.ps1" -Prompt "%CODEX_PROMPT%" -NoReopenWindow
exit /b %ERRORLEVEL%
