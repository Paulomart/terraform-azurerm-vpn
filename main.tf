terraform {
  backend "azurerm" {}
  required_version = ">= 0.12.0"
  required_providers {
    azurerm = ">= 1.28.0"
  }
}

#
# Resource group
#

resource "azurerm_resource_group" "gw" {
  name     = var.resource_group_name
  location = var.location

  tags = var.tags
}

#
# Gateway
#

# module "vpn_key" {
#   source     = "../../secrets/cert"
#   name       = "vpn"
#   vault_name = "${data.terraform_remote_state.setup.vault_name}"
#   vault_id   = "${data.terraform_remote_state.setup.vault_id}"
# }

resource "random_string" "dns" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_public_ip" "gw" {
  name                = "${var.name}-gw-pip"
  location            = azurerm_resource_group.gw.location
  resource_group_name = azurerm_resource_group.gw.name

  allocation_method = "Static"
  domain_name_label = format("%sgw%s", lower(replace(var.name, "/[[:^alnum:]]/", "")), random_string.dns.result)
  sku               = "Standard"

  tags = var.tags
}

resource "azurerm_public_ip" "gw_aa" {
  count               = var.active_active ? 1 : 0
  name                = "${var.name}-gw-aa-pip"
  location            = azurerm_resource_group.gw.location
  resource_group_name = azurerm_resource_group.gw.name

  allocation_method = "Static"
  domain_name_label = format("%sgwaa%s", lower(replace(var.name, "/[[:^alnum:]]/", "")), random_string.dns.result)
  sku               = "Standard"

  tags = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "gw_pip" {
  count                      = var.log_analytics_workspace_id != null ? 1 : 0
  name                       = "gw-pip-log-analytics"
  target_resource_id         = azurerm_public_ip.gw.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  log {
    category = "DDoSProtectionNotifications"

    retention_policy {
      enabled = false
    }
  }

  log {
    category = "DDoSMitigationFlowLogs"

    retention_policy {
      enabled = false
    }
  }

  log {
    category = "DDoSMitigationReports"

    retention_policy {
      enabled = false
    }
  }

  metric {
    category = "AllMetrics"

    retention_policy {
      enabled = false
    }
  }
}

resource "azurerm_virtual_network_gateway" "gw" {
  name                = "${var.name}-gw"
  location            = azurerm_resource_group.gw.location
  resource_group_name = azurerm_resource_group.gw.name

  type     = "Vpn"
  vpn_type = "RouteBased"

  active_active = var.active_active
  enable_bgp    = var.enable_bgp
  sku           = var.sku

  ip_configuration {
    name                          = "${var.name}-gw-config"
    public_ip_address_id          = azurerm_public_ip.gw.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = var.subnet_id
  }

  dynamic "ip_configuration" {
    for_each = var.active_active ? [true] : []
    iterator = ic
    content {
      name                          = "${var.name}-gw-aa-config"
      public_ip_address_id          = azurerm_public_ip.gw_aa.id
      private_ip_address_allocation = "Dynamic"
      subnet_id                     = var.subnet_id
    }
  }

  dynamic "vpn_client_configuration" {
    for_each = var.client_configuration != null ? [var.client_configuration] : []
    iterator = vpn
    content {
      address_space = [vpn.address_space]

      root_certificate {
        name = "VPN-Certificate"

        public_cert_data = "TODO"
      }

      vpn_client_protocols = vpn.protocols
    }
  }

  # TODO Buggy... keep want to change this attribute
  lifecycle {
    ignore_changes = ["vpn_client_configuration[0].root_certificate"]
  }

  tags = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "gw" {
  count                      = var.log_analytics_workspace_id != null ? 1 : 0
  name                       = "gw-analytics"
  target_resource_id         = azurerm_virtual_network_gateway.gw.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  log {
    category = "GatewayDiagnosticLog"

    retention_policy {
      enabled = false
    }
  }

  log {
    category = "TunnelDiagnosticLog"

    retention_policy {
      enabled = false
    }
  }

  log {
    category = "RouteDiagnosticLog"

    retention_policy {
      enabled = false
    }
  }

  log {
    category = "IKEDiagnosticLog"

    retention_policy {
      enabled = false
    }
  }

  log {
    category = "P2SDiagnosticLog"

    retention_policy {
      enabled = false
    }
  }

  metric {
    category = "AllMetrics"

    retention_policy {
      enabled = false
    }
  }
}

resource "azurerm_local_network_gateway" "local" {
  count               = length(var.local_networks)
  name                = "${var.local_networks[count.index].name}-lng"
  resource_group_name = azurerm_resource_group.gw.name
  location            = azurerm_resource_group.gw.location
  gateway_address     = var.local_networks[count.index].gateway_address
  address_space       = var.local_networks[count.index].address_space

  tags = var.tags
}

resource "azurerm_virtual_network_gateway_connection" "local" {
  count               = length(var.local_networks)
  name                = "${var.local_networks[count.index].name}-lngc"
  location            = azurerm_resource_group.gw.location
  resource_group_name = azurerm_resource_group.gw.name

  type                       = var.local_networks[count.index].type
  virtual_network_gateway_id = azurerm_virtual_network_gateway.gw.id
  local_network_gateway_id   = azurerm_local_network_gateway.local[count.index].id

  shared_key = var.local_networks[count.index].shared_key

  tags = var.tags
}