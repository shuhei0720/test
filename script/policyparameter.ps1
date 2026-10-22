# 前提:
# ・Connect-AzAccount 済み
# ・Az.Accounts / Az.ResourceGraph / Az.Monitor / Az.Resources 導入済み
# ・PowerShell 7 で実行

# 対象のポリシー割り当てID（Resource ID）配列
$policyAssignmentIds = @(
    '<対象のポリシー割り当てID>'
)

# Resource Graphで取得できないリソースタイプを個別定義
$additionalResourceTypes = @(
    'microsoft.storage/storageaccounts/blobservices'
    'microsoft.storage/storageaccounts/fileservices'
    'microsoft.storage/storageaccounts/queueservices'
    'microsoft.storage/storageaccounts/tableservices'
)

# Azure Resource Graph: タイプごとに代表1件を取得
$query = @"
resources
| summarize arg_max(tostring(id), type) by type
| project id, type
"@

$first = 1000
$skipToken = $null
$uniqTypeSamples = [System.Collections.Generic.List[object]]::new()

do {
    $params = @{
        Query = $query
        First = $first
    }

    if ($skipToken) {
        $params.SkipToken = $skipToken
    }

    $page = Search-AzGraph @params

    if ($page -and $page.Data) {
        $uniqTypeSamples.AddRange($page.Data)
    }

    $skipToken = $page.SkipToken
} while ($skipToken)

# ログカテゴリをサポートするタイプのみ抽出
# 比較・収集の段階で小文字化してセットへ追加
$supportedTypesLower = [System.Collections.Generic.HashSet[string]]::new()

foreach ($row in $uniqTypeSamples) {
    $type = $row.type
    $sampleId = $row.id

    if (-not $type -or -not $sampleId) {
        continue
    }

    try {
        $logs = Get-AzDiagnosticSettingCategory -ResourceId $sampleId -ErrorAction Stop |
            Where-Object { $_.CategoryType -eq 'Logs' }

        if ($logs) {
            [void]$supportedTypesLower.Add($type.ToLower())
        }
    }
    catch {
    }
}

# 個別定義したリソースタイプを追加
foreach ($type in $additionalResourceTypes) {
    [void]$supportedTypesLower.Add($type.ToLower())
}

# 新規検出（すでに小文字化済み）
$newDetectedLower = [string[]]($supportedTypesLower | Sort-Object)

# ユーティリティ: Parameter 正規化
# この環境は Parameters ではなく Parameter を使用
function Normalize-PolicyParameter {
    param([object]$raw)

    $norm = @{}

    if ($null -eq $raw) {
        return $norm
    }

    foreach ($p in $raw.PSObject.Properties) {
        $name = $p.Name
        $val = $p.Value

        if ($null -eq $name) {
            continue
        }

        if ($null -eq $val) {
            $norm[$name] = @{ value = $null }
        }
        elseif (
            $val.PSObject -and
            ($val.PSObject.Properties.Name -contains 'value')
        ) {
            $norm[$name] = @{ value = $val.value }
        }
        else {
            $norm[$name] = @{ value = $val }
        }
    }

    return $norm
}

function AsStringArray {
    param([object]$val)

    if ($null -eq $val) {
        return @()
    }

    if (
        $val -is [System.Collections.IEnumerable] -and
        -not ($val -is [string])
    ) {
        return @($val)
    }

    return @([string]$val)
}

foreach ($assignmentId in $policyAssignmentIds) {
    Write-Host "----- 処理開始: $assignmentId -----"

    try {
        $pa = Get-AzPolicyAssignment -Id $assignmentId -ErrorAction Stop

        # 既存は「Parameter」を参照して正規化
        $existingParam = $pa.Parameter
        $norm = Normalize-PolicyParameter -raw $existingParam

        # 既存リストを取得し、小文字化して比較用セットへ追加
        $existingListRaw = AsStringArray -val (
            $norm.ContainsKey('listOfResourceTypes') ?
                $norm['listOfResourceTypes'].value :
                $null
        )

        $compareSetLower = [System.Collections.Generic.HashSet[string]]::new()

        foreach ($e in $existingListRaw) {
            if ($e) {
                [void]$compareSetLower.Add($e.ToLower())
            }
        }

        # 比較用セットに新規検出（すでに小文字化済み）を追加
        foreach ($t in $newDetectedLower) {
            [void]$compareSetLower.Add($t)
        }

        # 最終送信用の配列（小文字統一・ユニーク・ソート）
        $mergedLowerArray = [string[]]($compareSetLower | Sort-Object)

        # 送信パラメーター（既存キーは保持、リストのみ差し替え）
        $paramObj = @{}

        foreach ($kv in $norm.GetEnumerator()) {
            $paramObj[$kv.Key] = @{ value = $kv.Value.value }
        }

        $paramObj['listOfResourceTypes'] = @{
            value = $mergedLowerArray
        }

        # JSONを生成（Array型を保持）
        $jsonParams = $paramObj | ConvertTo-Json -Depth 10

        # 送信JSONプレビュー
        Write-Host "送信JSONプレビュー:"
        Write-Host $jsonParams

        # 更新（ID指定、PolicyParameterにJSONを渡す）
        Update-AzPolicyAssignment -Id $pa.Id -PolicyParameter $jsonParams |
            Out-Null

        # 確認（再取得）
        $updated = Get-AzPolicyAssignment -Id $pa.Id -ErrorAction Stop

        Write-Host (
            "更新成功: {0} (list 合計: {1}, 比較時点で小文字統一・ユニーク化済み)" -f
            $assignmentId, $mergedLowerArray.Count
        )
    }
    catch {
        Write-Warning "更新失敗: $assignmentId - $($_.Exception.Message)"
    }

    Write-Host "----- 処理完了: $assignmentId -----"
}