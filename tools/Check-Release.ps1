[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$forbiddenTrackedPaths = @(
    'Start-CodexWorkflow.config.json',
    'node_modules/',
    'runs/',
    'codex_cli_runs/',
    'pic/',
    'codex-main/'
)

$trackedFiles = @()
if (Test-Path -LiteralPath (Join-Path $root '.git') -PathType Container) {
    $trackedFiles = @(& git -C $root -c core.quotepath=false ls-files)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to enumerate tracked files.'
    }
}
else {
    $trackedFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object {
        $_.FullName.Substring($root.Length + 1).Replace('\', '/')
    } | Where-Object {
        $_ -notmatch '^(node_modules|runs|codex_cli_runs|pic|cache)/' -and
        $_ -ne 'Start-CodexWorkflow.config.json'
    })
}

foreach ($relativePath in $trackedFiles) {
    $normalized = $relativePath.Replace('\', '/')
    foreach ($forbiddenPath in $forbiddenTrackedPaths) {
        if ($normalized -eq $forbiddenPath.TrimEnd('/') -or $normalized.StartsWith($forbiddenPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Forbidden release file is tracked: $normalized"
        }
    }
}

$textExtensions = @('.cmd', '.js', '.json', '.md', '.ps1', '.psm1', '.txt', '.yml', '.yaml')
$sensitivePatterns = @(
    '(?i)C:\\Users\\[^\\\s]+',
    '(?i)D:\\Soft\\AI\\Codex',
    '(?i)sk-[A-Za-z0-9_-]{16,}'
)

foreach ($relativePath in $trackedFiles) {
    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    if ([System.IO.Path]::GetExtension($path) -notin $textExtensions) { continue }

    $text = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))
    foreach ($pattern in $sensitivePatterns) {
        if ($text -match $pattern) {
            throw "Potential local path or secret found in release file: $relativePath"
        }
    }
}

Write-Host 'release check passed'
