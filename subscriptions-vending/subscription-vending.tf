# =============================================================================
# Subscription Creation
# =============================================================================

# YAML に subscription_id がないものだけ新規サブスクリプションを作成
resource "azurerm_subscription" "vending" {
  for_each = local.subscriptions_to_create

  subscription_name = local.subscriptions[each.key].subscription_name
  alias             = each.key
  billing_scope_id  = local.subscriptions[each.key].billing_scope_id
  workload          = local.subscriptions[each.key].workload_type
  tags              = local.subscriptions[each.key].tags
}

# 作成直後の Azure 側の反映待ち
resource "time_sleep" "wait_for_subscription" {
  for_each = local.subscriptions_to_create

  depends_on      = [azurerm_subscription.vending]
  create_duration = "30s"
}

# =============================================================================
# Management Group Association
# =============================================================================

# 新規作成したサブスクリプションを管理グループに紐付け
resource "azapi_resource" "vending_mg_association" {
  for_each = local.subscriptions_to_create

  type      = "Microsoft.Management/managementGroups/subscriptions@2021-04-01"
  name      = azurerm_subscription.vending[each.key].subscription_id
  parent_id = "/providers/Microsoft.Management/managementGroups/${each.value.management_group_id}"

  retry = {
    error_message_regex  = ["NotFound", "not found", "ManagementGroupNotFound"]
    interval_seconds     = 30
    max_interval_seconds = 300
  }
}

# 既存サブスクリプションも管理グループに紐付け
resource "azapi_resource" "vending_mg_association_existing" {
  for_each = local.subscriptions_with_ids

  type      = "Microsoft.Management/managementGroups/subscriptions@2021-04-01"
  name      = each.value.subscription_id
  parent_id = "/providers/Microsoft.Management/managementGroups/${each.value.management_group_id}"

  retry = {
    error_message_regex  = ["NotFound", "not found", "ManagementGroupNotFound"]
    interval_seconds     = 30
    max_interval_seconds = 300
  }
}

# =============================================================================
# RBAC Assignments
# =============================================================================

# UPN から object_id を引く
data "azuread_user" "vending_rbac_users" {
  for_each = {
    for pair in flatten([
      for k, v in local.vending_with_rbac : [
        for upn in v.rbac_assignments : {
          key = "${k}:${upn}"
          upn = upn
        }
      ]
    ]) : pair.key => pair
  }

  user_principal_name = each.value.upn
}

# User Access Administrator を subscription スコープで付与
resource "azurerm_role_assignment" "vending_user_access_administrator" {
  for_each = data.azuread_user.vending_rbac_users

  scope                = "/subscriptions/${local.vending_with_rbac[split(":", each.key)[0]].sub_id}"
  role_definition_name = "User Access Administrator"
  principal_id         = each.value.object_id
}

# =============================================================================
# Resource Groups
# =============================================================================

# network / alert 用 RG を作成
resource "azapi_resource" "vending_resource_groups" {
  for_each = local.vending_resource_groups

  type      = "Microsoft.Resources/resourceGroups@2024-03-01"
  name      = each.value.name
  parent_id = "/subscriptions/${each.value.sub_id}"
  location  = each.value.location
  tags      = each.value.tags

  depends_on = [time_sleep.wait_for_subscription]

  lifecycle { ignore_changes = all }
}

# =============================================================================
# Health Alert
# =============================================================================

# 通知先 Action Group
resource "azapi_resource" "spoke_action_group" {
  for_each = local.vending_with_alerts

  type      = "Microsoft.Insights/actionGroups@2023-01-01"
  name      = each.value.action_group_name
  parent_id = "/subscriptions/${each.value.sub_id}/resourceGroups/${each.value.rg_name}"
  location  = "global"
  tags      = each.value.tags

  body = {
    properties = {
      groupShortName = each.value.short_name
      enabled        = true
      emailReceivers = [
        for contact in each.value.alert_contacts : {
          name                 = contact.name
          emailAddress         = contact.email_address
          useCommonAlertSchema = true
        }
      ]
    }
  }

  depends_on = [azapi_resource.vending_resource_groups]

  lifecycle { ignore_changes = all }
}

# Service Health の Activity Log Alert
resource "azapi_resource" "service_health" {
  for_each = local.vending_with_alerts

  type      = "Microsoft.Insights/activityLogAlerts@2020-10-01"
  name      = each.value.alert_name
  parent_id = "/subscriptions/${each.value.sub_id}/resourceGroups/${each.value.rg_name}"
  location  = "global"
  tags      = each.value.tags

  body = {
    properties = {
      enabled     = true
      description = "${each.value.subscription_name} の Service Health 正常性アラート"
      scopes      = ["/subscriptions/${each.value.sub_id}"]
      condition = {
        allOf = [
          {
            field  = "category"
            equals = "ServiceHealth"
          }
        ]
      }
      actions = {
        actionGroups = [
          {
            actionGroupId = azapi_resource.spoke_action_group[each.key].id
          }
        ]
      }
    }
  }

  depends_on = [
    azapi_resource.vending_resource_groups,
    azapi_resource.spoke_action_group
  ]
}

# =============================================================================
# Budget Alert
# =============================================================================

resource "azurerm_consumption_budget_subscription" "vending" {
  for_each = local.vending_with_budget

  name            = each.value.name
  subscription_id = "/subscriptions/${each.value.sub_id}"

  amount     = each.value.amount
  time_grain = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    enabled        = true
    threshold      = each.value.threshold
    operator       = "GreaterThan"
    threshold_type = "Actual"

    contact_emails = each.value.contact_emails
  }

  depends_on = [time_sleep.wait_for_subscription]

  lifecycle {
    ignore_changes = all
  }
}

# =============================================================================
# VNet
# =============================================================================

# Spoke VNet 本体を作成
resource "azapi_resource" "vending_vnet" {
  for_each = local.vending_with_vnet

  type      = "Microsoft.Network/virtualNetworks@2024-01-01"
  name      = each.value.vnet_name
  parent_id = "/subscriptions/${local.resolved_subscription_ids[each.key]}/resourceGroups/${each.value.vnet_rg_name}"
  location  = each.value.location
  tags      = each.value.tags

  body = {
    properties = merge(
      {
        addressSpace = {
          addressPrefixes = each.value.address_space
        }
      },
      try(length(each.value.hub.hub_dns_servers), 0) > 0 ? {
        dhcpOptions = {
          dnsServers = each.value.hub.hub_dns_servers
        }
      } : {}
    )
  }

  depends_on = [azapi_resource.vending_resource_groups]

  lifecycle { ignore_changes = all }
}

# DNS サーバーだけは別 PATCH で管理
resource "azapi_update_resource" "vending_vnet_dns" {
  for_each = {
    for k, v in local.vending_with_vnet : k => v
    if try(length(v.hub.hub_dns_servers), 0) > 0
  }

  type        = "Microsoft.Network/virtualNetworks@2024-01-01"
  resource_id = azapi_resource.vending_vnet[each.key].id

  body = {
    properties = {
      dhcpOptions = {
        dnsServers = each.value.hub.hub_dns_servers
      }
    }
  }

  depends_on = [azapi_resource.vending_vnet]
}

# =============================================================================
# NSG
# =============================================================================

# PrivateSubnet 用 NSG
resource "azapi_resource" "vending_nsg_private" {
  for_each = local.vending_nsg_private

  type      = "Microsoft.Network/networkSecurityGroups@2024-01-01"
  name      = each.value.nsg_private_name
  parent_id = "/subscriptions/${local.resolved_subscription_ids[each.key]}/resourceGroups/${each.value.vnet_rg_name}"
  location  = each.value.location
  tags      = each.value.tags

  body = {
    properties = {
      securityRules = [
        {
          name = "AllowPrivateInbound"
          properties = {
            priority                 = 100
            direction                = "Inbound"
            access                   = "Allow"
            protocol                 = "*"
            sourcePortRange          = "*"
            destinationPortRange     = "*"
            sourceAddressPrefixes    = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
            destinationAddressPrefix = "*"
          }
        },
        {
          name = "DenyAllInbound"
          properties = {
            priority                 = 200
            direction                = "Inbound"
            access                   = "Deny"
            protocol                 = "*"
            sourcePortRange          = "*"
            destinationPortRange     = "*"
            sourceAddressPrefix      = "*"
            destinationAddressPrefix = "*"
          }
        }
      ]
    }
  }

  depends_on = [azapi_resource.vending_resource_groups]

  lifecycle { ignore_changes = all }
}

# ProtectSubnet 用 NSG
resource "azapi_resource" "vending_nsg_protect" {
  for_each = local.vending_nsg_protect

  type      = "Microsoft.Network/networkSecurityGroups@2024-01-01"
  name      = each.value.nsg_protect_name
  parent_id = "/subscriptions/${local.resolved_subscription_ids[each.key]}/resourceGroups/${each.value.vnet_rg_name}"
  location  = each.value.location
  tags      = each.value.tags

  body = {
    properties = {
      securityRules = [
        {
          name = "AllowFromPrivateSubnet"
          properties = {
            priority                 = 100
            direction                = "Inbound"
            access                   = "Allow"
            protocol                 = "*"
            sourcePortRange          = "*"
            destinationPortRange     = "*"
            sourceAddressPrefix      = each.value.private_subnet.effective_address_prefix
            destinationAddressPrefix = "*"
          }
        },
        {
          name = "DenyAllInbound"
          properties = {
            priority                 = 200
            direction                = "Inbound"
            access                   = "Deny"
            protocol                 = "*"
            sourcePortRange          = "*"
            destinationPortRange     = "*"
            sourceAddressPrefix      = "*"
            destinationAddressPrefix = "*"
          }
        }
      ]
    }
  }

  depends_on = [azapi_resource.vending_resource_groups]

  lifecycle { ignore_changes = all }
}

# =============================================================================
# Route Table
# =============================================================================

# AGW 用 RT
resource "azapi_resource" "vending_rt_agw" {
  for_each = local.vending_rt_agw

  type      = "Microsoft.Network/routeTables@2024-01-01"
  name      = each.value.rt_agw_name
  parent_id = "/subscriptions/${local.resolved_subscription_ids[each.key]}/resourceGroups/${each.value.vnet_rg_name}"
  location  = each.value.location
  tags      = each.value.tags

  body = {
    properties = {
      routes = [
        {
          name = "ToFW"
          properties = {
            addressPrefix    = each.value.private_subnet.effective_address_prefix
            nextHopType      = "VirtualAppliance"
            nextHopIpAddress = each.value.spoke_fw_ip
          }
        }
      ]
    }
  }

  depends_on = [azapi_resource.vending_resource_groups]

  lifecycle { ignore_changes = [body] }
}

# PrivateSubnet 用 RT
resource "azapi_resource" "vending_rt_private" {
  for_each = local.vending_rt_private

  type      = "Microsoft.Network/routeTables@2024-01-01"
  name      = each.value.rt_private_name
  parent_id = "/subscriptions/${local.resolved_subscription_ids[each.key]}/resourceGroups/${each.value.vnet_rg_name}"
  location  = each.value.location
  tags      = each.value.tags

  body = {
    properties = {
      disableBgpRoutePropagation = true
      routes = concat(
        [
          {
            name = "Default"
            properties = {
              addressPrefix    = "0.0.0.0/0"
              nextHopType      = "VirtualAppliance"
              nextHopIpAddress = each.value.hub.hub_firewall_private_ip
            }
          }
        ],
        each.value.agw_subnet != null && each.value.spoke_fw_ip != null ? [
          {
            name = "toAFW"
            properties = {
              addressPrefix    = each.value.agw_subnet.effective_address_prefix
              nextHopType      = "VirtualAppliance"
              nextHopIpAddress = each.value.spoke_fw_ip
            }
          }
        ] : []
      )
    }
  }

  depends_on = [azapi_resource.vending_resource_groups]

  lifecycle { ignore_changes = [body] }
}

# ProtectSubnet 用 RT
resource "azapi_resource" "vending_rt_protect" {
  for_each = local.vending_rt_protect

  type      = "Microsoft.Network/routeTables@2024-01-01"
  name      = each.value.rt_protect_name
  parent_id = "/subscriptions/${local.resolved_subscription_ids[each.key]}/resourceGroups/${each.value.vnet_rg_name}"
  location  = each.value.location
  tags      = each.value.tags

  body = {
    properties = {
      disableBgpRoutePropagation = true
      routes = [
        {
          name = "Default"
          properties = {
            addressPrefix    = "0.0.0.0/0"
            nextHopType      = "VirtualAppliance"
            nextHopIpAddress = each.value.hub.hub_firewall_private_ip
          }
        }
      ]
    }
  }

  depends_on = [azapi_resource.vending_resource_groups]

  lifecycle { ignore_changes = [body] }
}

# =============================================================================
# Subnets
# =============================================================================

# サブネットごとに NSG / RT を条件付きで関連付け
resource "azapi_resource" "vending_subnets" {
  for_each = local.vending_subnets

  type      = "Microsoft.Network/virtualNetworks/subnets@2024-01-01"
  name      = each.value.name
  parent_id = azapi_resource.vending_vnet[each.value.sub_key].id

  body = {
    properties = merge(
      {
        addressPrefix         = each.value.effective_address_prefix
        defaultOutboundAccess = false
      },
      each.value.name == "ApplicationGatewaySubnet" ? {
        routeTable = {
          id = azapi_resource.vending_rt_agw[each.value.sub_key].id
        }
      } : {},
      each.value.name == "PrivateSubnet" ? {
        networkSecurityGroup = {
          id = azapi_resource.vending_nsg_private[each.value.sub_key].id
        }
        routeTable = {
          id = azapi_resource.vending_rt_private[each.value.sub_key].id
        }
      } : {},
      each.value.name == "ProtectSubnet" ? {
        networkSecurityGroup = {
          id = azapi_resource.vending_nsg_protect[each.value.sub_key].id
        }
        routeTable = {
          id = azapi_resource.vending_rt_protect[each.value.sub_key].id
        }
      } : {}
    )
  }

  retry = {
    error_message_regex  = ["AnotherOperationInProgress", "InUseSubnetCannotBeUpdated"]
    interval_seconds     = 10
    max_interval_seconds = 60
  }

  depends_on = [
    azapi_update_resource.vending_vnet_dns,
    azapi_resource.vending_nsg_private,
    azapi_resource.vending_nsg_protect,
    azapi_resource.vending_rt_agw,
    azapi_resource.vending_rt_private,
    azapi_resource.vending_rt_protect
  ]

  lifecycle { ignore_changes = all }
}

# # =============================================================================
# # Spoke -> Hub Peering
# # =============================================================================

# resource "azapi_resource" "vending_spoke_to_hub" {
#   for_each = local.vending_with_peering

#   type      = "Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01"
#   name      = each.value.spoke_to_hub_peering_name
#   parent_id = azapi_resource.vending_vnet[each.key].id

#   body = {
#     properties = {
#       remoteVirtualNetwork = {
#         id = each.value.hub.hub_virtual_network_id
#       }
#       allowForwardedTraffic     = true
#       allowVirtualNetworkAccess = true
#       useRemoteGateways         = each.value.use_hub_gateway
#     }
#   }

#   retry = {
#     error_message_regex  = ["ReferencedResourceNotProvisioned", "InUseSubnetCannotBeUpdated", "AnotherOperationInProgress", "RemoteVnetHasNoGateways"]
#     interval_seconds     = 30
#     max_interval_seconds = 300
#   }

#   depends_on = [azapi_resource.vending_subnets]
# }

# # =============================================================================
# # Hub -> Spoke Peering
# # =============================================================================

# resource "azapi_resource" "vending_hub_to_spoke" {
#   for_each = local.vending_with_peering

#   type      = "Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01"
#   name      = each.value.hub_to_spoke_peering_name
#   parent_id = "${each.value.hub.hub_virtual_network_parent_id}/providers/Microsoft.Network/virtualNetworks/${each.value.hub.hub_virtual_network_name}"

#   body = {
#     properties = {
#       remoteVirtualNetwork = {
#         id = azapi_resource.vending_vnet[each.key].id
#       }
#       allowForwardedTraffic     = true
#       allowVirtualNetworkAccess = true
#       allowGatewayTransit       = true
#     }
#   }

#   retry = {
#     error_message_regex  = ["ReferencedResourceNotProvisioned", "InUseSubnetCannotBeUpdated", "AnotherOperationInProgress"]
#     interval_seconds     = 30
#     max_interval_seconds = 300
#   }

#   depends_on = [azapi_resource.vending_subnets]
# }

# # =============================================================================
# # GatewaySubnet Route Table routes
# # =============================================================================

# resource "azapi_resource" "gateway_to_vending" {
#   for_each = local.vending_spoke_routes_with_gateway

#   type      = "Microsoft.Network/routeTables/routes@2024-01-01"
#   name      = each.value.name
#   parent_id = "/subscriptions/${var.hub_environments[each.value.env_short_name].hub_subscription_id}/resourceGroups/${var.hub_environments[each.value.env_short_name].hub_gateway_route_table_resource_group_name}/providers/Microsoft.Network/routeTables/${var.hub_environments[each.value.env_short_name].hub_gateway_route_table_name}"

#   body = {
#     properties = {
#       addressPrefix    = each.value.address_prefix
#       nextHopType      = "VirtualAppliance"
#       nextHopIpAddress = var.hub_environments[each.value.env_short_name].hub_firewall_private_ip
#     }
#   }
# }
