#requires -Version 7.2
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

# 移行対象を判定する、既存の Log Analytics ワークスペース
$targetWorkspaceId = "/subscriptions/<既存サブスクリプションID>/resourceGroups/<既存RG名>/providers/Microsoft.OperationalInsights/workspaces/<既存ログアナ名>"

# SubscriptionId はサブスクリプション名またはIDを指定
$targets = @(
    @{
        SubscriptionId = "<サブスクリプション名またはID-1>"
        ResourceGroup  = "rg-log-archive-01"
        Location       = "japaneast"
        StorageAccount = "<ストレージアカウント名-1>"
        WorkspaceName  = "log-archive-01"
    }
    @{
        SubscriptionId = "<サブスクリプション名またはID-2>"
        ResourceGroup  = "rg-log-archive-02"
        Location       = "japaneast"
        StorageAccount = "<ストレージアカウント名-2>"
        WorkspaceName  = "log-archive-02"
    }
)

# CSV はスクリプトと同じフォルダーに、実行日時付きで出力
$outputDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$csvPath = Join-Path $outputDirectory "log_migration_results_$(Get-Date -Format 'yyyyMMdd_HHmmss_fff').csv"
$failures = [System.Collections.Generic.List[object]]::new()

function Add-Failure {
    param(
        [string]$SubscriptionId,
        [string]$ResourceId,
        [string]$SettingName,
        [string]$Stage,
        [string]$Message
    )

    $failures.Add([pscustomobject][ordered]@{
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

function Export-Results {
    param([switch]$PrecheckFailed)

    $report = @(foreach ($subscription in ($targets.SubscriptionId | Select-Object -Unique)) {
        $items = @($failures | Where-Object { $_.SubscriptionId -eq $subscription })
        if ($items.Count -gt 0) {
            if ($PrecheckFailed) {
                foreach ($item in $items) { $item.Result = "未実施" }
            }
            $items
        }
        else {
            [pscustomobject][ordered]@{
                SubscriptionId        = $subscription
                Result                = if ($PrecheckFailed) { "未実施" } else { "完了" }
                ResourceId            = ""
                DiagnosticSettingName = ""
                Stage                 = if ($PrecheckFailed) { "事前確認" } else { "" }
                Reason                = if ($PrecheckFailed) { "他の対象の事前確認NGにより、全体の作成・更新を開始していません。" } else { "" }
            }
        }
    })

    $report | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8BOM
    $report | Select-Object SubscriptionId, Result -Unique | Format-Table -AutoSize
    Write-Host "処理結果CSV: $csvPath"
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

function Initialize-VmLogTables {
    param([string]$WorkspaceId)

    foreach ($name in @("Event", "Syslog")) {
        $tableId = "$WorkspaceId/tables/$name"
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
}

function Set-VmDcr {
    param([hashtable]$Target, $Workspace)

    $subscription = $Target.SubscriptionId
    try {
        $vms = @(Invoke-AzJson -Arguments @("vm", "list", "--subscription", $subscription))
    }
    catch {
        Add-Failure -SubscriptionId $subscription -ResourceId "/subscriptions/$subscription" `
            -Stage "VM一覧取得" -Message $_.Exception.Message
        return
    }
    if ($vms.Count -eq 0) { return }

    $dcrName = $Target.WorkspaceName -replace '^log', 'dcr'
    $dcrId = "/subscriptions/$subscription/resourceGroups/$($Target.ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules/$dcrName"

    $stage = "VMログテーブル準備"
    try {
        Initialize-VmLogTables -WorkspaceId $Workspace.id
        $stage = "DCR作成"
        $body = @{
            location = $Workspace.location
            properties = @{
                dataSources = @{
                    windowsEventLogs = @(@{
                        name = "eventLogsDataSource"
                        streams = @("Microsoft-Event")
                        xPathQueries = @(
                            "Application!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0 or Level=5)]]"
                            "Security!*[System[(band(Keywords,13510798882111488))]]"
                            "System!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0 or Level=5)]]"
                        )
                    })
                    syslog = @(@{
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
                    })
                }
                destinations = @{
                    logAnalytics = @(@{
                        name = "new-workspace"
                        workspaceResourceId = $Workspace.id
                    })
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
                break
            }
            catch {
                if ($_.Exception.Message -notmatch '\bInvalidOutputTable\b' -or (Get-Date) -ge $deadline) { throw }
                Write-Host "DCR宛先テーブルの反映を待っています: $($Workspace.name)"
                Start-Sleep -Seconds 10
            }
        }
    }
    catch {
        foreach ($vm in $vms) {
            Add-Failure -SubscriptionId $subscription -ResourceId $vm.id `
                -Stage $stage -Message "$dcrId / $($_.Exception.Message)"
        }
        return
    }

    foreach ($vm in $vms) {
        try {
            Set-ArmResource -ResourceId "$($vm.id)/providers/Microsoft.Insights/dataCollectionRuleAssociations/$dcrName" -Body @{
                properties = @{ dataCollectionRuleId = $dcrId }
            }
        }
        catch {
            Add-Failure -SubscriptionId $subscription -ResourceId $vm.id `
                -Stage "DCR関連付け" -Message "$dcrId / $($_.Exception.Message)"
        }
    }
}

# 全件の名前チェックに通った場合だけ、作成・更新に進む
Write-Host "ストレージアカウント名を事前確認しています。"
foreach ($target in $targets) {
    $name = $target.StorageAccount
    $resourceId = ""
    $target.ExistingStorage = $false

    try {
        $stage = "サブスクリプション確認"
        $account = Invoke-AzJson -Arguments @(
            "account", "show", "--subscription", $target.SubscriptionId
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
            if ($result.reason -ne "AlreadyExists") {
                throw "名前を利用できません: $name / $($result.reason) / $($result.message)"
            }
            $accounts = Invoke-AzJson -Arguments @(
                "storage", "account", "list", "--subscription", $target.SubscriptionId
            )
            $existing = $accounts | Where-Object { $_.id -eq $resourceId }
            if (-not $existing) {
                throw "指定先以外で使用済みのストレージ名です: $name"
            }
            if ($existing.location -ne $target.Location) {
                throw "既存ストレージのリージョン不一致: 既存=$($existing.location), 指定=$($target.Location)"
            }
            $target.ExistingStorage = $true
        }
        Write-Host "名前確認OK: $($target.SubscriptionId) / $name"
    }
    catch {
        Add-Failure -SubscriptionId $target.SubscriptionId -ResourceId $resourceId `
            -Stage $stage -Message $_.Exception.Message
    }
}

if ($failures.Count -gt 0) {
    Export-Results -PrecheckFailed
    return
}

foreach ($target in $targets) {
    $subscription = $target.SubscriptionId
    Write-Host "`n処理中のサブスクリプション: $subscription"

    try {
        foreach ($namespace in @("Microsoft.OperationalInsights", "Microsoft.Insights")) {
            $stage = "$namespace 登録"
            $failedResourceId = "/subscriptions/$subscription/providers/$namespace"
            $provider = Invoke-AzJson -Arguments @(
                "provider", "show", "--subscription", $subscription, "--namespace", $namespace
            )
            if ($provider.registrationState -ne "Registered") {
                $null = Invoke-AzJson -Arguments @(
                    "provider", "register", "--subscription", $subscription,
                    "--namespace", $namespace, "--wait"
                )
            }
        }

        $stage = "リソースグループ作成"
        $failedResourceId = "/subscriptions/$subscription/resourceGroups/$($target.ResourceGroup)"
        $groupId = $failedResourceId

        $null = Invoke-AzJson -Arguments @(
            "group", "create", "--subscription", $subscription,
            "--name", $target.ResourceGroup, "--location", $target.Location
        )

        $stage = "ストレージ作成・設定"
        $failedResourceId = "$groupId/providers/Microsoft.Storage/storageAccounts/$($target.StorageAccount)"
        $storageArguments = @(
            "storage", "account",
            $(if ($target.ExistingStorage) { "update" } else { "create" }),
            "--subscription", $subscription,
            "--resource-group", $target.ResourceGroup,
            "--name", $target.StorageAccount,
            "--public-network-access", "Disabled",
            "--default-action", "Deny", "--bypass", "AzureServices"
        )
        if (-not $target.ExistingStorage) {
            $storageArguments += @("--location", $target.Location)
        }
        $storage = Invoke-AzJson -Arguments $storageArguments

        $stage = "Log Analytics 作成"
        $failedResourceId = "$groupId/providers/Microsoft.OperationalInsights/workspaces/$($target.WorkspaceName)"
        $workspace = Invoke-AzJson -Arguments @(
            "monitor", "log-analytics", "workspace", "create",
            "--subscription", $subscription,
            "--resource-group", $target.ResourceGroup,
            "--workspace-name", $target.WorkspaceName,
            "--location", $target.Location
        )

        Set-VmDcr -Target $target -Workspace $workspace

        $stage = "リソース一覧取得"
        $failedResourceId = "/subscriptions/$subscription"
        $resources = Invoke-AzJson -Arguments @(
            "resource", "list", "--subscription", $subscription
        )

        foreach ($resource in $resources) {
            try {
                $settings = Invoke-AzJson -Arguments @(
                    "monitor", "diagnostic-settings", "list",
                    "--subscription", $subscription, "--resource", $resource.id
                )
            }
            catch {
                if ($_.Exception.Message -match '\bResourceTypeNotSupported\b') {
                    continue
                }
                Add-Failure -SubscriptionId $subscription -ResourceId $resource.id `
                    -Stage "診断設定取得" -Message $_.Exception.Message
                continue
            }

            foreach ($setting in @($settings | Where-Object {
                $_.workspaceId -eq $targetWorkspaceId
            })) {
                try {
                    if ($resource.location -and
                        $resource.location -ne "global" -and
                        $resource.location -ne $storage.location) {
                        throw "リージョン不一致: リソース=$($resource.location), ストレージ=$($storage.location)"
                    }

                    # 同じ診断設定のログアナ送信先を解除し、ストレージに変更
                    $null = Invoke-AzJson -Arguments @(
                        "monitor", "diagnostic-settings", "update",
                        "--subscription", $subscription,
                        "--resource", $resource.id, "--name", $setting.name,
                        "--storage-account-id", $storage.id,
                        "--set", "workspaceId=null", "logAnalyticsDestinationType=null"
                    )

                }
                catch {
                    Add-Failure -SubscriptionId $subscription -ResourceId $resource.id `
                        -SettingName $setting.name -Stage "診断設定更新" `
                        -Message $_.Exception.Message
                }
            }
        }
    }
    catch {
        Add-Failure -SubscriptionId $subscription -ResourceId $failedResourceId `
            -Stage $stage -Message $_.Exception.Message
    }
}

Export-Results
