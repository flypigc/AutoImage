Set-StrictMode -Version Latest

$script:WorkflowRoot = $PSScriptRoot
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Initialize-WorkflowCommon {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $script:WorkflowRoot = [System.IO.Path]::GetFullPath($Root)
}

function Resolve-WorkflowPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [switch]$MustExist
    )

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    }
    else {
        Join-Path $script:WorkflowRoot $Path
    }

    if ($MustExist) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    return [System.IO.Path]::GetFullPath($candidate)
}

function Get-RelativeWorkflowPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $basePath = [System.IO.Path]::GetFullPath($script:WorkflowRoot)
    if (-not $basePath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $basePath += [System.IO.Path]::DirectorySeparatorChar
    }

    $targetPath = [System.IO.Path]::GetFullPath($Path)
    $baseUri = [System.Uri]$basePath
    $targetUri = [System.Uri]$targetPath
    $relative = [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/', '\')

    if ([string]::IsNullOrWhiteSpace($relative)) {
        return '.'
    }

    return $relative
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function New-Slug {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [int]$MaxLength = 48,
        [string]$Fallback = 'codex-run'
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Fallback
    }

    $trimmed = $Text.Trim()
    if ($trimmed.Length -gt $MaxLength) {
        $trimmed = $trimmed.Substring(0, $MaxLength)
    }

    $ascii = [regex]::Replace($trimmed.ToLowerInvariant(), '[^a-z0-9]+', '-')
    $ascii = $ascii.Trim('-')

    if ([string]::IsNullOrWhiteSpace($ascii)) {
        return $Fallback
    }

    return $ascii
}

function Convert-ToMarkdownCodeBlock {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [string]$Fence = '```'
    )

    if ($null -eq $Text) {
        $Text = ''
    }

    $normalized = $Text -replace "`r`n", "`n"
    return @(
        $Fence
        $normalized
        $Fence
    ) -join "`n"
}

function Get-PromptSegments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $normalized = $Text -replace "`r`n", "`n"
    $parts = [regex]::Split($normalized, '(?m)^\s*---+\s*$')
    $segments = New-Object System.Collections.Generic.List[string]

    foreach ($part in $parts) {
        $item = $part.Trim()
        if (-not [string]::IsNullOrWhiteSpace($item)) {
            [void]$segments.Add($item)
        }
    }

    return $segments.ToArray()
}

function New-CodexExecArguments {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspacePath,
        [Parameter(Mandatory = $true)][string]$LastMessagePath,
        [Parameter(Mandatory = $true)][string]$PromptText,
        [AllowEmptyString()][string]$Model = '',
        [AllowEmptyString()][string]$Profile = '',
        [AllowEmptyString()][string]$ResumeThreadId = ''
    )

    if ([string]::IsNullOrWhiteSpace($ResumeThreadId)) {
        $arguments = New-Object System.Collections.Generic.List[string]
        foreach ($argument in @('exec', '--skip-git-repo-check', '-C', $WorkspacePath, '--color', 'never', '--output-last-message', $LastMessagePath)) {
            [void]$arguments.Add($argument)
        }
        if (-not [string]::IsNullOrWhiteSpace($Model)) { [void]$arguments.Add('-m'); [void]$arguments.Add($Model) }
        if (-not [string]::IsNullOrWhiteSpace($Profile)) { [void]$arguments.Add('-p'); [void]$arguments.Add($Profile) }
        [void]$arguments.Add($PromptText)
        return @($arguments.ToArray())
    }

    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @('exec', 'resume', '--skip-git-repo-check', '--output-last-message', $LastMessagePath)) {
        [void]$arguments.Add($argument)
    }
    if (-not [string]::IsNullOrWhiteSpace($Model)) { [void]$arguments.Add('-m'); [void]$arguments.Add($Model) }
    [void]$arguments.Add($ResumeThreadId)
    [void]$arguments.Add($PromptText)
    return @($arguments.ToArray())
}

function Test-WorkflowConversationDelimiter {
    param([AllowEmptyString()][string]$Line)

    return $Line -match '^\s*-{3,}\s*$'
}

function Test-WorkflowConversationHardBreak {
    param([AllowEmptyString()][string]$Line)

    return $Line -match '^\s*-{6,}\s*$'
}

function Get-WorkflowConversationGroups {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lines = (($Text -replace "`r`n", "`n") -split "`n", 0, [System.StringSplitOptions]::None)
    $groups = New-Object System.Collections.Generic.List[object]
    $currentGroup = New-Object System.Collections.Generic.List[string]
    $currentPromptLines = New-Object System.Collections.Generic.List[string]
    $softDelimiterStreak = 0

    foreach ($line in $lines) {
        if (Test-WorkflowConversationDelimiter -Line $line) {
            if ($currentPromptLines.Count -gt 0) {
                $prompt = (($currentPromptLines.ToArray()) -join "`n").Trim()
                if (-not [string]::IsNullOrWhiteSpace($prompt)) { [void]$currentGroup.Add($prompt) }
                $currentPromptLines.Clear()
            }

            if (Test-WorkflowConversationHardBreak -Line $line) {
                if ($currentGroup.Count -gt 0) { [void]$groups.Add([pscustomobject]@{ Prompts = @($currentGroup.ToArray()) }) }
                $currentGroup = New-Object System.Collections.Generic.List[string]
                $softDelimiterStreak = 0
                continue
            }

            $softDelimiterStreak++
            if ($softDelimiterStreak -ge 2) {
                if ($currentGroup.Count -gt 0) { [void]$groups.Add([pscustomobject]@{ Prompts = @($currentGroup.ToArray()) }) }
                $currentGroup = New-Object System.Collections.Generic.List[string]
                $softDelimiterStreak = 0
            }
            continue
        }

        $softDelimiterStreak = 0
        [void]$currentPromptLines.Add($line)
    }

    if ($currentPromptLines.Count -gt 0) {
        $prompt = (($currentPromptLines.ToArray()) -join "`n").Trim()
        if (-not [string]::IsNullOrWhiteSpace($prompt)) { [void]$currentGroup.Add($prompt) }
    }
    if ($currentGroup.Count -gt 0) { [void]$groups.Add([pscustomobject]@{ Prompts = @($currentGroup.ToArray()) }) }

    return @($groups.ToArray())
}

function Get-RequiredCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required command not found: $Name"
    }

    return $command
}

function Get-CodexCliPaths {
    $codexCommand = Get-RequiredCommand -Name 'codex'
    $commandPath = if ([string]::IsNullOrWhiteSpace($codexCommand.Source)) {
        $codexCommand.Definition
    }
    else {
        $codexCommand.Source
    }

    $result = @{
        CommandPath = $commandPath
        WrapperPath = $commandPath
        NodeExe = $null
        CodexJs = $null
    }

    if (Test-Path -LiteralPath $commandPath -PathType Leaf) {
        try {
            $wrapperText = [System.IO.File]::ReadAllText($commandPath, $script:Utf8NoBom)
            $nodeDirMatch = [regex]::Match($wrapperText, '\$nodeDir\s*=\s*"([^"]+)"')
            if ($nodeDirMatch.Success) {
                $nodeDir = $nodeDirMatch.Groups[1].Value
                $nodeExe = Join-Path $nodeDir 'node.exe'
                $codexJs = Join-Path $nodeDir 'node_modules\@openai\codex\bin\codex.js'
                if ((Test-Path -LiteralPath $nodeExe) -and (Test-Path -LiteralPath $codexJs)) {
                    $result.NodeExe = $nodeExe
                    $result.CodexJs = $codexJs
                }
            }
        }
        catch {
        }
    }

    return $result
}

function Invoke-CodexCliExec {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CliPaths,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$PromptText,
        [Parameter(Mandatory = $true)]
        [string]$ConsoleLogPath,
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,
        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 600,
        [hashtable]$EnvironmentOverrides = @{}
    )

    function ConvertTo-WorkflowProcessArgument {
        param(
            [AllowEmptyString()]
            [string]$Value
        )

        if ($null -eq $Value) {
            return '""'
        }

        if ($Value -notmatch '[\s"]') {
            return $Value
        }

        return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
    }

    function Stop-WorkflowProcessTree {
        param([int]$ProcessId)

        try {
            $taskkill = Get-Command taskkill.exe -ErrorAction SilentlyContinue
            if ($taskkill) {
                & $taskkill.Source /PID $ProcessId /T /F | Out-Null
                return
            }
        }
        catch {
        }

        try {
            $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue)
            foreach ($child in $children) {
                Stop-WorkflowProcessTree -ProcessId ([int]$child.ProcessId)
            }
        }
        catch {
        }

        try {
            Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        }
        catch {
        }
    }

    function Invoke-WorkflowProcess {
        param(
            [Parameter(Mandatory = $true)]
            [string]$FilePath,
            [Parameter(Mandatory = $true)]
            [string[]]$ArgumentList,
            [hashtable]$EnvironmentOverrides = @{}
        )

        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $ConsoleLogPath)) | Out-Null
        [System.IO.File]::WriteAllText($ConsoleLogPath, "Starting Codex CLI...`r`n", $script:Utf8NoBom)

        function Write-WorkflowProcessConsoleLine {
            param(
                [AllowEmptyString()]
                [string]$Line,
                [ValidateSet('Output', 'Error')]
                [string]$Stream
            )

            if ($Stream -eq 'Error') {
                [Console]::Error.WriteLine($Line)
                return
            }

            [Console]::Out.WriteLine($Line)
        }

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $FilePath
        $startInfo.WorkingDirectory = $WorkspacePath
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        $startInfo.StandardOutputEncoding = $script:Utf8NoBom
        $startInfo.StandardErrorEncoding = $script:Utf8NoBom
        $startInfo.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-WorkflowProcessArgument -Value ([string]$_) }) -join ' ')
        foreach ($name in $EnvironmentOverrides.Keys) {
            $value = [string]$EnvironmentOverrides[$name]
            if (-not [string]::IsNullOrWhiteSpace($name) -and -not [string]::IsNullOrWhiteSpace($value)) {
                $startInfo.Environment[$name] = $value
            }
        }

        $outputLines = [System.Collections.ArrayList]::new()
        $writer = [System.IO.StreamWriter]::new($ConsoleLogPath, $true, $script:Utf8NoBom)
        $writer.AutoFlush = $true
        $timedOut = $false
        $startedAt = Get-Date

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo

        try {
            [void]$process.Start()

            $writer.WriteLine(("Command: {0} {1}" -f $FilePath, $startInfo.Arguments))
            $writer.WriteLine("Timeout seconds: {0}" -f $TimeoutSeconds)

            # Codex may read additional stdin when a prompt is supplied as an argument.
            # Close stdin explicitly so non-interactive runs cannot hang on the menu console.
            $process.StandardInput.Close()

            $stdoutClosed = $false
            $stderrClosed = $false
            $stdoutTask = $process.StandardOutput.ReadLineAsync()
            $stderrTask = $process.StandardError.ReadLineAsync()

            while (-not ($process.HasExited -and $stdoutClosed -and $stderrClosed)) {
                if (-not $stdoutClosed -and $stdoutTask.IsCompleted) {
                    $line = $stdoutTask.Result
                    if ($null -eq $line) {
                        $stdoutClosed = $true
                    }
                    else {
                        [void]$outputLines.Add([string]$line)
                        $writer.WriteLine([string]$line)
                        Write-WorkflowProcessConsoleLine -Line ([string]$line) -Stream Output
                        $stdoutTask = $process.StandardOutput.ReadLineAsync()
                    }
                }

                if (-not $stderrClosed -and $stderrTask.IsCompleted) {
                    $line = $stderrTask.Result
                    if ($null -eq $line) {
                        $stderrClosed = $true
                    }
                    else {
                        [void]$outputLines.Add([string]$line)
                        $writer.WriteLine([string]$line)
                        Write-WorkflowProcessConsoleLine -Line ([string]$line) -Stream Error
                        $stderrTask = $process.StandardError.ReadLineAsync()
                    }
                }

                if (((Get-Date) - $startedAt).TotalSeconds -ge $TimeoutSeconds) {
                    $timedOut = $true
                    $writer.WriteLine("Timed out after {0} seconds. Terminating process tree." -f $TimeoutSeconds)
                    Stop-WorkflowProcessTree -ProcessId $process.Id
                    break
                }

                Start-Sleep -Milliseconds 50
            }

            try {
                $process.WaitForExit()
            }
            catch {
            }

            $finishedAt = Get-Date
            $exitCode = if ($timedOut) { 124 } elseif ($process.HasExited) { [int]$process.ExitCode } else { 1 }
            $writer.WriteLine("Exit code: {0}" -f $exitCode)
            $writer.WriteLine("Duration seconds: {0}" -f ([math]::Round(($finishedAt - $startedAt).TotalSeconds, 2)))

            return @{
                ExitCode = $exitCode
                OutputLines = @($outputLines.ToArray())
                TimedOut = $timedOut
                StartedAt = $startedAt
                FinishedAt = $finishedAt
            }
        }
        finally {
            try { $writer.Dispose() } catch {}
            try { $process.Dispose() } catch {}
        }
    }

    $directArguments = @($Arguments)
    $directFilePath = [string]$CliPaths.CommandPath
    if ($directFilePath.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        $directArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $directFilePath) + $directArguments
        $directFilePath = 'powershell.exe'
    }

    try {
        return (Invoke-WorkflowProcess -FilePath $directFilePath -ArgumentList $directArguments -EnvironmentOverrides $EnvironmentOverrides)
    }
    catch {
        if ([string]::IsNullOrWhiteSpace([string]$CliPaths.NodeExe) -or [string]::IsNullOrWhiteSpace([string]$CliPaths.CodexJs)) {
            throw
        }

        return (Invoke-WorkflowProcess -FilePath $CliPaths.NodeExe -ArgumentList (@($CliPaths.CodexJs) + @($Arguments)) -EnvironmentOverrides $EnvironmentOverrides)
    }
}

function Test-WorkflowApiSwitchableFailure {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [int]$ExitCode = 1,
        [switch]$TimedOut
    )

    if ($TimedOut -or $ExitCode -eq 124) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return ($Text -match '(?i)(OPENAI_API_KEY is not set|timeout|timed out|temporar|rate_limit|429|500|502|503|504|bad gateway|service unavailable|gateway timeout|too many requests|connection|connect|socket|network|proxy|tls|ssl|econnreset|econnrefused|etimedout|enotfound|eai_again)')
}

function Write-WorkflowRunIndex {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Entry
    )

    $runsRoot = Join-Path $script:WorkflowRoot 'runs'
    [System.IO.Directory]::CreateDirectory($runsRoot) | Out-Null
    $indexPath = Join-Path $runsRoot 'index.jsonl'
    $json = $Entry | ConvertTo-Json -Compress -Depth 8

    $mutexNameSource = [System.IO.Path]::GetFullPath($script:WorkflowRoot).ToLowerInvariant()
    $mutexHash = [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash($script:Utf8NoBom.GetBytes($mutexNameSource))
    ).Replace('-', '')
    $mutex = [System.Threading.Mutex]::new($false, "Global\CodexWorkflowRunIndex-$mutexHash")
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
        if (-not $hasLock) {
            throw "Timed out waiting for run index lock: $indexPath"
        }

        [System.IO.File]::AppendAllText($indexPath, $json + "`n", $script:Utf8NoBom)
    }
    finally {
        if ($hasLock) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }

    return $indexPath
}

function Get-WorkflowDirectoryStats {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{
            Path = $Path
            Exists = $false
            Files = 0
            SizeBytes = 0
            SizeMB = 0
        }
    }

    $measure = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    $bytes = if ($measure.Sum) { [int64]$measure.Sum } else { [int64]0 }

    return [pscustomobject]@{
        Path = $Path
        Exists = $true
        Files = [int]$measure.Count
        SizeBytes = $bytes
        SizeMB = [math]::Round($bytes / 1MB, 2)
    }
}

function Move-WorkflowSelectionIndex {
    param(
        [int]$Current,
        [int]$Delta,
        [int]$Count
    )

    if ($Count -le 0) {
        return 0
    }

    $normalizedCurrent = (($Current % $Count) + $Count) % $Count
    return (($normalizedCurrent + $Delta) % $Count + $Count) % $Count
}

function Test-WorkflowCleanTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string[]]$AllowedRoots = @()
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $workflowRoot = [System.IO.Path]::GetFullPath($script:WorkflowRoot).TrimEnd('\', '/')
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\', '/')

    if ($fullPath -eq $pathRoot -or $fullPath -eq $workflowRoot) {
        return $false
    }

    $effectiveRoots = if ($AllowedRoots.Count -gt 0) {
        $AllowedRoots
    }
    else {
        @(
            (Join-Path $workflowRoot 'runs'),
            (Join-Path $workflowRoot 'codex_cli_runs'),
            (Join-Path $workflowRoot 'pic')
        )
    }

    foreach ($root in $effectiveRoots) {
        $allowed = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
        if ($fullPath -eq $allowed -or $fullPath.StartsWith($allowed + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

Export-ModuleMember -Function @(
    'Initialize-WorkflowCommon',
    'Resolve-WorkflowPath',
    'Get-RelativeWorkflowPath',
    'Write-Utf8NoBomFile',
    'New-Slug',
    'Convert-ToMarkdownCodeBlock',
    'Get-PromptSegments',
    'New-CodexExecArguments',
    'Get-WorkflowConversationGroups',
    'Get-RequiredCommand',
    'Get-CodexCliPaths',
    'Invoke-CodexCliExec',
    'Test-WorkflowApiSwitchableFailure',
    'Write-WorkflowRunIndex',
    'Get-WorkflowDirectoryStats',
    'Move-WorkflowSelectionIndex',
    'Test-WorkflowCleanTarget'
)
