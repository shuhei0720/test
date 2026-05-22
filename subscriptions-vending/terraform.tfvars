# EA 課金アカウントID
billing_account_id = "71561797"

# jira申請の請求先会社 => 登録アカウントID へ変換
enrollment_account_id_map = {
  "パーソルホールディングス株式会社"        = "356163"
  "パーソルキャリア株式会社"            = "356251"
  "パーソルマーケティング株式会社"         = "356342"
  "パーソルエクセルHRパートナーズ株式会社"    = "356445"
  "パーソルクロステクノロジー株式会社"       = "356446"
  "パーソルテンプスタッフ株式会社"         = "356447"
  "パーソルファクトリーパートナーズ株式会社"    = "356448"
  "パーソルプロセス＆テクノロジー株式会社"     = "356449"
  "パーソルAVCテクノロジー株式会社"       = "360884"
  "株式会社パーソル総合研究所"           = "366453"
  "パーソルダイバース株式会社"           = "368661"
  "パーソルワークスイッチコンサルティング株式会社" = "372441"
  "パーソルワークスデザイン株式会社"        = "374494"
  "パーソルビジネスプロセスデザイン株式会社"    = "374763"
  "パーソルエスアンドアイ株式会社"         = "402957"
}

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
    spoke_ipam_pool_id                          = "/subscriptions/bec80a1b-7f04-462d-9299-149138ee0e8a/resourceGroups/nwtest/providers/Microsoft.Network/networkManagers/afasdfasdf/ipamPools/safdasdf"
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
    spoke_ipam_pool_id                          = "/subscriptions/bec80a1b-7f04-462d-9299-149138ee0e8a/resourceGroups/nwtest/providers/Microsoft.Network/networkManagers/afasdfasdf/ipamPools/safdasdf"
  }

  dev = {
    # dev は DNS / ER / Gateway Route Table なし
    hub_subscription_id           = "5c717140-1b81-46bc-a254-167e978997d6"
    hub_virtual_network_id        = "/subscriptions/5c717140-1b81-46bc-a254-167e978997d6/resourceGroups/rg-hub-sand-network-01/providers/Microsoft.Network/virtualNetworks/vnet-hub-sand-network-01"
    hub_virtual_network_name      = "vnet-hub-sand-network-01"
    hub_virtual_network_parent_id = "/subscriptions/5c717140-1b81-46bc-a254-167e978997d6/resourceGroups/rg-hub-sand-network-01"
    hub_firewall_private_ip       = "10.186.0.4"
    spoke_ipam_pool_id            = "/subscriptions/bec80a1b-7f04-462d-9299-149138ee0e8a/resourceGroups/nwtest/providers/Microsoft.Network/networkManagers/afasdfasdf/ipamPools/safdasdf"
  }
}
