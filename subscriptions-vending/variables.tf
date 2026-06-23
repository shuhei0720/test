variable "subscription_vending_path" {
  description = "サブスクリプション定義 YAML ファイルのディレクトリパス"
  type        = string
  default     = "./subscriptions"
}

variable "billing_account_id" {
  description = "EA の billingAccountId"
  type        = string
}

variable "enrollment_account_id" {
  description = "EA の enrollmentAccountId"
  type        = string
}

variable "terraform_state_storage_account_id" {
  description = "Terraform state Storage Account のリソースID"
  type        = string
  default     = ""
}

variable "hub_environments" {
  description = "environment(prod/stg/dev) ごとの Hub 接続情報"
  type = map(object({
    hub_subscription_id                         = string
    hub_virtual_network_id                      = string
    hub_virtual_network_name                    = string
    hub_virtual_network_parent_id               = string
    hub_firewall_private_ip                     = string
    hub_dns_servers                             = optional(list(string))
    hub_gateway_route_table_resource_group_name = optional(string)
    hub_gateway_route_table_name                = optional(string)
  }))
}
