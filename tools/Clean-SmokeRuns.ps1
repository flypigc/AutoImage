[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RunsRoot = '.\runs',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'WorkflowCommon.psm1') -Force
Initialize-WorkflowCommon -Root $root

$resolvedRunsRoot = Resolve-WorkflowPath -Path $RunsRoot
if (-not (Test-Path -LiteralPath $resolvedRunsRoot -PathType Container)) {
    Write-Host "Smoke runs root missing: $resolvedRunsRoot"
    return
}

$targets = @(Get-ChildItem -LiteralPath $resolvedRunsRoot -Recurse -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'smoke' })

foreach ($target in $targets) {
    if (-not (Test-WorkflowCleanTarget -Path $target.FullName -AllowedRoots @((Join-Path $root 'runs')))) {
        throw "Refusing to clean unsafe target: $($target.FullName)"
    }
}

if ($targets.Count -eq 0) {
    Write-Host "No smoke runs found."
    return
}

foreach ($target in $targets) {
    if ($Force -or $PSCmdlet.ShouldProcess($target.FullName, 'Remove smoke run directory')) {
        Remove-Item -LiteralPath $target.FullName -Recurse -Force
        Write-Host ("removed: {0}" -f (Get-RelativeWorkflowPath -Path $target.FullName))
    }
}
