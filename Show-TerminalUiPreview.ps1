[CmdletBinding()]
param(
    [ValidateRange(0, 18)]
    [int]$Style = 0,
    [switch]$Snapshot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Glyph = @{
    TopLeft     = [string][char]0x250C
    TopRight    = [string][char]0x2510
    BottomLeft  = [string][char]0x2514
    BottomRight = [string][char]0x2518
    Horizontal  = [string][char]0x2500
    Vertical    = [string][char]0x2502
    Branch      = [string][char]0x251C
    LastBranch  = [string][char]0x2514
    Arrow       = [string][char]0x25B6
    Dot         = [string][char]0x2022
    Block       = [string][char]0x2588
    Shade       = [string][char]0x2591
    Check       = [string][char]0x2713
}

$script:Styles = @(
    [pscustomobject]@{ Name = "Search / filter selector"; Id = "search"; Hint = "Type to filter, then move the highlighted result." }
    [pscustomobject]@{ Name = "Multi-select list"; Id = "multi"; Hint = "Select several items with Space before submitting." }
    [pscustomobject]@{ Name = "Command palette"; Id = "command"; Hint = "A searchable action launcher, similar to Codex slash commands." }
    [pscustomobject]@{ Name = "Autocomplete popup"; Id = "complete"; Hint = "Suggestions appear below the active input." }
    [pscustomobject]@{ Name = "Confirmation modal"; Id = "confirm"; Hint = "A focused decision over dimmed background content." }
    [pscustomobject]@{ Name = "Permission approval"; Id = "approval"; Hint = "Approve once, always approve, or deny a request." }
    [pscustomobject]@{ Name = "Tabs"; Id = "tabs"; Hint = "Switch between related views without leaving the screen." }
    [pscustomobject]@{ Name = "Split pane"; Id = "split"; Hint = "A selectable list on the left and details on the right." }
    [pscustomobject]@{ Name = "Tree navigator"; Id = "tree"; Hint = "Expand and collapse hierarchical content." }
    [pscustomobject]@{ Name = "Scrollable table"; Id = "table"; Hint = "Navigate a long, sortable table inside a fixed viewport." }
    [pscustomobject]@{ Name = "Paged text viewer"; Id = "pager"; Hint = "Read long prompts, logs, or errors one page at a time." }
    [pscustomobject]@{ Name = "Live log panel"; Id = "logs"; Hint = "Append-only output with a pinned running status." }
    [pscustomobject]@{ Name = "Persistent status bar"; Id = "status"; Hint = "Keep model, workspace, tokens, and mode visible." }
    [pscustomobject]@{ Name = "Toast notification"; Id = "toast"; Hint = "Show a short success or error message without changing views." }
    [pscustomobject]@{ Name = "Step wizard"; Id = "wizard"; Hint = "Guide complex configuration through ordered steps." }
    [pscustomobject]@{ Name = "Collapsible details"; Id = "collapse"; Hint = "Keep summaries compact and reveal detail on demand." }
    [pscustomobject]@{ Name = "Sparkline chart"; Id = "sparkline"; Hint = "Show a compact trend without a full charting surface." }
    [pscustomobject]@{ Name = "Full-screen dashboard"; Id = "dashboard"; Hint = "Combine metrics, progress, tables, and live status." }
)

$script:State = [pscustomobject]@{
    GalleryRow    = if ($Style -gt 0) { $Style - 1 } else { 0 }
    Row           = 0
    SearchQuery   = "co"
    CommandQuery  = "/m"
    CompleteText  = "gpt-"
    Checked       = @($true, $false, $true, $false, $false, $false)
    Action        = 0
    Result        = ""
    Tab           = 0
    Expanded      = $true
    TableRow      = 3
    Page          = 0
    LogTick       = 0
    ToastVisible  = $true
    WizardStep    = 1
    Metric        = 0
    DashboardSort = 0
}

function Get-UiWidth {
    try {
        if (-not [Console]::IsOutputRedirected) {
            return [Math]::Max(42, [Math]::Min(100, [Console]::WindowWidth - 1))
        }
    }
    catch {
    }

    return 78
}

function Get-UiHeight {
    try {
        if (-not [Console]::IsOutputRedirected) {
            return [Math]::Max(12, [Console]::WindowHeight)
        }
    }
    catch {
    }

    return 30
}

function Format-UiText {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [int]$Width
    )

    if ($Width -le 0) {
        return ""
    }
    if ($null -eq $Text) {
        $Text = ""
    }
    if ($Text.Length -gt $Width) {
        if ($Width -le 3) {
            return $Text.Substring(0, $Width)
        }
        return $Text.Substring(0, $Width - 3) + "..."
    }
    return $Text.PadRight($Width)
}

function Write-UiTitle {
    param([string]$Text)

    $width = Get-UiWidth
    Write-Host (Format-UiText -Text ("  " + $Text) -Width $width) -ForegroundColor Black -BackgroundColor Cyan
}

function Write-UiRule {
    param(
        [string]$Label = "",
        [ConsoleColor]$Color = [ConsoleColor]::DarkGray
    )

    $width = Get-UiWidth
    $prefix = if ([string]::IsNullOrWhiteSpace($Label)) { "" } else { " $Label " }
    $remaining = [Math]::Max(0, $width - $prefix.Length)
    Write-Host ($prefix + ($script:Glyph.Horizontal * $remaining)) -ForegroundColor $Color
}

function Write-UiBox {
    param(
        [string]$Title,
        [string[]]$Lines,
        [ConsoleColor]$BorderColor = [ConsoleColor]::DarkCyan
    )

    $width = Get-UiWidth
    $inner = [Math]::Max(1, $width - 2)
    $label = if ([string]::IsNullOrWhiteSpace($Title)) { "" } else { " $Title " }
    $topFill = [Math]::Max(0, $inner - $label.Length)
    Write-Host ($script:Glyph.TopLeft + $label + ($script:Glyph.Horizontal * $topFill) + $script:Glyph.TopRight) -ForegroundColor $BorderColor
    foreach ($line in @($Lines)) {
        Write-Host -NoNewline $script:Glyph.Vertical -ForegroundColor $BorderColor
        Write-Host -NoNewline (Format-UiText -Text ([string]$line) -Width $inner)
        Write-Host $script:Glyph.Vertical -ForegroundColor $BorderColor
    }
    Write-Host ($script:Glyph.BottomLeft + ($script:Glyph.Horizontal * $inner) + $script:Glyph.BottomRight) -ForegroundColor $BorderColor
}

function Write-UiRow {
    param(
        [string]$Text,
        [switch]$Selected,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    $width = Get-UiWidth
    $prefix = if ($Selected) { "> " } else { "  " }
    $line = Format-UiText -Text ($prefix + $Text) -Width $width
    if ($Selected) {
        Write-Host $line -ForegroundColor Black -BackgroundColor Cyan
    }
    else {
        Write-Host $line -ForegroundColor $Color
    }
}

function Write-UiBar {
    param(
        [string]$Label,
        [double]$Value,
        [double]$Maximum = 100,
        [int]$Width = 24,
        [ConsoleColor]$Color = [ConsoleColor]::Green,
        [string]$Suffix = "%"
    )

    $ratio = if ($Maximum -gt 0) { [Math]::Min(1.0, [Math]::Max(0.0, $Value / $Maximum)) } else { 0.0 }
    $filled = [Math]::Min($Width, [Math]::Max(0, [int][Math]::Round($ratio * $Width)))
    $empty = $Width - $filled
    Write-Host -NoNewline ("{0,-11}[" -f $Label) -ForegroundColor Cyan
    if ($filled -gt 0) {
        Write-Host -NoNewline ($script:Glyph.Block * $filled) -ForegroundColor $Color
    }
    if ($empty -gt 0) {
        Write-Host -NoNewline ($script:Glyph.Shade * $empty) -ForegroundColor DarkGray
    }
    Write-Host ("] {0,3}{1}" -f [Math]::Round($Value), $Suffix) -ForegroundColor Gray
}

function Move-UiIndex {
    param(
        [int]$Current,
        [int]$Delta,
        [int]$Count
    )

    if ($Count -le 0) {
        return 0
    }
    return (($Current + $Delta + $Count) % $Count)
}

function Show-SearchPreview {
    param($State)

    $all = @("codex", "codex-mini", "configuration", "conversation", "image batch", "run history", "statistics", "workspace")
    $matches = @($all | Where-Object { $_ -like ("*" + $State.SearchQuery + "*") })
    if ($matches.Count -eq 0) {
        $State.Row = 0
    }
    elseif ($State.Row -ge $matches.Count) {
        $State.Row = $matches.Count - 1
    }

    Write-UiBox -Title "FILTER" -Lines @(("Search: {0}_" -f $State.SearchQuery))
    Write-Host (" {0} result(s)" -f $matches.Count) -ForegroundColor DarkGray
    if ($matches.Count -eq 0) {
        Write-UiRow -Text "No matching items" -Color Yellow
    }
    else {
        for ($i = 0; $i -lt $matches.Count; $i++) {
            Write-UiRow -Text $matches[$i] -Selected:($i -eq $State.Row)
        }
    }
}

function Show-MultiPreview {
    param($State)

    $items = @("Text API", "Image API", "Batch defaults", "Run history", "Browser tools", "Debug logging")
    Write-UiRule -Label "SELECT COMPONENTS" -Color Cyan
    for ($i = 0; $i -lt $items.Count; $i++) {
        $mark = if ($State.Checked[$i]) { "[x]" } else { "[ ]" }
        Write-UiRow -Text ("{0} {1}" -f $mark, $items[$i]) -Selected:($i -eq $State.Row)
    }
    Write-Host " Space toggles the current item; Enter applies the selection." -ForegroundColor DarkGray
}

function Show-CommandPreview {
    param($State)

    $commands = @(
        [pscustomobject]@{ Name = "/model"; Detail = "select the active model" }
        [pscustomobject]@{ Name = "/mode"; Detail = "change collaboration mode" }
        [pscustomobject]@{ Name = "/memory"; Detail = "open saved memories" }
        [pscustomobject]@{ Name = "/status"; Detail = "show session status" }
        [pscustomobject]@{ Name = "/review"; Detail = "review the current workspace" }
        [pscustomobject]@{ Name = "/exit"; Detail = "return to workflow" }
    )
    $matches = @($commands | Where-Object { $_.Name -like ("*" + $State.CommandQuery.TrimStart('/') + "*") })
    if ($matches.Count -eq 0) { $State.Row = 0 } elseif ($State.Row -ge $matches.Count) { $State.Row = $matches.Count - 1 }

    Write-UiBox -Title "COMMAND" -Lines @(("{0}_" -f $State.CommandQuery)) -BorderColor Green
    for ($i = 0; $i -lt $matches.Count; $i++) {
        Write-UiRow -Text ("{0,-12} {1}" -f $matches[$i].Name, $matches[$i].Detail) -Selected:($i -eq $State.Row)
    }
    if ($matches.Count -eq 0) {
        Write-UiRow -Text "No command found" -Color Yellow
    }
}

function Show-CompletePreview {
    param($State)

    $models = @("gpt-5", "gpt-5-codex", "gpt-5-mini", "o3", "o4-mini")
    $matches = @($models | Where-Object { $_ -like ($State.CompleteText + "*") })
    if ($matches.Count -eq 0) { $State.Row = 0 } elseif ($State.Row -ge $matches.Count) { $State.Row = $matches.Count - 1 }

    Write-UiBox -Title "MODEL" -Lines @(("Model: {0}_" -f $State.CompleteText))
    Write-Host " Suggestions" -ForegroundColor DarkGray
    for ($i = 0; $i -lt $matches.Count; $i++) {
        Write-UiRow -Text $matches[$i] -Selected:($i -eq $State.Row)
    }
    if ($matches.Count -eq 0) {
        Write-UiRow -Text "No suggestions" -Color Yellow
    }
}

function Show-ConfirmPreview {
    param($State)

    Write-Host "  Run 14   image-batch   queued   0%" -ForegroundColor DarkGray
    Write-Host "  Run 15   conversation  waiting  0%" -ForegroundColor DarkGray
    Write-Host ""
    Write-UiBox -Title "CONFIRM" -Lines @(
        "Start 12 queued tasks?",
        "The configured API may incur usage charges.",
        ""
    ) -BorderColor Yellow
    $actions = @("Start", "Cancel")
    for ($i = 0; $i -lt $actions.Count; $i++) {
        Write-UiRow -Text ("[ {0} ]" -f $actions[$i]) -Selected:($i -eq $State.Action)
    }
    if (-not [string]::IsNullOrWhiteSpace($State.Result)) {
        Write-Host (" " + $State.Result) -ForegroundColor Green
    }
}

function Show-ApprovalPreview {
    param($State)

    Write-UiBox -Title "PERMISSION REQUEST" -Lines @(
        "Command: npm install",
        "Directory: C:\Projects\codex-workflow",
        "Reason: install the declared UI dependencies"
    ) -BorderColor Yellow
    $actions = @("Allow once", "Always allow this command", "Deny")
    for ($i = 0; $i -lt $actions.Count; $i++) {
        Write-UiRow -Text $actions[$i] -Selected:($i -eq $State.Action)
    }
    if (-not [string]::IsNullOrWhiteSpace($State.Result)) {
        Write-Host (" Decision: " + $State.Result) -ForegroundColor Cyan
    }
}

function Show-TabsPreview {
    param($State)

    $tabs = @("Overview", "History", "Models", "Settings")
    for ($i = 0; $i -lt $tabs.Count; $i++) {
        $text = " {0} " -f $tabs[$i]
        if ($i -eq $State.Tab) {
            Write-Host -NoNewline $text -ForegroundColor Black -BackgroundColor Cyan
        }
        else {
            Write-Host -NoNewline $text -ForegroundColor DarkGray
        }
        Write-Host -NoNewline " "
    }
    Write-Host ""
    Write-UiRule
    switch ($State.Tab) {
        0 { Write-UiBox -Title "OVERVIEW" -Lines @("Runs: 128", "Success: 96.1%", "Tokens: 2.4M") }
        1 { Write-UiBox -Title "HISTORY" -Lines @("14:22  prompt       ok", "14:18  image-batch  ok", "14:03  conversation fail") }
        2 { Write-UiBox -Title "MODELS" -Lines @("gpt-5-codex   71 runs", "gpt-5         42 runs", "o4-mini       15 runs") }
        3 { Write-UiBox -Title "SETTINGS" -Lines @("Language     zh-CN", "Concurrency  4", "Workspace    workflow") }
    }
}

function Show-SplitPreview {
    param($State)

    $tasks = @("#18  conversation", "#17  image batch", "#16  prompt file", "#15  API test", "#14  cleanup")
    $details = @(
        @("Status: running", "Model: gpt-5-codex", "Elapsed: 00:41", "Tokens: 18,420"),
        @("Status: success", "Images: 8/8", "Elapsed: 02:12", "Output: pic\batch-17"),
        @("Status: success", "Prompts: 24/24", "Elapsed: 04:08", "Tokens: 92,104"),
        @("Status: success", "Endpoint: /models", "HTTP: 200", "Latency: 428ms"),
        @("Status: success", "Removed: 6 runs", "Freed: 84 MB", "Elapsed: 00:01")
    )
    $width = Get-UiWidth
    $leftWidth = [Math]::Min(30, [Math]::Max(18, [int]($width * 0.38)))
    $rightWidth = [Math]::Max(18, $width - $leftWidth - 3)
    Write-Host ((Format-UiText " TASKS" $leftWidth) + " | " + (Format-UiText "DETAIL" $rightWidth)) -ForegroundColor Cyan
    Write-Host (($script:Glyph.Horizontal * $leftWidth) + "-+-" + ($script:Glyph.Horizontal * $rightWidth)) -ForegroundColor DarkGray
    for ($i = 0; $i -lt [Math]::Max($tasks.Count, $details[$State.Row].Count); $i++) {
        $left = ""
        if ($i -lt $tasks.Count) {
            $prefix = if ($i -eq $State.Row) { "> " } else { "  " }
            $left = $prefix + $tasks[$i]
        }
        $right = if ($i -lt $details[$State.Row].Count) { " " + $details[$State.Row][$i] } else { "" }
        $color = if ($i -eq $State.Row) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Gray }
        Write-Host ((Format-UiText $left $leftWidth) + " | " + (Format-UiText $right $rightWidth)) -ForegroundColor $color
    }
}

function Get-TreeRows {
    param($State)

    $rows = New-Object System.Collections.Generic.List[string]
    [void]$rows.Add("[-] workflow")
    if ($State.Expanded) {
        [void]$rows.Add("  $($script:Glyph.Branch)- [settings]")
        [void]$rows.Add("  $($script:Glyph.Branch)- [runs]")
        [void]$rows.Add("  $($script:Glyph.Branch)- Start-CodexWorkflow.ps1")
        [void]$rows.Add("  $($script:Glyph.Branch)- WorkflowProgressUi.ps1")
        [void]$rows.Add("  $($script:Glyph.LastBranch)- Show-TerminalUiPreview.ps1")
    }
    else {
        $rows[0] = "[+] workflow"
    }
    [void]$rows.Add("[+] codex-main")
    return $rows.ToArray()
}

function Show-TreePreview {
    param($State)

    $rows = @(Get-TreeRows -State $State)
    if ($State.Row -ge $rows.Count) { $State.Row = $rows.Count - 1 }
    Write-UiRule -Label "WORKSPACE TREE" -Color Cyan
    for ($i = 0; $i -lt $rows.Count; $i++) {
        Write-UiRow -Text $rows[$i] -Selected:($i -eq $State.Row)
    }
    Write-Host " Space expands or collapses the workflow node." -ForegroundColor DarkGray
}

function Show-TablePreview {
    param($State)

    $rows = for ($i = 1; $i -le 24; $i++) {
        [pscustomobject]@{
            Id = $i
            State = if (($i % 7) -eq 0) { "fail" } elseif (($i % 3) -eq 0) { "running" } else { "ok" }
            Progress = if (($i % 3) -eq 0) { ($i * 7) % 100 } else { 100 }
            Time = "00:{0:D2}" -f (($i * 11) % 60)
            Name = "workflow-run-{0:D2}" -f $i
        }
    }
    $visible = [Math]::Max(4, [Math]::Min(9, (Get-UiHeight) - 12))
    $start = [Math]::Max(0, [Math]::Min($rows.Count - $visible, $State.TableRow - [int]($visible / 2)))
    Write-Host " IDX STATE    PROGRESS             PCT   TIME  NAME" -ForegroundColor Black -BackgroundColor DarkCyan
    for ($i = $start; $i -lt [Math]::Min($rows.Count, $start + $visible); $i++) {
        $item = $rows[$i]
        $barWidth = 16
        $filled = [int][Math]::Round($item.Progress / 100 * $barWidth)
        $bar = ($script:Glyph.Block * $filled) + ($script:Glyph.Shade * ($barWidth - $filled))
        $line = " {0,3} {1,-8} {2} {3,3}%  {4}  {5}" -f $item.Id, $item.State, $bar, $item.Progress, $item.Time, $item.Name
        Write-UiRow -Text $line -Selected:($i -eq $State.TableRow) -Color $(if ($item.State -eq "fail") { "Red" } else { "Gray" })
    }
    Write-Host (" Rows {0}-{1} of {2}" -f ($start + 1), [Math]::Min($rows.Count, $start + $visible), $rows.Count) -ForegroundColor DarkGray
}

function Show-PagerPreview {
    param($State)

    $pages = @(
        @("# Workflow run report", "", "The batch started with 24 prompts and concurrency 4.", "All API profiles passed validation before execution.", "", "PageDown continues to execution details."),
        @("## Execution details", "", "Workers maintained a fixed bottom progress region.", "Output remained scrollable above the live task table.", "One request was retried after a transient timeout.", "", "PageDown continues to the result summary."),
        @("## Result summary", "", "Succeeded: 23", "Failed: 1", "Total tokens: 92,104", "Elapsed: 04:08", "", "End of report.")
    )
    Write-UiBox -Title ("VIEWER  PAGE {0}/{1}" -f ($State.Page + 1), $pages.Count) -Lines $pages[$State.Page] -BorderColor DarkGreen
    Write-Host " PageUp/PageDown changes pages." -ForegroundColor DarkGray
}

function Show-LogsPreview {
    param($State)

    $all = @(
        "14:22:01 INFO  loading workflow configuration",
        "14:22:01 OK    API profile validated",
        "14:22:02 INFO  queued 12 prompt jobs",
        "14:22:03 RUN   worker-1 prompt-01",
        "14:22:03 RUN   worker-2 prompt-02",
        "14:22:05 OK    prompt-01 1,842 tokens",
        "14:22:06 WARN  prompt-02 retrying after timeout",
        "14:22:08 OK    prompt-03 2,104 tokens",
        "14:22:09 RUN   worker-4 prompt-06"
    )
    $count = [Math]::Min($all.Count, 5 + $State.LogTick)
    Write-UiRule -Label "LIVE OUTPUT" -Color Cyan
    for ($i = [Math]::Max(0, $count - 7); $i -lt $count; $i++) {
        $color = if ($all[$i] -match " OK ") { "Green" } elseif ($all[$i] -match "WARN") { "Yellow" } else { "Gray" }
        Write-Host (" " + $all[$i]) -ForegroundColor $color
    }
    $spinner = @("|", "/", "-", "\")[$State.LogTick % 4]
    Write-Host (" {0} Running  {1}/12 complete  elapsed 00:{2:D2}" -f $spinner, [Math]::Min(12, 4 + $State.LogTick), (9 + $State.LogTick)) -ForegroundColor Cyan
    Write-Host " Enter appends the next sample event." -ForegroundColor DarkGray
}

function Show-StatusPreview {
    param($State)

    Write-UiBox -Title "CONVERSATION" -Lines @(
        "You: Review the current workflow changes.",
        "",
        "Codex: I am checking the menu state and progress renderer.",
        "",
        "Tool: rg completed in 0.4s"
    ) -BorderColor DarkGray
    $width = Get-UiWidth
    $status = " gpt-5-codex | Default | D:\...\workflow | 18.4k tokens | online "
    Write-Host (Format-UiText -Text $status -Width $width) -ForegroundColor Black -BackgroundColor Green
}

function Show-ToastPreview {
    param($State)

    if ($State.ToastVisible) {
        Write-UiBox -Title "SUCCESS" -Lines @("Configuration saved", "Text API profile: primary") -BorderColor Green
        Write-Host ""
    }
    Write-Host " Settings / Text API" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " Name      primary"
    Write-Host " Model     gpt-5-codex"
    Write-Host " Base URL  https://api.openai.com/v1"
    Write-Host ""
    Write-Host " Enter or Space toggles the notification." -ForegroundColor DarkGray
}

function Show-WizardPreview {
    param($State)

    $steps = @("Profile", "Endpoint", "Model", "Review")
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $marker = if ($i -lt $State.WizardStep) { "[$($script:Glyph.Check)]" } elseif ($i -eq $State.WizardStep) { "[$($i + 1)]" } else { "[ ]" }
        $color = if ($i -eq $State.WizardStep) { "Cyan" } elseif ($i -lt $State.WizardStep) { "Green" } else { "DarkGray" }
        Write-Host -NoNewline (" {0} {1} " -f $marker, $steps[$i]) -ForegroundColor $color
        if ($i -lt $steps.Count - 1) { Write-Host -NoNewline "--" -ForegroundColor DarkGray }
    }
    Write-Host ""
    Write-UiRule
    switch ($State.WizardStep) {
        0 { Write-UiBox -Title "PROFILE" -Lines @("Name: primary", "Type: Text API") }
        1 { Write-UiBox -Title "ENDPOINT" -Lines @("Base URL: https://api.openai.com/v1", "API key: ********") }
        2 { Write-UiBox -Title "MODEL" -Lines @("Model: gpt-5-codex", "Reasoning: medium") }
        3 { Write-UiBox -Title "REVIEW" -Lines @("Profile: primary", "Endpoint: api.openai.com", "Model: gpt-5-codex", "Ready to save") -BorderColor Green }
    }
    Write-Host " Left/Right moves between steps." -ForegroundColor DarkGray
}

function Show-CollapsePreview {
    param($State)

    $marker = if ($State.Expanded) { "[-]" } else { "[+]" }
    Write-UiRow -Text ("{0} Tool call: shell_command  completed in 1.2s" -f $marker) -Selected
    if ($State.Expanded) {
        Write-Host "     Command   npm run check" -ForegroundColor Gray
        Write-Host "     Exit code 0" -ForegroundColor Green
        Write-Host "     Output    42 tests passed" -ForegroundColor Gray
    }
    Write-UiRow -Text "[+] Files changed: 2" -Color DarkGray
    Write-UiRow -Text "[+] Token usage: 18,420" -Color DarkGray
    Write-Host " Space expands or collapses the selected detail." -ForegroundColor DarkGray
}

function New-Sparkline {
    param([double[]]$Values)

    $levels = 0x2581..0x2588 | ForEach-Object { [string][char]$_ }
    $max = ($Values | Measure-Object -Maximum).Maximum
    if ($max -le 0) { $max = 1 }
    $result = New-Object System.Text.StringBuilder
    foreach ($value in $Values) {
        $index = [Math]::Min(7, [Math]::Max(0, [int][Math]::Floor(($value / $max) * 7)))
        [void]$result.Append($levels[$index])
    }
    return $result.ToString()
}

function Show-SparklinePreview {
    param($State)

    $metrics = @(
        [pscustomobject]@{ Name = "Tokens / run"; Unit = "tok"; Values = [double[]]@(12, 18, 16, 24, 31, 28, 36, 42, 38, 51, 47, 62, 58, 71, 66, 82, 78, 91, 87, 96) }
        [pscustomobject]@{ Name = "Duration"; Unit = "sec"; Values = [double[]]@(8, 9, 7, 12, 10, 14, 11, 9, 15, 13, 12, 18, 16, 14, 20, 17, 15, 13, 12, 10) }
        [pscustomobject]@{ Name = "Success rate"; Unit = "%"; Values = [double[]]@(72, 78, 76, 81, 84, 83, 88, 91, 89, 93, 92, 95, 94, 96, 97, 95, 98, 97, 99, 98) }
    )
    $metric = $metrics[$State.Metric]
    $sparkline = New-Sparkline -Values $metric.Values
    Write-UiBox -Title $metric.Name.ToUpperInvariant() -Lines @(
        "",
        ("  {0}" -f $sparkline),
        "",
        ("  Latest: {0:N0} {1}   Min: {2:N0}   Max: {3:N0}" -f $metric.Values[-1], $metric.Unit, (($metric.Values | Measure-Object -Minimum).Minimum), (($metric.Values | Measure-Object -Maximum).Maximum))
    ) -BorderColor Magenta
    Write-Host " Left/Right switches metrics." -ForegroundColor DarkGray
}

function Show-DashboardPreview {
    param($State)

    Write-UiBar -Label "CPU workers" -Value 68 -Color Green
    Write-UiBar -Label "Token quota" -Value 43 -Color Cyan
    Write-UiBar -Label "Cache hit" -Value 76 -Color Yellow
    Write-Host ""
    Write-Host " RUNS  OK  FAIL  TOKENS     AVG       UPTIME" -ForegroundColor Black -BackgroundColor DarkCyan
    Write-Host "  128 123     5  2,431,882  18,999    03:42:18" -ForegroundColor White
    Write-Host ""
    $sortName = if ($State.DashboardSort -eq 0) { "TOKENS" } else { "TIME" }
    Write-Host (" ACTIVE TASKS                                      sort: {0}" -f $sortName) -ForegroundColor Cyan
    Write-Host " ID  STATE    PROGRESS          MODEL          TOKENS   TIME" -ForegroundColor DarkGray
    Write-Host " 18  running  [########--] 82%  gpt-5-codex   18,420  00:41" -ForegroundColor Green
    Write-Host " 19  running  [####------] 37%  gpt-5          8,104  00:18" -ForegroundColor Cyan
    Write-Host " 20  queued   [----------]  0%  gpt-5-codex        0     --" -ForegroundColor Gray
    Write-Host ""
    $width = Get-UiWidth
    Write-Host (Format-UiText -Text " online | workers 4/4 | queue 1 | refresh 1s | S changes sort " -Width $width) -ForegroundColor Black -BackgroundColor Green
}

function Show-Gallery {
    param($State)

    Clear-Host
    Write-UiTitle -Text "TERMINAL UI PATTERN GALLERY"
    Write-Host " Up/Down selects a pattern. Enter opens the live preview." -ForegroundColor DarkGray
    Write-UiRule

    $height = Get-UiHeight
    $visible = [Math]::Max(5, [Math]::Min($script:Styles.Count, $height - 8))
    $start = [Math]::Max(0, [Math]::Min($script:Styles.Count - $visible, $State.GalleryRow - [int]($visible / 2)))
    for ($i = $start; $i -lt [Math]::Min($script:Styles.Count, $start + $visible); $i++) {
        Write-UiRow -Text ("{0,2}. {1}" -f ($i + 1), $script:Styles[$i].Name) -Selected:($i -eq $State.GalleryRow)
    }
    Write-UiRule
    Write-Host (" {0}" -f $script:Styles[$State.GalleryRow].Hint) -ForegroundColor Yellow
    Write-Host " Enter preview | Esc/Q close" -ForegroundColor DarkGray
}

function Show-StylePreview {
    param(
        [int]$Index,
        $State,
        [switch]$NoClear
    )

    if (-not $NoClear) {
        Clear-Host
    }
    $item = $script:Styles[$Index]
    Write-UiTitle -Text ("[{0:D2}/{1:D2}] {2}" -f ($Index + 1), $script:Styles.Count, $item.Name.ToUpperInvariant())
    Write-Host (" " + $item.Hint) -ForegroundColor DarkGray
    Write-UiRule

    switch ($item.Id) {
        "search" { Show-SearchPreview -State $State }
        "multi" { Show-MultiPreview -State $State }
        "command" { Show-CommandPreview -State $State }
        "complete" { Show-CompletePreview -State $State }
        "confirm" { Show-ConfirmPreview -State $State }
        "approval" { Show-ApprovalPreview -State $State }
        "tabs" { Show-TabsPreview -State $State }
        "split" { Show-SplitPreview -State $State }
        "tree" { Show-TreePreview -State $State }
        "table" { Show-TablePreview -State $State }
        "pager" { Show-PagerPreview -State $State }
        "logs" { Show-LogsPreview -State $State }
        "status" { Show-StatusPreview -State $State }
        "toast" { Show-ToastPreview -State $State }
        "wizard" { Show-WizardPreview -State $State }
        "collapse" { Show-CollapsePreview -State $State }
        "sparkline" { Show-SparklinePreview -State $State }
        "dashboard" { Show-DashboardPreview -State $State }
    }

    Write-UiRule
    Write-Host " [ / ] previous/next style | Esc gallery | Ctrl+Q close" -ForegroundColor DarkGray
}

function Test-ControlQ {
    param([ConsoleKeyInfo]$Key)

    return ($Key.Key -eq [ConsoleKey]::Q -and (($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0))
}

function Update-PreviewState {
    param(
        [int]$Index,
        [ConsoleKeyInfo]$Key,
        $State
    )

    $id = $script:Styles[$Index].Id
    switch ($id) {
        "search" {
            $matches = @(@("codex", "codex-mini", "configuration", "conversation", "image batch", "run history", "statistics", "workspace") | Where-Object { $_ -like ("*" + $State.SearchQuery + "*") })
            if ($Key.Key -eq "UpArrow") { $State.Row = Move-UiIndex $State.Row -1 $matches.Count; return }
            if ($Key.Key -eq "DownArrow") { $State.Row = Move-UiIndex $State.Row 1 $matches.Count; return }
            if ($Key.Key -eq "Backspace" -and $State.SearchQuery.Length -gt 0) { $State.SearchQuery = $State.SearchQuery.Substring(0, $State.SearchQuery.Length - 1); $State.Row = 0; return }
            if (-not [char]::IsControl($Key.KeyChar)) { $State.SearchQuery += [string]$Key.KeyChar; $State.Row = 0 }
        }
        "multi" {
            if ($Key.Key -eq "UpArrow") { $State.Row = Move-UiIndex $State.Row -1 6 }
            elseif ($Key.Key -eq "DownArrow") { $State.Row = Move-UiIndex $State.Row 1 6 }
            elseif ($Key.Key -eq "Spacebar") { $State.Checked[$State.Row] = -not $State.Checked[$State.Row] }
        }
        "command" {
            $commands = @("/model", "/mode", "/memory", "/status", "/review", "/exit")
            $count = @($commands | Where-Object { $_ -like ("*" + $State.CommandQuery.TrimStart('/') + "*") }).Count
            if ($Key.Key -eq "UpArrow") { $State.Row = Move-UiIndex $State.Row -1 $count; return }
            if ($Key.Key -eq "DownArrow") { $State.Row = Move-UiIndex $State.Row 1 $count; return }
            if ($Key.Key -eq "Backspace" -and $State.CommandQuery.Length -gt 1) { $State.CommandQuery = $State.CommandQuery.Substring(0, $State.CommandQuery.Length - 1); $State.Row = 0; return }
            if (-not [char]::IsControl($Key.KeyChar) -and $Key.KeyChar -ne '/') { $State.CommandQuery += [string]$Key.KeyChar; $State.Row = 0 }
        }
        "complete" {
            $count = @(@("gpt-5", "gpt-5-codex", "gpt-5-mini", "o3", "o4-mini") | Where-Object { $_ -like ($State.CompleteText + "*") }).Count
            if ($Key.Key -eq "UpArrow") { $State.Row = Move-UiIndex $State.Row -1 $count; return }
            if ($Key.Key -eq "DownArrow") { $State.Row = Move-UiIndex $State.Row 1 $count; return }
            if ($Key.Key -eq "Backspace" -and $State.CompleteText.Length -gt 0) { $State.CompleteText = $State.CompleteText.Substring(0, $State.CompleteText.Length - 1); $State.Row = 0; return }
            if (-not [char]::IsControl($Key.KeyChar)) { $State.CompleteText += [string]$Key.KeyChar; $State.Row = 0 }
        }
        "confirm" {
            if ($Key.Key -in @("LeftArrow", "UpArrow")) { $State.Action = Move-UiIndex $State.Action -1 2 }
            elseif ($Key.Key -in @("RightArrow", "DownArrow")) { $State.Action = Move-UiIndex $State.Action 1 2 }
            elseif ($Key.Key -eq "Enter") { $State.Result = if ($State.Action -eq 0) { "Tasks started" } else { "Canceled" } }
        }
        "approval" {
            if ($Key.Key -eq "UpArrow") { $State.Action = Move-UiIndex $State.Action -1 3 }
            elseif ($Key.Key -eq "DownArrow") { $State.Action = Move-UiIndex $State.Action 1 3 }
            elseif ($Key.Key -eq "Enter") { $State.Result = @("allowed once", "always allowed", "denied")[$State.Action] }
        }
        "tabs" {
            if ($Key.Key -in @("LeftArrow", "UpArrow")) { $State.Tab = Move-UiIndex $State.Tab -1 4 }
            elseif ($Key.Key -in @("RightArrow", "DownArrow", "Tab")) { $State.Tab = Move-UiIndex $State.Tab 1 4 }
        }
        "split" {
            if ($Key.Key -eq "UpArrow") { $State.Row = Move-UiIndex $State.Row -1 5 }
            elseif ($Key.Key -eq "DownArrow") { $State.Row = Move-UiIndex $State.Row 1 5 }
        }
        "tree" {
            $count = @(Get-TreeRows -State $State).Count
            if ($Key.Key -eq "UpArrow") { $State.Row = Move-UiIndex $State.Row -1 $count }
            elseif ($Key.Key -eq "DownArrow") { $State.Row = Move-UiIndex $State.Row 1 $count }
            elseif ($Key.Key -in @("Spacebar", "Enter", "LeftArrow", "RightArrow")) { $State.Expanded = -not $State.Expanded; $State.Row = 0 }
        }
        "table" {
            if ($Key.Key -eq "UpArrow") { $State.TableRow = [Math]::Max(0, $State.TableRow - 1) }
            elseif ($Key.Key -eq "DownArrow") { $State.TableRow = [Math]::Min(23, $State.TableRow + 1) }
            elseif ($Key.Key -eq "PageUp") { $State.TableRow = [Math]::Max(0, $State.TableRow - 7) }
            elseif ($Key.Key -eq "PageDown") { $State.TableRow = [Math]::Min(23, $State.TableRow + 7) }
            elseif ($Key.Key -eq "Home") { $State.TableRow = 0 }
            elseif ($Key.Key -eq "End") { $State.TableRow = 23 }
        }
        "pager" {
            if ($Key.Key -in @("LeftArrow", "UpArrow", "PageUp")) { $State.Page = [Math]::Max(0, $State.Page - 1) }
            elseif ($Key.Key -in @("RightArrow", "DownArrow", "PageDown", "Spacebar")) { $State.Page = [Math]::Min(2, $State.Page + 1) }
            elseif ($Key.Key -eq "Home") { $State.Page = 0 }
            elseif ($Key.Key -eq "End") { $State.Page = 2 }
        }
        "logs" {
            if ($Key.Key -eq "Enter") { $State.LogTick = ($State.LogTick + 1) % 5 }
        }
        "toast" {
            if ($Key.Key -in @("Enter", "Spacebar")) { $State.ToastVisible = -not $State.ToastVisible }
        }
        "wizard" {
            if ($Key.Key -in @("LeftArrow", "UpArrow")) { $State.WizardStep = [Math]::Max(0, $State.WizardStep - 1) }
            elseif ($Key.Key -in @("RightArrow", "DownArrow", "Enter")) { $State.WizardStep = [Math]::Min(3, $State.WizardStep + 1) }
        }
        "collapse" {
            if ($Key.Key -in @("Spacebar", "Enter", "LeftArrow", "RightArrow")) { $State.Expanded = -not $State.Expanded }
        }
        "sparkline" {
            if ($Key.Key -in @("LeftArrow", "UpArrow")) { $State.Metric = Move-UiIndex $State.Metric -1 3 }
            elseif ($Key.Key -in @("RightArrow", "DownArrow")) { $State.Metric = Move-UiIndex $State.Metric 1 3 }
        }
        "dashboard" {
            if ($Key.Key -eq "S") { $State.DashboardSort = 1 - $State.DashboardSort }
        }
    }
}

if ($Snapshot) {
    if ($Style -eq 0) {
        Write-UiTitle -Text "TERMINAL UI PATTERN GALLERY"
        for ($i = 0; $i -lt $script:Styles.Count; $i++) {
            Write-UiRow -Text ("{0,2}. {1}" -f ($i + 1), $script:Styles[$i].Name) -Selected:($i -eq $script:State.GalleryRow)
        }
    }
    else {
        Show-StylePreview -Index ($Style - 1) -State $script:State -NoClear
    }
    return
}

if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
    throw "Interactive preview requires a terminal. Use -Snapshot for redirected output."
}

$mode = if ($Style -gt 0) { "preview" } else { "gallery" }
$previewIndex = if ($Style -gt 0) { $Style - 1 } else { $script:State.GalleryRow }

try {
    [Console]::CursorVisible = $false
    while ($true) {
        if ($mode -eq "gallery") {
            Show-Gallery -State $script:State
        }
        else {
            Show-StylePreview -Index $previewIndex -State $script:State
        }

        $key = [Console]::ReadKey($true)
        if (Test-ControlQ -Key $key) {
            break
        }

        if ($mode -eq "gallery") {
            $closeGallery = $false
            switch ($key.Key) {
                "UpArrow" { $script:State.GalleryRow = Move-UiIndex $script:State.GalleryRow -1 $script:Styles.Count; continue }
                "DownArrow" { $script:State.GalleryRow = Move-UiIndex $script:State.GalleryRow 1 $script:Styles.Count; continue }
                "PageUp" { $script:State.GalleryRow = [Math]::Max(0, $script:State.GalleryRow - 7); continue }
                "PageDown" { $script:State.GalleryRow = [Math]::Min($script:Styles.Count - 1, $script:State.GalleryRow + 7); continue }
                "Home" { $script:State.GalleryRow = 0; continue }
                "End" { $script:State.GalleryRow = $script:Styles.Count - 1; continue }
                "Enter" { $previewIndex = $script:State.GalleryRow; $script:State.Row = 0; $mode = "preview"; continue }
                "Escape" { $closeGallery = $true }
                "Q" { $closeGallery = $true }
            }
            if ($closeGallery) {
                break
            }
            continue
        }

        if ($key.Key -eq "Escape") {
            $script:State.GalleryRow = $previewIndex
            $mode = "gallery"
            continue
        }
        if ($key.KeyChar -eq '[') {
            $previewIndex = Move-UiIndex $previewIndex -1 $script:Styles.Count
            $script:State.Row = 0
            continue
        }
        if ($key.KeyChar -eq ']') {
            $previewIndex = Move-UiIndex $previewIndex 1 $script:Styles.Count
            $script:State.Row = 0
            continue
        }

        Update-PreviewState -Index $previewIndex -Key $key -State $script:State
    }
}
finally {
    try {
        [Console]::CursorVisible = $true
    }
    catch {
    }
    Clear-Host
}
