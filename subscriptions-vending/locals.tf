locals {
  # subscriptions 配下の YAML 一覧
  subscription_yaml_files = fileset(var.subscription_vending_path, "*.yaml")

  # YAML をそのまま map 化
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

  # YAML から使う値を整理
  subscriptions = {
    for k, v in local.subscriptions_raw : k => {
      subscription_name     = v.subscription_name
      workload_type         = try(v.workload_type, "Production")
      management_group_id   = v.management_group_id
      location              = v.location
      env_short_name        = v.env_short_name
      tags                  = try(v.tags, {})
      budget                = try(tonumber(v.budget), null)
      enrollment_account_id = var.enrollment_account_id_map[v.tags.cost_center]
      billing_scope_id      = "/providers/Microsoft.Billing/billingAccounts/6d92e1a7-44ef-5b9d-fe85-600e31fecd27:7ffb2b72-d71a-46c2-ac74-10566d437c9e_2019-05-31/billingProfiles/KXVV-QQVV-BG7-PGB/invoiceSections/b5316415-c236-41e7-8237-fcf186346a73"

      network_rg_name     = v.resource_groups.network.name
      network_rg_location = try(v.resource_groups.network.location, v.location)
      alert_rg_name       = v.resource_groups.application.name
      alert_rg_location   = try(v.resource_groups.application.location, v.location)

      service_name       = try(v.subscription_request.service_name, k)
      service_short_name = try(v.subscription_request.service_short_name, k)

      alert_contacts   = try(v.alert_contacts, [])
      rbac_assignments = [for x in try(v.rbac_assignments, []) : x if trimspace(x) != ""]

      vnet_name       = try(v.virtual_network.name, null)
      vnet_rg_name    = try(v.virtual_network.resource_group_name, null)
      address_space   = try(v.virtual_network.address_space, [])
      has_vnet        = try(v.virtual_network, null) != null
      has_peering     = try(v.virtual_network.hub_peering_enabled, false)
      use_hub_gateway = try(v.virtual_network.use_hub_gateway, false)

      use_ipam = (
        try(v.virtual_network, null) != null &&
        length(try(v.virtual_network.address_space, [])) > 0 &&
        startswith(v.virtual_network.address_space[0], "/")
      )

      ipam_prefix_length = (
        try(v.virtual_network, null) != null &&
        length(try(v.virtual_network.address_space, [])) > 0 &&
        startswith(v.virtual_network.address_space[0], "/")
      ) ? tonumber(trimprefix(v.virtual_network.address_space[0], "/")) : null

      rt_agw_name      = "rt-${try(v.subscription_request.service_short_name, k)}-${v.env_short_name}-agw-01"
      rt_private_name  = "rt-${try(v.subscription_request.service_short_name, k)}-${v.env_short_name}-private-01"
      rt_protect_name  = "rt-${try(v.subscription_request.service_short_name, k)}-${v.env_short_name}-protect-01"
      nsg_private_name = "nsg-${try(v.subscription_request.service_short_name, k)}-${v.env_short_name}-private-01"
      nsg_protect_name = "nsg-${try(v.subscription_request.service_short_name, k)}-${v.env_short_name}-protect-01"

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

  # RBAC付与用
  vending_with_rbac = {
    for k, v in local.subscriptions : k => {
      sub_id           = local.resolved_subscription_ids[k]
      rbac_assignments = v.rbac_assignments
    }
    if length(v.rbac_assignments) > 0
  }

  # VNet の実CIDR（固定CIDR or IPAM払い出し後のCIDR）
  resolved_vnet_address_space = {
    for k, v in local.subscriptions : k => (
      v.use_ipam
      ? azapi_resource.vending_vnet[k].output.properties.addressSpace.addressPrefixes[0]
      : v.address_space[0]
    )
    if v.has_vnet
  }

  # YAML に定義された subnet 名一覧
  requested_subnet_names = {
    for k, v in local.subscriptions_raw : k => [
      for s in try(v.virtual_network.subnets, []) : s.name
    ]
    if try(v.virtual_network, null) != null
  }

  # Subnet 用の for_each map（Subnet も IPAM 割り当て）
  vending_subnets = merge([
    for k, v in local.subscriptions : {
      for s in try(local.subscriptions_raw[k].virtual_network.subnets, []) :
      "${k}/${s.name}" => {
        sub_key       = k
        sub_id        = local.resolved_subscription_ids[k]
        vnet_rg       = v.vnet_rg_name
        name          = s.name
        prefix_length = tonumber(trimprefix(s.address_prefix, "/"))
        ipam_pool_id  = v.hub.spoke_ipam_pool_id
      }
    } if v.has_vnet
  ]...)

  # 作成後の subnet 実CIDR（data.azapi_resource から取得）
  resolved_subnet_prefixes = {
    for k, v in local.vending_subnets :
    k => data.azapi_resource.vending_subnet_read[k].output.properties.ipamPoolPrefixAllocations[0].allocatedAddressPrefixes[0]
  }

  # 特定サブネットを名前で引けるようにする
  firewall_subnet_map = {
    for k, v in local.subscriptions : k => (
      contains(try(local.requested_subnet_names[k], []), "AzureFirewallSubnet") ? {
        name                     = "AzureFirewallSubnet"
        effective_address_prefix = local.resolved_subnet_prefixes["${k}/AzureFirewallSubnet"]
      } : null
    )
    if v.has_vnet
  }

  agw_subnet_map = {
    for k, v in local.subscriptions : k => (
      contains(try(local.requested_subnet_names[k], []), "ApplicationGatewaySubnet") ? {
        name                     = "ApplicationGatewaySubnet"
        effective_address_prefix = local.resolved_subnet_prefixes["${k}/ApplicationGatewaySubnet"]
      } : null
    )
    if v.has_vnet
  }

  private_subnet_map = {
    for k, v in local.subscriptions : k => (
      contains(try(local.requested_subnet_names[k], []), "PrivateSubnet") ? {
        name                     = "PrivateSubnet"
        effective_address_prefix = local.resolved_subnet_prefixes["${k}/PrivateSubnet"]
      } : null
    )
    if v.has_vnet
  }

  protect_subnet_map = {
    for k, v in local.subscriptions : k => (
      contains(try(local.requested_subnet_names[k], []), "ProtectSubnet") ? {
        name                     = "ProtectSubnet"
        effective_address_prefix = local.resolved_subnet_prefixes["${k}/ProtectSubnet"]
      } : null
    )
    if v.has_vnet
  }

  # AzureFirewallSubnet の 4番目のIPを Spoke FW IP として使う
  spoke_fw_ip_map = {
    for k, v in local.firewall_subnet_map : k => (
      v != null ? cidrhost(v.effective_address_prefix, 4) : null
    )
  }

  # RG 用の for_each map
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

  # 通知系用
  vending_with_alerts = {
    for k, v in local.subscriptions : k => {
      sub_id            = local.resolved_subscription_ids[k]
      subscription_name = v.subscription_name
      location          = v.location
      alert_contacts    = v.alert_contacts
      short_name        = substr(replace(v.service_short_name, "-", ""), 0, 12)
      tags              = v.tags
      rg_name           = v.alert_rg_name
      env_short_name    = v.env_short_name
    }
    if length(v.alert_contacts) > 0
  }

  # 予算アラート用
  vending_with_budget = {
    for k, v in local.subscriptions : k => {
      sub_id            = local.resolved_subscription_ids[k]
      subscription_name = v.subscription_name
      amount            = v.budget
      alert_contacts    = v.alert_contacts
      env_short_name    = v.env_short_name
    }
    if v.budget != null && length(v.alert_contacts) > 0
  }

  # VNetありのもの
  vending_with_vnet = {
    for k, v in local.subscriptions : k => v
    if v.has_vnet
  }

  # Peeringありのもの
  vending_with_peering = {
    for k, v in local.subscriptions : k => v
    if v.has_vnet && v.has_peering
  }

  # Hub Gateway 側に追加する Spoke ルート
  vending_spoke_routes = flatten([
    for k, v in local.subscriptions : [
      for i, cidr in [local.resolved_vnet_address_space[k]] : {
        key            = "${k}-${i}"
        env_short_name = v.env_short_name
        name           = "to-${v.vnet_name}-${i}"
        address_prefix = cidr
      }
    ] if v.has_vnet && v.has_peering
  ])

  # 各種サブネットが存在する場合だけ対象化
  vending_nsg_private = {
    for k, v in local.subscriptions : k => v
    if contains(try(local.requested_subnet_names[k], []), "PrivateSubnet")
  }

  vending_nsg_protect = {
    for k, v in local.subscriptions : k => v
    if contains(try(local.requested_subnet_names[k], []), "ProtectSubnet")
  }

  vending_rt_agw = {
    for k, v in local.subscriptions : k => v
    if contains(try(local.requested_subnet_names[k], []), "ApplicationGatewaySubnet")
    && contains(try(local.requested_subnet_names[k], []), "PrivateSubnet")
    && contains(try(local.requested_subnet_names[k], []), "AzureFirewallSubnet")
  }

  vending_rt_private = {
    for k, v in local.subscriptions : k => v
    if contains(try(local.requested_subnet_names[k], []), "PrivateSubnet")
  }

  vending_rt_protect = {
    for k, v in local.subscriptions : k => v
    if contains(try(local.requested_subnet_names[k], []), "ProtectSubnet")
  }

  # ER なし環境では gateway route を作らない
  vending_spoke_routes_with_gateway = {
    for r in local.vending_spoke_routes : r.key => r
    if try(var.hub_environments[r.env_short_name].hub_gateway_route_table_resource_group_name, null) != null
    && try(var.hub_environments[r.env_short_name].hub_gateway_route_table_name, null) != null
  }
}
