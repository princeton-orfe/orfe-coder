# -----------------------------------------------------------------------------
# Azure Authentication Variables
# -----------------------------------------------------------------------------

variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure AD Tenant ID (Entra ID)"
  type        = string
}

variable "client_id" {
  description = "Service Principal Client ID"
  type        = string
}

variable "client_secret" {
  description = "Service Principal Client Secret"
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# General Configuration
# -----------------------------------------------------------------------------

variable "resource_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "coder"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus"
}

variable "department_name" {
  description = "Department name for tagging and OIDC display"
  type        = string
  default     = "Engineering"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Production"
    ManagedBy   = "Terraform"
    Application = "Coder"
  }
}

# -----------------------------------------------------------------------------
# AKS Configuration
# -----------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "Kubernetes version for AKS cluster"
  type        = string
  default     = "1.28"
}

variable "node_count" {
  description = "Initial number of nodes in the AKS cluster"
  type        = number
  default     = 1
}

variable "node_vm_size" {
  description = "VM size for AKS nodes"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "enable_autoscaling" {
  description = "Enable cluster autoscaling"
  type        = bool
  default     = true
}

variable "min_node_count" {
  description = "Minimum number of nodes when autoscaling is enabled"
  type        = number
  default     = 1
}

variable "max_node_count" {
  description = "Maximum number of nodes when autoscaling is enabled"
  type        = number
  default     = 5
}

variable "aks_admin_group_ids" {
  description = "List of Azure AD group IDs that will have admin access to the AKS cluster"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# PostgreSQL Configuration
# -----------------------------------------------------------------------------

variable "postgres_sku" {
  description = "PostgreSQL Flexible Server SKU"
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "PostgreSQL storage in MB"
  type        = number
  default     = 32768 # 32 GB
}

# -----------------------------------------------------------------------------
# Backup Configuration
# -----------------------------------------------------------------------------

variable "backup_retention_days" {
  description = "Number of days to retain PostgreSQL automated backups (7-35)"
  type        = number
  default     = 14

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "Backup retention must be between 7 and 35 days."
  }
}

variable "geo_redundant_backup" {
  description = "Enable geo-redundant backups for PostgreSQL (cross-region disaster recovery)"
  type        = bool
  default     = false
}

variable "enable_backup_export" {
  description = "Enable backup export to Azure Blob Storage for long-term retention"
  type        = bool
  default     = true
}

variable "backup_blob_retention_days" {
  description = "Number of days to retain backup exports in blob storage"
  type        = number
  default     = 365
}

# -----------------------------------------------------------------------------
# External Provisioner Configuration
# -----------------------------------------------------------------------------

variable "enable_external_provisioners" {
  description = "Enable external provisioner daemons (for local laptops/desktops)"
  type        = bool
  default     = false
}

variable "provisioner_tags" {
  description = "Default tags for external provisioner organization (e.g., 'location:office,type:desktop')"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Coder Configuration
# -----------------------------------------------------------------------------

variable "coder_version" {
  description = "Coder Helm chart version"
  type        = string
  default     = "2.16.0"
}

variable "coder_domain" {
  description = "Domain name for Coder (e.g., coder.example.com). Leave empty to use LoadBalancer IP."
  type        = string
  default     = ""
}

variable "coder_wildcard_domain" {
  description = "Wildcard domain for Coder workspaces (e.g., coder.example.com for *.coder.example.com)"
  type        = string
  default     = ""
}

variable "coder_experiments" {
  description = "Comma-separated list of Coder experiments to enable"
  type        = string
  default     = ""
}

variable "enable_ingress" {
  description = "Enable Kubernetes Ingress for Coder (requires domain)"
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Network Access Configuration
# -----------------------------------------------------------------------------

variable "network_access_type" {
  description = "How to expose Coder: 'loadbalancer' (public IP), 'wireguard' (VPN), or 'clusterip' (kubectl port-forward only)"
  type        = string
  default     = "loadbalancer"

  validation {
    condition     = contains(["loadbalancer", "wireguard", "clusterip"], var.network_access_type)
    error_message = "network_access_type must be 'loadbalancer', 'wireguard', or 'clusterip'."
  }
}

variable "wireguard_network_cidr" {
  description = "CIDR for WireGuard VPN network"
  type        = string
  default     = "10.10.0.0/24"
}

variable "wireguard_port" {
  description = "UDP port for WireGuard VPN"
  type        = number
  default     = 51820
}

variable "wireguard_peers" {
  description = "List of WireGuard peers (team members). Each peer needs a name and will be assigned an IP."
  type = list(object({
    name       = string
    public_key = string
  }))
  default = []
}

# -----------------------------------------------------------------------------
# Entra ID (Azure AD) Configuration
# -----------------------------------------------------------------------------

variable "allowed_email_domains" {
  description = "List of allowed email domains for OIDC authentication"
  type        = list(string)
  default     = []
}

variable "enable_group_sync" {
  description = "Enable group synchronization from Entra ID to Coder"
  type        = bool
  default     = false
}
