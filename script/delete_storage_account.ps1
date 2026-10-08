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

    $null = Invoke-AzJson -Arguments @(
        "storage", "blob", "delete-batch",
        "--subscription", $subscriptionId,
        "--account-name", $storageAccountName,
        "--auth-mode", "login", "--source", $name,
        "--delete-snapshots", "include"
    )

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
Write-Host "ストレージアカウント削除完了: $storageAccountName"
