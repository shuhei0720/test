#Requires -Modules Az.Accounts, Az.Resources

# ===== Change these three values =====
$SubscriptionId       = '00000000-0000-0000-0000-000000000000'
$StorageAccountId     = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-logs/providers/Microsoft.Storage/storageAccounts/stexamplelogs'
$DiagnosticSettingName = 'diag-storage-alllogs'

$ErrorActionPreference = 'Stop'
$ApiVersion = '2021-05-01-preview'
$StorageAccountId = $StorageAccountId.TrimEnd('/')
$CsvPath = Join-Path $PWD ('diagnostic-results-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# Return HTTP errors as data so that unsupported resources and failures can be distinguished.
function Invoke-ArmRequest {
    param([string]$Path, [string]$Method = 'GET', [string]$Payload)
    try {
        $parameters = @{ Path = $Path; Method = $Method; ErrorAction = 'Stop' }
        if ($Payload) { $parameters.Payload = $Payload }
        $response = Invoke-AzRestMethod @parameters
        $status = [int]$response.StatusCode
        $content = [string]$response.Content
    }
    catch {
        $status = 0
        if ($_.Exception.Response.StatusCode) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        $content = [string]$_.ErrorDetails.Message
        if (-not $content) { $content = $_.Exception.Message }
    }
    $data = $null
    try { $data = $content | ConvertFrom-Json -ErrorAction Stop } catch { }
    [pscustomobject]@{
        Status = $status
        Data   = $data
        Detail = "HTTP $status : $content"
    }
}

# Use the existing login (for example, Azure Cloud Shell).
if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

# Validate the destination before changing any diagnostic settings.
if ($StorageAccountId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Storage/storageAccounts/[^/]+$') {
    throw 'StorageAccountId must be a full storage account resource ID.'
}
$destination = Invoke-ArmRequest -Path "${StorageAccountId}?api-version=2023-05-01"
if ($destination.Status -ne 200) { throw $destination.Detail }

# Enumerate ARM resources and explicitly add Storage service subresources.
$resources = @(Get-AzResource)
$targets = @{}
foreach ($resource in $resources) {
    $targets[$resource.ResourceId] = [pscustomobject]@{
        Id = $resource.ResourceId
        StorageServiceCandidate = $false
    }
}
foreach ($resource in ($resources | Where-Object ResourceType -eq 'Microsoft.Storage/storageAccounts')) {
    foreach ($service in @('blobServices', 'fileServices', 'queueServices', 'tableServices')) {
        $id = "$($resource.ResourceId)/$service/default"
        if (-not $targets.ContainsKey($id)) {
            $targets[$id] = [pscustomobject]@{
                Id = $id
                StorageServiceCandidate = $true
            }
        }
    }
}

$results = [System.Collections.Generic.List[object]]::new()
$settingName = [uri]::EscapeDataString($DiagnosticSettingName)
$index = 0
foreach ($target in ($targets.Values | Sort-Object Id)) {
    $index++
    $id = $target.Id
    Write-Host "[$index/$($targets.Count)] $id"
    $row = [pscustomobject]@{
        ResourceId = $id
        Status     = ''
        Selection  = ''
        Reason     = ''
    }
    $stage = 'Categories'
    try {
        # Sending a storage account's logs to itself is unsupported.
        if ($id -ieq $StorageAccountId -or $id.StartsWith("$StorageAccountId/", [StringComparison]::OrdinalIgnoreCase)) {
            $row.Status = 'Skipped'
            $row.Reason = 'Destination storage account itself (including child resources).'
            continue
        }

        $basePath = "$id/providers/Microsoft.Insights"
        $response = Invoke-ArmRequest -Path "$basePath/diagnosticSettingsCategories?api-version=$ApiVersion"
        if ($response.Status -ne 200) {
            $code = [string]$response.Data.error.code
            $message = [string]$response.Data.error.message
            $unsupported = $code -eq 'ResourceTypeNotSupported' -or (
                $response.Status -in @(400, 404) -and
                $message -match '(?i)(resource type|diagnostic settings?).*(not supported|does not support)|not supported.*(resource type|diagnostic)'
            )
            $missingService = $target.StorageServiceCandidate -and
                $response.Status -eq 404 -and $code -in @('ResourceNotFound', 'ParentResourceNotFound')
            if ($unsupported -or $missingService) {
                $row.Status = 'Skipped'
                $row.Reason = $response.Detail
                continue
            }
            throw $response.Detail
        }

        $logCategories = @($response.Data.value | Where-Object { $_.properties.categoryType -eq 'Logs' })
        if ($logCategories.Count -eq 0) {
            $row.Status = 'Skipped'
            $row.Reason = 'No log categories (metrics only or no diagnostic categories).'
            continue
        }

        $hasAllLogs = @($logCategories | Where-Object { @($_.properties.categoryGroups) -contains 'allLogs' }).Count -gt 0
        if ($hasAllLogs) {
            $logs = @(@{ categoryGroup = 'allLogs'; enabled = $true })
            $row.Selection = 'allLogs'
        }
        else {
            $names = @($logCategories.name | Sort-Object -Unique)
            $logs = @($names | ForEach-Object { @{ category = $_; enabled = $true } })
            $row.Selection = $names -join ';'
        }

        # PUT replaces only this named setting. Other named settings are untouched.
        # Metrics are deliberately not collected.
        $body = @{
            properties = @{
                storageAccountId = $StorageAccountId
                logs             = $logs
                metrics          = @()
            }
        } | ConvertTo-Json -Depth 10
        $stage = 'CreateOrUpdate'
        $response = Invoke-ArmRequest -Method PUT -Path "$basePath/diagnosticSettings/${settingName}?api-version=$ApiVersion" -Payload $body
        if ($response.Status -notin @(200, 201)) { throw $response.Detail }
        $row.Status = 'Succeeded'
        $row.Reason = 'Diagnostic setting created or updated.'
    }
    catch {
        $row.Status = 'Failed'
        $row.Reason = "$stage : $($_.Exception.Message)"
    }
    finally {
        $results.Add($row)
        Write-Host "  $($row.Status) : $($row.Reason)"
    }
}

$results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8
Write-Host "`nSubscription : $SubscriptionId"
Write-Host "Destination  : $StorageAccountId"
$results | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize
$results | Where-Object Status -eq 'Failed' | Format-List ResourceId, Reason
Write-Host "CSV : $CsvPath"
