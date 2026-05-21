terraform {
  # Terraform 本体の対応バージョン
  required_version = ">= 1.12"

  required_providers {
    # Azure リソース作成用
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    # Azure REST API を直接たたく用
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }

    # Azure AD / Entra ID のユーザー参照用
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }

    # リソース作成後の待機用
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  resource_provider_registrations = "none"
  features {}
}

provider "azapi" {}

provider "azuread" {}
