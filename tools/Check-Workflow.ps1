[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

$scriptFiles = Get-ChildItem -LiteralPath $root -File |
    Where-Object { $_.Extension -in @('.ps1', '.psm1') }

foreach ($file in $scriptFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $message = ($errors | ForEach-Object { "{0}:{1}: {2}" -f $file.Name, $_.Extent.StartLineNumber, $_.Message }) -join "`n"
        throw $message
    }
}

$requiredFiles = @(
    'README.md',
    'DEVELOPMENT.md',
    'WorkflowCommon.psm1',
    'WorkflowProgressUi.ps1',
    'Invoke-CodexCliAsk.ps1',
    'Start-CodexWorkflow.ps1',
    'Start-CodexWorkflow.config.example.json',
    'Start-CodexWorkflow.zh-CN.json',
    'Start-CodexConversation.ps1',
    'Start-CodexImageBatch.ps1',
    'cli-progress-bridge.js'
)

foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file missing: $relativePath"
    }
}

$textRunnerFiles = @(
    'Invoke-CodexCliAsk.ps1',
    'Start-CodexConversation.ps1'
)

foreach ($relativePath in $textRunnerFiles) {
    $path = Join-Path $root $relativePath
    $text = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))
    if ($text.Contains('"--json"') -or $text.Contains("'--json'")) {
        throw "Text Codex runner must not use --json because terminal output should match Codex CLI human logs: $relativePath"
    }

    if ($relativePath -eq 'Start-CodexConversation.ps1' -and $text.Contains('New-CodexExecArguments')) {
        continue
    }

    if (-not $text.Contains('"--output-last-message"') -and -not $text.Contains("'--output-last-message'")) {
        throw "Text Codex runner must save the final response with --output-last-message: $relativePath"
    }
}

$commonText = [System.IO.File]::ReadAllText((Join-Path $root 'WorkflowCommon.psm1'), [System.Text.UTF8Encoding]::new($false))
if (-not $commonText.Contains("'--output-last-message'")) {
    throw 'Shared Codex argument builder must save the final response with --output-last-message.'
}

$workflowText = [System.IO.File]::ReadAllText((Join-Path $root 'Start-CodexWorkflow.ps1'), [System.Text.UTF8Encoding]::new($false))
if (-not $workflowText.Contains('[string]::IsNullOrEmpty([string]$value)')) {
    throw 'Workflow script argument builder must skip empty string parameters such as RunName.'
}
if (-not $workflowText.Contains('Write-MenuTabs -Items $items -SelectedIndex $selected')) {
    throw 'Interactive workflow menus must render through the shared tab UI.'
}
if (-not $workflowText.Contains('$navigation = Read-WorkflowTreeNavigationChoice')) {
    throw 'The main workflow must use the live tree-tab navigator.'
}
if (-not $workflowText.Contains('Write-WorkflowTreeNavigation -Roots $roots')) {
    throw 'The main workflow tree must render its submenu without opening a second menu.'
}
if ($workflowText.Contains('Write-MenuTabs -Items $Roots')) {
    throw 'The main navigation must remain vertical and must not render as a horizontal tab row.'
}
if (-not $workflowText.Contains('$rowIndex -lt $Roots.Count')) {
    throw 'The tree navigator must render main navigation items as vertical rows.'
}
if (-not $workflowText.Contains('Switch-WorkflowTreeGroup -GroupId ([string]$node.GroupId)')) {
    throw 'Tree groups must toggle in place instead of returning an empty action.'
}
if (-not $workflowText.Contains('Get-WorkflowTreeParentGroupIndex -Nodes $nodes -SelectedNode $selectedNode')) {
    throw 'Tree navigation must support returning from a child to its parent group.'
}
if ($workflowText.Contains('Format-WorkflowDisplayText -Text (Get-WorkflowTreeNodeDisplayText')) {
    throw 'Tree-node indentation must not be trimmed by the generic display formatter.'
}
if (-not $workflowText.Contains('Get-WorkflowTreeNodeDisplayText -Node $entry.Node -MaxWidth')) {
    throw 'Tree nodes must preserve hierarchy while truncating labels to the pane width.'
}
if ($workflowText.Contains('return (" {0} {1} " -f ([int]$Item.Choice)')) {
    throw 'Menu tab labels must not display numeric prefixes.'
}
if ($workflowText.Contains('Write-WorkflowStatsTabs') -or $workflowText.Contains('Get-WorkflowStatsTabs')) {
    throw 'Stats must remain a single report and must not render navigation tabs.'
}
if (-not $workflowText.Contains('$currentStamp = Get-WorkflowStatsSourceStamp')) {
    throw 'Stats must monitor the run index and refresh while the report remains open.'
}
if (-not $workflowText.Contains('Write-WorkflowStatsScreen')) {
    throw 'Stats must rebuild its data on each live refresh.'
}

$workflowConfig = [System.IO.File]::ReadAllText(
    (Join-Path $root 'Start-CodexWorkflow.config.example.json'),
    [System.Text.UTF8Encoding]::new($false)
) | ConvertFrom-Json
if ([string]$workflowConfig.Workspace -ne '.\cache') {
    throw 'The example workspace must resolve to the repository-local cache directory.'
}
foreach ($secretProperty in @('TextApiKey', 'ImageApiKey', 'OpenAIApiKey')) {
    if (-not [string]::IsNullOrWhiteSpace([string]$workflowConfig.$secretProperty)) {
        throw "Example configuration must not contain a secret: $secretProperty"
    }
}

$workflowTokens = $null
$workflowErrors = $null
$workflowAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'Start-CodexWorkflow.ps1'),
    [ref]$workflowTokens,
    [ref]$workflowErrors
)
$uiAssignment = $workflowAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$Ui' -and
        $node.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
        $node.Right.Expression -is [System.Management.Automation.Language.HashtableAst]
}, $true) | Select-Object -First 1
if ($null -eq $uiAssignment) {
    throw 'Default workflow UI dictionary was not found.'
}

$defaultUiKeys = @($uiAssignment.Right.Expression.KeyValuePairs | ForEach-Object { [string]$_.Item1.SafeGetValue() })
$localizedUi = [System.IO.File]::ReadAllText(
    (Join-Path $root 'Start-CodexWorkflow.zh-CN.json'),
    [System.Text.UTF8Encoding]::new($false)
) | ConvertFrom-Json
$localizedUiKeys = @($localizedUi.PSObject.Properties.Name)
$missingLocalizedKeys = @($defaultUiKeys | Where-Object { $_ -notin $localizedUiKeys })
if ($missingLocalizedKeys.Count -gt 0) {
    throw ("zh-CN UI keys missing: {0}" -f ($missingLocalizedKeys -join ', '))
}

Write-Host "workflow check passed"
