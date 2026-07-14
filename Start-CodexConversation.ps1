[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConversationFile,

    [string]$Workspace = '.',
    [string]$OutputRoot = '.\runs\text',
    [string]$RunName,
    [string]$Model,
    [string]$Profile,
    [string]$TextApiKey,
    [string]$TextBaseUrl,
    [string]$TextApiProfilesJson,
    [string]$SummaryPrompt,
    [string]$SummaryPromptFile,
    [string]$ResumeStatePath,
    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

. (Join-Path $ScriptRoot 'WorkflowProgressUi.ps1')
Import-Module (Join-Path $ScriptRoot 'WorkflowCommon.psm1') -Force
Initialize-WorkflowCommon -Root $ScriptRoot
$script:TextApiKeyOverride = $TextApiKey
$script:TextBaseUrlOverride = $TextBaseUrl
$script:TextApiProfilesJson = $TextApiProfilesJson

function Get-TextApiEnvironmentOverrides {
    param(
        [AllowNull()]
        [object]$Profile = $null
    )

    $apiKey = $script:TextApiKeyOverride
    $baseUrl = $script:TextBaseUrlOverride
    if ($null -ne $Profile) {
        $apiKeyProperty = $Profile.PSObject.Properties["ApiKey"]
        $baseUrlProperty = $Profile.PSObject.Properties["BaseUrl"]
        if ($apiKeyProperty) { $apiKey = [string]$apiKeyProperty.Value }
        if ($baseUrlProperty) { $baseUrl = [string]$baseUrlProperty.Value }
    }

    $overrides = @{}
    if (-not [string]::IsNullOrWhiteSpace($apiKey)) {
        $overrides.OPENAI_API_KEY = $apiKey
    }

    if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
        $overrides.OPENAI_BASE_URL = $baseUrl
        $overrides.OPENAI_API_BASE = $baseUrl
    }

    return $overrides
}

function ConvertFrom-ApiProfilesJson {
    param(
        [AllowEmptyString()]
        [string]$Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return @()
    }

    try {
        $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
        $items = if ($parsed -is [array]) { @($parsed) } else { @($parsed) }
        return @($items | Where-Object { $null -ne $_ })
    }
    catch {
        throw "Invalid API profiles JSON: $($_.Exception.Message)"
    }
}

function Get-ApiProfileName {
    param(
        [AllowNull()]
        [object]$Profile,
        [int]$Index
    )

    if ($null -ne $Profile) {
        $nameProperty = $Profile.PSObject.Properties["Name"]
        if ($nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
            return [string]$nameProperty.Value
        }
    }

    return "API profile $Index"
}

function Get-ApiProfileModel {
    param(
        [AllowNull()]
        [object]$Profile
    )

    if ($null -ne $Profile) {
        $modelProperty = $Profile.PSObject.Properties["Model"]
        if ($modelProperty -and -not [string]::IsNullOrWhiteSpace([string]$modelProperty.Value)) {
            return [string]$modelProperty.Value
        }
    }

    return ""
}

function Get-CodexArgumentsForApiProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [AllowNull()]
        [object]$Profile
    )

    $profileModel = Get-ApiProfileModel -Profile $Profile
    if ([string]::IsNullOrWhiteSpace($profileModel)) {
        return @($Arguments)
    }

    $result = New-Object System.Collections.Generic.List[string]
    $replaced = $false
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -eq '-m' -and ($i + 1) -lt $Arguments.Count) {
            [void]$result.Add('-m')
            [void]$result.Add($profileModel)
            $i++
            $replaced = $true
            continue
        }

        [void]$result.Add($Arguments[$i])
    }

    if (-not $replaced) {
        $positionalCount = if ($result.Count -gt 1 -and $result[1] -eq 'resume') { 2 } else { 1 }
        $insertAt = [Math]::Max(1, $result.Count - $positionalCount)
        $result.Insert($insertAt, '-m')
        $result.Insert($insertAt + 1, $profileModel)
    }

    return @($result.ToArray())
}

function Get-TextApiProfiles {
    $profiles = @(ConvertFrom-ApiProfilesJson -Json $script:TextApiProfilesJson)
    if ($profiles.Count -gt 0) {
        return $profiles
    }

    if (-not [string]::IsNullOrWhiteSpace($script:TextApiKeyOverride) -or -not [string]::IsNullOrWhiteSpace($script:TextBaseUrlOverride)) {
        return @([pscustomobject]@{
            Name = "text primary"
            ApiKey = $script:TextApiKeyOverride
            BaseUrl = $script:TextBaseUrlOverride
            Model = $Model
        })
    }

    return @([pscustomobject]@{
        Name = "Codex default"
        ApiKey = ""
        BaseUrl = ""
        Model = $Model
    })
}

function Invoke-CodexCliExecWithTextApiFallback {
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
        [int]$TimeoutSeconds = 600
    )

    $profiles = @(Get-TextApiProfiles)
    $lastResult = $null
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $profile = $profiles[$i]
        $profileName = Get-ApiProfileName -Profile $profile -Index ($i + 1)
        if ($profiles.Count -gt 1) {
            Write-Host ("Using text API profile {0}/{1}: {2}" -f ($i + 1), $profiles.Count, $profileName)
        }

        try {
            $result = Invoke-CodexCliExec `
                -CliPaths $CliPaths `
                -Arguments (Get-CodexArgumentsForApiProfile -Arguments $Arguments -Profile $profile) `
                -PromptText $PromptText `
                -ConsoleLogPath $ConsoleLogPath `
                -WorkspacePath $WorkspacePath `
                -TimeoutSeconds $TimeoutSeconds `
                -EnvironmentOverrides (Get-TextApiEnvironmentOverrides -Profile $profile)
        }
        catch {
            if ($i -ge ($profiles.Count - 1) -or -not (Test-WorkflowApiSwitchableFailure -Text ($_ | Out-String))) {
                throw
            }

            Write-Host ("Text API profile failed, switching: {0}" -f $profileName) -ForegroundColor Yellow
            continue
        }

        $lastResult = $result
        if ([int]$result.ExitCode -eq 0) {
            return $result
        }

        $outputText = (@($result.OutputLines) -join "`n")
        if ($i -ge ($profiles.Count - 1) -or -not (Test-WorkflowApiSwitchableFailure -Text $outputText -ExitCode ([int]$result.ExitCode) -TimedOut:([bool]$result.TimedOut))) {
            return $result
        }

        Write-Host ("Text API profile returned a transient failure, switching: {0}" -f $profileName) -ForegroundColor Yellow
    }

    return $lastResult
}

function Test-DelimiterLine {
    param(
        [AllowEmptyString()]
        [string]$Line
    )

    return $Line -match '^\s*-{3,}\s*$'
}

function Test-HardBreakLine {
    param(
        [AllowEmptyString()]
        [string]$Line
    )

    return $Line -match '^\s*-{6,}\s*$'
}

function Get-ConversationGroupsFromText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $normalized = $Text -replace "`r`n", "`n"
    $lines = $normalized -split "`n", 0, [System.StringSplitOptions]::None

    $groups = New-Object System.Collections.Generic.List[object]
    $currentGroup = New-Object System.Collections.Generic.List[string]
    $currentPromptLines = New-Object System.Collections.Generic.List[string]
    $softDelimiterStreak = 0

    foreach ($line in $lines) {
        if (Test-DelimiterLine -Line $line) {
            if ($currentPromptLines.Count -gt 0) {
                $prompt = (($currentPromptLines.ToArray()) -join "`n").Trim()
                if (-not [string]::IsNullOrWhiteSpace($prompt)) {
                    [void]$currentGroup.Add($prompt)
                }
                $currentPromptLines.Clear()
            }

            if (Test-HardBreakLine -Line $line) {
                if ($currentGroup.Count -gt 0) {
                    [void]$groups.Add([pscustomobject]@{
                        Prompts = @($currentGroup.ToArray())
                    })
                }
                $currentGroup = New-Object System.Collections.Generic.List[string]
                $softDelimiterStreak = 0
                continue
            }

            $softDelimiterStreak++
            if ($softDelimiterStreak -ge 2) {
                if ($currentGroup.Count -gt 0) {
                    [void]$groups.Add([pscustomobject]@{
                        Prompts = @($currentGroup.ToArray())
                    })
                }
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
        if (-not [string]::IsNullOrWhiteSpace($prompt)) {
            [void]$currentGroup.Add($prompt)
        }
    }

    if ($currentGroup.Count -gt 0) {
        [void]$groups.Add([pscustomobject]@{
            Prompts = @($currentGroup.ToArray())
        })
    }

    return @($groups.ToArray())
}

function Get-CodexRunResult {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$OutputLines
    )

    $agentMessages = New-Object System.Collections.Generic.List[string]
    $threadId = $null
    $usage = $null

    foreach ($lineObject in $OutputLines) {
        if ($null -eq $lineObject) {
            continue
        }

        $line = [string]$lineObject
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $sessionMatch = [regex]::Match($line, 'session id:\s*([0-9a-fA-F-]{36})')
            if ($sessionMatch.Success) {
                $threadId = $sessionMatch.Groups[1].Value
            }

            continue
        }

        if ($event.type -eq "thread.started" -and $event.thread_id) {
            $threadId = [string]$event.thread_id
            continue
        }

        if ($event.type -eq "turn.completed" -and $event.usage) {
            $usage = $event.usage
            continue
        }

        if ($event.type -eq "item.completed" -and $event.item -and $event.item.type -eq "agent_message" -and $event.item.text) {
            [void]$agentMessages.Add([string]$event.item.text)
        }
    }

    $lastMessage = ""
    if ($agentMessages.Count -gt 0) {
        $lastMessage = ($agentMessages.ToArray() -join "`r`n`r`n")
    }

    return @{
        LastMessage = $lastMessage
        ThreadId = $threadId
        Usage = $usage
    }
}

function Save-PromptRunSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SummaryPath,
        [Parameter(Mandatory = $true)]
        [string]$PromptText,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$LastMessageText,
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,
        [Parameter(Mandatory = $true)]
        [string]$RunDirectory,
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,
        [Parameter(Mandatory = $true)]
        [datetime]$StartedAt,
        [Parameter(Mandatory = $true)]
        [datetime]$FinishedAt,
        [Parameter(Mandatory = $true)]
        [string]$CodexCommandLine,
        [AllowNull()]
        [string]$ThreadId,
        [AllowNull()]
        [psobject]$Usage,
        [AllowEmptyString()]
        [string]$ResumedFromThreadId
    )

    $duration = [math]::Round(($FinishedAt - $StartedAt).TotalSeconds, 2)
    $status = if ($ExitCode -eq 0) { "success" } else { "failed" }

    $lines = @(
        "# Codex Conversation Prompt Run"
        ""
        "- Status: $status"
        "- Exit code: $ExitCode"
        "- Started: $($StartedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
        "- Finished: $($FinishedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
        "- Duration seconds: $duration"
        ('- Workspace: `{0}`' -f (Get-RelativeWorkflowPath -Path $WorkspacePath))
        ('- Run directory: `{0}`' -f (Get-RelativeWorkflowPath -Path $RunDirectory))
        ('- Command: `{0}`' -f $CodexCommandLine)
        ('- Thread ID: `{0}`' -f $ThreadId)
        ('- Resumed from: `{0}`' -f $ResumedFromThreadId)
        ""
        "## Usage"
        ""
        "- Input tokens: $(if ($Usage) { [string]$Usage.input_tokens } else { '' })"
        "- Cached input tokens: $(if ($Usage) { [string]$Usage.cached_input_tokens } else { '' })"
        "- Output tokens: $(if ($Usage) { [string]$Usage.output_tokens } else { '' })"
        "- Reasoning output tokens: $(if ($Usage) { [string]$Usage.reasoning_output_tokens } else { '' })"
        ""
        "## Prompt"
        ""
        (Convert-ToMarkdownCodeBlock -Text $PromptText)
        ""
        "## Final Answer"
        ""
        (Convert-ToMarkdownCodeBlock -Text $LastMessageText)
        ""
    )

    Write-Utf8NoBomFile -Path $SummaryPath -Text ($lines -join "`r`n")
}

function Save-GroupIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [int]$GroupIndex,
        [Parameter(Mandatory = $true)]
        [object[]]$PromptRuns,
        [Parameter(Mandatory = $true)]
        [string]$SummaryPromptText,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$SummaryText,
        [AllowNull()]
        [string]$ThreadId,
        [Parameter(Mandatory = $true)]
        [datetime]$StartedAt,
        [Parameter(Mandatory = $true)]
        [datetime]$FinishedAt
    )

    $duration = [math]::Round(($FinishedAt - $StartedAt).TotalSeconds, 2)
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("# Conversation Group $($GroupIndex)")
    [void]$lines.Add("")
    [void]$lines.Add("- Started: $($StartedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))")
    [void]$lines.Add("- Finished: $($FinishedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))")
    [void]$lines.Add("- Duration seconds: $duration")
    [void]$lines.Add(('- Thread ID before clear: `{0}`' -f $ThreadId))
    [void]$lines.Add("- Prompt count: $($PromptRuns.Count)")
    [void]$lines.Add("")
    [void]$lines.Add("## Prompt Runs")
    [void]$lines.Add("")

    foreach ($run in $PromptRuns) {
        [void]$lines.Add("### $($run.Index). $($run.Name)")
        [void]$lines.Add("")
        [void]$lines.Add("- Status: $($run.Status)")
        [void]$lines.Add("- Exit code: $($run.ExitCode)")
        [void]$lines.Add("- Directory: [$($run.DirectoryName)](./$($run.DirectoryName)/)")
        [void]$lines.Add("- Summary: [summary.md](./$($run.DirectoryName)/summary.md)")
        [void]$lines.Add("")
    }

    [void]$lines.Add("## Summary Prompt")
    [void]$lines.Add("")
    [void]$lines.Add((Convert-ToMarkdownCodeBlock -Text $SummaryPromptText))
    [void]$lines.Add("")
    [void]$lines.Add("## Summary Document")
    [void]$lines.Add("")
    [void]$lines.Add($SummaryText)
    [void]$lines.Add("")

    Write-Utf8NoBomFile -Path $Path -Text ($lines -join "`r`n")
}

function Save-ConversationIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,
        [Parameter(Mandatory = $true)]
        [string]$ConversationDirectory,
        [Parameter(Mandatory = $true)]
        [object[]]$GroupResults,
        [Parameter(Mandatory = $true)]
        [datetime]$StartedAt,
        [Parameter(Mandatory = $true)]
        [datetime]$FinishedAt
    )

    $duration = [math]::Round(($FinishedAt - $StartedAt).TotalSeconds, 2)
    $promptCount = @($GroupResults | ForEach-Object { $_.PromptRuns.Count } | Measure-Object -Sum).Sum

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("# Codex Conversation Run")
    [void]$lines.Add("")
    [void]$lines.Add("- Started: $($StartedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))")
    [void]$lines.Add("- Finished: $($FinishedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))")
    [void]$lines.Add("- Duration seconds: $duration")
    [void]$lines.Add(('- Workspace: `{0}`' -f (Get-RelativeWorkflowPath -Path $WorkspacePath)))
    [void]$lines.Add(('- Conversation directory: `{0}`' -f (Get-RelativeWorkflowPath -Path $ConversationDirectory)))
    [void]$lines.Add("- Group count: $($GroupResults.Count)")
    [void]$lines.Add("- Prompt count: $promptCount")
    [void]$lines.Add("")
    [void]$lines.Add("## Groups")
    [void]$lines.Add("")

    foreach ($group in $GroupResults) {
        [void]$lines.Add("### Group $($group.GroupIndex)")
        [void]$lines.Add("")
        [void]$lines.Add("- Directory: [$($group.DirectoryName)](./$($group.DirectoryName)/)")
        [void]$lines.Add("- Group index: [group_index.md](./$($group.DirectoryName)/group_index.md)")
        [void]$lines.Add("- Summary document: [group_summary.md](./$($group.DirectoryName)/group_summary.md)")
        [void]$lines.Add("- Prompt count: $($group.PromptRuns.Count)")
        [void]$lines.Add("")
    }

    Write-Utf8NoBomFile -Path $Path -Text ($lines -join "`r`n")
}

function Update-ConversationProgress {
    param(
        [Parameter(Mandatory = $true)]
        [int]$GroupNumber,
        [Parameter(Mandatory = $true)]
        [int]$GroupCount,
        [Parameter(Mandatory = $true)]
        [int]$CompletedOperations,
        [Parameter(Mandatory = $true)]
        [int]$TotalOperations,
        [Parameter(Mandatory = $true)]
        [int]$CompletedInGroup,
        [Parameter(Mandatory = $true)]
        [int]$GroupOperationCount,
        [Parameter(Mandatory = $true)]
        [string]$Phase,
        [AllowEmptyString()]
        [string]$RunName
    )

    $currentOperation = if ([string]::IsNullOrWhiteSpace($RunName)) { $Phase } else { $RunName }

    Write-WorkflowSerialProgress `
        -Key "conversation-batch" `
        -TotalLabel ("Conversation groups {0}/{1}" -f $GroupNumber, $GroupCount) `
        -TotalCompleted $CompletedOperations `
        -TotalCount $TotalOperations `
        -SubLabel ("Group {0}: {1}" -f $GroupNumber, $Phase) `
        -SubCompleted $CompletedInGroup `
        -SubCount $GroupOperationCount `
        -Status $currentOperation
}

function Write-TerminalRunResult {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Index,
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [AllowEmptyString()]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$MessagePath,
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $relativeMessagePath = Get-RelativeWorkflowPath -Path $MessagePath
    $status = if ($ExitCode -eq 0) { "success" } else { "failed" }
    $displayText = if ([string]::IsNullOrWhiteSpace($Text)) {
        "(No assistant message captured. Check the console log for details.)"
    }
    else {
        $Text.TrimEnd()
    }

    Move-WorkflowCursorBelowProgress
    Write-Host ""
    Write-Host ("[{0}] {1} ({2})" -f $Index, $Title, $status) -ForegroundColor Green
    Write-Host $displayText
    Write-Host ("saved: {0}" -f $relativeMessagePath) -ForegroundColor DarkGray
    Write-Host ""
}

function Invoke-CodexPromptRun {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CliPaths,
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,
        [Parameter(Mandatory = $true)]
        [string]$ParentDirectory,
        [Parameter(Mandatory = $true)]
        [string]$PromptText,
        [Parameter(Mandatory = $true)]
        [string]$RunName,
        [Parameter(Mandatory = $true)]
        [int]$Index,
        [AllowEmptyString()]
        [string]$Model,
        [AllowEmptyString()]
        [string]$Profile,
        [AllowNull()]
        [string]$ResumeThreadId,
        [int]$TimeoutSeconds = 600
    )

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $runDirectory = Join-Path $ParentDirectory ("{0}_{1}" -f $timestamp, (New-Slug -Text $RunName))
    [System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null

    $promptPath = Join-Path $runDirectory "prompt.txt"
    $lastMessagePath = Join-Path $runDirectory "assistant_last_message.md"
    $consoleLogPath = Join-Path $runDirectory "console.log"
    $summaryPath = Join-Path $runDirectory "summary.md"

    Write-Utf8NoBomFile -Path $promptPath -Text $PromptText

    $codexArgs = New-CodexExecArguments `
        -WorkspacePath $WorkspacePath `
        -LastMessagePath $lastMessagePath `
        -PromptText $PromptText `
        -Model $Model `
        -Profile $Profile `
        -ResumeThreadId $ResumeThreadId

    $startedAt = Get-Date
    $commandLine = "codex " + ($codexArgs -join " ")
    Move-WorkflowCursorBelowProgress
    Write-Host ("[{0}] running: {1}" -f $Index, $RunName)

    try {
        $invokeResult = Invoke-CodexCliExecWithTextApiFallback `
            -CliPaths $CliPaths `
            -Arguments $codexArgs `
            -PromptText $PromptText `
            -ConsoleLogPath $consoleLogPath `
            -WorkspacePath $WorkspacePath `
            -TimeoutSeconds $TimeoutSeconds
        $exitCode = [int]$invokeResult.ExitCode
    }
    finally {
        $finishedAt = Get-Date
    }

    $runResult = Get-CodexRunResult -OutputLines $invokeResult.OutputLines
    $threadId = if ([string]::IsNullOrWhiteSpace($runResult.ThreadId)) { $ResumeThreadId } else { $runResult.ThreadId }
    $lastMessageText = if (Test-Path -LiteralPath $lastMessagePath -PathType Leaf) {
        [System.IO.File]::ReadAllText($lastMessagePath, [System.Text.UTF8Encoding]::new($false)).TrimEnd()
    }
    else {
        $runResult.LastMessage
    }
    Write-Utf8NoBomFile -Path $lastMessagePath -Text $lastMessageText

    Save-PromptRunSummary `
        -SummaryPath $summaryPath `
        -PromptText $PromptText `
        -LastMessageText $lastMessageText `
        -WorkspacePath $WorkspacePath `
        -RunDirectory $runDirectory `
        -ExitCode $exitCode `
        -StartedAt $startedAt `
        -FinishedAt $finishedAt `
        -CodexCommandLine $commandLine `
        -ThreadId $threadId `
        -Usage $runResult.Usage `
        -ResumedFromThreadId $(if ($ResumeThreadId) { $ResumeThreadId } else { "" })

    Write-TerminalRunResult `
        -Index $Index `
        -Title $RunName `
        -Text $lastMessageText `
        -MessagePath $lastMessagePath `
        -ExitCode $exitCode

    Write-WorkflowRunIndex -Entry @{
        type = 'conversation-prompt'
        status = $(if ($exitCode -eq 0) { 'success' } else { 'failed' })
        exitCode = $exitCode
        timedOut = [bool]$invokeResult.TimedOut
        startedAt = $startedAt.ToString('o')
        finishedAt = $finishedAt.ToString('o')
        runDirectory = $runDirectory
        relativeRunDirectory = Get-RelativeWorkflowPath -Path $runDirectory
        model = $Model
        profile = $Profile
        name = $RunName
        threadId = $threadId
        resumedFrom = $(if ($ResumeThreadId) { $ResumeThreadId } else { '' })
    } | Out-Null

    return @{
        Index = $Index
        Name = $RunName
        DirectoryName = [System.IO.Path]::GetFileName($runDirectory)
        RunDirectory = $runDirectory
        ExitCode = $exitCode
        Status = $(if ($exitCode -eq 0) { "success" } else { "failed" })
        PromptText = $PromptText
        LastMessageText = $lastMessageText
        SummaryPath = $summaryPath
        ThreadId = $threadId
    }
}

function New-ConversationState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConversationFilePath,
        [Parameter(Mandatory = $true)]
        [string]$ConversationDirectory,
        [Parameter(Mandatory = $true)]
        [string]$ConversationHash,
        [Parameter(Mandatory = $true)]
        [object[]]$Groups,
        [Parameter(Mandatory = $true)]
        [int]$TotalOperations,
        [Parameter(Mandatory = $true)]
        [datetime]$StartedAt
    )

    $stateGroups = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Groups.Count; $i++) {
        [void]$stateGroups.Add([ordered]@{
            GroupIndex = ($i + 1)
            ThreadId = ''
            PromptRuns = @()
            SummaryRun = $null
            Completed = $false
            PromptCount = @($Groups[$i].Prompts).Count
        })
    }

    return [ordered]@{
        Version = 2
        Status = 'running'
        ConversationFile = $ConversationFilePath
        ConversationHash = $ConversationHash
        ConversationDirectory = $ConversationDirectory
        StartedAt = $StartedAt.ToString('o')
        UpdatedAt = $StartedAt.ToString('o')
        CompletedOperations = 0
        TotalOperations = $TotalOperations
        LastError = ''
        CompletedAt = ''
        Groups = @($stateGroups.ToArray())
    }
}

function Save-ConversationState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $State.UpdatedAt = (Get-Date).ToString('o')
    Write-Utf8NoBomFile -Path $Path -Text ($State | ConvertTo-Json -Depth 12)
}

function ConvertFrom-StateRun {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Run
    )

    return [pscustomobject]@{
        Index = [int]$Run.Index
        Name = [string]$Run.Name
        DirectoryName = [string]$Run.DirectoryName
        RunDirectory = [string]$Run.RunDirectory
        ExitCode = [int]$Run.ExitCode
        Status = [string]$Run.Status
        PromptText = [string]$Run.PromptText
        LastMessageText = [string]$Run.LastMessageText
        SummaryPath = [string]$Run.SummaryPath
        ThreadId = [string]$Run.ThreadId
    }
}

function ConvertTo-StateRun {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Run
    )

    return [ordered]@{
        Index = [int]$Run.Index
        Name = [string]$Run.Name
        DirectoryName = [string]$Run.DirectoryName
        RunDirectory = [string]$Run.RunDirectory
        ExitCode = [int]$Run.ExitCode
        Status = [string]$Run.Status
        PromptText = [string]$Run.PromptText
        LastMessageText = [string]$Run.LastMessageText
        SummaryPath = [string]$Run.SummaryPath
        ThreadId = [string]$Run.ThreadId
    }
}

$cliPaths = Get-CodexCliPaths
$resolvedWorkspace = Resolve-WorkflowPath -Path $Workspace -MustExist
$resolvedConversationFile = Resolve-WorkflowPath -Path $ConversationFile -MustExist
$resolvedOutputRoot = Resolve-WorkflowPath -Path $OutputRoot
[System.IO.Directory]::CreateDirectory($resolvedOutputRoot) | Out-Null

$conversationText = [System.IO.File]::ReadAllText($resolvedConversationFile)
$groups = @(Get-ConversationGroupsFromText -Text $conversationText)
if ($groups.Count -eq 0) {
    throw "Conversation file does not contain any prompts."
}

$conversationHashBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($conversationText)
$conversationHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($conversationHashBytes)).Replace('-', '').ToLowerInvariant()
$totalOperations = 0
foreach ($group in $groups) { $totalOperations += ($group.Prompts.Count + 1) }

if (-not [string]::IsNullOrWhiteSpace($SummaryPromptFile)) {
    $resolvedSummaryPromptFile = Resolve-WorkflowPath -Path $SummaryPromptFile -MustExist
    $SummaryPrompt = [System.IO.File]::ReadAllText($resolvedSummaryPromptFile, [System.Text.UTF8Encoding]::new($false))
}

if ([string]::IsNullOrWhiteSpace($SummaryPrompt)) {
    $SummaryPrompt = @"
Please summarize everything completed in this conversation segment as a Markdown document.

Requirements:
1. Use a short title.
2. Include the sections `Completed Work`, `Key Outputs or Conclusions`, and `Open Items or Next Steps`.
3. If files, commands, or concrete deliverables were produced, list them as bullets.
4. Base the summary only on this conversation segment.
5. Output Markdown only.
"@
}

$conversationStartedAt = Get-Date
$state = $null
$statePath = $null

if (-not [string]::IsNullOrWhiteSpace($ResumeStatePath)) {
    $statePath = Resolve-WorkflowPath -Path $ResumeStatePath -MustExist
    $state = [System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    foreach ($stateProperty in @('ConversationHash', 'TotalOperations', 'LastError', 'CompletedAt')) {
        if (-not $state.PSObject.Properties[$stateProperty]) {
            $state | Add-Member -NotePropertyName $stateProperty -NotePropertyValue $(if ($stateProperty -eq 'TotalOperations') { $totalOperations } else { '' })
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$state.ConversationHash) -and [string]$state.ConversationHash -ne $conversationHash) {
        throw "Conversation content does not match the saved state. Resume from the saved conversation.txt snapshot or start a new batch."
    }
    if (@($state.Groups).Count -ne $groups.Count) {
        throw "Conversation group count does not match the saved state."
    }
    for ($stateGroupIndex = 0; $stateGroupIndex -lt $groups.Count; $stateGroupIndex++) {
        $savedGroup = $state.Groups[$stateGroupIndex]
        if (-not $savedGroup.PSObject.Properties['PromptCount']) {
            $savedGroup | Add-Member -NotePropertyName PromptCount -NotePropertyValue @($groups[$stateGroupIndex].Prompts).Count
        }
        if ([int]$savedGroup.PromptCount -ne @($groups[$stateGroupIndex].Prompts).Count) {
            throw "Conversation prompt count changed in group $($stateGroupIndex + 1)."
        }
        if (@($savedGroup.PromptRuns).Count -gt [int]$savedGroup.PromptCount) {
            throw "Saved progress exceeds the prompt count in group $($stateGroupIndex + 1)."
        }
    }
    $state.ConversationHash = $conversationHash
    $state.TotalOperations = $totalOperations
    if ([int]$state.CompletedOperations -gt $totalOperations) {
        throw "Saved progress exceeds the total operation count."
    }
    $state.Status = 'running'
    $state.LastError = ''
    $conversationDirectory = [string]$state.ConversationDirectory
    if (-not (Test-Path -LiteralPath $conversationDirectory -PathType Container)) {
        throw "State conversation directory not found: $conversationDirectory"
    }
    $conversationStartedAt = [datetime]$state.StartedAt
    $savedSummaryPromptPath = Join-Path $conversationDirectory 'summary_prompt.txt'
    if (Test-Path -LiteralPath $savedSummaryPromptPath -PathType Leaf) {
        $SummaryPrompt = [System.IO.File]::ReadAllText($savedSummaryPromptPath, [System.Text.UTF8Encoding]::new($false))
    }
    Save-ConversationState -Path $statePath -State $state
    Write-Host ("resuming conversation state: {0}" -f (Get-RelativeWorkflowPath -Path $statePath))
}
else {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $baseName = if ([string]::IsNullOrWhiteSpace($RunName)) {
        New-Slug -Text ([System.IO.Path]::GetFileNameWithoutExtension($resolvedConversationFile))
    }
    else {
        New-Slug -Text $RunName
    }
    $conversationDirectory = Join-Path $resolvedOutputRoot ("{0}_{1}" -f $timestamp, $baseName)
    [System.IO.Directory]::CreateDirectory($conversationDirectory) | Out-Null

    Write-Utf8NoBomFile -Path (Join-Path $conversationDirectory "conversation.txt") -Text $conversationText
    Write-Utf8NoBomFile -Path (Join-Path $conversationDirectory "summary_prompt.txt") -Text $SummaryPrompt

    $statePath = Join-Path $conversationDirectory "conversation_state.json"
    $state = New-ConversationState `
        -ConversationFilePath $resolvedConversationFile `
        -ConversationDirectory $conversationDirectory `
        -ConversationHash $conversationHash `
        -Groups $groups `
        -TotalOperations $totalOperations `
        -StartedAt $conversationStartedAt
    Save-ConversationState -Path $statePath -State $state
}

$groupResults = New-Object System.Collections.Generic.List[object]
$exitCode = 0
try {
    $completedOperations = [int]$state.CompletedOperations

    for ($groupIndex = 0; $groupIndex -lt $groups.Count; $groupIndex++) {
        $group = $groups[$groupIndex]
        $groupNumber = $groupIndex + 1
        $stateGroup = $state.Groups[$groupIndex]
        $groupDirectory = Join-Path $conversationDirectory ("group-{0:D3}" -f $groupNumber)
        [System.IO.Directory]::CreateDirectory($groupDirectory) | Out-Null

        $groupStartedAt = Get-Date
        $threadId = if ([string]::IsNullOrWhiteSpace([string]$stateGroup.ThreadId)) { $null } else { [string]$stateGroup.ThreadId }
        $promptRuns = New-Object System.Collections.Generic.List[object]
        foreach ($stateRun in @($stateGroup.PromptRuns)) {
            [void]$promptRuns.Add((ConvertFrom-StateRun -Run $stateRun))
        }
        $groupOperationCount = $group.Prompts.Count + 1
        $completedInGroup = $promptRuns.Count

        if ($stateGroup.Completed) {
            if ($null -ne $stateGroup.SummaryRun) {
                $summaryRun = ConvertFrom-StateRun -Run $stateGroup.SummaryRun
                [void]$groupResults.Add([pscustomobject]@{
                    GroupIndex = $groupNumber
                    DirectoryName = [System.IO.Path]::GetFileName($groupDirectory)
                    GroupDirectory = $groupDirectory
                    PromptRuns = @($promptRuns.ToArray())
                    SummaryPath = (Join-Path $groupDirectory "group_summary.md")
                    ThreadId = $threadId
                })
            }
            continue
        }

        Move-WorkflowCursorBelowProgress
        Write-Host ("group: {0}/{1}" -f $groupNumber, $groups.Count)
        Update-ConversationProgress `
            -GroupNumber $groupNumber `
            -GroupCount $groups.Count `
            -CompletedOperations $completedOperations `
            -TotalOperations $totalOperations `
            -CompletedInGroup $completedInGroup `
            -GroupOperationCount $groupOperationCount `
            -Phase "Preparing group" `
            -RunName ("group-{0:D3}" -f $groupNumber)

        for ($promptIndex = $promptRuns.Count; $promptIndex -lt $group.Prompts.Count; $promptIndex++) {
            $promptText = [string]$group.Prompts[$promptIndex]
            $runName = "prompt-{0:D3}-{1}" -f ($promptIndex + 1), (New-Slug -Text $promptText)

            Update-ConversationProgress `
                -GroupNumber $groupNumber `
                -GroupCount $groups.Count `
                -CompletedOperations $completedOperations `
                -TotalOperations $totalOperations `
                -CompletedInGroup $completedInGroup `
                -GroupOperationCount $groupOperationCount `
                -Phase ("Running prompt {0}/{1}" -f ($promptIndex + 1), $group.Prompts.Count) `
                -RunName $runName

            $run = Invoke-CodexPromptRun `
                -CliPaths $cliPaths `
                -WorkspacePath $resolvedWorkspace `
                -ParentDirectory $groupDirectory `
                -PromptText $promptText `
                -RunName $runName `
                -Index ($promptIndex + 1) `
                -Model $Model `
                -Profile $Profile `
                -ResumeThreadId $threadId `
                -TimeoutSeconds $TimeoutSeconds

            [void]$promptRuns.Add($run)

            if ($run.ExitCode -ne 0) {
                $exitCode = $run.ExitCode
                throw "Prompt run failed in group $groupNumber prompt $($promptIndex + 1). See $($run.RunDirectory)"
            }

            $threadId = $run.ThreadId
            $stateGroup.ThreadId = $threadId
            $stateGroup.PromptRuns = @($promptRuns.ToArray() | ForEach-Object { ConvertTo-StateRun -Run $_ })
            $completedInGroup += 1
            $completedOperations += 1
            $state.CompletedOperations = $completedOperations
            Save-ConversationState -Path $statePath -State $state

            Update-ConversationProgress `
                -GroupNumber $groupNumber `
                -GroupCount $groups.Count `
                -CompletedOperations $completedOperations `
                -TotalOperations $totalOperations `
                -CompletedInGroup $completedInGroup `
                -GroupOperationCount $groupOperationCount `
                -Phase ("Completed prompt {0}/{1}" -f ($promptIndex + 1), $group.Prompts.Count) `
                -RunName $runName
        }

        Update-ConversationProgress `
            -GroupNumber $groupNumber `
            -GroupCount $groups.Count `
            -CompletedOperations $completedOperations `
            -TotalOperations $totalOperations `
            -CompletedInGroup $completedInGroup `
            -GroupOperationCount $groupOperationCount `
            -Phase "Running group summary" `
            -RunName "group-summary"

        $summaryRun = Invoke-CodexPromptRun `
            -CliPaths $cliPaths `
            -WorkspacePath $resolvedWorkspace `
            -ParentDirectory $groupDirectory `
            -PromptText $SummaryPrompt `
            -RunName "group-summary" `
            -Index ($group.Prompts.Count + 1) `
            -Model $Model `
            -Profile $Profile `
            -ResumeThreadId $threadId `
            -TimeoutSeconds $TimeoutSeconds

        if ($summaryRun.ExitCode -ne 0) {
            $exitCode = $summaryRun.ExitCode
            throw "Summary run failed in group $groupNumber. See $($summaryRun.RunDirectory)"
        }

        $completedInGroup += 1
        $completedOperations += 1
        $state.CompletedOperations = $completedOperations

        $groupSummaryPath = Join-Path $groupDirectory "group_summary.md"
        Write-Utf8NoBomFile -Path $groupSummaryPath -Text $summaryRun.LastMessageText
        $stateGroup.SummaryRun = ConvertTo-StateRun -Run $summaryRun
        $stateGroup.Completed = $true
        $stateGroup.ThreadId = $threadId
        Save-ConversationState -Path $statePath -State $state

        $groupFinishedAt = Get-Date
        $groupIndexPath = Join-Path $groupDirectory "group_index.md"
        Save-GroupIndex `
            -Path $groupIndexPath `
            -GroupIndex $groupNumber `
            -PromptRuns $promptRuns.ToArray() `
            -SummaryPromptText $SummaryPrompt `
            -SummaryText $summaryRun.LastMessageText `
            -ThreadId $threadId `
            -StartedAt $groupStartedAt `
            -FinishedAt $groupFinishedAt

        [void]$groupResults.Add([pscustomobject]@{
            GroupIndex = $groupNumber
            DirectoryName = [System.IO.Path]::GetFileName($groupDirectory)
            GroupDirectory = $groupDirectory
            PromptRuns = @($promptRuns.ToArray())
            SummaryPath = $groupSummaryPath
            ThreadId = $threadId
        })

        Update-ConversationProgress `
            -GroupNumber $groupNumber `
            -GroupCount $groups.Count `
            -CompletedOperations $completedOperations `
            -TotalOperations $totalOperations `
            -CompletedInGroup $completedInGroup `
            -GroupOperationCount $groupOperationCount `
            -Phase "Group completed" `
            -RunName ("group-{0:D3}" -f $groupNumber)

        Move-WorkflowCursorBelowProgress
        Write-Host ("group done: {0}/{1}" -f $groupNumber, $groups.Count)
    }
}
catch {
    $state.Status = 'failed'
    $state.LastError = $_.Exception.Message
    Save-ConversationState -Path $statePath -State $state
    throw
}
finally {
    # The custom fixed progress remains visible after the last update.
}

$conversationFinishedAt = Get-Date
$state.Status = if ($exitCode -eq 0) { 'completed' } else { 'failed' }
$state.CompletedAt = $conversationFinishedAt.ToString('o')
Save-ConversationState -Path $statePath -State $state
$conversationIndexPath = Join-Path $conversationDirectory "conversation_index.md"
Save-ConversationIndex `
    -Path $conversationIndexPath `
    -WorkspacePath $resolvedWorkspace `
    -ConversationDirectory $conversationDirectory `
    -GroupResults $groupResults.ToArray() `
    -StartedAt $conversationStartedAt `
    -FinishedAt $conversationFinishedAt

Move-WorkflowCursorBelowProgress
Write-Host ("conversation done | output: {0}" -f (Get-RelativeWorkflowPath -Path $conversationDirectory))
Write-Host ("index: {0}" -f (Get-RelativeWorkflowPath -Path $conversationIndexPath))

exit $exitCode
