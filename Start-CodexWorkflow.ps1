[CmdletBinding()]
param(
    [string]$Workspace = '.\cache',
    [string]$DefaultOutputRoot = '.\runs\text',
    [string]$DefaultImageRoot = '.\runs\images',
    [ValidateSet('en', 'zh-CN')]
    [string]$Language = 'en'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $script:OutputEncoding = [System.Text.UTF8Encoding]::new($false)
}
catch {
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$invokeScript = Join-Path $scriptRoot "Invoke-CodexCliAsk.ps1"
$conversationScript = Join-Path $scriptRoot "Start-CodexConversation.ps1"
$imageBatchScript = Join-Path $scriptRoot "Start-CodexImageBatch.ps1"
$envCheckScript = Join-Path $scriptRoot "Check-CodexBrowserEnv.ps1"
$progressUiScript = Join-Path $scriptRoot "WorkflowProgressUi.ps1"
$commonScript = Join-Path $scriptRoot "WorkflowCommon.psm1"
$workflowConfigPath = Join-Path $scriptRoot "Start-CodexWorkflow.config.json"
$conversationExampleDefault = '.\conversation_example.txt'
$promptBatchDefault = '.\prompts.md'
$singleImageOutputDefault = '.\runs\images\output.png'

$WorkflowConfig = [ordered]@{
    Language = $Language
    Workspace = $Workspace
    OutputRoot = $DefaultOutputRoot
    ImageOutputRoot = $DefaultImageRoot
    TextApiName = ""
    TextApiKey = ""
    TextBaseUrl = ""
    TextModel = ""
    TextApiProfiles = @()
    ImageApiName = ""
    ImageApiKey = ""
    ImageBaseUrl = ""
    ImageModel = ""
    ImageApiProfiles = @()
    ImageAspectRatio = ""
    ImageSize = ""
    ImageQuality = ""
    ImageFormat = "png"
    ImageCompressionQuality = ""
    ImageModeration = "low"
    OpenAIApiKey = ""
    OpenAIBaseUrl = ""
    MaxConcurrency = 2
    MaxAttempts = 6
    RetryBaseDelaySeconds = 2
    RetryMaxDelaySeconds = 20
    TimeoutSeconds = 600
    ImageRequestTimeoutSeconds = 600
    ImageTotalTimeoutSeconds = 1800
    WaitInTerminal = $true
}

if (Test-Path -LiteralPath $workflowConfigPath -PathType Leaf) {
    try {
        $loadedConfig = [System.IO.File]::ReadAllText($workflowConfigPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in $loadedConfig.PSObject.Properties) {
            if ($WorkflowConfig.Contains($property.Name)) {
                $WorkflowConfig[$property.Name] = $property.Value
            }
        }
    }
    catch {
    }
}

if ($PSBoundParameters.ContainsKey('Language')) {
    $WorkflowConfig.Language = $Language
}
elseif ($WorkflowConfig.Language -in @('en', 'zh-CN')) {
    $Language = [string]$WorkflowConfig.Language
}

if ($PSBoundParameters.ContainsKey('Workspace')) {
    $WorkflowConfig.Workspace = $Workspace
}
else {
    $Workspace = [string]$WorkflowConfig.Workspace
}

if ($PSBoundParameters.ContainsKey('DefaultOutputRoot')) {
    $WorkflowConfig.OutputRoot = $DefaultOutputRoot
}
else {
    $DefaultOutputRoot = [string]$WorkflowConfig.OutputRoot
}

if ($PSBoundParameters.ContainsKey('DefaultImageRoot')) {
    $WorkflowConfig.ImageOutputRoot = $DefaultImageRoot
}
else {
    $DefaultImageRoot = [string]$WorkflowConfig.ImageOutputRoot
}

if ([string]::IsNullOrWhiteSpace([string]$WorkflowConfig.ImageFormat)) {
    $WorkflowConfig.ImageFormat = "png"
}
if ([string]::IsNullOrWhiteSpace([string]$WorkflowConfig.ImageModeration)) {
    $WorkflowConfig.ImageModeration = "low"
}

if (Test-Path -LiteralPath $progressUiScript) {
    . $progressUiScript
}

Import-Module $commonScript -Force
Initialize-WorkflowCommon -Root $scriptRoot

$Ui = @{
    Banner = "Codex Workflow Interactive Terminal UI"
    Menu1 = "Chat"
    Menu2 = "Batch"
    Menu3 = "Images"
    Menu4 = "Stats"
    Menu5 = "Settings"
    Menu0 = "Exit"
    TreeRegionMain = "Main"
    TreeRegionSubmenu = "Submenu"
    TreeRegionCurrent = "Current"
    TreeHint = "Up/Down selects; Right expands; Left collapses or returns; Enter toggles or runs; Tab switches panes."
    TreeStatsAction = "View statistics"
    TreeExitAction = "Exit workflow"
    StatsTitle = "Codex Workflow htop | token, time, and run history"
    StatsSectionType = "By type"
    StatsSectionModel = "By model"
    StatsSectionRecent = "Recent runs"
    StatsNoHistory = "No history found under runs\index.jsonl."
    StatsRows = "Rows {0}-{1} of {2}"
    StatsRunsSummary = "Runs {0} | OK {1} | Fail {2} | Success {3} | Time {4}"
    StatsAverageSummary = "Avg {0} | Fast {1} | Slow {2} | Cache {3}"
    StatsTodaySummary = "Today {0:N0} tok/{1} runs | 24h {2:N0} tok/{3} runs | Avg/run {4:N0}"
    StatsTokenNote = "Token totals use captured usage from history and summaries."
    StatsMissingUsageNote = "Older or image runs without usage are counted as 0 tokens."
    StatsLiveHint = "Auto refresh | R refresh | Enter/Esc/Ctrl+Z return"
    StatsBarTotal = "Total token"
    StatsBarInput = "Input/total"
    StatsBarCached = "Cached/input"
    StatsBarOutput = "Output/total"
    StatsBarReasoning = "Reason/output"
    StatsColumnIndex = "ID"
    StatsColumnType = "TYPE"
    StatsColumnRuns = "RUNS"
    StatsColumnOk = "OK"
    StatsColumnFail = "FAIL"
    StatsColumnTokens = "TOKENS"
    StatsColumnInput = "INPUT"
    StatsColumnOutput = "OUTPUT"
    StatsColumnTime = "TIME"
    StatsColumnModel = "MODEL"
    StatsColumnAverage = "AVG"
    StatsColumnStatus = "ST"
    StatsColumnName = "NAME"
    StatsUnknown = "(unknown)"
    StatsDefaultModel = "(default)"
    StatsStatusOk = "ok"
    StatsStatusFail = "fail"
    ChatMenu1 = "Codex"
    ChatMenu2 = "Single prompt run"
    CodexTuiLaunch = "Use /exit, Ctrl+D, or Codex's Ctrl+C flow to return."
    CodexTuiReturned = "Returned from Codex TUI."
    BatchMenu1 = "Single prompt file"
    BatchMenu2 = "Prompt list batch"
    BatchMenu3 = "Conversation batch"
    ImageMenu1 = "Single image generation"
    ImageMenu2 = "Image batch"
    ImageMenu3 = "Retry failed image batch"
    ImageMenu4 = "Cancel running image batch"
    ConfigMenu1 = "View current settings"
    ConfigMenu2 = "Language"
    ConfigMenu3 = "API profiles"
    ConfigMenu4 = "Default paths"
    ConfigMenu5 = "Batch defaults"
    ConfigMenu6 = "Image generation settings"
    ApiMenu1 = "Text config"
    ApiMenu2 = "Image config"
    ApiDetailMenu1 = "Primary API"
    ApiDetailMenu2 = "Fallback APIs"
    ApiDetailMenu3 = "Test"
    BackMenu0 = "Back"
    SelectAction = "Select an action"
    MenuHint = "Left/Right or Tab selects; Enter opens; number quick-select; Esc exits."
    SubMenuHint = "Left/Right or Tab selects; Enter opens; number quick-select; Esc or Ctrl+Z returns."
    InvalidChoice = "Invalid choice."
    Required = "This value is required."
    PathNotFound = "Path not found: {0}"
    EnterInteger = "Enter an integer between {0} and {1}."
    EnterYesNo = "Enter y or n."
    PromptIntro = "Enter prompt text. Type END on its own line to finish. Esc exits; Ctrl+Z returns to the menu."
    ComposerTitle = "Message Codex"
    ComposerHint = "Enter sends. Shift+Enter, Ctrl+Enter, or Ctrl+J inserts a new line. Esc exits. Ctrl+Z returns."
    ComposerPrompt = "codex"
    ComposerEmpty = "Type a message before sending."
    PromptEmpty = "Prompt must not be empty."
    PressEnter = "Press Enter to return to the menu"
    WorkflowFailed = "Workflow failed:"
    WorkflowCanceled = "Canceled. Returned to the main menu."
    WorkflowExitCode = "Process exited with code {0}."
    BackgroundSchedulerStarted = "Background scheduler started (PID {0})."
    InputHint = "Esc exits. Ctrl+Z returns to the main menu."
    WorkspacePath = "Workspace path"
    OutputRoot = "Output root"
    RunNameOptional = "Run name (optional)"
    ModelOptional = "Model (optional)"
    RunArchive = "Archive this run"
    OpenSummary = "Open summary when finished"
    ParseOnly = "Parse only (do not execute)"
    BatchFailurePolicy = "Failure policy"
    BatchFailureContinue = "Continue after failures"
    BatchFailureStop = "Stop at first failure"
    BatchPreview = "Prompt preview"
    ResumePromptBatch = "Resume incomplete prompt batch"
    LanguageLabel = "Language"
    ApiKeyLabel = "OpenAI API key"
    BaseUrlLabel = "OpenAI base URL"
    TextApiKeyLabel = "Text API key"
    TextBaseUrlLabel = "Text base URL"
    TextPrimaryApiLabel = "Text primary API"
    ImageApiKeyLabel = "Image API key"
    ImageBaseUrlLabel = "Image base URL"
    ImagePrimaryApiLabel = "Image primary API"
    TextApiProfilesLabel = "Text fallback API profiles"
    ImageApiProfilesLabel = "Image fallback API profiles"
    ApiProfileNameLabel = "API name"
    ApiProfileKeyLabel = "API key"
    ApiProfileBaseUrlLabel = "Base URL"
    ApiProfileModelLabel = "Model"
    FallbackApiAdd = "Add fallback API"
    FallbackApiEdit = "Edit by index"
    FallbackApiDelete = "Delete by index"
    FallbackApiMoveUp = "Move up"
    FallbackApiMoveDown = "Move down"
    FallbackApiClear = "Clear all"
    FallbackApiNoProfiles = "No fallback APIs configured"
    FallbackApiIndexLabel = "Fallback API index"
    FallbackApiClearConfirm = "Clear all fallback APIs"
    TextModel = "Text model"
    ConfigSaved = "Settings saved."
    ConfigFile = "Settings file"
    ConfigCurrent = "Current settings"
    ConfigNotSet = "(not set)"
    ConfigKeepBlank = "Leave blank to keep current value. Type CLEAR to clear."
    ApiTestSuccess = "API connection succeeded."
    ApiTestFailed = "API connection failed:"
    ApiTestMissingKey = "API key is not configured. Set it in Settings or OPENAI_API_KEY."
    ApiTestEndpoint = "Endpoint"
    CleanHistoryConfirm = "Delete all files under the managed text and image output directories"
    CleanHistoryDone = "History output directories cleaned."
    CleanHistorySkipMissing = "Skipped missing directory: {0}"
    CleanHistoryTarget = "Target"
    ImageAspectRatio = "Image aspect ratio"
    ImageSize = "Image size"
    ImageQuality = "Image quality"
    ImageFormat = "Image format"
    ImageCompressionQuality = "Compression quality"
    ImageModeration = "Risk check"
    ImageGenerationAuto = "Auto"
    ImageCompressionCustom = "Custom 0-100"
    ImageQualityLow = "Low"
    ImageQualityMedium = "Medium"
    ImageQualityHigh = "High"
    ImageModerationLow = "Low"
    PromptFile = "Prompt file"
    PromptListFile = "Prompt list file"
    BatchNameOptional = "Batch name (optional)"
    ConversationFile = "Conversation file"
    ConversationResumeTitle = "Conversation batch state"
    ConversationNewRun = "Start a new conversation batch"
    ConversationGroups = "Groups"
    ConversationPrompts = "Prompts"
    ConversationCompleted = "Completed operations"
    ConversationRemaining = "Remaining operations"
    SummaryPromptFileOptional = "Summary prompt file (optional)"
    ImageArtifactsRoot = "Image artifacts root"
    ImageOutputPath = "Image output path"
    ImageExtensionMismatch = "Output extension must match the selected image format ({0})."
    OpenImage = "Open image when finished"
    OpenImageFolder = "Open image folder when finished"
    ImageApiProfile = "Image API profile"
    ReferenceAspectRatioIgnored = "Reference-image edits ignore the global aspect ratio setting."
    ImageBatchStateTitle = "Image batch state"
    ImageBatchNoStates = "No matching image batch states were found."
    ImageBatchCancelRequested = "Cancellation requested for image batch: {0}"
    ImageReferencePromptCount = "Prompts with reference images"
    ImageModel = "Image model"
    MaxAttempts = "Max attempts"
    RetryBase = "Retry base delay seconds"
    RetryMax = "Retry max delay seconds"
    TimeoutSeconds = "Codex timeout seconds"
    ImageRequestTimeoutSeconds = "Image request timeout seconds"
    ImageTotalTimeoutSeconds = "Image total timeout seconds"
    PromptBatchFile = "Prompt batch file"
    ImageOutputRoot = "Image output root"
    MaxConcurrency = "Max concurrency"
    WaitInTerminal = "Wait for completion in this terminal"
    EndToken = "END"
    YesTokens = "y,yes"
    NoTokens = "n,no"
    YesNoDefaultTrue = "Y/n"
    YesNoDefaultFalse = "y/N"
}

$DefaultUi = $Ui.Clone()

$WorkflowExitSignal = "__CODEX_WORKFLOW_EXIT__"
$WorkflowBackSignal = "__CODEX_WORKFLOW_BACK__"
$script:WorkflowComposerBottom = -1
$script:WorkflowOriginalTreatControlCAsInput = $null
$script:WorkflowTreeRootIndex = 0
$script:WorkflowTreeSelections = @{}
$script:WorkflowTreeFocus = 'Main'
$script:WorkflowTreeExpandedGroups = @{
    ConfigApi = $true
    ConfigText = $true
    ConfigImage = $false
    ConfigImageGeneration = $false
}
$script:CodexBoxTopLeft = [string][char]0x256D
$script:CodexBoxTopRight = [string][char]0x256E
$script:CodexBoxBottomLeft = [string][char]0x2570
$script:CodexBoxBottomRight = [string][char]0x256F
$script:CodexBoxHorizontal = [string][char]0x2500
$script:CodexBoxVertical = [string][char]0x2502

try {
    $script:WorkflowOriginalTreatControlCAsInput = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
}
catch {
}

function Import-WorkflowUiLanguage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LanguageName
    )

    if ($LanguageName -eq 'en') {
        return
    }

    $languageFile = Join-Path $scriptRoot ("Start-CodexWorkflow.{0}.json" -f $LanguageName)
    if (-not (Test-Path -LiteralPath $languageFile)) {
        return
    }

    $json = [System.IO.File]::ReadAllText($languageFile, [System.Text.UTF8Encoding]::new($false))
    $localizedUi = $json | ConvertFrom-Json

    foreach ($property in $localizedUi.PSObject.Properties) {
        $Ui[$property.Name] = [string]$property.Value
    }

    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $script:OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    }
    catch {
    }
}

function Set-WorkflowUiLanguage {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('en', 'zh-CN')]
        [string]$LanguageName
    )

    $Ui.Clear()
    foreach ($key in $DefaultUi.Keys) {
        $Ui[$key] = $DefaultUi[$key]
    }

    Import-WorkflowUiLanguage -LanguageName $LanguageName
}

function ConvertTo-WorkflowInt {
    param(
        [object]$Value,
        [int]$DefaultValue,
        [int]$Min = 1,
        [int]$Max = [int]::MaxValue
    )

    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) {
        return [Math]::Min($Max, [Math]::Max($Min, $parsed))
    }

    return $DefaultValue
}

function ConvertTo-WorkflowBool {
    param(
        [object]$Value,
        [bool]$DefaultValue = $true
    )

    if ($Value -is [bool]) {
        return [bool]$Value
    }

    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -in @('true', '1', 'yes', 'y')) {
        return $true
    }

    if ($text -in @('false', '0', 'no', 'n')) {
        return $false
    }

    return $DefaultValue
}

function Save-WorkflowConfig {
    $json = $WorkflowConfig | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($workflowConfigPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Apply-WorkflowConfig {
    if ($WorkflowConfig.Language -in @('en', 'zh-CN')) {
        $script:Language = [string]$WorkflowConfig.Language
        Set-WorkflowUiLanguage -LanguageName $script:Language
    }

    $script:Workspace = [string]$WorkflowConfig.Workspace
    $script:DefaultOutputRoot = [string]$WorkflowConfig.OutputRoot
    $script:DefaultImageRoot = [string]$WorkflowConfig.ImageOutputRoot
}

function Get-MaskedSecret {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Ui.ConfigNotSet
    }

    if ($Value.Length -le 8) {
        return "********"
    }

    return "{0}...{1}" -f $Value.Substring(0, 4), $Value.Substring($Value.Length - 4)
}

Set-WorkflowUiLanguage -LanguageName $Language
Apply-WorkflowConfig

function Resolve-UserPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [switch]$MustExist
    )

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    }
    else {
        Join-Path $scriptRoot $Path
    }

    if ($MustExist) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    return [System.IO.Path]::GetFullPath($candidate)
}

function Write-Banner {
    param([switch]$NoClear)

    if ($NoClear) {
        try {
            [Console]::SetCursorPosition(0, 0)
        }
        catch {
        }
    }
    else {
        Clear-WorkflowProgressArea -Anchor Top
        Clear-WorkflowProgressArea -Anchor Bottom
        Clear-Host
    }

    $corner = [string][char]0x250C
    $horizontal = [string][char]0x2500
    $vertical = [string][char]0x2502
    Write-Host ""
    Write-Host ("{0}{1} {2}" -f $corner, $horizontal, $Ui.Banner) -ForegroundColor Cyan
    Write-Host $vertical -ForegroundColor DarkGray
}

function Write-FrameLine {
    param(
        [AllowEmptyString()]
        [string]$Text = "",
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,
        [switch]$Color
    )

    $vertical = [string][char]0x2502
    if ([string]::IsNullOrEmpty($Text)) {
        Write-Host $vertical -ForegroundColor DarkGray
        return
    }

    Write-Host -NoNewline ("{0} " -f $vertical) -ForegroundColor DarkGray
    if ($Color) {
        Write-Host $Text -ForegroundColor $ForegroundColor
    }
    else {
        Write-Host $Text
    }
}

function Test-ControlZKey {
    param(
        [Parameter(Mandatory = $true)]
        [ConsoleKeyInfo]$KeyInfo
    )

    return (
        ($KeyInfo.Key -eq [ConsoleKey]::Z -and (($KeyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) -or
        ([int][char]$KeyInfo.KeyChar -eq 26)
    )
}

function Test-ControlCKey {
    param(
        [Parameter(Mandatory = $true)]
        [ConsoleKeyInfo]$KeyInfo
    )

    return (
        ($KeyInfo.Key -eq [ConsoleKey]::C -and (($KeyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) -or
        ([int][char]$KeyInfo.KeyChar -eq 3)
    )
}

function Read-InteractiveLine {
    param(
        [AllowEmptyString()]
        [string]$PromptText = ""
    )

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        return (Read-Host $PromptText)
    }

    try {
        [Console]::CursorVisible = $true
    }
    catch {
    }

    if (-not [string]::IsNullOrEmpty($PromptText)) {
        Write-Host -NoNewline ($PromptText + ": ")
    }

    $buffer = New-Object System.Text.StringBuilder

    while ($true) {
        $key = [Console]::ReadKey($true)

        if (Test-ControlCKey -KeyInfo $key) {
            throw $WorkflowBackSignal
        }

        if ($key.Key -eq [ConsoleKey]::Escape) {
            throw $WorkflowExitSignal
        }

        if (Test-ControlZKey -KeyInfo $key) {
            throw $WorkflowBackSignal
        }

        if ($key.Key -eq [ConsoleKey]::Enter) {
            Write-Host ""
            return $buffer.ToString()
        }

        if ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($buffer.Length -gt 0) {
                [void]$buffer.Remove($buffer.Length - 1, 1)
                Write-Host -NoNewline "`b `b"
            }
            continue
        }

        if (-not [char]::IsControl($key.KeyChar)) {
            [void]$buffer.Append($key.KeyChar)
            Write-Host -NoNewline $key.KeyChar
        }
    }
}

function Get-MenuItems {
    return @(
        [pscustomobject]@{ Choice = 1; Text = $Ui.Menu1 }
        [pscustomobject]@{ Choice = 2; Text = $Ui.Menu2 }
        [pscustomobject]@{ Choice = 3; Text = $Ui.Menu3 }
        [pscustomobject]@{ Choice = 4; Text = $Ui.Menu4 }
        [pscustomobject]@{ Choice = 5; Text = $Ui.Menu5 }
        [pscustomobject]@{ Choice = 0; Text = $Ui.Menu0 }
    )
}

function Get-ChatMenuItems {
    return @(
        [pscustomobject]@{ Choice = 1; Text = $Ui.ChatMenu1 }
        [pscustomobject]@{ Choice = 2; Text = $Ui.ChatMenu2 }
        [pscustomobject]@{ Choice = 0; Text = $Ui.BackMenu0 }
    )
}

function Get-BatchMenuItems {
    return @(
        [pscustomobject]@{ Choice = 1; Text = $Ui.BatchMenu1 }
        [pscustomobject]@{ Choice = 2; Text = $Ui.BatchMenu2 }
        [pscustomobject]@{ Choice = 3; Text = $Ui.BatchMenu3 }
        [pscustomobject]@{ Choice = 0; Text = $Ui.BackMenu0 }
    )
}

function Get-ImageMenuItems {
    return @(
        [pscustomobject]@{ Choice = 1; Text = $Ui.ImageMenu1 }
        [pscustomobject]@{ Choice = 2; Text = $Ui.ImageMenu2 }
        [pscustomobject]@{ Choice = 3; Text = $Ui.ImageMenu3 }
        [pscustomobject]@{ Choice = 4; Text = $Ui.ImageMenu4 }
        [pscustomobject]@{ Choice = 0; Text = $Ui.BackMenu0 }
    )
}

function Get-ConfigMenuItems {
    return @(
        [pscustomobject]@{ Choice = 1; Text = $Ui.ConfigMenu1 }
        [pscustomobject]@{ Choice = 2; Text = $Ui.ConfigMenu2 }
        [pscustomobject]@{ Choice = 3; Text = $Ui.ConfigMenu3 }
        [pscustomobject]@{ Choice = 4; Text = $Ui.ConfigMenu4 }
        [pscustomobject]@{ Choice = 5; Text = $Ui.ConfigMenu5 }
        [pscustomobject]@{ Choice = 6; Text = $Ui.ConfigMenu6 }
        [pscustomobject]@{ Choice = 0; Text = $Ui.BackMenu0 }
    )
}

function Get-ImageGenerationConfigMenuItems {
    return @(
        [pscustomobject]@{ Choice = 1; Text = $Ui.ImageAspectRatio }
        [pscustomobject]@{ Choice = 2; Text = $Ui.ImageSize }
        [pscustomobject]@{ Choice = 3; Text = $Ui.ImageQuality }
        [pscustomobject]@{ Choice = 4; Text = $Ui.ImageFormat }
        [pscustomobject]@{ Choice = 5; Text = $Ui.ImageCompressionQuality }
        [pscustomobject]@{ Choice = 6; Text = $Ui.ImageModeration }
        [pscustomobject]@{ Choice = 0; Text = $Ui.BackMenu0 }
    )
}

function Get-ConfigApiMenuItems {
    return @(
        [pscustomobject]@{ Choice = 1; Text = $Ui.ApiMenu1 }
        [pscustomobject]@{ Choice = 2; Text = $Ui.ApiMenu2 }
        [pscustomobject]@{ Choice = 0; Text = $Ui.BackMenu0 }
    )
}

function Get-ConfigApiDetailMenuItems {
    return @(
        [pscustomobject]@{ Choice = 1; Text = $Ui.ApiDetailMenu1 }
        [pscustomobject]@{ Choice = 2; Text = $Ui.ApiDetailMenu2 }
        [pscustomobject]@{ Choice = 3; Text = $Ui.ApiDetailMenu3 }
        [pscustomobject]@{ Choice = 0; Text = $Ui.BackMenu0 }
    )
}

function Test-MenuChoice {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,
        [int]$Choice
    )

    foreach ($item in $Items) {
        if ([int]$item.Choice -eq $Choice) {
            return $true
        }
    }

    return $false
}

function Test-MenuChoicePrefix {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,
        [Parameter(Mandatory = $true)]
        [string]$Prefix
    )

    foreach ($item in $Items) {
        $choiceText = [string][int]$item.Choice
        if ($choiceText.Length -gt $Prefix.Length -and $choiceText.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
            return $true
        }
    }

    return $false
}

function Get-MenuTabText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    return (" {0} " -f ([string]$Item.Text))
}

function Get-MenuTabContentWidth {
    try {
        if (-not [Console]::IsOutputRedirected) {
            return [Math]::Max(20, [Console]::WindowWidth - 3)
        }
    }
    catch {
    }

    return 76
}

function Write-MenuTabs {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,
        [int]$SelectedIndex = 0
    )

    $contentWidth = Get-MenuTabContentWidth
    $rows = New-Object System.Collections.Generic.List[object]
    $currentRow = New-Object System.Collections.Generic.List[object]
    $currentWidth = 0

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $text = Get-MenuTabText -Item $Items[$i]
        $tabWidth = Get-WorkflowDisplayWidth -Text $text
        if ($tabWidth -gt $contentWidth) {
            $text = Format-WorkflowDisplayText -Text $text -MaxWidth $contentWidth
            $tabWidth = Get-WorkflowDisplayWidth -Text $text
        }
        $gapWidth = if ($currentRow.Count -gt 0) { 1 } else { 0 }

        if ($currentRow.Count -gt 0 -and ($currentWidth + $gapWidth + $tabWidth) -gt $contentWidth) {
            [void]$rows.Add(@($currentRow.ToArray()))
            $currentRow = New-Object System.Collections.Generic.List[object]
            $currentWidth = 0
            $gapWidth = 0
        }

        [void]$currentRow.Add([pscustomobject]@{
            Index = $i
            Text = $text
        })
        $currentWidth += $gapWidth + $tabWidth
    }

    if ($currentRow.Count -gt 0) {
        [void]$rows.Add(@($currentRow.ToArray()))
    }

    $vertical = [string][char]0x2502
    foreach ($row in $rows) {
        Write-Host -NoNewline ("{0} " -f $vertical) -ForegroundColor DarkGray
        $tabs = @($row)
        for ($i = 0; $i -lt $tabs.Count; $i++) {
            if ($i -gt 0) {
                Write-Host -NoNewline " "
            }
            if ([int]$tabs[$i].Index -eq $SelectedIndex) {
                Write-Host -NoNewline $tabs[$i].Text -ForegroundColor Black -BackgroundColor Cyan
            }
            else {
                Write-Host -NoNewline $tabs[$i].Text -ForegroundColor Gray
            }
        }
        Write-Host ""
    }
}

function Write-MenuHint {
    param([AllowEmptyString()][string]$Hint = "")

    if ([string]::IsNullOrWhiteSpace($Hint)) {
        return
    }

    $text = Format-WorkflowDisplayText -Text $Hint -MaxWidth (Get-MenuTabContentWidth)
    Write-FrameLine -Text $text -ForegroundColor DarkGray -Color
}

function Get-WorkflowTreeNodes {
    param([int]$MainChoice)

    switch ($MainChoice) {
        1 {
            return @(
                [pscustomobject]@{ Text = $Ui.ChatMenu1; Depth = 0; IsGroup = $false; Action = 'ChatCodex' }
                [pscustomobject]@{ Text = $Ui.ChatMenu2; Depth = 0; IsGroup = $false; Action = 'ChatSingle' }
            )
        }
        2 {
            return @(
                [pscustomobject]@{ Text = $Ui.BatchMenu1; Depth = 0; IsGroup = $false; Action = 'BatchPromptFile' }
                [pscustomobject]@{ Text = $Ui.BatchMenu2; Depth = 0; IsGroup = $false; Action = 'BatchPromptList' }
                [pscustomobject]@{ Text = $Ui.BatchMenu3; Depth = 0; IsGroup = $false; Action = 'BatchConversation' }
            )
        }
        3 {
            return @(
                [pscustomobject]@{ Text = $Ui.ImageMenu1; Depth = 0; IsGroup = $false; Action = 'ImageSingle' }
                [pscustomobject]@{ Text = $Ui.ImageMenu2; Depth = 0; IsGroup = $false; Action = 'ImageBatch' }
                [pscustomobject]@{ Text = $Ui.ImageMenu3; Depth = 0; IsGroup = $false; Action = 'ImageRetryFailed' }
                [pscustomobject]@{ Text = $Ui.ImageMenu4; Depth = 0; IsGroup = $false; Action = 'ImageCancel' }
            )
        }
        4 {
            return @(
                [pscustomobject]@{ Text = $Ui.TreeStatsAction; Depth = 0; IsGroup = $false; Action = 'Stats' }
            )
        }
        5 {
            return @(
                [pscustomobject]@{ Text = $Ui.ConfigMenu1; Depth = 0; IsGroup = $false; Action = 'ConfigSummary' }
                [pscustomobject]@{ Text = $Ui.ConfigMenu2; Depth = 0; IsGroup = $false; Action = 'ConfigLanguage' }
                [pscustomobject]@{ Text = $Ui.ConfigMenu3; Depth = 0; IsGroup = $true; GroupId = 'ConfigApi'; Action = '' }
                [pscustomobject]@{ Text = $Ui.ApiMenu1; Depth = 1; IsGroup = $true; GroupId = 'ConfigText'; Action = '' }
                [pscustomobject]@{ Text = $Ui.ApiDetailMenu1; Depth = 2; IsGroup = $false; Action = 'ConfigTextPrimary' }
                [pscustomobject]@{ Text = $Ui.ApiDetailMenu2; Depth = 2; IsGroup = $false; Action = 'ConfigTextFallback' }
                [pscustomobject]@{ Text = $Ui.ApiDetailMenu3; Depth = 2; IsGroup = $false; Action = 'ConfigTextTest' }
                [pscustomobject]@{ Text = $Ui.ApiMenu2; Depth = 1; IsGroup = $true; GroupId = 'ConfigImage'; Action = '' }
                [pscustomobject]@{ Text = $Ui.ApiDetailMenu1; Depth = 2; IsGroup = $false; Action = 'ConfigImagePrimary' }
                [pscustomobject]@{ Text = $Ui.ApiDetailMenu2; Depth = 2; IsGroup = $false; Action = 'ConfigImageFallback' }
                [pscustomobject]@{ Text = $Ui.ApiDetailMenu3; Depth = 2; IsGroup = $false; Action = 'ConfigImageTest' }
                [pscustomobject]@{ Text = $Ui.ConfigMenu4; Depth = 0; IsGroup = $false; Action = 'ConfigPaths' }
                [pscustomobject]@{ Text = $Ui.ConfigMenu5; Depth = 0; IsGroup = $false; Action = 'ConfigBatchDefaults' }
                [pscustomobject]@{ Text = $Ui.ConfigMenu6; Depth = 0; IsGroup = $true; GroupId = 'ConfigImageGeneration'; Action = '' }
                [pscustomobject]@{ Text = $Ui.ImageAspectRatio; Depth = 1; IsGroup = $false; Action = 'ConfigImageAspectRatio' }
                [pscustomobject]@{ Text = $Ui.ImageSize; Depth = 1; IsGroup = $false; Action = 'ConfigImageSize' }
                [pscustomobject]@{ Text = $Ui.ImageQuality; Depth = 1; IsGroup = $false; Action = 'ConfigImageQuality' }
                [pscustomobject]@{ Text = $Ui.ImageFormat; Depth = 1; IsGroup = $false; Action = 'ConfigImageFormat' }
                [pscustomobject]@{ Text = $Ui.ImageCompressionQuality; Depth = 1; IsGroup = $false; Action = 'ConfigImageCompression' }
                [pscustomobject]@{ Text = $Ui.ImageModeration; Depth = 1; IsGroup = $false; Action = 'ConfigImageModeration' }
            )
        }
        0 {
            return @(
                [pscustomobject]@{ Text = $Ui.TreeExitAction; Depth = 0; IsGroup = $false; Action = 'Exit' }
            )
        }
    }

    return @()
}

function Test-WorkflowTreeGroupExpanded {
    param([Parameter(Mandatory = $true)][string]$GroupId)

    if (-not $script:WorkflowTreeExpandedGroups.ContainsKey($GroupId)) {
        $script:WorkflowTreeExpandedGroups[$GroupId] = $true
    }
    return [bool]$script:WorkflowTreeExpandedGroups[$GroupId]
}

function Set-WorkflowTreeGroupExpanded {
    param(
        [Parameter(Mandatory = $true)][string]$GroupId,
        [bool]$Expanded
    )

    $script:WorkflowTreeExpandedGroups[$GroupId] = $Expanded
}

function Switch-WorkflowTreeGroup {
    param([Parameter(Mandatory = $true)][string]$GroupId)

    Set-WorkflowTreeGroupExpanded -GroupId $GroupId -Expanded (-not (Test-WorkflowTreeGroupExpanded -GroupId $GroupId))
}

function Get-WorkflowTreeVisibleNodes {
    param([int]$MainChoice)

    $allNodes = @(Get-WorkflowTreeNodes -MainChoice $MainChoice)
    $visible = New-Object System.Collections.Generic.List[object]
    $collapsedDepth = -1

    foreach ($node in $allNodes) {
        $depth = [int]$node.Depth
        if ($collapsedDepth -ge 0) {
            if ($depth -gt $collapsedDepth) {
                continue
            }
            $collapsedDepth = -1
        }

        [void]$visible.Add($node)
        if ([bool]$node.IsGroup -and -not (Test-WorkflowTreeGroupExpanded -GroupId ([string]$node.GroupId))) {
            $collapsedDepth = $depth
        }
    }

    return @($visible.ToArray())
}

function Get-WorkflowTreeSelectableIndexes {
    param([object[]]$Nodes)

    $indexes = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $Nodes.Count; $i++) {
        [void]$indexes.Add($i)
    }
    return @($indexes.ToArray())
}

function Get-WorkflowTreeSelectedNodeIndex {
    param(
        [int]$MainChoice,
        [object[]]$Nodes
    )

    $selectable = @(Get-WorkflowTreeSelectableIndexes -Nodes $Nodes)
    if ($selectable.Count -eq 0) {
        return 0
    }

    $key = [string]$MainChoice
    if (-not $script:WorkflowTreeSelections.ContainsKey($key) -or $script:WorkflowTreeSelections[$key] -notin $selectable) {
        $script:WorkflowTreeSelections[$key] = $selectable[0]
    }
    return [int]$script:WorkflowTreeSelections[$key]
}

function Move-WorkflowTreeCursor {
    param(
        [object[]]$Roots,
        [int]$RootIndex,
        [int]$Delta
    )

    $rootChoice = [int]$Roots[$RootIndex].Choice
    $nodes = @(Get-WorkflowTreeVisibleNodes -MainChoice $rootChoice)
    $selectable = @(Get-WorkflowTreeSelectableIndexes -Nodes $nodes)
    if ($selectable.Count -eq 0) {
        return $RootIndex
    }
    $selectedNode = Get-WorkflowTreeSelectedNodeIndex -MainChoice $rootChoice -Nodes $nodes
    $position = [Array]::IndexOf([int[]]$selectable, [int]$selectedNode)
    $newPosition = Move-WorkflowSelectionIndex -Current $position -Delta $Delta -Count $selectable.Count
    $script:WorkflowTreeSelections[[string]$rootChoice] = $selectable[$newPosition]
    return $RootIndex
}

function Get-WorkflowTreeVisibleRows {
    try {
        if (-not [Console]::IsOutputRedirected) {
            return [Math]::Max(5, [Console]::WindowHeight - 12)
        }
    }
    catch {
    }
    return 12
}

function Write-WorkflowTreeSectionTitle {
    param([string]$Title)

    $tee = [string][char]0x251C
    $horizontal = [string][char]0x2500
    Write-Host -NoNewline ($tee + $horizontal + " ") -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor Cyan
}

function Get-WorkflowTreeNodePath {
    param(
        [string]$RootText,
        [object[]]$Nodes,
        [int]$SelectedNode
    )

    $levels = @{}
    for ($i = 0; $i -le $SelectedNode; $i++) {
        $depth = [int]$Nodes[$i].Depth
        foreach ($key in @($levels.Keys)) {
            if ([int]$key -ge $depth) {
                $levels.Remove($key)
            }
        }
        $levels[$depth] = [string]$Nodes[$i].Text
    }

    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add($RootText)
    foreach ($depth in @($levels.Keys | Sort-Object)) {
        [void]$parts.Add([string]$levels[$depth])
    }
    return ($parts.ToArray() -join " > ")
}

function Get-WorkflowTreeParentGroupIndex {
    param(
        [object[]]$Nodes,
        [int]$SelectedNode
    )

    if ($SelectedNode -le 0) {
        return -1
    }

    $selectedDepth = [int]$Nodes[$SelectedNode].Depth
    for ($i = $SelectedNode - 1; $i -ge 0; $i--) {
        if ([bool]$Nodes[$i].IsGroup -and [int]$Nodes[$i].Depth -lt $selectedDepth) {
            return $i
        }
    }
    return -1
}

function Get-WorkflowTreeNodeDisplayText {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [int]$MaxWidth = 0
    )

    $indent = "  " * [int]$Node.Depth
    if ([bool]$Node.IsGroup) {
        $marker = if (Test-WorkflowTreeGroupExpanded -GroupId ([string]$Node.GroupId)) { [string][char]0x25BE } else { [string][char]0x25B8 }
        $marker += " "
    }
    else {
        $marker = ([string][char]0x2022) + " "
    }

    $prefix = $indent + $marker
    $label = [string]$Node.Text
    if ($MaxWidth -gt 0) {
        $labelWidth = [Math]::Max(1, $MaxWidth - (Get-WorkflowDisplayWidth -Text $prefix))
        $label = Format-WorkflowDisplayText -Text $label -MaxWidth $labelWidth
    }
    return ($prefix + $label)
}

function Get-WorkflowTreeRenderRows {
    param(
        [object[]]$Nodes,
        [int]$SelectedNode,
        [int]$MaxRows
    )

    $rows = New-Object System.Collections.Generic.List[object]
    if ($Nodes.Count -le $MaxRows) {
        for ($i = 0; $i -lt $Nodes.Count; $i++) {
            [void]$rows.Add([pscustomobject]@{ NodeIndex = $i; Node = $Nodes[$i]; Ellipsis = $false })
        }
        return @($rows.ToArray())
    }

    $visibleNodes = [Math]::Max(3, $MaxRows - 2)
    $start = [Math]::Max(0, [Math]::Min($Nodes.Count - $visibleNodes, $SelectedNode - [int][Math]::Floor($visibleNodes / 2)))
    $end = [Math]::Min($Nodes.Count, $start + $visibleNodes)
    if ($start -gt 0) {
        [void]$rows.Add([pscustomobject]@{ NodeIndex = -1; Node = $null; Ellipsis = $true })
    }
    for ($i = $start; $i -lt $end; $i++) {
        [void]$rows.Add([pscustomobject]@{ NodeIndex = $i; Node = $Nodes[$i]; Ellipsis = $false })
    }
    if ($end -lt $Nodes.Count) {
        [void]$rows.Add([pscustomobject]@{ NodeIndex = -1; Node = $null; Ellipsis = $true })
    }
    return @($rows.ToArray())
}

function Write-WorkflowTreeNavigation {
    param(
        [object[]]$Roots,
        [int]$RootIndex
    )

    $rootChoice = [int]$Roots[$RootIndex].Choice
    $nodes = @(Get-WorkflowTreeVisibleNodes -MainChoice $rootChoice)
    $selectedNode = Get-WorkflowTreeSelectedNodeIndex -MainChoice $rootChoice -Nodes $nodes
    $contentWidth = Get-MenuTabContentWidth
    $focus = [string]$script:WorkflowTreeFocus
    $renderRows = @(Get-WorkflowTreeRenderRows -Nodes $nodes -SelectedNode $selectedNode -MaxRows (Get-WorkflowTreeVisibleRows))
    $vertical = [string][char]0x2502
    $tee = [string][char]0x251C
    $cross = [string][char]0x253C
    $horizontal = [string][char]0x2500

    Write-Banner

    if ($contentWidth -ge 58) {
        $leftWidth = [Math]::Min(22, [Math]::Max(16, [int][Math]::Floor($contentWidth * 0.28)))
        $rightWidth = [Math]::Max(20, $contentWidth - $leftWidth - 3)
        $leftTitle = Pad-WorkflowDisplayRight -Text (Format-WorkflowDisplayText -Text (" " + $Ui.TreeRegionMain) -MaxWidth $leftWidth) -Width $leftWidth
        $rightTitleText = " " + [string]$Roots[$RootIndex].Text
        $rightTitle = Pad-WorkflowDisplayRight -Text (Format-WorkflowDisplayText -Text $rightTitleText -MaxWidth $rightWidth) -Width $rightWidth

        Write-Host -NoNewline ("{0} " -f $vertical) -ForegroundColor DarkGray
        if ($focus -eq 'Main') { Write-Host -NoNewline $leftTitle -ForegroundColor Black -BackgroundColor Cyan } else { Write-Host -NoNewline $leftTitle -ForegroundColor White -BackgroundColor DarkGray }
        Write-Host -NoNewline (" {0} " -f $vertical) -ForegroundColor DarkGray
        if ($focus -eq 'Submenu') { Write-Host $rightTitle -ForegroundColor Black -BackgroundColor Cyan } else { Write-Host $rightTitle -ForegroundColor White -BackgroundColor DarkGray }
        Write-Host ($tee + ($horizontal * ($leftWidth + 1)) + $cross + ($horizontal * ($rightWidth + 2))) -ForegroundColor DarkGray

        $rowCount = [Math]::Max($Roots.Count, $renderRows.Count)
        for ($rowIndex = 0; $rowIndex -lt $rowCount; $rowIndex++) {
            $leftText = if ($rowIndex -lt $Roots.Count) { Format-WorkflowDisplayText -Text ([string]$Roots[$rowIndex].Text) -MaxWidth ([Math]::Max(1, $leftWidth - 1)) } else { "" }
            $leftCell = Pad-WorkflowDisplayRight -Text (" " + $leftText) -Width $leftWidth
            Write-Host -NoNewline ("{0} " -f $vertical) -ForegroundColor DarkGray
            if ($rowIndex -eq $RootIndex) {
                if ($focus -eq 'Main') { Write-Host -NoNewline $leftCell -ForegroundColor Black -BackgroundColor Cyan } else { Write-Host -NoNewline $leftCell -ForegroundColor White -BackgroundColor DarkCyan }
            }
            else {
                Write-Host -NoNewline $leftCell -ForegroundColor Gray
            }
            Write-Host -NoNewline (" {0} " -f $vertical) -ForegroundColor DarkGray

            if ($rowIndex -ge $renderRows.Count) {
                Write-Host ""
                continue
            }
            $entry = $renderRows[$rowIndex]
            if ([bool]$entry.Ellipsis) {
                Write-Host "..." -ForegroundColor DarkGray
                continue
            }
            $nodeText = Get-WorkflowTreeNodeDisplayText -Node $entry.Node -MaxWidth $rightWidth
            $rightCell = Pad-WorkflowDisplayRight -Text $nodeText -Width $rightWidth
            if ([int]$entry.NodeIndex -eq $selectedNode) {
                if ($focus -eq 'Submenu') { Write-Host $rightCell -ForegroundColor Black -BackgroundColor Cyan } else { Write-Host $rightCell -ForegroundColor White -BackgroundColor DarkCyan }
            }
            elseif ([bool]$entry.Node.IsGroup) {
                Write-Host $nodeText -ForegroundColor DarkCyan
            }
            else {
                Write-Host $nodeText -ForegroundColor Gray
            }
        }
        Write-Host ($tee + ($horizontal * ($leftWidth + 1)) + $cross + ($horizontal * ($rightWidth + 2))) -ForegroundColor DarkGray
    }
    else {
        Write-WorkflowTreeSectionTitle -Title $Ui.TreeRegionMain
        for ($i = 0; $i -lt $Roots.Count; $i++) {
            $text = Pad-WorkflowDisplayRight -Text (Format-WorkflowDisplayText -Text ([string]$Roots[$i].Text) -MaxWidth $contentWidth) -Width $contentWidth
            Write-Host -NoNewline ("{0} " -f $vertical) -ForegroundColor DarkGray
            if ($i -eq $RootIndex) {
                if ($focus -eq 'Main') { Write-Host $text -ForegroundColor Black -BackgroundColor Cyan } else { Write-Host $text -ForegroundColor White -BackgroundColor DarkCyan }
            }
            else { Write-Host $text -ForegroundColor Gray }
        }
        Write-WorkflowTreeSectionTitle -Title ([string]$Roots[$RootIndex].Text)
        foreach ($entry in $renderRows) {
            if ([bool]$entry.Ellipsis) { Write-FrameLine -Text "..." -ForegroundColor DarkGray -Color; continue }
            $text = Get-WorkflowTreeNodeDisplayText -Node $entry.Node -MaxWidth $contentWidth
            Write-Host -NoNewline ("{0} " -f $vertical) -ForegroundColor DarkGray
            if ([int]$entry.NodeIndex -eq $selectedNode) {
                $cell = Pad-WorkflowDisplayRight -Text $text -Width $contentWidth
                if ($focus -eq 'Submenu') { Write-Host $cell -ForegroundColor Black -BackgroundColor Cyan } else { Write-Host $cell -ForegroundColor White -BackgroundColor DarkCyan }
            }
            elseif ([bool]$entry.Node.IsGroup) { Write-Host $text -ForegroundColor DarkCyan }
            else { Write-Host $text -ForegroundColor Gray }
        }
    }

    Write-WorkflowTreeSectionTitle -Title $Ui.TreeRegionCurrent
    $path = Get-WorkflowTreeNodePath -RootText ([string]$Roots[$RootIndex].Text) -Nodes $nodes -SelectedNode $selectedNode
    Write-FrameLine -Text (Format-WorkflowDisplayText -Text $path -MaxWidth $contentWidth) -ForegroundColor White -Color
    Write-FrameLine
    Write-MenuHint -Hint $Ui.TreeHint
}

function Read-WorkflowTreeNavigationChoice {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        $choice = Read-MenuChoice -Items (Get-MenuItems) -Hint $Ui.MenuHint
        return [pscustomobject]@{
            Action = switch ($choice) {
                1 { 'LegacyChatMenu' }
                2 { 'LegacyBatchMenu' }
                3 { 'LegacyImageMenu' }
                4 { 'Stats' }
                5 { 'LegacyConfigMenu' }
                default { 'Exit' }
            }
        }
    }

    try {
        [Console]::CursorVisible = $false
    }
    catch {
    }

    try {
        while ($true) {
            $roots = @(Get-MenuItems)
            $script:WorkflowTreeRootIndex = [Math]::Max(0, [Math]::Min($roots.Count - 1, $script:WorkflowTreeRootIndex))
            Write-WorkflowTreeNavigation -Roots $roots -RootIndex $script:WorkflowTreeRootIndex
            $key = [Console]::ReadKey($true)

            if (Test-ControlCKey -KeyInfo $key) {
                return [pscustomobject]@{ Action = 'Exit' }
            }
            if ($key.Key -eq [ConsoleKey]::Escape) {
                if ($script:WorkflowTreeFocus -eq 'Submenu') {
                    $script:WorkflowTreeFocus = 'Main'
                    continue
                }
                return [pscustomobject]@{ Action = 'Exit' }
            }
            if (Test-ControlZKey -KeyInfo $key) {
                $script:WorkflowTreeFocus = 'Main'
                continue
            }

            switch ($key.Key) {
                'LeftArrow' {
                    if ($script:WorkflowTreeFocus -eq 'Main') {
                        continue
                    }

                    $choice = [int]$roots[$script:WorkflowTreeRootIndex].Choice
                    $nodes = @(Get-WorkflowTreeVisibleNodes -MainChoice $choice)
                    $selectedNode = Get-WorkflowTreeSelectedNodeIndex -MainChoice $choice -Nodes $nodes
                    $node = $nodes[$selectedNode]
                    if ([bool]$node.IsGroup -and (Test-WorkflowTreeGroupExpanded -GroupId ([string]$node.GroupId))) {
                        Set-WorkflowTreeGroupExpanded -GroupId ([string]$node.GroupId) -Expanded $false
                        $script:WorkflowTreeSelections[[string]$choice] = $selectedNode
                        continue
                    }

                    $parentGroup = Get-WorkflowTreeParentGroupIndex -Nodes $nodes -SelectedNode $selectedNode
                    if ($parentGroup -ge 0) {
                        $script:WorkflowTreeSelections[[string]$choice] = $parentGroup
                    }
                    else {
                        $script:WorkflowTreeFocus = 'Main'
                    }
                    continue
                }
                'RightArrow' {
                    if ($script:WorkflowTreeFocus -eq 'Main') {
                        $script:WorkflowTreeFocus = 'Submenu'
                        continue
                    }

                    $choice = [int]$roots[$script:WorkflowTreeRootIndex].Choice
                    $nodes = @(Get-WorkflowTreeVisibleNodes -MainChoice $choice)
                    $selectedNode = Get-WorkflowTreeSelectedNodeIndex -MainChoice $choice -Nodes $nodes
                    $node = $nodes[$selectedNode]
                    if ([bool]$node.IsGroup) {
                        Set-WorkflowTreeGroupExpanded -GroupId ([string]$node.GroupId) -Expanded $true
                    }
                    continue
                }
                'Tab' {
                    $script:WorkflowTreeFocus = if ($script:WorkflowTreeFocus -eq 'Main') { 'Submenu' } else { 'Main' }
                    continue
                }
                'UpArrow' {
                    if ($script:WorkflowTreeFocus -eq 'Main') {
                        $script:WorkflowTreeRootIndex = Move-WorkflowSelectionIndex -Current $script:WorkflowTreeRootIndex -Delta -1 -Count $roots.Count
                    }
                    else {
                        $script:WorkflowTreeRootIndex = Move-WorkflowTreeCursor -Roots $roots -RootIndex $script:WorkflowTreeRootIndex -Delta -1
                    }
                    continue
                }
                'DownArrow' {
                    if ($script:WorkflowTreeFocus -eq 'Main') {
                        $script:WorkflowTreeRootIndex = Move-WorkflowSelectionIndex -Current $script:WorkflowTreeRootIndex -Delta 1 -Count $roots.Count
                    }
                    else {
                        $script:WorkflowTreeRootIndex = Move-WorkflowTreeCursor -Roots $roots -RootIndex $script:WorkflowTreeRootIndex -Delta 1
                    }
                    continue
                }
                'Home' {
                    if ($script:WorkflowTreeFocus -eq 'Main') {
                        $script:WorkflowTreeRootIndex = 0
                    }
                    else {
                        $choice = [int]$roots[$script:WorkflowTreeRootIndex].Choice
                        $nodes = @(Get-WorkflowTreeVisibleNodes -MainChoice $choice)
                        $selectable = @(Get-WorkflowTreeSelectableIndexes -Nodes $nodes)
                        if ($selectable.Count -gt 0) { $script:WorkflowTreeSelections[[string]$choice] = $selectable[0] }
                    }
                    continue
                }
                'End' {
                    if ($script:WorkflowTreeFocus -eq 'Main') {
                        $script:WorkflowTreeRootIndex = $roots.Count - 1
                    }
                    else {
                        $choice = [int]$roots[$script:WorkflowTreeRootIndex].Choice
                        $nodes = @(Get-WorkflowTreeVisibleNodes -MainChoice $choice)
                        $selectable = @(Get-WorkflowTreeSelectableIndexes -Nodes $nodes)
                        if ($selectable.Count -gt 0) { $script:WorkflowTreeSelections[[string]$choice] = $selectable[-1] }
                    }
                    continue
                }
                'Enter' {
                    $choice = [int]$roots[$script:WorkflowTreeRootIndex].Choice
                    $nodes = @(Get-WorkflowTreeVisibleNodes -MainChoice $choice)
                    $selectedNode = Get-WorkflowTreeSelectedNodeIndex -MainChoice $choice -Nodes $nodes
                    $selectable = @(Get-WorkflowTreeSelectableIndexes -Nodes $nodes)
                    if ($script:WorkflowTreeFocus -eq 'Main' -and $selectable.Count -gt 1) {
                        $script:WorkflowTreeFocus = 'Submenu'
                        continue
                    }

                    $node = $nodes[$selectedNode]
                    if ([bool]$node.IsGroup) {
                        Switch-WorkflowTreeGroup -GroupId ([string]$node.GroupId)
                        $script:WorkflowTreeSelections[[string]$choice] = $selectedNode
                        continue
                    }

                    $action = [string]$node.Action
                    if ([string]::IsNullOrWhiteSpace($action)) {
                        continue
                    }
                    return [pscustomobject]@{ Action = $action }
                }
            }
        }
    }
    finally {
        try {
            [Console]::CursorVisible = $true
        }
        catch {
        }
    }
}

function Read-MenuChoiceFallback {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,
        [AllowEmptyString()]
        [string]$Title = "",
        [object[]]$DetailLines = @(),
        [AllowEmptyString()]
        [string]$Hint = $Ui.MenuHint
    )

    while ($true) {
        Write-Banner
        if (-not [string]::IsNullOrWhiteSpace($Title)) {
            Write-FrameLine -Text $Title -ForegroundColor Cyan -Color
            Write-FrameLine
        }

        foreach ($line in @($DetailLines)) {
            Write-FrameLine -Text ([string]$line)
        }
        if (@($DetailLines).Count -gt 0) {
            Write-FrameLine
        }

        foreach ($item in $Items) {
            Write-FrameLine -Text ((Get-MenuTabText -Item $item).Trim())
        }
        Write-FrameLine
        if (-not [string]::IsNullOrWhiteSpace($Hint)) {
            Write-MenuHint -Hint $Hint
            Write-FrameLine
        }

        $choice = Read-InteractiveLine -PromptText $Ui.SelectAction
        $parsedChoice = 0
        if ([int]::TryParse($choice, [ref]$parsedChoice) -and (Test-MenuChoice -Items $Items -Choice $parsedChoice)) {
            return $parsedChoice
        }

        Write-FrameLine -Text $Ui.InvalidChoice -ForegroundColor Yellow -Color
        Write-FrameLine
    }
}

function Read-MenuChoice {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,
        [AllowEmptyString()]
        [string]$Title = "",
        [object[]]$DetailLines = @(),
        [AllowEmptyString()]
        [string]$Hint = $Ui.MenuHint,
        [switch]$ControlZReturns
    )

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        return (Read-MenuChoiceFallback -Items $Items -Title $Title -DetailLines $DetailLines -Hint $Hint)
    }

    try {
        [Console]::CursorVisible = $false
    }
    catch {
    }

    $items = @($Items)
    $selected = 0
    $digitBuffer = ""
    try {
    while ($true) {
        Write-Banner
        if (-not [string]::IsNullOrWhiteSpace($Title)) {
            Write-FrameLine -Text $Title -ForegroundColor Cyan -Color
            Write-FrameLine
        }

        Write-MenuTabs -Items $items -SelectedIndex $selected
        Write-FrameLine
        foreach ($line in @($DetailLines)) {
            Write-FrameLine -Text ([string]$line)
        }
        if (@($DetailLines).Count -gt 0) {
            Write-FrameLine
        }
        if (-not [string]::IsNullOrWhiteSpace($Hint)) {
            Write-MenuHint -Hint $Hint
        }

        try {
            $key = [Console]::ReadKey($true)
        }
        catch {
            return (Read-MenuChoiceFallback -Items $items -Title $Title -DetailLines $DetailLines -Hint $Hint)
        }

        if (Test-ControlCKey -KeyInfo $key) {
            throw $WorkflowBackSignal
        }

        switch ($key.Key) {
            "UpArrow" { $digitBuffer = ""; $selected = Move-WorkflowSelectionIndex -Current $selected -Delta -1 -Count $items.Count; continue }
            "LeftArrow" { $digitBuffer = ""; $selected = Move-WorkflowSelectionIndex -Current $selected -Delta -1 -Count $items.Count; continue }
            "DownArrow" { $digitBuffer = ""; $selected = Move-WorkflowSelectionIndex -Current $selected -Delta 1 -Count $items.Count; continue }
            "RightArrow" { $digitBuffer = ""; $selected = Move-WorkflowSelectionIndex -Current $selected -Delta 1 -Count $items.Count; continue }
            "Tab" {
                $digitBuffer = ""
                $delta = if (($key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0) { -1 } else { 1 }
                $selected = Move-WorkflowSelectionIndex -Current $selected -Delta $delta -Count $items.Count
                continue
            }
            "Home" { $digitBuffer = ""; $selected = 0; continue }
            "End" { $digitBuffer = ""; $selected = $items.Count - 1; continue }
            "Enter" {
                if (-not [string]::IsNullOrWhiteSpace($digitBuffer)) {
                    $bufferChoice = 0
                    if ([int]::TryParse($digitBuffer, [ref]$bufferChoice) -and (Test-MenuChoice -Items $items -Choice $bufferChoice)) {
                        return $bufferChoice
                    }
                }

                return [int]$items[$selected].Choice
            }
            "Escape" { return 0 }
        }

        if (Test-ControlZKey -KeyInfo $key) {
            if ($ControlZReturns) {
                return 0
            }
            continue
        }

        if ($key.KeyChar -match '^[0-9]$') {
            $digitBuffer += [string]$key.KeyChar
            $digitChoice = 0
            if (-not [int]::TryParse($digitBuffer, [ref]$digitChoice)) {
                $digitBuffer = ""
                continue
            }

            if (Test-MenuChoice -Items $items -Choice $digitChoice) {
                if (-not (Test-MenuChoicePrefix -Items $items -Prefix $digitBuffer)) {
                    return $digitChoice
                }

                try {
                    $deadline = (Get-Date).AddMilliseconds(650)
                    while ((Get-Date) -lt $deadline -and -not [Console]::KeyAvailable) {
                        Start-Sleep -Milliseconds 25
                    }

                    if (-not [Console]::KeyAvailable) {
                        return $digitChoice
                    }
                }
                catch {
                    return $digitChoice
                }
            }

            if (-not (Test-MenuChoicePrefix -Items $items -Prefix $digitBuffer)) {
                $digitBuffer = ""
            }
        }
        else {
            $digitBuffer = ""
        }
    }
    }
    finally {
        try {
            [Console]::CursorVisible = $true
        }
        catch {
        }
    }
}

function Read-TextValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PromptLabel,
        [string]$DefaultValue,
        [switch]$Required
    )

    while ($true) {
        $fullPrompt = if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
            $PromptLabel
        }
        else {
            "{0} [{1}]" -f $PromptLabel, $DefaultValue
        }

        $value = Read-InteractiveLine -PromptText $fullPrompt
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $DefaultValue
        }

        if (-not $Required -or -not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }

        Write-Host $Ui.Required -ForegroundColor Yellow
    }
}

function Read-ConfigTextValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PromptLabel,
        [AllowEmptyString()]
        [string]$CurrentValue = "",
        [AllowEmptyString()]
        [string]$DisplayValue = "",
        [switch]$MaskCurrent
    )

    $displayValue = if (-not [string]::IsNullOrWhiteSpace($DisplayValue)) {
        $DisplayValue
    }
    elseif ($MaskCurrent) {
        Get-MaskedSecret -Value $CurrentValue
    }
    elseif ([string]::IsNullOrWhiteSpace($CurrentValue)) {
        $Ui.ConfigNotSet
    }
    else {
        $CurrentValue
    }
    Write-Host $Ui.ConfigKeepBlank -ForegroundColor DarkGray
    $raw = Read-InteractiveLine -PromptText ("{0} [{1}]" -f $PromptLabel, $displayValue)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $CurrentValue
    }

    if ($raw.Trim().Equals("CLEAR", [System.StringComparison]::OrdinalIgnoreCase)) {
        return ""
    }

    return $raw.Trim()
}

function Read-ExistingPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PromptLabel,
        [string]$DefaultValue
    )

    while ($true) {
        $pathValue = Read-TextValue -PromptLabel $PromptLabel -DefaultValue $DefaultValue -Required
        try {
            return Resolve-UserPath -Path $pathValue -MustExist
        }
        catch {
            Write-Host ($Ui.PathNotFound -f $pathValue) -ForegroundColor Yellow
        }
    }
}

function Read-IntValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PromptLabel,
        [Parameter(Mandatory = $true)]
        [int]$DefaultValue,
        [int]$Min = 1,
        [int]$Max = [int]::MaxValue
    )

    while ($true) {
        $raw = Read-InteractiveLine -PromptText ("{0} [{1}]" -f $PromptLabel, $DefaultValue)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $DefaultValue
        }

        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge $Min -and $parsed -le $Max) {
            return $parsed
        }

        Write-Host ($Ui.EnterInteger -f $Min, $Max) -ForegroundColor Yellow
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PromptLabel,
        [bool]$DefaultValue = $true
    )

    $defaultText = if ($DefaultValue) { $Ui.YesNoDefaultTrue } else { $Ui.YesNoDefaultFalse }
    $yesTokens = @($Ui.YesTokens -split "," | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    $noTokens = @($Ui.NoTokens -split "," | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })

    while ($true) {
        $raw = Read-InteractiveLine -PromptText ("{0} [{1}]" -f $PromptLabel, $defaultText)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $DefaultValue
        }

        $normalized = $raw.Trim().ToLowerInvariant()
        if ($yesTokens -contains $normalized) {
            return $true
        }

        if ($noTokens -contains $normalized) {
            return $false
        }

        Write-Host $Ui.EnterYesNo -ForegroundColor Yellow
    }
}

function Read-MultilinePrompt {
    Write-Host ""
    Write-Host $Ui.PromptIntro -ForegroundColor DarkGray
    $lines = New-Object System.Collections.Generic.List[string]

    while ($true) {
        $line = Read-InteractiveLine
        $trimmedLine = $line.Trim()
        if ($trimmedLine.Equals("END", [System.StringComparison]::OrdinalIgnoreCase) -or $trimmedLine.Equals($Ui.EndToken, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        [void]$lines.Add($line)
    }

    $text = (($lines.ToArray()) -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw $Ui.PromptEmpty
    }

    return $text
}

function Format-WorkflowUiText {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [int]$MaxWidth = 72
    )

    if ($MaxWidth -le 0) {
        return ""
    }

    $line = if ($null -eq $Text) { "" } else { ([string]$Text -replace "\s+", " ").Trim() }
    if ($line.Length -le $MaxWidth) {
        return $line
    }

    if ($MaxWidth -le 3) {
        return $line.Substring(0, $MaxWidth)
    }

    return $line.Substring(0, $MaxWidth - 3) + "..."
}

function Get-WorkflowDisplayWidth {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return 0
    }

    $width = 0
    foreach ($character in $Text.ToCharArray()) {
        $code = [int][char]$character
        if ([char]::IsControl($character)) {
            continue
        }

        if (
            ($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE10 -and $code -le 0xFE19) -or
            ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)
        ) {
            $width += 2
        }
        else {
            $width += 1
        }
    }

    return $width
}

function Format-WorkflowDisplayText {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [int]$MaxWidth
    )

    if ($MaxWidth -le 0) {
        return ""
    }

    $line = if ($null -eq $Text) { "" } else { ([string]$Text -replace "\s+", " ").Trim() }
    if ((Get-WorkflowDisplayWidth -Text $line) -le $MaxWidth) {
        return $line
    }

    if ($MaxWidth -le 3) {
        $builder = New-Object System.Text.StringBuilder
        $usedWidth = 0
        foreach ($character in $line.ToCharArray()) {
            $charWidth = Get-WorkflowDisplayWidth -Text ([string]$character)
            if (($usedWidth + $charWidth) -gt $MaxWidth) {
                break
            }

            [void]$builder.Append($character)
            $usedWidth += $charWidth
        }

        return $builder.ToString()
    }

    $targetWidth = $MaxWidth - 3
    $result = New-Object System.Text.StringBuilder
    $currentWidth = 0
    foreach ($character in $line.ToCharArray()) {
        $charWidth = Get-WorkflowDisplayWidth -Text ([string]$character)
        if (($currentWidth + $charWidth) -gt $targetWidth) {
            break
        }

        [void]$result.Append($character)
        $currentWidth += $charWidth
    }

    return $result.ToString() + "..."
}

function Pad-WorkflowDisplayRight {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [int]$Width
    )

    $value = if ($null -eq $Text) { "" } else { [string]$Text }
    $padding = [Math]::Max(0, $Width - (Get-WorkflowDisplayWidth -Text $value))
    return $value + (" " * $padding)
}

function New-CodexRoundedBorder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,
        [Parameter(Mandatory = $true)]
        [string]$Right,
        [int]$Width,
        [AllowEmptyString()]
        [string]$Label = ""
    )

    $innerWidth = [Math]::Max(1, $Width - 2)
    $labelText = if ([string]::IsNullOrWhiteSpace($Label)) { "" } else { " {0} " -f $Label }
    $labelWidth = Get-WorkflowDisplayWidth -Text $labelText
    if ($labelWidth -ge $innerWidth) {
        return $Left + ($script:CodexBoxHorizontal * $innerWidth) + $Right
    }

    $leftRule = if ([string]::IsNullOrEmpty($labelText)) { "" } else { $script:CodexBoxHorizontal }
    $rightRuleWidth = [Math]::Max(0, $innerWidth - (Get-WorkflowDisplayWidth -Text ($leftRule + $labelText)))
    return $Left + $leftRule + $labelText + ($script:CodexBoxHorizontal * $rightRuleWidth) + $Right
}

function Get-WorkflowInputBoxWidth {
    try {
        if (-not [Console]::IsOutputRedirected) {
            return [Math]::Max(50, [Math]::Min(96, [Console]::WindowWidth - 1))
        }
    }
    catch {
    }

    return 78
}

function Write-CodexPromptBox {
    $boxWidth = Get-WorkflowInputBoxWidth
    $innerWidth = [Math]::Max(10, $boxWidth - 4)
    $borderLabelWidth = [Math]::Max(10, $boxWidth - 8)
    $title = Format-WorkflowDisplayText -Text $Ui.ComposerTitle -MaxWidth $borderLabelWidth
    $hint = Format-WorkflowDisplayText -Text $Ui.ComposerHint -MaxWidth $borderLabelWidth
    $topBorder = New-CodexRoundedBorder -Left $script:CodexBoxTopLeft -Right $script:CodexBoxTopRight -Width $boxWidth -Label $title
    $bottomBorder = New-CodexRoundedBorder -Left $script:CodexBoxBottomLeft -Right $script:CodexBoxBottomRight -Width $boxWidth -Label $hint

    Write-Host ""
    Write-Host $topBorder -ForegroundColor DarkCyan
    Write-Host ("{0} {1} {0}" -f $script:CodexBoxVertical, (Pad-WorkflowDisplayRight -Text "" -Width $innerWidth)) -ForegroundColor White
    Write-Host $bottomBorder -ForegroundColor DarkCyan
}

function Add-CodexComposerText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lines,
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return
    }

    $normalized = $Text -replace "`r`n", "`n"
    $normalized = $normalized -replace "`r", "`n"
    $parts = [System.Text.RegularExpressions.Regex]::Split($normalized, "`n")
    if ($parts.Count -eq 0) {
        return
    }

    $lastIndex = $Lines.Count - 1
    $Lines[$lastIndex] = $Lines[$lastIndex] + $parts[0]

    for ($i = 1; $i -lt $parts.Count; $i++) {
        [void]$Lines.Add($parts[$i])
    }
}

function Get-CodexComposerText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lines
    )

    return (($Lines.ToArray()) -join [Environment]::NewLine)
}

function Remove-CodexComposerCharacter {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lines
    )

    $lastIndex = $Lines.Count - 1
    $current = $Lines[$lastIndex]
    if ($current.Length -gt 0) {
        $Lines[$lastIndex] = $current.Substring(0, $current.Length - 1)
        return
    }

    if ($Lines.Count -gt 1) {
        $Lines.RemoveAt($lastIndex)
    }
}

function Test-CodexComposerNewLineKey {
    param(
        [Parameter(Mandatory = $true)]
        [ConsoleKeyInfo]$KeyInfo
    )

    $hasShift = (($KeyInfo.Modifiers -band [ConsoleModifiers]::Shift) -ne 0)
    $hasControl = (($KeyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0)
    $isModifiedEnter = ($KeyInfo.Key -eq [ConsoleKey]::Enter -and ($hasShift -or $hasControl))
    $isControlJ = (
        ($KeyInfo.Key -eq [ConsoleKey]::J -and $hasControl) -or
        ([int][char]$KeyInfo.KeyChar -eq 10)
    )

    return ($isModifiedEnter -or $isControlJ)
}

function Get-CodexComposerRows {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lines,
        [int]$InnerWidth
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $promptPrefix = "{0} > " -f $Ui.ComposerPrompt
    if ($promptPrefix.Length -ge $InnerWidth) {
        $promptPrefix = "> "
    }

    $continuationPrefix = " " * $promptPrefix.Length

    for ($lineIndex = 0; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $lineText = $Lines[$lineIndex]
        $offset = 0
        $segmentIndex = 0

        do {
            $prefix = if ($segmentIndex -eq 0) { $promptPrefix } else { $continuationPrefix }
            $available = [Math]::Max(1, $InnerWidth - $prefix.Length)
            $remaining = $lineText.Length - $offset
            $take = if ($remaining -gt 0) { [Math]::Min($available, $remaining) } else { 0 }
            $segment = if ($take -gt 0) { $lineText.Substring($offset, $take) } else { "" }
            $rowText = $prefix + $segment

            [void]$rows.Add([pscustomobject]@{
                Text = $rowText
                IsCursorRow = ($lineIndex -eq ($Lines.Count - 1) -and ($offset + $take) -ge $lineText.Length)
            })

            $offset += $take
            $segmentIndex++
        } while ($offset -lt $lineText.Length)
    }

    return $rows
}

function Move-CodexComposerCursorAfterBox {
    try {
        if ($script:WorkflowComposerBottom -ge 0) {
            $targetTop = [Math]::Min([Console]::WindowHeight - 1, $script:WorkflowComposerBottom + 1)
            [Console]::SetCursorPosition(0, $targetTop)
            Write-Host ""
            return
        }
    }
    catch {
    }

    Write-Host ""
}

function Write-CodexComposerScreen {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Lines,
        [AllowEmptyString()]
        [string]$Notice = ""
    )

    $boxWidth = Get-WorkflowInputBoxWidth
    $innerWidth = [Math]::Max(10, $boxWidth - 4)
    $borderLabelWidth = [Math]::Max(10, $boxWidth - 8)
    $title = Format-WorkflowDisplayText -Text $Ui.ComposerTitle -MaxWidth $borderLabelWidth
    $hint = Format-WorkflowDisplayText -Text $Ui.ComposerHint -MaxWidth $borderLabelWidth
    $topBorder = New-CodexRoundedBorder -Left $script:CodexBoxTopLeft -Right $script:CodexBoxTopRight -Width $boxWidth -Label $title
    $bottomBorder = New-CodexRoundedBorder -Left $script:CodexBoxBottomLeft -Right $script:CodexBoxBottomRight -Width $boxWidth -Label $hint
    $rows = @(Get-CodexComposerRows -Lines $Lines -InnerWidth $innerWidth)

    $maxInputRows = 6
    try {
        $maxInputRows = [Math]::Max(3, [Math]::Min(8, [Console]::WindowHeight - 8))
    }
    catch {
    }

    $startIndex = [Math]::Max(0, $rows.Count - $maxInputRows)
    $visibleRows = @($rows[$startIndex..($rows.Count - 1)])
    $inputRows = New-Object System.Collections.Generic.List[object]
    foreach ($row in $visibleRows) {
        [void]$inputRows.Add($row)
    }

    while ($inputRows.Count -lt 3) {
        [void]$inputRows.Add([pscustomobject]@{ Text = ""; IsCursorRow = $false })
    }

    $noticeRowCount = if ([string]::IsNullOrWhiteSpace($Notice)) { 0 } else { 1 }
    $boxHeight = 2 + $inputRows.Count + $noticeRowCount
    $boxTop = 0

    try {
        Clear-Host
        $boxTop = [Math]::Max(0, [Console]::WindowHeight - $boxHeight - 1)
        [Console]::SetCursorPosition(0, $boxTop)
    }
    catch {
        Write-Host ""
    }

    Write-Host $topBorder -ForegroundColor Cyan

    $cursorTop = $boxTop + 1
    $cursorLeft = 2
    for ($i = 0; $i -lt $inputRows.Count; $i++) {
        $rowText = [string]$inputRows[$i].Text
        if ($rowText.Length -gt $innerWidth) {
            $rowText = $rowText.Substring(0, $innerWidth)
        }

        if ($inputRows[$i].IsCursorRow) {
            $cursorTop = $boxTop + 1 + $i
            $cursorLeft = [Math]::Min($boxWidth - 3, 2 + (Get-WorkflowDisplayWidth -Text $rowText))
        }

        $rowColor = if ($inputRows[$i].IsCursorRow) { 'Yellow' } elseif (($i % 2) -eq 0) { 'White' } else { 'Gray' }
        Write-Host ("{0} {1} {0}" -f $script:CodexBoxVertical, (Pad-WorkflowDisplayRight -Text $rowText -Width $innerWidth)) -ForegroundColor $rowColor
    }

    if ($noticeRowCount -gt 0) {
        $noticeText = Format-WorkflowUiText -Text $Notice -MaxWidth $innerWidth
        Write-Host ("{0} {1} {0}" -f $script:CodexBoxVertical, (Pad-WorkflowDisplayRight -Text $noticeText -Width $innerWidth)) -ForegroundColor Magenta
    }

    Write-Host $bottomBorder -ForegroundColor DarkGreen
    $script:WorkflowComposerBottom = $boxTop + $boxHeight - 1

    try {
        [Console]::SetCursorPosition($cursorLeft, $cursorTop)
    }
    catch {
    }
}

function Read-CodexPromptBox {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        return (Read-MultilinePrompt)
    }

    try {
        [Console]::CursorVisible = $true
    }
    catch {
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("")
    $notice = ""
    Write-CodexComposerScreen -Lines $lines -Notice $notice

    while ($true) {
        try {
            $key = [Console]::ReadKey($true)
        }
        catch {
            return (Read-MultilinePrompt)
        }

        if (Test-ControlCKey -KeyInfo $key) {
            Move-CodexComposerCursorAfterBox
            throw $WorkflowBackSignal
        }

        if ($key.Key -eq [ConsoleKey]::Escape) {
            Move-CodexComposerCursorAfterBox
            throw $WorkflowExitSignal
        }

        if (Test-ControlZKey -KeyInfo $key) {
            Move-CodexComposerCursorAfterBox
            throw $WorkflowBackSignal
        }

        if (Test-CodexComposerNewLineKey -KeyInfo $key) {
            [void]$lines.Add("")
            $notice = ""
            Write-CodexComposerScreen -Lines $lines -Notice $notice
            continue
        }

        if ($key.Key -eq [ConsoleKey]::Enter) {
            $text = (Get-CodexComposerText -Lines $lines).Trim()
            if ([string]::IsNullOrWhiteSpace($text)) {
                $notice = $Ui.ComposerEmpty
                Write-CodexComposerScreen -Lines $lines -Notice $notice
                continue
            }

            Move-CodexComposerCursorAfterBox
            return $text
        }

        if ($key.Key -eq [ConsoleKey]::Backspace) {
            Remove-CodexComposerCharacter -Lines $lines
            $notice = ""
            Write-CodexComposerScreen -Lines $lines -Notice $notice
            continue
        }

        if ($key.Key -eq [ConsoleKey]::V -and (($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) {
            try {
                Add-CodexComposerText -Lines $lines -Text (Get-Clipboard -Raw)
            }
            catch {
            }

            $notice = ""
            Write-CodexComposerScreen -Lines $lines -Notice $notice
            continue
        }

        if (-not [char]::IsControl($key.KeyChar)) {
            Add-CodexComposerText -Lines $lines -Text ([string]$key.KeyChar)
            $notice = ""
            Write-CodexComposerScreen -Lines $lines -Notice $notice
        }
    }
}

function Pause-ForUser {
    Write-Host ""
    [void](Read-InteractiveLine -PromptText $Ui.PressEnter)
}

function ConvertTo-WorkflowScriptArgument {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Stop-WorkflowChildProcessTree {
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
            Stop-WorkflowChildProcessTree -ProcessId ([int]$child.ProcessId)
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

function New-WorkflowScriptArgumentList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)) {
        [void]$arguments.Add([string]$argument)
    }

    foreach ($key in ($Parameters.Keys | Sort-Object)) {
        $value = $Parameters[$key]
        if ($null -eq $value) {
            continue
        }

        if ($value -is [string] -and [string]::IsNullOrEmpty([string]$value)) {
            continue
        }

        if ($value -is [switch] -or $value -is [bool]) {
            if ([bool]$value) {
                [void]$arguments.Add("-$key")
            }
            continue
        }

        [void]$arguments.Add("-$key")
        if ($value -is [System.Array]) {
            foreach ($item in $value) {
                [void]$arguments.Add([string]$item)
            }
        }
        else {
            [void]$arguments.Add([string]$value)
        }
    }

    return @($arguments.ToArray())
}

function Invoke-WorkflowScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters,
        [switch]$NoWait
    )

    Clear-WorkflowProgressArea -Anchor Top
    Clear-WorkflowProgressArea -Anchor Bottom
    Clear-Host

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.WorkingDirectory = $scriptRoot
    $startInfo.UseShellExecute = $false
    $startInfo.Arguments = ((New-WorkflowScriptArgumentList -ScriptPath $ScriptPath -Parameters $Parameters | ForEach-Object {
        ConvertTo-WorkflowScriptArgument -Value ([string]$_)
    }) -join ' ')

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        if ($NoWait) {
            $global:LASTEXITCODE = 0
            return [pscustomobject]@{ ProcessId = $process.Id; ExitCode = 0; Background = $true }
        }
        while (-not $process.HasExited) {
            try {
                if ((-not [Console]::IsInputRedirected) -and [Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if (Test-ControlCKey -KeyInfo $key) {
                        Stop-WorkflowChildProcessTree -ProcessId $process.Id
                        throw $WorkflowBackSignal
                    }
                }
            }
            catch {
                if ($_.Exception.Message -eq $WorkflowBackSignal) {
                    throw
                }
            }

            Start-Sleep -Milliseconds 50
        }

        $global:LASTEXITCODE = [int]$process.ExitCode
        if ($process.ExitCode -ne 0) {
            Write-Host ($Ui.WorkflowExitCode -f $process.ExitCode) -ForegroundColor Red
        }
    }
    finally {
        try { $process.Dispose() } catch {}
    }
}

function Confirm-WorkflowRun {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind,
        [Parameter(Mandatory = $true)]
        [hashtable]$Details
    )

    Write-Banner
    Write-Host ("Ready to run: {0}" -f $Kind) -ForegroundColor Cyan
    Write-Host ""
    foreach ($key in $Details.Keys) {
        Write-Host ("{0}: {1}" -f $key, $Details[$key])
    }
    Write-Host ""
    return (Read-YesNo -PromptLabel "Continue" -DefaultValue $true)
}

function Get-IncompleteConversationStates {
    param([Parameter(Mandatory = $true)][string]$OutputRoot)

    $resolved = Resolve-UserPath -Path $OutputRoot
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { return @() }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($stateFile in @(Get-ChildItem -LiteralPath $resolved -Recurse -File -Filter conversation_state.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try {
            $state = [System.IO.File]::ReadAllText($stateFile.FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -ErrorAction Stop
            if ([string]$state.Status -eq 'completed') { continue }
            $snapshotPath = Join-Path ([string]$state.ConversationDirectory) 'conversation.txt'
            [void]$results.Add([pscustomobject]@{
                Path = $stateFile.FullName
                State = $state
                SnapshotPath = $snapshotPath
                Display = ("{0} | {1} | {2} completed" -f $stateFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), (Get-RelativeWorkflowPath -Path $stateFile.FullName), ([int]$state.CompletedOperations))
            })
        }
        catch {
        }
    }
    return @($results.ToArray())
}

function Select-ConversationBatchState {
    param([Parameter(Mandatory = $true)][string]$OutputRoot)

    $states = @(Get-IncompleteConversationStates -OutputRoot $OutputRoot)
    if ($states.Count -eq 0) {
        return [pscustomobject]@{ IsNew = $true; Item = $null }
    }

    $items = New-Object System.Collections.Generic.List[object]
    [void]$items.Add([pscustomobject]@{ Choice = 1; Text = $Ui.ConversationNewRun })
    for ($i = 0; $i -lt $states.Count; $i++) {
        [void]$items.Add([pscustomobject]@{ Choice = $i + 2; Text = [string]$states[$i].Display })
    }
    [void]$items.Add([pscustomobject]@{ Choice = 0; Text = $Ui.BackMenu0 })

    $choice = Read-MenuChoice -Items @($items.ToArray()) -Title $Ui.ConversationResumeTitle -Hint $Ui.SubMenuHint -ControlZReturns
    if ($choice -eq 0) { return $null }
    if ($choice -eq 1) { return [pscustomobject]@{ IsNew = $true; Item = $null } }
    return [pscustomobject]@{ IsNew = $false; Item = $states[$choice - 2] }
}

function Get-LatestIncompletePromptBatchState {
    param(
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $true)][string]$PromptFile
    )

    $resolved = Resolve-UserPath -Path $OutputRoot
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        return $null
    }

    $sourceHash = (Get-FileHash -LiteralPath $PromptFile -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach ($stateFile in @(Get-ChildItem -LiteralPath $resolved -Recurse -File -Filter prompt_batch_state.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try {
            $state = [System.IO.File]::ReadAllText($stateFile.FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            if ([string]$state.SourceHash -eq $sourceHash -and $state.Status -ne 'completed' -and [int]$state.NextIndex -lt [int]$state.PromptCount) {
                return $stateFile.FullName
            }
        }
        catch {
        }
    }

    return $null
}

function Get-CodexHomePath {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return $env:CODEX_HOME
    }

    return (Join-Path $HOME ".codex")
}

function Get-CodexAuthApiKey {
    $authPath = Join-Path (Get-CodexHomePath) "auth.json"
    if (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) {
        return ""
    }

    try {
        $auth = [System.IO.File]::ReadAllText($authPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        $property = $auth.PSObject.Properties["OPENAI_API_KEY"]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    catch {
    }

    return ""
}

function Get-CodexConfigSettings {
    $configPath = Join-Path (Get-CodexHomePath) "config.toml"
    $result = @{
        ConfigPath = $configPath
        Model = ""
        ModelProvider = ""
        BaseUrl = ""
    }

    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return $result
    }

    try {
        $configText = [System.IO.File]::ReadAllText($configPath, [System.Text.UTF8Encoding]::new($false))
        $providerMatch = [regex]::Match($configText, '(?m)^\s*model_provider\s*=\s*"([^"]+)"')
        if ($providerMatch.Success) {
            $result.ModelProvider = $providerMatch.Groups[1].Value
        }

        $modelMatch = [regex]::Match($configText, '(?m)^\s*model\s*=\s*"([^"]+)"')
        if ($modelMatch.Success) {
            $result.Model = $modelMatch.Groups[1].Value
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$result.ModelProvider)) {
            $escapedProviderName = [regex]::Escape([string]$result.ModelProvider)
            $sectionPattern = "(?ms)^\[model_providers\.$escapedProviderName\]\s*(.*?)(?=^\[|\z)"
            $sectionMatch = [regex]::Match($configText, $sectionPattern)
            if ($sectionMatch.Success) {
                $baseUrlMatch = [regex]::Match($sectionMatch.Groups[1].Value, '(?m)^\s*base_url\s*=\s*"([^"]+)"')
                if ($baseUrlMatch.Success) {
                    $result.BaseUrl = $baseUrlMatch.Groups[1].Value
                }
            }
        }
    }
    catch {
    }

    return $result
}

function Get-WorkflowEffectiveApiKeyInfo {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind = 'Text'
    )

    if ($Kind -eq 'Text' -and -not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.TextApiKey)) {
        return [pscustomobject]@{ Value = [string]$WorkflowConfig.TextApiKey; Source = "workflow text override" }
    }

    if ($Kind -eq 'Image' -and -not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.ImageApiKey)) {
        return [pscustomobject]@{ Value = [string]$WorkflowConfig.ImageApiKey; Source = "workflow image override" }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.OpenAIApiKey)) {
        return [pscustomobject]@{ Value = [string]$WorkflowConfig.OpenAIApiKey; Source = "workflow legacy fallback" }
    }

    if ($Kind -eq 'Image' -and -not [string]::IsNullOrWhiteSpace($env:OPENAI_IMAGE_API_KEY)) {
        return [pscustomobject]@{ Value = $env:OPENAI_IMAGE_API_KEY; Source = "env OPENAI_IMAGE_API_KEY" }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
        return [pscustomobject]@{ Value = $env:OPENAI_API_KEY; Source = "env OPENAI_API_KEY" }
    }

    $codexKey = Get-CodexAuthApiKey
    if (-not [string]::IsNullOrWhiteSpace($codexKey)) {
        return [pscustomobject]@{ Value = $codexKey; Source = "Codex auth" }
    }

    return [pscustomobject]@{ Value = ""; Source = "" }
}

function Get-WorkflowEffectiveBaseUrlInfo {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind = 'Text'
    )

    if ($Kind -eq 'Text' -and -not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.TextBaseUrl)) {
        return [pscustomobject]@{ Value = [string]$WorkflowConfig.TextBaseUrl; Source = "workflow text override" }
    }

    if ($Kind -eq 'Image' -and -not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.ImageBaseUrl)) {
        return [pscustomobject]@{ Value = [string]$WorkflowConfig.ImageBaseUrl; Source = "workflow image override" }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.OpenAIBaseUrl)) {
        return [pscustomobject]@{ Value = [string]$WorkflowConfig.OpenAIBaseUrl; Source = "workflow legacy fallback" }
    }

    if ($Kind -eq 'Image' -and -not [string]::IsNullOrWhiteSpace($env:OPENAI_IMAGE_BASE_URL)) {
        return [pscustomobject]@{ Value = $env:OPENAI_IMAGE_BASE_URL; Source = "env OPENAI_IMAGE_BASE_URL" }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_BASE_URL)) {
        return [pscustomobject]@{ Value = $env:OPENAI_BASE_URL; Source = "env OPENAI_BASE_URL" }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_API_BASE)) {
        return [pscustomobject]@{ Value = $env:OPENAI_API_BASE; Source = "env OPENAI_API_BASE" }
    }

    $codexSettings = Get-CodexConfigSettings
    if (-not [string]::IsNullOrWhiteSpace([string]$codexSettings.BaseUrl)) {
        return [pscustomobject]@{ Value = [string]$codexSettings.BaseUrl; Source = "Codex config" }
    }

    return [pscustomobject]@{ Value = "https://api.openai.com"; Source = "default" }
}

function Get-WorkflowEffectiveTextModelInfo {
    if (-not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.TextModel)) {
        return [pscustomobject]@{ Value = [string]$WorkflowConfig.TextModel; Source = "workflow override" }
    }

    $codexSettings = Get-CodexConfigSettings
    if (-not [string]::IsNullOrWhiteSpace([string]$codexSettings.Model)) {
        return [pscustomobject]@{ Value = [string]$codexSettings.Model; Source = "Codex config" }
    }

    return [pscustomobject]@{ Value = ""; Source = "" }
}

function Get-WorkflowEffectiveImageModelInfo {
    if (-not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.ImageModel)) {
        return [pscustomobject]@{ Value = [string]$WorkflowConfig.ImageModel; Source = "workflow image override" }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_IMAGE_MODEL)) {
        return [pscustomobject]@{ Value = $env:OPENAI_IMAGE_MODEL; Source = "env OPENAI_IMAGE_MODEL" }
    }

    return [pscustomobject]@{ Value = "gpt-image-1"; Source = "default" }
}

function Get-WorkflowConfiguredApiProfiles {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind
    )

    $value = if ($Kind -eq 'Text') { $WorkflowConfig.TextApiProfiles } else { $WorkflowConfig.ImageApiProfiles }
    if ($null -eq $value) {
        return @()
    }

    $items = if ($value -is [array]) { @($value) } else { @($value) }
    $profiles = New-Object System.Collections.Generic.List[object]
    foreach ($item in $items) {
        if ($null -eq $item) {
            continue
        }

        $name = ""
        $apiKey = ""
        $baseUrl = ""
        $model = ""
        if ($item -is [string]) {
            $baseUrl = [string]$item
        }
        else {
            $nameProperty = $item.PSObject.Properties["Name"]
            $apiKeyProperty = $item.PSObject.Properties["ApiKey"]
            $baseUrlProperty = $item.PSObject.Properties["BaseUrl"]
            $modelProperty = $item.PSObject.Properties["Model"]
            if ($nameProperty) { $name = [string]$nameProperty.Value }
            if ($apiKeyProperty) { $apiKey = [string]$apiKeyProperty.Value }
            if ($baseUrlProperty) { $baseUrl = [string]$baseUrlProperty.Value }
            if ($modelProperty) { $model = [string]$modelProperty.Value }
        }

        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = "{0} API {1}" -f $Kind.ToLowerInvariant(), ($profiles.Count + 1)
        }

        if (-not [string]::IsNullOrWhiteSpace($apiKey) -or -not [string]::IsNullOrWhiteSpace($baseUrl) -or -not [string]::IsNullOrWhiteSpace($model)) {
            [void]$profiles.Add([pscustomobject]@{
                Name = $name
                ApiKey = $apiKey
                BaseUrl = $baseUrl
                Model = $model
            })
        }
    }

    return @($profiles.ToArray())
}

function ConvertTo-WorkflowApiProfilesJson {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind,
        [switch]$ForDisplay
    )

    $profiles = @(Get-WorkflowConfiguredApiProfiles -Kind $Kind)
    if ($profiles.Count -eq 0) {
        return ""
    }

    $displayProfiles = if ($ForDisplay) {
        @($profiles | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                ApiKey = $(if ([string]::IsNullOrWhiteSpace([string]$_.ApiKey)) { "" } else { Get-MaskedSecret -Value ([string]$_.ApiKey) })
                BaseUrl = [string]$_.BaseUrl
                Model = [string]$_.Model
            }
        })
    }
    else {
        $profiles
    }

    return ($displayProfiles | ConvertTo-Json -Depth 6 -Compress)
}

function Set-WorkflowApiProfilesFromJson {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind,
        [AllowEmptyString()]
        [string]$Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        if ($Kind -eq 'Text') {
            $WorkflowConfig.TextApiProfiles = @()
        }
        else {
            $WorkflowConfig.ImageApiProfiles = @()
        }
        return
    }

    $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    $items = if ($parsed -is [array]) { @($parsed) } else { @($parsed) }
    $profiles = @($items | ForEach-Object {
        [pscustomobject]@{
            Name = [string]$_.Name
            ApiKey = [string]$_.ApiKey
            BaseUrl = [string]$_.BaseUrl
            Model = [string]$_.Model
        }
    })

    if ($Kind -eq 'Text') {
        $WorkflowConfig.TextApiProfiles = $profiles
    }
    else {
        $WorkflowConfig.ImageApiProfiles = $profiles
    }
}

function Set-WorkflowConfiguredApiProfiles {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind,
        [AllowEmptyCollection()]
        [object[]]$Profiles = @()
    )

    $normalized = @($Profiles | ForEach-Object {
        [pscustomobject]@{
            Name = [string]$_.Name
            ApiKey = [string]$_.ApiKey
            BaseUrl = [string]$_.BaseUrl
            Model = [string]$_.Model
        }
    })

    if ($Kind -eq 'Text') {
        $WorkflowConfig.TextApiProfiles = $normalized
    }
    else {
        $WorkflowConfig.ImageApiProfiles = $normalized
    }
}

function Get-WorkflowPrimaryApiProfile {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind,
        [switch]$ForDisplay
    )

    $profile = if ($Kind -eq 'Text') {
        [pscustomobject]@{
            Name = [string]$WorkflowConfig.TextApiName
            ApiKey = [string]$WorkflowConfig.TextApiKey
            BaseUrl = [string]$WorkflowConfig.TextBaseUrl
            Model = [string]$WorkflowConfig.TextModel
        }
    }
    else {
        [pscustomobject]@{
            Name = [string]$WorkflowConfig.ImageApiName
            ApiKey = [string]$WorkflowConfig.ImageApiKey
            BaseUrl = [string]$WorkflowConfig.ImageBaseUrl
            Model = [string]$WorkflowConfig.ImageModel
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$profile.Name)) {
        $profile.Name = if ($Kind -eq 'Text') { "text primary" } else { "image primary" }
    }

    if ($ForDisplay -and -not [string]::IsNullOrWhiteSpace([string]$profile.ApiKey)) {
        $profile.ApiKey = Get-MaskedSecret -Value ([string]$profile.ApiKey)
    }

    return $profile
}

function ConvertTo-WorkflowPrimaryApiJson {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind,
        [switch]$ForDisplay
    )

    if ($ForDisplay) {
        $profile = Get-WorkflowPrimaryApiProfile -Kind $Kind
        $apiKeyInfo = Get-WorkflowEffectiveApiKeyInfo -Kind $Kind
        $baseUrlInfo = Get-WorkflowEffectiveBaseUrlInfo -Kind $Kind
        $modelInfo = if ($Kind -eq 'Text') { Get-WorkflowEffectiveTextModelInfo } else { Get-WorkflowEffectiveImageModelInfo }
        return ([pscustomobject]@{
            Name = [string]$profile.Name
            ApiKey = Format-WorkflowEffectiveConfigValue -Value ([string]$apiKeyInfo.Value) -Source ([string]$apiKeyInfo.Source) -Mask
            BaseUrl = Format-WorkflowEffectiveConfigValue -Value ([string]$baseUrlInfo.Value) -Source ([string]$baseUrlInfo.Source)
            Model = Format-WorkflowEffectiveConfigValue -Value ([string]$modelInfo.Value) -Source ([string]$modelInfo.Source)
        } | ConvertTo-Json -Depth 4 -Compress)
    }

    return (Get-WorkflowPrimaryApiProfile -Kind $Kind | ConvertTo-Json -Depth 4 -Compress)
}

function Set-WorkflowPrimaryApiFromJson {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind,
        [AllowEmptyString()]
        [string]$Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        $parsed = [pscustomobject]@{ Name = ""; ApiKey = ""; BaseUrl = ""; Model = "" }
    }
    else {
        $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    }

    if ($Kind -eq 'Text') {
        $WorkflowConfig.TextApiName = [string]$parsed.Name
        $WorkflowConfig.TextApiKey = [string]$parsed.ApiKey
        $WorkflowConfig.TextBaseUrl = [string]$parsed.BaseUrl
        $WorkflowConfig.TextModel = [string]$parsed.Model
    }
    else {
        $WorkflowConfig.ImageApiName = [string]$parsed.Name
        $WorkflowConfig.ImageApiKey = [string]$parsed.ApiKey
        $WorkflowConfig.ImageBaseUrl = [string]$parsed.BaseUrl
        $WorkflowConfig.ImageModel = [string]$parsed.Model
    }
}

function Format-WorkflowEffectiveConfigValue {
    param(
        [AllowEmptyString()]
        [string]$Value,
        [AllowEmptyString()]
        [string]$Source = "",
        [switch]$Mask
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Ui.ConfigNotSet
    }

    $displayValue = if ($Mask) { Get-MaskedSecret -Value $Value } else { $Value }
    if ([string]::IsNullOrWhiteSpace($Source)) {
        return $displayValue
    }

    return ("{0} ({1})" -f $displayValue, $Source)
}

function Get-WorkflowConfigDisplayValue {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Ui.ConfigNotSet
    }

    return $Value
}

function Get-WorkflowImageFormatExtension {
    param(
        [AllowEmptyString()]
        [string]$Format
    )

    switch ($Format.ToLowerInvariant()) {
        "jpeg" { return ".jpg" }
        "webp" { return ".webp" }
        default { return ".png" }
    }
}

function Read-WorkflowImageOutputPath {
    param(
        [Parameter(Mandatory = $true)][string]$DefaultValue,
        [Parameter(Mandatory = $true)][string]$Format
    )

    $expectedExtension = Get-WorkflowImageFormatExtension -Format $Format
    while ($true) {
        $value = Read-TextValue -PromptLabel $Ui.ImageOutputPath -DefaultValue $DefaultValue -Required
        $resolved = Resolve-UserPath -Path $value
        $actualExtension = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
        $validExtensions = if ($expectedExtension -eq '.jpg') { @('.jpg', '.jpeg') } else { @($expectedExtension) }
        if ($actualExtension -in $validExtensions) { return $resolved }
        Write-Host ($Ui.ImageExtensionMismatch -f $expectedExtension) -ForegroundColor Yellow
    }
}

function Read-WorkflowOptionValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$Values,
        [Parameter(Mandatory = $true)]
        [string[]]$Labels,
        [AllowEmptyString()]
        [string]$CurrentValue = ""
    )

    $items = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $marker = if ([string]$Values[$i] -eq $CurrentValue) { " *" } else { "" }
        [void]$items.Add([pscustomobject]@{
            Choice = $i + 1
            Text = ("{0}{1}" -f $Labels[$i], $marker)
        })
    }
    [void]$items.Add([pscustomobject]@{ Choice = 0; Text = $Ui.BackMenu0 })

    $choice = Read-MenuChoice -Items @($items.ToArray()) -Title $Title -Hint $Ui.SubMenuHint -ControlZReturns
    if ($choice -le 0) {
        return $null
    }

    return [string]$Values[$choice - 1]
}

function Get-WorkflowImageOptionDisplayValue {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('AspectRatio', 'Size', 'Quality', 'Format', 'Compression', 'Moderation')]
        [string]$Kind,
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Ui.ImageGenerationAuto
    }

    switch ($Kind) {
        'Quality' {
            switch ($Value) {
                'low' { return $Ui.ImageQualityLow }
                'medium' { return $Ui.ImageQualityMedium }
                'high' { return $Ui.ImageQualityHigh }
            }
        }
        'Format' {
            switch ($Value) {
                'jpeg' { return 'JPEG' }
                'webp' { return 'WebP' }
                'png' { return 'PNG' }
            }
        }
        'Moderation' {
            if ($Value -eq 'low') {
                return $Ui.ImageModerationLow
            }
        }
    }

    return $Value
}

function Get-WorkflowImageGenerationDetailLines {
    return @(
        ("{0}: {1}" -f $Ui.ImageAspectRatio, (Get-WorkflowImageOptionDisplayValue -Kind AspectRatio -Value ([string]$WorkflowConfig.ImageAspectRatio)))
        ("{0}: {1}" -f $Ui.ImageSize, (Get-WorkflowImageOptionDisplayValue -Kind Size -Value ([string]$WorkflowConfig.ImageSize)))
        ("{0}: {1}" -f $Ui.ImageQuality, (Get-WorkflowImageOptionDisplayValue -Kind Quality -Value ([string]$WorkflowConfig.ImageQuality)))
        ("{0}: {1}" -f $Ui.ImageFormat, (Get-WorkflowImageOptionDisplayValue -Kind Format -Value ([string]$WorkflowConfig.ImageFormat)))
        ("{0}: {1}" -f $Ui.ImageCompressionQuality, (Get-WorkflowImageOptionDisplayValue -Kind Compression -Value ([string]$WorkflowConfig.ImageCompressionQuality)))
        ("{0}: {1}" -f $Ui.ImageModeration, (Get-WorkflowImageOptionDisplayValue -Kind Moderation -Value ([string]$WorkflowConfig.ImageModeration)))
    )
}

function Write-WorkflowConfigSummary {
    Write-Banner
    Write-FrameLine -Text $Ui.ConfigCurrent -ForegroundColor Cyan -Color
    Write-FrameLine
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.ConfigFile, $workflowConfigPath)
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.LanguageLabel, (Get-WorkflowConfigDisplayValue -Value ([string]$WorkflowConfig.Language)))
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.WorkspacePath, (Get-WorkflowConfigDisplayValue -Value ([string]$WorkflowConfig.Workspace)))
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.OutputRoot, (Get-WorkflowConfigDisplayValue -Value ([string]$WorkflowConfig.OutputRoot)))
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.ImageOutputRoot, (Get-WorkflowConfigDisplayValue -Value ([string]$WorkflowConfig.ImageOutputRoot)))
    Write-FrameLine
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.TextPrimaryApiLabel, (ConvertTo-WorkflowPrimaryApiJson -Kind Text -ForDisplay))
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.TextApiProfilesLabel, (Get-WorkflowConfigDisplayValue -Value (ConvertTo-WorkflowApiProfilesJson -Kind Text -ForDisplay)))
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.ImagePrimaryApiLabel, (ConvertTo-WorkflowPrimaryApiJson -Kind Image -ForDisplay))
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.ImageApiProfilesLabel, (Get-WorkflowConfigDisplayValue -Value (ConvertTo-WorkflowApiProfilesJson -Kind Image -ForDisplay)))
    foreach ($line in Get-WorkflowImageGenerationDetailLines) {
        Write-FrameLine -Text $line
    }
    Write-FrameLine
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.MaxConcurrency, (ConvertTo-WorkflowInt -Value $WorkflowConfig.MaxConcurrency -DefaultValue 2 -Min 1 -Max 20))
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.MaxAttempts, (ConvertTo-WorkflowInt -Value $WorkflowConfig.MaxAttempts -DefaultValue 6 -Min 1 -Max 20))
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.RetryBase, (ConvertTo-WorkflowInt -Value $WorkflowConfig.RetryBaseDelaySeconds -DefaultValue 2 -Min 1 -Max 300))
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.RetryMax, (ConvertTo-WorkflowInt -Value $WorkflowConfig.RetryMaxDelaySeconds -DefaultValue 20 -Min 1 -Max 600))
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.TimeoutSeconds, (ConvertTo-WorkflowInt -Value $WorkflowConfig.TimeoutSeconds -DefaultValue 600 -Min 1 -Max 86400))
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.ImageRequestTimeoutSeconds, (ConvertTo-WorkflowInt -Value $WorkflowConfig.ImageRequestTimeoutSeconds -DefaultValue 600 -Min 1 -Max 86400))
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.ImageTotalTimeoutSeconds, (ConvertTo-WorkflowInt -Value $WorkflowConfig.ImageTotalTimeoutSeconds -DefaultValue 1800 -Min 1 -Max 86400))
    Write-FrameLine -Text ("{0}: {1}" -f $Ui.WaitInTerminal, (ConvertTo-WorkflowBool -Value $WorkflowConfig.WaitInTerminal -DefaultValue $true))
}

function Complete-WorkflowConfigEdit {
    Save-WorkflowConfig
    Apply-WorkflowConfig
    Write-Host ""
    Write-Host $Ui.ConfigSaved -ForegroundColor Green
    Start-Sleep -Milliseconds 600
}

function Read-WorkflowApiProfileForm {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind,
        [AllowNull()]
        [object]$Profile,
        [AllowEmptyString()]
        [string]$DefaultName = ""
    )

    $name = ""
    $apiKey = ""
    $baseUrl = ""
    $model = ""
    if ($null -ne $Profile) {
        foreach ($field in @("Name", "ApiKey", "BaseUrl", "Model")) {
            $property = $Profile.PSObject.Properties[$field]
            if ($property) {
                switch ($field) {
                    "Name" { $name = [string]$property.Value }
                    "ApiKey" { $apiKey = [string]$property.Value }
                    "BaseUrl" { $baseUrl = [string]$property.Value }
                    "Model" { $model = [string]$property.Value }
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $DefaultName
    }

    Write-Host ""
    Write-Host ("{0}: Name / ApiKey / BaseUrl / Model" -f $(if ($Kind -eq 'Text') { $Ui.ApiMenu1 } else { $Ui.ApiMenu2 })) -ForegroundColor Cyan
    $name = Read-ConfigTextValue -PromptLabel $Ui.ApiProfileNameLabel -CurrentValue $name
    $apiKeyDisplay = if ([string]::IsNullOrWhiteSpace($apiKey)) { $Ui.ConfigNotSet } else { Get-MaskedSecret -Value $apiKey }
    $apiKey = Read-ConfigTextValue -PromptLabel $Ui.ApiProfileKeyLabel -CurrentValue $apiKey -DisplayValue $apiKeyDisplay -MaskCurrent
    $baseUrl = Read-ConfigTextValue -PromptLabel $Ui.ApiProfileBaseUrlLabel -CurrentValue $baseUrl
    $model = Read-ConfigTextValue -PromptLabel $Ui.ApiProfileModelLabel -CurrentValue $model

    return [pscustomobject]@{
        Name = $name
        ApiKey = $apiKey
        BaseUrl = $baseUrl
        Model = $model
    }
}

function Invoke-ConfigLanguageAction {
    $items = @(
        [pscustomobject]@{ Choice = 1; Text = "English" }
        [pscustomobject]@{ Choice = 2; Text = "zh-CN" }
        [pscustomobject]@{ Choice = 0; Text = $Ui.BackMenu0 }
    )
    $choice = Read-MenuChoice -Items $items -Title $Ui.LanguageLabel -Hint $Ui.SubMenuHint -ControlZReturns
    switch ($choice) {
        1 { $WorkflowConfig.Language = "en"; Complete-WorkflowConfigEdit }
        2 { $WorkflowConfig.Language = "zh-CN"; Complete-WorkflowConfigEdit }
    }
}

function Invoke-ConfigPrimaryApiAction {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind
    )

    $profile = Get-WorkflowPrimaryApiProfile -Kind $Kind
    $updated = Read-WorkflowApiProfileForm -Kind $Kind -Profile $profile -DefaultName $(if ($Kind -eq 'Text') { "text primary" } else { "image primary" })
    if ($Kind -eq 'Text') {
        $WorkflowConfig.TextApiName = [string]$updated.Name
        $WorkflowConfig.TextApiKey = [string]$updated.ApiKey
        $WorkflowConfig.TextBaseUrl = [string]$updated.BaseUrl
        $WorkflowConfig.TextModel = [string]$updated.Model
    }
    else {
        $WorkflowConfig.ImageApiName = [string]$updated.Name
        $WorkflowConfig.ImageApiKey = [string]$updated.ApiKey
        $WorkflowConfig.ImageBaseUrl = [string]$updated.BaseUrl
        $WorkflowConfig.ImageModel = [string]$updated.Model
    }
    Complete-WorkflowConfigEdit
}

function Format-WorkflowApiProfileSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Profile,
        [int]$Index = 0
    )

    $displayKey = if ([string]::IsNullOrWhiteSpace([string]$Profile.ApiKey)) {
        $Ui.ConfigNotSet
    }
    else {
        Get-MaskedSecret -Value ([string]$Profile.ApiKey)
    }
    $displayBaseUrl = Get-WorkflowConfigDisplayValue -Value ([string]$Profile.BaseUrl)
    $displayModel = Get-WorkflowConfigDisplayValue -Value ([string]$Profile.Model)
    $prefix = if ($Index -gt 0) { "{0}. " -f $Index } else { "" }

    return ("{0}{1} | {2}: {3} | {4}: {5} | {6}: {7}" -f $prefix, [string]$Profile.Name, $Ui.ApiProfileKeyLabel, $displayKey, $Ui.ApiProfileBaseUrlLabel, $displayBaseUrl, $Ui.ApiProfileModelLabel, $displayModel)
}

function Get-WorkflowApiProfileDetailLines {
    param(
        [AllowEmptyCollection()]
        [object[]]$Profiles
    )

    if ($Profiles.Count -eq 0) {
        return @($Ui.FallbackApiNoProfiles)
    }

    $lines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Profiles.Count; $i++) {
        [void]$lines.Add((Format-WorkflowApiProfileSummary -Profile $Profiles[$i] -Index ($i + 1)))
    }

    return @($lines.ToArray())
}

function Invoke-ConfigApiProfilesAction {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind
    )

    while ($true) {
        $profiles = @(Get-WorkflowConfiguredApiProfiles -Kind $Kind)
        $title = if ($Kind -eq 'Text') { $Ui.TextApiProfilesLabel } else { $Ui.ImageApiProfilesLabel }
        $detailLines = @(Get-WorkflowApiProfileDetailLines -Profiles $profiles)

        $items = @(
            [pscustomobject]@{ Choice = 1; Text = $Ui.FallbackApiAdd }
            [pscustomobject]@{ Choice = 2; Text = $Ui.FallbackApiEdit }
            [pscustomobject]@{ Choice = 3; Text = $Ui.FallbackApiDelete }
            [pscustomobject]@{ Choice = 4; Text = $Ui.FallbackApiMoveUp }
            [pscustomobject]@{ Choice = 5; Text = $Ui.FallbackApiMoveDown }
            [pscustomobject]@{ Choice = 6; Text = $Ui.FallbackApiClear }
            [pscustomobject]@{ Choice = 0; Text = $Ui.BackMenu0 }
        )
        $choice = Read-MenuChoice -Items $items -Title $title -DetailLines $detailLines -Hint $Ui.SubMenuHint -ControlZReturns
        switch ($choice) {
            0 { return }
            1 {
                $newProfile = Read-WorkflowApiProfileForm -Kind $Kind -Profile $null -DefaultName ("backup-{0}" -f ($profiles.Count + 1))
                Set-WorkflowConfiguredApiProfiles -Kind $Kind -Profiles @($profiles + $newProfile)
                Complete-WorkflowConfigEdit
            }
            2 {
                if ($profiles.Count -eq 0) { continue }
                $index = if ($profiles.Count -eq 1) { 0 } else { (Read-IntValue -PromptLabel $Ui.FallbackApiIndexLabel -DefaultValue 1 -Min 1 -Max $profiles.Count) - 1 }
                $profiles[$index] = Read-WorkflowApiProfileForm -Kind $Kind -Profile $profiles[$index] -DefaultName ("backup-{0}" -f ($index + 1))
                Set-WorkflowConfiguredApiProfiles -Kind $Kind -Profiles $profiles
                Complete-WorkflowConfigEdit
            }
            3 {
                if ($profiles.Count -eq 0) { continue }
                $index = if ($profiles.Count -eq 1) { 0 } else { (Read-IntValue -PromptLabel $Ui.FallbackApiIndexLabel -DefaultValue 1 -Min 1 -Max $profiles.Count) - 1 }
                $updated = New-Object System.Collections.Generic.List[object]
                for ($i = 0; $i -lt $profiles.Count; $i++) {
                    if ($i -ne $index) { [void]$updated.Add($profiles[$i]) }
                }
                Set-WorkflowConfiguredApiProfiles -Kind $Kind -Profiles @($updated.ToArray())
                Complete-WorkflowConfigEdit
            }
            4 {
                if ($profiles.Count -lt 2) { continue }
                $index = (Read-IntValue -PromptLabel $Ui.FallbackApiIndexLabel -DefaultValue 1 -Min 1 -Max $profiles.Count) - 1
                if ($index -le 0) { continue }
                $temp = $profiles[$index - 1]
                $profiles[$index - 1] = $profiles[$index]
                $profiles[$index] = $temp
                Set-WorkflowConfiguredApiProfiles -Kind $Kind -Profiles $profiles
                Complete-WorkflowConfigEdit
            }
            5 {
                if ($profiles.Count -lt 2) { continue }
                $index = (Read-IntValue -PromptLabel $Ui.FallbackApiIndexLabel -DefaultValue 1 -Min 1 -Max $profiles.Count) - 1
                if ($index -ge ($profiles.Count - 1)) { continue }
                $temp = $profiles[$index + 1]
                $profiles[$index + 1] = $profiles[$index]
                $profiles[$index] = $temp
                Set-WorkflowConfiguredApiProfiles -Kind $Kind -Profiles $profiles
                Complete-WorkflowConfigEdit
            }
            6 {
                if ($profiles.Count -eq 0) { continue }
                if (Read-YesNo -PromptLabel $Ui.FallbackApiClearConfirm -DefaultValue $false) {
                    Set-WorkflowConfiguredApiProfiles -Kind $Kind -Profiles @()
                    Complete-WorkflowConfigEdit
                }
            }
        }
    }
}

function Invoke-ConfigPathsAction {
    $WorkflowConfig.Workspace = Read-ConfigTextValue -PromptLabel $Ui.WorkspacePath -CurrentValue ([string]$WorkflowConfig.Workspace)
    $WorkflowConfig.OutputRoot = Read-ConfigTextValue -PromptLabel $Ui.OutputRoot -CurrentValue ([string]$WorkflowConfig.OutputRoot)
    $WorkflowConfig.ImageOutputRoot = Read-ConfigTextValue -PromptLabel $Ui.ImageOutputRoot -CurrentValue ([string]$WorkflowConfig.ImageOutputRoot)
    Complete-WorkflowConfigEdit
}

function Invoke-ConfigBatchDefaultsAction {
    $WorkflowConfig.MaxConcurrency = Read-IntValue -PromptLabel $Ui.MaxConcurrency -DefaultValue (ConvertTo-WorkflowInt -Value $WorkflowConfig.MaxConcurrency -DefaultValue 2 -Min 1 -Max 20) -Min 1 -Max 20
    $WorkflowConfig.MaxAttempts = Read-IntValue -PromptLabel $Ui.MaxAttempts -DefaultValue (ConvertTo-WorkflowInt -Value $WorkflowConfig.MaxAttempts -DefaultValue 6 -Min 1 -Max 20) -Min 1 -Max 20
    $WorkflowConfig.RetryBaseDelaySeconds = Read-IntValue -PromptLabel $Ui.RetryBase -DefaultValue (ConvertTo-WorkflowInt -Value $WorkflowConfig.RetryBaseDelaySeconds -DefaultValue 2 -Min 1 -Max 300) -Min 1 -Max 300
    $WorkflowConfig.RetryMaxDelaySeconds = Read-IntValue -PromptLabel $Ui.RetryMax -DefaultValue (ConvertTo-WorkflowInt -Value $WorkflowConfig.RetryMaxDelaySeconds -DefaultValue 20 -Min 1 -Max 600) -Min 1 -Max 600
    $WorkflowConfig.TimeoutSeconds = Read-IntValue -PromptLabel $Ui.TimeoutSeconds -DefaultValue (ConvertTo-WorkflowInt -Value $WorkflowConfig.TimeoutSeconds -DefaultValue 600 -Min 1 -Max 86400) -Min 1 -Max 86400
    $WorkflowConfig.ImageRequestTimeoutSeconds = Read-IntValue -PromptLabel $Ui.ImageRequestTimeoutSeconds -DefaultValue (ConvertTo-WorkflowInt -Value $WorkflowConfig.ImageRequestTimeoutSeconds -DefaultValue 600 -Min 1 -Max 86400) -Min 1 -Max 86400
    $WorkflowConfig.ImageTotalTimeoutSeconds = Read-IntValue -PromptLabel $Ui.ImageTotalTimeoutSeconds -DefaultValue (ConvertTo-WorkflowInt -Value $WorkflowConfig.ImageTotalTimeoutSeconds -DefaultValue 1800 -Min 1 -Max 86400) -Min 1 -Max 86400
    $WorkflowConfig.WaitInTerminal = Read-YesNo -PromptLabel $Ui.WaitInTerminal -DefaultValue (ConvertTo-WorkflowBool -Value $WorkflowConfig.WaitInTerminal -DefaultValue $true)
    Complete-WorkflowConfigEdit
}

function Invoke-ConfigImageGenerationAction {
    param(
        [ValidateRange(0, 6)]
        [int]$InitialChoice = 0,
        [switch]$SingleSetting
    )

    $script:WorkflowLastActionExecuted = $true
    while ($true) {
        $choice = if ($SingleSetting) {
            $InitialChoice
        }
        else {
            Read-MenuChoice `
                -Items (Get-ImageGenerationConfigMenuItems) `
                -Title $Ui.ConfigMenu6 `
                -DetailLines (Get-WorkflowImageGenerationDetailLines) `
                -Hint $Ui.SubMenuHint `
                -ControlZReturns
        }

        switch ($choice) {
            0 { return }
            1 {
                $selectedValue = Read-WorkflowOptionValue `
                    -Title $Ui.ImageAspectRatio `
                    -Values @("", "1:1", "3:2", "2:3", "16:9", "9:16", "7:4", "4:7") `
                    -Labels @($Ui.ImageGenerationAuto, "1:1", "3:2", "2:3", "16:9", "9:16", "7:4", "4:7") `
                    -CurrentValue ([string]$WorkflowConfig.ImageAspectRatio)
                if ($null -ne $selectedValue) {
                    $WorkflowConfig.ImageAspectRatio = $selectedValue
                    Complete-WorkflowConfigEdit
                }
            }
            2 {
                $selectedValue = Read-WorkflowOptionValue `
                    -Title $Ui.ImageSize `
                    -Values @("", "1024x1024", "1536x1024", "1024x1536", "2048x2048", "2048x1152", "1152x2048", "3840x2160", "2160x3840", "1792x1024", "1024x1792") `
                    -Labels @($Ui.ImageGenerationAuto, "1024x1024", "1536x1024", "1024x1536", "2048x2048", "2048x1152", "1152x2048", "3840x2160", "2160x3840", "1792x1024", "1024x1792") `
                    -CurrentValue ([string]$WorkflowConfig.ImageSize)
                if ($null -ne $selectedValue) {
                    $WorkflowConfig.ImageSize = $selectedValue
                    Complete-WorkflowConfigEdit
                }
            }
            3 {
                $selectedValue = Read-WorkflowOptionValue `
                    -Title $Ui.ImageQuality `
                    -Values @("", "low", "medium", "high") `
                    -Labels @($Ui.ImageGenerationAuto, $Ui.ImageQualityLow, $Ui.ImageQualityMedium, $Ui.ImageQualityHigh) `
                    -CurrentValue ([string]$WorkflowConfig.ImageQuality)
                if ($null -ne $selectedValue) {
                    $WorkflowConfig.ImageQuality = $selectedValue
                    Complete-WorkflowConfigEdit
                }
            }
            4 {
                $selectedValue = Read-WorkflowOptionValue `
                    -Title $Ui.ImageFormat `
                    -Values @("png", "jpeg", "webp") `
                    -Labels @("PNG", "JPEG", "WebP") `
                    -CurrentValue ([string]$WorkflowConfig.ImageFormat)
                if ($null -ne $selectedValue) {
                    $WorkflowConfig.ImageFormat = $selectedValue
                    Complete-WorkflowConfigEdit
                }
            }
            5 {
                $compressionChoice = Read-WorkflowOptionValue `
                    -Title $Ui.ImageCompressionQuality `
                    -Values @("", "__custom__") `
                    -Labels @($Ui.ImageGenerationAuto, $Ui.ImageCompressionCustom) `
                    -CurrentValue ([string]$WorkflowConfig.ImageCompressionQuality)
                if ($null -eq $compressionChoice) {
                    if ($SingleSetting) { return }
                    continue
                }
                if ($compressionChoice -eq "__custom__") {
                    $WorkflowConfig.ImageCompressionQuality = [string](Read-IntValue -PromptLabel $Ui.ImageCompressionQuality -DefaultValue 100 -Min 0 -Max 100)
                }
                else {
                    $WorkflowConfig.ImageCompressionQuality = $compressionChoice
                }
                Complete-WorkflowConfigEdit
            }
            6 {
                $selectedValue = Read-WorkflowOptionValue `
                    -Title $Ui.ImageModeration `
                    -Values @("low", "") `
                    -Labels @($Ui.ImageModerationLow, $Ui.ImageGenerationAuto) `
                    -CurrentValue ([string]$WorkflowConfig.ImageModeration)
                if ($null -ne $selectedValue) {
                    $WorkflowConfig.ImageModeration = $selectedValue
                    Complete-WorkflowConfigEdit
                }
            }
        }

        if ($SingleSetting) {
            return
        }
    }
}

function Get-WorkflowEffectiveApiKey {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind = 'Text'
    )

    $info = Get-WorkflowEffectiveApiKeyInfo -Kind $Kind
    return [string]$info.Value
}

function Get-WorkflowEffectiveBaseUrl {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind = 'Text'
    )

    $info = Get-WorkflowEffectiveBaseUrlInfo -Kind $Kind
    return [string]$info.Value
}

function Get-WorkflowModelsEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl
    )

    $trimmed = $BaseUrl.Trim().TrimEnd("/")
    if ($trimmed.EndsWith("/v1", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "$trimmed/models"
    }

    return "$trimmed/v1/models"
}

function Get-WorkflowModelEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$Model
    )

    $modelsEndpoint = (Get-WorkflowModelsEndpoint -BaseUrl $BaseUrl).TrimEnd("/")
    return ("{0}/{1}" -f $modelsEndpoint, [System.Uri]::EscapeDataString($Model))
}

function Get-WorkflowChatCompletionsEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl
    )

    $trimmed = $BaseUrl.Trim().TrimEnd("/")
    if ($trimmed.EndsWith("/v1", [System.StringComparison]::OrdinalIgnoreCase)) {
        return "$trimmed/chat/completions"
    }

    return "$trimmed/v1/chat/completions"
}

function Get-WorkflowBalanceEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $trimmed = $BaseUrl.Trim().TrimEnd("/")
    if ($trimmed.EndsWith("/v1", [System.StringComparison]::OrdinalIgnoreCase)) {
        $trimmed = $trimmed.Substring(0, $trimmed.Length - 3).TrimEnd("/")
    }

    return ($trimmed + $Path)
}

function Get-WorkflowResponseJson {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response
    )

    try {
        if ($Response.Content) {
            return ($Response.Content | ConvertFrom-Json -ErrorAction Stop)
        }
    }
    catch {
    }

    return $null
}

function Get-WorkflowModelIdsFromResponse {
    param(
        [AllowNull()]
        [object]$Json
    )

    if ($null -eq $Json) {
        return @()
    }

    $dataProperty = $Json.PSObject.Properties["data"]
    if (-not $dataProperty -or $null -eq $dataProperty.Value) {
        return @()
    }

    return @($dataProperty.Value | ForEach-Object {
        $idProperty = $_.PSObject.Properties["id"]
        if ($idProperty -and -not [string]::IsNullOrWhiteSpace([string]$idProperty.Value)) {
            [string]$idProperty.Value
        }
    })
}

function Invoke-TestApiConnectionAction {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind = 'Text'
    )

    Apply-WorkflowConfig
    $effectiveApiKey = Get-WorkflowEffectiveApiKey -Kind $Kind
    $effectiveBaseUrl = Get-WorkflowEffectiveBaseUrl -Kind $Kind
    $profiles = @(New-WorkflowApiExecutionProfiles -Kind $Kind)
    Write-Host ""

    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $profile = $profiles[$i]
        $name = if (-not [string]::IsNullOrWhiteSpace([string]$profile.Name)) { [string]$profile.Name } else { "API profile {0}" -f ($i + 1) }
        $apiKey = if (-not [string]::IsNullOrWhiteSpace([string]$profile.ApiKey)) { [string]$profile.ApiKey } else { $effectiveApiKey }
        $baseUrl = if (-not [string]::IsNullOrWhiteSpace([string]$profile.BaseUrl)) { [string]$profile.BaseUrl } else { $effectiveBaseUrl }
        $model = [string]$profile.Model

        Write-Host ("[{0}/{1}] {2}" -f ($i + 1), $profiles.Count, $name) -ForegroundColor Cyan
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            Write-Host $Ui.ApiTestMissingKey -ForegroundColor Yellow
            continue
        }

        $endpoint = Get-WorkflowModelsEndpoint -BaseUrl $baseUrl
        Write-Host ("{0}: {1}" -f $Ui.ApiTestEndpoint, $endpoint) -ForegroundColor DarkGray

        try {
            $headers = @{ Authorization = "Bearer $apiKey" }
            $response = Invoke-WebRequest -Uri $endpoint -Headers $headers -Method Get -UseBasicParsing -TimeoutSec 20
            Write-Host ("{0} HTTP {1}" -f $Ui.ApiTestSuccess, [int]$response.StatusCode) -ForegroundColor Green
            $modelIds = @(Get-WorkflowModelIdsFromResponse -Json (Get-WorkflowResponseJson -Response $response))
            if (-not [string]::IsNullOrWhiteSpace($model)) {
                if ($modelIds -contains $model) {
                    Write-Host ("Model available: {0}" -f $model) -ForegroundColor Green
                }
                elseif ($modelIds.Count -gt 0) {
                    Write-Host ("Model not listed: {0}" -f $model) -ForegroundColor Yellow
                }
                else {
                    Write-Host ("Model check skipped: model list response was not recognized.") -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "Model not configured for this API profile." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host $Ui.ApiTestFailed -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        if (-not [string]::IsNullOrWhiteSpace($model)) {
            $modelEndpoint = Get-WorkflowModelEndpoint -BaseUrl $baseUrl -Model $model
            try {
                $modelResponse = Invoke-WebRequest -Uri $modelEndpoint -Headers @{ Authorization = "Bearer $apiKey" } -Method Get -UseBasicParsing -TimeoutSec 20
                Write-Host ("Model endpoint OK: {0} HTTP {1}" -f $model, [int]$modelResponse.StatusCode) -ForegroundColor Green
            }
            catch {
                Write-Host ("Model endpoint failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }

            if ($Kind -eq 'Text') {
                $chatEndpoint = Get-WorkflowChatCompletionsEndpoint -BaseUrl $baseUrl
                try {
                    $chatBody = @{
                        model = $model
                        messages = @(@{ role = "user"; content = "ping" })
                        max_tokens = 1
                    } | ConvertTo-Json -Depth 6 -Compress
                    $chatBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($chatBody)
                    $chatResponse = Invoke-WebRequest -Uri $chatEndpoint -Headers @{ Authorization = "Bearer $apiKey" } -Method Post -ContentType "application/json; charset=utf-8" -Body $chatBytes -UseBasicParsing -TimeoutSec 30
                    Write-Host ("Model invocation OK: {0} HTTP {1}" -f $model, [int]$chatResponse.StatusCode) -ForegroundColor Green
                }
                catch {
                    Write-Host ("Model invocation failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                }
            }
            else {
                Write-Host ("Image model live generation skipped to avoid billing: {0}" -f $model) -ForegroundColor DarkGray
            }
        }

        foreach ($balancePath in @('/dashboard/billing/credit_grants', '/v1/dashboard/billing/credit_grants', '/v1/usage')) {
            $balanceEndpoint = Get-WorkflowBalanceEndpoint -BaseUrl $baseUrl -Path $balancePath
            try {
                $balanceResponse = Invoke-WebRequest -Uri $balanceEndpoint -Headers @{ Authorization = "Bearer $apiKey" } -Method Get -UseBasicParsing -TimeoutSec 12
                Write-Host ("Balance endpoint OK: {0} HTTP {1}" -f $balancePath, [int]$balanceResponse.StatusCode) -ForegroundColor Green
                $balanceJson = Get-WorkflowResponseJson -Response $balanceResponse
                if ($balanceJson) {
                    $balanceText = ($balanceJson | ConvertTo-Json -Depth 4 -Compress)
                    if ($balanceText.Length -gt 240) {
                        $balanceText = $balanceText.Substring(0, 237) + "..."
                    }
                    Write-Host ("Balance response: {0}" -f $balanceText) -ForegroundColor DarkGray
                }
                break
            }
            catch {
                $message = $_.Exception.Message
                if ($message -match '\b(404|405)\b') {
                    Write-Host ("Balance endpoint unavailable: {0}" -f $balancePath) -ForegroundColor DarkGray
                    continue
                }

                Write-Host ("Balance check failed: {0} - {1}" -f $balancePath, $message) -ForegroundColor Yellow
                break
            }
        }

        Write-Host ""
    }
}

function Get-WorkflowCleanTargets {
    return @(
        (Resolve-UserPath -Path $DefaultOutputRoot),
        (Resolve-UserPath -Path $DefaultImageRoot)
    ) | Select-Object -Unique
}

function Test-SafeCleanTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Test-WorkflowCleanTarget -Path $Path -AllowedRoots @(
        (Join-Path $scriptRoot 'runs'),
        (Join-Path $scriptRoot 'codex_cli_runs'),
        (Join-Path $scriptRoot 'pic')
    ))
}

function Invoke-CleanHistoryAction {
    Apply-WorkflowConfig
    $targets = @(Get-WorkflowCleanTargets)
    Write-Host ""
    $stats = New-Object System.Collections.Generic.List[object]
    foreach ($target in $targets) {
        $stat = Get-WorkflowDirectoryStats -Path $target
        [void]$stats.Add($stat)
        $detail = if ($stat.Exists) {
            "{0} files, {1} MB" -f $stat.Files, $stat.SizeMB
        }
        else {
            "missing"
        }
        Write-Host ("{0}: {1} ({2})" -f $Ui.CleanHistoryTarget, $target, $detail) -ForegroundColor DarkGray
    }

    if (-not (Read-YesNo -PromptLabel $Ui.CleanHistoryConfirm -DefaultValue $false)) {
        return
    }

    foreach ($targetInfo in $stats) {
        $target = [string]$targetInfo.Path
        if (-not (Test-SafeCleanTarget -Path $target)) {
            throw "Unsafe clean target: $target"
        }

        if (-not $targetInfo.Exists) {
            Write-Host ($Ui.CleanHistorySkipMissing -f $target) -ForegroundColor DarkGray
            continue
        }

        Get-ChildItem -LiteralPath $target -Force | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force
        }
    }

    Write-Host $Ui.CleanHistoryDone -ForegroundColor Green
}

function Add-WorkflowParameterIfSet {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [AllowEmptyString()]
        [string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $Parameters[$Name] = $Value
    }
}

function New-WorkflowApiExecutionProfiles {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind
    )

    $profiles = New-Object System.Collections.Generic.List[object]
    if ($Kind -eq 'Text') {
        if (-not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.TextApiKey) -or -not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.TextBaseUrl) -or -not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.TextModel)) {
            [void]$profiles.Add([pscustomobject]@{
                Name = $(if ([string]::IsNullOrWhiteSpace([string]$WorkflowConfig.TextApiName)) { "workflow text primary" } else { [string]$WorkflowConfig.TextApiName })
                ApiKey = [string]$WorkflowConfig.TextApiKey
                BaseUrl = [string]$WorkflowConfig.TextBaseUrl
                Model = [string]$WorkflowConfig.TextModel
            })
        }
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.ImageApiKey) -or -not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.ImageBaseUrl) -or -not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.ImageModel)) {
            [void]$profiles.Add([pscustomobject]@{
                Name = $(if ([string]::IsNullOrWhiteSpace([string]$WorkflowConfig.ImageApiName)) { "workflow image primary" } else { [string]$WorkflowConfig.ImageApiName })
                ApiKey = [string]$WorkflowConfig.ImageApiKey
                BaseUrl = [string]$WorkflowConfig.ImageBaseUrl
                Model = [string]$WorkflowConfig.ImageModel
            })
        }
    }

    if ($profiles.Count -eq 0 -and (-not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.OpenAIApiKey) -or -not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.OpenAIBaseUrl))) {
        [void]$profiles.Add([pscustomobject]@{
            Name = "workflow legacy fallback"
            ApiKey = [string]$WorkflowConfig.OpenAIApiKey
            BaseUrl = [string]$WorkflowConfig.OpenAIBaseUrl
            Model = ""
        })
    }

    if ($profiles.Count -eq 0) {
        $defaultModelInfo = if ($Kind -eq 'Text') { Get-WorkflowEffectiveTextModelInfo } else { Get-WorkflowEffectiveImageModelInfo }
        [void]$profiles.Add([pscustomobject]@{
            Name = "Codex default"
            ApiKey = ""
            BaseUrl = ""
            Model = [string]$defaultModelInfo.Value
        })
    }

    foreach ($profile in @(Get-WorkflowConfiguredApiProfiles -Kind $Kind)) {
        [void]$profiles.Add($profile)
    }

    return @($profiles.ToArray())
}

function Add-WorkflowApiProfilesJsonParameter {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters,
        [ValidateSet('Text', 'Image')]
        [string]$Kind
    )

    $profiles = @(New-WorkflowApiExecutionProfiles -Kind $Kind)
    $hasConfiguredFallback = @(Get-WorkflowConfiguredApiProfiles -Kind $Kind).Count -gt 0
    $hasPrimaryOverride = $false
    foreach ($profile in $profiles) {
        if (-not [string]::IsNullOrWhiteSpace([string]$profile.ApiKey) -or -not [string]::IsNullOrWhiteSpace([string]$profile.BaseUrl) -or -not [string]::IsNullOrWhiteSpace([string]$profile.Model)) {
            $hasPrimaryOverride = $true
            break
        }
    }

    if ($profiles.Count -gt 1 -or $hasConfiguredFallback) {
        $parameterName = if ($Kind -eq 'Text') { "TextApiProfilesJson" } else { "ImageApiProfilesJson" }
        $Parameters[$parameterName] = ($profiles | ConvertTo-Json -Depth 6 -Compress)
    }
    elseif (-not $hasPrimaryOverride) {
        return
    }
}

function Add-WorkflowTextApiParameters {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters
    )

    $primary = (New-WorkflowApiExecutionProfiles -Kind Text)[0]
    $apiKey = [string]$primary.ApiKey
    $baseUrl = [string]$primary.BaseUrl
    $model = [string]$primary.Model

    Add-WorkflowParameterIfSet -Parameters $Parameters -Name "TextApiKey" -Value $apiKey
    Add-WorkflowParameterIfSet -Parameters $Parameters -Name "TextBaseUrl" -Value $baseUrl
    Add-WorkflowParameterIfSet -Parameters $Parameters -Name "Model" -Value $model
    Add-WorkflowApiProfilesJsonParameter -Parameters $Parameters -Kind Text
}

function Get-WorkflowTextPrimaryApiProfile {
    return (New-WorkflowApiExecutionProfiles -Kind Text)[0]
}

function Invoke-WithWorkflowTextEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    $primary = Get-WorkflowTextPrimaryApiProfile
    $previousOpenAiApiKey = $env:OPENAI_API_KEY
    $previousOpenAiBaseUrl = $env:OPENAI_BASE_URL
    $previousOpenAiApiBase = $env:OPENAI_API_BASE

    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$primary.ApiKey)) {
            $env:OPENAI_API_KEY = [string]$primary.ApiKey
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$primary.BaseUrl)) {
            $env:OPENAI_BASE_URL = [string]$primary.BaseUrl
            $env:OPENAI_API_BASE = [string]$primary.BaseUrl
        }

        & $ScriptBlock @ArgumentList
    }
    finally {
        $env:OPENAI_API_KEY = $previousOpenAiApiKey
        $env:OPENAI_BASE_URL = $previousOpenAiBaseUrl
        $env:OPENAI_API_BASE = $previousOpenAiApiBase
    }
}

function Invoke-CodexInteractiveChatAction {
    $workspacePath = Resolve-UserPath -Path $Workspace -MustExist
    $cliPaths = Get-CodexCliPaths
    $primary = Get-WorkflowTextPrimaryApiProfile
    $codexArgs = @("-C", $workspacePath)

    if (-not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.TextModel)) {
        $codexArgs += @("-m", [string]$WorkflowConfig.TextModel)
    }

    Clear-WorkflowProgressArea -Anchor Top
    Clear-WorkflowProgressArea -Anchor Bottom
    Clear-Host
    Write-Host $Ui.CodexTuiLaunch -ForegroundColor Cyan
    Write-Host ("Workspace: {0}" -f $workspacePath) -ForegroundColor DarkGray
    if (-not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.TextModel)) {
        Write-Host ("Model: {0}" -f ([string]$WorkflowConfig.TextModel)) -ForegroundColor DarkGray
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$primary.Model)) {
        Write-Host ("Model: {0}" -f ([string]$primary.Model)) -ForegroundColor DarkGray
    }
    Write-Host ""

    $launch = [pscustomobject]@{
        CommandPath = [string]$cliPaths.CommandPath
        Arguments = @($codexArgs)
    }

    Invoke-WithWorkflowTextEnvironment -ArgumentList @($launch) -ScriptBlock {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Launch
        )

        $commandPath = [string]$Launch.CommandPath
        $codexArguments = [string[]]@($Launch.Arguments)
        if ($commandPath.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $commandPath @codexArguments
        }
        else {
            & $commandPath @codexArguments
        }
    }

    Clear-WorkflowProgressArea -Anchor Top
    Clear-WorkflowProgressArea -Anchor Bottom
    Clear-Host
    Write-Host $Ui.CodexTuiReturned -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 500
}

function Add-WorkflowImageApiParameters {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters
    )

    $primary = (New-WorkflowApiExecutionProfiles -Kind Image)[0]
    $apiKey = [string]$primary.ApiKey
    $baseUrl = [string]$primary.BaseUrl
    $model = [string]$primary.Model

    Add-WorkflowParameterIfSet -Parameters $Parameters -Name "ImageApiKey" -Value $apiKey
    Add-WorkflowParameterIfSet -Parameters $Parameters -Name "ImageBaseUrl" -Value $baseUrl
    Add-WorkflowParameterIfSet -Parameters $Parameters -Name "Model" -Value $model
    Add-WorkflowApiProfilesJsonParameter -Parameters $Parameters -Kind Image
    Add-WorkflowParameterIfSet -Parameters $Parameters -Name "ImageAspectRatio" -Value ([string]$WorkflowConfig.ImageAspectRatio)
    Add-WorkflowParameterIfSet -Parameters $Parameters -Name "ImageSize" -Value ([string]$WorkflowConfig.ImageSize)
    Add-WorkflowParameterIfSet -Parameters $Parameters -Name "ImageQuality" -Value ([string]$WorkflowConfig.ImageQuality)
    Add-WorkflowParameterIfSet -Parameters $Parameters -Name "ImageOutputFormat" -Value ([string]$WorkflowConfig.ImageFormat)
    Add-WorkflowParameterIfSet -Parameters $Parameters -Name "ImageOutputCompression" -Value ([string]$WorkflowConfig.ImageCompressionQuality)
    Add-WorkflowParameterIfSet -Parameters $Parameters -Name "ImageModeration" -Value ([string]$WorkflowConfig.ImageModeration)
}

function Get-WorkflowPrimaryProfileModel {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind
    )

    $primary = (New-WorkflowApiExecutionProfiles -Kind $Kind)[0]
    return [string]$primary.Model
}

function Invoke-SinglePromptChatAction {
    $workspacePath = Resolve-UserPath -Path $Workspace -MustExist
    $outputRoot = Resolve-UserPath -Path $DefaultOutputRoot
    $promptText = Read-CodexPromptBox
    $runName = Read-TextValue -PromptLabel $Ui.RunNameOptional -DefaultValue ""
    $modelOverride = Read-TextValue -PromptLabel $Ui.ModelOptional -DefaultValue ""
    $archiveRun = Read-YesNo -PromptLabel $Ui.RunArchive -DefaultValue $true
    $openSummary = if ($archiveRun) { Read-YesNo -PromptLabel $Ui.OpenSummary -DefaultValue $false } else { $false }
    $timeout = ConvertTo-WorkflowInt -Value $WorkflowConfig.TimeoutSeconds -DefaultValue 600 -Min 1 -Max 86400
    $effectiveModel = if ([string]::IsNullOrWhiteSpace($modelOverride)) { Get-WorkflowPrimaryProfileModel -Kind Text } else { $modelOverride }

    if (-not (Confirm-WorkflowRun -Kind "Chat" -Details @{
        Workspace = $workspacePath
        Output = $(if ($archiveRun) { $outputRoot } else { '(temporary; not archived)' })
        RunName = $runName
        Model = $effectiveModel
        Archive = $archiveRun
        OpenSummary = $openSummary
        TimeoutSeconds = $timeout
    })) { return }

    $parameters = @{
        Prompt = $promptText
        Workspace = $workspacePath
        OutputRoot = $outputRoot
        RunName = $runName
        Model = ""
        TimeoutSeconds = $timeout
        NoReopenWindow = $true
    }
    if (-not $archiveRun) { $parameters.NoArchive = $true }
    if ($openSummary) { $parameters.OpenSummary = $true }
    Add-WorkflowTextApiParameters -Parameters $parameters
    if (-not [string]::IsNullOrWhiteSpace($modelOverride)) { $parameters.Model = $modelOverride }
    Invoke-WorkflowScript -ScriptPath $invokeScript -Parameters $parameters
}

function Invoke-ChatMenu {
    $chatChoice = Read-MenuChoice -Items (Get-ChatMenuItems) -Title $Ui.Menu1 -Hint $Ui.SubMenuHint -ControlZReturns
    switch ($chatChoice) {
        1 {
            Invoke-CodexInteractiveChatAction
            $script:WorkflowLastActionExecuted = $false
        }
        2 {
            $script:WorkflowLastActionExecuted = $true
            Invoke-SinglePromptChatAction
        }
    }
}

function Invoke-PromptFileAction {
    $workspacePath = Resolve-UserPath -Path $Workspace -MustExist
    $promptFile = Read-ExistingPath -PromptLabel $Ui.PromptFile -DefaultValue ""
    $outputRoot = Resolve-UserPath -Path $DefaultOutputRoot
    $runName = Read-TextValue -PromptLabel $Ui.RunNameOptional -DefaultValue ""
    $modelOverride = Read-TextValue -PromptLabel $Ui.ModelOptional -DefaultValue ""
    $openSummary = Read-YesNo -PromptLabel $Ui.OpenSummary -DefaultValue $false
    $timeout = ConvertTo-WorkflowInt -Value $WorkflowConfig.TimeoutSeconds -DefaultValue 600 -Min 1 -Max 86400
    $effectiveModel = if ([string]::IsNullOrWhiteSpace($modelOverride)) { Get-WorkflowPrimaryProfileModel -Kind Text } else { $modelOverride }

    if (-not (Confirm-WorkflowRun -Kind "Prompt file" -Details @{
        PromptFile = $promptFile
        Workspace = $workspacePath
        Output = $outputRoot
        Model = $effectiveModel
        OpenSummary = $openSummary
        TimeoutSeconds = $timeout
    })) { return }

    $parameters = @{
        PromptFile = $promptFile
        Workspace = $workspacePath
        OutputRoot = $outputRoot
        RunName = $runName
        Model = ""
        TimeoutSeconds = $timeout
        NoReopenWindow = $true
    }
    if ($openSummary) { $parameters.OpenSummary = $true }
    Add-WorkflowTextApiParameters -Parameters $parameters
    if (-not [string]::IsNullOrWhiteSpace($modelOverride)) { $parameters.Model = $modelOverride }
    Invoke-WorkflowScript -ScriptPath $invokeScript -Parameters $parameters
}

function Invoke-PromptListBatchAction {
    $workspacePath = Resolve-UserPath -Path $Workspace -MustExist
    $promptListFile = Read-ExistingPath -PromptLabel $Ui.PromptListFile -DefaultValue ""
    $outputRoot = Resolve-UserPath -Path $DefaultOutputRoot
    $runName = Read-TextValue -PromptLabel $Ui.BatchNameOptional -DefaultValue ""
    $timeout = ConvertTo-WorkflowInt -Value $WorkflowConfig.TimeoutSeconds -DefaultValue 600 -Min 1 -Max 86400
    $promptEntries = @(Get-PromptSegments -Text ([System.IO.File]::ReadAllText($promptListFile, [System.Text.UTF8Encoding]::new($false))))
    $promptCount = $promptEntries.Count
    if ($promptCount -eq 0) { throw $Ui.PromptEmpty }
    $preview = @($promptEntries | Select-Object -First 3 | ForEach-Object {
        $line = ([string]$_ -replace '\s+', ' ').Trim()
        if ($line.Length -gt 60) { $line.Substring(0, 57) + '...' } else { $line }
    }) -join ' | '
    $parseOnly = Read-YesNo -PromptLabel $Ui.ParseOnly -DefaultValue $false
    $failurePolicy = Read-WorkflowOptionValue `
        -Title $Ui.BatchFailurePolicy `
        -Values @('Continue', 'Stop') `
        -Labels @($Ui.BatchFailureContinue, $Ui.BatchFailureStop) `
        -CurrentValue 'Continue'
    if ($null -eq $failurePolicy) { return }
    $resumeStatePath = ""
    if (-not $parseOnly) {
        $latestState = Get-LatestIncompletePromptBatchState -OutputRoot $outputRoot -PromptFile $promptListFile
        if ($latestState -and (Read-YesNo -PromptLabel ("{0}: {1}" -f $Ui.ResumePromptBatch, (Get-RelativeWorkflowPath -Path $latestState)) -DefaultValue $true)) {
            $resumeStatePath = $latestState
        }
    }

    if (-not (Confirm-WorkflowRun -Kind "Prompt list batch" -Details @{
        PromptFile = $promptListFile
        PromptCount = $promptCount
        Preview = $preview
        ParseOnly = $parseOnly
        FailurePolicy = $failurePolicy
        ResumeState = $resumeStatePath
        Workspace = $workspacePath
        Output = $outputRoot
        Model = (Get-WorkflowPrimaryProfileModel -Kind Text)
        TimeoutSeconds = $timeout
    })) { return }

    $parameters = @{
        PromptListFile = $promptListFile
        Workspace = $workspacePath
        OutputRoot = $outputRoot
        RunName = $runName
        Model = ""
        TimeoutSeconds = $timeout
        NoReopenWindow = $true
    }
    if ($parseOnly) { $parameters.ParseOnly = $true }
    if (-not [string]::IsNullOrWhiteSpace($resumeStatePath)) { $parameters.ResumeBatchStatePath = $resumeStatePath }
    $parameters.BatchFailurePolicy = $failurePolicy
    Add-WorkflowTextApiParameters -Parameters $parameters
    Invoke-WorkflowScript -ScriptPath $invokeScript -Parameters $parameters
}

function Invoke-ConversationBatchAction {
    $workspacePath = Resolve-UserPath -Path $Workspace -MustExist
    $outputRoot = Resolve-UserPath -Path $DefaultOutputRoot
    $selection = Select-ConversationBatchState -OutputRoot $outputRoot
    if ($null -eq $selection) { return }

    $resumeStatePath = ""
    $summaryPromptFile = ""
    $runName = ""
    $completedOperations = 0
    if ($selection.IsNew) {
        $conversationFile = Read-ExistingPath -PromptLabel $Ui.ConversationFile -DefaultValue $conversationExampleDefault
        $runName = Read-TextValue -PromptLabel $Ui.RunNameOptional -DefaultValue ""
        $summaryPromptValue = Read-TextValue -PromptLabel $Ui.SummaryPromptFileOptional -DefaultValue ""
        if (-not [string]::IsNullOrWhiteSpace($summaryPromptValue)) {
            $summaryPromptFile = Resolve-UserPath -Path $summaryPromptValue -MustExist
        }
    }
    else {
        $resumeItem = $selection.Item
        $resumeStatePath = [string]$resumeItem.Path
        if (Test-Path -LiteralPath $resumeItem.SnapshotPath -PathType Leaf) {
            $conversationFile = [string]$resumeItem.SnapshotPath
        }
        elseif (Test-Path -LiteralPath ([string]$resumeItem.State.ConversationFile) -PathType Leaf) {
            $conversationFile = [string]$resumeItem.State.ConversationFile
        }
        else {
            throw "Conversation source and saved snapshot are both missing."
        }
        $completedOperations = [int]$resumeItem.State.CompletedOperations
    }

    $conversationText = [System.IO.File]::ReadAllText($conversationFile, [System.Text.UTF8Encoding]::new($false))
    $groups = @(Get-WorkflowConversationGroups -Text $conversationText)
    $promptCount = [int](($groups | ForEach-Object { $_.Prompts.Count } | Measure-Object -Sum).Sum)
    $totalOperations = $promptCount + $groups.Count
    $remainingOperations = [Math]::Max(0, $totalOperations - $completedOperations)
    $timeout = ConvertTo-WorkflowInt -Value $WorkflowConfig.TimeoutSeconds -DefaultValue 600 -Min 1 -Max 86400

    if (-not (Confirm-WorkflowRun -Kind "Conversation batch" -Details @{
        ConversationFile = $conversationFile
        ResumeState = $resumeStatePath
        Groups = $groups.Count
        Prompts = $promptCount
        CompletedOperations = $completedOperations
        RemainingOperations = $remainingOperations
        SummaryPromptFile = $summaryPromptFile
        Workspace = $workspacePath
        Output = $outputRoot
        Model = (Get-WorkflowPrimaryProfileModel -Kind Text)
        TimeoutSeconds = $timeout
    })) { return }

    $parameters = @{
        ConversationFile = $conversationFile
        Workspace = $workspacePath
        OutputRoot = $outputRoot
        RunName = $runName
        Model = ""
        TimeoutSeconds = $timeout
    }
    if (-not [string]::IsNullOrWhiteSpace($resumeStatePath)) {
        $parameters.ResumeStatePath = $resumeStatePath
    }
    if (-not [string]::IsNullOrWhiteSpace($summaryPromptFile)) {
        $parameters.SummaryPromptFile = $summaryPromptFile
    }
    Add-WorkflowTextApiParameters -Parameters $parameters

    Invoke-WorkflowScript -ScriptPath $conversationScript -Parameters $parameters
}

function Invoke-SingleImageAction {
    $workspacePath = Resolve-UserPath -Path $Workspace -MustExist
    $outputRoot = Resolve-UserPath -Path $DefaultImageRoot
    $defaultImagePath = [System.IO.Path]::ChangeExtension($singleImageOutputDefault, (Get-WorkflowImageFormatExtension -Format ([string]$WorkflowConfig.ImageFormat)))
    $imageOutputPath = Read-WorkflowImageOutputPath -DefaultValue $defaultImagePath -Format ([string]$WorkflowConfig.ImageFormat)
    $runName = Read-TextValue -PromptLabel $Ui.RunNameOptional -DefaultValue ""
    $openImage = Read-YesNo -PromptLabel $Ui.OpenImage -DefaultValue $false
    $openImageFolder = Read-YesNo -PromptLabel $Ui.OpenImageFolder -DefaultValue $false
    $attempts = ConvertTo-WorkflowInt -Value $WorkflowConfig.MaxAttempts -DefaultValue 6 -Min 1 -Max 20
    $retryBase = ConvertTo-WorkflowInt -Value $WorkflowConfig.RetryBaseDelaySeconds -DefaultValue 2 -Min 1 -Max 300
    $retryMax = ConvertTo-WorkflowInt -Value $WorkflowConfig.RetryMaxDelaySeconds -DefaultValue 20 -Min 1 -Max 600
    $imageTimeout = ConvertTo-WorkflowInt -Value $WorkflowConfig.ImageRequestTimeoutSeconds -DefaultValue 600 -Min 1 -Max 86400
    $imageTotalTimeout = ConvertTo-WorkflowInt -Value $WorkflowConfig.ImageTotalTimeoutSeconds -DefaultValue 1800 -Min 1 -Max 86400
    $imageProfile = (New-WorkflowApiExecutionProfiles -Kind Image)[0]
    $promptText = Read-MultilinePrompt

    if (-not (Confirm-WorkflowRun -Kind "Single image" -Details @{
        Output = $imageOutputPath
        Workspace = $workspacePath
        Model = [string]$imageProfile.Model
        ApiProfile = [string]$imageProfile.Name
        ImageAspectRatio = (Get-WorkflowImageOptionDisplayValue -Kind AspectRatio -Value ([string]$WorkflowConfig.ImageAspectRatio))
        ImageSize = (Get-WorkflowImageOptionDisplayValue -Kind Size -Value ([string]$WorkflowConfig.ImageSize))
        ImageQuality = (Get-WorkflowImageOptionDisplayValue -Kind Quality -Value ([string]$WorkflowConfig.ImageQuality))
        ImageFormat = (Get-WorkflowImageOptionDisplayValue -Kind Format -Value ([string]$WorkflowConfig.ImageFormat))
        MaxAttempts = $attempts
        RequestTimeoutSeconds = $imageTimeout
        TotalTimeoutSeconds = $imageTotalTimeout
        OpenImage = $openImage
        OpenFolder = $openImageFolder
    })) { return }

    $parameters = @{
        Prompt = $promptText
        Workspace = $workspacePath
        OutputRoot = $outputRoot
        RunName = $runName
        GenerateImage = $true
        Model = ""
        ImageOutputPath = $imageOutputPath
        ImageMaxAttempts = $attempts
        ImageRetryBaseDelaySeconds = $retryBase
        ImageRetryMaxDelaySeconds = $retryMax
        ImageRequestTimeoutSeconds = $imageTimeout
        ImageTotalTimeoutSeconds = $imageTotalTimeout
        NoReopenWindow = $true
    }
    if ($openImage) { $parameters.OpenResult = $true }
    if ($openImageFolder) { $parameters.OpenResultFolder = $true }
    Add-WorkflowImageApiParameters -Parameters $parameters
    Invoke-WorkflowScript -ScriptPath $invokeScript -Parameters $parameters
}

function Invoke-ImageBatchAction {
    $promptFile = Read-ExistingPath -PromptLabel $Ui.PromptBatchFile -DefaultValue $promptBatchDefault
    $outputRoot = Resolve-UserPath -Path $DefaultImageRoot
    $maxConcurrency = ConvertTo-WorkflowInt -Value $WorkflowConfig.MaxConcurrency -DefaultValue 2 -Min 1 -Max 20
    $attempts = ConvertTo-WorkflowInt -Value $WorkflowConfig.MaxAttempts -DefaultValue 6 -Min 1 -Max 20
    $retryBase = ConvertTo-WorkflowInt -Value $WorkflowConfig.RetryBaseDelaySeconds -DefaultValue 2 -Min 1 -Max 300
    $retryMax = ConvertTo-WorkflowInt -Value $WorkflowConfig.RetryMaxDelaySeconds -DefaultValue 20 -Min 1 -Max 600
    $imageTimeout = ConvertTo-WorkflowInt -Value $WorkflowConfig.ImageRequestTimeoutSeconds -DefaultValue 600 -Min 1 -Max 86400
    $imageTotalTimeout = ConvertTo-WorkflowInt -Value $WorkflowConfig.ImageTotalTimeoutSeconds -DefaultValue 1800 -Min 1 -Max 86400
    $waitForCompletion = ConvertTo-WorkflowBool -Value $WorkflowConfig.WaitInTerminal -DefaultValue $true
    $promptText = [System.IO.File]::ReadAllText($promptFile, [System.Text.UTF8Encoding]::new($false))
    $promptSegments = @(Get-PromptSegments -Text $promptText)
    $promptCount = $promptSegments.Count
    $referencePromptCount = @($promptSegments | Where-Object { $_ -match '!\[[^\]]*\]\([^)]+\)|<img\b[^>]*\bsrc\s*=' }).Count
    $imageApiProfileCount = @(New-WorkflowApiExecutionProfiles -Kind Image).Count
    $imageApiProfileStrategy = if ($imageApiProfileCount -gt 1) { "{0} (round-robin)" -f $imageApiProfileCount } else { [string]$imageApiProfileCount }

    if (-not (Confirm-WorkflowRun -Kind "Image batch" -Details @{
        PromptFile = $promptFile
        PromptCount = $promptCount
        Output = $outputRoot
        Model = (Get-WorkflowPrimaryProfileModel -Kind Image)
        ImageApiProfiles = $imageApiProfileStrategy
        ImageAspectRatio = (Get-WorkflowImageOptionDisplayValue -Kind AspectRatio -Value ([string]$WorkflowConfig.ImageAspectRatio))
        ImageSize = (Get-WorkflowImageOptionDisplayValue -Kind Size -Value ([string]$WorkflowConfig.ImageSize))
        ImageQuality = (Get-WorkflowImageOptionDisplayValue -Kind Quality -Value ([string]$WorkflowConfig.ImageQuality))
        ImageFormat = (Get-WorkflowImageOptionDisplayValue -Kind Format -Value ([string]$WorkflowConfig.ImageFormat))
        ReferenceImagePrompts = $referencePromptCount
        AspectRatioNotice = $(if ($referencePromptCount -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$WorkflowConfig.ImageAspectRatio)) { $Ui.ReferenceAspectRatioIgnored } else { '' })
        MaxConcurrency = $maxConcurrency
        RequestTimeoutSeconds = $imageTimeout
        TotalTimeoutSeconds = $imageTotalTimeout
        Wait = $waitForCompletion
    })) { return }

    $parameters = @{
        PromptFile = $promptFile
        OutputRoot = $outputRoot
        Model = ""
        MaxConcurrency = $maxConcurrency
        ImageMaxAttempts = $attempts
        ImageRetryBaseDelaySeconds = $retryBase
        ImageRetryMaxDelaySeconds = $retryMax
        ImageRequestTimeoutSeconds = $imageTimeout
        ImageTotalTimeoutSeconds = $imageTotalTimeout
    }
    if ($waitForCompletion) {
        $parameters.Wait = $true
    }
    Add-WorkflowImageApiParameters -Parameters $parameters

    if ($waitForCompletion) {
        Invoke-WorkflowScript -ScriptPath $imageBatchScript -Parameters $parameters
    }
    else {
        $background = Invoke-WorkflowScript -ScriptPath $imageBatchScript -Parameters $parameters -NoWait
        Write-Host ($Ui.BackgroundSchedulerStarted -f $background.ProcessId) -ForegroundColor Green
    }
}

function Get-WorkflowImageBatchStates {
    param(
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $true)][string[]]$Statuses
    )

    $resolved = Resolve-UserPath -Path $OutputRoot
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { return @() }
    $states = New-Object System.Collections.Generic.List[object]
    foreach ($stateFile in @(Get-ChildItem -LiteralPath $resolved -Recurse -File -Filter batch_state.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try {
            $state = [System.IO.File]::ReadAllText($stateFile.FullName, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -ErrorAction Stop
            if ([string]$state.Status -notin $Statuses) { continue }
            [void]$states.Add([pscustomobject]@{
                Path = $stateFile.FullName
                State = $state
                Display = ("{0} | ok {1} fail {2} pending {3} | {4}" -f [string]$state.Status, [int]$state.SuccessCount, [int]$state.FailedCount, [int]$state.PendingCount, (Get-RelativeWorkflowPath -Path $stateFile.FullName))
            })
        }
        catch {
        }
    }
    return @($states.ToArray())
}

function Select-WorkflowImageBatchState {
    param(
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [Parameter(Mandatory = $true)][string[]]$Statuses
    )

    $states = @(Get-WorkflowImageBatchStates -OutputRoot $OutputRoot -Statuses $Statuses)
    if ($states.Count -eq 0) {
        Write-Host $Ui.ImageBatchNoStates -ForegroundColor Yellow
        return $null
    }
    $items = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $states.Count; $i++) { [void]$items.Add([pscustomobject]@{ Choice = $i + 1; Text = [string]$states[$i].Display }) }
    [void]$items.Add([pscustomobject]@{ Choice = 0; Text = $Ui.BackMenu0 })
    $choice = Read-MenuChoice -Items @($items.ToArray()) -Title $Ui.ImageBatchStateTitle -Hint $Ui.SubMenuHint -ControlZReturns
    if ($choice -le 0) { return $null }
    return $states[$choice - 1]
}

function New-WorkflowImageBatchParameters {
    param(
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$OutputRoot,
        [bool]$WaitForCompletion,
        [AllowEmptyString()][string]$ResumeStatePath = '',
        [switch]$RetryFailed
    )

    $parameters = @{
        PromptFile = $PromptFile
        OutputRoot = $OutputRoot
        Model = ''
        MaxConcurrency = ConvertTo-WorkflowInt -Value $WorkflowConfig.MaxConcurrency -DefaultValue 2 -Min 1 -Max 20
        ImageMaxAttempts = ConvertTo-WorkflowInt -Value $WorkflowConfig.MaxAttempts -DefaultValue 6 -Min 1 -Max 20
        ImageRetryBaseDelaySeconds = ConvertTo-WorkflowInt -Value $WorkflowConfig.RetryBaseDelaySeconds -DefaultValue 2 -Min 1 -Max 300
        ImageRetryMaxDelaySeconds = ConvertTo-WorkflowInt -Value $WorkflowConfig.RetryMaxDelaySeconds -DefaultValue 20 -Min 1 -Max 600
        ImageRequestTimeoutSeconds = ConvertTo-WorkflowInt -Value $WorkflowConfig.ImageRequestTimeoutSeconds -DefaultValue 600 -Min 1 -Max 86400
        ImageTotalTimeoutSeconds = ConvertTo-WorkflowInt -Value $WorkflowConfig.ImageTotalTimeoutSeconds -DefaultValue 1800 -Min 1 -Max 86400
    }
    if ($WaitForCompletion) { $parameters.Wait = $true }
    if (-not [string]::IsNullOrWhiteSpace($ResumeStatePath)) { $parameters.ResumeStatePath = $ResumeStatePath }
    if ($RetryFailed) { $parameters.RetryFailed = $true }
    Add-WorkflowImageApiParameters -Parameters $parameters
    return $parameters
}

function Invoke-RetryFailedImageBatchAction {
    $outputRoot = Resolve-UserPath -Path $DefaultImageRoot
    $selected = Select-WorkflowImageBatchState -OutputRoot $outputRoot -Statuses @('failed')
    if ($null -eq $selected) { return }
    $promptFile = [string]$selected.State.SourcePath
    if (-not (Test-Path -LiteralPath $promptFile -PathType Leaf)) { throw ($Ui.PathNotFound -f $promptFile) }
    $waitForCompletion = Read-YesNo -PromptLabel $Ui.WaitInTerminal -DefaultValue (ConvertTo-WorkflowBool -Value $WorkflowConfig.WaitInTerminal -DefaultValue $true)
    $parameters = New-WorkflowImageBatchParameters -PromptFile $promptFile -OutputRoot $outputRoot -WaitForCompletion $waitForCompletion -ResumeStatePath ([string]$selected.Path) -RetryFailed
    if (-not (Confirm-WorkflowRun -Kind 'Retry failed image batch' -Details @{ State = $selected.Path; Failed = [int]$selected.State.FailedCount; MaxConcurrency = $parameters.MaxConcurrency; Wait = $waitForCompletion })) { return }
    if ($waitForCompletion) {
        Invoke-WorkflowScript -ScriptPath $imageBatchScript -Parameters $parameters
    }
    else {
        $background = Invoke-WorkflowScript -ScriptPath $imageBatchScript -Parameters $parameters -NoWait
        Write-Host ($Ui.BackgroundSchedulerStarted -f $background.ProcessId) -ForegroundColor Green
    }
}

function Invoke-CancelImageBatchAction {
    $outputRoot = Resolve-UserPath -Path $DefaultImageRoot
    $selected = Select-WorkflowImageBatchState -OutputRoot $outputRoot -Statuses @('running', 'cancel_requested')
    if ($null -eq $selected) { return }
    $state = $selected.State
    $state.Status = 'cancel_requested'
    $state.UpdatedAt = (Get-Date).ToString('o')
    [System.IO.File]::WriteAllText(([string]$selected.Path + '.cancel'), $state.UpdatedAt, [System.Text.UTF8Encoding]::new($false))
    $temporaryPath = [string]$selected.Path + '.tmp'
    [System.IO.File]::WriteAllText($temporaryPath, ($state | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $selected.Path -Force
    Write-Host ($Ui.ImageBatchCancelRequested -f (Get-RelativeWorkflowPath -Path $selected.Path)) -ForegroundColor Yellow
}

function Invoke-BatchMenu {
    $batchChoice = Read-MenuChoice -Items (Get-BatchMenuItems) -Title $Ui.Menu2 -Hint $Ui.SubMenuHint -ControlZReturns
    switch ($batchChoice) {
        1 {
            $script:WorkflowLastActionExecuted = $true
            Invoke-PromptFileAction
        }
        2 {
            $script:WorkflowLastActionExecuted = $true
            Invoke-PromptListBatchAction
        }
        3 {
            $script:WorkflowLastActionExecuted = $true
            Invoke-ConversationBatchAction
        }
    }
}

function Invoke-ImageMenu {
    $imageChoice = Read-MenuChoice -Items (Get-ImageMenuItems) -Title $Ui.Menu3 -Hint $Ui.SubMenuHint -ControlZReturns
    switch ($imageChoice) {
        1 {
            $script:WorkflowLastActionExecuted = $true
            Invoke-SingleImageAction
        }
        2 {
            $script:WorkflowLastActionExecuted = $true
            Invoke-ImageBatchAction
        }
        3 {
            $script:WorkflowLastActionExecuted = $true
            Invoke-RetryFailedImageBatchAction
        }
        4 {
            $script:WorkflowLastActionExecuted = $true
            Invoke-CancelImageBatchAction
        }
    }
}

function ConvertTo-WorkflowHistoryInt64 {
    param([object]$Value)

    $number = 0L
    if ($null -ne $Value -and [long]::TryParse(([string]$Value).Trim(), [ref]$number)) {
        return $number
    }

    return 0L
}

function Get-WorkflowHistoryProperty {
    param(
        [AllowNull()]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Get-WorkflowHistoryUsageValue {
    param(
        [AllowNull()]
        [object]$Usage,
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $value = Get-WorkflowHistoryProperty -Object $Usage -Name $name
        if ($null -ne $value) {
            return (ConvertTo-WorkflowHistoryInt64 -Value $value)
        }
    }

    return 0L
}

function Get-WorkflowSummaryUsage {
    param(
        [AllowEmptyString()]
        [string]$RunDirectory
    )

    $usage = [ordered]@{
        InputTokens = 0L
        CachedInputTokens = 0L
        OutputTokens = 0L
        ReasoningOutputTokens = 0L
    }

    if ([string]::IsNullOrWhiteSpace($RunDirectory)) {
        return [pscustomobject]$usage
    }

    $summaryPath = Join-Path $RunDirectory 'summary.md'
    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
        return [pscustomobject]$usage
    }

    $summaryText = [System.IO.File]::ReadAllText($summaryPath, [System.Text.UTF8Encoding]::new($false))
    $patterns = @{
        InputTokens = '(?mi)^\s*-\s*Input tokens:\s*([0-9,]+)\s*$'
        CachedInputTokens = '(?mi)^\s*-\s*Cached input tokens:\s*([0-9,]+)\s*$'
        OutputTokens = '(?mi)^\s*-\s*Output tokens:\s*([0-9,]+)\s*$'
        ReasoningOutputTokens = '(?mi)^\s*-\s*Reasoning output tokens:\s*([0-9,]+)\s*$'
    }

    foreach ($key in $patterns.Keys) {
        $match = [regex]::Match($summaryText, $patterns[$key])
        if ($match.Success) {
            $usage[$key] = ConvertTo-WorkflowHistoryInt64 -Value ($match.Groups[1].Value -replace ',', '')
        }
    }

    return [pscustomobject]$usage
}

function Get-WorkflowRunHistory {
    $indexPath = Join-Path $scriptRoot 'runs\index.jsonl'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        return @()
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($line in [System.IO.File]::ReadLines($indexPath, [System.Text.UTF8Encoding]::new($false))) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }

        $startedAt = [datetime]::MinValue
        $finishedAt = [datetime]::MinValue
        [void][datetime]::TryParse([string](Get-WorkflowHistoryProperty -Object $entry -Name 'startedAt'), [ref]$startedAt)
        [void][datetime]::TryParse([string](Get-WorkflowHistoryProperty -Object $entry -Name 'finishedAt'), [ref]$finishedAt)
        $durationSeconds = if ($startedAt -ne [datetime]::MinValue -and $finishedAt -ne [datetime]::MinValue) {
            [Math]::Max(0, ($finishedAt - $startedAt).TotalSeconds)
        }
        else {
            0
        }

        $usageObject = Get-WorkflowHistoryProperty -Object $entry -Name 'usage'
        $summaryUsage = Get-WorkflowSummaryUsage -RunDirectory ([string](Get-WorkflowHistoryProperty -Object $entry -Name 'runDirectory'))
        $inputTokens = Get-WorkflowHistoryUsageValue -Usage $usageObject -Names @('input_tokens', 'inputTokens')
        $cachedInputTokens = Get-WorkflowHistoryUsageValue -Usage $usageObject -Names @('cached_input_tokens', 'cachedInputTokens')
        $outputTokens = Get-WorkflowHistoryUsageValue -Usage $usageObject -Names @('output_tokens', 'outputTokens')
        $reasoningTokens = Get-WorkflowHistoryUsageValue -Usage $usageObject -Names @('reasoning_output_tokens', 'reasoningOutputTokens')

        if ($inputTokens -eq 0) { $inputTokens = [long]$summaryUsage.InputTokens }
        if ($cachedInputTokens -eq 0) { $cachedInputTokens = [long]$summaryUsage.CachedInputTokens }
        if ($outputTokens -eq 0) { $outputTokens = [long]$summaryUsage.OutputTokens }
        if ($reasoningTokens -eq 0) { $reasoningTokens = [long]$summaryUsage.ReasoningOutputTokens }

        [void]$entries.Add([pscustomobject]@{
            Type = [string](Get-WorkflowHistoryProperty -Object $entry -Name 'type')
            Status = [string](Get-WorkflowHistoryProperty -Object $entry -Name 'status')
            Model = [string](Get-WorkflowHistoryProperty -Object $entry -Name 'model')
            Name = [string](Get-WorkflowHistoryProperty -Object $entry -Name 'name')
            StartedAt = $startedAt
            FinishedAt = $finishedAt
            DurationSeconds = $durationSeconds
            InputTokens = $inputTokens
            CachedInputTokens = $cachedInputTokens
            OutputTokens = $outputTokens
            ReasoningOutputTokens = $reasoningTokens
            TotalTokens = ($inputTokens + $outputTokens)
        })
    }

    return @($entries.ToArray())
}

function Format-WorkflowStatNumber {
    param([double]$Value)
    return ("{0:N0}" -f $Value)
}

function Format-WorkflowStatDuration {
    param([double]$Seconds)

    $duration = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    if ($duration.TotalHours -ge 1) {
        return ("{0:00}:{1:00}:{2:00}" -f [Math]::Floor($duration.TotalHours), $duration.Minutes, $duration.Seconds)
    }

    return ("{0:00}:{1:00}" -f $duration.Minutes, $duration.Seconds)
}

function Format-WorkflowStatPercent {
    param(
        [double]$Numerator,
        [double]$Denominator
    )

    if ($Denominator -le 0) {
        return "0.0%"
    }

    return ("{0:N1}%" -f (($Numerator / $Denominator) * 100))
}

function Format-WorkflowStatCell {
    param(
        [AllowNull()]
        [object]$Value,
        [int]$Width,
        [ValidateSet('Left', 'Right')]
        [string]$Align = 'Left'
    )

    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    $text = $text -replace "\s+", " "
    $text = Format-WorkflowDisplayText -Text $text -MaxWidth $Width
    $padding = [Math]::Max(0, $Width - (Get-WorkflowDisplayWidth -Text $text))

    if ($Align -eq 'Right') {
        return ((" " * $padding) + $text)
    }

    return ($text + (" " * $padding))
}

function Get-WorkflowStatsViewportWidth {
    try {
        if (-not [Console]::IsOutputRedirected) {
            return [Math]::Max(28, [Math]::Min(96, [Console]::WindowWidth - 1))
        }
    }
    catch {
    }

    return 78
}

function Write-WorkflowStatsText {
    param(
        [AllowEmptyString()]
        [string]$Text = "",
        [int]$Width = 0,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,
        [switch]$Fill,
        [switch]$Highlight
    )

    if ($Width -le 0) {
        $Width = Get-WorkflowStatsViewportWidth
    }

    $line = Format-WorkflowDisplayText -Text $Text -MaxWidth $Width
    if ($Fill -or $Highlight) {
        $line = Pad-WorkflowDisplayRight -Text $line -Width $Width
    }

    if ($Highlight) {
        Write-Host $line -ForegroundColor Black -BackgroundColor Green
    }
    else {
        Write-Host $line -ForegroundColor $ForegroundColor
    }
}

function Write-WorkflowStatsHeader {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Columns,
        [int]$Width = 78
    )

    $line = (($Columns | ForEach-Object { Format-WorkflowStatCell -Value $_.Name -Width $_.Width -Align $(if ($_.Align) { $_.Align } else { 'Left' }) }) -join "  ")
    $line = Pad-WorkflowDisplayRight -Text $line -Width $Width
    Write-Host $line -ForegroundColor Black -BackgroundColor DarkCyan
}

function Write-WorkflowStatsRow {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Columns,
        [Parameter(Mandatory = $true)]
        [object[]]$Values,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,
        [int]$Width = 78
    )

    $cells = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $value = if ($i -lt $Values.Count) { $Values[$i] } else { "" }
        $align = if ($Columns[$i].Align) { [string]$Columns[$i].Align } else { "Left" }
        [void]$cells.Add((Format-WorkflowStatCell -Value $value -Width ([int]$Columns[$i].Width) -Align $align))
    }

    $line = $cells.ToArray() -join "  "
    $line = Pad-WorkflowDisplayRight -Text $line -Width $Width
    Write-Host $line -ForegroundColor $ForegroundColor
}

function Write-WorkflowHtopBar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [double]$Value,
        [double]$MaxValue,
        [ConsoleColor]$Color = [ConsoleColor]::Green,
        [string]$Suffix = "",
        [int]$ViewportWidth = 0
    )

    if ($ViewportWidth -le 0) {
        $ViewportWidth = Get-WorkflowStatsViewportWidth
    }

    $labelWidth = if ($ViewportWidth -ge 58) { 14 } else { 10 }
    $valueWidth = if ($ViewportWidth -ge 52) { 10 } else { 7 }
    $showPercent = $ViewportWidth -ge 48
    $suffixWidth = Get-WorkflowDisplayWidth -Text $Suffix
    $fixedWidth = $labelWidth + $valueWidth + $suffixWidth + $(if ($showPercent) { 11 } else { 4 })
    $width = [Math]::Max(6, [Math]::Min(28, $ViewportWidth - $fixedWidth))
    $ratio = if ($MaxValue -gt 0) { [Math]::Min(1.0, [Math]::Max(0.0, $Value / $MaxValue)) } else { 0.0 }
    $scaled = $ratio * $width
    $filled = [int][Math]::Floor($scaled)
    $hasPartial = $ratio -gt 0 -and $filled -lt $width -and ($scaled - $filled) -gt 0.0001
    $empty = $width - $filled - $(if ($hasPartial) { 1 } else { 0 })

    $labelText = Format-WorkflowStatCell -Value $Label -Width $labelWidth
    Write-Host -NoNewline ($labelText + "[") -ForegroundColor Cyan
    if ($filled -gt 0) {
        Write-Host -NoNewline ("|" * $filled) -ForegroundColor $Color
    }
    if ($hasPartial) {
        Write-Host -NoNewline ":" -ForegroundColor $Color
    }
    if ($empty -gt 0) {
        Write-Host -NoNewline ("-" * $empty) -ForegroundColor DarkGray
    }
    if ($showPercent) {
        Write-Host ("] {0,$valueWidth} {1,7}{2}" -f (Format-WorkflowStatNumber -Value $Value), (Format-WorkflowStatPercent -Numerator $Value -Denominator $MaxValue), $Suffix) -ForegroundColor Gray
    }
    else {
        Write-Host ("] {0,$valueWidth}{1}" -f (Format-WorkflowStatNumber -Value $Value), $Suffix) -ForegroundColor Gray
    }
}

function Get-WorkflowStatsData {
    param([object[]]$History = @())

    $historyItems = @($History)
    $totalTokens = [double](($historyItems | Measure-Object -Property TotalTokens -Sum).Sum)
    $inputTokens = [double](($historyItems | Measure-Object -Property InputTokens -Sum).Sum)
    $cachedTokens = [double](($historyItems | Measure-Object -Property CachedInputTokens -Sum).Sum)
    $outputTokens = [double](($historyItems | Measure-Object -Property OutputTokens -Sum).Sum)
    $reasoningTokens = [double](($historyItems | Measure-Object -Property ReasoningOutputTokens -Sum).Sum)
    $totalSeconds = [double](($historyItems | Measure-Object -Property DurationSeconds -Sum).Sum)
    $successCount = @($historyItems | Where-Object { $_.Status -eq 'success' }).Count
    $failedCount = @($historyItems | Where-Object { $_.Status -eq 'failed' }).Count
    $now = Get-Date
    $todayHistory = @($historyItems | Where-Object { $_.FinishedAt -ge $now.Date })
    $dayHistory = @($historyItems | Where-Object { $_.FinishedAt -ge $now.AddHours(-24) })
    $todayTokens = [double](($todayHistory | Measure-Object -Property TotalTokens -Sum).Sum)
    $dayTokens = [double](($dayHistory | Measure-Object -Property TotalTokens -Sum).Sum)
    $avgTokens = if ($historyItems.Count -gt 0) { $totalTokens / $historyItems.Count } else { 0 }
    $avgSeconds = if ($historyItems.Count -gt 0) { $totalSeconds / $historyItems.Count } else { 0 }
    $fastestSeconds = ($historyItems | Where-Object { $_.DurationSeconds -gt 0 } | Measure-Object -Property DurationSeconds -Minimum).Minimum
    if ($null -eq $fastestSeconds) { $fastestSeconds = 0 }
    $slowestSeconds = ($historyItems | Measure-Object -Property DurationSeconds -Maximum).Maximum
    if ($null -eq $slowestSeconds) { $slowestSeconds = 0 }

    return [pscustomobject]@{
        History = $historyItems
        TotalTokens = $totalTokens
        InputTokens = $inputTokens
        CachedTokens = $cachedTokens
        OutputTokens = $outputTokens
        ReasoningTokens = $reasoningTokens
        TotalSeconds = $totalSeconds
        SuccessCount = $successCount
        FailedCount = $failedCount
        SuccessRate = Format-WorkflowStatPercent -Numerator $successCount -Denominator $historyItems.Count
        CacheRate = Format-WorkflowStatPercent -Numerator $cachedTokens -Denominator $inputTokens
        TodayTokens = $todayTokens
        TodayRuns = $todayHistory.Count
        DayTokens = $dayTokens
        DayRuns = $dayHistory.Count
        AverageTokens = $avgTokens
        AverageSeconds = $avgSeconds
        FastestSeconds = [double]$fastestSeconds
        SlowestSeconds = [double]$slowestSeconds
    }
}

function Get-WorkflowStatsTableData {
    param(
        [ValidateSet('Type', 'Model', 'Recent')]
        [string]$View,
        [Parameter(Mandatory = $true)]
        [object]$Data,
        [int]$Width
    )

    $columns = @()
    $rows = New-Object System.Collections.Generic.List[object]

    if ($View -eq 'Type') {
        if ($Width -ge 78) {
            $columns = @(
                [pscustomobject]@{ Name = $Ui.StatsColumnType; Width = 12; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnRuns; Width = 5; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnOk; Width = 4; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnFail; Width = 5; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTokens; Width = 10; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnInput; Width = 10; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnOutput; Width = 10; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTime; Width = 8; Align = 'Right' }
            )
        }
        elseif ($Width -ge 58) {
            $columns = @(
                [pscustomobject]@{ Name = $Ui.StatsColumnType; Width = 12; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnRuns; Width = 5; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnOk; Width = 5; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnFail; Width = 5; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTokens; Width = 10; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTime; Width = 8; Align = 'Right' }
            )
        }
        else {
            $typeWidth = [Math]::Max(8, $Width - 18)
            $columns = @(
                [pscustomobject]@{ Name = $Ui.StatsColumnType; Width = $typeWidth; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnRuns; Width = 5; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTokens; Width = 9; Align = 'Right' }
            )
        }

        foreach ($group in @($Data.History | Group-Object Type | Sort-Object Count -Descending)) {
            $items = @($group.Group)
            $typeName = if ([string]::IsNullOrWhiteSpace($group.Name)) { $Ui.StatsUnknown } else { $group.Name }
            $tokens = [double](($items | Measure-Object TotalTokens -Sum).Sum)
            $input = [double](($items | Measure-Object InputTokens -Sum).Sum)
            $output = [double](($items | Measure-Object OutputTokens -Sum).Sum)
            $duration = [double](($items | Measure-Object DurationSeconds -Sum).Sum)
            $values = if ($Width -ge 78) {
                @($typeName, $items.Count, @($items | Where-Object { $_.Status -eq 'success' }).Count, @($items | Where-Object { $_.Status -eq 'failed' }).Count, ("{0:N0}" -f $tokens), ("{0:N0}" -f $input), ("{0:N0}" -f $output), (Format-WorkflowStatDuration -Seconds $duration))
            }
            elseif ($Width -ge 58) {
                @($typeName, $items.Count, @($items | Where-Object { $_.Status -eq 'success' }).Count, @($items | Where-Object { $_.Status -eq 'failed' }).Count, ("{0:N0}" -f $tokens), (Format-WorkflowStatDuration -Seconds $duration))
            }
            else {
                @($typeName, $items.Count, ("{0:N0}" -f $tokens))
            }
            [void]$rows.Add([pscustomobject]@{ Values = $values; Color = [ConsoleColor]::Gray })
        }
    }
    elseif ($View -eq 'Model') {
        if ($Width -ge 78) {
            $fullModelWidth = [Math]::Max(15, [Math]::Min(20, $Width - 63))
            $columns = @(
                [pscustomobject]@{ Name = $Ui.StatsColumnModel; Width = $fullModelWidth; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnRuns; Width = 5; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTokens; Width = 10; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnInput; Width = 10; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnOutput; Width = 10; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnAverage; Width = 8; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTime; Width = 8; Align = 'Right' }
            )
        }
        elseif ($Width -ge 58) {
            $columns = @(
                [pscustomobject]@{ Name = $Ui.StatsColumnModel; Width = 18; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnRuns; Width = 5; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTokens; Width = 10; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnAverage; Width = 8; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTime; Width = 8; Align = 'Right' }
            )
        }
        else {
            $modelWidth = [Math]::Max(10, $Width - 18)
            $columns = @(
                [pscustomobject]@{ Name = $Ui.StatsColumnModel; Width = $modelWidth; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnRuns; Width = 5; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTokens; Width = 9; Align = 'Right' }
            )
        }

        foreach ($group in @($Data.History | Group-Object Model | Sort-Object Count -Descending)) {
            $items = @($group.Group)
            $modelName = if ([string]::IsNullOrWhiteSpace($group.Name)) { $Ui.StatsDefaultModel } else { $group.Name }
            $tokens = [double](($items | Measure-Object TotalTokens -Sum).Sum)
            $input = [double](($items | Measure-Object InputTokens -Sum).Sum)
            $output = [double](($items | Measure-Object OutputTokens -Sum).Sum)
            $duration = [double](($items | Measure-Object DurationSeconds -Sum).Sum)
            $average = if ($items.Count -gt 0) { $tokens / $items.Count } else { 0 }
            $values = if ($Width -ge 78) {
                @($modelName, $items.Count, ("{0:N0}" -f $tokens), ("{0:N0}" -f $input), ("{0:N0}" -f $output), ("{0:N0}" -f $average), (Format-WorkflowStatDuration -Seconds $duration))
            }
            elseif ($Width -ge 58) {
                @($modelName, $items.Count, ("{0:N0}" -f $tokens), ("{0:N0}" -f $average), (Format-WorkflowStatDuration -Seconds $duration))
            }
            else {
                @($modelName, $items.Count, ("{0:N0}" -f $tokens))
            }
            [void]$rows.Add([pscustomobject]@{ Values = $values; Color = [ConsoleColor]::Gray })
        }
    }
    else {
        if ($Width -ge 80) {
            $columns = @(
                [pscustomobject]@{ Name = $Ui.StatsColumnIndex; Width = 3; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnType; Width = 5; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnStatus; Width = 4; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnModel; Width = 12; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTokens; Width = 8; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnInput; Width = 7; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnOutput; Width = 7; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTime; Width = 7; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnName; Width = 9; Align = 'Left' }
            )
        }
        elseif ($Width -ge 58) {
            $columns = @(
                [pscustomobject]@{ Name = $Ui.StatsColumnIndex; Width = 4; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnType; Width = 9; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnStatus; Width = 6; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnModel; Width = 12; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTokens; Width = 9; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTime; Width = 8; Align = 'Right' }
            )
        }
        elseif ($Width -ge 40) {
            $typeWidth = [Math]::Max(6, $Width - 25)
            $columns = @(
                [pscustomobject]@{ Name = $Ui.StatsColumnIndex; Width = 4; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnType; Width = $typeWidth; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnStatus; Width = 6; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTokens; Width = 9; Align = 'Right' }
            )
        }
        else {
            $typeWidth = [Math]::Max(6, $Width - 17)
            $columns = @(
                [pscustomobject]@{ Name = $Ui.StatsColumnIndex; Width = 4; Align = 'Right' }
                [pscustomobject]@{ Name = $Ui.StatsColumnType; Width = $typeWidth; Align = 'Left' }
                [pscustomobject]@{ Name = $Ui.StatsColumnTokens; Width = 9; Align = 'Right' }
            )
        }

        $recent = @($Data.History | Sort-Object FinishedAt -Descending)
        for ($i = 0; $i -lt $recent.Count; $i++) {
            $item = $recent[$i]
            $modelName = if ([string]::IsNullOrWhiteSpace($item.Model)) { $Ui.StatsDefaultModel } else { $item.Model }
            $name = if ([string]::IsNullOrWhiteSpace($item.Name)) { "" } else { $item.Name }
            $status = if ($item.Status -eq 'success') { $Ui.StatsStatusOk } elseif ($item.Status -eq 'failed') { $Ui.StatsStatusFail } else { $item.Status }
            $color = if ($item.Status -eq 'success') { [ConsoleColor]::Green } elseif ($item.Status -eq 'failed') { [ConsoleColor]::Red } else { [ConsoleColor]::Gray }
            $values = if ($Width -ge 80) {
                @(($i + 1), $item.Type, $status, $modelName, ("{0:N0}" -f $item.TotalTokens), ("{0:N0}" -f $item.InputTokens), ("{0:N0}" -f $item.OutputTokens), (Format-WorkflowStatDuration -Seconds $item.DurationSeconds), $name)
            }
            elseif ($Width -ge 58) {
                @(($i + 1), $item.Type, $status, $modelName, ("{0:N0}" -f $item.TotalTokens), (Format-WorkflowStatDuration -Seconds $item.DurationSeconds))
            }
            elseif ($Width -ge 40) {
                @(($i + 1), $item.Type, $status, ("{0:N0}" -f $item.TotalTokens))
            }
            else {
                @(($i + 1), $item.Type, ("{0:N0}" -f $item.TotalTokens))
            }
            [void]$rows.Add([pscustomobject]@{ Values = $values; Color = $color })
        }
    }

    return [pscustomobject]@{
        Columns = @($columns)
        Rows = @($rows.ToArray())
    }
}

function Write-WorkflowStatsOverview {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Data,
        [int]$Width
    )

    $totalTokenMax = [Math]::Max(1.0, $Data.TotalTokens)
    $inputTokenMax = [Math]::Max(1.0, $Data.InputTokens)
    $outputTokenMax = [Math]::Max(1.0, $Data.OutputTokens)

    Write-Host ""
    Write-WorkflowHtopBar -Label $Ui.StatsBarTotal -Value $Data.TotalTokens -MaxValue $totalTokenMax -Color Green -ViewportWidth $Width
    Write-WorkflowHtopBar -Label $Ui.StatsBarInput -Value $Data.InputTokens -MaxValue $totalTokenMax -Color Cyan -ViewportWidth $Width
    Write-WorkflowHtopBar -Label $Ui.StatsBarCached -Value $Data.CachedTokens -MaxValue $inputTokenMax -Color DarkCyan -ViewportWidth $Width
    Write-WorkflowHtopBar -Label $Ui.StatsBarOutput -Value $Data.OutputTokens -MaxValue $totalTokenMax -Color Yellow -ViewportWidth $Width
    Write-WorkflowHtopBar -Label $Ui.StatsBarReasoning -Value $Data.ReasoningTokens -MaxValue $outputTokenMax -Color Magenta -ViewportWidth $Width
    Write-Host ""
    Write-WorkflowStatsText -Text ($Ui.StatsRunsSummary -f $Data.History.Count, $Data.SuccessCount, $Data.FailedCount, $Data.SuccessRate, (Format-WorkflowStatDuration -Seconds $Data.TotalSeconds)) -Width $Width -ForegroundColor White
    Write-WorkflowStatsText -Text ($Ui.StatsAverageSummary -f (Format-WorkflowStatDuration -Seconds $Data.AverageSeconds), (Format-WorkflowStatDuration -Seconds $Data.FastestSeconds), (Format-WorkflowStatDuration -Seconds $Data.SlowestSeconds), $Data.CacheRate) -Width $Width
    Write-WorkflowStatsText -Text ($Ui.StatsTodaySummary -f $Data.TodayTokens, $Data.TodayRuns, $Data.DayTokens, $Data.DayRuns, $Data.AverageTokens) -Width $Width
}

function Write-WorkflowStatsReportTable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [object]$Table,
        [int]$Width,
        [int]$MaxRows = 15
    )

    $rows = @($Table.Rows)
    Write-Host ""
    $titleLine = Pad-WorkflowDisplayRight -Text (Format-WorkflowDisplayText -Text (" " + $Title) -MaxWidth $Width) -Width $Width
    Write-Host $titleLine -ForegroundColor White -BackgroundColor DarkGray
    if ($rows.Count -eq 0) {
        Write-WorkflowStatsText -Text $Ui.StatsNoHistory -Width $Width -ForegroundColor Yellow
        return
    }

    $end = [Math]::Min($rows.Count, [Math]::Max(1, $MaxRows))
    Write-Host ""
    Write-WorkflowStatsHeader -Columns $Table.Columns -Width $Width
    for ($i = 0; $i -lt $end; $i++) {
        Write-WorkflowStatsRow -Columns $Table.Columns -Values $rows[$i].Values -ForegroundColor $rows[$i].Color -Width $Width
    }
    if ($end -lt $rows.Count) {
        Write-WorkflowStatsText -Text ($Ui.StatsRows -f 1, $end, $rows.Count) -Width $Width -ForegroundColor DarkGray
    }
}

function Get-WorkflowStatsSourceStamp {
    $indexPath = Join-Path $scriptRoot 'runs\index.jsonl'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        return 'missing'
    }

    try {
        $item = Get-Item -LiteralPath $indexPath -ErrorAction Stop
        return ("{0}:{1}" -f $item.Length, $item.LastWriteTimeUtc.Ticks)
    }
    catch {
        return 'unavailable'
    }
}

function Write-WorkflowStatsScreen {
    $data = Get-WorkflowStatsData -History @(Get-WorkflowRunHistory)
    $width = Get-WorkflowStatsViewportWidth

    Clear-Host
    Write-WorkflowStatsText -Text (" " + $Ui.StatsTitle + " ") -Width $width -Fill -Highlight
    if ($data.History.Count -eq 0) {
        Write-Host ""
        Write-WorkflowStatsText -Text $Ui.StatsNoHistory -Width $width -ForegroundColor Yellow
    }
    else {
        Write-WorkflowStatsOverview -Data $data -Width $width
        Write-WorkflowStatsReportTable -Title $Ui.StatsSectionType -Table (Get-WorkflowStatsTableData -View Type -Data $data -Width $width) -Width $width -MaxRows 20
        Write-WorkflowStatsReportTable -Title $Ui.StatsSectionModel -Table (Get-WorkflowStatsTableData -View Model -Data $data -Width $width) -Width $width -MaxRows 8
        Write-WorkflowStatsReportTable -Title $Ui.StatsSectionRecent -Table (Get-WorkflowStatsTableData -View Recent -Data $data -Width $width) -Width $width -MaxRows 10
    }
    Write-Host ""
    Write-WorkflowStatsText -Text $Ui.StatsTokenNote -Width $width -ForegroundColor DarkGray
    Write-WorkflowStatsText -Text $Ui.StatsMissingUsageNote -Width $width -ForegroundColor DarkGray
    Write-WorkflowStatsText -Text $Ui.StatsLiveHint -Width $width -ForegroundColor Cyan
}

function Invoke-WorkflowStatsAction {
    $script:WorkflowLastActionExecuted = $false
    $observedStamp = Get-WorkflowStatsSourceStamp
    $observedWidth = Get-WorkflowStatsViewportWidth
    Write-WorkflowStatsScreen

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        return
    }

    while ($true) {
        $forceRefresh = $false
        for ($poll = 0; $poll -lt 10; $poll++) {
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if (
                        $key.Key -eq [ConsoleKey]::Enter -or
                        $key.Key -eq [ConsoleKey]::Escape -or
                        $key.Key -eq [ConsoleKey]::Q -or
                        (Test-ControlCKey -KeyInfo $key) -or
                        (Test-ControlZKey -KeyInfo $key)
                    ) {
                        return
                    }
                    if ($key.Key -eq [ConsoleKey]::R) {
                        $forceRefresh = $true
                        break
                    }
                }
            }
            catch {
                return
            }
            Start-Sleep -Milliseconds 100
        }

        $currentStamp = Get-WorkflowStatsSourceStamp
        $currentWidth = Get-WorkflowStatsViewportWidth
        if ($forceRefresh -or $currentStamp -ne $observedStamp -or $currentWidth -ne $observedWidth) {
            $observedStamp = $currentStamp
            $observedWidth = $currentWidth
            Write-WorkflowStatsScreen
        }
    }
}

function Invoke-ConfigApiDetailMenu {
    param(
        [ValidateSet('Text', 'Image')]
        [string]$Kind
    )

    $title = if ($Kind -eq 'Text') { $Ui.ApiMenu1 } else { $Ui.ApiMenu2 }
    while ($true) {
        $detailChoice = Read-MenuChoice -Items (Get-ConfigApiDetailMenuItems) -Title $title -Hint $Ui.SubMenuHint -ControlZReturns
        switch ($detailChoice) {
            0 { return }
            1 { Invoke-ConfigPrimaryApiAction -Kind $Kind }
            2 { Invoke-ConfigApiProfilesAction -Kind $Kind }
            3 {
                Invoke-TestApiConnectionAction -Kind $Kind
                Pause-ForUser
            }
        }
    }
}

function Invoke-ConfigApiMenu {
    while ($true) {
        $apiChoice = Read-MenuChoice -Items (Get-ConfigApiMenuItems) -Title $Ui.ConfigMenu3 -Hint $Ui.SubMenuHint -ControlZReturns
        switch ($apiChoice) {
            0 { return }
            1 { Invoke-ConfigApiDetailMenu -Kind Text }
            2 { Invoke-ConfigApiDetailMenu -Kind Image }
        }
    }
}

function Invoke-ConfigMenu {
    while ($true) {
        $configChoice = Read-MenuChoice -Items (Get-ConfigMenuItems) -Title $Ui.Menu5 -Hint $Ui.SubMenuHint -ControlZReturns
        switch ($configChoice) {
            0 { return }
            1 {
                Write-WorkflowConfigSummary
                Pause-ForUser
            }
            2 { Invoke-ConfigLanguageAction }
            3 { Invoke-ConfigApiMenu }
            4 { Invoke-ConfigPathsAction }
            5 { Invoke-ConfigBatchDefaultsAction }
            6 { Invoke-ConfigImageGenerationAction }
        }
    }
}

function Invoke-WorkflowTreeAction {
    param([Parameter(Mandatory = $true)][string]$Action)

    switch ($Action) {
        'LegacyChatMenu' { Invoke-ChatMenu }
        'LegacyBatchMenu' { Invoke-BatchMenu }
        'LegacyImageMenu' { Invoke-ImageMenu }
        'LegacyConfigMenu' { Invoke-ConfigMenu }
        'ChatCodex' { Invoke-CodexInteractiveChatAction }
        'ChatSingle' { $script:WorkflowLastActionExecuted = $true; Invoke-SinglePromptChatAction }
        'BatchPromptFile' { $script:WorkflowLastActionExecuted = $true; Invoke-PromptFileAction }
        'BatchPromptList' { $script:WorkflowLastActionExecuted = $true; Invoke-PromptListBatchAction }
        'BatchConversation' { $script:WorkflowLastActionExecuted = $true; Invoke-ConversationBatchAction }
        'ImageSingle' { $script:WorkflowLastActionExecuted = $true; Invoke-SingleImageAction }
        'ImageBatch' { $script:WorkflowLastActionExecuted = $true; Invoke-ImageBatchAction }
        'ImageRetryFailed' { $script:WorkflowLastActionExecuted = $true; Invoke-RetryFailedImageBatchAction }
        'ImageCancel' { $script:WorkflowLastActionExecuted = $true; Invoke-CancelImageBatchAction }
        'Stats' { Invoke-WorkflowStatsAction }
        'ConfigSummary' {
            Write-WorkflowConfigSummary
            Pause-ForUser
            $script:WorkflowLastActionExecuted = $false
        }
        'ConfigLanguage' {
            Invoke-ConfigLanguageAction
            $script:WorkflowLastActionExecuted = $false
        }
        'ConfigTextPrimary' {
            Invoke-ConfigPrimaryApiAction -Kind Text
            $script:WorkflowLastActionExecuted = $false
        }
        'ConfigTextFallback' {
            Invoke-ConfigApiProfilesAction -Kind Text
            $script:WorkflowLastActionExecuted = $false
        }
        'ConfigTextTest' {
            Invoke-TestApiConnectionAction -Kind Text
            Pause-ForUser
            $script:WorkflowLastActionExecuted = $false
        }
        'ConfigImagePrimary' {
            Invoke-ConfigPrimaryApiAction -Kind Image
            $script:WorkflowLastActionExecuted = $false
        }
        'ConfigImageFallback' {
            Invoke-ConfigApiProfilesAction -Kind Image
            $script:WorkflowLastActionExecuted = $false
        }
        'ConfigImageTest' {
            Invoke-TestApiConnectionAction -Kind Image
            Pause-ForUser
            $script:WorkflowLastActionExecuted = $false
        }
        'ConfigPaths' {
            Invoke-ConfigPathsAction
            $script:WorkflowLastActionExecuted = $false
        }
        'ConfigBatchDefaults' {
            Invoke-ConfigBatchDefaultsAction
            $script:WorkflowLastActionExecuted = $false
        }
        'ConfigImageAspectRatio' { Invoke-ConfigImageGenerationAction -InitialChoice 1 -SingleSetting; $script:WorkflowLastActionExecuted = $false }
        'ConfigImageSize' { Invoke-ConfigImageGenerationAction -InitialChoice 2 -SingleSetting; $script:WorkflowLastActionExecuted = $false }
        'ConfigImageQuality' { Invoke-ConfigImageGenerationAction -InitialChoice 3 -SingleSetting; $script:WorkflowLastActionExecuted = $false }
        'ConfigImageFormat' { Invoke-ConfigImageGenerationAction -InitialChoice 4 -SingleSetting; $script:WorkflowLastActionExecuted = $false }
        'ConfigImageCompression' { Invoke-ConfigImageGenerationAction -InitialChoice 5 -SingleSetting; $script:WorkflowLastActionExecuted = $false }
        'ConfigImageModeration' { Invoke-ConfigImageGenerationAction -InitialChoice 6 -SingleSetting; $script:WorkflowLastActionExecuted = $false }
    }
}

try {
    while ($true) {
        try {
            $navigation = Read-WorkflowTreeNavigationChoice
        }
        catch {
            if ($_.Exception.Message -eq $WorkflowExitSignal) {
                break
            }

            if ($_.Exception.Message -eq $WorkflowBackSignal) {
                continue
            }

            throw
        }

        if ([string]$navigation.Action -eq 'Exit') {
            break
        }

        $script:WorkflowLastActionExecuted = $false

        try {
            Invoke-WorkflowTreeAction -Action ([string]$navigation.Action)
        }
        catch {
            if ($_.Exception.Message -eq $WorkflowExitSignal) {
                break
            }

            if ($_.Exception.Message -eq $WorkflowBackSignal) {
                Write-Host ""
                Write-Host $Ui.WorkflowCanceled -ForegroundColor DarkGray
                Start-Sleep -Milliseconds 600
                continue
            }

            Write-Host ""
            Write-Host $Ui.WorkflowFailed -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
        }

        if (-not $script:WorkflowLastActionExecuted) {
            continue
        }

        try {
            Pause-ForUser
        }
        catch {
            if ($_.Exception.Message -eq $WorkflowExitSignal) {
                break
            }

            if ($_.Exception.Message -eq $WorkflowBackSignal) {
                continue
            }

            throw
        }
    }
}
finally {
    try {
        if ($null -ne $script:WorkflowOriginalTreatControlCAsInput) {
            [Console]::TreatControlCAsInput = [bool]$script:WorkflowOriginalTreatControlCAsInput
        }
    }
    catch {
    }
}
