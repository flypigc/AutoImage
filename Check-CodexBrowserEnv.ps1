[CmdletBinding()]
param(
    [string]$CodexHome = "",
    [switch]$Json
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    }
    else {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    }
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$progressUiScript = Join-Path $scriptRoot "WorkflowProgressUi.ps1"
$browserCheckSpinnerStarted = $false
if (-not $Json -and (Test-Path -LiteralPath $progressUiScript)) {
    . $progressUiScript
    if (Get-Command Start-WorkflowSpinner -ErrorAction SilentlyContinue) {
        $browserCheckSpinnerStarted = [bool](Start-WorkflowSpinner -Text "Checking browser automation environment")
    }
}

function Test-TomlSectionEnabled {
    param(
        [string]$ConfigText,
        [string]$SectionName
    )

    $pattern = '(?ms)^\[' + [regex]::Escape($SectionName) + '\]\s*.*?^enabled\s*=\s*true\s*$'
    return [regex]::IsMatch($ConfigText, $pattern)
}

function Test-TomlSectionPresent {
    param(
        [string]$ConfigText,
        [string]$SectionName
    )

    $pattern = '(?m)^\[' + [regex]::Escape($SectionName) + '\]\s*$'
    return [regex]::IsMatch($ConfigText, $pattern)
}

function Test-TomlAnyPluginEnabled {
    param(
        [string]$ConfigText,
        [string[]]$PluginNames
    )

    foreach ($pluginName in $PluginNames) {
        $pattern = '(?ms)^\[plugins\."' + [regex]::Escape($pluginName) + '@[^"]+"\]\s*.*?^enabled\s*=\s*true\s*$'
        if ([regex]::IsMatch($ConfigText, $pattern)) {
            return $true
        }
    }

    return $false
}

function Get-PluginRoot {
    param(
        [string]$PluginCacheRoot
    )

    if (-not (Test-Path -LiteralPath $PluginCacheRoot)) {
        return $null
    }

    $dirs = @(Get-ChildItem -LiteralPath $PluginCacheRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName ".codex-plugin\plugin.json") } |
        Sort-Object Name -Descending)

    if ($dirs.Count -eq 0) {
        return $null
    }

    return $dirs[0].FullName
}

function Get-FirstExistingPluginRoot {
    param(
        [string[]]$PluginCacheRoots
    )

    foreach ($root in $PluginCacheRoots) {
        $pluginRoot = Get-PluginRoot -PluginCacheRoot $root
        if ($pluginRoot) {
            return $pluginRoot
        }
    }

    return $null
}

function Invoke-NodeJson {
    param(
        [string]$ScriptPath
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        return @{
            ok = $false
            exitCode = $null
            raw = "missing script: $ScriptPath"
            data = $null
        }
    }

    $output = & node $ScriptPath --json 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $trimmed = $output.Trim()
    $data = $null

    if ($trimmed) {
        try {
            $data = $trimmed | ConvertFrom-Json
        } catch {
            $data = $null
        }
    }

    return @{
        ok = ($data -ne $null)
        exitCode = $exitCode
        raw = $trimmed
        data = $data
    }
}

function Find-ChromePath {
    $roots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:LOCALAPPDATA
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $candidates = @($roots | ForEach-Object {
        Join-Path $_ 'Google\Chrome\Application\chrome.exe'
    })

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

$configPath = Join-Path $CodexHome "config.toml"
$configText = if (Test-Path -LiteralPath $configPath) {
    Get-Content -Raw -LiteralPath $configPath
} else {
    ""
}

$browserPluginEnabled = Test-TomlAnyPluginEnabled -ConfigText $configText -PluginNames @("browser", "browser-use")
$chromePluginEnabled = Test-TomlAnyPluginEnabled -ConfigText $configText -PluginNames @("chrome")
$chromeDevtoolsConfigured = Test-TomlSectionPresent -ConfigText $configText -SectionName 'mcp_servers.chrome-devtools'

$browserPluginRoot = Get-FirstExistingPluginRoot -PluginCacheRoots @(
    (Join-Path $CodexHome "plugins\cache\browser-recovery\browser-use"),
    (Join-Path $CodexHome "plugins\cache\openai-bundled\browser-use"),
    (Join-Path $CodexHome "plugins\cache\openai-bundled\browser")
)

$chromePluginRoot = Get-FirstExistingPluginRoot -PluginCacheRoots @(
    (Join-Path $CodexHome "plugins\cache\openai-bundled\chrome"),
    (Join-Path $CodexHome "plugins\cache\browser-recovery\chrome")
)

$extensionId = $null
$webStoreUrl = $null
$installedBrowsersResult = $null
$extensionResult = $null
$nativeHostResult = $null

if ($chromePluginRoot) {
    $extensionIdPath = Join-Path $chromePluginRoot "scripts\extension-id.json"
    if (Test-Path -LiteralPath $extensionIdPath) {
        try {
            $extensionId = (Get-Content -Raw -LiteralPath $extensionIdPath | ConvertFrom-Json).extensionId
        } catch {
            $extensionId = $null
        }
    }

    if ($extensionId) {
        $webStoreUrl = "https://chromewebstore.google.com/detail/codex/$extensionId"
    }

    $installedBrowsersResult = Invoke-NodeJson -ScriptPath (Join-Path $chromePluginRoot "scripts\installed-browsers.js")
    $extensionResult = Invoke-NodeJson -ScriptPath (Join-Path $chromePluginRoot "scripts\check-extension-installed.js")
    $nativeHostResult = Invoke-NodeJson -ScriptPath (Join-Path $chromePluginRoot "scripts\check-native-host-manifest.js")
} elseif ($browserPluginRoot) {
    $installedBrowsersResult = Invoke-NodeJson -ScriptPath (Join-Path $browserPluginRoot "scripts\installed-browsers.js")
}

$chromePath = Find-ChromePath
$chromeInstalled = $chromePath -ne $null

if ((-not $chromeInstalled) -and $installedBrowsersResult -and $installedBrowsersResult.data -and $installedBrowsersResult.data.installed_browsers) {
    $installedBrowsers = @($installedBrowsersResult.data.installed_browsers)
    $chromeEntry = $installedBrowsers | Where-Object { $_.name -eq "Google Chrome" } | Select-Object -First 1
    if ($chromeEntry) {
        $chromeInstalled = $true
        $chromePath = $chromeEntry.path
    }
}

$extensionInstalled = $null
$extensionEnabled = $null
$nativeHostReady = $null
$nativeHostProblem = $null

if ($extensionResult -and $extensionResult.data) {
    $extensionInstalled = [bool]$extensionResult.data.installed
    $extensionEnabled = [bool]$extensionResult.data.enabled
}

if ($nativeHostResult -and $nativeHostResult.data) {
    $nativeHostReady = [bool]$nativeHostResult.data.correct
    $nativeHostProblem = $nativeHostResult.data.problem
}

$chromeDevtoolsReady = $chromeDevtoolsConfigured -and $chromeInstalled
$chromeExtensionModeReady = $chromePluginEnabled -and $chromeInstalled -and ($extensionInstalled -eq $true) -and ($extensionEnabled -eq $true) -and ($nativeHostReady -eq $true)

$nextActions = New-Object System.Collections.Generic.List[string]

if (-not $browserPluginEnabled) {
    $nextActions.Add("Enable a browser plugin in Codex. The local recovery plugin browser-use@browser-recovery can be used for in-app browser automation.")
}
if (-not $chromePluginEnabled) {
    $nextActions.Add("Restore the Chrome plugin in Codex. Without it, Codex cannot verify or use the Chrome extension mode.")
}
if (-not $chromeInstalled) {
    $nextActions.Add("Install Google Chrome Stable.")
}
if ($chromePluginRoot -and ($extensionInstalled -eq $false)) {
    if ($webStoreUrl) {
        $nextActions.Add("Install the Codex Chrome Extension: $webStoreUrl")
    } else {
        $nextActions.Add("Install the Codex Chrome Extension in Chrome.")
    }
} elseif ($chromePluginRoot -and ($extensionEnabled -eq $false)) {
    $nextActions.Add("Enable the Codex Chrome Extension in chrome://extensions/.")
}
if (-not $chromePluginRoot) {
    $nextActions.Add("Reinstall the official Chrome plugin from the Codex app plugin UI so its native host files and checks are restored.")
} elseif ($chromePluginEnabled -and ($nativeHostReady -eq $false)) {
    $nextActions.Add("Reinstall the Chrome plugin from the Codex plugin UI to restore native host registration.")
}

$summary = [ordered]@{
    codexHome = $CodexHome
    browserPluginEnabled = $browserPluginEnabled
    browserPluginRoot = $browserPluginRoot
    chromePluginEnabled = $chromePluginEnabled
    chromePluginRoot = $chromePluginRoot
    chromeDevtoolsConfigured = $chromeDevtoolsConfigured
    chromeInstalled = $chromeInstalled
    chromePath = $chromePath
    chromeDevtoolsReady = $chromeDevtoolsReady
    extensionId = $extensionId
    codexChromeWebStoreUrl = $webStoreUrl
    extensionInstalled = $extensionInstalled
    extensionEnabled = $extensionEnabled
    nativeHostReady = $nativeHostReady
    nativeHostProblem = $nativeHostProblem
    chromeExtensionModeReady = $chromeExtensionModeReady
    nextActions = @($nextActions)
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 6
    exit 0
}

if (Get-Command Stop-WorkflowSpinner -ErrorAction SilentlyContinue) {
    [void](Stop-WorkflowSpinner -State "succeed" -Text "Browser environment check complete")
}

Write-Host "Codex browser automation status"
Write-Host ("CODEX_HOME              {0}" -f $summary.codexHome)
Write-Host ("browser plugin enabled  {0}" -f $(if ($summary.browserPluginEnabled) { "yes" } else { "no" }))
Write-Host ("chrome plugin enabled   {0}" -f $(if ($summary.chromePluginEnabled) { "yes" } else { "no" }))
Write-Host ("chrome installed        {0}" -f $(if ($summary.chromeInstalled) { "yes" } else { "no" }))
if ($summary.chromePath) {
    Write-Host ("chrome path             {0}" -f $summary.chromePath)
}
Write-Host ("chrome-devtools ready   {0}" -f $(if ($summary.chromeDevtoolsReady) { "yes" } else { "no" }))
Write-Host ("extension installed     {0}" -f $(if ($null -eq $summary.extensionInstalled) { "unknown" } elseif ($summary.extensionInstalled) { "yes" } else { "no" }))
Write-Host ("extension enabled       {0}" -f $(if ($null -eq $summary.extensionEnabled) { "unknown" } elseif ($summary.extensionEnabled) { "yes" } else { "no" }))
Write-Host ("native host ready       {0}" -f $(if ($null -eq $summary.nativeHostReady) { "unknown" } elseif ($summary.nativeHostReady) { "yes" } else { "no" }))
Write-Host ("chrome extension mode   {0}" -f $(if ($summary.chromeExtensionModeReady) { "yes" } else { "no" }))

if ($summary.nativeHostProblem) {
    Write-Host ("native host problem     {0}" -f $summary.nativeHostProblem)
}
if ($summary.codexChromeWebStoreUrl) {
    Write-Host ("web store               {0}" -f $summary.codexChromeWebStoreUrl)
}

$nextActionItems = @($summary.nextActions)
if ($nextActionItems.Count -gt 0) {
    Write-Host ""
    Write-Host "Next actions"
    foreach ($action in $nextActionItems) {
        Write-Host ("- {0}" -f $action)
    }
}
