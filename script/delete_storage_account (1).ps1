$ErrorActionPreference = "Stop"
$storageAccountId = "/subscriptions/サブスクリプションID/resourceGroups/リソースグループ名/providers/Microsoft.Storage/storageAccounts/ストレージアカウント名"

# ------------------------------------------------------------
# Azure CLI実行：失敗した時点で停止
# ------------------------------------------------------------
function Invoke-AzJson {
    param([string[]]$Arguments)

    $output = & az @Arguments --only-show-errors --output json 2>&1
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw $text }
    if ($text) { $text | ConvertFrom-Json }
}

# ------------------------------------------------------------
# リソースIDから削除対象を特定
# ------------------------------------------------------------
$storageAccountId = $storageAccountId.Trim().TrimEnd('/')
if ($storageAccountId -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Storage/storageAccounts/([^/]+)$') {
    throw "ストレージアカウントのリソースIDを指定してください。"
}
$subscriptionId = $Matches[1]
$resourceGroup = $Matches[2]
$storageAccountName = $Matches[3]

$account = Invoke-AzJson -Arguments @(
    "storage", "account", "show",
    "--subscription", $subscriptionId,
    "--resource-group", $resourceGroup,
    "--name", $storageAccountName
)
Write-Host "削除対象: $($account.id)"

# ------------------------------------------------------------
# 実行元IPv4を一時許可し、Blobへの接続を確認
# ------------------------------------------------------------
$originalPublicAccess = $account.publicNetworkAccess
$originalDefaultAction = $account.networkRuleSet.defaultAction
if ($originalPublicAccess -notin @("Enabled", "Disabled")) {
    throw "このスクリプトはEnabled/Disabledのネットワーク設定を対象にしています。現在: $originalPublicAccess"
}
$clientIp = ([string](Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 30)).Trim()
$ip = $null
if (-not [System.Net.IPAddress]::TryParse($clientIp, [ref]$ip) -or
    $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw "実行元のパブリックIPv4を取得できません: $clientIp"
}
$addIpRule = $clientIp -notin @($account.networkRuleSet.ipRules.ipAddressOrRange)
$ruleAttempted = $false
$networkAttempted = $false
$deleted = $false

try {
    Write-Host "一時許可する実行元IPv4: $clientIp"
    if ($addIpRule) {
        $ruleAttempted = $true
        $null = Invoke-AzJson -Arguments @(
            "storage", "account", "network-rule", "add",
            "--subscription", $subscriptionId, "--resource-group", $resourceGroup,
            "--account-name", $storageAccountName, "--ip-address", $clientIp
        )
    }
    $networkAttempted = $true
    $null = Invoke-AzJson -Arguments @(
        "storage", "account", "update",
        "--subscription", $subscriptionId, "--resource-group", $resourceGroup,
        "--name", $storageAccountName,
        "--public-network-access", "Enabled", "--default-action", "Deny"
    )

    $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
        try {
            $null = Invoke-AzJson -Arguments @(
                "storage", "container", "list", "--subscription", $subscriptionId,
                "--account-name", $storageAccountName, "--auth-mode", "login",
                "--num-results", "1"
            )
            break
        }
        catch {
            if ((Get-Date) -ge $deadline) {
                throw "5分待ってもBlobに接続できません。実行元IP・プロキシ・Blobデータ権限を確認してください。削除は開始していません。`n$($_.Exception.Message)"
            }
            Write-Host "接続設定の反映を待っています..."
            Start-Sleep -Seconds 10
        }
    }

    $containers = @(Invoke-AzJson -Arguments @(
        "storage", "container-rm", "list",
        "--subscription", $subscriptionId,
        "--resource-group", $resourceGroup,
        "--storage-account", $storageAccountName
    ))

    # ------------------------------------------------------------
    # Blob・スナップショット・過去バージョンを削除してからコンテナーを削除
    # ------------------------------------------------------------
    foreach ($container in $containers) {
        $name = $container.name
        Write-Host "コンテナー内を削除中: $name"

        $blobs = @(Invoke-AzJson -Arguments @(
            "storage", "blob", "list", "--subscription", $subscriptionId,
            "--account-name", $storageAccountName, "--auth-mode", "login",
            "--container-name", $name, "--num-results", "*"
        ))
        foreach ($blob in $blobs) {
            $null = Invoke-AzJson -Arguments @(
                "storage", "blob", "delete", "--subscription", $subscriptionId,
                "--account-name", $storageAccountName, "--auth-mode", "login",
                "--container-name", $name, "--name", $blob.name,
                "--delete-snapshots", "include"
            )
        }

        $versions = @(Invoke-AzJson -Arguments @(
            "storage", "blob", "list",
            "--subscription", $subscriptionId,
            "--account-name", $storageAccountName,
            "--auth-mode", "login", "--container-name", $name,
            "--include", "v", "--num-results", "*"
        ))
        foreach ($blob in $versions) {
            if (-not $blob.versionId) {
                throw "Blobが残っています。ログ送信が停止しているか確認してください: $name / $($blob.name)"
            }
            $null = Invoke-AzJson -Arguments @(
                "storage", "blob", "delete",
                "--subscription", $subscriptionId,
                "--account-name", $storageAccountName,
                "--auth-mode", "login", "--container-name", $name,
                "--name", $blob.name, "--version-id", $blob.versionId
            )
        }

        $remaining = @(Invoke-AzJson -Arguments @(
            "storage", "blob", "list",
            "--subscription", $subscriptionId,
            "--account-name", $storageAccountName,
            "--auth-mode", "login", "--container-name", $name,
            "--include", "v", "s", "--num-results", "*"
        ))
        if ($remaining.Count -gt 0) {
            throw "Blob・バージョン・スナップショットが残っています: $name"
        }

        $null = Invoke-AzJson -Arguments @(
            "storage", "container-rm", "delete",
            "--subscription", $subscriptionId,
            "--resource-group", $resourceGroup,
            "--storage-account", $storageAccountName,
            "--name", $name, "--yes"
        )
        Write-Host "コンテナー削除完了: $name"
    }

    # ------------------------------------------------------------
    # ストレージアカウントを削除
    # ------------------------------------------------------------
    $null = Invoke-AzJson -Arguments @(
        "storage", "account", "delete",
        "--subscription", $subscriptionId,
        "--resource-group", $resourceGroup,
        "--name", $storageAccountName, "--yes"
    )
    $deleted = $true
    Write-Host "ストレージアカウント削除完了: $storageAccountName"

}
finally {
    # ------------------------------------------------------------
    # 削除未完了の場合は、変更したネットワーク設定を復元
    # ------------------------------------------------------------
    if (-not $deleted) {
        if ($networkAttempted) {
            try {
                $null = Invoke-AzJson -Arguments @(
                    "storage", "account", "update",
                    "--subscription", $subscriptionId, "--resource-group", $resourceGroup,
                    "--name", $storageAccountName,
                    "--public-network-access", $originalPublicAccess,
                    "--default-action", $originalDefaultAction
                )
                Write-Host "元のネットワーク設定に復元しました。"
            }
            catch { Write-Warning "ネットワーク設定の復元に失敗しました。手動確認が必要です: $($_.Exception.Message)" }
        }
        if ($ruleAttempted) {
            try {
                $null = Invoke-AzJson -Arguments @(
                    "storage", "account", "network-rule", "remove",
                    "--subscription", $subscriptionId, "--resource-group", $resourceGroup,
                    "--account-name", $storageAccountName, "--ip-address", $clientIp
                )
            }
            catch { Write-Warning "一時IPルールの削除に失敗しました: $clientIp / $($_.Exception.Message)" }
        }
    }
}
