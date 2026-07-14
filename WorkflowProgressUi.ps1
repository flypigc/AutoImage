$existingFallbackState = Get-Variable -Name WorkflowProgressFallbackState -Scope Script -ErrorAction SilentlyContinue
if (-not $existingFallbackState) {
    $script:WorkflowProgressFallbackState = @{}
}

$existingAreaLines = Get-Variable -Name WorkflowProgressAreaLines -Scope Script -ErrorAction SilentlyContinue
if (-not $existingAreaLines) {
    $script:WorkflowProgressAreaLines = @{}
}

$existingCliProgressBridge = Get-Variable -Name WorkflowCliProgressBridge -Scope Script -ErrorAction SilentlyContinue
if (-not $existingCliProgressBridge) {
    $script:WorkflowCliProgressBridge = $null
}

$existingCliProgressBridgeDisabled = Get-Variable -Name WorkflowCliProgressBridgeDisabled -Scope Script -ErrorAction SilentlyContinue
if (-not $existingCliProgressBridgeDisabled) {
    $script:WorkflowCliProgressBridgeDisabled = $false
}

$existingSpinnerFallbackActive = Get-Variable -Name WorkflowSpinnerFallbackActive -Scope Script -ErrorAction SilentlyContinue
if (-not $existingSpinnerFallbackActive) {
    $script:WorkflowSpinnerFallbackActive = $false
}

$existingProgressUiRoot = Get-Variable -Name WorkflowProgressUiRoot -Scope Script -ErrorAction SilentlyContinue
if (-not $existingProgressUiRoot -or [string]::IsNullOrWhiteSpace([string]$existingProgressUiRoot.Value)) {
    $script:WorkflowProgressUiRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $PSScriptRoot
    }
    else {
        Split-Path -Parent $MyInvocation.MyCommand.Path
    }
}

function Test-WorkflowProgressConsole {
    try {
        if ([Console]::IsOutputRedirected) {
            return $false
        }

        $null = [Console]::WindowWidth
        $null = [Console]::WindowHeight
        return $true
    }
    catch {
        try {
            $oldColorVariable = Get-Variable -Name oldColor -ErrorAction SilentlyContinue
            if ($oldColorVariable) {
                [Console]::ForegroundColor = $oldColorVariable.Value
            }
        }
        catch {
        }

        return $false
    }
}

function Set-WorkflowCursorVisible {
    param([bool]$Visible)

    try {
        if (-not [Console]::IsOutputRedirected) {
            [Console]::CursorVisible = $Visible
        }
    }
    catch {
    }
}

function Get-WorkflowConsoleWidth {
    try {
        if (Test-WorkflowProgressConsole) {
            return [Math]::Max(40, [Console]::WindowWidth)
        }
    }
    catch {
    }

    return 100
}

function Test-WorkflowAnsiColor {
    return (
        -not [string]::IsNullOrWhiteSpace($env:WT_SESSION) -or
        -not [string]::IsNullOrWhiteSpace($env:ANSICON) -or
        $env:ConEmuANSI -eq "ON" -or
        $env:TERM -like "xterm*"
    )
}

function ConvertTo-WorkflowAsciiJson {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    $json = $InputObject | ConvertTo-Json -Compress -Depth 8
    $builder = New-Object System.Text.StringBuilder
    foreach ($jsonChar in $json.ToCharArray()) {
        $code = [int][char]$jsonChar
        if ($code -gt 127) {
            [void]$builder.Append(("\u{0:X4}" -f $code))
        }
        else {
            [void]$builder.Append($jsonChar)
        }
    }

    return $builder.ToString()
}

function Start-WorkflowCliProgressBridge {
    if ($script:WorkflowCliProgressBridgeDisabled) {
        return $null
    }

    try {
        if ($script:WorkflowCliProgressBridge -and -not $script:WorkflowCliProgressBridge.HasExited) {
            return $script:WorkflowCliProgressBridge
        }
    }
    catch {
        $script:WorkflowCliProgressBridge = $null
    }

    try {
        $bridgeScript = Join-Path $script:WorkflowProgressUiRoot "cli-progress-bridge.js"
        $dependencyPath = Join-Path $script:WorkflowProgressUiRoot "node_modules\cli-progress"
        if (-not (Test-Path -LiteralPath $bridgeScript -PathType Leaf) -or -not (Test-Path -LiteralPath $dependencyPath -PathType Container)) {
            $script:WorkflowCliProgressBridgeDisabled = $true
            return $null
        }

        $nodeCommand = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue
        if (-not $nodeCommand) {
            $nodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue
        }

        if (-not $nodeCommand) {
            $script:WorkflowCliProgressBridgeDisabled = $true
            return $null
        }

        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = [string]$nodeCommand.Source
        $processInfo.Arguments = '"' + ($bridgeScript -replace '"', '\"') + '"'
        $processInfo.WorkingDirectory = $script:WorkflowProgressUiRoot
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardInput = $true
        $processInfo.RedirectStandardOutput = $false
        $processInfo.RedirectStandardError = $false
        $processInfo.CreateNoWindow = $false

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        if (-not $process.Start()) {
            $script:WorkflowCliProgressBridgeDisabled = $true
            return $null
        }

        $process.StandardInput.AutoFlush = $true
        $script:WorkflowCliProgressBridge = $process
        return $process
    }
    catch {
        $script:WorkflowCliProgressBridgeDisabled = $true
        $script:WorkflowCliProgressBridge = $null
        return $null
    }
}

function Send-WorkflowCliProgressEvent {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Event,
        [int]$LineCount = 0
    )

    if (-not (Test-WorkflowProgressConsole)) {
        return $false
    }

    $process = Start-WorkflowCliProgressBridge
    if (-not $process) {
        return $false
    }

    try {
        $line = ConvertTo-WorkflowAsciiJson -InputObject $Event
        $process.StandardInput.WriteLine($line)
        if ($LineCount -ge 0) {
            $script:WorkflowProgressAreaLines["Bottom"] = $LineCount
        }

        return $true
    }
    catch {
        try {
            if ($process -and -not $process.HasExited) {
                $process.Kill()
            }
        }
        catch {
        }

        $script:WorkflowCliProgressBridgeDisabled = $true
        $script:WorkflowCliProgressBridge = $null
        return $false
    }
}

function Test-WorkflowBottomProgressActive {
    if (-not $script:WorkflowProgressAreaLines.ContainsKey("Bottom")) {
        return $false
    }

    return ([int]$script:WorkflowProgressAreaLines["Bottom"] -gt 0)
}

function Test-WorkflowNodeDependency {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $dependencyPath = Join-Path $script:WorkflowProgressUiRoot ("node_modules\{0}" -f $Name)
    return (Test-Path -LiteralPath $dependencyPath -PathType Container)
}

function Start-WorkflowSpinner {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    if (Test-WorkflowBottomProgressActive) {
        return $false
    }

    Set-WorkflowCursorVisible -Visible $false
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        Write-Host $Text -ForegroundColor DarkGray
    }
    $script:WorkflowSpinnerFallbackActive = $true
    return $false
}

function Update-WorkflowSpinner {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    if (Test-WorkflowBottomProgressActive) {
        return $false
    }

    return $false
}

function Stop-WorkflowSpinner {
    param(
        [ValidateSet("succeed", "fail", "warn", "info", "stop")]
        [string]$State = "stop",
        [AllowEmptyString()]
        [string]$Text = ""
    )

    if ($script:WorkflowSpinnerFallbackActive -and $State -ne "stop" -and -not [string]::IsNullOrWhiteSpace($Text)) {
        $prefix = switch ($State) {
            "succeed" { "ok" }
            "fail" { "fail" }
            "warn" { "warn" }
            "info" { "info" }
            default { "" }
        }

        if ([string]::IsNullOrWhiteSpace($prefix)) {
            Write-Host $Text
        }
        else {
            Write-Host ("{0}: {1}" -f $prefix, $Text)
        }
    }

    $script:WorkflowSpinnerFallbackActive = $false
    Set-WorkflowCursorVisible -Visible $true
    return $false
}

function Format-WorkflowProgressText {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [int]$MaxWidth = 80
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

function Get-WorkflowProgressPercent {
    param(
        [int]$Completed,
        [int]$Total
    )

    if ($Total -le 0) {
        return 100
    }

    $safeCompleted = [Math]::Min([Math]::Max(0, $Completed), $Total)
    return [int][Math]::Min(100, [Math]::Floor(($safeCompleted / $Total) * 100))
}

function New-WorkflowProgressBar {
    param(
        [int]$Percent,
        [int]$Width = 24,
        [switch]$AppleBlue
    )

    $safeWidth = [Math]::Max(4, $Width)
    $safePercent = [Math]::Min(100, [Math]::Max(0, $Percent))
    $filled = [int][Math]::Floor(($safePercent / 100) * $safeWidth)
    $empty = $safeWidth - $filled
    $filledBlock = [string][char]0x2588
    $emptyBlock = [string][char]0x2591
    $filledText = $filledBlock * $filled
    $emptyText = $emptyBlock * $empty

    if ($AppleBlue -and $filled -gt 0 -and (Test-WorkflowAnsiColor)) {
        $blue = "$([char]27)[38;2;0;122;255m"
        $reset = "$([char]27)[0m"
        return ($blue + $filledText + $reset + $emptyText)
    }

    return ($filledText + $emptyText)
}

function Remove-WorkflowAnsi {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    return ([regex]::Replace($Text, "$([char]27)\[[0-9;]*m", ""))
}

function Get-WorkflowVisibleLength {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    return (Remove-WorkflowAnsi -Text $Text).Length
}

function Format-WorkflowFixedLine {
    param(
        [AllowEmptyString()]
        [string]$Text,
        [int]$MaxWidth = 80
    )

    $line = if ($null -eq $Text) { "" } else { ([string]$Text -replace "\s+", " ").Trim() }
    $visibleLength = Get-WorkflowVisibleLength -Text $line
    if ($visibleLength -gt $MaxWidth) {
        return (Format-WorkflowProgressText -Text (Remove-WorkflowAnsi -Text $line) -MaxWidth $MaxWidth)
    }

    return ($line + (" " * [Math]::Max(0, $MaxWidth - $visibleLength)))
}

function Reset-WorkflowTopScrollRegion {
    if (-not (Test-WorkflowAnsiColor)) {
        return
    }

    try {
        if (-not [Console]::IsOutputRedirected) {
            $esc = [string][char]27
            [Console]::Write("$esc[r")
        }
    }
    catch {
    }
}

function Write-WorkflowAnsiBottomLines {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    if (-not (Test-WorkflowAnsiColor)) {
        return $false
    }

    try {
        if ([Console]::IsOutputRedirected) {
            return $false
        }

        $width = Get-WorkflowConsoleWidth
        $lineCount = $Lines.Count
        if ($lineCount -le 0) {
            Reset-WorkflowTopScrollRegion
            return $true
        }

        $esc = [string][char]27
        $save = "$esc[s"
        $restore = "$esc[u"
        $clearLine = "$esc[2K"
        $windowHeight = [Math]::Max(1, [Console]::WindowHeight)
        $startRow = [Math]::Max(1, $windowHeight - $lineCount + 1)
        $bottom = "{0}[{1};1H" -f $esc, $startRow
        $output = New-Object System.Text.StringBuilder
        [void]$output.Append($save)
        [void]$output.Append($bottom)
        for ($i = 0; $i -lt $lineCount; $i++) {
            [void]$output.Append($clearLine)
            [void]$output.Append((Format-WorkflowFixedLine -Text $Lines[$i] -MaxWidth ([Math]::Max(1, $width - 1))))
            if ($i -lt ($lineCount - 1)) {
                [void]$output.Append("`n")
            }
        }
        [void]$output.Append($restore)
        [Console]::Write($output.ToString())
        $script:WorkflowProgressAreaLines["Bottom"] = $lineCount
        return $true
    }
    catch {
        return $false
    }
}

function Write-WorkflowFixedLines {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Top", "Bottom")]
        [string]$Anchor,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Lines,
        [switch]$AppleBlue
    )

    if (-not (Test-WorkflowProgressConsole)) {
        return $false
    }

    try {
        $windowWidth = [Math]::Max(20, [Console]::WindowWidth)
        $windowHeight = [Math]::Max(1, [Console]::WindowHeight)
        $lineCount = [Math]::Min($Lines.Count, $windowHeight)
        if ($lineCount -le 0) {
            return $true
        }

        $cursorLeft = [Console]::CursorLeft
        $cursorTop = [Console]::CursorTop
        $windowTop = [Console]::WindowTop
        $startRow = if ($Anchor -eq "Top") {
            $windowTop
        }
        else {
            $windowTop + $windowHeight - $lineCount
        }

        $usableWidth = [Math]::Max(1, $windowWidth - 1)
        for ($i = 0; $i -lt $lineCount; $i++) {
            [Console]::SetCursorPosition(0, $startRow + $i)
            $line = Format-WorkflowFixedLine -Text $Lines[$i] -MaxWidth $usableWidth
            [Console]::Write($line)
        }

        $script:WorkflowProgressAreaLines[$Anchor] = $lineCount

        $restoreLeft = [Math]::Min($cursorLeft, [Math]::Max(0, [Console]::WindowWidth - 1))
        $restoreTop = [Math]::Min($cursorTop, [Math]::Max(0, [Console]::BufferHeight - 1))
        if ($Anchor -eq "Top") {
            $restoreTop = [Math]::Max($restoreTop, [Math]::Min([Console]::BufferHeight - 1, $startRow + $lineCount))
        }
        [Console]::SetCursorPosition($restoreLeft, $restoreTop)
        return $true
    }
    catch {
        return $false
    }
}

function Move-WorkflowCursorBelowProgress {
    param(
        [ValidateSet("Top", "Bottom")]
        [string]$Anchor = "Bottom"
    )

    if (-not (Test-WorkflowProgressConsole)) {
        return
    }

    try {
        if (-not $script:WorkflowProgressAreaLines.ContainsKey($Anchor)) {
            return
        }

        $lineCount = [int]$script:WorkflowProgressAreaLines[$Anchor]
        if ($lineCount -le 0) {
            return
        }

        if ($Anchor -eq "Top") {
            $targetRow = [Math]::Min([Console]::BufferHeight - 1, [Console]::WindowTop + $lineCount)
            if ([Console]::CursorTop -lt $targetRow) {
                [Console]::SetCursorPosition(0, $targetRow)
            }
            return
        }

        $progressTop = [Math]::Max([Console]::WindowTop, [Console]::WindowTop + [Console]::WindowHeight - $lineCount)
        if ([Console]::CursorTop -ge $progressTop) {
            $targetRow = [Math]::Max([Console]::WindowTop, $progressTop - 1)
            [Console]::SetCursorPosition(0, $targetRow)
        }
    }
    catch {
    }
}

function Clear-WorkflowProgressArea {
    param(
        [ValidateSet("Top", "Bottom")]
        [string]$Anchor = "Top",
        [int]$LineCount = 0
    )

    if (-not (Test-WorkflowProgressConsole)) {
        return
    }

    try {
        if ($LineCount -le 0 -and $script:WorkflowProgressAreaLines.ContainsKey($Anchor)) {
            $LineCount = [int]$script:WorkflowProgressAreaLines[$Anchor]
        }

        if ($LineCount -le 0) {
            return
        }

        if ($script:WorkflowCliProgressBridge) {
            try {
                if (-not $script:WorkflowCliProgressBridge.HasExited) {
                    $clearLine = ConvertTo-WorkflowAsciiJson -InputObject @{ type = "clear" }
                    $script:WorkflowCliProgressBridge.StandardInput.WriteLine($clearLine)
                }
            }
            catch {
            }
        }
        elseif ($Anchor -eq "Top") {
            Reset-WorkflowTopScrollRegion
        }

        $windowWidth = [Math]::Max(20, [Console]::WindowWidth)
        $windowHeight = [Math]::Max(1, [Console]::WindowHeight)
        $lineCount = [Math]::Min($LineCount, $windowHeight)
        $cursorLeft = [Console]::CursorLeft
        $cursorTop = [Console]::CursorTop
        $windowTop = [Console]::WindowTop
        $startRow = if ($Anchor -eq "Top") {
            $windowTop
        }
        else {
            $windowTop + $windowHeight - $lineCount
        }

        $blank = " " * [Math]::Max(1, $windowWidth - 1)
        for ($i = 0; $i -lt $lineCount; $i++) {
            [Console]::SetCursorPosition(0, $startRow + $i)
            [Console]::Write($blank)
        }

        $restoreLeft = [Math]::Min($cursorLeft, [Math]::Max(0, [Console]::WindowWidth - 1))
        $restoreTop = [Math]::Min($cursorTop, [Math]::Max(0, [Console]::BufferHeight - 1))
        [Console]::SetCursorPosition($restoreLeft, $restoreTop)
        $script:WorkflowProgressAreaLines[$Anchor] = 0
        if ($Anchor -eq "Top") {
            Reset-WorkflowTopScrollRegion
        }
    }
    catch {
    }
}

function Write-WorkflowProgressFallback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Lines,
        [switch]$Force
    )

    $now = Get-Date
    if (-not $Force -and $script:WorkflowProgressFallbackState.ContainsKey($Key)) {
        $lastWrite = $script:WorkflowProgressFallbackState[$Key]
        if ($lastWrite -and (($now - $lastWrite).TotalSeconds -lt 2)) {
            return
        }
    }

    if (Write-WorkflowAnsiBottomLines -Lines $Lines) {
        $script:WorkflowProgressFallbackState[$Key] = $now
        return
    }

    $script:WorkflowProgressFallbackState[$Key] = $now
}

function Write-WorkflowSerialProgress {
    param(
        [string]$Key = "serial",
        [Parameter(Mandatory = $true)]
        [string]$TotalLabel,
        [Parameter(Mandatory = $true)]
        [int]$TotalCompleted,
        [Parameter(Mandatory = $true)]
        [int]$TotalCount,
        [Parameter(Mandatory = $true)]
        [string]$SubLabel,
        [Parameter(Mandatory = $true)]
        [int]$SubCompleted,
        [Parameter(Mandatory = $true)]
        [int]$SubCount,
        [AllowEmptyString()]
        [string]$Status,
        [switch]$Force
    )

    [void](Stop-WorkflowSpinner -State "stop")
    Set-WorkflowCursorVisible -Visible $false

    $serialEvent = @{
        type = "serial"
        totalLabel = $TotalLabel
        totalCompleted = $TotalCompleted
        totalCount = $TotalCount
        subLabel = $SubLabel
        subCompleted = $SubCompleted
        subCount = $SubCount
        status = $Status
    }

    if (Send-WorkflowCliProgressEvent -Event $serialEvent -LineCount 2) {
        return
    }

    $width = Get-WorkflowConsoleWidth
    $barWidth = if ($width -ge 120) { 32 } elseif ($width -ge 80) { 24 } else { 16 }
    $labelWidth = if ($width -ge 120) { 32 } elseif ($width -ge 80) { 24 } else { 16 }
    $totalPercent = Get-WorkflowProgressPercent -Completed $TotalCompleted -Total $TotalCount
    $subPercent = Get-WorkflowProgressPercent -Completed $SubCompleted -Total $SubCount
    $totalBar = New-WorkflowProgressBar -Percent $totalPercent -Width $barWidth -AppleBlue
    $subBar = New-WorkflowProgressBar -Percent $subPercent -Width $barWidth -AppleBlue
    $totalText = Format-WorkflowProgressText -Text $TotalLabel -MaxWidth $labelWidth
    $subText = Format-WorkflowProgressText -Text $SubLabel -MaxWidth $labelWidth
    $statusText = Format-WorkflowProgressText -Text $Status -MaxWidth ([Math]::Max(10, $width - $barWidth - $labelWidth - 22))

    $totalLine = "{0,-5} {1} {2,3}% {3} {4}/{5}" -f "TOTAL", $totalBar, $totalPercent, $totalText, $TotalCompleted, $TotalCount
    $subLine = "{0,-5} {1} {2,3}% {3} {4}/{5}" -f "TASK", $subBar, $subPercent, $subText, $SubCompleted, $SubCount
    if (-not [string]::IsNullOrWhiteSpace($statusText)) {
        $subLine = "$subLine | $statusText"
    }

    $lines = @($totalLine, $subLine)
    if (-not (Write-WorkflowFixedLines -Anchor Bottom -Lines $lines)) {
        Write-WorkflowProgressFallback -Key $Key -Lines $lines -Force:$Force
    }
}

function Get-WorkflowObjectPropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-WorkflowTaskState {
    param(
        [AllowNull()]
        [object]$Job
    )

    $status = Get-WorkflowObjectPropertyValue -InputObject $Job -Name "Status"
    if (-not [string]::IsNullOrWhiteSpace([string]$status)) {
        return ([string]$status).ToLowerInvariant()
    }

    $process = Get-WorkflowObjectPropertyValue -InputObject $Job -Name "Process"
    if ($process) {
        try {
            if (-not $process.HasExited) {
                return "running"
            }
        }
        catch {
        }

        return "finished"
    }

    return "queued"
}

function Get-WorkflowTaskSortRank {
    param(
        [AllowNull()]
        [object]$Job
    )

    $state = Get-WorkflowTaskState -Job $Job
    switch ($state) {
        "running" { return 0 }
        "queued" { return 1 }
        "failed" { return 2 }
        "success" { return 3 }
        default { return 4 }
    }
}

function Format-WorkflowDuration {
    param(
        [AllowNull()]
        [object]$StartedAt,
        [AllowNull()]
        [object]$FinishedAt
    )

    if (-not $StartedAt) {
        return "--"
    }

    $endTime = if ($FinishedAt) { [datetime]$FinishedAt } else { Get-Date }
    $duration = $endTime - [datetime]$StartedAt
    $seconds = [int][Math]::Max(0, [Math]::Floor($duration.TotalSeconds))

    if ($seconds -ge 3600) {
        return ("{0}h{1:D2}m" -f [int]($seconds / 3600), [int](($seconds % 3600) / 60))
    }

    if ($seconds -ge 60) {
        return ("{0}m{1:D2}s" -f [int]($seconds / 60), [int]($seconds % 60))
    }

    return ("{0}s" -f $seconds)
}

function Get-WorkflowTaskPercent {
    param(
        [AllowNull()]
        [object]$Job
    )

    $state = Get-WorkflowTaskState -Job $Job
    switch ($state) {
        "queued" { return 0 }
        "success" { return 100 }
        "failed" { return 100 }
    }

    $startedAt = Get-WorkflowObjectPropertyValue -InputObject $Job -Name "StartedAt"
    if (-not $startedAt) {
        return 5
    }

    $elapsedSeconds = [Math]::Max(0, ((Get-Date) - [datetime]$startedAt).TotalSeconds)
    return [int][Math]::Min(95, [Math]::Max(5, [Math]::Floor(5 + ($elapsedSeconds * 2))))
}

function Write-WorkflowConcurrentTaskTable {
    param(
        [string]$Key = "concurrent",
        [Parameter(Mandatory = $true)]
        [int]$TotalCount,
        [Parameter(Mandatory = $true)]
        [int]$CompletedCount,
        [Parameter(Mandatory = $true)]
        [int]$SuccessCount,
        [Parameter(Mandatory = $true)]
        [int]$FailedCount,
        [Parameter(Mandatory = $true)]
        [int]$QueuedCount,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Jobs,
        [AllowEmptyString()]
        [string]$CurrentStatus,
        [switch]$Force
    )

    if ($TotalCount -le 0) {
        return
    }

    [void](Stop-WorkflowSpinner -State "stop")
    Set-WorkflowCursorVisible -Visible $false

    $width = Get-WorkflowConsoleWidth
    $barWidth = if ($width -ge 120) { 24 } elseif ($width -ge 80) { 18 } else { 12 }
    $percent = Get-WorkflowProgressPercent -Completed $CompletedCount -Total $TotalCount
    $bar = New-WorkflowProgressBar -Percent $percent -Width $barWidth -AppleBlue
    $status = Format-WorkflowProgressText -Text $CurrentStatus -MaxWidth ([Math]::Max(10, $width - $barWidth - 56))
    $totalLine = "{0,-5} {1} {2,3}% done {3}/{4} ok {5} fail {6} queued {7}" -f "TOTAL", $bar, $percent, $CompletedCount, $TotalCount, $SuccessCount, $FailedCount, $QueuedCount
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        $totalLine = "$totalLine | $status"
    }

    $taskRows = if (Test-WorkflowProgressConsole) {
        $windowTaskRows = [Math]::Max(1, [Console]::WindowHeight - 3)
        [Math]::Max(1, [Math]::Min([Math]::Min($Jobs.Count, $windowTaskRows), 10))
    }
    else {
        [Math]::Min($Jobs.Count, 8)
    }

    $orderedJobs = @(
        $Jobs |
            Sort-Object -Property @{ Expression = { Get-WorkflowTaskSortRank -Job $_ } }, @{ Expression = { [int](Get-WorkflowObjectPropertyValue -InputObject $_ -Name "Index") } } |
            Select-Object -First $taskRows
    )

    $eventTasks = New-Object System.Collections.Generic.List[object]
    foreach ($job in $orderedJobs) {
        $index = [int](Get-WorkflowObjectPropertyValue -InputObject $job -Name "Index")
        $state = Get-WorkflowTaskState -Job $job
        $jobPercent = Get-WorkflowTaskPercent -Job $job
        $startedAt = Get-WorkflowObjectPropertyValue -InputObject $job -Name "StartedAt"
        $finishedAt = Get-WorkflowObjectPropertyValue -InputObject $job -Name "FinishedAt"
        $elapsed = Format-WorkflowDuration -StartedAt $startedAt -FinishedAt $finishedAt
        $name = [string](Get-WorkflowObjectPropertyValue -InputObject $job -Name "JobName")
        [void]$eventTasks.Add(@{
            index = $index
            state = $state
            percent = $jobPercent
            elapsed = $elapsed
            name = $name
        })
    }

    $hiddenCount = [Math]::Max(0, $Jobs.Count - $orderedJobs.Count)
    $concurrentEvent = @{
        type = "concurrent"
        totalCount = $TotalCount
        completedCount = $CompletedCount
        successCount = $SuccessCount
        failedCount = $FailedCount
        queuedCount = $QueuedCount
        currentStatus = $CurrentStatus
        tasks = @($eventTasks.ToArray())
        hiddenCount = $hiddenCount
    }

    $eventLineCount = 2 + $eventTasks.Count
    if ($hiddenCount -gt 0) {
        $eventLineCount++
    }

    if (Send-WorkflowCliProgressEvent -Event $concurrentEvent -LineCount $eventLineCount) {
        return
    }

    $header = "IDX STATE    PROGRESS{0} PCT  TIME   NAME" -f (" " * [Math]::Max(1, $barWidth - 8))
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add($totalLine)
    [void]$lines.Add($header)

    $nameWidth = [Math]::Max(8, $width - $barWidth - 31)
    foreach ($job in $orderedJobs) {
        $index = [int](Get-WorkflowObjectPropertyValue -InputObject $job -Name "Index")
        $state = Get-WorkflowTaskState -Job $job
        $jobPercent = Get-WorkflowTaskPercent -Job $job
        $jobBar = New-WorkflowProgressBar -Percent $jobPercent -Width $barWidth -AppleBlue
        $startedAt = Get-WorkflowObjectPropertyValue -InputObject $job -Name "StartedAt"
        $finishedAt = Get-WorkflowObjectPropertyValue -InputObject $job -Name "FinishedAt"
        $elapsed = Format-WorkflowDuration -StartedAt $startedAt -FinishedAt $finishedAt
        $name = Format-WorkflowProgressText -Text ([string](Get-WorkflowObjectPropertyValue -InputObject $job -Name "JobName")) -MaxWidth $nameWidth
        [void]$lines.Add(("{0,3} {1,-8} {2} {3,3}% {4,6} {5}" -f $index, $state, $jobBar, $jobPercent, $elapsed, $name))
    }

    if ($Jobs.Count -gt $orderedJobs.Count) {
        [void]$lines.Add(("... showing {0}/{1} tasks" -f $orderedJobs.Count, $Jobs.Count))
    }

    $lineArray = @($lines.ToArray())
    if (-not (Write-WorkflowFixedLines -Anchor Bottom -Lines $lineArray)) {
        Write-WorkflowProgressFallback -Key $Key -Lines $lineArray -Force:$Force
    }
}
