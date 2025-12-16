# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "resource_group_name" {
  description = "Name of the created resource group"
  value       = azurerm_resource_group.coder.name
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster"
  value       = azurerm_kubernetes_cluster.coder.name
}

output "aks_cluster_fqdn" {
  description = "FQDN of the AKS cluster"
  value       = azurerm_kubernetes_cluster.coder.fqdn
}

output "postgres_server_fqdn" {
  description = "FQDN of the PostgreSQL server"
  value       = azurerm_postgresql_flexible_server.coder.fqdn
  sensitive   = true
}

output "network_access_type" {
  description = "Network access type configured"
  value       = var.network_access_type
}

output "coder_load_balancer_ip" {
  description = "External IP address of the Coder LoadBalancer service (only if network_access_type=loadbalancer)"
  value       = var.network_access_type == "loadbalancer" ? try(data.kubernetes_service.coder.status[0].load_balancer[0].ingress[0].ip, "Pending") : "N/A - using ${var.network_access_type}"
}

output "coder_access_url" {
  description = "URL to access Coder"
  value = var.network_access_type == "loadbalancer" ? (
    var.coder_domain != "" ? "https://${var.coder_domain}" : "http://${try(data.kubernetes_service.coder.status[0].load_balancer[0].ingress[0].ip, "PENDING")}"
  ) : var.network_access_type == "wireguard" ? (
    "http://${cidrhost(var.wireguard_network_cidr, 1)}:80 (via WireGuard VPN)"
  ) : "Use: kubectl port-forward -n coder svc/coder 8080:80"
}

output "entra_id_app_client_id" {
  description = "Entra ID Application (Client) ID for OIDC"
  value       = azuread_application.coder.client_id
}

output "entra_id_app_object_id" {
  description = "Entra ID Application Object ID"
  value       = azuread_application.coder.object_id
}

output "entra_id_issuer_url" {
  description = "Entra ID OIDC Issuer URL"
  value       = "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
}

output "kubeconfig_command" {
  description = "Command to configure kubectl"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.coder.name} --name ${azurerm_kubernetes_cluster.coder.name} --overwrite-existing"
}

output "dns_configuration" {
  description = "DNS configuration instructions"
  value       = var.coder_domain != "" ? "Create an A record for ${var.coder_domain} pointing to ${try(data.kubernetes_service.coder.status[0].load_balancer[0].ingress[0].ip, "PENDING")}" : "No custom domain configured. Access Coder via the LoadBalancer IP."
}

# -----------------------------------------------------------------------------
# Sensitive Outputs (use terraform output -json for full details)
# -----------------------------------------------------------------------------

output "entra_id_app_client_secret" {
  description = "Entra ID Application Client Secret (sensitive)"
  value       = azuread_application_password.coder.value
  sensitive   = true
}

output "postgres_admin_password" {
  description = "PostgreSQL administrator password (sensitive)"
  value       = random_password.db_password.result
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Backup Outputs
# -----------------------------------------------------------------------------

output "backup_storage_account_name" {
  description = "Name of the backup storage account"
  value       = var.enable_backup_export ? azurerm_storage_account.backup[0].name : "Backup export not enabled"
}

output "backup_storage_account_connection_string" {
  description = "Connection string for backup storage account (sensitive)"
  value       = var.enable_backup_export ? azurerm_storage_account.backup[0].primary_connection_string : ""
  sensitive   = true
}

output "postgres_backup_info" {
  description = "PostgreSQL backup configuration"
  value = {
    retention_days        = var.backup_retention_days
    geo_redundant         = var.geo_redundant_backup
    point_in_time_restore = "Available for the last ${var.backup_retention_days} days"
    restore_command       = "az postgres flexible-server restore --resource-group ${azurerm_resource_group.coder.name} --name <new-server-name> --source-server ${azurerm_postgresql_flexible_server.coder.name} --restore-time <ISO8601-timestamp>"
  }
}

# -----------------------------------------------------------------------------
# External Provisioner Outputs
# -----------------------------------------------------------------------------

output "external_provisioner_enabled" {
  description = "Whether external provisioners are enabled"
  value       = var.enable_external_provisioners
}

output "provisioner_psk" {
  description = "Pre-shared key for external provisioner authentication (sensitive)"
  value       = var.enable_external_provisioners ? random_password.provisioner_psk.result : "External provisioners not enabled"
  sensitive   = true
}

output "provisioner_setup_command" {
  description = "Command to run on local machines to start a provisioner daemon"
  value       = var.enable_external_provisioners ? <<-EOT
    # Install Coder CLI and run provisioner daemon on a local machine:
    #
    # macOS/Linux:
    # curl -fsSL https://coder.com/install.sh | sh
    #
    # Windows (PowerShell):
    # winget install Coder.Coder
    #
    # Then run the provisioner daemon:
    # export CODER_URL="${var.coder_domain != "" ? "https://${var.coder_domain}" : "http://<LOADBALANCER_IP>"}"
    # coder provisionerd start --psk="$(terraform output -raw provisioner_psk)" --name="$(hostname)" --tag="owner=local,location=office"
    EOT
    : "External provisioners not enabled. Set enable_external_provisioners = true"
}

# -----------------------------------------------------------------------------
# WireGuard VPN Outputs
# -----------------------------------------------------------------------------

output "wireguard_enabled" {
  description = "Whether WireGuard VPN is enabled"
  value       = var.network_access_type == "wireguard"
}

output "wireguard_endpoint" {
  description = "WireGuard server endpoint (IP:port)"
  value       = var.network_access_type == "wireguard" ? "${try(data.kubernetes_service.wireguard[0].status[0].load_balancer[0].ingress[0].ip, "PENDING")}:${var.wireguard_port}" : "WireGuard not enabled"
}

output "wireguard_server_public_key" {
  description = "WireGuard server public key (generate from private key)"
  value       = var.network_access_type == "wireguard" ? "Run: echo '${random_password.wireguard_private_key[0].result}' | wg pubkey" : "WireGuard not enabled"
  sensitive   = true
}

output "wireguard_client_config_template" {
  description = "Template for WireGuard client configuration"
  value       = var.network_access_type == "wireguard" ? <<-EOT
    # WireGuard Client Configuration Template
    # Save as /etc/wireguard/coder.conf (Linux) or import into WireGuard app

    [Interface]
    PrivateKey = <YOUR_PRIVATE_KEY>
    Address = <YOUR_ASSIGNED_IP>/24
    DNS = 10.1.0.10

    [Peer]
    PublicKey = <SERVER_PUBLIC_KEY>
    Endpoint = ${try(data.kubernetes_service.wireguard[0].status[0].load_balancer[0].ingress[0].ip, "PENDING")}:${var.wireguard_port}
    AllowedIPs = ${var.wireguard_network_cidr}, 10.0.0.0/16, 10.1.0.0/16
    PersistentKeepalive = 25

    # After connecting, access Coder at:
    # http://coder.coder.svc.cluster.local or http://10.1.x.x (Coder ClusterIP)
    EOT
    : "WireGuard not enabled"
}
