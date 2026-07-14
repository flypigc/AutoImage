[CmdletBinding(DefaultParameterSetName = "Prompt")]
param(
    [Parameter(ParameterSetName = "Prompt", Mandatory = $false)]
    [string]$Prompt,

    [Parameter(ParameterSetName = "PromptFile", Mandatory = $true)]
    [string]$PromptFile,

    [Parameter(ParameterSetName = "PromptListFile", Mandatory = $true)]
    [string]$PromptListFile,

    [string]$Workspace = '.',
    [string]$OutputRoot = '.\runs\text',
    [string]$RunName,
    [string]$Model,
    [string]$Profile,
    [string]$TextApiKey,
    [string]$TextBaseUrl,
    [string]$TextApiProfilesJson,
    [string]$ImageApiKey,
    [string]$ImageBaseUrl,
    [string]$ImageApiProfilesJson,
    [switch]$GenerateImage,
    [string]$ImageOutputPath,
    [string]$ImageArtifactsRoot,
    [string]$ImageAspectRatio,
    [string]$ImageSize,
    [string]$ImageQuality,
    [string]$ImageOutputFormat,
    [string]$ImageOutputCompression,
    [string]$ImageModeration,
    [string]$ImageReferencePathsJson,
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

    [ValidateSet("Continue", "Stop")]
    [string]$BatchFailurePolicy = "Continue",

    [string]$ResumeBatchStatePath,
    [switch]$ParseOnly,
    [switch]$NoArchive,
    [switch]$OpenSummary,
    [switch]$OpenResult,
    [switch]$OpenResultFolder,
    [switch]$NoReopenWindow
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
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
$script:ImageApiKeyOverride = $ImageApiKey
$script:ImageBaseUrlOverride = $ImageBaseUrl
$script:ImageApiProfilesJson = if ([string]::IsNullOrWhiteSpace($ImageApiProfilesJson)) { $env:CODEX_WORKFLOW_IMAGE_API_PROFILES_JSON } else { $ImageApiProfilesJson }

function Get-CodexConfigPath {
    $codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        Join-Path $HOME ".codex"
    }
    else {
        $env:CODEX_HOME
    }

    $configPath = Join-Path $codexHome "config.toml"
    if (Test-Path -LiteralPath $configPath) {
        return $configPath
    }

    return $null
}

function Get-CodexHomePath {
    if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return (Join-Path $HOME ".codex")
    }

    return $env:CODEX_HOME
}

function Get-CodexAuthPath {
    $codexHome = Get-CodexHomePath
    $authPath = Join-Path $codexHome "auth.json"
    if (Test-Path -LiteralPath $authPath) {
        return $authPath
    }

    return $null
}

function Get-ImageApiKey {
    param(
        [AllowNull()]
        [object]$Profile = $null
    )

    if ($null -ne $Profile) {
        $apiKeyProperty = $Profile.PSObject.Properties["ApiKey"]
        if ($apiKeyProperty -and -not [string]::IsNullOrWhiteSpace([string]$apiKeyProperty.Value)) {
            return [string]$apiKeyProperty.Value
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:ImageApiKeyOverride)) {
        return $script:ImageApiKeyOverride
    }

    if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_IMAGE_API_KEY)) {
        return $env:OPENAI_IMAGE_API_KEY
    }

    if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
        return $env:OPENAI_API_KEY
    }

    $authPath = Get-CodexAuthPath
    if (-not $authPath) {
        return $null
    }

    try {
        $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }

    $keyProperty = $auth.PSObject.Properties["OPENAI_API_KEY"]
    if ($null -eq $keyProperty) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace([string]$keyProperty.Value)) {
        return $null
    }

    return [string]$keyProperty.Value
}

function Get-ImageApiSettings {
    param(
        [AllowNull()]
        [object]$Profile = $null
    )

    $baseUrl = ""
    if ($null -ne $Profile) {
        $baseUrlProperty = $Profile.PSObject.Properties["BaseUrl"]
        if ($baseUrlProperty) {
            $baseUrl = [string]$baseUrlProperty.Value
        }
    }

    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = $script:ImageBaseUrlOverride
    }
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = $env:OPENAI_IMAGE_BASE_URL
    }

    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = $env:OPENAI_BASE_URL
    }

    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = $env:OPENAI_API_BASE
    }

    $defaultModel = $env:OPENAI_IMAGE_MODEL
    $providerName = $null
    $configPath = Get-CodexConfigPath

    if ($configPath) {
        $configText = [System.IO.File]::ReadAllText($configPath)

        $providerMatch = [regex]::Match($configText, '(?m)^\s*model_provider\s*=\s*"([^"]+)"')
        if ($providerMatch.Success) {
            $providerName = $providerMatch.Groups[1].Value
        }

        if ([string]::IsNullOrWhiteSpace($baseUrl) -and -not [string]::IsNullOrWhiteSpace($providerName)) {
            $escapedProviderName = [regex]::Escape($providerName)
            $sectionPattern = "(?ms)^\[model_providers\.$escapedProviderName\]\s*(.*?)(?=^\[|\z)"
            $sectionMatch = [regex]::Match($configText, $sectionPattern)
            if ($sectionMatch.Success) {
                $baseUrlMatch = [regex]::Match($sectionMatch.Groups[1].Value, '(?m)^\s*base_url\s*=\s*"([^"]+)"')
                if ($baseUrlMatch.Success) {
                    $baseUrl = $baseUrlMatch.Groups[1].Value
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = "https://api.openai.com/"
    }

    if ([string]::IsNullOrWhiteSpace($defaultModel)) {
        $defaultModel = "gpt-image-1"
    }

    return @{
        BaseUrl = $baseUrl
        DefaultModel = $defaultModel
        ProviderName = $providerName
        ConfigPath = $configPath
    }
}

function Get-ImagesGenerationEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl
    )

    $normalizedBaseUrl = $BaseUrl.Trim()
    if (-not $normalizedBaseUrl.EndsWith("/")) {
        $normalizedBaseUrl += "/"
    }

    if ($normalizedBaseUrl -match '/v1/?$') {
        return ($normalizedBaseUrl.TrimEnd('/') + "/images/generations")
    }

    return ($normalizedBaseUrl + "v1/images/generations")
}

function Get-ImagesEditEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl
    )

    $normalizedBaseUrl = $BaseUrl.Trim()
    if (-not $normalizedBaseUrl.EndsWith("/")) {
        $normalizedBaseUrl += "/"
    }

    if ($normalizedBaseUrl -match '/v1/?$') {
        return ($normalizedBaseUrl.TrimEnd('/') + "/images/edits")
    }

    return ($normalizedBaseUrl + "v1/images/edits")
}

function Test-IsLikelyImageModel {
    param(
        [AllowEmptyString()]
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return $false
    }

    $normalized = $ModelName.Trim().ToLowerInvariant()
    return ($normalized -like 'gpt-image-*' -or
        $normalized -like 'dall-e*' -or
        $normalized -match '(^|[-_])image([-_]|$)')
}

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

    $model = Get-ApiProfileModel -Profile $Profile
    if ([string]::IsNullOrWhiteSpace($model)) {
        return @($Arguments)
    }

    $result = New-Object System.Collections.Generic.List[string]
    $replaced = $false
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -eq '-m' -and ($i + 1) -lt $Arguments.Count) {
            [void]$result.Add('-m')
            [void]$result.Add($model)
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
        $result.Insert($insertAt + 1, $model)
    }

    return @($result.ToArray())
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

function Get-ImageApiProfiles {
    $profiles = @(ConvertFrom-ApiProfilesJson -Json $script:ImageApiProfilesJson)
    if ($profiles.Count -gt 0) {
        return $profiles
    }

    if (-not [string]::IsNullOrWhiteSpace($script:ImageApiKeyOverride) -or -not [string]::IsNullOrWhiteSpace($script:ImageBaseUrlOverride)) {
        return @([pscustomobject]@{
            Name = "image primary"
            ApiKey = $script:ImageApiKeyOverride
            BaseUrl = $script:ImageBaseUrlOverride
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

function Get-WebResponseStatusCode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $responseProperty = $exception.PSObject.Properties["Response"]
        if ($responseProperty -and $null -ne $responseProperty.Value) {
            $statusCodeProperty = $responseProperty.Value.PSObject.Properties["StatusCode"]
            if ($statusCodeProperty -and $null -ne $statusCodeProperty.Value) {
                $statusCode = $statusCodeProperty.Value
                if ($statusCode -is [int]) {
                    return [int]$statusCode
                }

                $valueProperty = $statusCode.PSObject.Properties["value__"]
                if ($valueProperty -and $null -ne $valueProperty.Value) {
                    return [int]$valueProperty.Value
                }

                try {
                    return [int]$statusCode
                }
                catch {
                }
            }
        }

        $exception = $exception.InnerException
    }

    return $null
}

function Get-WebResponseHeaders {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $responseProperty = $exception.PSObject.Properties["Response"]
        if ($responseProperty -and $null -ne $responseProperty.Value) {
            $headersProperty = $responseProperty.Value.PSObject.Properties["Headers"]
            if ($headersProperty -and $null -ne $headersProperty.Value) {
                return $headersProperty.Value
            }
        }

        $exception = $exception.InnerException
    }

    return $null
}

function Test-IsRetriableImageError {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $statusCode = Get-WebResponseStatusCode -ErrorRecord $ErrorRecord
    if ($statusCode -in @(408, 409, 425, 429, 500, 502, 503, 504)) {
        return $true
    }

    $errorText = ($ErrorRecord | Out-String)
    return ($errorText -match 'Concurrency limit exceeded' -or
        $errorText -match 'rate_limit' -or
        $errorText -match 'timed out' -or
        $errorText -match 'temporar' -or
        $errorText -match 'Unable to connect' -or
        $errorText -match 'connection.*closed' -or
        $errorText -match '503 Service Unavailable' -or
        $errorText -match '502 Bad Gateway' -or
        $errorText -match '504 Gateway Timeout')
}

function Get-ImageRetryDelaySeconds {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory = $true)]
        [int]$Attempt,
        [Parameter(Mandatory = $true)]
        [int]$BaseDelaySeconds,
        [Parameter(Mandatory = $true)]
        [int]$MaxDelaySeconds
    )

    $headers = Get-WebResponseHeaders -ErrorRecord $ErrorRecord
    if ($null -ne $headers) {
        try {
            $retryAfterText = $headers["Retry-After"]
            if (-not [string]::IsNullOrWhiteSpace([string]$retryAfterText)) {
                $retryAfterSeconds = 0
                if ([int]::TryParse([string]$retryAfterText, [ref]$retryAfterSeconds) -and $retryAfterSeconds -gt 0) {
                    return [Math]::Min($retryAfterSeconds, $MaxDelaySeconds)
                }

                $retryAfterDate = [datetime]::MinValue
                if ([datetime]::TryParse([string]$retryAfterText, [ref]$retryAfterDate)) {
                    $secondsUntilRetry = [int][Math]::Ceiling(($retryAfterDate.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds)
                    if ($secondsUntilRetry -gt 0) {
                        return [Math]::Min($secondsUntilRetry, $MaxDelaySeconds)
                    }
                }
            }
        }
        catch {
        }
    }

    $scaledDelay = [Math]::Min($BaseDelaySeconds * [Math]::Pow(2, [Math]::Max(0, $Attempt - 1)), $MaxDelaySeconds)
    $jitterMilliseconds = Get-Random -Minimum 0 -Maximum 1000
    return [int][Math]::Ceiling($scaledDelay + ($jitterMilliseconds / 1000.0))
}

function Invoke-OpenAIImageGeneration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PromptText,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [string]$Model,
        [string]$AspectRatio,
        [string]$Size,
        [string]$Quality,
        [string]$OutputFormat,
        [string]$OutputCompression,
        [string]$Moderation,
        [string[]]$ReferenceImagePaths = @(),
        [ValidateRange(1, 20)]
        [int]$MaxAttempts = 6,
        [ValidateRange(1, 300)]
        [int]$RetryBaseDelaySeconds = 2,
        [ValidateRange(1, 600)]
        [int]$RetryMaxDelaySeconds = 20,
        [ValidateRange(1, 86400)]
        [int]$RequestTimeoutSeconds = 600,
        [ValidateRange(1, 86400)]
        [int]$TotalTimeoutSeconds = 1800
    )

    $profiles = @(Get-ImageApiProfiles)
    $lastErrorRecord = $null
    $operationStartedAt = Get-Date
    for ($profileIndex = 0; $profileIndex -lt $profiles.Count; $profileIndex++) {
    $profile = $profiles[$profileIndex]
    $profileName = Get-ApiProfileName -Profile $profile -Index ($profileIndex + 1)
    if ($profiles.Count -gt 1) {
        Write-Host ("Using image API profile {0}/{1}: {2}" -f ($profileIndex + 1), $profiles.Count, $profileName)
    }

    try {
    $apiKey = Get-ImageApiKey -Profile $profile
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "OPENAI_API_KEY is not set in the current shell and was not found in Codex auth.json."
    }

    $outputDirectory = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    }

        $apiSettings = Get-ImageApiSettings -Profile $profile
        $effectiveModel = Get-ApiProfileModel -Profile $profile
        if ([string]::IsNullOrWhiteSpace($effectiveModel)) {
            $effectiveModel = $Model
        }

        if ([string]::IsNullOrWhiteSpace($effectiveModel)) {
            $effectiveModel = $apiSettings.DefaultModel
        }

        if (-not (Test-IsLikelyImageModel -ModelName $effectiveModel)) {
            throw ("Configured model '{0}' is not a valid image model. Set OPENAI_IMAGE_MODEL or pass -Model with an image-capable model such as gpt-image-2." -f $effectiveModel)
        }

        $hasReferenceImages = @($ReferenceImagePaths).Count -gt 0
        $endpoint = if ($hasReferenceImages) {
            Get-ImagesEditEndpoint -BaseUrl $apiSettings.BaseUrl
        }
        else {
            Get-ImagesGenerationEndpoint -BaseUrl $apiSettings.BaseUrl
        }

    $headers = @{
        Authorization = "Bearer $apiKey"
    }

    $body = [ordered]@{
        model = $effectiveModel
        prompt = $PromptText
    }
    if (-not $hasReferenceImages -and -not [string]::IsNullOrWhiteSpace($AspectRatio)) {
        $body["aspect_ratio"] = $AspectRatio
    }
    if (-not [string]::IsNullOrWhiteSpace($Size)) {
        $body["size"] = $Size
    }
    if (-not [string]::IsNullOrWhiteSpace($Quality)) {
        $body["quality"] = $Quality
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputFormat)) {
        $body["output_format"] = $OutputFormat
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputCompression) -and ([string]::IsNullOrWhiteSpace($OutputFormat) -or $OutputFormat -in @("jpeg", "webp"))) {
        $body["output_compression"] = [int]$OutputCompression
    }
    if (-not [string]::IsNullOrWhiteSpace($Moderation)) {
        $body["moderation"] = $Moderation
    }
    $bodyBytes = $null
    if (-not $hasReferenceImages) {
        $body = $body | ConvertTo-Json -Depth 5 -Compress
        $bodyBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($body)
    }

    $response = $null
    $attemptCount = 0

    try {
        while ($attemptCount -lt $MaxAttempts) {
            $attemptCount++
            $attemptPercent = [int][Math]::Min(95, [Math]::Floor((($attemptCount - 1) / $MaxAttempts) * 100))
            Write-WorkflowSerialProgress `
                -Key "image-generation" `
                -TotalLabel "Image generation" `
                -TotalCompleted $attemptPercent `
                -TotalCount 100 `
                -SubLabel ("Attempt {0}/{1}" -f $attemptCount, $MaxAttempts) `
                -SubCompleted 0 `
                -SubCount 1 `
                -Status $effectiveModel

            try {
                $remainingSeconds = [int][Math]::Floor($TotalTimeoutSeconds - ((Get-Date) - $operationStartedAt).TotalSeconds)
                if ($remainingSeconds -le 0) { throw [System.TimeoutException]::new("Image task exceeded the total timeout of $TotalTimeoutSeconds seconds.") }
                $effectiveRequestTimeout = [Math]::Max(1, [Math]::Min($RequestTimeoutSeconds, $remainingSeconds))
                if ($hasReferenceImages) {
                    $response = Invoke-OpenAIImageEdit `
                        -Endpoint $endpoint `
                        -ApiKey $apiKey `
                        -Fields $body `
                        -ImagePaths $ReferenceImagePaths `
                        -RequestTimeoutSeconds $effectiveRequestTimeout
                }
                else {
                    $response = Invoke-RestMethod `
                        -Method Post `
                        -Uri $endpoint `
                        -Headers $headers `
                        -ContentType "application/json; charset=utf-8" `
                        -Body $bodyBytes `
                        -TimeoutSec $effectiveRequestTimeout
                }
                break
            }
            catch {
                if ($attemptCount -ge $MaxAttempts -or -not (Test-IsRetriableImageError -ErrorRecord $_)) {
                    throw
                }

                $delaySeconds = Get-ImageRetryDelaySeconds `
                    -ErrorRecord $_ `
                    -Attempt $attemptCount `
                    -BaseDelaySeconds $RetryBaseDelaySeconds `
                    -MaxDelaySeconds $RetryMaxDelaySeconds

                $remainingAfterFailure = [int][Math]::Floor($TotalTimeoutSeconds - ((Get-Date) - $operationStartedAt).TotalSeconds)
                if ($remainingAfterFailure -le $delaySeconds) {
                    throw [System.TimeoutException]::new("Image task cannot retry within the total timeout of $TotalTimeoutSeconds seconds.")
                }

                Write-WorkflowSerialProgress `
                    -Key "image-generation" `
                    -TotalLabel "Image generation" `
                    -TotalCompleted $attemptPercent `
                    -TotalCount 100 `
                    -SubLabel ("Retry delay {0}s" -f $delaySeconds) `
                    -SubCompleted 0 `
                    -SubCount $delaySeconds `
                    -Status $effectiveModel
                Write-Host ("Image API transient failure on attempt {0}/{1}. Retrying in {2}s." -f $attemptCount, $MaxAttempts, $delaySeconds)
                Start-Sleep -Seconds $delaySeconds
            }
        }

        if (-not $response.data -or $response.data.Count -eq 0) {
            throw "OpenAI Images API returned no image data."
        }

        $imageData = $response.data[0]
        if ([string]::IsNullOrWhiteSpace($imageData.b64_json)) {
            throw "OpenAI Images API response did not include b64_json."
        }

        Write-WorkflowSerialProgress `
            -Key "image-generation" `
            -TotalLabel "Image generation" `
            -TotalCompleted 98 `
            -TotalCount 100 `
            -SubLabel "Saving image file" `
            -SubCompleted 0 `
            -SubCount 1 `
            -Status $OutputPath
        $imageBytes = [System.Convert]::FromBase64String([string]$imageData.b64_json)
        [System.IO.File]::WriteAllBytes($OutputPath, $imageBytes)

        Write-WorkflowSerialProgress `
            -Key "image-generation" `
            -TotalLabel "Image generation" `
            -TotalCompleted 100 `
            -TotalCount 100 `
            -SubLabel "Image saved" `
            -SubCompleted 1 `
            -SubCount 1 `
            -Status $OutputPath `
            -Force

        return @{
            Model = $effectiveModel
            AspectRatio = $AspectRatio
            Size = $Size
            Quality = $Quality
            OutputFormat = $OutputFormat
            OutputCompression = $OutputCompression
            Moderation = $Moderation
            ReferenceImageCount = @($ReferenceImagePaths).Count
            Endpoint = $endpoint
            ProviderName = $apiSettings.ProviderName
            ProfileName = $profileName
            ConfigPath = $apiSettings.ConfigPath
            Usage = $response.usage
            AttemptCount = $attemptCount
        }
    }
    finally {
        # The custom fixed progress remains visible after the last update.
    }
    }
    catch {
        $lastErrorRecord = $_
        if ($profileIndex -ge ($profiles.Count - 1) -or -not (Test-WorkflowApiSwitchableFailure -Text ($_ | Out-String))) {
            throw
        }

        Write-Host ("Image API profile failed, switching: {0}" -f $profileName) -ForegroundColor Yellow
    }
    }

    if ($lastErrorRecord) {
        throw $lastErrorRecord
    }
}

function Get-PromptEntriesFromText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $normalized = $Text -replace "`r`n", "`n"
    $parts = [regex]::Split($normalized, "(?m)^\s*---+\s*$")

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($part in $parts) {
        $item = $part.Trim()
        if (-not [string]::IsNullOrWhiteSpace($item)) {
            [void]$entries.Add($item)
        }
    }

    return $entries.ToArray()
}

function Get-ImageMimeType {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".jpg" { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".webp" { return "image/webp" }
        default { return "image/png" }
    }
}

function ConvertFrom-ImageReferencePathsJson {
    param(
        [AllowEmptyString()]
        [string]$Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return @()
    }

    $items = @($Json | ConvertFrom-Json)
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($item in $items) {
        $path = [string]$item
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        $resolved = Resolve-WorkflowPath -Path $path -MustExist
        $extension = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
        if ($extension -notin @('.png', '.jpg', '.jpeg', '.webp')) {
            throw "Unsupported reference image format: $resolved. Use PNG, JPEG, or WebP."
        }

        [void]$paths.Add($resolved)
    }

    if ($paths.Count -gt 16) {
        throw "A single image request can include at most 16 reference images."
    }

    return @($paths.ToArray())
}

function Invoke-OpenAIImageEdit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,
        [Parameter(Mandatory = $true)]
        [string]$ApiKey,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Fields,
        [Parameter(Mandatory = $true)]
        [string[]]$ImagePaths,
        [ValidateRange(1, 86400)]
        [int]$RequestTimeoutSeconds = 600
    )

    Add-Type -AssemblyName System.Net.Http

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds($RequestTimeoutSeconds)
    $content = [System.Net.Http.MultipartFormDataContent]::new()
    $disposables = New-Object System.Collections.Generic.List[object]

    try {
        foreach ($key in $Fields.Keys) {
            $value = [string]$Fields[$key]
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $fieldContent = [System.Net.Http.StringContent]::new($value, [System.Text.Encoding]::UTF8)
                [void]$disposables.Add($fieldContent)
                $content.Add($fieldContent, $key)
            }
        }

        foreach ($imagePath in $ImagePaths) {
            $stream = [System.IO.File]::OpenRead($imagePath)
            [void]$disposables.Add($stream)
            $fileContent = [System.Net.Http.StreamContent]::new($stream)
            [void]$disposables.Add($fileContent)
            $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse((Get-ImageMimeType -Path $imagePath))
            $content.Add($fileContent, "image[]", [System.IO.Path]::GetFileName($imagePath))
        }

        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Endpoint)
        [void]$disposables.Add($request)
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $ApiKey)
        $request.Content = $content

        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        [void]$disposables.Add($response)
        $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw ("Image edit API failed ({0}): {1}" -f ([int]$response.StatusCode), $responseText)
        }

        return ($responseText | ConvertFrom-Json)
    }
    finally {
        for ($i = $disposables.Count - 1; $i -ge 0; $i--) {
            if ($disposables[$i] -is [System.IDisposable]) {
                $disposables[$i].Dispose()
            }
        }
        $content.Dispose()
        $client.Dispose()
    }
}

function Start-NewCodexWindow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath
    )

    $escapedWorkspace = $WorkspacePath.Replace("'", "''")
    $launchCommand = "Set-Location -LiteralPath '$escapedWorkspace'; codex"

    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-NoExit",
        "-Command",
        $launchCommand
    ) | Out-Null
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

function Get-CodexImageRunResult {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$OutputLines
    )

    $sessionId = $null

    foreach ($lineObject in $OutputLines) {
        if ($null -eq $lineObject) {
            continue
        }

        $line = [string]$lineObject
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $match = [regex]::Match($line, 'session id:\s*([0-9a-fA-F-]{36})')
        if ($match.Success) {
            $sessionId = $match.Groups[1].Value
            break
        }
    }

    return @{
        SessionId = $sessionId
        Usage = $null
    }
}

function Find-CodexGeneratedImagePath {
    param(
        [AllowEmptyString()]
        [string]$SessionId,
        [datetime]$StartedAt
    )

    $generatedImagesRoot = Join-Path (Get-CodexHomePath) "generated_images"
    if (-not (Test-Path -LiteralPath $generatedImagesRoot)) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        $sessionDirectory = Join-Path $generatedImagesRoot $SessionId
        if (Test-Path -LiteralPath $sessionDirectory) {
            $sessionFiles = @(Get-ChildItem -LiteralPath $sessionDirectory -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
            if ($sessionFiles.Count -gt 0) {
                return $sessionFiles[0].FullName
            }
        }
    }

    $recentFiles = @(Get-ChildItem -LiteralPath $generatedImagesRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $StartedAt.AddSeconds(-5) } |
        Sort-Object LastWriteTime -Descending)

    if ($recentFiles.Count -gt 0) {
        return $recentFiles[0].FullName
    }

    return $null
}

function Get-OptionalPropertyString {
    param(
        [AllowNull()]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $Object) {
        return ""
    }

    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return ""
    }

    if ($null -eq $property.Value) {
        return ""
    }

    return [string]$property.Value
}

function Save-SummaryMarkdown {
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
        [psobject]$Usage
    )

    $duration = [math]::Round(($FinishedAt - $StartedAt).TotalSeconds, 2)
    $status = if ($ExitCode -eq 0) { "success" } else { "failed" }
    $relativeMessage = "assistant_last_message.md"
    $relativeLog = "console.log"
    $relativePrompt = "prompt.txt"
    $startedText = $StartedAt.ToString('yyyy-MM-dd HH:mm:ss zzz')
    $finishedText = $FinishedAt.ToString('yyyy-MM-dd HH:mm:ss zzz')
    $inputTokens = Get-OptionalPropertyString -Object $Usage -PropertyName "input_tokens"
    $cachedInputTokens = Get-OptionalPropertyString -Object $Usage -PropertyName "cached_input_tokens"
    $outputTokens = Get-OptionalPropertyString -Object $Usage -PropertyName "output_tokens"
    $reasoningTokens = Get-OptionalPropertyString -Object $Usage -PropertyName "reasoning_output_tokens"

    $lines = @(
        "# Codex CLI Run Summary"
        ""
        "- Status: $status"
        "- Exit code: $ExitCode"
        "- Started: $startedText"
        "- Finished: $finishedText"
        "- Duration seconds: $duration"
        ('- Workspace: `{0}`' -f (Get-RelativeWorkflowPath -Path $WorkspacePath))
        ('- Run directory: `{0}`' -f (Get-RelativeWorkflowPath -Path $RunDirectory))
        ('- Command: `{0}`' -f $CodexCommandLine)
        ('- Thread ID: `{0}`' -f $ThreadId)
        ""
        "## Files"
        ""
        "- Prompt: [$relativePrompt](./$relativePrompt)"
        "- Last message: [$relativeMessage](./$relativeMessage)"
        "- Console log: [$relativeLog](./$relativeLog)"
        ""
        "## Usage"
        ""
        "- Input tokens: $inputTokens"
        "- Cached input tokens: $cachedInputTokens"
        "- Output tokens: $outputTokens"
        "- Reasoning output tokens: $reasoningTokens"
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

    [System.IO.File]::WriteAllText($SummaryPath, ($lines -join "`r`n"), [System.Text.UTF8Encoding]::new($false))
}

function Save-BatchSummaryMarkdown {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SummaryPath,
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,
        [Parameter(Mandatory = $true)]
        [string]$BatchDirectory,
        [Parameter(Mandatory = $true)]
        [object[]]$RunSummaries,
        [Parameter(Mandatory = $true)]
        [datetime]$StartedAt,
        [Parameter(Mandatory = $true)]
        [datetime]$FinishedAt
    )

    $duration = [math]::Round(($FinishedAt - $StartedAt).TotalSeconds, 2)
    $successCount = @($RunSummaries | Where-Object { $_.ExitCode -eq 0 }).Count
    $failedCount = @($RunSummaries | Where-Object { $_.ExitCode -ne 0 }).Count

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("# Codex CLI Batch Summary")
    [void]$lines.Add("")
    [void]$lines.Add("- Started: $($StartedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))")
    [void]$lines.Add("- Finished: $($FinishedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))")
    [void]$lines.Add("- Duration seconds: $duration")
    [void]$lines.Add(('- Workspace: `{0}`' -f (Get-RelativeWorkflowPath -Path $WorkspacePath)))
    [void]$lines.Add(('- Batch directory: `{0}`' -f (Get-RelativeWorkflowPath -Path $BatchDirectory)))
    [void]$lines.Add("- Total prompts: $($RunSummaries.Count)")
    [void]$lines.Add("- Successful prompts: $successCount")
    [void]$lines.Add("- Failed prompts: $failedCount")
    [void]$lines.Add("")
    [void]$lines.Add("## Runs")
    [void]$lines.Add("")

    foreach ($run in $RunSummaries) {
        [void]$lines.Add("### $($run.Index). $($run.Name)")
        [void]$lines.Add("")
        [void]$lines.Add("- Status: $($run.Status)")
        [void]$lines.Add("- Exit code: $($run.ExitCode)")
        [void]$lines.Add("- Directory: [$($run.DirectoryName)](./$($run.DirectoryName)/)")
        [void]$lines.Add("- Summary: [summary.md](./$($run.DirectoryName)/summary.md)")
        [void]$lines.Add("- Last message: [assistant_last_message.md](./$($run.DirectoryName)/assistant_last_message.md)")
        [void]$lines.Add("")
        [void]$lines.Add("Prompt:")
        [void]$lines.Add((Convert-ToMarkdownCodeBlock -Text $run.PromptText))
        [void]$lines.Add("")
        [void]$lines.Add("Final answer:")
        [void]$lines.Add((Convert-ToMarkdownCodeBlock -Text $run.LastMessageText))
        [void]$lines.Add("")
    }

    [System.IO.File]::WriteAllText($SummaryPath, ($lines -join "`r`n"), [System.Text.UTF8Encoding]::new($false))
}

function Update-PromptBatchProgress {
    param(
        [Parameter(Mandatory = $true)]
        [int]$CompletedCount,
        [Parameter(Mandatory = $true)]
        [int]$TotalCount,
        [Parameter(Mandatory = $true)]
        [int]$SuccessCount,
        [Parameter(Mandatory = $true)]
        [int]$FailedCount,
        [AllowEmptyString()]
        [string]$CurrentOperation
    )

    if ($TotalCount -le 0) {
        return
    }

    $status = "Completed $CompletedCount/$TotalCount | Success $SuccessCount | Failed $FailedCount"
    $operationText = if ([string]::IsNullOrWhiteSpace($CurrentOperation)) { "Waiting for next prompt" } else { $CurrentOperation }
    $subCompleted = if ($CompletedCount -ge $TotalCount -or $operationText.StartsWith("Completed ", [System.StringComparison]::OrdinalIgnoreCase)) { 1 } else { 0 }

    Write-WorkflowSerialProgress `
        -Key "prompt-batch" `
        -TotalLabel "Prompt batch" `
        -TotalCompleted $CompletedCount `
        -TotalCount $TotalCount `
        -SubLabel $operationText `
        -SubCompleted $subCompleted `
        -SubCount 1 `
        -Status $status
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
        [int]$ExitCode,
        [switch]$SuppressSavedPath
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
    if (-not $SuppressSavedPath) {
        Write-Host ("saved: {0}" -f $relativeMessagePath) -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Invoke-CodexPromptRun {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CliPaths,
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,
        [Parameter(Mandatory = $true)]
        [string]$OutputRootPath,
        [Parameter(Mandatory = $true)]
        [string]$PromptText,
        [AllowEmptyString()]
        [string]$RunName,
        [AllowEmptyString()]
        [string]$Model,
        [AllowEmptyString()]
        [string]$Profile,
        [switch]$GenerateImage,
        [string]$ImageOutputPath,
        [string]$ImageArtifactsRoot,
        [string]$ImageAspectRatio,
        [string]$ImageSize,
        [string]$ImageQuality,
        [string]$ImageOutputFormat,
        [string]$ImageOutputCompression,
        [string]$ImageModeration,
        [string]$ImageReferencePathsJson,
        [int]$ImageMaxAttempts = 6,
        [int]$ImageRetryBaseDelaySeconds = 2,
        [int]$ImageRetryMaxDelaySeconds = 20,
        [int]$TimeoutSeconds = 600,
        [int]$ImageRequestTimeoutSeconds = 600,
        [int]$ImageTotalTimeoutSeconds = 1800,
        [int]$Index = 1,
        [switch]$NoArchive
    )

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $baseName = if ([string]::IsNullOrWhiteSpace($RunName)) { New-Slug -Text $PromptText } else { New-Slug -Text $RunName }

    if (-not [string]::IsNullOrWhiteSpace($ImageArtifactsRoot)) {
        $ImageArtifactsRoot = Resolve-WorkflowPath -Path $ImageArtifactsRoot
    }

    if (-not [string]::IsNullOrWhiteSpace($ImageOutputPath)) {
        $ImageOutputPath = Resolve-WorkflowPath -Path $ImageOutputPath
    }

    if ($NoArchive -and -not $GenerateImage) {
        $runDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-workflow-{0}" -f [guid]::NewGuid().ToString('N'))
    }
    elseif ($GenerateImage -and -not [string]::IsNullOrWhiteSpace($ImageArtifactsRoot)) {
        $runDirectory = Join-Path ([System.IO.Path]::GetFullPath($ImageArtifactsRoot)) $baseName
    }
    elseif ($GenerateImage -and -not [string]::IsNullOrWhiteSpace($ImageOutputPath)) {
        $imageParent = Split-Path -Parent $ImageOutputPath
        if ([string]::IsNullOrWhiteSpace($imageParent)) {
            $runDirectory = Join-Path $OutputRootPath ("{0}_{1}" -f $timestamp, $baseName)
        }
        else {
            $runDirectory = [System.IO.Path]::GetFullPath($imageParent)
        }
    }
    else {
        $runDirectory = Join-Path $OutputRootPath ("{0}_{1}" -f $timestamp, $baseName)
    }

    [System.IO.Directory]::CreateDirectory($runDirectory) | Out-Null

    $promptPath = Join-Path $runDirectory "prompt.txt"
    $lastMessagePath = Join-Path $runDirectory "assistant_last_message.md"
    $consoleLogPath = Join-Path $runDirectory "console.log"
    $summaryPath = Join-Path $runDirectory "summary.md"

    [System.IO.File]::WriteAllText($promptPath, $PromptText, [System.Text.UTF8Encoding]::new($false))

    if ($GenerateImage) {
        if (-not $ImageOutputPath) {
            $ImageOutputPath = Join-Path $runDirectory "output.png"
        }

        $displayImageOutputPath = Get-RelativeWorkflowPath -Path $ImageOutputPath

        $startedAt = Get-Date
        $exitCode = 0
        $lastMessageText = ""
        $imageResult = $null
        $imageApiSettings = Get-ImageApiSettings
        $referenceImagePaths = @(ConvertFrom-ImageReferencePathsJson -Json $ImageReferencePathsJson)

        try {
            $imageResult = Invoke-OpenAIImageGeneration `
                -PromptText $PromptText `
                -OutputPath $ImageOutputPath `
                -Model $Model `
                -AspectRatio $ImageAspectRatio `
                -Size $ImageSize `
                -Quality $ImageQuality `
                -OutputFormat $ImageOutputFormat `
                -OutputCompression $ImageOutputCompression `
                -Moderation $ImageModeration `
                -ReferenceImagePaths $referenceImagePaths `
                -MaxAttempts $ImageMaxAttempts `
                -RetryBaseDelaySeconds $ImageRetryBaseDelaySeconds `
                -RetryMaxDelaySeconds $ImageRetryMaxDelaySeconds `
                -RequestTimeoutSeconds $ImageRequestTimeoutSeconds `
                -TotalTimeoutSeconds $ImageTotalTimeoutSeconds
            $lastMessageText = "saved: $displayImageOutputPath"
            $consoleLines = @(
                "Generated image via OpenAI-compatible Images API."
                "Endpoint: $($imageResult.Endpoint)"
                "Model: $($imageResult.Model)"
                "API profile: $($imageResult.ProfileName)"
                "Provider: $($imageResult.ProviderName)"
                "Aspect ratio: $($imageResult.AspectRatio)"
                "Size: $($imageResult.Size)"
                "Quality: $($imageResult.Quality)"
                "Format: $($imageResult.OutputFormat)"
                "Attempts: $($imageResult.AttemptCount)"
                "Reference images: $($imageResult.ReferenceImageCount)"
                "Output: $displayImageOutputPath"
            )
            [System.IO.File]::WriteAllText($consoleLogPath, ($consoleLines -join "`r`n"), [System.Text.UTF8Encoding]::new($false))
        }
        catch {
            $exitCode = 1
            $lastMessageText = $_.Exception.Message
            $errorText = @(
                "Endpoint: $(Get-ImagesGenerationEndpoint -BaseUrl $imageApiSettings.BaseUrl)"
                "Model: $(if ([string]::IsNullOrWhiteSpace($Model)) { $imageApiSettings.DefaultModel } else { $Model })"
                "Provider: $($imageApiSettings.ProviderName)"
                "Reference images: $($referenceImagePaths.Count)"
                ""
                ($_ | Out-String).TrimEnd()
            ) -join "`r`n"
            [System.IO.File]::WriteAllText($consoleLogPath, $errorText, [System.Text.UTF8Encoding]::new($false))
        }

        $finishedAt = Get-Date
        [System.IO.File]::WriteAllText($lastMessagePath, $lastMessageText, [System.Text.UTF8Encoding]::new($false))

        Save-SummaryMarkdown `
            -SummaryPath $summaryPath `
            -PromptText $PromptText `
            -LastMessageText $lastMessageText `
            -WorkspacePath $WorkspacePath `
            -RunDirectory $runDirectory `
            -ExitCode $exitCode `
            -StartedAt $startedAt `
            -FinishedAt $finishedAt `
            -CodexCommandLine ("openai images.generate -> {0}" -f $displayImageOutputPath) `
            -ThreadId $null `
            -Usage $(if ($imageResult) { $imageResult.Usage } else { $null })

        Write-TerminalRunResult `
            -Index $Index `
            -Title $baseName `
            -Text $lastMessageText `
            -MessagePath $lastMessagePath `
            -ExitCode $exitCode

        Write-WorkflowRunIndex -Entry @{
            type = 'image'
            status = $(if ($exitCode -eq 0) { 'success' } else { 'failed' })
            exitCode = $exitCode
            startedAt = $startedAt.ToString('o')
            finishedAt = $finishedAt.ToString('o')
            runDirectory = $runDirectory
            relativeRunDirectory = Get-RelativeWorkflowPath -Path $runDirectory
            model = $Model
            name = $baseName
            usage = $(if ($imageResult) { $imageResult.Usage } else { $null })
        } | Out-Null

        return @{
            Index = $Index
            Name = $baseName
            DirectoryName = [System.IO.Path]::GetFileName($runDirectory)
            RunDirectory = $runDirectory
            ExitCode = $exitCode
            Status = $(if ($exitCode -eq 0) { "success" } else { "failed" })
            PromptText = $PromptText
            LastMessageText = $lastMessageText
            SummaryPath = $summaryPath
            Usage = $(if ($imageResult) { $imageResult.Usage } else { $null })
        }
    }

    $codexArgs = @(
        "exec",
        "--skip-git-repo-check",
        "-C",
        $WorkspacePath,
        "--color",
        "never",
        "--output-last-message",
        $lastMessagePath
    )

    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $codexArgs += @("-m", $Model)
    }

    if (-not [string]::IsNullOrWhiteSpace($Profile)) {
        $codexArgs += @("-p", $Profile)
    }

    $codexArgs += @($PromptText)

    $startedAt = Get-Date
    $codexCommandLine = "codex " + ($codexArgs -join " ")

    Move-WorkflowCursorBelowProgress
    Write-Host ("[{0}] running: {1}" -f $Index, $baseName)

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
    catch {
        $_ | Out-String | Set-Content -LiteralPath $consoleLogPath -Encoding utf8
        throw
    }
    finally {
        $finishedAt = Get-Date
    }

    $runResult = Get-CodexRunResult -OutputLines $invokeResult.OutputLines
    $lastMessageText = if (Test-Path -LiteralPath $lastMessagePath -PathType Leaf) {
        [System.IO.File]::ReadAllText($lastMessagePath, [System.Text.UTF8Encoding]::new($false)).TrimEnd()
    }
    else {
        $runResult.LastMessage
    }
    [System.IO.File]::WriteAllText($lastMessagePath, $lastMessageText, [System.Text.UTF8Encoding]::new($false))

    if (-not $NoArchive) {
        Save-SummaryMarkdown `
            -SummaryPath $summaryPath `
            -PromptText $PromptText `
            -LastMessageText $lastMessageText `
            -WorkspacePath $WorkspacePath `
            -RunDirectory $runDirectory `
            -ExitCode $exitCode `
            -StartedAt $startedAt `
            -FinishedAt $finishedAt `
            -CodexCommandLine $codexCommandLine `
            -ThreadId $runResult.ThreadId `
            -Usage $runResult.Usage
    }

    Write-TerminalRunResult `
        -Index $Index `
        -Title $baseName `
        -Text $lastMessageText `
        -MessagePath $lastMessagePath `
        -ExitCode $exitCode `
        -SuppressSavedPath:$NoArchive

    if (-not $NoArchive) {
        Write-WorkflowRunIndex -Entry @{
            type = 'text'
            status = $(if ($exitCode -eq 0) { 'success' } else { 'failed' })
            exitCode = $exitCode
            timedOut = [bool]$invokeResult.TimedOut
            startedAt = $startedAt.ToString('o')
            finishedAt = $finishedAt.ToString('o')
            runDirectory = $runDirectory
            relativeRunDirectory = Get-RelativeWorkflowPath -Path $runDirectory
            model = $Model
            profile = $Profile
            name = $baseName
            threadId = $runResult.ThreadId
            usage = $runResult.Usage
        } | Out-Null
    }

    return @{
        Index = $Index
        Name = $baseName
        DirectoryName = [System.IO.Path]::GetFileName($runDirectory)
        RunDirectory = $runDirectory
        ExitCode = $exitCode
        Status = $(if ($exitCode -eq 0) { "success" } else { "failed" })
        PromptText = $PromptText
        LastMessageText = $lastMessageText
        SummaryPath = $summaryPath
        Usage = $runResult.Usage
    }
}

function Get-WorkflowFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Save-PromptBatchState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$State
    )

    $State.UpdatedAt = (Get-Date).ToString('o')
    $temporaryPath = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temporaryPath, ($State | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

$cliPaths = Get-CodexCliPaths
$resolvedWorkspace = Resolve-WorkflowPath -Path $Workspace -MustExist
$resolvedOutputRoot = Resolve-WorkflowPath -Path $OutputRoot
[System.IO.Directory]::CreateDirectory($resolvedOutputRoot) | Out-Null

if ($PSCmdlet.ParameterSetName -eq "PromptListFile") {
    $resolvedPromptListFile = Resolve-WorkflowPath -Path $PromptListFile -MustExist
    $promptListText = [System.IO.File]::ReadAllText($resolvedPromptListFile, $Utf8NoBom)
    $promptEntries = @(Get-PromptEntriesFromText -Text $promptListText)

    if ($promptEntries.Count -eq 0) {
        throw "Prompt list file does not contain any prompts."
    }

    if ($ParseOnly) {
        Write-Host ("Prompt list parsed successfully: {0} prompts" -f $promptEntries.Count) -ForegroundColor Green
        for ($previewIndex = 0; $previewIndex -lt [Math]::Min(5, $promptEntries.Count); $previewIndex++) {
            $preview = ([string]$promptEntries[$previewIndex] -replace '\s+', ' ').Trim()
            if ($preview.Length -gt 100) { $preview = $preview.Substring(0, 97) + '...' }
            Write-Host ("[{0}] {1}" -f ($previewIndex + 1), $preview)
        }
        exit 0
    }

    $sourceHash = Get-WorkflowFileSha256 -Path $resolvedPromptListFile
    $runSummaries = New-Object System.Collections.Generic.List[object]
    $finalExitCode = 0
    $successCount = 0
    $failedCount = 0
    $startIndex = 0

    if (-not [string]::IsNullOrWhiteSpace($ResumeBatchStatePath)) {
        $statePath = Resolve-WorkflowPath -Path $ResumeBatchStatePath -MustExist
        $batchState = [System.IO.File]::ReadAllText($statePath, $Utf8NoBom) | ConvertFrom-Json -ErrorAction Stop
        foreach ($stateProperty in @('CompletedAt', 'LastError')) {
            if (-not $batchState.PSObject.Properties[$stateProperty]) {
                $batchState | Add-Member -NotePropertyName $stateProperty -NotePropertyValue ''
            }
        }
        if ([string]$batchState.SourceHash -ne $sourceHash) {
            throw "Prompt list changed since this batch state was created. Start a new batch or restore the original file."
        }
        if ([int]$batchState.PromptCount -ne $promptEntries.Count) {
            throw "Prompt count does not match the saved batch state."
        }

        $batchDirectory = [string]$batchState.BatchDirectory
        if (-not (Test-Path -LiteralPath $batchDirectory -PathType Container)) {
            throw "Prompt batch directory not found: $batchDirectory"
        }
        $batchStartedAt = [datetime]$batchState.StartedAt
        $startIndex = [Math]::Max(0, [Math]::Min($promptEntries.Count, [int]$batchState.NextIndex))
        foreach ($storedRun in @($batchState.Runs)) {
            if ([int]$storedRun.Index -le $startIndex) {
                [void]$runSummaries.Add($storedRun)
                if ([int]$storedRun.ExitCode -eq 0) { $successCount++ } else { $failedCount++ }
            }
        }
        Write-Host ("resuming prompt batch at {0}/{1}: {2}" -f ($startIndex + 1), $promptEntries.Count, (Get-RelativeWorkflowPath -Path $statePath))
    }
    else {
        $batchStartedAt = Get-Date
        $batchTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $batchBaseName = if ([string]::IsNullOrWhiteSpace($RunName)) { "codex-batch" } else { New-Slug -Text $RunName }
        $batchDirectory = Join-Path $resolvedOutputRoot ("{0}_{1}" -f $batchTimestamp, $batchBaseName)
        [System.IO.Directory]::CreateDirectory($batchDirectory) | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $batchDirectory "prompt_list.txt"), $promptListText, [System.Text.UTF8Encoding]::new($false))
        $statePath = Join-Path $batchDirectory 'prompt_batch_state.json'
        $batchState = [pscustomobject]@{
            Version = 1
            Status = 'running'
            SourcePath = $resolvedPromptListFile
            SourceHash = $sourceHash
            PromptCount = $promptEntries.Count
            BatchDirectory = $batchDirectory
            StartedAt = $batchStartedAt.ToString('o')
            UpdatedAt = $batchStartedAt.ToString('o')
            NextIndex = 0
            FailurePolicy = $BatchFailurePolicy
            Runs = @()
            LastError = ''
            CompletedAt = ''
        }
        Save-PromptBatchState -Path $statePath -State $batchState
    }

    $batchState.Status = 'running'
    $batchState.FailurePolicy = $BatchFailurePolicy
    Save-PromptBatchState -Path $statePath -State $batchState

    Update-PromptBatchProgress -CompletedCount $startIndex -TotalCount $promptEntries.Count -SuccessCount $successCount -FailedCount $failedCount -CurrentOperation "Preparing prompt batch"

    try {
        for ($i = $startIndex; $i -lt $promptEntries.Count; $i++) {
            $entryText = $promptEntries[$i]
            $entryName = "prompt-{0:D3}-{1}" -f ($i + 1), (New-Slug -Text $entryText)

            Update-PromptBatchProgress `
                -CompletedCount $i `
                -TotalCount $promptEntries.Count `
                -SuccessCount $successCount `
                -FailedCount $failedCount `
                -CurrentOperation ("Running {0}" -f $entryName)

            $runSummary = Invoke-CodexPromptRun `
                -CliPaths $cliPaths `
                -WorkspacePath $resolvedWorkspace `
                -OutputRootPath $batchDirectory `
                -PromptText $entryText `
                -RunName $entryName `
                -Model $Model `
                -Profile $Profile `
                -ImageMaxAttempts $ImageMaxAttempts `
                -ImageRetryBaseDelaySeconds $ImageRetryBaseDelaySeconds `
                -ImageRetryMaxDelaySeconds $ImageRetryMaxDelaySeconds `
                -TimeoutSeconds $TimeoutSeconds `
                -Index ($i + 1)

            [void]$runSummaries.Add($runSummary)
            if ($runSummary.ExitCode -eq 0) {
                $successCount += 1
            }
            else {
                $failedCount += 1
                $finalExitCode = $runSummary.ExitCode
            }

            $batchState.Runs = @($runSummaries.ToArray())
            $batchState.NextIndex = if ($runSummary.ExitCode -ne 0 -and $BatchFailurePolicy -eq 'Stop') { $i } else { $i + 1 }
            $batchState.LastError = if ($runSummary.ExitCode -eq 0) { '' } else { [string]$runSummary.LastMessageText }
            Save-PromptBatchState -Path $statePath -State $batchState

            Update-PromptBatchProgress `
                -CompletedCount ($i + 1) `
                -TotalCount $promptEntries.Count `
                -SuccessCount $successCount `
                -FailedCount $failedCount `
                -CurrentOperation ("Completed {0}" -f $entryName)

            if ($runSummary.ExitCode -ne 0 -and $BatchFailurePolicy -eq 'Stop') {
                break
            }
        }
    }
    catch {
        $batchState.Status = 'failed'
        $batchState.LastError = $_.Exception.Message
        Save-PromptBatchState -Path $statePath -State $batchState
        throw
    }
    finally {
        # The custom fixed progress remains visible after the last update.
    }

    $batchFinishedAt = Get-Date
    $batchSummaryPath = Join-Path $batchDirectory "batch_summary.md"
    Save-BatchSummaryMarkdown `
        -SummaryPath $batchSummaryPath `
        -WorkspacePath $resolvedWorkspace `
        -BatchDirectory $batchDirectory `
        -RunSummaries $runSummaries.ToArray() `
        -StartedAt $batchStartedAt `
        -FinishedAt $batchFinishedAt

    $batchState.Status = if ($failedCount -gt 0) { 'failed' } else { 'completed' }
    $batchState.CompletedAt = $batchFinishedAt.ToString('o')
    $batchState.Runs = @($runSummaries.ToArray())
    Save-PromptBatchState -Path $statePath -State $batchState

    Move-WorkflowCursorBelowProgress
    Write-Host ("batch summary: {0}" -f (Get-RelativeWorkflowPath -Path $batchSummaryPath))
    Write-Host ("batch state: {0}" -f (Get-RelativeWorkflowPath -Path $statePath))

    if (-not $NoReopenWindow) {
        Start-NewCodexWindow -WorkspacePath $resolvedWorkspace
        Write-Host "A new Codex window has been opened."
    }

    exit $finalExitCode
}

if ($PSCmdlet.ParameterSetName -eq "PromptFile") {
    $resolvedPromptFile = Resolve-WorkflowPath -Path $PromptFile -MustExist
    $promptText = [System.IO.File]::ReadAllText($resolvedPromptFile, $Utf8NoBom)
}
else {
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        $Prompt = Read-Host "Enter the prompt for Codex CLI"
    }

    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        throw "Prompt must not be empty."
    }

    $promptText = $Prompt
}

$singleRun = Invoke-CodexPromptRun `
    -CliPaths $cliPaths `
    -WorkspacePath $resolvedWorkspace `
    -OutputRootPath $resolvedOutputRoot `
    -PromptText $promptText `
    -RunName $RunName `
    -Model $Model `
    -Profile $Profile `
    -GenerateImage:$GenerateImage `
    -ImageOutputPath $ImageOutputPath `
    -ImageArtifactsRoot $ImageArtifactsRoot `
    -ImageAspectRatio $ImageAspectRatio `
    -ImageSize $ImageSize `
    -ImageQuality $ImageQuality `
    -ImageOutputFormat $ImageOutputFormat `
    -ImageOutputCompression $ImageOutputCompression `
    -ImageModeration $ImageModeration `
    -ImageReferencePathsJson $ImageReferencePathsJson `
    -ImageMaxAttempts $ImageMaxAttempts `
    -ImageRetryBaseDelaySeconds $ImageRetryBaseDelaySeconds `
    -ImageRetryMaxDelaySeconds $ImageRetryMaxDelaySeconds `
    -TimeoutSeconds $TimeoutSeconds `
    -ImageRequestTimeoutSeconds $ImageRequestTimeoutSeconds `
    -ImageTotalTimeoutSeconds $ImageTotalTimeoutSeconds `
    -NoArchive:$NoArchive `
    -Index 1

if ($singleRun.ExitCode -eq 0) {
    if ($GenerateImage -and $OpenResult -and (Test-Path -LiteralPath $ImageOutputPath -PathType Leaf)) {
        try { Start-Process -FilePath $ImageOutputPath } catch { Write-Warning ("Could not open image: {0}" -f $_.Exception.Message) }
    }
    if ($GenerateImage -and $OpenResultFolder -and -not [string]::IsNullOrWhiteSpace($ImageOutputPath)) {
        $resultFolder = Split-Path -Parent ([System.IO.Path]::GetFullPath($ImageOutputPath))
        if (Test-Path -LiteralPath $resultFolder -PathType Container) {
            try { Start-Process -FilePath $resultFolder } catch { Write-Warning ("Could not open image folder: {0}" -f $_.Exception.Message) }
        }
    }
    if (-not $GenerateImage -and -not $NoArchive -and $OpenSummary -and (Test-Path -LiteralPath $singleRun.SummaryPath -PathType Leaf)) {
        try { Start-Process -FilePath $singleRun.SummaryPath } catch { Write-Warning ("Could not open summary: {0}" -f $_.Exception.Message) }
    }
}

if ($NoArchive -and -not $GenerateImage -and (Test-Path -LiteralPath $singleRun.RunDirectory -PathType Container)) {
    Remove-Item -LiteralPath $singleRun.RunDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $NoReopenWindow) {
    Start-NewCodexWindow -WorkspacePath $resolvedWorkspace
    Write-Host "A new Codex window has been opened."
}

exit $singleRun.ExitCode
