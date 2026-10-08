$ErrorActionPreference = "Stop"
$storageAccountId = "/subscriptions/サブスクリプションID/resourceGroups/リソースグループ名/providers/Microsoft.Storage/storageAccounts/ストレージアカウント名"

# ------------------------------------------------------------
# 共通処理：認証トークンの取得、REST APIの実行、Blob一覧の取得
# ------------------------------------------------------------
$tokens = @{}
function Invoke-AzureRest {
    param(
        [string]$Method,
        [string]$Uri,
        [switch]$Storage,
        [object]$Body,
        [hashtable]$Headers = @{}
    )

    $audience = if ($Storage) { "https://storage.azure.com/" } else { "https://management.azure.com/" }
    if (-not $tokens.ContainsKey($audience) -or $tokens[$audience].RefreshAt -lt (Get-Date)) {
        $tokenFile = [IO.Path]::GetTempFileName()
        try {
            $json = & az account get-access-token --subscription $subscriptionId `
                --resource $audience --only-show-errors --output json 2> $tokenFile
            if ($LASTEXITCODE -ne 0) { throw (Get-Content $tokenFile -Raw) }
            $token = ($json -join "`n") | ConvertFrom-Json
            if (-not $token.accessToken) { throw "アクセストークンを取得できません。" }
            $expires = if ($token.expires_on) {
                [DateTimeOffset]::FromUnixTimeSeconds([long]$token.expires_on).LocalDateTime
            } else {
                [datetime]$token.expiresOn
            }
            $tokens[$audience] = @{ Value = $token.accessToken; RefreshAt = $expires.AddMinutes(-5) }
        }
        finally { Remove-Item $tokenFile -Force }
    }

    $requestHeaders = @{ Authorization = "Bearer $($tokens[$audience].Value)" }
    if ($Storage) {
        $requestHeaders["x-ms-version"] = "2023-11-03"
        $requestHeaders["x-ms-date"] = [DateTime]::UtcNow.ToString("R", [Globalization.CultureInfo]::InvariantCulture)
    }
    foreach ($key in $Headers.Keys) { $requestHeaders[$key] = $Headers[$key] }
    $request = @{
        Method = $Method; Uri = $Uri; Headers = $requestHeaders
        UseBasicParsing = $true; TimeoutSec = 60; ErrorAction = "Stop"
    }
    if ($null -ne $Body) {
        $request.ContentType = "application/json; charset=utf-8"
        $request.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 30))
    }
    Invoke-WebRequest @request
}

function Get-BlobItems {
    param([string]$ContainerUri, [switch]$History)

    $marker = ""
    do {
        $uri = "${ContainerUri}?restype=container&comp=list&maxresults=5000"
        if ($History) { $uri += "&include=versions%2Csnapshots" }
        if ($marker) { $uri += "&marker=$([Uri]::EscapeDataString($marker))" }
        $response = Invoke-AzureRest GET $uri -Storage
        $content = $response.Content
        if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
        [xml]$xml = $content.TrimStart([char]0xFEFF)
        foreach ($node in $xml.SelectNodes("/EnumerationResults/Blobs/Blob")) {
            $nameNode = $node.SelectSingleNode("Name")
            $name = $nameNode.InnerText
            if ($nameNode.GetAttribute("Encoded") -eq "true") { $name = [Uri]::UnescapeDataString($name) }
            $path = (($name -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
            [pscustomobject]@{
                Uri = "$ContainerUri/$path"
                VersionId = [string]$node.SelectSingleNode("VersionId").InnerText
                Snapshot = [string]$node.SelectSingleNode("Snapshot").InnerText
                Current = [string]$node.SelectSingleNode("IsCurrentVersion").InnerText
            }
        }
        $marker = [string]$xml.SelectSingleNode("/EnumerationResults/NextMarker").InnerText
    } while ($marker)
}

# ------------------------------------------------------------
# リソースIDから削除対象を取得し、元のネットワーク設定を保存
# ------------------------------------------------------------
$storageAccountId = $storageAccountId.Trim().TrimEnd('/')
if ($storageAccountId -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Storage/storageAccounts/([^/]+)$') {
    throw "ストレージアカウントのリソースIDを指定してください。"
}
$subscriptionId = $Matches[1]
$accountUri = "https://management.azure.com${storageAccountId}?api-version=2023-05-01"
$account = (Invoke-AzureRest GET $accountUri).Content | ConvertFrom-Json
$blobEndpoint = $account.properties.primaryEndpoints.blob.TrimEnd('/')
$originalNetwork = @{
    properties = @{
        publicNetworkAccess = $account.properties.publicNetworkAccess
        networkAcls = $account.properties.networkAcls
    }
}
if ($originalNetwork.properties.publicNetworkAccess -notin @("Enabled", "Disabled")) {
    throw "ネットワーク設定がEnabled/Disabledではないため停止します。"
}
Write-Host "削除対象: $($account.id)"

$clientIp = ([string](Invoke-RestMethod "https://api.ipify.org" -TimeoutSec 30)).Trim()
$ip = $null
if (-not [Net.IPAddress]::TryParse($clientIp, [ref]$ip) -or
    $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw "実行元のパブリックIPv4を取得できません: $clientIp"
}
$temporaryAcls = $account.properties.networkAcls | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$temporaryAcls.defaultAction = "Deny"
if ($clientIp -notin @($temporaryAcls.ipRules.value)) {
    $temporaryAcls.ipRules = @($temporaryAcls.ipRules) + @(@{ value = $clientIp; action = "Allow" })
}
$networkChanged = $false
$deleted = $false

try {
    # ------------------------------------------------------------
    # 実行元IPv4を一時許可し、Blobへの接続を確認
    # ------------------------------------------------------------
    Write-Host "一時許可する実行元IPv4: $clientIp"
    $networkChanged = $true
    $null = Invoke-AzureRest PATCH $accountUri -Body @{
        properties = @{ publicNetworkAccess = "Enabled"; networkAcls = $temporaryAcls }
    }
    $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
        try {
            $null = Invoke-AzureRest GET "${blobEndpoint}/?comp=list&maxresults=1" -Storage
            break
        }
        catch {
            if ((Get-Date) -ge $deadline) {
                throw "Blobに接続できません。実行元IP・プロキシ・Blobデータ権限を確認してください。削除は開始していません。`n$($_.Exception.Message)"
            }
            Write-Host "Blobへの接続を待っています..."
            Start-Sleep -Seconds 10
        }
    }

    # ------------------------------------------------------------
    # Blob・過去バージョン・スナップショットを削除後、コンテナーを削除
    # ------------------------------------------------------------
    $containers = @()
    $next = "https://management.azure.com${storageAccountId}/blobServices/default/containers?api-version=2023-05-01"
    do {
        $page = (Invoke-AzureRest GET $next).Content | ConvertFrom-Json
        $containers += @($page.value)
        $next = $page.nextLink
    } while ($next)

    foreach ($container in $containers) {
        Write-Host "コンテナー内を削除中: $($container.name)"
        $containerUri = "$blobEndpoint/$([Uri]::EscapeDataString($container.name))"
        $blobs = @(Get-BlobItems $containerUri)
        foreach ($blob in $blobs) {
            $null = Invoke-AzureRest DELETE $blob.Uri -Storage -Headers @{ "x-ms-delete-snapshots" = "include" }
        }
        $history = @(Get-BlobItems $containerUri -History)
        foreach ($blob in $history) {
            if ($blob.Current -eq "true") { throw "新しいBlobが存在します。ログ送信を停止してください: $($blob.Uri)" }
            if ($blob.Snapshot) {
                $uri = "$($blob.Uri)?snapshot=$([Uri]::EscapeDataString($blob.Snapshot))"
            } elseif ($blob.VersionId) {
                $uri = "$($blob.Uri)?versionid=$([Uri]::EscapeDataString($blob.VersionId))"
            } else {
                throw "Blobが残っています。ログ送信を停止してください: $($blob.Uri)"
            }
            $null = Invoke-AzureRest DELETE $uri -Storage
        }
        if (@(Get-BlobItems $containerUri -History).Count -gt 0) {
            throw "Blob・バージョン・スナップショットが残っています: $($container.name)"
        }
        $null = Invoke-AzureRest DELETE "https://management.azure.com$($container.id)?api-version=2023-05-01"
        Write-Host "コンテナー削除完了: $($container.name)"
    }

    # ------------------------------------------------------------
    # ストレージアカウントを削除し、削除完了を確認
    # ------------------------------------------------------------
    $null = Invoke-AzureRest DELETE $accountUri
    $deadline = (Get-Date).AddMinutes(5)
    while (-not $deleted) {
        try { $null = Invoke-AzureRest GET $accountUri }
        catch {
            if ([int]$_.Exception.Response.StatusCode -eq 404) { $deleted = $true }
            else { throw }
        }
        if ($deleted) { break }
        if ((Get-Date) -ge $deadline) { throw "削除完了を5分以内に確認できませんでした。Azure側の状態を確認してください。" }
        Start-Sleep -Seconds 5
    }
    Write-Host "ストレージアカウント削除完了: $($account.name)"
}
finally {
    # ------------------------------------------------------------
    # 削除未完了の場合は、元のネットワーク設定に復元
    # ------------------------------------------------------------
    if ($networkChanged -and -not $deleted) {
        try {
            $null = Invoke-AzureRest PATCH $accountUri -Body $originalNetwork
            Write-Host "元のネットワーク設定に復元しました。"
        }
        catch {
            if ([int]$_.Exception.Response.StatusCode -ne 404) {
                Write-Warning "ネットワーク設定の復元に失敗しました。手動確認が必要です: $($_.Exception.Message)"
            }
        }
    }
}
