#requires -Version 7.2
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

# 移行対象を判定する、既存の Log Analytics ワークスペース
$targetWorkspaceId = "/subscriptions/<既存サブスクリプションID>/resourceGroups/<既存RG名>/providers/Microsoft.OperationalInsights/workspaces/<既存ログアナ名>"

# サブスクリプションごとの作成先
$targets = @(
    @{
        SubscriptionId = "<サブスクリプションID-1>"
        ResourceGroup  = "rg-log-archive-01"
        Location       = "japaneast"
        StorageAccount = "<ストレージアカウント名-1>"
        WorkspaceName  = "log-archive-01"
    }
    @{
        SubscriptionId = "<サブスクリプションID-2>"
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

# 全件の名前チェックに通った場合だけ、作成・更新に進む
Write-Host "ストレージアカウント名を事前確認しています。"
foreach ($target in $targets) {
    $name = $target.StorageAccount
    $resourceId = "/subscriptions/$($target.SubscriptionId)/resourceGroups/$($target.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$name"

    try {
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
        $stage = "リソースグループ作成"
        $failedResourceId = "/subscriptions/$subscription/resourceGroups/$($target.ResourceGroup)"
        $groupId = $failedResourceId

        $null = Invoke-AzJson -Arguments @(
            "group", "create", "--subscription", $subscription,
            "--name", $target.ResourceGroup, "--location", $target.Location
        )

        $stage = "ストレージ作成"
        $failedResourceId = "$groupId/providers/Microsoft.Storage/storageAccounts/$($target.StorageAccount)"
        $storage = Invoke-AzJson -Arguments @(
            "storage", "account", "create", "--subscription", $subscription,
            "--resource-group", $target.ResourceGroup,
            "--name", $target.StorageAccount, "--location", $target.Location,
            "--public-network-access", "Disabled",
            "--default-action", "Deny", "--bypass", "AzureServices"
        )

        $stage = "Log Analytics 作成"
        $failedResourceId = "$groupId/providers/Microsoft.OperationalInsights/workspaces/$($target.WorkspaceName)"
        $null = Invoke-AzJson -Arguments @(
            "monitor", "log-analytics", "workspace", "create",
            "--subscription", $subscription,
            "--resource-group", $target.ResourceGroup,
            "--workspace-name", $target.WorkspaceName,
            "--location", $target.Location
        )

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
