#!/usr/bin/env python3
"""
Jira 申請情報から Terraform 用の yamlパラメーターファイルを生成するスクリプト。

このスクリプトの役割:
- GitHub Actions input を環境変数から受け取る
- 会社名、会社コード、環境コード、管理グループIDを導出する
- Terraform で作成する各種リソース名を生成する
- subscriptions/<subscription_name>.yaml を生成する
- PR 作成 step で使う値を GITHUB_OUTPUT に出力する
"""

import os
import re
from pathlib import Path


# =============================================================================
# 共通関数
# =============================================================================


def env(name: str) -> str:
    """環境変数を取得する。未定義の場合は空文字を返す。"""
    return os.environ.get(name, "")


def bool_string(value: str) -> str:
    """Jira から渡された値を YAML 用の true / false 文字列に変換する。"""
    return "true" if value in ["はい", "true", "True", "TRUE", "yes", "Yes", "YES"] else "false"


def unique_non_empty(values: list[str]) -> list[str]:
    """空文字を除外し、重複を排除したリストを返す。"""
    result = []

    for value in values:
        value = value.strip()
        if value and value not in result:
            result.append(value)

    return result


def write_output(key: str, value: str) -> None:
    """GitHub Actions の後続 step で参照できる output を出力する。"""
    github_output = os.environ.get("GITHUB_OUTPUT")
    if not github_output:
        return

    with open(github_output, "a", encoding="utf-8") as f:
        f.write(f"{key}={value}\n")


# =============================================================================
# 入力値の取得
# =============================================================================


jira_issue_key = env("JIRA_ISSUE_KEY")
request_type = env("REQUEST_TYPE")
subscription_owner_email = env("SUBSCRIPTION_OWNER_EMAIL")
subscription_admin_email = env("SUBSCRIPTION_ADMIN_EMAIL")
notification_email_1 = env("NOTIFICATION_EMAIL_1")
notification_email_2 = env("NOTIFICATION_EMAIL_2")
budget = env("BUDGET")
budget_alert_enabled_raw = env("BUDGET_ALERT_ENABLED")
billing_company_raw = env("BILLING_COMPANY")
environment_raw = env("ENVIRONMENT")
configuration_pattern = env("CONFIGURATION_PATTERN")
service_name = env("SERVICE_NAME")
service_short_name = env("SERVICE_SHORT_NAME")

custom_vnet_cidr = env("CUSTOM_VNET_CIDR")
custom_private_subnet_cidr = env("CUSTOM_PRIVATE_SUBNET_CIDR")
custom_protect_subnet_cidr = env("CUSTOM_PROTECT_SUBNET_CIDR")
custom_appgw_subnet_cidr = env("CUSTOM_APPGW_SUBNET_CIDR")


# =============================================================================
# 入力値から派生値を作成
# =============================================================================


# 請求先会社から会社名と会社コードを抽出する。
# 入力は パーソルホールディングス株式会社（PHD） を想定
billing_company_name = re.sub(r"（[^）]+）$", "", billing_company_raw)
match = re.match(r"^.*（([^）]+)）$", billing_company_raw)
billing_company_code = match.group(1) if match else billing_company_raw

# Jira の環境名を Terraform 用の値へ変換する。
if environment_raw == "本番環境":
    env_code = "prod"
    management_group_id = "Producrion"
elif environment_raw == "検証環境":
    env_code = "stg"
    management_group_id = "Staging"
elif environment_raw == "開発環境":
    env_code = "dev"
    management_group_id = "Sandbox"
else:
    env_code = environment_raw
    management_group_id = environment_raw

# dev 環境では Hub Gateway を使わない。
use_hub_gateway = "false" if env_code == "dev" else "true"

# YAML の budget.enabled は boolean として出力。
budget_alert_enabled = bool_string(budget_alert_enabled_raw)


# =============================================================================
# リソース名の生成
# =============================================================================


subscription_name = f"subscription_{env_code}_{billing_company_code}_{service_name}"
file_name = f"{subscription_name}.yaml"
branch_name = f"feature/{jira_issue_key}-subscription-request"

rg_network_name = f"rg-{service_short_name}-{env_code}-network-01"
rg_alert_name = f"rg-{service_short_name}-{env_code}-alert-01"
vnet_name = f"vnet-{service_short_name}-{env_code}-network-01"

rt_agw_name = f"rt-{service_short_name}-{env_code}-agw-01"
rt_private_name = f"rt-{service_short_name}-{env_code}-private-01"
rt_protect_name = f"rt-{service_short_name}-{env_code}-protect-01"

nsg_private_name = f"nsg-{service_short_name}-{env_code}-private-01"
nsg_protect_name = f"nsg-{service_short_name}-{env_code}-protect-01"

action_group_short_name = f"{service_short_name}{env_code}".replace("-", "")[:12]
action_group_name = f"ag-health-{service_short_name}-{env_code}-01"
service_health_alert_name = f"alr-health-{service_short_name}-{env_code}-01"
budget_name = f"budget-{env_code}-{billing_company_code}-{service_name}"

spoke_to_hub_peering_name = f"peer-{vnet_name}-to-hub"
hub_to_spoke_peering_name = f"peer-hub-to-{vnet_name}"


# =============================================================================
# YAML 本文の生成
# =============================================================================


# rbac_assignments は owner/admin の重複と空文字を除外する。
rbac_lines = "\n".join(
    [f'  - "{email}"' for email in unique_non_empty([subscription_owner_email, subscription_admin_email])]
)

# yamlの生成
yaml_text = f'''subscription_name: "{subscription_name}"
management_group_id: "{management_group_id}"
location: "japaneast"
env_short_name: "{env_code}"

tags:
  environment: "{env_code}"
  cost_center: "{billing_company_name}"
  owner: "{subscription_owner_email}"
  deployed_by: "Terraform"

rbac_assignments:
{rbac_lines}

resource_groups:
  network:
    name: "{rg_network_name}"
    location: "japaneast"
  alert:
    name: "{rg_alert_name}"
    location: "japaneast"

alerts:
  resource_group_name: "{rg_alert_name}"
  action_group_name: "{action_group_name}"
  service_health_alert_name: "{service_health_alert_name}"
  group_short_name: "{action_group_short_name}"
  contacts:
    - name: "subscription-owner"
      email_address: "{notification_email_1}"
    - name: "subscription-owner2"
      email_address: "{notification_email_2}"

budget:
  enabled: {budget_alert_enabled}
  name: "{budget_name}"
  amount: {budget}
  threshold: 80
  contact_emails:
    - "{notification_email_1}"
    - "{notification_email_2}"
'''

# パターンごとに生成する VNet のブロックを分岐。
# 構成パターン①は VNet なしなので virtual_network を出力しない。
if "パターン②" in configuration_pattern:
    yaml_text += f'''
virtual_network:
  name: "{vnet_name}"
  resource_group_name: "{rg_network_name}"
  address_space: ["/23"]
  hub_peering_enabled: true
  use_hub_gateway: {use_hub_gateway}
  spoke_to_hub_peering_name: "{spoke_to_hub_peering_name}"
  hub_to_spoke_peering_name: "{hub_to_spoke_peering_name}"
  subnets:
    - name: "ApplicationGatewaySubnet"
      address_prefix: "/24"
      route_table_name: "{rt_agw_name}"
    - name: "AzureFirewallSubnet"
      address_prefix: "/26"
    - name: "PrivateSubnet"
      address_prefix: "/26"
      route_table_name: "{rt_private_name}"
      network_security_group_name: "{nsg_private_name}"
    - name: "ProtectSubnet"
      address_prefix: "/27"
      route_table_name: "{rt_protect_name}"
      network_security_group_name: "{nsg_protect_name}"
'''

elif "パターン③" in configuration_pattern:
    yaml_text += f'''
virtual_network:
  name: "{vnet_name}"
  resource_group_name: "{rg_network_name}"
  address_space: ["/23"]
  hub_peering_enabled: true
  use_hub_gateway: {use_hub_gateway}
  spoke_to_hub_peering_name: "{spoke_to_hub_peering_name}"
  hub_to_spoke_peering_name: "{hub_to_spoke_peering_name}"
  subnets:
    - name: "ApplicationGatewaySubnet"
      address_prefix: "/24"
      route_table_name: "{rt_agw_name}"
    - name: "AzureFirewallSubnet"
      address_prefix: "/26"
    - name: "PrivateSubnet"
      address_prefix: "/26"
      route_table_name: "{rt_private_name}"
      network_security_group_name: "{nsg_private_name}"
'''

elif "パターン④" in configuration_pattern:
    yaml_text += f'''
virtual_network:
  name: "{vnet_name}"
  resource_group_name: "{rg_network_name}"
  address_space: ["{custom_vnet_cidr}"]
  hub_peering_enabled: true
  use_hub_gateway: {use_hub_gateway}
  spoke_to_hub_peering_name: "{spoke_to_hub_peering_name}"
  hub_to_spoke_peering_name: "{hub_to_spoke_peering_name}"
  subnets:
    - name: "ApplicationGatewaySubnet"
      address_prefix: "{custom_appgw_subnet_cidr}"
      route_table_name: "{rt_agw_name}"
    - name: "AzureFirewallSubnet"
      address_prefix: "/26"
    - name: "PrivateSubnet"
      address_prefix: "{custom_private_subnet_cidr}"
      route_table_name: "{rt_private_name}"
      network_security_group_name: "{nsg_private_name}"
    - name: "ProtectSubnet"
      address_prefix: "{custom_protect_subnet_cidr}"
      route_table_name: "{rt_protect_name}"
      network_security_group_name: "{nsg_protect_name}"
'''

elif "パターン⑤" in configuration_pattern:
    yaml_text += f'''
virtual_network:
  name: "{vnet_name}"
  resource_group_name: "{rg_network_name}"
  address_space: ["/23"]
  hub_peering_enabled: true
  use_hub_gateway: {use_hub_gateway}
  spoke_to_hub_peering_name: "{spoke_to_hub_peering_name}"
  hub_to_spoke_peering_name: "{hub_to_spoke_peering_name}"
  subnets:
    - name: "ApplicationGatewaySubnet"
      address_prefix: "/24"
      route_table_name: "{rt_agw_name}"
    - name: "PrivateSubnet"
      address_prefix: "/26"
      route_table_name: "{rt_private_name}"
      network_security_group_name: "{nsg_private_name}"
    - name: "ProtectSubnet"
      address_prefix: "/27"
      route_table_name: "{rt_protect_name}"
      network_security_group_name: "{nsg_protect_name}"
'''

# subscription_request は Jira 申請情報を保持する目的。
yaml_text += f'''
subscription_request:
  jira_issue_key: "{jira_issue_key}"
  request_type: "{request_type}"
  subscription_owner_email: "{subscription_owner_email}"
  subscription_admin_email: "{subscription_admin_email}"
  notification_email_1: "{notification_email_1}"
  notification_email_2: "{notification_email_2}"
  budget: "{budget}"
  budget_alert_enabled: "{budget_alert_enabled_raw}"
  billing_company_raw: "{billing_company_raw}"
  environment_raw: "{environment_raw}"
  configuration_pattern: "{configuration_pattern}"
  custom_vnet_cidr: "{custom_vnet_cidr}"
  custom_private_subnet_cidr: "{custom_private_subnet_cidr}"
  custom_protect_subnet_cidr: "{custom_protect_subnet_cidr}"
  custom_appgw_subnet_cidr: "{custom_appgw_subnet_cidr}"
  service_name: "{service_name}"
  service_short_name: "{service_short_name}"
'''


# =============================================================================
# YAML ファイルの出力
# =============================================================================


output_dir = Path("subscriptions")
output_dir.mkdir(parents=True, exist_ok=True)

output_file = output_dir / file_name
output_file.write_text(yaml_text, encoding="utf-8")


# =============================================================================
# GitHub Actions output の出力
# =============================================================================


outputs = {
    "subscription_name": subscription_name,
    "file_name": file_name,
    "branch_name": branch_name,
    "env_code": env_code,
    "management_group_id": management_group_id,
    "billing_company_name": billing_company_name,
    "billing_company_code": billing_company_code,
    "rg_network_name": rg_network_name,
    "rg_alert_name": rg_alert_name,
    "vnet_name": vnet_name,
}

for key, value in outputs.items():
    write_output(key, value)

print(f"Generated: {output_file}")
