[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$ImageOutputPath,
    [string]$ImageArtifactsRoot,
    [string]$RunName,
    [string]$OutputRoot,
    [string]$Model,
    [string]$ImageAspectRatio,
    [string]$ImageSize,
    [string]$ImageQuality,
    [string]$ImageOutputFormat,
    [string]$ImageOutputCompression,
    [string]$ImageModeration,
    [string]$ImageReferencePathsJson,
    [int]$ImageMaxAttempts,
    [int]$ImageRetryBaseDelaySeconds,
    [int]$ImageRetryMaxDelaySeconds,
    [int]$TimeoutSeconds,
    [int]$ImageRequestTimeoutSeconds,
    [int]$ImageTotalTimeoutSeconds,
    [switch]$GenerateImage,
    [switch]$NoReopenWindow
)

$prompt = [System.IO.File]::ReadAllText($PromptFile)
Start-Sleep -Milliseconds $(if ($prompt -match '\[SLOW\]') { 5000 } else { 150 })
if ($prompt -match '\[FAIL\]') {
    [Console]::Error.WriteLine('fake image failure')
    exit 7
}

$directory = Split-Path -Parent $ImageOutputPath
[System.IO.Directory]::CreateDirectory($directory) | Out-Null
$png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')
[System.IO.File]::WriteAllBytes($ImageOutputPath, $png)
exit 0
