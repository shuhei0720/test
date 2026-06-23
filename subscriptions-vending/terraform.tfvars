# EA 課金アカウントID
billing_account_id = "71561797"

# EA 登録アカウントID
enrollment_account_id = "356163"

# リモートstateとして使用するストレージアカウントのリソースID
terraform_state_storage_account_id = ""

# 環境ごとのHubの情報
hub_environments = {
  prod = {
    hub_subscription_id                         = "04fa21cc-4c6b-47cc-83f3-2c2ef7e3c8c8"
    hub_virtual_network_id                      = "/subscriptions/04fa21cc-4c6b-47cc-83f3-2c2ef7e3c8c8/resourceGroups/rg-hub-prod-network-01/providers/Microsoft.Network/virtualNetworks/vnet-hub-prod-network-01"
    hub_virtual_network_name                    = "vnet-hub-prod-network-01"
    hub_virtual_network_parent_id               = "/subscriptions/04fa21cc-4c6b-47cc-83f3-2c2ef7e3c8c8/resourceGroups/rg-hub-prod-network-01"
    hub_firewall_private_ip                     = "10.204.0.4"
    hub_dns_servers                             = ["10.204.0.100"]
    hub_gateway_route_table_resource_group_name = "rg-hub-prod-network-01"
    hub_gateway_route_table_name                = "rt-hub-prod-vpngw-01"
  }

  stg = {
    hub_subscription_id                         = "03035d02-180e-40bf-8c54-8bc3bac3b28b"
    hub_virtual_network_id                      = "/subscriptions/03035d02-180e-40bf-8c54-8bc3bac3b28b/resourceGroups/rg-hub-stg-network-01/providers/Microsoft.Network/virtualNetworks/vnet-hub-stg-network-01"
    hub_virtual_network_name                    = "vnet-hub-stg-network-01"
    hub_virtual_network_parent_id               = "/subscriptions/03035d02-180e-40bf-8c54-8bc3bac3b28b/resourceGroups/rg-hub-stg-network-01"
    hub_firewall_private_ip                     = "10.44.0.4"
    hub_dns_servers                             = ["10.44.0.100"]
    hub_gateway_route_table_resource_group_name = "rg-hub-stg-network-01"
    hub_gateway_route_table_name                = "rt-hub-stg-gw-01"
  }

  dev = {
    # dev は DNS / ER / Gateway Route Table なし
    hub_subscription_id           = "5c717140-1b81-46bc-a254-167e978997d6"
    hub_virtual_network_id        = "/subscriptions/5c717140-1b81-46bc-a254-167e978997d6/resourceGroups/rg-hub-sand-network-01/providers/Microsoft.Network/virtualNetworks/vnet-hub-sand-network-01"
    hub_virtual_network_name      = "vnet-hub-sand-network-01"
    hub_virtual_network_parent_id = "/subscriptions/5c717140-1b81-46bc-a254-167e978997d6/resourceGroups/rg-hub-sand-network-01"
    hub_firewall_private_ip       = "10.186.0.4"
  }
}
