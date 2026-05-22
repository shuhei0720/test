# =============================================================================
# Subscription Creation
# =============================================================================

resource "azurerm_subscription" "vending" {
  for_each = local.subscriptions_to_create

  subscription_name = local.subscriptions[each.key].subscription_name
  alias             = each.key
  billing_scope_id  = local.subscriptions[each.key].billing_scope_id
  workload          = local.subscriptions[each.key].workload_type
  tags              = local.subscriptions[each.key].tags
}

resource "time_sleep" "wait_for_subscription" {
  for_each = local.subscriptions_to_create

  depends_on      = [azurerm_subscription.vending]
  create_duration = "30s"
}

# =============================================================================
# Management Group Association
# =============================================================================

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

resource "azurerm_role_assignment" "vending_user_access_administrator" {
  for_each = data.azuread_user.vending_rbac_users

  scope                = "/subscriptions/${local.vending_with_rbac[split(":", each.key)[0]].sub_id}"
  role_definition_name = "User Access Administrator"
  principal_id         = each.value.object_id
}

# =============================================================================
# Resource Groups
# =============================================================================

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

resource "azapi_resource" "spoke_action_group" {
  for_each = local.vending_with_alerts

  type      = "Microsoft.Insights/actionGroups@2023-01-01"
  name      = "ag-health-${each.value.short_name}-${each.value.env_short_name}-01"
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

resource "azapi_resource" "service_health" {
  for_each = local.vending_with_alerts

  type      = "Microsoft.Insights/activityLogAlerts@2020-10-01"
  name      = "alr-health-${each.value.short_name}-${each.value.env_short_name}-01"
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

  name            = "budget-${each.value.env_short_name}-${replace(each.value.subscription_name, "subscription_", "")}"
  subscription_id = "/subscriptions/${each.value.sub_id}"

  amount     = each.value.amount
  time_grain = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"

    contact_emails = [for c in each.value.alert_contacts : c.email_address]
  }

  depends_on = [time_sleep.wait_for_subscription]

  lifecycle {
    ignore_changes = all
  }
}

# =============================================================================
# VNet
# =============================================================================

resource "azapi_resource" "vending_vnet" {
  for_each = local.vending_with_vnet

  type      = "Microsoft.Network/virtualNetworks@2024-01-01"
  name      = each.value.vnet_name
  parent_id = "/subscriptions/${local.resolved_subscription_ids[each.key]}/resourceGroups/${each.value.vnet_rg_name}"
  location  = each.value.location
  tags      = each.value.tags

  schema_validation_enabled = false

  body = {
    properties = merge(
      {
        addressSpace = merge(
          each.value.use_ipam ? {
            ipamPoolPrefixAllocations = [
              {
                numberOfIpAddresses = tostring(pow(2, 32 - each.value.ipam_prefix_length))
                pool = {
                  id = each.value.hub.spoke_ipam_pool_id
                }
              }
            ]
          } : {},
          each.value.use_ipam ? {} : {
            addressPrefixes = each.value.address_space
          }
        )
      },
      try(length(each.value.hub.hub_dns_servers), 0) > 0 ? {
        dhcpOptions = {
          dnsServers = each.value.hub.hub_dns_servers
        }
      } : {}
    )
  }

  response_export_values = ["properties.addressSpace.addressPrefixes"]

  depends_on = [azapi_resource.vending_resource_groups]

  lifecycle { ignore_changes = all }
}

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
# Subnets (ordered: AGW -> FW -> Private -> Protect)
# =============================================================================

resource "azapi_resource" "vending_subnets_agw" {
  for_each = local.vending_subnets_agw

  type      = "Microsoft.Network/virtualNetworks/subnets@2024-01-01"
  name      = each.value.name
  parent_id = azapi_resource.vending_vnet[each.value.sub_key].id

  schema_validation_enabled = false

  body = {
    properties = {
      defaultOutboundAccess = false
      ipamPoolPrefixAllocations = [
        {
          numberOfIpAddresses = tostring(pow(2, 32 - each.value.prefix_length))
          pool = {
            id = each.value.ipam_pool_id
          }
        }
      ]
    }
  }

  retry = {
    error_message_regex  = ["AnotherOperationInProgress", "InUseSubnetCannotBeUpdated"]
    interval_seconds     = 10
    max_interval_seconds = 60
  }

  depends_on = [azapi_update_resource.vending_vnet_dns]

  lifecycle { ignore_changes = all }
}

resource "azapi_resource" "vending_subnets_fw" {
  for_each = local.vending_subnets_fw

  type      = "Microsoft.Network/virtualNetworks/subnets@2024-01-01"
  name      = each.value.name
  parent_id = azapi_resource.vending_vnet[each.value.sub_key].id

  schema_validation_enabled = false

  body = {
    properties = {
      defaultOutboundAccess = false
      ipamPoolPrefixAllocations = [
        {
          numberOfIpAddresses = tostring(pow(2, 32 - each.value.prefix_length))
          pool = {
            id = each.value.ipam_pool_id
          }
        }
      ]
    }
  }

  retry = {
    error_message_regex  = ["AnotherOperationInProgress", "InUseSubnetCannotBeUpdated"]
    interval_seconds     = 10
    max_interval_seconds = 60
  }

  depends_on = [azapi_resource.vending_subnets_agw]

  lifecycle { ignore_changes = all }
}

resource "azapi_resource" "vending_subnets_private" {
  for_each = local.vending_subnets_private

  type      = "Microsoft.Network/virtualNetworks/subnets@2024-01-01"
  name      = each.value.name
  parent_id = azapi_resource.vending_vnet[each.value.sub_key].id

  schema_validation_enabled = false

  body = {
    properties = {
      defaultOutboundAccess = false
      ipamPoolPrefixAllocations = [
        {
          numberOfIpAddresses = tostring(pow(2, 32 - each.value.prefix_length))
          pool = {
            id = each.value.ipam_pool_id
          }
        }
      ]
    }
  }

  retry = {
    error_message_regex  = ["AnotherOperationInProgress", "InUseSubnetCannotBeUpdated"]
    interval_seconds     = 10
    max_interval_seconds = 60
  }

  depends_on = [azapi_resource.vending_subnets_fw]

  lifecycle { ignore_changes = all }
}

resource "azapi_resource" "vending_subnets_protect" {
  for_each = local.vending_subnets_protect

  type      = "Microsoft.Network/virtualNetworks/subnets@2024-01-01"
  name      = each.value.name
  parent_id = azapi_resource.vending_vnet[each.value.sub_key].id

  schema_validation_enabled = false

  body = {
    properties = {
      defaultOutboundAccess = false
      ipamPoolPrefixAllocations = [
        {
          numberOfIpAddresses = tostring(pow(2, 32 - each.value.prefix_length))
          pool = {
            id = each.value.ipam_pool_id
          }
        }
      ]
    }
  }

  retry = {
    error_message_regex  = ["AnotherOperationInProgress", "InUseSubnetCannotBeUpdated"]
    interval_seconds     = 10
    max_interval_seconds = 60
  }

  depends_on = [azapi_resource.vending_subnets_private]

  lifecycle { ignore_changes = all }
}

data "azapi_resource" "vending_subnet_read" {
  for_each = local.vending_subnets

  type = "Microsoft.Network/virtualNetworks/subnets@2024-01-01"
  resource_id = coalesce(
    try(azapi_resource.vending_subnets_agw[each.key].id, null),
    try(azapi_resource.vending_subnets_fw[each.key].id, null),
    try(azapi_resource.vending_subnets_private[each.key].id, null),
    try(azapi_resource.vending_subnets_protect[each.key].id, null)
  )

  response_export_values = ["*"]

  depends_on = [
    azapi_resource.vending_subnets_agw,
    azapi_resource.vending_subnets_fw,
    azapi_resource.vending_subnets_private,
    azapi_resource.vending_subnets_protect
  ]
}

# =============================================================================
# NSG
# =============================================================================

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

resource "azapi_resource" "vending_nsg_protect" {
  for_each = local.vending_nsg_protect

  type      = "Microsoft.Network/networkSecurityGroups@2024-01-01"
  name      = each.value.nsg_protect_name
  parent_id = "/subscriptions/${local.resolved_subscription_ids[each.key]}/resourceGroups/${each.value.vnet_rg_name}"
  location  = each.value.location
  tags      = each.value.tags

  schema_validation_enabled = false

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
            sourceAddressPrefix      = local.private_subnet_map[each.key].effective_address_prefix
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

  depends_on = [
    azapi_resource.vending_resource_groups,
    data.azapi_resource.vending_subnet_read
  ]

  lifecycle { ignore_changes = all }
}

# =============================================================================
# Route Table
# =============================================================================

resource "azapi_resource" "vending_rt_agw" {
  for_each = local.vending_rt_agw

  type      = "Microsoft.Network/routeTables@2024-01-01"
  name      = each.value.rt_agw_name
  parent_id = "/subscriptions/${local.resolved_subscription_ids[each.key]}/resourceGroups/${each.value.vnet_rg_name}"
  location  = each.value.location
  tags      = each.value.tags

  schema_validation_enabled = false

  body = {
    properties = {
      routes = [
        {
          name = "ToFW"
          properties = {
            addressPrefix    = local.private_subnet_map[each.key].effective_address_prefix
            nextHopType      = "VirtualAppliance"
            nextHopIpAddress = local.spoke_fw_ip_map[each.key]
          }
        }
      ]
    }
  }

  depends_on = [
    azapi_resource.vending_resource_groups,
    data.azapi_resource.vending_subnet_read
  ]

  lifecycle { ignore_changes = [body] }
}

resource "azapi_resource" "vending_rt_private" {
  for_each = local.vending_rt_private

  type      = "Microsoft.Network/routeTables@2024-01-01"
  name      = each.value.rt_private_name
  parent_id = "/subscriptions/${local.resolved_subscription_ids[each.key]}/resourceGroups/${each.value.vnet_rg_name}"
  location  = each.value.location
  tags      = each.value.tags

  schema_validation_enabled = false

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
        try(local.agw_subnet_map[each.key], null) != null && try(local.spoke_fw_ip_map[each.key], null) != null ? [
          {
            name = "toAFW"
            properties = {
              addressPrefix    = local.agw_subnet_map[each.key].effective_address_prefix
              nextHopType      = "VirtualAppliance"
              nextHopIpAddress = local.spoke_fw_ip_map[each.key]
            }
          }
        ] : []
      )
    }
  }

  depends_on = [
    azapi_resource.vending_resource_groups,
    data.azapi_resource.vending_subnet_read
  ]

  lifecycle { ignore_changes = [body] }
}

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

resource "azapi_update_resource" "vending_subnets_association" {
  for_each = local.vending_subnets

  type = "Microsoft.Network/virtualNetworks/subnets@2024-01-01"
  resource_id = coalesce(
    try(azapi_resource.vending_subnets_agw[each.key].id, null),
    try(azapi_resource.vending_subnets_fw[each.key].id, null),
    try(azapi_resource.vending_subnets_private[each.key].id, null),
    try(azapi_resource.vending_subnets_protect[each.key].id, null)
  )

  body = {
    properties = merge(
      {
        defaultOutboundAccess = false
        ipamPoolPrefixAllocations = [
          {
            numberOfIpAddresses = tostring(pow(2, 32 - each.value.prefix_length))
            pool = {
              id = each.value.ipam_pool_id
            }
          }
        ]
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
    data.azapi_resource.vending_subnet_read,
    azapi_resource.vending_nsg_private,
    azapi_resource.vending_nsg_protect,
    azapi_resource.vending_rt_agw,
    azapi_resource.vending_rt_private,
    azapi_resource.vending_rt_protect
  ]
}

# # =============================================================================
# # Spoke -> Hub Peering
# # =============================================================================

# resource "azapi_resource" "vending_spoke_to_hub" {
#   for_each = local.vending_with_peering

#   type      = "Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01"
#   name      = "peer-${each.value.vnet_name}-to-hub"
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

#   depends_on = [azapi_update_resource.vending_subnets_association]
# }

# # =============================================================================
# # Hub -> Spoke Peering
# # =============================================================================

# resource "azapi_resource" "vending_hub_to_spoke" {
#   for_each = local.vending_with_peering

#   type      = "Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-01-01"
#   name      = "peer-hub-to-${each.value.vnet_name}"
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

#   depends_on = [azapi_update_resource.vending_subnets_association]
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
