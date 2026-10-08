$ErrorActionPreference = "Stop"
$location = "japaneast"

# ------------------------------------------------------------
# 設定とCSV読込：作成先は東日本、LogDestinationはStorageまたはLog
# ------------------------------------------------------------
$targetWorkspaceId = "/subscriptions/43fc6c39-e53d-449d-9871-6d66f95ed2f3/resourcegroups/rg-hub-sand-resource-01/providers/microsoft.operationalinsights/workspaces/log-hub-sand-collection-01"

$outputDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$inputCsvPath = Join-Path $outputDirectory "log_migration_targets.csv"
$csvPath = Join-Path $outputDirectory "log_migration_results_$(Get-Date -Format 'yyyyMMdd_HHmmss_fff').csv"
$failures = [System.Collections.Generic.List[object]]::new()

$rows = @(Import-Csv -LiteralPath $inputCsvPath -Encoding utf8)
if ($rows.Count -eq 0) { throw "対象CSVにデータがありません: $inputCsvPath" }

$columns = @("SubscriptionName", "ResourceGroup", "StorageAccount", "WorkspaceName", "LogDestination")
foreach ($column in $columns) {
    if ($column -notin $rows[0].PSObject.Properties.Name) {
        throw "対象CSVに必要な列がありません: $column"
    }
}

$targets = @(foreach ($row in $rows) {
    @{
        SubscriptionName = ([string]$row.SubscriptionName).Trim()
        SubscriptionId   = ""
        ResourceGroup    = ([string]$row.ResourceGroup).Trim()
        StorageAccount   = ([string]$row.StorageAccount).Trim()
        WorkspaceName    = ([string]$row.WorkspaceName).Trim()
        LogDestination   = ([string]$row.LogDestination).Trim()
    }
})

# ------------------------------------------------------------
# 共通処理：結果の記録、Azure CLIとARM APIの実行
# ------------------------------------------------------------
function Add-Failure {
    param(
        [string]$SubscriptionName,
        [string]$SubscriptionId,
        [string]$ResourceId,
        [string]$SettingName,
        [string]$Stage,
        [string]$Message
    )

    if ($Stage -eq "診断設定更新" -and $Message -match 'Resources should be in the same region') {
        $regions = [regex]::Matches($Message, "(?i)is in region\s+'([^']+)'")
        if ($regions.Count -ge 2) {
            $Message = "リージョン不一致: リソース=$($regions[0].Groups[1].Value), ストレージ=$($regions[1].Groups[1].Value)"
        }
    }

    $failures.Add([pscustomobject][ordered]@{
        SubscriptionName      = $SubscriptionName
        SubscriptionId        = $SubscriptionId
        Result                = "要対応"
        ResourceId            = $ResourceId
        DiagnosticSettingName = $SettingName
        Stage                 = $Stage
        Reason                = $Message
    })
}

function Invoke-AzJson {
    param([string[]]$Arguments)

    $output = & az @Arguments --only-show-errors --output json 2>&1
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI 失敗: $text"
    }
    if ($text) {
        $text | ConvertFrom-Json
    }
}

function Set-ArmResource {
    param(
        [string]$ResourceId,
        [hashtable]$Body,
        [string]$ApiVersion = "2024-03-11"
    )

    $file = [System.IO.Path]::GetTempFileName()
    try {
        $Body | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file -Encoding utf8
        $null = Invoke-AzJson -Arguments @(
            "rest", "--method", "put",
            "--url", "https://management.azure.com${ResourceId}?api-version=$ApiVersion",
            "--body", "@$file"
        )
    }
    finally {
        Remove-Item -LiteralPath $file -Force
    }
}

# ------------------------------------------------------------
# 全対象の事前確認：CSV、サブスクリプション、Storage登録、ストレージ名
# ------------------------------------------------------------
Write-Host "CSV設定とストレージアカウント名を事前確認しています。"
foreach ($target in $targets) {
    $name = $target.StorageAccount
    $resourceId = ""

    try {
        $stage = "CSV設定確認"
        foreach ($column in $columns) {
            if ([string]::IsNullOrWhiteSpace($target[$column])) {
                throw "CSVの必須項目が空です: $column"
            }
        }
        if ($target.LogDestination -notin @("Storage", "Log")) {
            throw "LogDestinationはStorageまたはLogを指定してください: $($target.LogDestination)"
        }

        $stage = "サブスクリプション確認"
        $account = Invoke-AzJson -Arguments @(
            "account", "show", "--subscription", $target.SubscriptionName
        )
        if (-not $account.id) { throw "サブスクリプションIDを取得できません。" }
        $target.SubscriptionId = $account.id
        $resourceId = "/subscriptions/$($target.SubscriptionId)/resourceGroups/$($target.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$name"

        $stage = "Microsoft.Storage 登録"
        $provider = Invoke-AzJson -Arguments @(
            "provider", "show", "--subscription", $target.SubscriptionId,
            "--namespace", "Microsoft.Storage"
        )
        if ($provider.registrationState -ne "Registered") {
            Write-Host "Microsoft.Storage を登録しています: $($target.SubscriptionId)"
            $null = Invoke-AzJson -Arguments @(
                "provider", "register", "--subscription", $target.SubscriptionId,
                "--namespace", "Microsoft.Storage", "--wait"
            )
        }

        $stage = "ストレージ名事前確認"
        $result = Invoke-AzJson -Arguments @(
            "storage", "account", "check-name",
            "--subscription", $target.SubscriptionId, "--name", $name
        )
        if ($result.nameAvailable -ne $true) {
            throw "名前を利用できません: $name / $($result.reason) / $($result.message)"
        }
        Write-Host "名前確認OK: $($target.SubscriptionName) / $name"
    }
    catch {
        Add-Failure -SubscriptionName $target.SubscriptionName -SubscriptionId $target.SubscriptionId -ResourceId $resourceId `
            -Stage $stage -Message $_.Exception.Message
    }
}

$precheckFailed = $failures.Count -gt 0

if (-not $precheckFailed) {
    foreach ($target in $targets) {
        $subscriptionId = $target.SubscriptionId
        Write-Host "`n処理中のサブスクリプション: $($target.SubscriptionName) ($subscriptionId) / リソースログ送信先: $($target.LogDestination)"

        try {
            # ------------------------------------------------------------
            # リソースプロバイダーの登録とリソースグループ作成
            # ------------------------------------------------------------
            foreach ($namespace in @("Microsoft.OperationalInsights", "Microsoft.Insights", "Microsoft.Security")) {
                $stage = "$namespace 登録"
                $failedResourceId = "/subscriptions/$subscriptionId/providers/$namespace"
                $provider = Invoke-AzJson -Arguments @(
                    "provider", "show", "--subscription", $subscriptionId, "--namespace", $namespace
                )
                if ($provider.registrationState -ne "Registered") {
                    $null = Invoke-AzJson -Arguments @(
                        "provider", "register", "--subscription", $subscriptionId,
                        "--namespace", $namespace, "--wait"
                    )
                }
            }

            $stage = "リソースグループ作成"
            $failedResourceId = "/subscriptions/$subscriptionId/resourceGroups/$($target.ResourceGroup)"
            $groupId = $failedResourceId

            $null = Invoke-AzJson -Arguments @(
                "group", "create", "--subscription", $subscriptionId,
                "--name", $target.ResourceGroup, "--location", $location
            )

            # ------------------------------------------------------------
            # ストレージ作成・設定：ZRS、アクセス制御、暗号化、バージョン管理、ライフサイクル、Defender
            # ------------------------------------------------------------
            $stage = "ストレージ作成"
            $failedResourceId = "$groupId/providers/Microsoft.Storage/storageAccounts/$($target.StorageAccount)"
            $storage = Invoke-AzJson -Arguments @(
                "storage", "account", "create",
                "--subscription", $subscriptionId,
                "--resource-group", $target.ResourceGroup,
                "--name", $target.StorageAccount,
                "--public-network-access", "Disabled",
                "--default-action", "Deny", "--bypass", "AzureServices",
                "--allow-blob-public-access", "false",
                "--allow-shared-key-access", "false",
                "--https-only", "true", "--min-tls-version", "TLS1_2",
                "--location", $location, "--kind", "StorageV2",
                "--sku", "Standard_ZRS",
                "--require-infrastructure-encryption", "true", "--enable-alw", "true"
            )

            $stage = "Blobバージョン管理設定"
            $failedResourceId = "$($storage.id)/blobServices/default"
            $null = Invoke-AzJson -Arguments @(
                "storage", "account", "blob-service-properties", "update",
                "--subscription", $subscriptionId,
                "--resource-group", $target.ResourceGroup,
                "--account-name", $target.StorageAccount,
                "--enable-versioning", "true"
            )

            $stage = "ライフサイクル設定"
            $failedResourceId = "$($storage.id)/managementPolicies/default"
            $rules = @(
                @{
                    name = "log-append-365"
                    enabled = $true
                    type = "Lifecycle"
                    definition = @{
                        filters = @{ blobTypes = @("appendBlob") }
                        actions = @{
                            baseBlob = @{
                                delete = @{ daysAfterModificationGreaterThan = 365 }
                            }
                        }
                    }
                }
            )
            Set-ArmResource -ResourceId $failedResourceId -ApiVersion "2023-05-01" -Body @{
                properties = @{ policy = @{ rules = $rules } }
            }

            $stage = "Defender for Storage 設定"
            $failedResourceId = "$($storage.id)/providers/Microsoft.Security/defenderForStorageSettings/current"
            Set-ArmResource -ResourceId $failedResourceId -ApiVersion "2025-01-01" -Body @{
                properties = @{
                    isEnabled = $false
                    overrideSubscriptionLevelSettings = $true
                }
            }

            # ------------------------------------------------------------
            # Log Analytics作成・設定：365日保持、公開アクセス、リソースまたはワークスペース権限
            # ------------------------------------------------------------
            $stage = "Log Analytics 作成"
            $failedResourceId = "$groupId/providers/Microsoft.OperationalInsights/workspaces/$($target.WorkspaceName)"
            $workspace = Invoke-AzJson -Arguments @(
                "monitor", "log-analytics", "workspace", "create",
                "--subscription", $subscriptionId,
                "--resource-group", $target.ResourceGroup,
                "--workspace-name", $target.WorkspaceName,
                "--location", $location, "--retention-time", "365",
                "--ingestion-access", "Enabled", "--query-access", "Enabled"
            )
            $stage = "Log Analytics アクセス制御設定"
            $null = Invoke-AzJson -Arguments @(
                "resource", "update", "--subscription", $subscriptionId,
                "--ids", $workspace.id, "--api-version", "2023-09-01",
                "--set", "properties.features.enableLogAccessUsingOnlyResourcePermissions=true"
            )

            # ------------------------------------------------------------
            # VMログ設定：Event・Syslogテーブルの準備、Windows・Linux共通DCRの作成と関連付け
            # ------------------------------------------------------------
            try {
                $vms = @(Invoke-AzJson -Arguments @("vm", "list", "--subscription", $subscriptionId))
            }
            catch {
                Add-Failure -SubscriptionName $target.SubscriptionName -SubscriptionId $subscriptionId -ResourceId "/subscriptions/$subscriptionId" `
                    -Stage "VM一覧取得" -Message $_.Exception.Message
                $vms = @()
            }

            if ($vms.Count -gt 0) {
                $dcrName = $target.WorkspaceName -replace '^log', 'dcr'
                $dcrId = "/subscriptions/$subscriptionId/resourceGroups/$($target.ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules/$dcrName"

                $dcrReady = $false
                $stage = "VMログテーブル準備"
                try {
                    foreach ($name in @("Event", "Syslog")) {
                        $tableId = "$($workspace.id)/tables/$name"
                        $url = "https://management.azure.com${tableId}?api-version=2025-07-01"
                        try {
                            Set-ArmResource -ResourceId $tableId -ApiVersion "2025-07-01" -Body @{
                                properties = @{ schema = @{ name = $name } }
                            }
                        }
                        catch { throw "テーブル作成・更新失敗: $tableId / $($_.Exception.Message)" }
                        $table = $null

                        $deadline = (Get-Date).AddMinutes(5)
                        while ($table.properties.provisioningState -ne "Succeeded") {
                            if ((Get-Date) -ge $deadline) {
                                throw "テーブル準備がタイムアウトしました: $tableId / state=$($table.properties.provisioningState)"
                            }
                            if ($table.properties.provisioningState -in @("Failed", "Canceled", "Deleting")) {
                                throw "テーブルを利用できません: $tableId / state=$($table.properties.provisioningState)"
                            }
                            Start-Sleep -Seconds 10
                            try {
                                $table = Invoke-AzJson -Arguments @("rest", "--method", "get", "--url", $url)
                            }
                            catch {
                                if ($_.Exception.Message -notmatch '\b(TableNotFound|ResourceNotFound|NotFound)\b') { throw }
                            }
                        }
                    }

                    $stage = "DCR作成"
                    $body = @{
                        location = $workspace.location
                        properties = @{
                            dataSources = @{
                                windowsEventLogs = @(
                                    @{
                                        name = "eventLogsDataSource"
                                        streams = @("Microsoft-Event")
                                        xPathQueries = @(
                                            "Application!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0 or Level=5)]]"
                                            "Security!*[System[(band(Keywords,13510798882111488))]]"
                                            "System!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0 or Level=5)]]"
                                        )
                                    }
                                )
                                syslog = @(
                                    @{
                                        name = "sysLogsDataSource"
                                        streams = @("Microsoft-Syslog")
                                        facilityNames = @(
                                            "alert", "audit", "auth", "authpriv", "clock", "cron",
                                            "daemon", "ftp", "kern", "local0", "local1", "local2",
                                            "local3", "local4", "local5", "local6", "local7", "lpr",
                                            "mail", "news", "nopri", "ntp", "syslog", "user", "uucp"
                                        )
                                        logLevels = @(
                                            "Debug", "Info", "Notice", "Warning",
                                            "Error", "Critical", "Alert", "Emergency"
                                        )
                                    }
                                )
                            }
                            destinations = @{
                                logAnalytics = @(
                                    @{
                                        name = "new-workspace"
                                        workspaceResourceId = $workspace.id
                                    }
                                )
                            }
                            dataFlows = @(
                                @{
                                    streams = @("Microsoft-Event")
                                    destinations = @("new-workspace")
                                }
                                @{
                                    streams = @("Microsoft-Syslog")
                                    destinations = @("new-workspace")
                                }
                            )
                        }
                    }
                    $deadline = (Get-Date).AddMinutes(5)
                    while ($true) {
                        try {
                            Set-ArmResource -ResourceId $dcrId -Body $body
                            $dcrReady = $true
                            break
                        }
                        catch {
                            if ($_.Exception.Message -notmatch '\bInvalidOutputTable\b' -or (Get-Date) -ge $deadline) { throw }
                            Write-Host "DCR宛先テーブルの反映を待っています: $($workspace.name)"
                            Start-Sleep -Seconds 10
                        }
                    }
                }
                catch {
                    foreach ($vm in $vms) {
                        Add-Failure -SubscriptionName $target.SubscriptionName -SubscriptionId $subscriptionId -ResourceId $vm.id `
                            -Stage $stage -Message "$dcrId / $($_.Exception.Message)"
                    }
                }

                if ($dcrReady) {
                    foreach ($vm in $vms) {
                        try {
                            Set-ArmResource -ResourceId "$($vm.id)/providers/Microsoft.Insights/dataCollectionRuleAssociations/$dcrName" -Body @{
                                properties = @{ dataCollectionRuleId = $dcrId }
                            }
                        }
                        catch {
                            Add-Failure -SubscriptionName $target.SubscriptionName -SubscriptionId $subscriptionId -ResourceId $vm.id `
                                -Stage "DCR関連付け" -Message "$dcrId / $($_.Exception.Message)"
                        }
                    }
                }
            }

            # ------------------------------------------------------------
            # 診断設定の移行：ストレージの子リソースを含め、既存ログアナを宛先とする設定を更新
            # ------------------------------------------------------------
            $stage = "リソース一覧取得"
            $failedResourceId = "/subscriptions/$subscriptionId"
            $resources = Invoke-AzJson -Arguments @(
                "resource", "list", "--subscription", $subscriptionId
            )

            $resourceIds = @(
                foreach ($resource in $resources) {
                    $resource.id
                    if ($resource.type -eq "Microsoft.Storage/storageAccounts") {
                        $services = switch ($resource.kind) {
                            "BlobStorage"      { "blobServices" }
                            "BlockBlobStorage" { "blobServices" }
                            "FileStorage"      { "fileServices" }
                            default            { "blobServices"; "queueServices"; "tableServices"; "fileServices" }
                        }
                        foreach ($service in $services) {
                            "$($resource.id)/$service/default"
                        }
                    }
                }
            ) | Select-Object -Unique

            foreach ($resourceId in $resourceIds) {
                try {
                    $settings = Invoke-AzJson -Arguments @(
                        "monitor", "diagnostic-settings", "list",
                        "--subscription", $subscriptionId, "--resource", $resourceId
                    )
                }
                catch {
                    if ($_.Exception.Message -match '\bResourceTypeNotSupported\b') {
                        continue
                    }
                    Add-Failure -SubscriptionName $target.SubscriptionName -SubscriptionId $subscriptionId -ResourceId $resourceId `
                        -Stage "診断設定取得" -Message $_.Exception.Message
                    continue
                }

                $matchingSettings = @($settings | Where-Object { $_.workspaceId -eq $targetWorkspaceId })
                foreach ($setting in $matchingSettings) {
                    try {
                        $updateArguments = @(
                            "monitor", "diagnostic-settings", "update",
                            "--subscription", $subscriptionId,
                            "--resource", $resourceId, "--name", $setting.name
                        )

                        if ($target.LogDestination -eq "Storage") {
                            $updateArguments += @(
                                "--storage-account-id", $storage.id,
                                "--set", "workspaceId=null", "logAnalyticsDestinationType=null"
                            )
                        }
                        else {
                            $updateArguments += @(
                                "--workspace-id", $workspace.id,
                                "--set", "storageAccountId=null"
                            )
                        }

                        $null = Invoke-AzJson -Arguments $updateArguments
                    }
                    catch {
                        Add-Failure -SubscriptionName $target.SubscriptionName -SubscriptionId $subscriptionId -ResourceId $resourceId `
                            -SettingName $setting.name -Stage "診断設定更新" `
                            -Message $_.Exception.Message
                    }
                }
            }
        }
        catch {
            Add-Failure -SubscriptionName $target.SubscriptionName -SubscriptionId $subscriptionId -ResourceId $failedResourceId `
                -Stage $stage -Message $_.Exception.Message
        }
    }
}

# ------------------------------------------------------------
# 処理結果出力：成功リソースの明細は出さず、要対応の明細のみ記録
# ------------------------------------------------------------
$report = @(
    foreach ($subscriptionName in ($targets.SubscriptionName | Select-Object -Unique)) {
        $target = $targets | Where-Object { $_.SubscriptionName -eq $subscriptionName } | Select-Object -First 1
        $items = @($failures | Where-Object { $_.SubscriptionName -eq $subscriptionName })
        if ($items.Count -gt 0) {
            if ($precheckFailed) {
                foreach ($item in $items) { $item.Result = "未実施" }
            }
            $items
        }
        else {
            [pscustomobject][ordered]@{
                SubscriptionName      = $subscriptionName
                SubscriptionId        = $target.SubscriptionId
                Result                = if ($precheckFailed) { "未実施" } else { "完了" }
                ResourceId            = ""
                DiagnosticSettingName = ""
                Stage                 = if ($precheckFailed) { "事前確認" } else { "" }
                Reason                = if ($precheckFailed) { "他の対象の事前確認NGにより、全体の作成・更新を開始していません。" } else { "" }
            }
        }
    }
)

$report | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8BOM
$report | Select-Object SubscriptionName, SubscriptionId, Result -Unique | Format-Table -AutoSize
Write-Host "処理結果CSV: $csvPath"
