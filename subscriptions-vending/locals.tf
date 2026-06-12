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
      subscription_name   = v.subscription_name
      workload_type       = try(v.workload_type, "Production")
      management_group_id = v.management_group_id
      location            = v.location
      env_short_name      = v.env_short_name
      tags                = try(v.tags, {})

      enrollment_account_id = var.enrollment_account_id_map[v.tags.cost_center]
      billing_scope_id      = "/providers/Microsoft.Billing/billingAccounts/${var.billing_account_id}/enrollmentAccounts/${var.enrollment_account_id_map[v.tags.cost_center]}"

      network_rg_name     = v.resource_groups.network.name
      network_rg_location = try(v.resource_groups.network.location, v.location)
      alert_rg_name       = v.resource_groups.alert.name
      alert_rg_location   = try(v.resource_groups.alert.location, v.location)

      service_name       = try(v.subscription_request.service_name, k)
      service_short_name = try(v.subscription_request.service_short_name, k)

      rbac_assignments = [for x in try(v.rbac_assignments, []) : x if trimspace(x) != ""]

      alerts = try(v.alerts, null)
      budget = try(v.budget, null)

      vnet_name       = try(v.virtual_network.name, null)
      vnet_rg_name    = try(v.virtual_network.resource_group_name, null)
      address_space   = try(v.virtual_network.address_space, [])
      has_vnet        = try(v.virtual_network, null) != null
      has_peering     = try(v.virtual_network.hub_peering_enabled, false)
      use_hub_gateway = try(v.virtual_network.use_hub_gateway, false)

      spoke_to_hub_peering_name = try(v.virtual_network.spoke_to_hub_peering_name, null)
      hub_to_spoke_peering_name = try(v.virtual_network.hub_to_spoke_peering_name, null)

      # サブネットを先頭から自動採番して CIDR 化
      # address_prefix に CIDR が指定されている場合はそのまま使用
      # address_prefix に /24 のようなプレフィックス長だけ指定されている場合は address_space[0] から自動計算
      subnets = [
        for idx, s in try(v.virtual_network.subnets, []) : {
          name                        = s.name
          route_table_name            = try(s.route_table_name, null)
          network_security_group_name = try(s.network_security_group_name, null)
          effective_address_prefix = try(
            s.address_range,
            can(cidrhost(s.address_prefix, 0)) ? s.address_prefix : cidrsubnet(
              v.virtual_network.address_space[0],
              tonumber(replace(s.address_prefix, "/", "")) - tonumber(split("/", v.virtual_network.address_space[0])[1]),
              ceil(sum(concat([
                0
                ], [
                for prev in slice(try(v.virtual_network.subnets, []), 0, idx) :
                pow(
                  2,
                  tonumber(replace(s.address_prefix, "/", "")) - tonumber(replace(prev.address_prefix, "/", ""))
                )
              ])))
            )
          )
        }
      ]

      # 特定サブネットを名前で引けるようにする
      firewall_subnet = try(one([
        for s in [
          for idx, sn in try(v.virtual_network.subnets, []) : {
            name = sn.name
            effective_address_prefix = try(
              sn.address_range,
              can(cidrhost(sn.address_prefix, 0)) ? sn.address_prefix : cidrsubnet(
                v.virtual_network.address_space[0],
                tonumber(replace(sn.address_prefix, "/", "")) - tonumber(split("/", v.virtual_network.address_space[0])[1]),
                ceil(sum(concat([
                  0
                  ], [
                  for prev in slice(try(v.virtual_network.subnets, []), 0, idx) :
                  pow(
                    2,
                    tonumber(replace(sn.address_prefix, "/", "")) - tonumber(replace(prev.address_prefix, "/", ""))
                  )
                ])))
              )
            )
          }
        ] : s if s.name == "AzureFirewallSubnet"
      ]), null)

      agw_subnet = try(one([
        for s in [
          for idx, sn in try(v.virtual_network.subnets, []) : {
            name = sn.name
            effective_address_prefix = try(
              sn.address_range,
              can(cidrhost(sn.address_prefix, 0)) ? sn.address_prefix : cidrsubnet(
                v.virtual_network.address_space[0],
                tonumber(replace(sn.address_prefix, "/", "")) - tonumber(split("/", v.virtual_network.address_space[0])[1]),
                ceil(sum(concat([
                  0
                  ], [
                  for prev in slice(try(v.virtual_network.subnets, []), 0, idx) :
                  pow(
                    2,
                    tonumber(replace(sn.address_prefix, "/", "")) - tonumber(replace(prev.address_prefix, "/", ""))
                  )
                ])))
              )
            )
          }
        ] : s if s.name == "ApplicationGatewaySubnet"
      ]), null)

      private_subnet = try(one([
        for s in [
          for idx, sn in try(v.virtual_network.subnets, []) : {
            name = sn.name
            effective_address_prefix = try(
              sn.address_range,
              can(cidrhost(sn.address_prefix, 0)) ? sn.address_prefix : cidrsubnet(
                v.virtual_network.address_space[0],
                tonumber(replace(sn.address_prefix, "/", "")) - tonumber(split("/", v.virtual_network.address_space[0])[1]),
                ceil(sum(concat([
                  0
                  ], [
                  for prev in slice(try(v.virtual_network.subnets, []), 0, idx) :
                  pow(
                    2,
                    tonumber(replace(sn.address_prefix, "/", "")) - tonumber(replace(prev.address_prefix, "/", ""))
                  )
                ])))
              )
            )
          }
        ] : s if s.name == "PrivateSubnet"
      ]), null)

      protect_subnet = try(one([
        for s in [
          for idx, sn in try(v.virtual_network.subnets, []) : {
            name = sn.name
            effective_address_prefix = try(
              sn.address_range,
              can(cidrhost(sn.address_prefix, 0)) ? sn.address_prefix : cidrsubnet(
                v.virtual_network.address_space[0],
                tonumber(replace(sn.address_prefix, "/", "")) - tonumber(split("/", v.virtual_network.address_space[0])[1]),
                ceil(sum(concat([
                  0
                  ], [
                  for prev in slice(try(v.virtual_network.subnets, []), 0, idx) :
                  pow(
                    2,
                    tonumber(replace(sn.address_prefix, "/", "")) - tonumber(replace(prev.address_prefix, "/", ""))
                  )
                ])))
              )
            )
          }
        ] : s if s.name == "ProtectSubnet"
      ]), null)

      # AzureFirewallSubnet の 4番目のIPを Spoke FW IP として使う
      spoke_fw_ip = try(one([
        for s in [
          for idx, sn in try(v.virtual_network.subnets, []) : {
            name = sn.name
            effective_address_prefix = try(
              sn.address_range,
              can(cidrhost(sn.address_prefix, 0)) ? sn.address_prefix : cidrsubnet(
                v.virtual_network.address_space[0],
                tonumber(replace(sn.address_prefix, "/", "")) - tonumber(split("/", v.virtual_network.address_space[0])[1]),
                ceil(sum(concat([
                  0
                  ], [
                  for prev in slice(try(v.virtual_network.subnets, []), 0, idx) :
                  pow(
                    2,
                    tonumber(replace(sn.address_prefix, "/", "")) - tonumber(replace(prev.address_prefix, "/", ""))
                  )
                ])))
              )
            )
          }
        ] : cidrhost(s.effective_address_prefix, 4) if s.name == "AzureFirewallSubnet"
      ]), null)

      rt_agw_name      = try(one([for s in try(v.virtual_network.subnets, []) : s.route_table_name if s.name == "ApplicationGatewaySubnet"]), null)
      rt_private_name  = try(one([for s in try(v.virtual_network.subnets, []) : s.route_table_name if s.name == "PrivateSubnet"]), null)
      rt_protect_name  = try(one([for s in try(v.virtual_network.subnets, []) : s.route_table_name if s.name == "ProtectSubnet"]), null)
      nsg_private_name = try(one([for s in try(v.virtual_network.subnets, []) : s.network_security_group_name if s.name == "PrivateSubnet"]), null)
      nsg_protect_name = try(one([for s in try(v.virtual_network.subnets, []) : s.network_security_group_name if s.name == "ProtectSubnet"]), null)

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
      alert_contacts    = try(v.alerts.contacts, [])
      short_name        = try(v.alerts.group_short_name, substr(replace(v.service_short_name, "-", ""), 0, 12))
      action_group_name = try(v.alerts.action_group_name, null)
      alert_name        = try(v.alerts.service_health_alert_name, null)
      tags              = v.tags
      rg_name           = v.alert_rg_name
      env_short_name    = v.env_short_name
    }
    if try(v.alerts, null) != null && length(try(v.alerts.contacts, [])) > 0
  }

  # 予算アラート用
  vending_with_budget = {
    for k, v in local.subscriptions : k => {
      sub_id            = local.resolved_subscription_ids[k]
      subscription_name = v.subscription_name
      name              = try(v.budget.name, null)
      amount            = try(v.budget.amount, null)
      threshold         = try(v.budget.threshold, 80)
      contact_emails    = try(v.budget.contact_emails, [])
      alert_contacts    = try(v.alerts.contacts, [])
      env_short_name    = v.env_short_name
    }
    if try(v.budget.enabled, false) && try(v.budget.amount, null) != null
  }

  # Subnet 用の for_each map
  vending_subnets = merge([
    for k, v in local.subscriptions : {
      for idx, subnet in v.subnets :
      "${k}/${subnet.name}" => {
        sub_key                     = k
        sub_id                      = local.resolved_subscription_ids[k]
        vnet_rg                     = v.vnet_rg_name
        name                        = subnet.name
        effective_address_prefix    = subnet.effective_address_prefix
        subnet_index                = idx
        route_table_name            = subnet.route_table_name
        network_security_group_name = subnet.network_security_group_name
      }
    } if v.has_vnet
  ]...)

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
      for i, cidr in v.address_space : {
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
    if v.private_subnet != null && v.nsg_private_name != null
  }

  vending_nsg_protect = {
    for k, v in local.subscriptions : k => v
    if v.protect_subnet != null && v.nsg_protect_name != null
  }

  vending_rt_agw = {
    for k, v in local.subscriptions : k => v
    if v.agw_subnet != null && v.private_subnet != null && v.spoke_fw_ip != null && v.rt_agw_name != null
  }

  vending_rt_private = {
    for k, v in local.subscriptions : k => v
    if v.private_subnet != null && v.rt_private_name != null
  }

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
