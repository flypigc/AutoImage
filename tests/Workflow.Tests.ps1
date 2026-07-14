$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'WorkflowCommon.psm1') -Force

Describe 'WorkflowCommon' {
    It 'wraps selection indexes in both directions' {
        Move-WorkflowSelectionIndex -Current 0 -Delta -1 -Count 6 | Should Be 5
        Move-WorkflowSelectionIndex -Current 5 -Delta 1 -Count 6 | Should Be 0
        Move-WorkflowSelectionIndex -Current 2 -Delta 1 -Count 6 | Should Be 3
        Move-WorkflowSelectionIndex -Current 2 -Delta -1 -Count 6 | Should Be 1
    }

    It 'handles empty and out-of-range selection indexes' {
        Move-WorkflowSelectionIndex -Current 4 -Delta 1 -Count 0 | Should Be 0
        Move-WorkflowSelectionIndex -Current 8 -Delta 1 -Count 6 | Should Be 3
        Move-WorkflowSelectionIndex -Current -1 -Delta -1 -Count 6 | Should Be 4
    }

    It 'creates stable ASCII slugs' {
        New-Slug -Text 'Hello, World!' | Should Be 'hello-world'
        New-Slug -Text '中文标题' -Fallback 'fallback' | Should Be 'fallback'
    }

    It 'splits prompt files on delimiter lines' {
        $segments = @(Get-PromptSegments -Text "Prompt A`n---`nPrompt B`n`n---`n")

        $segments.Count | Should Be 2
        $segments[0] | Should Be 'Prompt A'
        $segments[1] | Should Be 'Prompt B'
    }

    It 'parses grouped conversation files consistently' {
        $groups = @(Get-WorkflowConversationGroups -Text "A`n---`nB`n------`nC`n---`nD")

        $groups.Count | Should Be 2
        @($groups[0].Prompts).Count | Should Be 2
        @($groups[1].Prompts).Count | Should Be 2
    }

    It 'builds first-turn Codex exec arguments with workspace options' {
        $arguments = @(New-CodexExecArguments `
            -WorkspacePath 'C:\workspace' `
            -LastMessagePath 'C:\result.md' `
            -PromptText 'hello' `
            -Model 'gpt-test' `
            -Profile 'profile-a')

        ($arguments -contains '--color') | Should Be $true
        ($arguments -contains '-C') | Should Be $true
        ($arguments -contains '-p') | Should Be $true
        $arguments[-1] | Should Be 'hello'
    }

    It 'builds resume arguments using only options accepted by codex exec resume' {
        $threadId = '019f5ec1-8183-7722-9f68-35398bbfeb5d'
        $arguments = @(New-CodexExecArguments `
            -WorkspacePath 'C:\workspace' `
            -LastMessagePath 'C:\result.md' `
            -PromptText 'continue' `
            -Model 'gpt-test' `
            -Profile 'profile-a' `
            -ResumeThreadId $threadId)

        $arguments[0] | Should Be 'exec'
        $arguments[1] | Should Be 'resume'
        ($arguments -contains '--color') | Should Be $false
        ($arguments -contains '-C') | Should Be $false
        ($arguments -contains '-p') | Should Be $false
        $arguments[-2] | Should Be $threadId
        $arguments[-1] | Should Be 'continue'
    }

    It 'resolves workflow-relative paths from the initialized root' {
        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-workflow-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testRoot | Out-Null
        try {
            Initialize-WorkflowCommon -Root $testRoot
            Resolve-WorkflowPath -Path 'runs\text' | Should Be (Join-Path $testRoot 'runs\text')
        }
        finally {
            Initialize-WorkflowCommon -Root $root
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'allows cleanup only inside workflow-owned roots' {
        Initialize-WorkflowCommon -Root $root

        Test-WorkflowCleanTarget -Path (Join-Path $root 'runs\smoke-test') | Should Be $true
        Test-WorkflowCleanTarget -Path $root | Should Be $false
        Test-WorkflowCleanTarget -Path ([System.IO.Path]::GetPathRoot($root)) | Should Be $false
    }

    It 'appends JSONL run index entries' {
        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-workflow-index-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testRoot | Out-Null
        try {
            Initialize-WorkflowCommon -Root $testRoot
            $indexPath = Write-WorkflowRunIndex -Entry @{
                type = 'test'
                status = 'success'
                runDirectory = $testRoot
            }

            Test-Path -LiteralPath $indexPath -PathType Leaf | Should Be $true
            $line = Get-Content -LiteralPath $indexPath -Encoding UTF8 | Select-Object -First 1
            ($line | ConvertFrom-Json).type | Should Be 'test'
        }
        finally {
            Initialize-WorkflowCommon -Root $root
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'streams Codex process output to the console and log' {
        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-workflow-stream-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testRoot | Out-Null
        try {
            $fakeCodexPath = Join-Path $testRoot 'fake-codex.ps1'
            $consoleLogPath = Join-Path $testRoot 'console.log'
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
                $result = Invoke-CodexCliExec `
                    -CliPaths @{ CommandPath = $fakeCodexPath; NodeExe = ''; CodexJs = '' } `
                    -Arguments @('exec', 'prompt') `
                    -PromptText 'prompt' `
                    -ConsoleLogPath $consoleLogPath `
                    -WorkspacePath $testRoot `
                    -TimeoutSeconds 30
            }
            finally {
                [Console]::SetOut($originalOut)
                [Console]::SetError($originalError)
                $capturedOut.Dispose()
                $capturedError.Dispose()
            }

            $result.ExitCode | Should Be 0
            $capturedOut.ToString().Contains('codex stdout line') | Should Be $true
            $capturedError.ToString().Contains('codex stderr line') | Should Be $true

            $logText = Get-Content -LiteralPath $consoleLogPath -Raw -Encoding UTF8
            $logText.Contains('codex stdout line') | Should Be $true
            $logText.Contains('codex stderr line') | Should Be $true
        }
        finally {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'persists image batch state and returns failure for partial failures' {
        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-workflow-image-batch-' + [guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
        try {
            $batchScript = Join-Path $root 'Start-CodexImageBatch.ps1'
            $fakeWorker = Join-Path $root 'tests\FakeImageWorker.ps1'
            $promptFile = Join-Path $root 'tests\image-batch-smoke.txt'
            $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $batchScript `
                -PromptFile $promptFile `
                -CodexScript $fakeWorker `
                -OutputRoot $testRoot `
                -MaxConcurrency 2 `
                -ImageRequestTimeoutSeconds 5 `
                -Wait)
            $exitCode = $LASTEXITCODE

            $exitCode | Should Be 1
            $statePath = (Get-ChildItem -LiteralPath $testRoot -Recurse -Filter batch_state.json | Select-Object -First 1).FullName
            Test-Path -LiteralPath $statePath -PathType Leaf | Should Be $true
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $state.Status | Should Be 'failed'
            $state.SuccessCount | Should Be 2
            $state.FailedCount | Should Be 1

            $retryOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $batchScript `
                -PromptFile $promptFile `
                -CodexScript $fakeWorker `
                -OutputRoot $testRoot `
                -MaxConcurrency 2 `
                -ImageRequestTimeoutSeconds 5 `
                -ResumeStatePath $statePath `
                -RetryFailed `
                -Wait)
            $LASTEXITCODE | Should Be 1
            (($retryOutput -join "`n").Contains('batch: 1 jobs')) | Should Be $true
        }
        finally {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps background image batches bounded and honors cancellation state' {
        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-workflow-image-cancel-' + [guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
        $process = $null
        try {
            $batchScript = Join-Path $root 'Start-CodexImageBatch.ps1'
            $fakeWorker = Join-Path $root 'tests\FakeImageWorker.ps1'
            $promptFile = Join-Path $root 'tests\image-batch-cancel-smoke.txt'
            $stdoutPath = Join-Path $testRoot 'scheduler.stdout.log'
            $stderrPath = Join-Path $testRoot 'scheduler.stderr.log'
            $process = Start-Process -FilePath powershell.exe -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $batchScript,
                '-PromptFile', $promptFile, '-CodexScript', $fakeWorker,
                '-OutputRoot', $testRoot, '-MaxConcurrency', '2',
                '-ImageRequestTimeoutSeconds', '5'
            ) -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru

            $statePath = $null
            $deadline = (Get-Date).AddSeconds(8)
            while ((Get-Date) -lt $deadline -and -not $statePath) {
                $stateFile = Get-ChildItem -LiteralPath $testRoot -Recurse -Filter batch_state.json -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($stateFile) { $statePath = $stateFile.FullName }
                if (-not $statePath) { Start-Sleep -Milliseconds 100 }
            }
            [string]::IsNullOrWhiteSpace($statePath) | Should Be $false

            $state = $null
            $deadline = (Get-Date).AddSeconds(8)
            do {
                $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if (@($state.Jobs | Where-Object Status -eq 'running').Count -eq 0) { Start-Sleep -Milliseconds 100 }
            } while ((Get-Date) -lt $deadline -and @($state.Jobs | Where-Object Status -eq 'running').Count -eq 0)
            @($state.Jobs | Where-Object Status -eq 'running').Count -le 2 | Should Be $true
            @($state.Jobs | Where-Object Status -eq 'running').Count -gt 0 | Should Be $true

            $state.Status = 'cancel_requested'
            [System.IO.File]::WriteAllText(($statePath + '.cancel'), (Get-Date).ToString('o'), [System.Text.UTF8Encoding]::new($false))
            $temporaryPath = $statePath + '.cancel.tmp'
            [System.IO.File]::WriteAllText($temporaryPath, ($state | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $temporaryPath -Destination $statePath -Force

            $process.WaitForExit(10000) | Should Be $true
            $process.WaitForExit()
            $process.Refresh()
            $finalState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $finalState.Status | Should Be 'canceled'
        }
        finally {
            if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
            if ($process) { $process.Dispose() }
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
