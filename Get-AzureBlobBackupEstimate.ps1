#requires -Version 7.0

<#
.SYNOPSIS
Measures active Azure blobs and estimates Azure Blob vaulted-backup costs.

.DESCRIPTION
Runs a metadata-only preflight and inventory against explicitly selected,
interactively selected, or all enabled Azure subscriptions in the active tenant.
The full scan measures active BlockBlob, AppendBlob, and PageBlob objects,
retrieves current Microsoft retail rates, and creates configurable retention and
daily-churn cost scenarios.

.EXAMPLE
pwsh ./Get-AzureBlobBackupEstimate.ps1 `
  -SubscriptionId "<subscription-id>" `
  -PreflightOnly `
  -OutputDirectory ./azure-blob-backup-results

.EXAMPLE
pwsh ./Get-AzureBlobBackupEstimate.ps1 `
  -SubscriptionId "<subscription-id>" `
  -AccountNamePrefix "exampledata" `
  -ExpectedAccountCount 10 `
  -FullScan `
  -OutputDirectory ./azure-blob-backup-results

.EXAMPLE
pwsh ./Get-AzureBlobBackupEstimate.ps1 `
  -AllEnabledSubscriptions `
  -ExpectedAccountCount 25 `
  -PreflightOnly `
  -OutputDirectory ./azure-blob-backup-results

.EXAMPLE
pwsh ./Get-AzureBlobBackupEstimate.ps1 `
  -PreflightOnly `
  -OutputDirectory ./azure-blob-backup-results

Displays an interactive picker for enabled subscriptions in the active tenant.

.NOTES
Generated output can contain Azure resource identifiers and must not be
committed to a public repository.
#>

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId = @(),
    [switch]$AllEnabledSubscriptions,
    [string]$SubscriptionFile = "",
    [string]$AccountNamePrefix = "",
    [ValidateRange(0, 1000000)]
    [int]$ExpectedAccountCount = 0,
    [int[]]$RetentionDays = @(10, 33),
    [double[]]$DailyChurnPercent = @(1, 3, 5),
    [ValidateSet("LRS", "GRS", "RA-GRS")]
    [string[]]$VaultRedundancy = @("LRS", "GRS", "RA-GRS"),
    [string]$OutputDirectory = (Join-Path (Get-Location) ("Azure-blob-backup-assessment-{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))),
    [switch]$PreflightOnly,
    [switch]$FullScan,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($PreflightOnly -and $FullScan) {
    throw "Use either -PreflightOnly or -FullScan, not both."
}
if (-not $PreflightOnly -and -not $FullScan) {
    throw "Specify -PreflightOnly first. After it passes, rerun with -FullScan."
}
if ($AllEnabledSubscriptions -and $SubscriptionId.Count -gt 0) {
    throw "Use either -SubscriptionId or -AllEnabledSubscriptions, not both."
}

$requiredRoles = @(
    "Reader",
    "Storage Blob Data Reader"
)
$script:StorageToken = $null
$script:StorageTokenObtainedUtc = [datetime]::MinValue
$script:PricingCache = @{}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine)
}

function Get-StorageHeaders {
    if (
        -not $script:StorageToken -or
        ((Get-Date).ToUniversalTime() - $script:StorageTokenObtainedUtc).TotalMinutes -ge 45
    ) {
        $script:StorageToken = (
            Invoke-AzCli @(
                "account", "get-access-token",
                "--resource", "https://storage.azure.com/",
                "--query", "accessToken",
                "--output", "tsv",
                "--only-show-errors"
            )
        ).Trim()
        $script:StorageTokenObtainedUtc = (Get-Date).ToUniversalTime()
    }

    return @{
        Authorization  = "Bearer $($script:StorageToken)"
        "x-ms-date"    = (Get-Date).ToUniversalTime().ToString("R")
        "x-ms-version" = "2023-11-03"
    }
}

function Invoke-StorageList {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $maximumAttempts = 6
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Uri $Uri `
                -Method Get `
                -Headers (Get-StorageHeaders) `
                -TimeoutSec 180 `
                -UseBasicParsing
            return [xml]$response.Content
        }
        catch {
            $statusCode = $null
            $responseProperty = $_.Exception.PSObject.Properties["Response"]
            if ($responseProperty -and $null -ne $responseProperty.Value) {
                $statusCodeProperty = $responseProperty.Value.PSObject.Properties["StatusCode"]
                if ($statusCodeProperty) {
                    $statusCode = [int]$statusCodeProperty.Value
                }
            }

            if ($statusCode -eq 401) {
                $script:StorageToken = $null
            }

            $retryable = $statusCode -in @(401, 408, 429, 500, 502, 503, 504)
            if (-not $retryable -or $attempt -eq $maximumAttempts) {
                throw
            }

            Start-Sleep -Seconds ([Math]::Min(60, [Math]::Pow(2, $attempt)))
        }
    }
}

function Get-Containers {
    param(
        [Parameter(Mandatory)]
        [string]$BlobEndpoint,
        [switch]$OneOnly
    )

    $endpoint = $BlobEndpoint.TrimEnd("/") + "/"
    $marker = ""
    $containers = [System.Collections.Generic.List[string]]::new()

    do {
        $maxResults = if ($OneOnly) { 1 } else { 5000 }
        $uri = "{0}?comp=list&maxresults={1}" -f $endpoint, $maxResults
        if ($marker) {
            $uri += "&marker=$([Uri]::EscapeDataString($marker))"
        }

        $document = Invoke-StorageList -Uri $uri
        foreach ($container in @($document.EnumerationResults.Containers.Container)) {
            if ($null -ne $container -and $container.Name) {
                $containers.Add([string]$container.Name)
            }
        }

        if ($OneOnly) {
            break
        }
        $marker = [string]$document.EnumerationResults.NextMarker
    } while ($marker)

    return $containers.ToArray()
}

function Measure-ContainerBlobs {
    param(
        [Parameter(Mandatory)]
        [string]$BlobEndpoint,
        [Parameter(Mandatory)]
        [string]$ContainerName
    )

    $endpoint = $BlobEndpoint.TrimEnd("/") + "/"
    $encodedContainer = [Uri]::EscapeDataString($ContainerName)
    $marker = ""
    [decimal]$blockBytes = 0
    [decimal]$appendBytes = 0
    [decimal]$pageBytes = 0
    [long]$blockCount = 0
    [long]$appendCount = 0
    [long]$pageCount = 0
    [long]$listRequests = 0

    do {
        $uri = "{0}{1}?restype=container&comp=list&maxresults=5000" -f $endpoint, $encodedContainer
        if ($marker) {
            $uri += "&marker=$([Uri]::EscapeDataString($marker))"
        }

        $document = Invoke-StorageList -Uri $uri
        $listRequests++

        foreach ($blob in @($document.EnumerationResults.Blobs.Blob)) {
            if ($null -eq $blob) {
                continue
            }

            [decimal]$length = 0
            if ($blob.Properties."Content-Length") {
                $length = [decimal]$blob.Properties."Content-Length"
            }

            switch ([string]$blob.Properties.BlobType) {
                "BlockBlob" {
                    $blockBytes += $length
                    $blockCount++
                }
                "AppendBlob" {
                    $appendBytes += $length
                    $appendCount++
                }
                "PageBlob" {
                    $pageBytes += $length
                    $pageCount++
                }
            }
        }

        $marker = [string]$document.EnumerationResults.NextMarker
    } while ($marker)

    return [pscustomobject]@{
        ContainerName = $ContainerName
        BlockBytes    = $blockBytes
        BlockCount    = $blockCount
        AppendBytes   = $appendBytes
        AppendCount   = $appendCount
        PageBytes     = $pageBytes
        PageCount     = $pageCount
        ListRequests  = $listRequests
    }
}

function Measure-StorageAccount {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Account
    )

    $containers = @(Get-Containers -BlobEndpoint $Account.blobEndpoint)
    [decimal]$blockBytes = 0
    [decimal]$appendBytes = 0
    [decimal]$pageBytes = 0
    [long]$blockCount = 0
    [long]$appendCount = 0
    [long]$pageCount = 0
    [long]$listRequests = 1

    foreach ($containerName in $containers) {
        $measurement = Measure-ContainerBlobs `
            -BlobEndpoint $Account.blobEndpoint `
            -ContainerName $containerName
        $blockBytes += $measurement.BlockBytes
        $blockCount += $measurement.BlockCount
        $appendBytes += $measurement.AppendBytes
        $appendCount += $measurement.AppendCount
        $pageBytes += $measurement.PageBytes
        $pageCount += $measurement.PageCount
        $listRequests += $measurement.ListRequests
    }

    return [pscustomobject]@{
        Status          = "Succeeded"
        SubscriptionId  = $Account.subscriptionId
        ResourceGroup   = $Account.resourceGroup
        AccountName     = $Account.name
        Region          = $Account.location
        Kind            = $Account.kind
        SkuName         = $Account.skuName
        IsHnsEnabled    = [bool]$Account.isHnsEnabled
        ContainerCount  = $containers.Count
        BlockBlobCount  = $blockCount
        BlockBlobBytes  = $blockBytes
        AppendBlobCount = $appendCount
        AppendBlobBytes = $appendBytes
        PageBlobCount   = $pageCount
        PageBlobBytes   = $pageBytes
        ListRequests    = $listRequests
        MeasuredUtc     = (Get-Date).ToUniversalTime().ToString("o")
        Error            = $null
    }
}

function Get-RetailItems {
    param(
        [Parameter(Mandatory)]
        [string]$Region
    )

    if ($script:PricingCache.ContainsKey($Region)) {
        return $script:PricingCache[$Region]
    }

    $filter = [Uri]::EscapeDataString("serviceName eq 'Backup' and armRegionName eq '$Region'")
    $uri = "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&`$filter=$filter"
    $items = [System.Collections.Generic.List[object]]::new()

    while ($uri) {
        $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 120
        foreach ($item in @($response.Items)) {
            $items.Add($item)
        }
        $uri = [string]$response.NextPageLink
    }

    $script:PricingCache[$Region] = $items.ToArray()
    return $script:PricingCache[$Region]
}

function Find-RetailMeter {
    param(
        [Parameter(Mandatory)]
        [object[]]$Items,
        [Parameter(Mandatory)]
        [string]$SkuName,
        [Parameter(Mandatory)]
        [string]$MeterName
    )

    $meter = $Items |
        Where-Object {
            $_.type -eq "Consumption" -and
            $_.skuName -eq $SkuName -and
            $_.meterName -eq $MeterName
        } |
        Sort-Object { [datetime]$_.effectiveStartDate } -Descending |
        Select-Object -First 1

    if (-not $meter) {
        throw "No current retail meter found for SKU '$SkuName', meter '$MeterName'."
    }
    return $meter
}

function Get-AccountRates {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$AccountResult,
        [Parameter(Mandatory)]
        [string]$Redundancy
    )

    $items = @(Get-RetailItems -Region $AccountResult.Region)
    $backupSku = if ($AccountResult.IsHnsEnabled) { "ADLS Gen2 Vaulted" } else { "Azure Blob" }
    $protectedInstance = Find-RetailMeter `
        -Items $items `
        -SkuName $backupSku `
        -MeterName "$backupSku Protected Instance"
    $vaultStorage = Find-RetailMeter `
        -Items $items `
        -SkuName "Standard" `
        -MeterName "Standard $Redundancy Data Stored"
    $writeOperations = Find-RetailMeter `
        -Items $items `
        -SkuName $backupSku `
        -MeterName "$backupSku $Redundancy Write Operations"

    return [pscustomobject]@{
        Region                  = $AccountResult.Region
        AccountType             = $backupSku
        Redundancy              = $Redundancy
        ProtectedInstanceRate   = [decimal]$protectedInstance.retailPrice
        ProtectedInstanceUnit   = [string]$protectedInstance.unitOfMeasure
        ProtectedInstanceMeter  = [string]$protectedInstance.meterName
        ProtectedInstanceId     = [string]$protectedInstance.meterId
        VaultStorageRate        = [decimal]$vaultStorage.retailPrice
        VaultStorageUnit        = [string]$vaultStorage.unitOfMeasure
        VaultStorageMeter       = [string]$vaultStorage.meterName
        VaultStorageId          = [string]$vaultStorage.meterId
        WriteOperationsRate     = [decimal]$writeOperations.retailPrice
        WriteOperationsUnit     = [string]$writeOperations.unitOfMeasure
        WriteOperationsMeter    = [string]$writeOperations.meterName
        WriteOperationsId       = [string]$writeOperations.meterId
        CurrencyCode            = [string]$protectedInstance.currencyCode
        EffectiveStartDate      = [string]$protectedInstance.effectiveStartDate
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]
        [object]$Value,
        [Parameter(Mandatory)]
        [string]$Path,
        [int]$Depth = 10
    )

    $Value |
        ConvertTo-Json -Depth $Depth |
        Set-Content -LiteralPath $Path -Encoding utf8
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI is required. Install it from https://aka.ms/installazurecliwindows."
}

$accountContext = (
    Invoke-AzCli @("account", "show", "--output", "json", "--only-show-errors")
) | ConvertFrom-Json

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$accountResultDirectory = Join-Path $OutputDirectory "account-results"
New-Item -ItemType Directory -Path $accountResultDirectory -Force | Out-Null

Write-Host "Tenant: $($accountContext.tenantId)"
Write-Host "Output: $OutputDirectory"
Write-Host "Required roles: $($requiredRoles -join ', ')"

& az extension add --name resource-graph --upgrade --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Unable to install or update the Azure CLI resource-graph extension."
}

$tenantSubscriptions = @(
    Invoke-AzCli @(
        "account", "list", "--all",
        "--output", "json",
        "--only-show-errors"
    ) |
        ConvertFrom-Json |
        Where-Object {
            $_.state -eq "Enabled" -and
            $_.tenantId -eq $accountContext.tenantId
        }
)
if ($tenantSubscriptions.Count -eq 0) {
    throw "No enabled subscriptions are available in the active tenant."
}

if (-not $SubscriptionFile) {
    $SubscriptionFile = Join-Path $PSScriptRoot "azure-blob-backup-subscriptions.json"
}
$SubscriptionFile = [IO.Path]::GetFullPath($SubscriptionFile)

$resolvedSubscriptions = [System.Collections.Generic.List[object]]::new()
if ($AllEnabledSubscriptions) {
    foreach ($subscription in $tenantSubscriptions) {
        $resolvedSubscriptions.Add($subscription)
    }
}
elseif ($SubscriptionId.Count -gt 0) {
    foreach ($requestedSubscriptionId in $SubscriptionId) {
        $matches = @(
            $tenantSubscriptions |
                Where-Object id -eq $requestedSubscriptionId
        )
        if ($matches.Count -ne 1) {
            throw "Subscription '$requestedSubscriptionId' isn't uniquely available and enabled in the active tenant."
        }
        $resolvedSubscriptions.Add($matches[0])
    }
}
elseif (Test-Path -LiteralPath $SubscriptionFile) {
    $manifest = Get-Content -LiteralPath $SubscriptionFile -Raw | ConvertFrom-Json
    $tenantProperty = $manifest.PSObject.Properties["tenantId"]
    if (
        $tenantProperty -and
        $tenantProperty.Value -and
        $tenantProperty.Value -ne $accountContext.tenantId
    ) {
        throw "Subscription file '$SubscriptionFile' belongs to tenant '$($tenantProperty.Value)', not the active tenant '$($accountContext.tenantId)'."
    }

    $subscriptionsProperty = $manifest.PSObject.Properties["subscriptions"]
    if (-not $subscriptionsProperty) {
        throw "Subscription file '$SubscriptionFile' doesn't contain a subscriptions array."
    }

    $manifestSubscriptionIds = @(
        $subscriptionsProperty.Value |
            Where-Object {
                $includeProperty = $_.PSObject.Properties["include"]
                $includeProperty -and $includeProperty.Value -eq $true
            } |
            ForEach-Object id
    )
    if ($manifestSubscriptionIds.Count -eq 0) {
        throw "Subscription file '$SubscriptionFile' doesn't include any subscriptions."
    }

    foreach ($requestedSubscriptionId in $manifestSubscriptionIds) {
        $matches = @(
            $tenantSubscriptions |
                Where-Object id -eq $requestedSubscriptionId
        )
        if ($matches.Count -ne 1) {
            throw "Subscription '$requestedSubscriptionId' from '$SubscriptionFile' isn't uniquely available and enabled in the active tenant."
        }
        $resolvedSubscriptions.Add($matches[0])
    }
    Write-Host "Loaded subscription selection from: $SubscriptionFile"
}
else {
    Write-Host "Enabled subscriptions in the active tenant:"
    for ($index = 0; $index -lt $tenantSubscriptions.Count; $index++) {
        $subscription = $tenantSubscriptions[$index]
        Write-Host ("  [{0}] {1} [{2}]" -f ($index + 1), $subscription.name, $subscription.id)
    }

    $selection = (Read-Host "Select subscription numbers separated by commas, or enter A for all").Trim()
    if ($selection -match "^(?i:a|all)$") {
        foreach ($subscription in $tenantSubscriptions) {
            $resolvedSubscriptions.Add($subscription)
        }
    }
    else {
        $selectedIndexes = [System.Collections.Generic.List[int]]::new()
        foreach ($value in $selection.Split(",")) {
            $selectedIndex = 0
            if (
                -not [int]::TryParse($value.Trim(), [ref]$selectedIndex) -or
                $selectedIndex -lt 1 -or
                $selectedIndex -gt $tenantSubscriptions.Count
            ) {
                throw "Invalid subscription selection '$($value.Trim())'."
            }
            if (-not $selectedIndexes.Contains($selectedIndex)) {
                $selectedIndexes.Add($selectedIndex)
            }
        }

        if ($selectedIndexes.Count -eq 0) {
            throw "Select at least one subscription."
        }
        foreach ($selectedIndex in $selectedIndexes) {
            $resolvedSubscriptions.Add($tenantSubscriptions[$selectedIndex - 1])
        }
    }

    $selectedSubscriptionIds = @($resolvedSubscriptions | ForEach-Object id)
    $manifestDirectory = Split-Path -Parent $SubscriptionFile
    if ($manifestDirectory) {
        New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    }
    $subscriptionManifest = [ordered]@{
        schemaVersion = 1
        tenantId      = $accountContext.tenantId
        generatedUtc = (Get-Date).ToUniversalTime().ToString("o")
        subscriptions = @(
            $tenantSubscriptions |
                Sort-Object name |
                ForEach-Object {
                    [ordered]@{
                        id      = $_.id
                        name    = $_.name
                        include = $_.id -in $selectedSubscriptionIds
                    }
                }
        )
    }
    Write-JsonFile -Value $subscriptionManifest -Path $SubscriptionFile
    Write-Host "Saved subscription selection to: $SubscriptionFile"
}
$subscriptions = @($resolvedSubscriptions | ForEach-Object id)

Write-Host "Target subscriptions:"
foreach ($subscription in $resolvedSubscriptions) {
    Write-Host "  $($subscription.name) [$($subscription.id)]"
}

$escapedPrefix = $AccountNamePrefix.Replace("'", "''").ToLowerInvariant()
$prefixClause = if ($escapedPrefix) {
    "| where tolower(name) startswith '$escapedPrefix'"
}
else {
    ""
}
$query = @"
Resources
| where type =~ 'microsoft.storage/storageaccounts'
$prefixClause
| project
    id,
    name,
    resourceGroup,
    subscriptionId,
    location,
    kind,
    skuName=tostring(sku.name),
    isHnsEnabled=tobool(properties.isHnsEnabled),
    blobEndpoint=tostring(properties.primaryEndpoints.blob)
| order by subscriptionId asc, name asc
"@

$graphArguments = @(
    "graph", "query",
    "-q", $query,
    "--first", "1000",
    "--output", "json",
    "--only-show-errors",
    "--subscriptions"
) + $subscriptions
$accounts = @((Invoke-AzCli $graphArguments | ConvertFrom-Json).data)

if ($accounts.Count -eq 0) {
    $scopeDescription = if ($AccountNamePrefix) {
        " beginning with '$AccountNamePrefix'"
    }
    else {
        ""
    }
    throw "No storage accounts$scopeDescription were found in the selected subscriptions."
}
if ($accounts.Count -ge 1000) {
    throw "The discovery result reached the 1,000-account safety limit. Add Resource Graph pagination before continuing."
}
if ($ExpectedAccountCount -gt 0 -and $accounts.Count -ne $ExpectedAccountCount) {
    throw "Safety stop: expected $ExpectedAccountCount matching accounts but discovered $($accounts.Count). No preflight or full scan was started."
}

foreach ($account in $accounts) {
    if (-not $account.blobEndpoint) {
        $details = (
            Invoke-AzCli @(
                "storage", "account", "show",
                "--ids", $account.id,
                "--output", "json",
                "--only-show-errors"
            )
        ) | ConvertFrom-Json
        $account.blobEndpoint = [string]$details.primaryEndpoints.blob
        $account.isHnsEnabled = [bool]$details.isHnsEnabled
    }
}

Write-Host "Discovered $($accounts.Count) matching storage accounts."

$preflight = [System.Collections.Generic.List[object]]::new()
foreach ($account in $accounts) {
    Write-Host "Preflight: $($account.name)"
    try {
        $null = @(Get-Containers -BlobEndpoint $account.blobEndpoint -OneOnly)
        $preflight.Add([pscustomobject]@{
            SubscriptionId = $account.subscriptionId
            ResourceGroup  = $account.resourceGroup
            AccountName    = $account.name
            Region         = $account.location
            Status         = "Passed"
            Error          = $null
        })
    }
    catch {
        $preflight.Add([pscustomobject]@{
            SubscriptionId = $account.subscriptionId
            ResourceGroup  = $account.resourceGroup
            AccountName    = $account.name
            Region         = $account.location
            Status         = "Failed"
            Error          = $_.Exception.Message
        })
    }
}

$preflightPath = Join-Path $OutputDirectory "preflight.csv"
$preflight | Export-Csv -LiteralPath $preflightPath -NoTypeInformation -Encoding utf8
$preflightFailures = @($preflight | Where-Object Status -eq "Failed")

if ($preflightFailures.Count -gt 0) {
    throw "Preflight failed for $($preflightFailures.Count) of $($accounts.Count) accounts. No full scan was started. See $preflightPath."
}

if ($PreflightOnly) {
    Write-Host "PASS: all $($accounts.Count) accounts allow metadata enumeration."
    Write-Host "Run again with -FullScan and the same -OutputDirectory to perform exact active-blob sizing."
    exit 0
}

$results = [System.Collections.Generic.List[object]]::new()
$position = 0
foreach ($account in $accounts) {
    $position++
    $resultPath = Join-Path $accountResultDirectory "$($account.name).json"

    if ((Test-Path -LiteralPath $resultPath) -and -not $Force) {
        $savedResult = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ($savedResult.Status -eq "Succeeded") {
            Write-Host "[$position/$($accounts.Count)] Resume: $($account.name)"
            $results.Add($savedResult)
            continue
        }
    }

    Write-Host "[$position/$($accounts.Count)] Measuring: $($account.name)"
    try {
        $result = Measure-StorageAccount -Account $account
    }
    catch {
        $result = [pscustomobject]@{
            Status          = "Failed"
            SubscriptionId  = $account.subscriptionId
            ResourceGroup   = $account.resourceGroup
            AccountName     = $account.name
            Region          = $account.location
            Kind            = $account.kind
            SkuName         = $account.skuName
            IsHnsEnabled    = [bool]$account.isHnsEnabled
            ContainerCount  = $null
            BlockBlobCount  = $null
            BlockBlobBytes  = $null
            AppendBlobCount = $null
            AppendBlobBytes = $null
            PageBlobCount   = $null
            PageBlobBytes   = $null
            ListRequests    = $null
            MeasuredUtc     = (Get-Date).ToUniversalTime().ToString("o")
            Error           = $_.Exception.Message
        }
    }

    Write-JsonFile -Value $result -Path $resultPath
    $results.Add($result)
}

$successfulResults = @($results | Where-Object Status -eq "Succeeded")
$failedResults = @($results | Where-Object Status -eq "Failed")
$accountCsvPath = Join-Path $OutputDirectory "account-sizing.csv"
$results |
    Select-Object *,
        @{ Name = "BlockBlobGiB"; Expression = { if ($null -ne $_.BlockBlobBytes) { [decimal]$_.BlockBlobBytes / 1GB } } },
        @{ Name = "AppendBlobGiB"; Expression = { if ($null -ne $_.AppendBlobBytes) { [decimal]$_.AppendBlobBytes / 1GB } } },
        @{ Name = "PageBlobGiB"; Expression = { if ($null -ne $_.PageBlobBytes) { [decimal]$_.PageBlobBytes / 1GB } } } |
    Export-Csv -LiteralPath $accountCsvPath -NoTypeInformation -Encoding utf8

if ($failedResults.Count -gt 0) {
    throw "The full scan failed for $($failedResults.Count) accounts. Successful results were saved and can be resumed. See $accountCsvPath."
}

$pricingEvidence = [System.Collections.Generic.List[object]]::new()
$scenarioRows = [System.Collections.Generic.List[object]]::new()

foreach ($redundancy in $VaultRedundancy) {
    $ratesByAccountKey = @{}
    foreach ($accountResult in $successfulResults) {
        $key = "$($accountResult.Region)|$($accountResult.IsHnsEnabled)|$redundancy"
        if (-not $ratesByAccountKey.ContainsKey($key)) {
            $ratesByAccountKey[$key] = Get-AccountRates `
                -AccountResult $accountResult `
                -Redundancy $redundancy
            $pricingEvidence.Add($ratesByAccountKey[$key])
        }
    }

    foreach ($retention in $RetentionDays) {
        if ($retention -lt 1) {
            throw "Retention days must be at least 1."
        }

        foreach ($churnPercent in $DailyChurnPercent) {
            if ($churnPercent -lt 0) {
                throw "Daily churn cannot be negative."
            }

            [decimal]$protectedGiB = 0
            [decimal]$modeledVaultGiB = 0
            [decimal]$protectedInstanceCost = 0
            [decimal]$vaultStorageCost = 0

            foreach ($accountResult in $successfulResults) {
                [decimal]$accountGiB = [decimal]$accountResult.BlockBlobBytes / 1GB
                $protectedGiB += $accountGiB
                [decimal]$accountVaultGiB = $accountGiB * (
                    1 + ([decimal]$churnPercent / 100) * [Math]::Max(0, $retention - 1)
                )
                $modeledVaultGiB += $accountVaultGiB

                $key = "$($accountResult.Region)|$($accountResult.IsHnsEnabled)|$redundancy"
                $rates = $ratesByAccountKey[$key]
                if ($accountGiB -gt 0) {
                    $protectedInstanceCost += (
                        [Math]::Ceiling([double]($accountGiB / 500)) *
                        [decimal]$rates.ProtectedInstanceRate
                    )
                }
                $vaultStorageCost += $accountVaultGiB * [decimal]$rates.VaultStorageRate
            }

            $scenarioRows.Add([pscustomobject]@{
                RetentionDays               = $retention
                DailyChurnPercent            = $churnPercent
                VaultRedundancy              = $redundancy
                ProtectedBlockBlobGiB        = [Math]::Round($protectedGiB, 3)
                ModeledVaultStorageGiB       = [Math]::Round($modeledVaultGiB, 3)
                ProtectedInstanceMonthlyUSD  = [Math]::Round($protectedInstanceCost, 2)
                VaultStorageMonthlyUSD       = [Math]::Round($vaultStorageCost, 2)
                WriteOperationsMonthlyUSD    = $null
                EstimatedMonthlyUSD          = [Math]::Round(
                    $protectedInstanceCost + $vaultStorageCost,
                    2
                )
                EstimatedAnnualUSD           = [Math]::Round(
                    ($protectedInstanceCost + $vaultStorageCost) * 12,
                    2
                )
                Exclusions                   = "Backup-attributed write operations, restore charges, taxes, and negotiated discounts"
            })
        }
    }
}

$scenarioPath = Join-Path $OutputDirectory "cost-scenarios.csv"
$scenarioRows |
    Sort-Object RetentionDays, DailyChurnPercent, VaultRedundancy |
    Export-Csv -LiteralPath $scenarioPath -NoTypeInformation -Encoding utf8

$pricingPath = Join-Path $OutputDirectory "pricing-evidence.json"
Write-JsonFile `
    -Value @($pricingEvidence | Sort-Object Region, AccountType, Redundancy -Unique) `
    -Path $pricingPath

[decimal]$totalBlockBytes = ($successfulResults | Measure-Object BlockBlobBytes -Sum).Sum
[decimal]$totalAppendBytes = ($successfulResults | Measure-Object AppendBlobBytes -Sum).Sum
[decimal]$totalPageBytes = ($successfulResults | Measure-Object PageBlobBytes -Sum).Sum
[long]$totalBlockCount = ($successfulResults | Measure-Object BlockBlobCount -Sum).Sum
[long]$totalAppendCount = ($successfulResults | Measure-Object AppendBlobCount -Sum).Sum
[long]$totalPageCount = ($successfulResults | Measure-Object PageBlobCount -Sum).Sum
[long]$totalListRequests = ($successfulResults | Measure-Object ListRequests -Sum).Sum

$summary = [pscustomobject]@{
    GeneratedUtc        = (Get-Date).ToUniversalTime().ToString("o")
    TenantId            = $accountContext.tenantId
    AccountNamePrefix   = $AccountNamePrefix
    SubscriptionIds     = $subscriptions
    AccountsDiscovered  = $accounts.Count
    AccountsMeasured    = $successfulResults.Count
    BlockBlobBytes      = $totalBlockBytes
    BlockBlobGiB        = [Math]::Round($totalBlockBytes / 1GB, 3)
    BlockBlobTiB        = [Math]::Round($totalBlockBytes / 1TB, 6)
    BlockBlobCount      = $totalBlockCount
    AppendBlobBytes     = $totalAppendBytes
    AppendBlobCount     = $totalAppendCount
    PageBlobBytes       = $totalPageBytes
    PageBlobCount       = $totalPageCount
    StorageListRequests = $totalListRequests
    CostModel           = "Initial active BlockBlob size plus changed bytes for each additional retained daily recovery point"
    CostExclusions      = @(
        "Backup-attributed write operations",
        "Restore charges",
        "Taxes",
        "Negotiated discounts"
    )
    Files               = @{
        Preflight       = "preflight.csv"
        AccountSizing   = "account-sizing.csv"
        CostScenarios   = "cost-scenarios.csv"
        PricingEvidence = "pricing-evidence.json"
    }
}

$summaryPath = Join-Path $OutputDirectory "summary.json"
Write-JsonFile -Value $summary -Path $summaryPath

$readme = @"
AZURE BLOB VAULTED BACKUP ASSESSMENT

Generated: $($summary.GeneratedUtc)
Tenant: $($summary.TenantId)
Matching accounts: $($summary.AccountsMeasured)
Exact active BlockBlob size: $($summary.BlockBlobGiB) GiB / $($summary.BlockBlobTiB) TiB
Exact active BlockBlob count: $($summary.BlockBlobCount)

The scan listed metadata only. It did not download blob content, retrieve storage
keys, create SAS tokens, or modify Azure resources.

Cost scenarios use Microsoft Azure Retail Prices API rates. They model an initial
full copy plus changed bytes for each additional retained daily recovery point.
The 1%, 3%, and 5% churn values are assumptions until changed bytes are measured.

The estimated totals exclude backup-attributed write operations because source
storage transaction counts do not prove the number of operations generated by
Azure Backup. They also exclude restore charges, taxes, and negotiated discounts.

Review:
  summary.json
  account-sizing.csv
  cost-scenarios.csv
  pricing-evidence.json
  preflight.csv
"@
$readme | Set-Content -LiteralPath (Join-Path $OutputDirectory "README.txt") -Encoding utf8

Write-Host "COMPLETE"
Write-Host "Exact active BlockBlob size: $($summary.BlockBlobTiB) TiB"
Write-Host "Cost scenarios: $scenarioPath"
Write-Host "Summary: $summaryPath"
