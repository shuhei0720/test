import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

import yaml

AZ_CMD = shutil.which("az") or shutil.which("az.cmd")
if not AZ_CMD:
    raise RuntimeError("Azure CLI (az) が見つかりません")

YAML_PATH = sys.argv[1] if len(sys.argv) > 1 else "./subscriptions-vending/subscriptions/subscription_dev_PHD_tftest002.yaml"
TFVARS_PATH = os.getenv("TFVARS_PATH", "")
BILLING_ACCOUNT_ID = os.getenv("BILLING_ACCOUNT_ID", "71561797")
EXPECTED_ENROLLMENT_ACCOUNT_ID = os.getenv("EXPECTED_ENROLLMENT_ACCOUNT_ID", "")
EXPECTED_ROLE = os.getenv("EXPECTED_ROLE", "User Access Administrator")

results = []
failed = False
access_token = None
subscription_id = None


def decode_output(data: bytes) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("cp932", errors="replace")


def run_az(args):
    r = subprocess.run([AZ_CMD] + args + ["-o", "json"], capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(decode_output(r.stderr).strip())
    stdout = decode_output(r.stdout).strip()
    return json.loads(stdout) if stdout else None


def get_access_token() -> str:
    global access_token
    if access_token:
        return access_token

    r = subprocess.run(
        [
            AZ_CMD,
            "account", "get-access-token",
            "--resource", "https://management.azure.com",
            "--query", "accessToken",
            "-o", "tsv",
        ],
        capture_output=True,
    )
    if r.returncode != 0:
        raise RuntimeError(decode_output(r.stderr).strip())

    access_token = decode_output(r.stdout).strip()
    return access_token


def arm_get(url: str):
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {get_access_token()}"},
        method="GET",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode("utf-8"))


def arm_id(subscription_id: str, resource_group: str, provider_path: str) -> str:
    return f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/{provider_path}"


def arm_url(resource_id: str, api_version: str) -> str:
    encoded = urllib.parse.quote(resource_id, safe="/:")
    return f"https://management.azure.com{encoded}?api-version={api_version}"


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


def get_subnet(config: dict, subnet_name: str):
    for subnet in config.get("virtual_network", {}).get("subnets", []):
        if subnet.get("name") == subnet_name:
            return subnet
    return None


def cidr_prefix_to_int(prefix: str) -> int:
    return int(prefix.replace("/", ""))


def ip_to_int(ip: str) -> int:
    parts = [int(x) for x in ip.split(".")]
    return (parts[0] << 24) + (parts[1] << 16) + (parts[2] << 8) + parts[3]


def int_to_ip(value: int) -> str:
    return ".".join(str((value >> shift) & 255) for shift in [24, 16, 8, 0])


def calculate_subnet_cidrs(vnet_cidr: str, subnets: list[dict]) -> dict[str, str]:
    """Terraform locals.tf と同じ考え方で、定義順に subnet CIDR を計算する。"""
    base_ip, _ = vnet_cidr.split("/")
    base_int = ip_to_int(base_ip)

    result = {}
    for idx, subnet in enumerate(subnets):
        prefix = cidr_prefix_to_int(subnet["address_prefix"])
        subnet_block_size = 2 ** (32 - prefix)

        netnum = 0
        for prev in subnets[:idx]:
            prev_prefix = cidr_prefix_to_int(prev["address_prefix"])
            netnum += 2 ** (prefix - prev_prefix)

        subnet_ip = int_to_ip(base_int + (netnum * subnet_block_size))
        result[subnet["name"]] = f"{subnet_ip}/{prefix}"

    return result


def find_tfvars_path() -> str:
    """GitHub Actions / ローカル実行のどちらでも terraform.tfvars を探せるようにする。"""
    candidates = []

    if TFVARS_PATH:
        candidates.append(TFVARS_PATH)

    candidates.extend([
        "./subscriptions-vending/terraform.tfvars",
        "./terraform.tfvars",
    ])

    for path in candidates:
        if os.path.exists(path):
            return path

    return ""


def extract_hcl_object_body(text: str, object_name: str) -> str:
    """HCL の object_name = { ... } ブロック本文を波括弧の対応で取得する。"""
    match = re.search(rf"^\s*{re.escape(object_name)}\s*=\s*\{{", text, re.MULTILINE)
    if not match:
        return ""

    start = match.end()
    depth = 1
    i = start

    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i]
        i += 1

    return ""


def load_hub_environment(tfvars_path: str, env_short_name: str) -> dict:
    """terraform.tfvars の hub_environments から対象環境の Hub 情報を取得する。"""
    resolved_path = tfvars_path or find_tfvars_path()
    if not resolved_path:
        return {}

    text = Path(resolved_path).read_text(encoding="utf-8")
    hub_envs_body = extract_hcl_object_body(text, "hub_environments")
    if not hub_envs_body:
        return {}

    env_body = extract_hcl_object_body(hub_envs_body, env_short_name)
    if not env_body:
        return {}

    result = {}

    for key in [
        "hub_subscription_id",
        "hub_virtual_network_id",
        "hub_virtual_network_name",
        "hub_virtual_network_parent_id",
        "hub_firewall_private_ip",
        "hub_gateway_route_table_resource_group_name",
        "hub_gateway_route_table_name",
    ]:
        match = re.search(rf'{key}\s*=\s*"([^"]+)"', env_body)
        if match:
            result[key] = match.group(1)

    dns_match = re.search(r"hub_dns_servers\s*=\s*\[(.*?)\]", env_body, re.DOTALL)
    if dns_match:
        result["hub_dns_servers"] = re.findall(r'"([^"]+)"', dns_match.group(1))

    return result


def has_network_test_target() -> bool:
    return bool(subscription_id and has_vnet and network_context)


with open(YAML_PATH, "r", encoding="utf-8") as f:
    config = yaml.safe_load(f)

SUBSCRIPTION_NAME = config["subscription_name"]
MANAGEMENT_GROUP_ID = config["management_group_id"]
ENV_SHORT_NAME = config["env_short_name"]
HUB_ENVIRONMENT = load_hub_environment(TFVARS_PATH, ENV_SHORT_NAME)
EXPECTED_ASSIGNEES = [x for x in config.get("rbac_assignments", []) if str(x).strip()]
EXPECTED_ENROLLMENT_ACCOUNT_DISPLAY_NAME = config["tags"]["cost_center"]

resource_groups = config.get("resource_groups", {})
alerts = config.get("alerts")
budget = config.get("budget")
virtual_network = config.get("virtual_network")
has_vnet = virtual_network is not None

network_context = {}

# =============================================================================
# サブスクリプション作成確認
# =============================================================================
try:
    subscriptions = run_az(["account", "list", "--all"])
    target = next((s for s in subscriptions if s.get("name") == SUBSCRIPTION_NAME), None)

    if target is None:
        add_result("サブスクリプション作成確認", False, SUBSCRIPTION_NAME, "未検出", "az account list に対象サブスクリプション名が存在しません")
    else:
        subscription_id = target["id"]
        actual = target.get("name", "")
        add_result("サブスクリプション作成確認", actual == SUBSCRIPTION_NAME, SUBSCRIPTION_NAME, actual, "期待値と実際値が一致しました" if actual == SUBSCRIPTION_NAME else "期待値と実際値が一致しません")
except Exception as e:
    add_result("サブスクリプション作成確認", False, SUBSCRIPTION_NAME, str(e), "サブスクリプション確認中にエラーが発生しました")

# =============================================================================
# 課金スコープ確認
# =============================================================================
try:
    if not subscription_id:
        add_result("課金スコープ確認", False, "課金スコープ確認可能", "subscription_id 未取得", "サブスクリプションが見つからないため確認できません")
    else:
        expected_enrollment_id = EXPECTED_ENROLLMENT_ACCOUNT_ID or None

        if not expected_enrollment_id:
            enrollment_accounts = arm_get(
                f"https://management.azure.com/providers/Microsoft.Billing/billingAccounts/{BILLING_ACCOUNT_ID}/enrollmentAccounts?api-version=2024-04-01"
            )
            for x in enrollment_accounts.get("value", []):
                props = x.get("properties", {})
                if props.get("displayName") == EXPECTED_ENROLLMENT_ACCOUNT_DISPLAY_NAME or props.get("departmentDisplayName") == EXPECTED_ENROLLMENT_ACCOUNT_DISPLAY_NAME:
                    expected_enrollment_id = x.get("name")
                    break

        if not expected_enrollment_id:
            add_result("課金スコープ確認", False, EXPECTED_ENROLLMENT_ACCOUNT_DISPLAY_NAME, "未解決", "期待する enrollment account が見つかりません")
        else:
            matched = None
            next_url = f"https://management.azure.com/providers/Microsoft.Billing/billingAccounts/{BILLING_ACCOUNT_ID}/billingSubscriptions?api-version=2024-04-01"

            while next_url:
                data = arm_get(next_url)
                for x in data.get("value", []):
                    props = x.get("properties", {})
                    if (props.get("subscriptionId") or "").lower() == subscription_id.lower():
                        matched = x
                        break
                if matched:
                    break
                next_url = data.get("nextLink")

            expected = f"enrollmentAccountId={expected_enrollment_id}, subscriptionName={SUBSCRIPTION_NAME}"
            if matched:
                props = matched.get("properties", {})
                actual = f"enrollmentAccountId={props.get('enrollmentAccountId', '')}, subscriptionName={props.get('displayName', '')}"
                ok = str(props.get("enrollmentAccountId", "")) == str(expected_enrollment_id)
                reason = "期待値と実際値が一致しました" if ok else "期待する Enrollment Account 配下ではありません"
            else:
                actual = "未検出"
                ok = False
                reason = "対象サブスクリプションが billingSubscriptions 一覧に見つかりません"

            add_result("課金スコープ確認", ok, expected, actual, reason)
except Exception as e:
    add_result("課金スコープ確認", False, EXPECTED_ENROLLMENT_ACCOUNT_DISPLAY_NAME, str(e), "課金スコープ確認中にエラーが発生しました")

# =============================================================================
# 管理グループ紐付け確認
# =============================================================================
try:
    if not subscription_id:
        add_result("管理グループ紐付け確認", False, True, False, "サブスクリプションが見つからないため確認できません")
    else:
        run_az(["account", "management-group", "subscription", "show", "--name", MANAGEMENT_GROUP_ID, "--subscription", subscription_id])
        add_result("管理グループ紐付け確認", True, True, True, f"サブスクリプションが管理グループ {MANAGEMENT_GROUP_ID} 配下に存在しました")
except Exception as e:
    add_result("管理グループ紐付け確認", False, True, False, f"サブスクリプションが管理グループ {MANAGEMENT_GROUP_ID} 配下に存在しません: {e}")

# =============================================================================
# RBAC 確認
# =============================================================================
try:
    if not subscription_id:
        add_result("RBAC確認", False, ", ".join(EXPECTED_ASSIGNEES), "subscription_id 未取得", "サブスクリプションが見つからないため確認できません")
    else:
        assignments = run_az(["role", "assignment", "list", "--scope", f"/subscriptions/{subscription_id}"])
        expected_list = [f"{x} ({EXPECTED_ROLE})" for x in EXPECTED_ASSIGNEES]
        actual_list = []

        for assignee in EXPECTED_ASSIGNEES:
            for a in assignments:
                principal_name = a.get("principalName") or ""
                role_name = a.get("roleDefinitionName") or ""
                if principal_name.lower() == assignee.lower() and role_name == EXPECTED_ROLE:
                    actual_list.append(f"{principal_name} ({role_name})")
                    break

        expected = ", ".join(sorted(expected_list))
        actual = ", ".join(sorted(actual_list)) if actual_list else "一致なし"
        add_result("RBAC確認", actual == expected, expected, actual, "期待値と実際値が一致しました" if actual == expected else "期待するRBACが不足しています")
except Exception as e:
    add_result("RBAC確認", False, ", ".join(EXPECTED_ASSIGNEES), str(e), "RBAC確認中にエラーが発生しました")

# =============================================================================
# Resource Group 確認
# =============================================================================
try:
    if not subscription_id:
        add_result("Resource Group確認", False, "RG確認可能", "subscription_id 未取得", "サブスクリプションが見つからないため確認できません")
    else:
        expected_rgs = [resource_groups["network"]["name"], resource_groups["alert"]["name"]]
        existing_rgs = run_az(["group", "list", "--subscription", subscription_id])
        existing_names = {x.get("name") for x in existing_rgs}
        missing = [rg for rg in expected_rgs if rg not in existing_names]
        add_result(
            "Resource Group確認",
            len(missing) == 0,
            ", ".join(expected_rgs),
            ", ".join(sorted(existing_names & set(expected_rgs))) if not missing else f"不足: {', '.join(missing)}",
            "期待する Resource Group が存在しました" if not missing else "期待する Resource Group が不足しています",
        )
except Exception as e:
    add_result("Resource Group確認", False, "network / alert RG", str(e), "Resource Group確認中にエラーが発生しました")

# =============================================================================
# Health Alert 確認
# =============================================================================
try:
    if not subscription_id or not alerts:
        add_result("Health Alert確認", True, "alerts 未指定時はスキップ", "スキップ", "alerts がないため確認対象外です")
    else:
        alert_rg = alerts["resource_group_name"]
        action_group_id = arm_id(subscription_id, alert_rg, f"Microsoft.Insights/actionGroups/{alerts['action_group_name']}")
        action_group = arm_get(arm_url(action_group_id, "2023-01-01"))
        receivers = action_group.get("properties", {}).get("emailReceivers", [])
        actual_emails = sorted([x.get("emailAddress") for x in receivers])
        expected_emails = sorted([x.get("email_address") for x in alerts.get("contacts", [])])

        add_result("Action Group確認", actual_emails == expected_emails, ", ".join(expected_emails), ", ".join(actual_emails), "期待するメール通知先が設定されています" if actual_emails == expected_emails else "Action Group のメール通知先が一致しません")

        service_health_id = arm_id(subscription_id, alert_rg, f"Microsoft.Insights/activityLogAlerts/{alerts['service_health_alert_name']}")
        service_health = arm_get(arm_url(service_health_id, "2020-10-01"))
        props = service_health.get("properties", {})
        scopes = props.get("scopes", [])
        action_groups = props.get("actions", {}).get("actionGroups", [])
        actual_ag_ids = [x.get("actionGroupId", "") for x in action_groups]
        actual_ag_names = [x.split("/")[-1] for x in actual_ag_ids]

        ok = props.get("enabled") is True and f"/subscriptions/{subscription_id}" in scopes and alerts["action_group_name"] in actual_ag_names
        add_result(
            "Service Health Alert確認",
            ok,
            f"enabled=True, scope=/subscriptions/{subscription_id}, actionGroup={alerts['action_group_name']}",
            f"enabled={props.get('enabled')}, scope=/subscriptions/{subscription_id}, actionGroup={', '.join(actual_ag_names)}",
            "Service Health Alert が期待通り設定されています" if ok else "Service Health Alert の設定が期待値と一致しません",
        )
except Exception as e:
    add_result("Health Alert確認", False, "Action Group / Service Health Alert", str(e), "Health Alert確認中にエラーが発生しました")

# =============================================================================
# Budget 確認
# =============================================================================
try:
    if not subscription_id or not budget or not budget.get("enabled", False):
        add_result("Budget確認", True, "budget 未指定または disabled 時はスキップ", "スキップ", "budget が無効なため確認対象外です")
    else:
        budgets = run_az(["consumption", "budget", "list", "--subscription", subscription_id])
        matched = next((b for b in budgets if b.get("name") == budget["name"]), None)

        if not matched:
            add_result("Budget確認", False, budget["name"], "未検出", "期待する Budget が見つかりません")
        else:
            amount = matched.get("amount")
            expected_amount = float(budget["amount"])
            actual_amount = float(amount)
            ok = actual_amount == expected_amount

            expected_amount_text = int(expected_amount) if expected_amount.is_integer() else expected_amount
            actual_amount_text = int(actual_amount) if actual_amount.is_integer() else actual_amount

            add_result(
                "Budget確認",
                ok,
                f"name={budget['name']}, amount={expected_amount_text}",
                f"name={matched.get('name')}, amount={actual_amount_text}",
                "Budget が期待通り設定されています" if ok else "Budget の金額が一致しません",
            )
except Exception as e:
    add_result("Budget確認", False, "Budget", str(e), "Budget確認中にエラーが発生しました")

# =============================================================================
# Network 確認用の共通情報作成
# =============================================================================
try:
    if subscription_id and has_vnet:
        vnet_rg = virtual_network["resource_group_name"]
        vnet_name = virtual_network["name"]
        expected_address_space = sorted(virtual_network.get("address_space", []))
        expected_subnet_cidrs = calculate_subnet_cidrs(expected_address_space[0], virtual_network.get("subnets", []))
        vnet_id = arm_id(subscription_id, vnet_rg, f"Microsoft.Network/virtualNetworks/{vnet_name}")

        network_context = {
            "vnet_rg": vnet_rg,
            "vnet_name": vnet_name,
            "vnet_id": vnet_id,
            "expected_address_space": expected_address_space,
            "expected_subnet_cidrs": expected_subnet_cidrs,
        }
except Exception as e:
    add_result("Network共通情報作成", False, "VNet確認用情報", str(e), "Network 確認用の共通情報作成中にエラーが発生しました")

# =============================================================================
# VNet 確認
# =============================================================================
try:
    if not has_network_test_target():
        add_result("VNet確認", True, "virtual_network 未指定時はスキップ", "スキップ", "virtual_network がない、または subscription_id 未取得のため確認対象外です")
    else:
        vnet = arm_get(arm_url(network_context["vnet_id"], "2024-01-01"))
        actual_address_space = sorted(vnet.get("properties", {}).get("addressSpace", {}).get("addressPrefixes", []))
        expected_address_space = network_context["expected_address_space"]

        add_result(
            "VNet確認",
            actual_address_space == expected_address_space,
            ", ".join(expected_address_space),
            ", ".join(actual_address_space),
            "VNet の address space が一致しました" if actual_address_space == expected_address_space else "VNet の address space が一致しません",
        )
except Exception as e:
    add_result("VNet確認", False, "VNet", str(e), "VNet確認中にエラーが発生しました")

# =============================================================================
# NSG 確認
# =============================================================================
try:
    if not has_network_test_target():
        add_result("NSG確認", True, "virtual_network 未指定時はスキップ", "スキップ", "virtual_network がない、または subscription_id 未取得のため確認対象外です")
    else:
        checked = False
        for subnet in virtual_network.get("subnets", []):
            nsg_name = subnet.get("network_security_group_name")
            if not nsg_name:
                continue

            checked = True
            nsg_id = arm_id(subscription_id, network_context["vnet_rg"], f"Microsoft.Network/networkSecurityGroups/{nsg_name}")
            nsg = arm_get(arm_url(nsg_id, "2024-01-01"))
            add_result(
                f"NSG確認({nsg_name})",
                nsg.get("name") == nsg_name,
                nsg_name,
                nsg.get("name"),
                "NSG が存在しました" if nsg.get("name") == nsg_name else "NSG が見つかりません",
            )

        if not checked:
            add_result("NSG確認", True, "NSG 指定なし", "スキップ", "network_security_group_name が指定された subnet がないため確認対象外です")
except Exception as e:
    add_result("NSG確認", False, "NSG", str(e), "NSG確認中にエラーが発生しました")

# =============================================================================
# Route Table 確認
# =============================================================================
try:
    if not has_network_test_target():
        add_result("Route Table確認", True, "virtual_network 未指定時はスキップ", "スキップ", "virtual_network がない、または subscription_id 未取得のため確認対象外です")
    else:
        checked = False
        for subnet in virtual_network.get("subnets", []):
            rt_name = subnet.get("route_table_name")
            if not rt_name:
                continue

            # パターン⑤では AzureFirewallSubnet がなく、ApplicationGatewaySubnet 用 RT は作成しない
            if subnet["name"] == "ApplicationGatewaySubnet" and get_subnet(config, "AzureFirewallSubnet") is None:
                continue

            checked = True
            rt_id = arm_id(subscription_id, network_context["vnet_rg"], f"Microsoft.Network/routeTables/{rt_name}")
            rt = arm_get(arm_url(rt_id, "2024-01-01"))
            add_result(
                f"Route Table確認({rt_name})",
                rt.get("name") == rt_name,
                rt_name,
                rt.get("name"),
                "Route Table が存在しました" if rt.get("name") == rt_name else "Route Table が見つかりません",
            )

        if not checked:
            add_result("Route Table確認", True, "Route Table 確認対象なし", "スキップ", "route_table_name が指定された確認対象 subnet がないため確認対象外です")
except Exception as e:
    add_result("Route Table確認", False, "Route Table", str(e), "Route Table確認中にエラーが発生しました")

# =============================================================================
# Subnet 確認
# =============================================================================
try:
    if not has_network_test_target():
        add_result("Subnet確認", True, "virtual_network 未指定時はスキップ", "スキップ", "virtual_network がない、または subscription_id 未取得のため確認対象外です")
    else:
        for subnet in virtual_network.get("subnets", []):
            subnet_name = subnet["name"]
            subnet_id = f"{network_context['vnet_id']}/subnets/{subnet_name}"
            actual_subnet = arm_get(arm_url(subnet_id, "2024-01-01"))
            props = actual_subnet.get("properties", {})

            expected_cidr = network_context["expected_subnet_cidrs"][subnet_name]
            actual_cidr = props.get("addressPrefix")

            checks = [actual_cidr == expected_cidr]
            expected_parts = [f"addressPrefix={expected_cidr}"]
            actual_parts = [f"addressPrefix={actual_cidr}"]

            expected_nsg = subnet.get("network_security_group_name")
            if expected_nsg:
                actual_nsg_id = props.get("networkSecurityGroup", {}).get("id", "")
                actual_nsg_name = actual_nsg_id.split("/")[-1] if actual_nsg_id else ""
                checks.append(actual_nsg_name.lower() == expected_nsg.lower())
                expected_parts.append(f"nsg={expected_nsg}")
                actual_parts.append(f"nsg={actual_nsg_name}")

            expected_rt = subnet.get("route_table_name")
            if expected_rt:
                actual_rt_id = props.get("routeTable", {}).get("id", "")
                actual_rt_name = actual_rt_id.split("/")[-1] if actual_rt_id else ""

                if subnet_name == "ApplicationGatewaySubnet" and get_subnet(config, "AzureFirewallSubnet") is None:
                    checks.append(actual_rt_id == "")
                    expected_parts.append("routeTable=なし")
                    actual_parts.append("routeTable=なし" if actual_rt_id == "" else f"routeTable={actual_rt_name}")
                else:
                    checks.append(actual_rt_name.lower() == expected_rt.lower())
                    expected_parts.append(f"routeTable={expected_rt}")
                    actual_parts.append(f"routeTable={actual_rt_name}")

            ok = all(checks)
            add_result(
                f"Subnet確認({subnet_name})",
                ok,
                ", ".join(expected_parts),
                ", ".join(actual_parts),
                "Subnet が期待通り設定されています" if ok else "Subnet の設定が期待値と一致しません",
            )
except Exception as e:
    add_result("Subnet確認", False, "Subnet", str(e), "Subnet確認中にエラーが発生しました")

# =============================================================================
# Spoke -> Hub Peering 確認
# =============================================================================
try:
    if not has_network_test_target() or not virtual_network.get("hub_peering_enabled", False):
        add_result("Spoke -> Hub Peering確認", True, "peering 未指定時はスキップ", "スキップ", "peering が無効、または virtual_network がないため確認対象外です")
    else:
        spoke_peering_name = virtual_network.get("spoke_to_hub_peering_name")
        expected_hub_vnet_id = HUB_ENVIRONMENT.get("hub_virtual_network_id", "")

        if not spoke_peering_name:
            add_result("Spoke -> Hub Peering確認", False, "spoke_to_hub_peering_name", "未指定", "YAML に spoke_to_hub_peering_name がありません")
        elif not expected_hub_vnet_id:
            add_result("Spoke -> Hub Peering確認", False, "hub_virtual_network_id", "未取得", f"terraform.tfvars から env_short_name={ENV_SHORT_NAME} の hub_virtual_network_id を取得できません")
        else:
            spoke_peering_id = f"{network_context['vnet_id']}/virtualNetworkPeerings/{spoke_peering_name}"
            spoke_peering = arm_get(arm_url(spoke_peering_id, "2024-01-01"))
            props = spoke_peering.get("properties", {})
            actual_remote_id = props.get("remoteVirtualNetwork", {}).get("id", "")

            ok = (
                spoke_peering.get("name") == spoke_peering_name
                and actual_remote_id.lower() == expected_hub_vnet_id.lower()
                and props.get("allowForwardedTraffic") == virtual_network.get("use_hub_gateway", False)
                and props.get("allowVirtualNetworkAccess") is True
                and props.get("useRemoteGateways") == virtual_network.get("use_hub_gateway", False)
            )
            add_result(
                "Spoke -> Hub Peering確認",
                ok,
                f"name={spoke_peering_name}, remote={expected_hub_vnet_id}, allowForwardedTraffic={virtual_network.get('use_hub_gateway', False)}, allowVirtualNetworkAccess=True, useRemoteGateways={virtual_network.get('use_hub_gateway', False)}",
                f"name={spoke_peering.get('name')}, remote={actual_remote_id}, allowForwardedTraffic={props.get('allowForwardedTraffic')}, allowVirtualNetworkAccess={props.get('allowVirtualNetworkAccess')}, useRemoteGateways={props.get('useRemoteGateways')}",
                "Spoke -> Hub Peering が期待通り設定されています" if ok else "Spoke -> Hub Peering の設定が期待値と一致しません",
            )
except Exception as e:
    add_result("Spoke -> Hub Peering確認", False, "Spoke -> Hub Peering", str(e), "Spoke -> Hub Peering確認中にエラーが発生しました")

# =============================================================================
# Hub -> Spoke Peering 確認
# =============================================================================
try:
    if not has_network_test_target() or not virtual_network.get("hub_peering_enabled", False):
        add_result("Hub -> Spoke Peering確認", True, "peering 未指定時はスキップ", "スキップ", "peering が無効、または virtual_network がないため確認対象外です")
    else:
        hub_peering_name = virtual_network.get("hub_to_spoke_peering_name")
        hub_vnet_id = HUB_ENVIRONMENT.get("hub_virtual_network_id", "")
        use_hub_gateway = virtual_network.get("use_hub_gateway", False)

        if not hub_peering_name:
            add_result("Hub -> Spoke Peering確認", False, "hub_to_spoke_peering_name", "未指定", "YAML に hub_to_spoke_peering_name がありません")
        elif not hub_vnet_id:
            add_result("Hub -> Spoke Peering確認", False, "hub_virtual_network_id", "未取得", f"terraform.tfvars から env_short_name={ENV_SHORT_NAME} の hub_virtual_network_id を取得できません")
        else:
            hub_peering_id = f"{hub_vnet_id}/virtualNetworkPeerings/{hub_peering_name}"
            hub_peering = arm_get(arm_url(hub_peering_id, "2024-01-01"))
            props = hub_peering.get("properties", {})
            actual_remote_id = props.get("remoteVirtualNetwork", {}).get("id", "")

            ok = (
                hub_peering.get("name") == hub_peering_name
                and actual_remote_id.lower() == network_context["vnet_id"].lower()
                and props.get("allowForwardedTraffic") == use_hub_gateway
                and props.get("allowVirtualNetworkAccess") is True
                and props.get("allowGatewayTransit") == use_hub_gateway
            )
            add_result(
                "Hub -> Spoke Peering確認",
                ok,
                f"name={hub_peering_name}, remote={network_context['vnet_id']}, allowForwardedTraffic={use_hub_gateway}, allowVirtualNetworkAccess=True, allowGatewayTransit={use_hub_gateway}",
                f"name={hub_peering.get('name')}, remote={actual_remote_id}, allowForwardedTraffic={props.get('allowForwardedTraffic')}, allowVirtualNetworkAccess={props.get('allowVirtualNetworkAccess')}, allowGatewayTransit={props.get('allowGatewayTransit')}",
                "Hub -> Spoke Peering が期待通り設定されています" if ok else "Hub -> Spoke Peering の設定が期待値と一致しません",
            )
except Exception as e:
    add_result("Hub -> Spoke Peering確認", False, "Hub -> Spoke Peering", str(e), "Hub -> Spoke Peering確認中にエラーが発生しました")

print("=== 払い出し自動テスト結果 ===")
for r in results:
    status = "OK" if r["ok"] else "NG"
    print(f"[{status}] {r['name']}")
    print(f"  期待値: {r['expected']}")
    print(f"  実際値: {r['actual']}")
    print(f"  理由  : {r['reason']}")

sys.exit(1 if failed else 0)
