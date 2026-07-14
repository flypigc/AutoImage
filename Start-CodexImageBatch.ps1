param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,

    [string]$CodexScript = '.\Invoke-CodexCliAsk.ps1',

    [string]$OutputRoot = '.\runs\images',

    [string]$Model,
    [string]$ImageApiKey,
    [string]$ImageBaseUrl,
    [string]$ImageApiProfilesJson,
    [string]$ImageAspectRatio,
    [string]$ImageSize,
    [string]$ImageQuality,
    [string]$ImageOutputFormat,
    [string]$ImageOutputCompression,
    [string]$ImageModeration,
    [string]$ImageReferencePathsJson,

    [ValidateRange(1, 20)]
    [int]$MaxConcurrency = 2,

    [ValidateRange(1, 20)]
    [int]$ImageMaxAttempts = 6,

    [ValidateRange(1, 300)]
    [int]$ImageRetryBaseDelaySeconds = 2,

    [ValidateRange(1, 600)]
    [int]$ImageRetryMaxDelaySeconds = 20,
    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 600,

    [ValidateRange(1, 86400)]
    [int]$ImageRequestTimeoutSeconds = 600,

    [ValidateRange(1, 86400)]
    [int]$ImageTotalTimeoutSeconds = 1800,

    [string]$ResumeStatePath,
    [switch]$RetryFailed,

    [switch]$Wait
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $PSScriptRoot
}

. (Join-Path $ScriptRoot 'WorkflowProgressUi.ps1')
Import-Module (Join-Path $ScriptRoot 'WorkflowCommon.psm1') -Force
Initialize-WorkflowCommon -Root $ScriptRoot

function Get-IndexedImageName {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Index,
        [Parameter(Mandatory = $true)]
        [int]$PadWidth,
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $safeName = New-Slug -Text $Text
    return ("{0}-{1}" -f $Index.ToString(("D{0}" -f $PadWidth)), $safeName)
}

function Write-PrefixedLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prefix,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    foreach ($line in $Lines) {
        if ($null -eq $line) {
            continue
        }

        Write-Host ("[{0}] {1}" -f $Prefix, $line)
    }
}

function Update-ImageBatchProgress {
    param(
        [Parameter(Mandatory = $true)]
        [int]$TotalCount,
        [Parameter(Mandatory = $true)]
        [int]$QueuedCount,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Jobs,
        [Parameter(Mandatory = $true)]
        [int]$CompletedCount,
        [Parameter(Mandatory = $true)]
        [int]$SuccessCount,
        [Parameter(Mandatory = $true)]
        [int]$FailedCount,
        [AllowEmptyString()]
        [string]$CurrentStatus,
        [switch]$Force
    )

    if ($TotalCount -le 0) {
        return
    }

    Write-WorkflowConcurrentTaskTable `
        -Key "image-batch" `
        -TotalCount $TotalCount `
        -CompletedCount $CompletedCount `
        -SuccessCount $SuccessCount `
        -FailedCount $FailedCount `
        -QueuedCount $QueuedCount `
        -Jobs $Jobs `
        -CurrentStatus $CurrentStatus `
        -Force:$Force
}

function Get-ImageJobStatus {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Job
    )

    if ((Test-Path -LiteralPath $Job.OutputPath) -and ((Get-Item -LiteralPath $Job.OutputPath).Length -gt 0)) {
        return 'success'
    }

    return 'failed'
}

function Start-ImageJob {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Job
    )

    if (Test-Path -LiteralPath $Job.OutputPath) {
        Remove-Item -LiteralPath $Job.OutputPath -Force -ErrorAction SilentlyContinue
    }

    foreach ($logPath in @($Job.StdoutPath, $Job.StderrPath, $Job.ConsolePath)) {
        if (Test-Path -LiteralPath $logPath) {
            Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        }
    }

    $args = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $Job.ScriptPath,
        '-PromptFile', $Job.PromptCopy,
        '-GenerateImage',
        '-ImageOutputPath', $Job.OutputPath,
        '-ImageArtifactsRoot', $Job.OutputDirectory,
        '-RunName', $Job.JobName,
        '-OutputRoot', $Job.OutputRoot,
        '-ImageMaxAttempts', $Job.ImageMaxAttempts,
        '-ImageRetryBaseDelaySeconds', $Job.ImageRetryBaseDelaySeconds,
        '-ImageRetryMaxDelaySeconds', $Job.ImageRetryMaxDelaySeconds,
        '-TimeoutSeconds', $Job.TimeoutSeconds,
        '-ImageRequestTimeoutSeconds', $Job.ImageRequestTimeoutSeconds,
        '-ImageTotalTimeoutSeconds', $Job.ImageTotalTimeoutSeconds,
        '-NoReopenWindow'
    )

    if (-not [string]::IsNullOrWhiteSpace($Job.Model)) {
        $args += @('-Model', $Job.Model)
    }
    if (-not [string]::IsNullOrWhiteSpace($Job.ImageAspectRatio)) {
        $args += @('-ImageAspectRatio', $Job.ImageAspectRatio)
    }
    if (-not [string]::IsNullOrWhiteSpace($Job.ImageSize)) {
        $args += @('-ImageSize', $Job.ImageSize)
    }
    if (-not [string]::IsNullOrWhiteSpace($Job.ImageQuality)) {
        $args += @('-ImageQuality', $Job.ImageQuality)
    }
    if (-not [string]::IsNullOrWhiteSpace($Job.ImageOutputFormat)) {
        $args += @('-ImageOutputFormat', $Job.ImageOutputFormat)
    }
    if (-not [string]::IsNullOrWhiteSpace($Job.ImageOutputCompression)) {
        $args += @('-ImageOutputCompression', $Job.ImageOutputCompression)
    }
    if (-not [string]::IsNullOrWhiteSpace($Job.ImageModeration)) {
        $args += @('-ImageModeration', $Job.ImageModeration)
    }
    if (-not [string]::IsNullOrWhiteSpace($Job.ImageReferencePathsJson)) {
        $args += @('-ImageReferencePathsJson', $Job.ImageReferencePathsJson)
    }

    $hadImageApiKey = Test-Path Env:\OPENAI_IMAGE_API_KEY
    $previousImageApiKey = $env:OPENAI_IMAGE_API_KEY
    $hadImageBaseUrl = Test-Path Env:\OPENAI_IMAGE_BASE_URL
    $previousImageBaseUrl = $env:OPENAI_IMAGE_BASE_URL
    $hadImageProfilesJson = Test-Path Env:\CODEX_WORKFLOW_IMAGE_API_PROFILES_JSON
    $previousImageProfilesJson = $env:CODEX_WORKFLOW_IMAGE_API_PROFILES_JSON

    try {
        if (-not [string]::IsNullOrWhiteSpace($Job.ImageApiKey)) {
            $env:OPENAI_IMAGE_API_KEY = $Job.ImageApiKey
        }

        if (-not [string]::IsNullOrWhiteSpace($Job.ImageBaseUrl)) {
            $env:OPENAI_IMAGE_BASE_URL = $Job.ImageBaseUrl
        }

        if (-not [string]::IsNullOrWhiteSpace($Job.ImageApiProfilesJson)) {
            $env:CODEX_WORKFLOW_IMAGE_API_PROFILES_JSON = $Job.ImageApiProfilesJson
        }

        $process = Start-Process `
            -FilePath 'powershell.exe' `
            -ArgumentList $args `
            -WindowStyle Hidden `
            -RedirectStandardOutput $Job.StdoutPath `
            -RedirectStandardError $Job.StderrPath `
            -PassThru
    }
    finally {
        if ($hadImageApiKey) {
            $env:OPENAI_IMAGE_API_KEY = $previousImageApiKey
        }
        else {
            Remove-Item Env:\OPENAI_IMAGE_API_KEY -ErrorAction SilentlyContinue
        }

        if ($hadImageBaseUrl) {
            $env:OPENAI_IMAGE_BASE_URL = $previousImageBaseUrl
        }
        else {
            Remove-Item Env:\OPENAI_IMAGE_BASE_URL -ErrorAction SilentlyContinue
        }

        if ($hadImageProfilesJson) {
            $env:CODEX_WORKFLOW_IMAGE_API_PROFILES_JSON = $previousImageProfilesJson
        }
        else {
            Remove-Item Env:\CODEX_WORKFLOW_IMAGE_API_PROFILES_JSON -ErrorAction SilentlyContinue
        }
    }

    $Job.Process = $process
    $Job.StartedAt = Get-Date
    $Job.FinishedAt = $null
    $Job.Status = 'running'
    return $Job
}

function Complete-ImageJob {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Job,
        [Parameter(Mandatory = $true)]
        [int]$TotalCount,
        [switch]$Quiet
    )

    if (-not $Quiet) { Move-WorkflowCursorBelowProgress }

    $stderrLines = if (Test-Path -LiteralPath $Job.StderrPath) {
        @(Get-Content -LiteralPath $Job.StderrPath)
    }
    else {
        @()
    }

    $consoleLines = @()
    if (Test-Path -LiteralPath $Job.ConsolePath) {
        $consoleLines = @(Get-Content -LiteralPath $Job.ConsolePath)
    }

    $status = Get-ImageJobStatus -Job $Job
    $Job.Status = $status
    $Job.FinishedAt = Get-Date
    if ($status -eq 'success' -and -not $Quiet) {
        Write-Host ("[{0}/{1}] saved: {2}" -f $Job.Index, $TotalCount, (Get-RelativeWorkflowPath -Path $Job.OutputPath))
    }
    elseif (-not $Quiet) {
        Write-Host ("[{0}/{1}] failed: {2}" -f $Job.Index, $TotalCount, $Job.JobName) -ForegroundColor Yellow
        $errorLines = @($stderrLines + $consoleLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8)
        if ($errorLines.Count -gt 0) {
            Write-PrefixedLines -Prefix $Job.JobName -Lines $errorLines
        }
    }
    return $status
}

function Resolve-MarkdownImageReferencePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reference,
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    $target = $Reference.Trim()
    if ([string]::IsNullOrWhiteSpace($target)) {
        return $null
    }

    if ($target.StartsWith('<') -and $target.EndsWith('>')) {
        $target = $target.Substring(1, $target.Length - 2).Trim()
    }

    if ($target -match '^(?i:https?|data):') {
        throw "Remote or data URI reference images are not supported in image batches yet: $target"
    }

    $target = [System.Uri]::UnescapeDataString($target)
    $candidate = if ([System.IO.Path]::IsPathRooted($target)) {
        $target
    }
    else {
        Join-Path $BaseDirectory $target
    }

    $resolved = Resolve-Path -LiteralPath $candidate -ErrorAction Stop
    $extension = [System.IO.Path]::GetExtension($resolved.Path).ToLowerInvariant()
    if ($extension -notin @('.png', '.jpg', '.jpeg', '.webp')) {
        throw "Unsupported reference image format: $($resolved.Path). Use PNG, JPEG, or WebP."
    }

    return [System.IO.Path]::GetFullPath($resolved.Path)
}

function Get-MarkdownImageReferencePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Markdown,
        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    $references = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($match in [regex]::Matches($Markdown, '!\[[^\]]*\]\((?<body>[^)]*)\)')) {
        $body = $match.Groups['body'].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($body)) {
            continue
        }

        $target = $body
        if ($target.StartsWith('<')) {
            $end = $target.IndexOf('>')
            if ($end -ge 0) {
                $target = $target.Substring(0, $end + 1)
            }
        }
        elseif ($target -match '^(?<path>\S+)\s+["''].*["'']\s*$') {
            $target = $Matches['path']
        }

        $resolved = Resolve-MarkdownImageReferencePath -Reference $target -BaseDirectory $BaseDirectory
        if ($resolved -and $seen.Add($resolved)) {
            [void]$references.Add($resolved)
        }
    }

    foreach ($match in [regex]::Matches($Markdown, '<img\b[^>]*\bsrc\s*=\s*(["''])(?<target>.*?)\1', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $resolved = Resolve-MarkdownImageReferencePath -Reference $match.Groups['target'].Value -BaseDirectory $BaseDirectory
        if ($resolved -and $seen.Add($resolved)) {
            [void]$references.Add($resolved)
        }
    }

    if ($references.Count -gt 16) {
        throw "A single image prompt segment can include at most 16 reference images."
    }

    return @($references.ToArray())
}

function ConvertFrom-BatchApiProfilesJson {
    param(
        [AllowEmptyString()]
        [string]$Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return @()
    }

    try {
        $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
        return @($parsed | Where-Object { $null -ne $_ })
    }
    catch {
        throw "Invalid image API profiles JSON: $($_.Exception.Message)"
    }
}

function Get-BatchApiProfileName {
    param(
        [AllowNull()]
        [object]$Profile,
        [int]$Index
    )

    if ($null -ne $Profile -and $Profile.PSObject.Properties["Name"] -and -not [string]::IsNullOrWhiteSpace([string]$Profile.Name)) {
        return [string]$Profile.Name
    }

    return ("image API #{0}" -f ($Index + 1))
}

function Get-RotatedImageApiProfilesJson {
    param(
        [AllowEmptyCollection()]
        [object[]]$Profiles,
        [int]$Offset
    )

    $profileCount = @($Profiles).Count
    if ($profileCount -eq 0) {
        return ""
    }

    if ($profileCount -eq 1) {
        return ($Profiles | ConvertTo-Json -Depth 6 -Compress)
    }

    $rotated = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $profileCount; $i++) {
        [void]$rotated.Add($Profiles[($Offset + $i) % $profileCount])
    }

    return ($rotated.ToArray() | ConvertTo-Json -Depth 6 -Compress)
}

function Save-ImageBatchState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object[]]$Jobs,
        [AllowEmptyString()][string]$Status = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Status)) { $State.Status = $Status }
    $State.UpdatedAt = (Get-Date).ToString('o')
    $State.Jobs = @($Jobs | ForEach-Object {
        [pscustomobject]@{
            Index = [int]$_.Index
            JobName = [string]$_.JobName
            Status = [string]$_.Status
            PromptCopy = [string]$_.PromptCopy
            OutputPath = [string]$_.OutputPath
            OutputDirectory = [string]$_.OutputDirectory
            StdoutPath = [string]$_.StdoutPath
            StderrPath = [string]$_.StderrPath
            ConsolePath = [string]$_.ConsolePath
            ApiProfileName = [string]$_.ImageApiProfileName
            ReferenceImageCount = @($_.ReferencePaths).Count
            StartedAt = $(if ($_.StartedAt) { ([datetime]$_.StartedAt).ToString('o') } else { '' })
            FinishedAt = $(if ($_.FinishedAt) { ([datetime]$_.FinishedAt).ToString('o') } else { '' })
        }
    })
    $State.SuccessCount = @($Jobs | Where-Object Status -eq 'success').Count
    $State.FailedCount = @($Jobs | Where-Object Status -eq 'failed').Count
    $State.PendingCount = @($Jobs | Where-Object { $_.Status -in @('queued', 'running') }).Count

    $temporaryPath = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temporaryPath, ($State | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Test-ImageBatchCancelRequested {
    param([Parameter(Mandatory = $true)][string]$StatePath)

    if (Test-Path -LiteralPath ($StatePath + '.cancel') -PathType Leaf) { return $true }
    try {
        $current = [System.IO.File]::ReadAllText($StatePath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        return [string]$current.Status -eq 'cancel_requested'
    }
    catch {
        return $false
    }
}

$promptPath = Resolve-WorkflowPath -Path $PromptFile -MustExist
$scriptPath = Resolve-WorkflowPath -Path $CodexScript -MustExist
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$promptText = [System.IO.File]::ReadAllText($promptPath, $utf8NoBom)
$segments = Get-PromptSegments -Text $promptText
$promptDirectory = Split-Path -Parent $promptPath
$imageApiProfiles = @(ConvertFrom-BatchApiProfilesJson -Json $ImageApiProfilesJson)

if ($segments.Count -eq 0) {
    throw "No prompt segments found in $PromptFile"
}

$resolvedOutputRoot = Resolve-WorkflowPath -Path $OutputRoot
$null = New-Item -ItemType Directory -Path $resolvedOutputRoot -Force

$sourceHash = (Get-FileHash -LiteralPath $promptPath -Algorithm SHA256).Hash.ToLowerInvariant()
$savedJobsByIndex = @{}
$isResume = -not [string]::IsNullOrWhiteSpace($ResumeStatePath)
if ($isResume) {
    $statePath = Resolve-WorkflowPath -Path $ResumeStatePath -MustExist
    $batchState = [System.IO.File]::ReadAllText($statePath, $utf8NoBom) | ConvertFrom-Json -ErrorAction Stop
    if ([string]$batchState.SourceHash -ne $sourceHash) { throw 'Image prompt file changed since the batch state was created.' }
    if ([int]$batchState.JobCount -ne $segments.Count) { throw 'Image prompt count does not match the saved batch state.' }
    $batchDirectory = [string]$batchState.BatchDirectory
    if (-not (Test-Path -LiteralPath $batchDirectory -PathType Container)) { throw "Image batch directory not found: $batchDirectory" }
    foreach ($savedJob in @($batchState.Jobs)) { $savedJobsByIndex[[int]$savedJob.Index] = $savedJob }
}
else {
    $batchTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $batchDirectory = Join-Path $resolvedOutputRoot $batchTimestamp
    $statePath = Join-Path $batchDirectory 'batch_state.json'
}
$cancelSignalPath = $statePath + '.cancel'
if (Test-Path -LiteralPath $cancelSignalPath -PathType Leaf) { Remove-Item -LiteralPath $cancelSignalPath -Force }
$metaRoot = Join-Path $batchDirectory '_meta'
$null = New-Item -ItemType Directory -Path $batchDirectory -Force
$null = New-Item -ItemType Directory -Path $metaRoot -Force

$allJobs = New-Object System.Collections.Generic.List[object]
$pendingJobs = New-Object System.Collections.Generic.List[object]
$padWidth = [Math]::Max(3, ([string]$segments.Count).Length)
$index = 1
foreach ($segment in $segments) {
    $referencePaths = @(Get-MarkdownImageReferencePaths -Markdown $segment -BaseDirectory $promptDirectory)
    if (-not [string]::IsNullOrWhiteSpace($ImageReferencePathsJson)) {
        $configuredReferences = @($ImageReferencePathsJson | ConvertFrom-Json)
        foreach ($reference in $configuredReferences) {
            $resolvedReference = Resolve-MarkdownImageReferencePath -Reference ([string]$reference) -BaseDirectory $promptDirectory
            if ($resolvedReference -and $referencePaths -notcontains $resolvedReference) {
                $referencePaths += $resolvedReference
            }
        }
    }
    if ($referencePaths.Count -gt 16) {
        throw "A single image prompt segment can include at most 16 reference images."
    }

    $profileOffset = if ($imageApiProfiles.Count -gt 0) { ($index - 1) % $imageApiProfiles.Count } else { 0 }
    $jobImageApiProfilesJson = if ($imageApiProfiles.Count -gt 0) {
        Get-RotatedImageApiProfilesJson -Profiles $imageApiProfiles -Offset $profileOffset
    }
    else {
        $ImageApiProfilesJson
    }
    $jobImageApiProfileName = if ($imageApiProfiles.Count -gt 0) {
        Get-BatchApiProfileName -Profile $imageApiProfiles[$profileOffset] -Index $profileOffset
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ImageApiKey) -or -not [string]::IsNullOrWhiteSpace($ImageBaseUrl)) {
        "image primary"
    }
    else {
        "Codex default"
    }

    $segmentName = Get-IndexedImageName -Index $index -PadWidth $padWidth -Text $segment
    $jobName = "codex-img-$segmentName"
    $imageOutDir = Join-Path $metaRoot $segmentName
    $null = New-Item -ItemType Directory -Path $imageOutDir -Force
    $imageFormat = if ([string]::IsNullOrWhiteSpace($ImageOutputFormat)) { "png" } else { $ImageOutputFormat.ToLowerInvariant() }
    $imageExtension = switch ($imageFormat) {
        "jpeg" { ".jpg" }
        "webp" { ".webp" }
        default { ".png" }
    }
    $imageOut = Join-Path $batchDirectory ($segmentName + $imageExtension)
    $promptCopy = Join-Path $imageOutDir 'prompt.txt'
    [System.IO.File]::WriteAllText($promptCopy, $segment, [System.Text.UTF8Encoding]::new($false))
    $referencePathsJson = if ($referencePaths.Count -gt 0) { $referencePaths | ConvertTo-Json -Compress } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($referencePathsJson)) {
        [System.IO.File]::WriteAllText((Join-Path $imageOutDir 'reference_images.json'), $referencePathsJson, [System.Text.UTF8Encoding]::new($false))
    }
    [System.IO.File]::WriteAllText((Join-Path $imageOutDir 'api_profile.txt'), $jobImageApiProfileName, [System.Text.UTF8Encoding]::new($false))
    $stdoutPath = Join-Path $imageOutDir 'launcher.stdout.log'
    $stderrPath = Join-Path $imageOutDir 'launcher.stderr.log'
    $consolePath = Join-Path $imageOutDir 'console.log'

    $savedStatus = if ($savedJobsByIndex.ContainsKey($index)) { [string]$savedJobsByIndex[$index].Status } else { 'queued' }
    $shouldRun = if (-not $isResume) { $true } elseif ($RetryFailed) { $savedStatus -eq 'failed' } else { $savedStatus -ne 'success' }
    $job = [pscustomobject]@{
        Index = $index
        JobName = $jobName
        Process = $null
        StartedAt = $null
        FinishedAt = $null
        Status = $(if ($shouldRun) { 'queued' } else { $savedStatus })
        ScriptPath = $scriptPath
        PromptCopy = $promptCopy
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
        ConsolePath = $consolePath
        OutputPath = $imageOut
        OutputDirectory = $imageOutDir
        OutputRoot = $resolvedOutputRoot
        Model = $Model
        ImageApiKey = $ImageApiKey
        ImageBaseUrl = $ImageBaseUrl
        ImageApiProfilesJson = $jobImageApiProfilesJson
        ImageApiProfileName = $jobImageApiProfileName
        ImageAspectRatio = $ImageAspectRatio
        ImageSize = $ImageSize
        ImageQuality = $ImageQuality
        ImageOutputFormat = $ImageOutputFormat
        ImageOutputCompression = $ImageOutputCompression
        ImageModeration = $ImageModeration
        ImageReferencePathsJson = $referencePathsJson
        ReferencePaths = @($referencePaths)
        ImageMaxAttempts = $ImageMaxAttempts
        ImageRetryBaseDelaySeconds = $ImageRetryBaseDelaySeconds
        ImageRetryMaxDelaySeconds = $ImageRetryMaxDelaySeconds
        TimeoutSeconds = $TimeoutSeconds
        ImageRequestTimeoutSeconds = $ImageRequestTimeoutSeconds
        ImageTotalTimeoutSeconds = $ImageTotalTimeoutSeconds
    }
    [void]$allJobs.Add($job)
    if ($shouldRun) { [void]$pendingJobs.Add($job) }
    $index++
}

if ($isResume) {
    foreach ($property in @('CompletedAt', 'LastError', 'SuccessCount', 'FailedCount', 'PendingCount')) {
        if (-not $batchState.PSObject.Properties[$property]) { $batchState | Add-Member -NotePropertyName $property -NotePropertyValue '' }
    }
    $batchState.Status = 'running'
    $batchState.SchedulerProcessId = $PID
    $batchState.MaxConcurrency = $MaxConcurrency
    $batchState.LastError = ''
}
else {
    $now = Get-Date
    $batchState = [pscustomobject]@{
        Version = 1
        Status = 'running'
        SourcePath = $promptPath
        SourceHash = $sourceHash
        JobCount = $segments.Count
        BatchDirectory = $batchDirectory
        StatePath = $statePath
        SchedulerProcessId = $PID
        MaxConcurrency = $MaxConcurrency
        StartedAt = $now.ToString('o')
        UpdatedAt = $now.ToString('o')
        CompletedAt = ''
        LastError = ''
        SuccessCount = 0
        FailedCount = 0
        PendingCount = $pendingJobs.Count
        Jobs = @()
    }
}
Save-ImageBatchState -Path $statePath -State $batchState -Jobs @($allJobs.ToArray()) -Status 'running'

if ($Wait) {
    Write-Host ("batch: {0} jobs | output: {1}" -f $pendingJobs.Count, (Get-RelativeWorkflowPath -Path $batchDirectory))
    if ($imageApiProfiles.Count -gt 1) {
        Write-Host ("api profiles: {0} | strategy: round-robin first profile, fallback on failure" -f $imageApiProfiles.Count)
    }
    Write-Host ("concurrency: {0}" -f $MaxConcurrency)
}

$runningJobs = New-Object System.Collections.Generic.List[object]
$queueIndex = 0
$completedCount = @($allJobs | Where-Object { $_.Status -in @('success', 'failed') }).Count
$successCount = @($allJobs | Where-Object Status -eq 'success').Count
$failedCount = @($allJobs | Where-Object Status -eq 'failed').Count
$schedulerExitCode = 0
$canceled = $false

if ($Wait) {
    Update-ImageBatchProgress `
        -TotalCount $segments.Count `
        -QueuedCount ($pendingJobs.Count - $queueIndex) `
        -Jobs @($pendingJobs.ToArray()) `
        -CompletedCount $completedCount `
        -SuccessCount $successCount `
        -FailedCount $failedCount `
        -CurrentStatus "Preparing image jobs"

}

try {
    while ($queueIndex -lt $pendingJobs.Count -or $runningJobs.Count -gt 0) {
        if (Test-ImageBatchCancelRequested -StatePath $statePath) {
            $canceled = $true
            throw [System.OperationCanceledException]::new('Image batch cancellation requested.')
        }

        while ($runningJobs.Count -lt $MaxConcurrency -and $queueIndex -lt $pendingJobs.Count) {
            $job = Start-ImageJob -Job $pendingJobs[$queueIndex]
            [void]$runningJobs.Add($job)
            $queueIndex++
            Save-ImageBatchState -Path $statePath -State $batchState -Jobs @($allJobs.ToArray())

            if ($Wait) {
                Update-ImageBatchProgress `
                    -TotalCount $segments.Count `
                    -QueuedCount ($pendingJobs.Count - $queueIndex) `
                    -Jobs @($pendingJobs.ToArray()) `
                    -CompletedCount $completedCount `
                    -SuccessCount $successCount `
                    -FailedCount $failedCount `
                    -CurrentStatus ("Started {0}" -f $job.JobName)
            }
        }

        $completedThisPass = @($runningJobs | Where-Object { $_.Process.HasExited })
        if ($completedThisPass.Count -eq 0) {
            if ($Wait) {
                Update-ImageBatchProgress `
                    -TotalCount $segments.Count `
                    -QueuedCount ($pendingJobs.Count - $queueIndex) `
                    -Jobs @($pendingJobs.ToArray()) `
                    -CompletedCount $completedCount `
                    -SuccessCount $successCount `
                    -FailedCount $failedCount `
                    -CurrentStatus "Waiting for running image jobs"
            }
            Start-Sleep -Milliseconds 500
            continue
        }

        foreach ($completedJob in $completedThisPass) {
            $jobStatus = Complete-ImageJob -Job $completedJob -TotalCount $segments.Count -Quiet:(-not $Wait)
            $completedCount += 1
            if ($jobStatus -eq 'success') { $successCount += 1 } else { $failedCount += 1 }

            [void]$runningJobs.Remove($completedJob)
            try { $completedJob.Process.Dispose() } catch {}
            Save-ImageBatchState -Path $statePath -State $batchState -Jobs @($allJobs.ToArray())

            if ($Wait) {
                Update-ImageBatchProgress `
                    -TotalCount $segments.Count `
                    -QueuedCount ($pendingJobs.Count - $queueIndex) `
                    -Jobs @($pendingJobs.ToArray()) `
                    -CompletedCount $completedCount `
                    -SuccessCount $successCount `
                    -FailedCount $failedCount `
                    -CurrentStatus ("Completed {0} -> {1}" -f $completedJob.JobName, $jobStatus)
            }
        }
    }
}
catch [System.OperationCanceledException] {
    $schedulerExitCode = 130
    foreach ($runningJob in @($runningJobs.ToArray())) {
        if ($runningJob.Process -and -not $runningJob.Process.HasExited) {
            try { & taskkill.exe /PID $runningJob.Process.Id /T /F | Out-Null } catch {}
        }
        $runningJob.Status = 'canceled'
        $runningJob.FinishedAt = Get-Date
    }
    for ($remainingIndex = $queueIndex; $remainingIndex -lt $pendingJobs.Count; $remainingIndex++) {
        $pendingJobs[$remainingIndex].Status = 'canceled'
        $pendingJobs[$remainingIndex].FinishedAt = Get-Date
    }
    $batchState.LastError = $_.Exception.Message
}
catch {
    $schedulerExitCode = 1
    $batchState.LastError = $_.Exception.Message
    foreach ($runningJob in @($runningJobs.ToArray())) {
        if ($runningJob.Process -and -not $runningJob.Process.HasExited) {
            try { & taskkill.exe /PID $runningJob.Process.Id /T /F | Out-Null } catch {}
        }
        $runningJob.Status = 'failed'
        $runningJob.FinishedAt = Get-Date
    }
}
finally {
    $failedCount = @($allJobs | Where-Object Status -eq 'failed').Count
    $successCount = @($allJobs | Where-Object Status -eq 'success').Count
    if ($canceled) {
        $finalStatus = 'canceled'
    }
    elseif ($schedulerExitCode -ne 0 -or $failedCount -gt 0) {
        $finalStatus = 'failed'
        if ($schedulerExitCode -eq 0) { $schedulerExitCode = 1 }
    }
    else {
        $finalStatus = 'completed'
    }
    $batchState.CompletedAt = (Get-Date).ToString('o')
    Save-ImageBatchState -Path $statePath -State $batchState -Jobs @($allJobs.ToArray()) -Status $finalStatus
    if (Test-Path -LiteralPath $cancelSignalPath -PathType Leaf) { Remove-Item -LiteralPath $cancelSignalPath -Force -ErrorAction SilentlyContinue }

    if ($Wait) {
        Update-ImageBatchProgress `
            -TotalCount $segments.Count `
            -QueuedCount 0 `
            -Jobs @($pendingJobs.ToArray()) `
            -CompletedCount $completedCount `
            -SuccessCount $successCount `
            -FailedCount $failedCount `
            -CurrentStatus "Image batch finished" `
            -Force
    }
}

if ($Wait) {
    Move-WorkflowCursorBelowProgress
    Write-Host ("done: ok {0} fail {1} | output: {2}" -f $successCount, $failedCount, (Get-RelativeWorkflowPath -Path $batchDirectory))
    Write-Host ("state: {0}" -f (Get-RelativeWorkflowPath -Path $statePath))
}

exit $schedulerExitCode
