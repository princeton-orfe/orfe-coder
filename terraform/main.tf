# Coder on Azure AKS with Entra ID Authentication
# Automated deployment for departmental use

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.80"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.45"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.24"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# -----------------------------------------------------------------------------
# Providers
# -----------------------------------------------------------------------------

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  client_id       = var.client_id
  client_secret   = var.client_secret
}

provider "azuread" {
  tenant_id     = var.tenant_id
  client_id     = var.client_id
  client_secret = var.client_secret
}

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.coder.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.coder.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.coder.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.coder.kube_config[0].cluster_ca_certificate)
  }
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.coder.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.coder.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.coder.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.coder.kube_config[0].cluster_ca_certificate)
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

data "azuread_client_config" "current" {}

# -----------------------------------------------------------------------------
# Random Resources for Secure Defaults
# -----------------------------------------------------------------------------

resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "provisioner_psk" {
  length  = 64
  special = false
}

resource "random_id" "suffix" {
  byte_length = 4
}

# -----------------------------------------------------------------------------
# Resource Group
# -----------------------------------------------------------------------------

resource "azurerm_resource_group" "coder" {
  name     = "${var.resource_prefix}-rg-${random_id.suffix.hex}"
  location = var.location

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Entra ID (Azure AD) Application Registration for Coder OIDC
# -----------------------------------------------------------------------------

resource "azuread_application" "coder" {
  display_name = "${var.resource_prefix}-coder-app"
  owners       = [data.azuread_client_config.current.object_id]

  sign_in_audience = "AzureADMyOrg"

  web {
    redirect_uris = [
      "https://${var.coder_domain}/api/v2/users/oidc/callback",
      "http://localhost:3000/api/v2/users/oidc/callback" # For local development
    ]

    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = true
    }
  }

  api {
    requested_access_token_version = 2
  }

  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph

    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d" # User.Read
      type = "Scope"
    }
    resource_access {
      id   = "64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0" # email
      type = "Scope"
    }
    resource_access {
      id   = "14dad69e-099b-42c9-810b-d002981feec1" # profile
      type = "Scope"
    }
    resource_access {
      id   = "37f7f235-527c-4136-accd-4a02d197296e" # openid
      type = "Scope"
    }
  }

  optional_claims {
    id_token {
      name                  = "email"
      essential             = true
      additional_properties = []
    }
    id_token {
      name                  = "preferred_username"
      essential             = true
      additional_properties = []
    }
    id_token {
      name                  = "groups"
      essential             = false
      additional_properties = ["emit_as_roles"]
    }
  }

  group_membership_claims = var.enable_group_sync ? ["SecurityGroup"] : []

  tags = ["Coder", "Development", var.department_name]
}

resource "azuread_application_password" "coder" {
  application_id = azuread_application.coder.id
  display_name   = "coder-oidc-secret"
  end_date       = timeadd(timestamp(), "8760h") # 1 year
}

resource "azuread_service_principal" "coder" {
  client_id                    = azuread_application.coder.client_id
  app_role_assignment_required = false
  owners                       = [data.azuread_client_config.current.object_id]
}

# -----------------------------------------------------------------------------
# Virtual Network
# -----------------------------------------------------------------------------

resource "azurerm_virtual_network" "coder" {
  name                = "${var.resource_prefix}-vnet"
  location            = azurerm_resource_group.coder.location
  resource_group_name = azurerm_resource_group.coder.name
  address_space       = ["10.0.0.0/16"]

  tags = var.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.coder.name
  virtual_network_name = azurerm_virtual_network.coder.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "postgres" {
  name                 = "postgres-subnet"
  resource_group_name  = azurerm_resource_group.coder.name
  virtual_network_name = azurerm_virtual_network.coder.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "postgresql-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# -----------------------------------------------------------------------------
# Azure Database for PostgreSQL Flexible Server
# -----------------------------------------------------------------------------

resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.resource_prefix}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.coder.name

  tags = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-dns-link"
  resource_group_name   = azurerm_resource_group.coder.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.coder.id
}

resource "azurerm_postgresql_flexible_server" "coder" {
  name                          = "${var.resource_prefix}-postgres-${random_id.suffix.hex}"
  resource_group_name           = azurerm_resource_group.coder.name
  location                      = azurerm_resource_group.coder.location
  version                       = "15"
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  administrator_login           = "coderadmin"
  administrator_password        = random_password.db_password.result
  zone                          = "1"
  storage_mb                    = var.postgres_storage_mb
  sku_name                      = var.postgres_sku
  backup_retention_days         = var.backup_retention_days
  geo_redundant_backup_enabled  = var.geo_redundant_backup
  public_network_access_enabled = false

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Backup Storage Account (for long-term retention and exports)
# -----------------------------------------------------------------------------

resource "azurerm_storage_account" "backup" {
  count = var.enable_backup_export ? 1 : 0

  name                     = "${replace(var.resource_prefix, "-", "")}backup${random_id.suffix.hex}"
  resource_group_name      = azurerm_resource_group.coder.name
  location                 = azurerm_resource_group.coder.location
  account_tier             = "Standard"
  account_replication_type = var.geo_redundant_backup ? "GRS" : "LRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = var.backup_blob_retention_days
    }

    container_delete_retention_policy {
      days = var.backup_blob_retention_days
    }
  }

  tags = var.tags
}

resource "azurerm_storage_container" "db_backups" {
  count = var.enable_backup_export ? 1 : 0

  name                  = "database-backups"
  storage_account_name  = azurerm_storage_account.backup[0].name
  container_access_type = "private"
}

resource "azurerm_storage_container" "coder_exports" {
  count = var.enable_backup_export ? 1 : 0

  name                  = "coder-exports"
  storage_account_name  = azurerm_storage_account.backup[0].name
  container_access_type = "private"
}

# Storage account lifecycle management for backup retention
resource "azurerm_storage_management_policy" "backup_lifecycle" {
  count = var.enable_backup_export ? 1 : 0

  storage_account_id = azurerm_storage_account.backup[0].id

  rule {
    name    = "backup-retention"
    enabled = true

    filters {
      blob_types = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 30
        tier_to_archive_after_days_since_modification_greater_than = 90
        delete_after_days_since_modification_greater_than          = var.backup_blob_retention_days
      }
      snapshot {
        delete_after_days_since_creation_greater_than = var.backup_blob_retention_days
      }
    }
  }
}

resource "azurerm_postgresql_flexible_server_database" "coder" {
  name      = "coder"
  server_id = azurerm_postgresql_flexible_server.coder.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# -----------------------------------------------------------------------------
# Azure Kubernetes Service
# -----------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "coder" {
  name                = "${var.resource_prefix}-aks-${random_id.suffix.hex}"
  location            = azurerm_resource_group.coder.location
  resource_group_name = azurerm_resource_group.coder.name
  dns_prefix          = "${var.resource_prefix}-coder"
  kubernetes_version  = var.kubernetes_version

  default_node_pool {
    name                = "default"
    node_count          = var.node_count
    vm_size             = var.node_vm_size
    vnet_subnet_id      = azurerm_subnet.aks.id
    enable_auto_scaling = var.enable_autoscaling
    min_count           = var.enable_autoscaling ? var.min_node_count : null
    max_count           = var.enable_autoscaling ? var.max_node_count : null

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "calico"
    load_balancer_sku = "standard"
    service_cidr      = "10.1.0.0/16"
    dns_service_ip    = "10.1.0.10"
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    managed                = true
    tenant_id              = var.tenant_id
    admin_group_object_ids = var.aks_admin_group_ids
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Kubernetes Namespace
# -----------------------------------------------------------------------------

resource "kubernetes_namespace" "coder" {
  metadata {
    name = "coder"
    labels = {
      "app.kubernetes.io/name"       = "coder"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [azurerm_kubernetes_cluster.coder]
}

# -----------------------------------------------------------------------------
# Kubernetes Secret for Database
# -----------------------------------------------------------------------------

resource "kubernetes_secret" "coder_db" {
  metadata {
    name      = "coder-db-credentials"
    namespace = kubernetes_namespace.coder.metadata[0].name
  }

  data = {
    url = "postgres://coderadmin:${urlencode(random_password.db_password.result)}@${azurerm_postgresql_flexible_server.coder.fqdn}:5432/coder?sslmode=require"
  }

  depends_on = [kubernetes_namespace.coder]
}

# -----------------------------------------------------------------------------
# Kubernetes Secret for OIDC
# -----------------------------------------------------------------------------

resource "kubernetes_secret" "coder_oidc" {
  metadata {
    name      = "coder-oidc-credentials"
    namespace = kubernetes_namespace.coder.metadata[0].name
  }

  data = {
    client-id     = azuread_application.coder.client_id
    client-secret = azuread_application_password.coder.value
  }

  depends_on = [kubernetes_namespace.coder]
}

# -----------------------------------------------------------------------------
# Kubernetes Secret for External Provisioners (PSK Authentication)
# -----------------------------------------------------------------------------

resource "kubernetes_secret" "provisioner_psk" {
  count = var.enable_external_provisioners ? 1 : 0

  metadata {
    name      = "coder-provisioner-psk"
    namespace = kubernetes_namespace.coder.metadata[0].name
  }

  data = {
    psk = random_password.provisioner_psk.result
  }

  depends_on = [kubernetes_namespace.coder]
}

# -----------------------------------------------------------------------------
# Coder Helm Release
# -----------------------------------------------------------------------------

resource "helm_release" "coder" {
  name       = "coder"
  repository = "https://helm.coder.com/v2"
  chart      = "coder"
  version    = var.coder_version
  namespace  = kubernetes_namespace.coder.metadata[0].name

  values = [
    yamlencode({
      coder = {
        env = concat([
          {
            name = "CODER_PG_CONNECTION_URL"
            valueFrom = {
              secretKeyRef = {
                name = kubernetes_secret.coder_db.metadata[0].name
                key  = "url"
              }
            }
          },
          {
            name  = "CODER_ACCESS_URL"
            value = var.coder_domain != "" ? "https://${var.coder_domain}" : ""
          },
          {
            name  = "CODER_WILDCARD_ACCESS_URL"
            value = var.coder_wildcard_domain != "" ? "*.${var.coder_wildcard_domain}" : ""
          },
          # Entra ID OIDC Configuration
          {
            name  = "CODER_OIDC_ISSUER_URL"
            value = "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
          },
          {
            name = "CODER_OIDC_CLIENT_ID"
            valueFrom = {
              secretKeyRef = {
                name = kubernetes_secret.coder_oidc.metadata[0].name
                key  = "client-id"
              }
            }
          },
          {
            name = "CODER_OIDC_CLIENT_SECRET"
            valueFrom = {
              secretKeyRef = {
                name = kubernetes_secret.coder_oidc.metadata[0].name
                key  = "client-secret"
              }
            }
          },
          {
            name  = "CODER_OIDC_EMAIL_DOMAIN"
            value = join(",", var.allowed_email_domains)
          },
          {
            name  = "CODER_OIDC_SCOPES"
            value = "openid,profile,email"
          },
          {
            name  = "CODER_OIDC_IGNORE_EMAIL_VERIFIED"
            value = "true" # Azure AD doesn't always return email_verified
          },
          {
            name  = "CODER_OIDC_USERNAME_FIELD"
            value = "preferred_username"
          },
          {
            name  = "CODER_OIDC_SIGN_IN_TEXT"
            value = "Sign in with ${var.department_name} Entra ID"
          },
          {
            name  = "CODER_OIDC_ICON_URL"
            value = "https://upload.wikimedia.org/wikipedia/commons/a/a8/Microsoft_Azure_Logo.svg"
          },
          # Telemetry and features
          {
            name  = "CODER_TELEMETRY_ENABLE"
            value = "false"
          },
          {
            name  = "CODER_EXPERIMENTS"
            value = var.coder_experiments
          }
        ],
        # Group sync configuration
        var.enable_group_sync ? [
          {
            name  = "CODER_OIDC_GROUP_FIELD"
            value = "groups"
          },
          {
            name  = "CODER_OIDC_GROUP_AUTO_CREATE"
            value = "true"
          }
        ] : [],
        # External provisioner configuration
        var.enable_external_provisioners ? [
          {
            name = "CODER_PROVISIONER_DAEMON_PSK"
            valueFrom = {
              secretKeyRef = {
                name = kubernetes_secret.provisioner_psk[0].metadata[0].name
                key  = "psk"
              }
            }
          }
        ] : [])

        service = {
          type = var.network_access_type == "loadbalancer" ? "LoadBalancer" : "ClusterIP"
          annotations = var.network_access_type == "loadbalancer" ? {
            "service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path" = "/healthz"
          } : {}
        }

        ingress = {
          enable = var.enable_ingress
          host   = var.coder_domain
          tls = {
            enable = var.enable_ingress
          }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_secret.coder_db,
    kubernetes_secret.coder_oidc,
    azurerm_postgresql_flexible_server_database.coder
  ]
}

# -----------------------------------------------------------------------------
# WireGuard VPN Server (optional - for secure access without public LoadBalancer)
# -----------------------------------------------------------------------------

resource "random_password" "wireguard_private_key" {
  count   = var.network_access_type == "wireguard" ? 1 : 0
  length  = 44
  special = false
}

resource "kubernetes_namespace" "wireguard" {
  count = var.network_access_type == "wireguard" ? 1 : 0

  metadata {
    name = "wireguard"
    labels = {
      "app.kubernetes.io/name"       = "wireguard"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [azurerm_kubernetes_cluster.coder]
}

resource "kubernetes_secret" "wireguard_config" {
  count = var.network_access_type == "wireguard" ? 1 : 0

  metadata {
    name      = "wireguard-config"
    namespace = kubernetes_namespace.wireguard[0].metadata[0].name
  }

  data = {
    "wg0.conf" = templatefile("${path.module}/wireguard.conf.tpl", {
      server_private_key = random_password.wireguard_private_key[0].result
      server_address     = cidrhost(var.wireguard_network_cidr, 1)
      server_cidr        = var.wireguard_network_cidr
      listen_port        = var.wireguard_port
      peers              = var.wireguard_peers
      peer_ips           = { for i, peer in var.wireguard_peers : peer.name => cidrhost(var.wireguard_network_cidr, i + 2) }
      coder_service_ip   = "coder.coder.svc.cluster.local"
    })
  }
}

resource "kubernetes_deployment" "wireguard" {
  count = var.network_access_type == "wireguard" ? 1 : 0

  metadata {
    name      = "wireguard"
    namespace = kubernetes_namespace.wireguard[0].metadata[0].name
    labels = {
      app = "wireguard"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "wireguard"
      }
    }

    template {
      metadata {
        labels = {
          app = "wireguard"
        }
      }

      spec {
        container {
          name  = "wireguard"
          image = "linuxserver/wireguard:latest"

          port {
            container_port = var.wireguard_port
            protocol       = "UDP"
          }

          env {
            name  = "PUID"
            value = "1000"
          }
          env {
            name  = "PGID"
            value = "1000"
          }
          env {
            name  = "TZ"
            value = "UTC"
          }

          volume_mount {
            name       = "config"
            mount_path = "/config/wg_confs"
          }

          security_context {
            capabilities {
              add = ["NET_ADMIN", "SYS_MODULE"]
            }
          }
        }

        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret.wireguard_config[0].metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "wireguard" {
  count = var.network_access_type == "wireguard" ? 1 : 0

  metadata {
    name      = "wireguard"
    namespace = kubernetes_namespace.wireguard[0].metadata[0].name
  }

  spec {
    type = "LoadBalancer"

    selector = {
      app = "wireguard"
    }

    port {
      port        = var.wireguard_port
      target_port = var.wireguard_port
      protocol    = "UDP"
    }
  }
}

data "kubernetes_service" "wireguard" {
  count = var.network_access_type == "wireguard" ? 1 : 0

  metadata {
    name      = "wireguard"
    namespace = kubernetes_namespace.wireguard[0].metadata[0].name
  }

  depends_on = [kubernetes_service.wireguard]
}

# -----------------------------------------------------------------------------
# Get Load Balancer IP (for DNS configuration)
# -----------------------------------------------------------------------------

data "kubernetes_service" "coder" {
  metadata {
    name      = "coder"
    namespace = kubernetes_namespace.coder.metadata[0].name
  }

  depends_on = [helm_release.coder]
}
