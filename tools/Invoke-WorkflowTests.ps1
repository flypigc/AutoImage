[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$testPath = Join-Path $root 'tests'
$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1

if ($pester) {
    Import-Module $pester.Path -Force
    $result = Invoke-Pester -Script $testPath -PassThru
    if ($result.FailedCount -gt 0) {
        exit 1
    }

    exit 0
}

Import-Module (Join-Path $root 'WorkflowCommon.psm1') -Force

function Assert-WorkflowTest {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

Initialize-WorkflowCommon -Root $root
Assert-WorkflowTest -Condition ((Move-WorkflowSelectionIndex -Current 0 -Delta -1 -Count 6) -eq 5) -Message 'Selection index did not wrap upward.'
Assert-WorkflowTest -Condition ((Move-WorkflowSelectionIndex -Current 5 -Delta 1 -Count 6) -eq 0) -Message 'Selection index did not wrap downward.'
Assert-WorkflowTest -Condition ((New-Slug -Text 'Hello, World!') -eq 'hello-world') -Message 'New-Slug failed.'
Assert-WorkflowTest -Condition (@(Get-PromptSegments -Text "A`n---`nB").Count -eq 2) -Message 'Get-PromptSegments failed.'
Assert-WorkflowTest -Condition (Test-WorkflowCleanTarget -Path (Join-Path $root 'runs\smoke-test')) -Message 'Clean target allow-list failed.'
Assert-WorkflowTest -Condition (-not (Test-WorkflowCleanTarget -Path $root)) -Message 'Clean target root rejection failed.'

$streamTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-workflow-stream-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $streamTestRoot | Out-Null
try {
    $fakeCodexPath = Join-Path $streamTestRoot 'fake-codex.ps1'
    $consoleLogPath = Join-Path $streamTestRoot 'console.log'
    @'
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

[Console]::Out.WriteLine('codex stdout line')
[Console]::Error.WriteLine('codex stderr line')
'@ | Set-Content -LiteralPath $fakeCodexPath -Encoding UTF8

    $originalOut = [Console]::Out
    $originalError = [Console]::Error
    $capturedOut = [System.IO.StringWriter]::new()
    $capturedError = [System.IO.StringWriter]::new()
    try {
        [Console]::SetOut($capturedOut)
        [Console]::SetError($capturedError)
        $streamResult = Invoke-CodexCliExec `
            -CliPaths @{ CommandPath = $fakeCodexPath; NodeExe = ''; CodexJs = '' } `
            -Arguments @('exec', 'prompt') `
            -PromptText 'prompt' `
            -ConsoleLogPath $consoleLogPath `
            -WorkspacePath $streamTestRoot `
            -TimeoutSeconds 30
    }
    finally {
        [Console]::SetOut($originalOut)
        [Console]::SetError($originalError)
        $capturedOut.Dispose()
        $capturedError.Dispose()
    }

    Assert-WorkflowTest -Condition ([int]$streamResult.ExitCode -eq 0) -Message 'Invoke-CodexCliExec fake process failed.'
    Assert-WorkflowTest -Condition ($capturedOut.ToString().Contains('codex stdout line')) -Message 'Codex stdout was not streamed to the console.'
    Assert-WorkflowTest -Condition ($capturedError.ToString().Contains('codex stderr line')) -Message 'Codex stderr was not streamed to the console.'

    $streamLogText = Get-Content -LiteralPath $consoleLogPath -Raw -Encoding UTF8
    Assert-WorkflowTest -Condition ($streamLogText.Contains('codex stdout line')) -Message 'Codex stdout was not written to console.log.'
    Assert-WorkflowTest -Condition ($streamLogText.Contains('codex stderr line')) -Message 'Codex stderr was not written to console.log.'
}
finally {
    Remove-Item -LiteralPath $streamTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Pester not installed; fallback workflow tests passed.'
