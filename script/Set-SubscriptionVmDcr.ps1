#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Compute

# ===== 以下の4変数を変更してください =====
$SubscriptionId      = '00000000-0000-0000-0000-000000000000'
$DcrResourceGroupName = 'rg-monitor'
$DcrName              = 'dcr-vm-logs'
$WorkspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-monitor/providers/Microsoft.OperationalInsights/workspaces/log-example'

$ErrorActionPreference = 'Stop'
$DcrApiVersion = '2024-03-11'
$WorkspaceResourceId = $WorkspaceResourceId.TrimEnd('/')
$CsvPath = Join-Path $PWD ('vm-dcr-results-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# REST APIを呼び出す。許可した404だけを「存在しない」として扱う
function Invoke-Arm {
    param(
        [string]$Path,
        [string]$Method = 'GET',
        [object]$Body,
        [switch]$AllowNotFound
    )
    try {
        $parameters = @{ Path = $Path; Method = $Method; ErrorAction = 'Stop' }
        if ($null -ne $Body) {
            $parameters.Payload = $Body | ConvertTo-Json -Depth 40
        }
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
    if ($AllowNotFound -and $status -eq 404) { return $null }
    if ($status -lt 200 -or $status -ge 300) {
        throw "HTTP ${status}：$content"
    }
    if ($content) { return ($content | ConvertFrom-Json -AsHashtable) }
}

# オブジェクトのキーと配列を並べ替え、順序に依存せず設定内容を比較する
function ConvertTo-ComparisonText {
    param([object]$Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = foreach ($key in ($Value.Keys | Sort-Object)) {
            if ($null -ne $Value[$key]) {
                ($key | ConvertTo-Json -Compress) + ':' + (ConvertTo-ComparisonText $Value[$key])
            }
        }
        return ('{' + ($parts -join ',') + '}')
    }
    if ($Value -is [array]) {
        $parts = @($Value | ForEach-Object { ConvertTo-ComparisonText $_ } | Sort-Object)
        return ('[' + ($parts -join ',') + ']')
    }
    return (ConvertTo-Json -InputObject $Value -Compress -Depth 40)
}

# Azureが補完するワークスペースIDや既定のデータフロー表現を比較から除く
function Get-DcrComparisonText {
    param([object]$Rule)
    $properties = $Rule.properties | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable
    foreach ($destination in @($properties.destinations.logAnalytics)) {
        if ($null -ne $destination) { $destination.Remove('workspaceId') }
    }
    foreach ($flow in @($properties.dataFlows)) {
        if ($flow.transformKql -eq 'source') { $flow.Remove('transformKql') }
        if (@($flow.streams).Count -eq 1 -and $flow.outputStream -eq $flow.streams[0]) {
            $flow.Remove('outputStream')
        }
    }
    return (ConvertTo-ComparisonText @{
        dataSources  = $properties.dataSources
        destinations = $properties.destinations
        dataFlows    = $properties.dataFlows
    })
}

if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

# 送信先ワークスペースは既存のものを指定する
if ($WorkspaceResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.OperationalInsights/workspaces/[^/]+$') {
    throw 'WorkspaceResourceIdにLog Analyticsワークスペースの完全なリソースIDを指定してください。'
}
$workspace = Invoke-Arm -Path "${WorkspaceResourceId}?api-version=2022-10-01"
$location = $workspace.location
$rgId = "/subscriptions/$SubscriptionId/resourceGroups/$DcrResourceGroupName"
$dcrId = "$rgId/providers/Microsoft.Insights/dataCollectionRules/$DcrName"
$dcrPath = "${dcrId}?api-version=$DcrApiVersion"

# 作成先リソースグループが存在しなければ作成する
$rg = Invoke-Arm -Path "${rgId}?api-version=2021-04-01" -AllowNotFound
if ($null -eq $rg) {
    Invoke-Arm -Method PUT -Path "${rgId}?api-version=2021-04-01" -Body @{ location = $location } | Out-Null
    Write-Host "リソースグループを作成しました：$DcrResourceGroupName"
}

# 写真の設定を使用する。Windows／Linux共通のためkindは指定しない
$body = @{
    location = $location
    properties = @{
        dataSources = @{
            windowsEventLogs = @(
                @{
                    name = 'eventLogsDataSource'
                    streams = @('Microsoft-Event')
                    xPathQueries = @(
                        'Application!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0 or Level=5)]]'
                        'Security!*[System[(band(Keywords,13510798882111488))]]'
                        'System!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0 or Level=5)]]'
                    )
                }
            )
            syslog = @(
                @{
                    name = 'sysLogsDataSource'
                    streams = @('Microsoft-Syslog')
                    facilityNames = @(
                        'alert', 'audit', 'auth', 'authpriv', 'clock', 'cron',
                        'daemon', 'ftp', 'kern', 'local0', 'local1', 'local2',
                        'local3', 'local4', 'local5', 'local6', 'local7', 'lpr',
                        'mail', 'news', 'nopri', 'ntp', 'syslog', 'user', 'uucp'
                    )
                    logLevels = @(
                        'Debug', 'Info', 'Notice', 'Warning',
                        'Error', 'Critical', 'Alert', 'Emergency'
                    )
                }
            )
        }
        destinations = @{
            logAnalytics = @(
                @{ name = 'new-workspace'; workspaceResourceId = $WorkspaceResourceId }
            )
        }
        dataFlows = @(
            @{ streams = @('Microsoft-Event'); destinations = @('new-workspace') }
            @{ streams = @('Microsoft-Syslog'); destinations = @('new-workspace') }
        )
    }
}

# 同名DCRは同じ収集設定ならスキップし、異なる場合は写真の設定へ更新する
$existingDcr = Invoke-Arm -Path $dcrPath -AllowNotFound
$dcrResult = 'スキップ'
if ($null -ne $existingDcr) {
    if ($existingDcr.location -ne $location -or $existingDcr.kind) {
        throw '既存DCRのリージョンまたはkindが今回の構成と異なります。新しいDCR名を指定してください。'
    }
    if ($existingDcr.tags) { $body.tags = $existingDcr.tags }
    # 既存のDCE、説明、エージェント設定などは維持する
    foreach ($key in @('dataCollectionEndpointId', 'description', 'agentSettings')) {
        if ($existingDcr.properties.ContainsKey($key)) {
            $body.properties[$key] = $existingDcr.properties[$key]
        }
    }
}
if ($null -eq $existingDcr -or (Get-DcrComparisonText $existingDcr) -cne (Get-DcrComparisonText $body)) {
    Invoke-Arm -Method PUT -Path $dcrPath -Body $body | Out-Null
    $dcrResult = '作成・更新'
}

# DCRの作成・更新が完了してからVMに関連付ける
$deadline = (Get-Date).AddMinutes(5)
do {
    $dcr = Invoke-Arm -Path $dcrPath
    $state = $dcr.properties.provisioningState
    if ($state -eq 'Succeeded') { break }
    if ($state -in @('Failed', 'Canceled') -or (Get-Date) -ge $deadline) {
        throw "DCRの準備に失敗、またはタイムアウトしました：$state"
    }
    Start-Sleep -Seconds 5
} while ($true)
Write-Host "DCR：$dcrResult / $dcrId"

# DCRのIDから安定した関連付け名を作る。既存の同一DCRへの関連付けは名前に関係なく再利用する
$hash = [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($dcrId.ToLowerInvariant()))
$associationName = 'dcr-' + [Convert]::ToHexString($hash).Substring(0, 16).ToLowerInvariant()
$versions = @{}
$results = [System.Collections.Generic.List[object]]::new()
$vms = @(Get-AzVM)
$index = 0

foreach ($vm in $vms) {
    $index++
    Write-Host "[$index/$($vms.Count)] VM：$($vm.Name)"
    $row = [pscustomobject]@{
        VM名 = $vm.Name
        リソースID = $vm.Id
        OS = [string]$vm.StorageProfile.OsDisk.OsType
        ID設定 = '未処理'
        DCR関連付け = '未処理'
        AMA = '未処理'
        処理結果 = ''
        理由 = ''
    }
    $stage = 'OS判定'
    try {
        if ($row.OS -notin @('Windows', 'Linux')) {
            $row.処理結果 = 'スキップ'
            $row.理由 = 'Windows／Linux以外、またはOSを判定できないVMです。'
            continue
        }

        # AMAの認証用にシステム割り当てIDを有効化する。既存のユーザー割り当てIDは残す
        $stage = 'マネージドID設定'
        if ([string]$vm.Identity.Type -notmatch 'SystemAssigned') {
            $parameters = @{ ResourceGroupName = $vm.ResourceGroupName; VM = $vm; IdentityType = 'SystemAssigned' }
            if ($vm.Identity.UserAssignedIdentities -and $vm.Identity.UserAssignedIdentities.Count -gt 0) {
                $parameters.IdentityType = 'SystemAssignedUserAssigned'
                $parameters.IdentityId = @($vm.Identity.UserAssignedIdentities.Keys)
            }
            Update-AzVM @parameters | Out-Null
            $row.ID設定 = '有効化'
        }
        else { $row.ID設定 = 'スキップ' }

        # 他のDCR関連付けは残し、今回のDCRを追加する
        $stage = 'DCR関連付け'
        $basePath = "$($vm.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations"
        $associations = Invoke-Arm -Path "${basePath}?api-version=$DcrApiVersion"
        $same = @($associations.value | Where-Object { $_.properties.dataCollectionRuleId -ieq $dcrId })
        if ($same.Count -gt 0) { $row.DCR関連付け = 'スキップ' }
        else {
            if (@($associations.value | Where-Object { $_.name -eq $associationName }).Count -gt 0) {
                throw '同名の関連付けが別の接続先で使用されています。既存設定を確認してください。'
            }
            Invoke-Arm -Method PUT -Path "$basePath/${associationName}?api-version=$DcrApiVersion" -Body @{
                properties = @{ dataCollectionRuleId = $dcrId }
            } | Out-Null
            $row.DCR関連付け = '作成'
        }

        # OSに対応するAMA拡張機能を確認する
        $stage = 'AMA確認'
        $extensionType = if ($row.OS -eq 'Windows') { 'AzureMonitorWindowsAgent' } else { 'AzureMonitorLinuxAgent' }
        $extensions = @(Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name)
        $agents = @($extensions | Where-Object { $_.Publisher -eq 'Microsoft.Azure.Monitor' -and $_.ExtensionType -eq $extensionType })
        $agent = $agents | Select-Object -First 1
        if ($agent -and $agent.ProvisioningState -eq 'Succeeded') {
            $row.AMA = 'スキップ'
        }
        else {
            # 停止中は関連付けまで行い、AMAの導入は起動後の再実行に回す
            $vmStatus = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status
            $running = @($vmStatus.Statuses | Where-Object Code -eq 'PowerState/running').Count -gt 0
            if (-not $running) {
                $row.AMA = '保留'
                $row.処理結果 = '保留'
                $row.理由 = 'VMが実行中ではないため、AMAの導入を保留しました。VM起動後に再実行してください。'
                continue
            }
            if ($agent -and $agent.ProvisioningState -notin @('Failed', 'Canceled')) {
                $row.AMA = '保留'
                $row.処理結果 = '保留'
                $row.理由 = "AMAの既存処理を確認してください。状態：$($agent.ProvisioningState)"
                continue
            }

            # VMのリージョンで提供される最新バージョンを取得し、自動アップグレードを有効にする
            $stage = 'AMAインストール'
            $versionKey = "$($vm.Location)/$extensionType"
            if (-not $versions.ContainsKey($versionKey)) {
                $latest = Get-AzVMExtensionImage -Location $vm.Location -PublisherName 'Microsoft.Azure.Monitor' -Type $extensionType |
                    Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
                if (-not $latest) { throw '利用可能なAMAのバージョンを取得できませんでした。' }
                $versions[$versionKey] = ([version]$latest.Version).ToString(2)
            }
            $parameters = @{
                ResourceGroupName = $vm.ResourceGroupName
                VMName = $vm.Name
                Name = $extensionType
                Location = $vm.Location
                Publisher = 'Microsoft.Azure.Monitor'
                ExtensionType = $extensionType
                TypeHandlerVersion = $versions[$versionKey]
                EnableAutomaticUpgrade = $true
            }
            # 失敗済みのAMAを再試行する場合は既存の名前・公開設定を引き継ぐ
            if ($agent) {
                $parameters.Name = $agent.Name
                if ($agent.PublicSettings) {
                    $publicSettings = [string]$agent.PublicSettings | ConvertFrom-Json -AsHashtable
                    if ([string]$publicSettings.proxy.auth -eq 'true') {
                        throw '既存AMAに認証付きプロキシ設定があります。秘密情報を保持して個別に再設定してください。'
                    }
                    $parameters.SettingString = [string]$agent.PublicSettings
                }
                $parameters.ForceRerun = [guid]::NewGuid().ToString()
            }
            Set-AzVMExtension @parameters | Out-Null
            $check = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -Name $parameters.Name
            if ($check.ProvisioningState -ne 'Succeeded') {
                throw "AMAの導入が完了していません。状態：$($check.ProvisioningState)"
            }
            $row.AMA = '導入・再設定'
        }
        $row.処理結果 = if ($row.ID設定 -eq 'スキップ' -and $row.DCR関連付け -eq 'スキップ' -and $row.AMA -eq 'スキップ') { 'スキップ' } else { '成功' }
        $row.理由 = '必要なID・DCR関連付け・AMA拡張機能を確認しました。ログ受信は別途確認してください。'
    }
    catch {
        $row.処理結果 = '失敗'
        $detail = [string]$_.ErrorDetails.Message
        if (-not $detail) { $detail = $_.Exception.Message }
        $row.理由 = "${stage}：$detail"
    }
    finally {
        $results.Add($row)
        Write-Host "  $($row.処理結果)：$($row.理由)"
        # 途中終了時にも、それまでの結果を残す
        $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8BOM
    }
}

Write-Host "`n対象サブスクリプション：$SubscriptionId"
Write-Host "DCR：$dcrId"
Write-Host "送信先：$WorkspaceResourceId"
$results | Group-Object 処理結果 | Select-Object @{Name='処理結果';Expression={$_.Name}}, @{Name='件数';Expression={$_.Count}} | Format-Table -AutoSize
$results | Where-Object 処理結果 -in @('失敗', '保留') | Format-List VM名, 理由
if ($vms.Count -eq 0) { Write-Host '対象のAzure VMはありません。' }
else { Write-Host "結果CSV：$CsvPath" }
