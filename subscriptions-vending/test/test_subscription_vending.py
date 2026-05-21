import json
import os
import shutil
import subprocess
import sys
import urllib.request

import yaml

AZ_CMD = shutil.which("az") or shutil.which("az.cmd")
if not AZ_CMD:
    raise RuntimeError("Azure CLI (az) が見つかりません")

YAML_PATH = sys.argv[1] if len(sys.argv) > 1 else "./subscriptions/subscription_dev_PHD_tftest002.yaml"
BILLING_ACCOUNT_ID = os.getenv("BILLING_ACCOUNT_ID", "71561797")
EXPECTED_ROLE = os.getenv("EXPECTED_ROLE", "User Access Administrator")

results = []
failed = False


def decode_output(data: bytes) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("cp932", errors="replace")


def run_az(args):
    r = subprocess.run([AZ_CMD] + args + ["-o", "json"], capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(decode_output(r.stderr).strip())
    return json.loads(decode_output(r.stdout))


def add_result(name, ok, expected, actual, reason):
    global failed
    results.append({
        "name": name,
        "ok": ok,
        "expected": expected,
        "actual": actual,
        "reason": reason,
    })
    if not ok:
        failed = True


with open(YAML_PATH, "r", encoding="utf-8") as f:
    config = yaml.safe_load(f)

SUBSCRIPTION_NAME = config["subscription_name"]
MANAGEMENT_GROUP_ID = config["management_group_id"]
EXPECTED_ASSIGNEES = [x for x in config.get("rbac_assignments", []) if str(x).strip()]
EXPECTED_ENROLLMENT_ACCOUNT_DISPLAY_NAME = config["tags"]["cost_center"]

subscription_id = None

# サブスクリプション作成確認
try:
    subscriptions = run_az(["account", "list", "--all"])
    target = None
    for s in subscriptions:
        if s.get("name") == SUBSCRIPTION_NAME:
            target = s
            break

    if target is None:
        add_result(
            "サブスクリプション作成確認",
            False,
            SUBSCRIPTION_NAME,
            "未検出",
            "az account list の結果に対象サブスクリプション名が存在しません"
        )
    else:
        subscription_id = target["id"]
        expected = SUBSCRIPTION_NAME
        actual = target.get("name", "")
        add_result(
            "サブスクリプション作成確認",
            actual == expected,
            expected,
            actual,
            "期待値と実際値が一致しました" if actual == expected else "期待値と実際値が一致しません"
        )
except Exception as e:
    add_result("サブスクリプション作成確認", False, SUBSCRIPTION_NAME, str(e), "サブスクリプション確認中にエラーが発生しました")

# 課金スコープ確認
try:
    if not subscription_id:
        add_result("課金スコープ確認", False, "課金スコープ確認可能", "subscription_id 未取得", "サブスクリプションが見つからないため確認できません")
    else:
        token_raw = subprocess.run(
            [
                AZ_CMD,
                "account", "get-access-token",
                "--resource", "https://management.azure.com",
                "--query", "accessToken",
                "-o", "tsv",
            ],
            capture_output=True,
        )
        if token_raw.returncode != 0:
            raise RuntimeError(decode_output(token_raw.stderr).strip())
        token = decode_output(token_raw.stdout).strip()

        req = urllib.request.Request(
            f"https://management.azure.com/providers/Microsoft.Billing/billingAccounts/{BILLING_ACCOUNT_ID}/enrollmentAccounts?api-version=2024-04-01",
            headers={"Authorization": f"Bearer {token}"},
            method="GET",
        )
        with urllib.request.urlopen(req) as resp:
            enrollment_accounts = json.loads(resp.read().decode("utf-8"))

        expected_enrollment_id = None
        for x in enrollment_accounts.get("value", []):
            props = x.get("properties", {})
            if props.get("displayName") == EXPECTED_ENROLLMENT_ACCOUNT_DISPLAY_NAME or props.get("departmentDisplayName") == EXPECTED_ENROLLMENT_ACCOUNT_DISPLAY_NAME:
                expected_enrollment_id = x.get("name")
                break

        if not expected_enrollment_id:
            add_result(
                "課金スコープ確認",
                False,
                EXPECTED_ENROLLMENT_ACCOUNT_DISPLAY_NAME,
                "未解決",
                "期待する enrollment account が billing account 配下に見つかりません"
            )
        else:
            matched = None
            next_url = f"https://management.azure.com/providers/Microsoft.Billing/billingAccounts/{BILLING_ACCOUNT_ID}/billingSubscriptions?api-version=2024-04-01"

            while next_url:
                req = urllib.request.Request(
                    next_url,
                    headers={"Authorization": f"Bearer {token}"},
                    method="GET",
                )
                with urllib.request.urlopen(req) as resp:
                    data = json.loads(resp.read().decode("utf-8"))

                for x in data.get("value", []):
                    props = x.get("properties", {})
                    if (props.get("subscriptionId") or "").lower() == subscription_id.lower():
                        matched = x
                        break

                if matched:
                    break

                next_link = data.get("nextLink")
                next_url = next_link if next_link else None

            expected = f"enrollmentAccountId={expected_enrollment_id}, subscriptionName={SUBSCRIPTION_NAME}"

            if matched:
                props = matched.get("properties", {})
                actual = f"enrollmentAccountId={props.get('enrollmentAccountId', '')}, subscriptionName={props.get('displayName', '')}"
                ok = str(props.get("enrollmentAccountId", "")) == str(expected_enrollment_id)
                reason = "期待値と実際値が一致しました" if ok else "対象サブスクリプションは見つかりましたが、期待する Enrollment Account 配下ではありません"
            else:
                actual = "未検出"
                ok = False
                reason = "対象サブスクリプションが billingSubscriptions 一覧に見つかりません"

            add_result("課金スコープ確認", ok, expected, actual, reason)
except Exception as e:
    add_result("課金スコープ確認", False, EXPECTED_ENROLLMENT_ACCOUNT_DISPLAY_NAME, str(e), "課金スコープ確認中にエラーが発生しました")

# 管理グループ紐付け確認
try:
    if not subscription_id:
        add_result("管理グループ紐付け確認", False, True, False, "サブスクリプションが見つからないため確認できません")
    else:
        run_az([
            "account", "management-group", "subscription", "show",
            "--name", MANAGEMENT_GROUP_ID,
            "--subscription", subscription_id,
        ])
        add_result(
            "管理グループ紐付け確認",
            True,
            True,
            True,
            f"サブスクリプションが管理グループ {MANAGEMENT_GROUP_ID} 配下に存在しました"
        )
except Exception as e:
    add_result(
        "管理グループ紐付け確認",
        False,
        True,
        False,
        f"サブスクリプションが管理グループ {MANAGEMENT_GROUP_ID} 配下に存在しません: {e}"
    )

# RBAC確認
try:
    if not subscription_id:
        add_result("RBAC確認", False, ", ".join(EXPECTED_ASSIGNEES), "subscription_id 未取得", "サブスクリプションが見つからないため確認できません")
    else:
        assignments = run_az([
            "role", "assignment", "list",
            "--scope", f"/subscriptions/{subscription_id}"
        ])

        expected_list = [f"{x} ({EXPECTED_ROLE})" for x in EXPECTED_ASSIGNEES]
        actual_list = []

        for assignee in EXPECTED_ASSIGNEES:
            for a in assignments:
                principal_name = (a.get("principalName") or "")
                role_name = a.get("roleDefinitionName") or ""
                if principal_name.lower() == assignee.lower() and role_name == EXPECTED_ROLE:
                    actual_list.append(f"{principal_name} ({role_name})")
                    break

        expected = ", ".join(sorted(expected_list))
        actual = ", ".join(sorted(actual_list)) if actual_list else "一致なし"

        add_result(
            "RBAC確認",
            actual == expected,
            expected,
            actual,
            "期待値と実際値が一致しました" if actual == expected else "期待するRBACが不足しています"
        )
except Exception as e:
    add_result("RBAC確認", False, ", ".join(EXPECTED_ASSIGNEES), str(e), "RBAC確認中にエラーが発生しました")

print("=== 払い出し自動テスト結果 ===")
for r in results:
    status = "OK" if r["ok"] else "NG"
    print(f"[{status}] {r['name']}")
    print(f"  期待値: {r['expected']}")
    print(f"  実際値: {r['actual']}")
    print(f"  理由  : {r['reason']}")

sys.exit(1 if failed else 0)
