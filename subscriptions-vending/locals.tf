locals {
  # subscriptions 配下の YAML 一覧
  subscription_yaml_files = fileset(var.subscription_vending_path, "*.yaml")

  # YAML をそのまま map 化
  # key は YAML ファイル名から .yaml を除いた値になる
  subscriptions_raw = {
    for f in local.subscription_yaml_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${var.subscription_vending_path}/${f}"))
  }

  # 新規作成対象
  # YAML に subscription_id がないものは、新規サブスクリプション作成対象
  subscriptions_to_create = {
    for k, v in local.subscriptions_raw : k => v
    if try(v.subscription_id, null) == null
  }

  # 既存サブスクリプション対象
  # YAML に subscription_id があるものは、既存サブスクリプションとして扱う
  subscriptions_with_ids = {
    for k, v in local.subscriptions_raw : k => v
    if try(v.subscription_id, null) != null
  }

  # YAML から Terraform で使う値を整理する
  subscriptions = {
    for k, v in local.subscriptions_raw : k => {
      subscription_name   = v.subscription_name
      workload_type       = try(v.workload_type, "Production")
      management_group_id = v.management_group_id
      location            = v.location
      env_short_name      = v.env_short_name
      tags                = try(v.tags, {})

      # 課金スコープ
      # enrollment_account_id は YAML には持たせず、tfvars の cost_center 対応表から取得する
      enrollment_account_id = var.enrollment_account_id_map[v.tags.cost_center]
      billing_scope_id      = "/providers/Microsoft.Billing/billingAccounts/6d92e1a7-44ef-5b9d-fe85-600e31fecd27:7ffb2b72-d71a-46c2-ac74-10566d437c9e_2019-05-31/billingProfiles/KXVV-QQVV-BG7-PGB/invoiceSections/b5316415-c236-41e7-8237-fcf186346a73"

      # Resource Group
      network_rg_name     = v.resource_groups.network.name
      network_rg_location = try(v.resource_groups.network.location, v.location)
      alert_rg_name       = v.resource_groups.alert.name
      alert_rg_location   = try(v.resource_groups.alert.location, v.location)

      # 申請情報から参照するサービス名
      service_name       = try(v.subscription_request.service_name, k)
      service_short_name = try(v.subscription_request.service_short_name, k)

      # RBAC
      # 空文字は除外する
      rbac_assignments = [for x in try(v.rbac_assignments, []) : x if trimspace(x) != ""]

      # 監視、予算
      alerts = try(v.alerts, null)
      budget = try(v.budget, null)

      # VNet 情報
      vnet_name       = try(v.virtual_network.name, null)
      vnet_rg_name    = try(v.virtual_network.resource_group_name, null)
      address_space   = try(v.virtual_network.address_space, [])
      has_vnet        = try(v.virtual_network, null) != null
      has_peering     = try(v.virtual_network.hub_peering_enabled, false)
      use_hub_gateway = try(v.virtual_network.use_hub_gateway, false)

      # Peering 名
      # リソース名は jira-dispatch 側で生成し、YAML からそのまま受け取る
      spoke_to_hub_peering_name = try(v.virtual_network.spoke_to_hub_peering_name, null)
      hub_to_spoke_peering_name = try(v.virtual_network.hub_to_spoke_peering_name, null)

      # RT / NSG 名
      # リソース名は Terraform 側で組み立てず、YAML から取得する
      rt_agw_name      = try(one([for s in try(v.virtual_network.subnets, []) : s.route_table_name if s.name == "ApplicationGatewaySubnet"]), null)
      rt_private_name  = try(one([for s in try(v.virtual_network.subnets, []) : s.route_table_name if s.name == "PrivateSubnet"]), null)
      rt_protect_name  = try(one([for s in try(v.virtual_network.subnets, []) : s.route_table_name if s.name == "ProtectSubnet"]), null)
      nsg_private_name = try(one([for s in try(v.virtual_network.subnets, []) : s.network_security_group_name if s.name == "PrivateSubnet"]), null)
      nsg_protect_name = try(one([for s in try(v.virtual_network.subnets, []) : s.network_security_group_name if s.name == "ProtectSubnet"]), null)

      # Hub 情報
      # env_short_name をキーに tfvars の hub_environments から取得する
      hub = var.hub_environments[v.env_short_name]

      # サブネットを先頭から自動採番して CIDR 化する
      # 前提:
      # - VNet の address_space[0] は 10.x.x.x/23 のようなフル CIDR
      # - Subnet の address_prefix は /24, /26, /27 のようなプレフィックス長のみ
      # - YAML の subnets 定義順に、address_space[0] の先頭から CIDR を割り当てる
      subnets = [
        for idx, s in try(v.virtual_network.subnets, []) : {
          name                        = s.name
          route_table_name            = try(s.route_table_name, null)
          network_security_group_name = try(s.network_security_group_name, null)
          effective_address_prefix = cidrsubnet(
            v.virtual_network.address_space[0],
            tonumber(replace(s.address_prefix, "/", "")) - tonumber(split("/", v.virtual_network.address_space[0])[1]),
            sum(concat(
              [0],
              [
                for prev in slice(try(v.virtual_network.subnets, []), 0, idx) :
                pow(
                  2,
                  tonumber(replace(s.address_prefix, "/", "")) - tonumber(replace(prev.address_prefix, "/", ""))
                )
              ]
            ))
          )
        }
      ]

      # AzureFirewallSubnet を取得する
      # 名前自体を知るためではなく、以下の目的で取得している:
      # - AzureFirewallSubnet が存在するか判定する
      # - 自動計算後の CIDR を取得する
      # - spoke_fw_ip の計算に使う
      firewall_subnet = try(one([
        for s in [
          for idx, sn in try(v.virtual_network.subnets, []) : {
            name = sn.name
            effective_address_prefix = cidrsubnet(
              v.virtual_network.address_space[0],
              tonumber(replace(sn.address_prefix, "/", "")) - tonumber(split("/", v.virtual_network.address_space[0])[1]),
              sum(concat(
                [0],
                [
                  for prev in slice(try(v.virtual_network.subnets, []), 0, idx) :
                  pow(
                    2,
                    tonumber(replace(sn.address_prefix, "/", "")) - tonumber(replace(prev.address_prefix, "/", ""))
                  )
                ]
              ))
            )
          }
        ] : s if s.name == "AzureFirewallSubnet"
      ]), null)

      # ApplicationGatewaySubnet を取得する
      # 後続の Route Table 作成やルート設定の条件判定、CIDR 参照に使う
      agw_subnet = try(one([
        for s in [
          for idx, sn in try(v.virtual_network.subnets, []) : {
            name = sn.name
            effective_address_prefix = cidrsubnet(
              v.virtual_network.address_space[0],
              tonumber(replace(sn.address_prefix, "/", "")) - tonumber(split("/", v.virtual_network.address_space[0])[1]),
              sum(concat(
                [0],
                [
                  for prev in slice(try(v.virtual_network.subnets, []), 0, idx) :
                  pow(
                    2,
                    tonumber(replace(sn.address_prefix, "/", "")) - tonumber(replace(prev.address_prefix, "/", ""))
                  )
                ]
              ))
            )
          }
        ] : s if s.name == "ApplicationGatewaySubnet"
      ]), null)

      # PrivateSubnet を取得する
      # 後続の NSG / Route Table 作成、NSG ルール、ルート設定の CIDR 参照に使う
      private_subnet = try(one([
        for s in [
          for idx, sn in try(v.virtual_network.subnets, []) : {
            name = sn.name
            effective_address_prefix = cidrsubnet(
              v.virtual_network.address_space[0],
              tonumber(replace(sn.address_prefix, "/", "")) - tonumber(split("/", v.virtual_network.address_space[0])[1]),
              sum(concat(
                [0],
                [
                  for prev in slice(try(v.virtual_network.subnets, []), 0, idx) :
                  pow(
                    2,
                    tonumber(replace(sn.address_prefix, "/", "")) - tonumber(replace(prev.address_prefix, "/", ""))
                  )
                ]
              ))
            )
          }
        ] : s if s.name == "PrivateSubnet"
      ]), null)

      # ProtectSubnet を取得する
      # 構成パターンによって存在しない場合があるため、null 許容で取得する
      protect_subnet = try(one([
        for s in [
          for idx, sn in try(v.virtual_network.subnets, []) : {
            name = sn.name
            effective_address_prefix = cidrsubnet(
              v.virtual_network.address_space[0],
              tonumber(replace(sn.address_prefix, "/", "")) - tonumber(split("/", v.virtual_network.address_space[0])[1]),
              sum(concat(
                [0],
                [
                  for prev in slice(try(v.virtual_network.subnets, []), 0, idx) :
                  pow(
                    2,
                    tonumber(replace(sn.address_prefix, "/", "")) - tonumber(replace(prev.address_prefix, "/", ""))
                  )
                ]
              ))
            )
          }
        ] : s if s.name == "ProtectSubnet"
      ]), null)

      # AzureFirewallSubnet の 4 番目の IP を Spoke Firewall の IP として使う
      # AzureFirewallSubnet が存在しない構成では null になる
      spoke_fw_ip = try(one([
        for s in [
          for idx, sn in try(v.virtual_network.subnets, []) : {
            name = sn.name
            effective_address_prefix = cidrsubnet(
              v.virtual_network.address_space[0],
              tonumber(replace(sn.address_prefix, "/", "")) - tonumber(split("/", v.virtual_network.address_space[0])[1]),
              sum(concat(
                [0],
                [
                  for prev in slice(try(v.virtual_network.subnets, []), 0, idx) :
                  pow(
                    2,
                    tonumber(replace(sn.address_prefix, "/", "")) - tonumber(replace(prev.address_prefix, "/", ""))
                  )
                ]
              ))
            )
          }
        ] : cidrhost(s.effective_address_prefix, 4) if s.name == "AzureFirewallSubnet"
      ]), null)
    }
  }

  # 新規作成後も含めた subscription_id の確定値
  # 既存サブスクは YAML の subscription_id、新規作成は azurerm_subscription の結果を使う
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

  # VNet ありのもの
  vending_with_vnet = {
    for k, v in local.subscriptions : k => v
    if v.has_vnet
  }

  # Peering ありのもの
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
