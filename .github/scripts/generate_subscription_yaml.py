#!/usr/bin/env python3
"""
Jira 申請情報から Terraform 用の subscriptions/*.yaml を生成するスクリプト。

このスクリプトの責務:
- GitHub Actions の workflow_dispatch input を環境変数から受け取る
- 会社名、会社コード、環境コードなどを導出する
- Terraform で作成する Azure リソース名を生成する
- subscriptions/<subscription_name>.yaml を生成する
- PR 本文などで使う値を GITHUB_OUTPUT に出力する
"""

import os
import re
from pathlib import Path
from typing import Any

import yaml


# =============================================================================
# Utility functions
# =============================================================================


def get_env(name: str, default: str = "") -> str:
    """環境変数を取得する。未定義の場合は default を返す。"""
    return os.environ.get(name, default)


def parse_billing_company(raw_company: str) -> tuple[str, str]:
    """
    Jira から受け取った請求先会社文字列から会社名と会社コードを抽出する。

    入力例:
      パーソルホールディングス株式会社（PHD）

    出力:
      billing_company_name = パーソルホールディングス株式会社
      billing_company_code = PHD
    """
    billing_company_name = re.sub(r"（[^）]+）$", "", raw_company)

    match = re.match(r"^.*（([^）]+)）$", raw_company)
    billing_company_code = match.group(1) if match else raw_company

    return billing_company_name, billing_company_code


def derive_environment(environment_raw: str) -> tuple[str, str]:
    """
    Jira の環境名から Terraform / Azure 用の環境コードと管理グループIDを導出する。
    """
    environment_map = {
        "本番環境": ("prod", "Producrion"),
        "検証環境": ("stg", "Staging"),
        "開発環境": ("dev", "Sandbox"),
    }

    return environment_map.get(environment_raw, (environment_raw, environment_raw))


def to_bool(value: str) -> bool:
    """
    Jira から受け取った予算アラート利用有無を YAML 用の boolean に変換する。

    true 扱い:
      はい, true, True, TRUE, yes, Yes, YES

    それ以外は false 扱い。
    """
    return value in ["はい", "true", "True", "TRUE", "yes", "Yes", "YES"]


def unique_non_empty(values: list[str]) -> list[str]:
    """
    空文字を除外し、重複を排除したリストを返す。

    rbac_assignments で owner と admin が同じ場合に重複登録しないために使う。
    """
    result: list[str] = []
    seen: set[str] = set()

    for value in values:
        normalized = value.strip()
        if normalized and normalized not in seen:
            result.append(normalized)
            seen.add(normalized)

    return result


def write_github_outputs(outputs: dict[str, str]) -> None:
    """
    GitHub Actions の後続 step から参照できるように GITHUB_OUTPUT へ値を書き出す。

    例:
      steps.vars.outputs.subscription_name
    """
    github_output = os.environ.get("GITHUB_OUTPUT")
    if not github_output:
        return

    with open(github_output, "a", encoding="utf-8") as f:
        for key, value in outputs.items():
            f.write(f"{key}={value}\n")


# =============================================================================
# YAML model builders
# =============================================================================


def build_virtual_network(
    configuration_pattern: str,
    vnet_name: str,
    rg_network_name: str,
    use_hub_gateway: bool,
    spoke_to_hub_peering_name: str,
    hub_to_spoke_peering_name: str,
    rt_agw_name: str,
    rt_private_name: str,
    rt_protect_name: str,
    nsg_private_name: str,
    nsg_protect_name: str,
) -> dict[str, Any] | None:
    """
    構成パターンに応じて virtual_network セクションを生成する。

    パターン①:
      VNet なし

    パターン②:
      AppGW + AzureFirewallSubnet + PrivateSubnet + ProtectSubnet

    パターン③:
      AppGW + AzureFirewallSubnet + PrivateSubnet

    パターン④:
      カスタム CIDR 構成

    パターン⑤:
      AppGW + PrivateSubnet + ProtectSubnet
    """
    base = {
        "name": vnet_name,
        "resource_group_name": rg_network_name,
        "hub_peering_enabled": True,
        "use_hub_gateway": use_hub_gateway,
        "spoke_to_hub_peering_name": spoke_to_hub_peering_name,
        "hub_to_spoke_peering_name": hub_to_spoke_peering_name,
    }

    if "パターン①" in configuration_pattern:
        return None

    if "パターン②" in configuration_pattern:
        return {
            **base,
            "address_space": ["/23"],
            "subnets": [
                {
                    "name": "ApplicationGatewaySubnet",
                    "address_prefix": "/24",
                    "route_table_name": rt_agw_name,
                },
                {
                    "name": "AzureFirewallSubnet",
                    "address_prefix": "/26",
                },
                {
                    "name": "PrivateSubnet",
                    "address_prefix": "/26",
                    "route_table_name": rt_private_name,
                    "network_security_group_name": nsg_private_name,
                },
                {
                    "name": "ProtectSubnet",
                    "address_prefix": "/27",
                    "route_table_name": rt_protect_name,
                    "network_security_group_name": nsg_protect_name,
                },
            ],
        }

    if "パターン③" in configuration_pattern:
        return {
            **base,
            "address_space": ["/23"],
            "subnets": [
                {
                    "name": "ApplicationGatewaySubnet",
                    "address_prefix": "/24",
                    "route_table_name": rt_agw_name,
                },
                {
                    "name": "AzureFirewallSubnet",
                    "address_prefix": "/26",
                },
                {
                    "name": "PrivateSubnet",
                    "address_prefix": "/26",
                    "route_table_name": rt_private_name,
                    "network_security_group_name": nsg_private_name,
                },
            ],
        }

    if "パターン④" in configuration_pattern:
        return {
            **base,
            "address_space": [get_env("CUSTOM_VNET_CIDR")],
            "subnets": [
                {
                    "name": "ApplicationGatewaySubnet",
                    "address_prefix": get_env("CUSTOM_APPGW_SUBNET_CIDR"),
                    "route_table_name": rt_agw_name,
                },
                {
                    "name": "AzureFirewallSubnet",
                    "address_prefix": "/26",
                },
                {
                    "name": "PrivateSubnet",
                    "address_prefix": get_env("CUSTOM_PRIVATE_SUBNET_CIDR"),
                    "route_table_name": rt_private_name,
                    "network_security_group_name": nsg_private_name,
                },
                {
                    "name": "ProtectSubnet",
                    "address_prefix": get_env("CUSTOM_PROTECT_SUBNET_CIDR"),
                    "route_table_name": rt_protect_name,
                    "network_security_group_name": nsg_protect_name,
                },
            ],
        }

    if "パターン⑤" in configuration_pattern:
        return {
            **base,
            "address_space": ["/23"],
            "subnets": [
                {
                    "name": "ApplicationGatewaySubnet",
                    "address_prefix": "/24",
                    "route_table_name": rt_agw_name,
                },
                {
                    "name": "PrivateSubnet",
                    "address_prefix": "/26",
                    "route_table_name": rt_private_name,
                    "network_security_group_name": nsg_private_name,
                },
                {
                    "name": "ProtectSubnet",
                    "address_prefix": "/27",
                    "route_table_name": rt_protect_name,
                    "network_security_group_name": nsg_protect_name,
                },
            ],
        }

    return None


# =============================================================================
# Main process
# =============================================================================


def main() -> None:
    # -------------------------------------------------------------------------
    # GitHub Actions から渡された Jira 申請情報を取得する
    # -------------------------------------------------------------------------
    jira_issue_key = get_env("JIRA_ISSUE_KEY")
    request_type = get_env("REQUEST_TYPE")
    subscription_owner_email = get_env("SUBSCRIPTION_OWNER_EMAIL")
    subscription_admin_email = get_env("SUBSCRIPTION_ADMIN_EMAIL")
    notification_email_1 = get_env("NOTIFICATION_EMAIL_1")
    notification_email_2 = get_env("NOTIFICATION_EMAIL_2")
    budget = get_env("BUDGET")
    budget_alert_enabled_raw = get_env("BUDGET_ALERT_ENABLED")
    billing_company_raw = get_env("BILLING_COMPANY")
    environment_raw = get_env("ENVIRONMENT")
    configuration_pattern = get_env("CONFIGURATION_PATTERN")
    service_name = get_env("SERVICE_NAME")
    service_short_name = get_env("SERVICE_SHORT_NAME")

    # -------------------------------------------------------------------------
    # 入力値から派生値を生成する
    # -------------------------------------------------------------------------
    billing_company_name, billing_company_code = parse_billing_company(billing_company_raw)
    env_code, management_group_id = derive_environment(environment_raw)

    # dev 環境では Hub Gateway を使わない
    use_hub_gateway = env_code != "dev"

    # YAML の budget.enabled は boolean にする
    budget_alert_enabled = to_bool(budget_alert_enabled_raw)

    # -------------------------------------------------------------------------
    # Terraform で作成する Azure リソース名を生成する
    # -------------------------------------------------------------------------
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

    # -------------------------------------------------------------------------
    # Terraform が利用する YAML データを組み立てる
    # subscription_request 以外は Terraform が使う値を中心に出力する
    # -------------------------------------------------------------------------
    data: dict[str, Any] = {
        "subscription_name": subscription_name,
        "workload_type": "Production",
        "management_group_id": management_group_id,
        "location": "japaneast",
        "env_short_name": env_code,
        "tags": {
            "environment": env_code,
            "cost_center": billing_company_name,
            "owner": subscription_owner_email,
            "deployed_by": "Terraform",
        },
        "rbac_assignments": unique_non_empty(
            [
                subscription_owner_email,
                subscription_admin_email,
            ]
        ),
        "resource_groups": {
            "network": {
                "name": rg_network_name,
                "location": "japaneast",
            },
            "alert": {
                "name": rg_alert_name,
                "location": "japaneast",
            },
        },
        "alerts": {
            "resource_group_name": rg_alert_name,
            "action_group_name": action_group_name,
            "service_health_alert_name": service_health_alert_name,
            "group_short_name": action_group_short_name,
            "contacts": [
                {
                    "name": "subscription-owner",
                    "email_address": notification_email_1,
                },
                {
                    "name": "subscription-owner2",
                    "email_address": notification_email_2,
                },
            ],
        },
        "budget": {
            "enabled": budget_alert_enabled,
            "name": budget_name,
            "amount": int(budget),
            "threshold": 80,
            "contact_emails": [
                notification_email_1,
                notification_email_2,
            ],
        },
    }

    # -------------------------------------------------------------------------
    # 構成パターンに応じて virtual_network セクションを追加する
    # パターン①の場合は virtual_network 自体を出力しない
    # -------------------------------------------------------------------------
    virtual_network = build_virtual_network(
        configuration_pattern=configuration_pattern,
        vnet_name=vnet_name,
        rg_network_name=rg_network_name,
        use_hub_gateway=use_hub_gateway,
        spoke_to_hub_peering_name=spoke_to_hub_peering_name,
        hub_to_spoke_peering_name=hub_to_spoke_peering_name,
        rt_agw_name=rt_agw_name,
        rt_private_name=rt_private_name,
        rt_protect_name=rt_protect_name,
        nsg_private_name=nsg_private_name,
        nsg_protect_name=nsg_protect_name,
    )

    if virtual_network is not None:
        data["virtual_network"] = virtual_network

    # -------------------------------------------------------------------------
    # subscription_request は Jira 申請情報を原文のまま保持する監査用領域
    # Terraform が直接使う値というより、申請内容の追跡用
    # -------------------------------------------------------------------------
    data["subscription_request"] = {
        "jira_issue_key": jira_issue_key,
        "request_type": request_type,
        "subscription_owner_email": subscription_owner_email,
        "subscription_admin_email": subscription_admin_email,
        "notification_email_1": notification_email_1,
        "notification_email_2": notification_email_2,
        "budget": budget,
        "budget_alert_enabled": budget_alert_enabled_raw,
        "billing_company_raw": billing_company_raw,
        "environment_raw": environment_raw,
        "configuration_pattern": configuration_pattern,
        "custom_vnet_cidr": get_env("CUSTOM_VNET_CIDR"),
        "custom_private_subnet_cidr": get_env("CUSTOM_PRIVATE_SUBNET_CIDR"),
        "custom_protect_subnet_cidr": get_env("CUSTOM_PROTECT_SUBNET_CIDR"),
        "custom_appgw_subnet_cidr": get_env("CUSTOM_APPGW_SUBNET_CIDR"),
        "service_name": service_name,
        "service_short_name": service_short_name,
    }

    # -------------------------------------------------------------------------
    # subscriptions/<subscription_name>.yaml を生成する
    # -------------------------------------------------------------------------
    output_dir = Path("subscriptions")
    output_dir.mkdir(parents=True, exist_ok=True)

    output_file = output_dir / file_name

    with output_file.open("w", encoding="utf-8") as f:
        yaml.safe_dump(
            data,
            f,
            allow_unicode=True,
            sort_keys=False,
            default_flow_style=False,
        )

    # -------------------------------------------------------------------------
    # PR 作成 step で使う値を GitHub Actions output に出す
    # -------------------------------------------------------------------------
    write_github_outputs(
        {
            "billing_company_name": billing_company_name,
            "billing_company_code": billing_company_code,
            "env_code": env_code,
            "management_group_id": management_group_id,
            "use_hub_gateway": str(use_hub_gateway).lower(),
            "budget_alert_enabled": str(budget_alert_enabled).lower(),
            "subscription_name": subscription_name,
            "file_name": file_name,
            "branch_name": branch_name,
            "rg_network_name": rg_network_name,
            "rg_alert_name": rg_alert_name,
            "vnet_name": vnet_name,
            "rt_agw_name": rt_agw_name,
            "rt_private_name": rt_private_name,
            "rt_protect_name": rt_protect_name,
            "nsg_private_name": nsg_private_name,
            "nsg_protect_name": nsg_protect_name,
            "action_group_short_name": action_group_short_name,
            "action_group_name": action_group_name,
            "service_health_alert_name": service_health_alert_name,
            "budget_name": budget_name,
            "spoke_to_hub_peering_name": spoke_to_hub_peering_name,
            "hub_to_spoke_peering_name": hub_to_spoke_peering_name,
        }
    )

    print(f"Generated: {output_file}")


if __name__ == "__main__":
    main()
