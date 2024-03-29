# A Terraform module to create a subset of cloud components
# Copyright (C) 2022 IQ3 CLOUD Skaylink GmbH

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version. 

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# For questions and contributions please contact info@iq3cloud.com
# https://github.com/iq3cloud-dev/terraform-azurerm-iq3-aks

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "2.1.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~>1.10.0"
    }
  }
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.kubernetes.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.kubernetes.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.kubernetes.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.kubernetes.kube_config.0.cluster_ca_certificate)
  load_config_file       = false
}

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.kubernetes.kube_config.0.host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.kubernetes.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.kubernetes.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.kubernetes.kube_config.0.cluster_ca_certificate)
  }
}

resource "azurerm_kubernetes_cluster" "kubernetes" {
  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count
    ]
  }

  name                = var.name
  location            = data.azurerm_resource_group.resourcegroup.location
  resource_group_name = data.azurerm_resource_group.resourcegroup.name
  dns_prefix          = var.name
  kubernetes_version  = var.aks_configuration.kubernetes_version

  linux_profile {
    admin_username = var.aks_node_authentication.node_admin_username

    ssh_key {
      # remove any new lines using the replace interpolation function
      key_data = replace(var.aks_node_authentication.node_admin_ssh_public, "\n", "")
    }
  }

  default_node_pool {
    name                 = "agentpool"
    type                 = "VirtualMachineScaleSets"
    node_count           = var.aks_configuration.kubernetes_node_count
    enable_auto_scaling  = var.aks_configuration.kubernetes_enable_auto_scaling
    min_count            = var.aks_configuration.kubernetes_min_node_count
    max_count            = var.aks_configuration.kubernetes_max_node_count
    vm_size              = var.aks_configuration.vm_size
    os_disk_size_gb      = var.aks_configuration.os_disk_size_gb
    vnet_subnet_id       = var.aks_subnet_id
    orchestrator_version = var.aks_configuration.kubernetes_version
  }

  network_profile {
    network_plugin    = var.aks_configuration.network_plugin
    network_policy    = var.aks_configuration.network_policy
    load_balancer_sku = "basic"
  }

  role_based_access_control {
    enabled = true
  }

  dynamic "service_principal" {
    for_each = var.use_managed_identity ? [] : ["SP"]
    content {
      client_id     = data.azurerm_key_vault_secret.aksspid[0].value
      client_secret = data.azurerm_key_vault_secret.aksspsecret[0].value
    }
  }

  dynamic "identity" {
    for_each = var.use_managed_identity ? ["SystemAssigned"] : []
    content {
      type = "SystemAssigned"
    }
  }

  addon_profile {
    dynamic "oms_agent" {
      for_each = var.aks_addons.aks_log_analytics_workspace_id == "" ? [] : ["create"]
      content {
        enabled                    = true
        log_analytics_workspace_id = var.aks_addons.aks_log_analytics_workspace_id
      }
    }
    kube_dashboard {
      enabled = var.aks_addons.enable_kubernetes_dashboard
    }
    azure_policy {
      enabled = var.aks_addons.enable_azure_policy
    }

  }
}

# Create Static Public IP Address to be used by Nginx Ingress
resource "azurerm_public_ip" "nginx_ingress" {
  count               = var.ingress_controller == true ? 1 : 0
  name                = "${var.name}-public-IP"
  location            = azurerm_kubernetes_cluster.kubernetes.location
  resource_group_name = azurerm_kubernetes_cluster.kubernetes.node_resource_group
  allocation_method   = "Static"
  domain_name_label   = var.ip_domain_name_label
}

resource "helm_release" "nginx_ingress_controller" {
  count = var.ingress_controller == true ? 1 : 0

  name       = "nginx-ingress-controller"
  repository = "https://helm.nginx.com/stable"
  chart      = "nginx-ingress"

  set {
    name  = "controller.replicaCount"
    value = 2
  }
  set {
    name  = "controller.service.loadBalancerIP"
    value = azurerm_public_ip.nginx_ingress[0].ip_address
  }
}