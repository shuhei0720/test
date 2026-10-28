#Requires -Modules Az.Accounts, Az.Resources

# ===== 以下の3変数を変更してください =====
$SubscriptionId       = '00000000-0000-0000-0000-000000000000'
$StorageAccountId     = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-logs/providers/Microsoft.Storage/storageAccounts/stexamplelogs'
$DiagnosticSettingName = 'diag-storage-alllogs'

$ErrorActionPreference = 'Stop'
$ApiVersion = '2021-05-01-preview'
$StorageAccountId = $StorageAccountId.TrimEnd('/')
$CsvPath = Join-Path $PWD ('diagnostic-results-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# 非対応によるスキップと実際の失敗を区別するため、HTTPエラーもデータとして返す
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

# 有効なログだけを並べ替えて比較する（順序や無効な項目の有無は無視）
function Get-LogSignature {
    param([object[]]$Logs)
    $keys = @($Logs | Where-Object { $_.enabled -eq $true } | ForEach-Object {
        if ($_.categoryGroup) { "group:$($_.categoryGroup)" }
        else { "category:$($_.category)" }
    } | Sort-Object -Unique)
    return ($keys -join ';')
}

# Cloud Shellなどの既存のログインを利用する。未ログインの場合は接続する
if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

# 診断設定を変更する前に、送信先ストレージの指定と参照可否を確認する
if ($StorageAccountId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Storage/storageAccounts/[^/]+$') {
    throw 'StorageAccountIdには、ストレージアカウントの完全なリソースIDを指定してください。'
}
$destination = Invoke-ArmRequest -Path "${StorageAccountId}?api-version=2023-05-01"
if ($destination.Status -ne 200) { throw $destination.Detail }

# リソースを取得し、StorageのBlob／File／Queue／Tableサブリソースを明示的に追加する
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
    Write-Host "[$index/$($targets.Count)] 処理対象：$id"
    $row = [pscustomobject]@{
        ResourceId = $id
        Status     = ''
        Selection  = ''
        Reason     = ''
    }
    $stage = '診断カテゴリの取得'
    try {
        # ストレージ自身へのログ送信はできないため、本体と配下のリソースを除外する
        if ($id -ieq $StorageAccountId -or $id.StartsWith("$StorageAccountId/", [StringComparison]::OrdinalIgnoreCase)) {
            $row.Status = 'スキップ'
            $row.Reason = '送信先ストレージ自身、またはその配下のリソースのため対象外です。'
            continue
        }

        $basePath = "$id/providers/Microsoft.Insights"
        $response = Invoke-ArmRequest -Path "$basePath/diagnosticSettingsCategories?api-version=$ApiVersion"
        if ($response.Status -ne 200) {
            if ($null -ne $response.Data.error) {
                $code = [string]$response.Data.error.code
                $message = [string]$response.Data.error.message
            }
            else {
                $code = [string]$response.Data.code
                $message = [string]$response.Data.message
            }
            $unsupported = $code -eq 'ResourceTypeNotSupported' -or (
                $response.Status -in @(400, 404) -and
                $message -match '(?i)(resource type|diagnostic settings?).*(not supported|does not support)|not supported.*(resource type|diagnostic)'
            )
            $missingService = $target.StorageServiceCandidate -and
                $response.Status -eq 404 -and $code -in @('ResourceNotFound', 'ParentResourceNotFound')
            if ($unsupported -or $missingService) {
                $row.Status = 'スキップ'
                $row.Reason = "診断設定に非対応、またはStorageサブリソースが存在しません。詳細：$($response.Detail)"
                continue
            }
            throw $response.Detail
        }

        $logCategories = @($response.Data.value | Where-Object { $_.properties.categoryType -eq 'Logs' })
        if ($logCategories.Count -eq 0) {
            $row.Status = 'スキップ'
            $row.Reason = 'ログカテゴリがありません（メトリクスのみ、または診断カテゴリなし）。'
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

        # 既存設定を取得する。取得失敗を「設定なし」として扱わない
        $stage = '既存の診断設定の取得'
        $response = Invoke-ArmRequest -Path "$basePath/diagnosticSettings?api-version=$ApiVersion"
        if ($response.Status -ne 200) { throw $response.Detail }
        $existing = @($response.Data.value | Where-Object { $_.name -eq $DiagnosticSettingName })
        if ($existing.Count -gt 0) {
            $properties = $existing[0].properties
            $sameStorage = ([string]$properties.storageAccountId).TrimEnd('/') -ieq $StorageAccountId
            $sameLogs = (Get-LogSignature -Logs @($properties.logs)) -eq (Get-LogSignature -Logs $logs)
            $noMetrics = @($properties.metrics | Where-Object { $_.enabled -eq $true }).Count -eq 0
            $noOtherDestinations = -not (
                $properties.workspaceId -or
                $properties.eventHubAuthorizationRuleId -or
                $properties.eventHubName -or
                $properties.serviceBusRuleId -or
                $properties.marketplacePartnerId
            )
            if ($sameStorage -and $sameLogs -and $noMetrics -and $noOtherDestinations) {
                $row.Status = 'スキップ'
                $row.Reason = '同名の診断設定が既にあり、送信先・有効なログ・メトリクスの設定が一致しています。'
                continue
            }
        }

        # 指定した名前の診断設定を作成・更新する。別名の設定は変更しない
        # メトリクスは収集しない。同名設定の他の送信先は、この内容で置き換わる
        $body = @{
            properties = @{
                storageAccountId = $StorageAccountId
                logs             = $logs
                metrics          = @()
            }
        } | ConvertTo-Json -Depth 10
        $stage = '診断設定の作成・更新'
        $response = Invoke-ArmRequest -Method PUT -Path "$basePath/diagnosticSettings/${settingName}?api-version=$ApiVersion" -Payload $body
        if ($response.Status -notin @(200, 201)) { throw $response.Detail }
        $row.Status = '成功'
        $row.Reason = '診断設定を作成または更新しました。'
    }
    catch {
        $row.Status = '失敗'
        $row.Reason = "$stage : $($_.Exception.Message)"
    }
    finally {
        $results.Add($row)
        Write-Host "  $($row.Status) : $($row.Reason)"
    }
}

$results | Select-Object `
    @{Name = 'リソースID'; Expression = { $_.ResourceId }},
    @{Name = '処理結果'; Expression = { $_.Status }},
    @{Name = '選択ログ'; Expression = { $_.Selection }},
    @{Name = '理由'; Expression = { $_.Reason }} |
    Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8
Write-Host "`n対象サブスクリプション：$SubscriptionId"
Write-Host "送信先ストレージ：$StorageAccountId"
$results | Group-Object Status | Select-Object `
    @{Name = '処理結果'; Expression = { $_.Name }},
    @{Name = '件数'; Expression = { $_.Count }} |
    Format-Table -AutoSize
$results | Where-Object Status -eq '失敗' | Select-Object `
    @{Name = 'リソースID'; Expression = { $_.ResourceId }},
    @{Name = '理由'; Expression = { $_.Reason }} |
    Format-List
Write-Host "結果CSV：$CsvPath"
