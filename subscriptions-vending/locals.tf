locals {
  # subscriptions 配下の YAML 一覧
  subscription_yaml_files = fileset(var.subscription_vending_path, "*.yaml")

  # YAML をそのまま map 化
  # key は YAML ファイル名から .yaml を除いた値
  subscriptions_raw = {
    for f in local.subscription_yaml_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${var.subscription_vending_path}/${f}"))
  }

  # 新規作成対象（subscription_id 未指定）
  subscriptions_to_create = {
    for k, v in local.subscriptions_raw : k => v
    if try(v.subscription_id, null) == null
  }

  # 既存サブスク（subscription_id 指定済み）
  subscriptions_with_ids = {
    for k, v in local.subscriptions_raw : k => v
    if try(v.subscription_id, null) != null
  }

  # サブネット CIDR を一度だけ計算する
  # key は subscription_key/subnet_name
  calculated_subnets = merge([
    for subscription_key, subscription in local.subscriptions_raw : {
      for idx, subnet in try(subscription.virtual_network.subnets, []) :
      "${subscription_key}/${subnet.name}" => {
        subscription_key            = subscription_key
        subnet_index                = idx
        name                        = subnet.name
        route_table_name            = try(subnet.route_table_name, null)
        network_security_group_name = try(subnet.network_security_group_name, null)

        effective_address_prefix = try(
          subnet.address_range,
          can(cidrhost(subnet.address_prefix, 0)) ? subnet.address_prefix : cidrsubnet(
            subscription.virtual_network.address_space[0],
            tonumber(replace(subnet.address_prefix, "/", "")) - tonumber(split("/", subscription.virtual_network.address_space[0])[1]),
            ceil(sum(concat([
              0
              ], [
              for prev in slice(try(subscription.virtual_network.subnets, []), 0, idx) :
              pow(
                2,
                tonumber(replace(subnet.address_prefix, "/", "")) - tonumber(replace(prev.address_prefix, "/", ""))
              )
            ])))
          )
        )
      }
    }
  ]...)

  # サブスクリプションごとに、サブネット名で計算済みサブネットを引けるようにする
  # 例: local.calculated_subnets_by_name["subscription_xxx"]["PrivateSubnet"]
  calculated_subnets_by_name = {
    for subscription_key in keys(local.subscriptions_raw) : subscription_key => {
      for subnet_key, subnet in local.calculated_subnets :
      subnet.name => subnet
      if subnet.subscription_key == subscription_key
    }
  }

  # YAML から Terraform で使う値を整理
  subscriptions = {
    for k, v in local.subscriptions_raw : k => {
      subscription_name   = v.subscription_name
      workload_type       = try(v.workload_type, "Production")
      management_group_id = v.management_group_id
      location            = v.location
      env_short_name      = v.env_short_name
      tags                = try(v.tags, {})

      # billing_scope_id は現在の課金スコープを固定で使用する
      billing_scope_id = "/providers/Microsoft.Billing/billingAccounts/6d92e1a7-44ef-5b9d-fe85-600e31fecd27:7ffb2b72-d71a-46c2-ac74-10566d437c9e_2019-05-31/billingProfiles/KXVV-QQVV-BG7-PGB/invoiceSections/b5316415-c236-41e7-8237-fcf186346a73"

      # Resource Group
      network_rg_name     = v.resource_groups.network.name
      network_rg_location = try(v.resource_groups.network.location, v.location)
      alert_rg_name       = v.resource_groups.alert.name
      alert_rg_location   = try(v.resource_groups.alert.location, v.location)

      # subscription_request は申請情報保持用だが、サービス略称は一部の fallback で使う
      service_name       = try(v.subscription_request.service_name, k)
      service_short_name = try(v.subscription_request.service_short_name, k)

      # RBAC
      rbac_assignments = [for x in try(v.rbac_assignments, []) : x if trimspace(x) != ""]

      # Alert / Budget は YAML の値をそのまま利用する
      alerts = try(v.alerts, null)
      budget = try(v.budget, null)

      # VNet
      vnet_name       = try(v.virtual_network.name, null)
      vnet_rg_name    = try(v.virtual_network.resource_group_name, null)
      address_space   = try(v.virtual_network.address_space, [])
      has_vnet        = try(v.virtual_network, null) != null
      has_peering     = try(v.virtual_network.hub_peering_enabled, false)
      use_hub_gateway = try(v.virtual_network.use_hub_gateway, false)

      # Peering / Gateway route 名は jira-dispatch 側で生成した値を使う
      spoke_to_hub_peering_name = try(v.virtual_network.spoke_to_hub_peering_name, null)
      hub_to_spoke_peering_name = try(v.virtual_network.hub_to_spoke_peering_name, null)
      gateway_route_name_prefix = try(v.virtual_network.gateway_route_name_prefix, null)

      # RT / NSG 名は YAML の subnet 定義から取得する
      rt_agw_name      = try(local.calculated_subnets_by_name[k]["ApplicationGatewaySubnet"].route_table_name, null)
      rt_private_name  = try(local.calculated_subnets_by_name[k]["PrivateSubnet"].route_table_name, null)
      rt_protect_name  = try(local.calculated_subnets_by_name[k]["ProtectSubnet"].route_table_name, null)
      nsg_private_name = try(local.calculated_subnets_by_name[k]["PrivateSubnet"].network_security_group_name, null)
      nsg_protect_name = try(local.calculated_subnets_by_name[k]["ProtectSubnet"].network_security_group_name, null)

      # 計算済みサブネット一覧
      subnets = [
        for subnet_key, subnet in local.calculated_subnets : subnet
        if subnet.subscription_key == k
      ]

      # 後続リソースで使う主要サブネット
      firewall_subnet = try(local.calculated_subnets_by_name[k]["AzureFirewallSubnet"], null)
      agw_subnet      = try(local.calculated_subnets_by_name[k]["ApplicationGatewaySubnet"], null)
      private_subnet  = try(local.calculated_subnets_by_name[k]["PrivateSubnet"], null)
      protect_subnet  = try(local.calculated_subnets_by_name[k]["ProtectSubnet"], null)

      # AzureFirewallSubnet の 4番目の IP を Spoke FW IP として使う
      spoke_fw_ip = try(cidrhost(local.calculated_subnets_by_name[k]["AzureFirewallSubnet"].effective_address_prefix, 4), null)

      # Hub 情報
      hub = var.hub_environments[v.env_short_name]
    }
  }

  # 新規作成後も含めた subscription_id の確定値
  resolved_subscription_ids = {
    for k, v in local.subscriptions_raw : k => (
      try(v.subscription_id, null) != null
      ? v.subscription_id
      : azurerm_subscription.vending[k].subscription_id
    )
  }

  # RBAC 付与用
  vending_with_rbac = {
    for k, v in local.subscriptions : k => {
      sub_id           = local.resolved_subscription_ids[k]
      rbac_assignments = v.rbac_assignments
    }
    if length(v.rbac_assignments) > 0
  }

  # RG 作成用
  vending_resource_groups = merge([
    for k, v in local.subscriptions : {
      "${k}/network" = {
        sub_key  = k
        sub_id   = local.resolved_subscription_ids[k]
        name     = v.network_rg_name
        location = v.network_rg_location
        tags     = v.tags
      }
      "${k}/alert" = {
        sub_key  = k
        sub_id   = local.resolved_subscription_ids[k]
        name     = v.alert_rg_name
        location = v.alert_rg_location
        tags     = v.tags
      }
    }
  ]...)

  # Health Alert 作成用
  vending_with_alerts = {
    for k, v in local.subscriptions : k => {
      sub_id            = local.resolved_subscription_ids[k]
      subscription_name = v.subscription_name
      location          = v.location
      alert_contacts    = try(v.alerts.contacts, [])
      short_name        = try(v.alerts.group_short_name, null)
      action_group_name = try(v.alerts.action_group_name, null)
      alert_name        = try(v.alerts.service_health_alert_name, null)
      tags              = v.tags
      rg_name           = v.alert_rg_name
      env_short_name    = v.env_short_name
    }
    if try(v.alerts, null) != null
    && try(v.alerts.action_group_name, null) != null
    && try(v.alerts.service_health_alert_name, null) != null
    && length(try(v.alerts.contacts, [])) > 0
  }

  # Budget Alert 作成用
  vending_with_budget = {
    for k, v in local.subscriptions : k => {
      sub_id         = local.resolved_subscription_ids[k]
      name           = try(v.budget.name, null)
      amount         = try(v.budget.amount, null)
      threshold      = try(v.budget.threshold, 80)
      contact_emails = try(v.budget.contact_emails, [])
      env_short_name = v.env_short_name
    }
    if try(v.budget.enabled, false)
    && try(v.budget.name, null) != null
    && try(v.budget.amount, null) != null
    && length(try(v.budget.contact_emails, [])) > 0
  }

  # VNet 作成用
  vending_with_vnet = {
    for k, v in local.subscriptions : k => v
    if v.has_vnet
  }

  # Subnet 作成用
  vending_subnets = merge([
    for k, v in local.subscriptions : {
      for subnet in v.subnets :
      "${k}/${subnet.name}" => {
        sub_key                     = k
        sub_id                      = local.resolved_subscription_ids[k]
        vnet_rg                     = v.vnet_rg_name
        name                        = subnet.name
        effective_address_prefix    = subnet.effective_address_prefix
        subnet_index                = subnet.subnet_index
        route_table_name            = subnet.route_table_name
        network_security_group_name = subnet.network_security_group_name
      }
    } if v.has_vnet
  ]...)

  # Peering 作成用
  vending_with_peering = {
    for k, v in local.subscriptions : k => v
    if v.has_vnet && v.has_peering
  }

  # Hub Gateway 側に追加する Spoke ルート
  # ルート名の prefix は jira-dispatch 側で生成した gateway_route_name_prefix を使う
  vending_spoke_routes = flatten([
    for k, v in local.subscriptions : [
      for i, cidr in v.address_space : {
        key            = "${k}-${i}"
        env_short_name = v.env_short_name
        name           = "${v.gateway_route_name_prefix}-${i}"
        address_prefix = cidr
      }
    ] if v.has_vnet && v.has_peering && v.gateway_route_name_prefix != null
  ])

  # PrivateSubnet 用 NSG 作成対象
  vending_nsg_private = {
    for k, v in local.subscriptions : k => v
    if v.private_subnet != null && v.nsg_private_name != null
  }

  # ProtectSubnet 用 NSG 作成対象
  vending_nsg_protect = {
    for k, v in local.subscriptions : k => v
    if v.protect_subnet != null && v.nsg_protect_name != null
  }

  # ApplicationGatewaySubnet 用 Route Table 作成対象
  vending_rt_agw = {
    for k, v in local.subscriptions : k => v
    if v.agw_subnet != null && v.private_subnet != null && v.spoke_fw_ip != null && v.rt_agw_name != null
  }

  # PrivateSubnet 用 Route Table 作成対象
  vending_rt_private = {
    for k, v in local.subscriptions : k => v
    if v.private_subnet != null && v.rt_private_name != null
  }

  # ProtectSubnet 用 Route Table 作成対象
  vending_rt_protect = {
    for k, v in local.subscriptions : k => v
    if v.protect_subnet != null && v.rt_protect_name != null
  }

  # ER なし環境では gateway route を作らない
  vending_spoke_routes_with_gateway = {
    for r in local.vending_spoke_routes : r.key => r
    if try(var.hub_environments[r.env_short_name].hub_gateway_route_table_resource_group_name, null) != null
    && try(var.hub_environments[r.env_short_name].hub_gateway_route_table_name, null) != null
  }
}
