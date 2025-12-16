#!/usr/bin/env bash
# Coder on Azure AKS - Interactive Configuration Script
# Generates terraform.tfvars based on user input
# Compatible with Bash 3.2+ (macOS default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
TFVARS_FILE="${TERRAFORM_DIR}/terraform.tfvars"

# Colors and formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Unicode characters
CHECK="✓"
CROSS="✗"
ARROW="→"
BULLET="•"
STAR="★"

# Configuration values (individual variables for Bash 3.2 compatibility)
CFG_subscription_id=""
CFG_tenant_id=""
CFG_client_id=""
CFG_client_secret=""
CFG_resource_group_name=""
CFG_department_name=""
CFG_location=""
CFG_node_vm_size=""
CFG_node_count=""
CFG_enable_autoscaling=""
CFG_min_node_count=""
CFG_max_node_count=""
CFG_kubernetes_version=""
CFG_postgres_sku=""
CFG_postgres_storage_mb=""
CFG_backup_retention_days=""
CFG_geo_redundant_backup=""
CFG_enable_backup_export=""
CFG_backup_blob_retention_days=""
CFG_network_access_type=""
CFG_wireguard_port=""
CFG_wireguard_network_cidr=""
CFG_enable_external_provisioners=""
CFG_coder_domain=""
CFG_coder_wildcard_domain=""
CFG_enable_ingress=""
CFG_email_domains=""
CFG_enable_group_sync=""

# Helper functions
print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║${NC}          ${MAGENTA}${BOLD}Coder on Azure AKS - Configuration${NC}              ${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    local title="$1"
    local icon="${2:-${STAR}}"
    echo ""
    echo -e "${BLUE}${BOLD}${icon} ${title}${NC}"
    echo -e "${DIM}────────────────────────────────────────────────────────────${NC}"
}

print_step() {
    echo -e "  ${CYAN}${ARROW}${NC} $1"
}

print_success() {
    echo -e "  ${GREEN}${CHECK}${NC} $1"
}

print_warning() {
    echo -e "  ${YELLOW}!${NC} $1"
}

print_error() {
    echo -e "  ${RED}${CROSS}${NC} $1"
}

print_info() {
    echo -e "  ${DIM}${BULLET} $1${NC}"
}

# Validate UUID format
validate_uuid() {
    local uuid="$1"
    if [[ "${uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        return 0
    fi
    return 1
}

# Check if Azure CLI is available and logged in
check_azure_cli() {
    print_section "Checking Prerequisites" "🔍"

    if ! command -v az &> /dev/null; then
        print_warning "Azure CLI not found"
        print_info "Install from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        return 1
    fi
    print_success "Azure CLI installed"

    if ! command -v terraform &> /dev/null; then
        print_warning "Terraform not found"
        print_info "Install from: https://developer.hashicorp.com/terraform/install"
    else
        print_success "Terraform installed"
    fi

    # Check if logged in
    if az account show &> /dev/null; then
        local account_name
        account_name=$(az account show --query "name" -o tsv 2>/dev/null)
        print_success "Logged into Azure: ${account_name}"
        return 0
    else
        print_warning "Not logged into Azure CLI"
        echo ""
        echo -ne "  ${BOLD}Would you like to login now?${NC} ${DIM}[Y/n]${NC}: "
        read -r login_answer
        echo ""

        if [[ ! "${login_answer}" =~ ^[Nn]$ ]]; then
            az login
            return $?
        fi
        return 1
    fi
}

# Try to auto-detect Azure values
auto_detect_azure() {
    print_section "Auto-detecting Azure Configuration" "🔎"

    # Get subscription
    local sub_id sub_name
    sub_id=$(az account show --query "id" -o tsv 2>/dev/null || echo "")
    sub_name=$(az account show --query "name" -o tsv 2>/dev/null || echo "")

    if [[ -n "${sub_id}" ]]; then
        print_success "Subscription: ${sub_name}"
        CFG_subscription_id="${sub_id}"
    fi

    # Get tenant
    local tenant_id
    tenant_id=$(az account show --query "tenantId" -o tsv 2>/dev/null || echo "")
    if [[ -n "${tenant_id}" ]]; then
        print_success "Tenant ID: ${tenant_id:0:8}..."
        CFG_tenant_id="${tenant_id}"
    fi

    # Check for existing service principal in environment
    if [[ -n "${ARM_CLIENT_ID:-}" ]]; then
        print_success "Found ARM_CLIENT_ID in environment"
        CFG_client_id="${ARM_CLIENT_ID}"
    fi
    if [[ -n "${ARM_CLIENT_SECRET:-}" ]]; then
        print_success "Found ARM_CLIENT_SECRET in environment"
        CFG_client_secret="${ARM_CLIENT_SECRET}"
    fi
}

# Create or use existing service principal
configure_service_principal() {
    print_section "Service Principal Configuration" "🔑"

    if [[ -n "${CFG_client_id}" ]] && [[ -n "${CFG_client_secret}" ]]; then
        print_info "Service principal credentials already configured"
        echo -ne "  ${BOLD}Reconfigure service principal?${NC} ${DIM}[y/N]${NC}: "
        read -r sp_reconfigure
        if [[ ! "${sp_reconfigure}" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    echo -e "  ${BOLD}How would you like to configure the service principal?${NC}"
    echo -e "    ${DIM}1)${NC} Create a new service principal ${DIM}(recommended)${NC}"
    echo -e "    ${DIM}2)${NC} Enter existing service principal credentials"
    echo -ne "  ${CYAN}Select option${NC} ${DIM}[1]${NC}: "
    read -r sp_choice

    if [[ "${sp_choice}" == "2" ]]; then
        # Manual entry
        echo -ne "  ${BOLD}Client ID (App ID)${NC}: "
        read -r CFG_client_id
        while ! validate_uuid "${CFG_client_id}"; do
            print_error "Invalid UUID format"
            echo -ne "  ${BOLD}Client ID (App ID)${NC}: "
            read -r CFG_client_id
        done

        echo -ne "  ${BOLD}Client Secret${NC}: "
        read -rs CFG_client_secret
        echo ""
    else
        # Create new service principal
        print_step "Creating service principal..."

        local sp_name="coder-terraform-sp-$(date +%s)"
        local sp_output

        if sp_output=$(az ad sp create-for-rbac \
            --name "${sp_name}" \
            --role Contributor \
            --scopes "/subscriptions/${CFG_subscription_id}" \
            --output json 2>&1); then

            CFG_client_id=$(echo "${sp_output}" | grep -o '"appId": "[^"]*"' | cut -d'"' -f4)
            CFG_client_secret=$(echo "${sp_output}" | grep -o '"password": "[^"]*"' | cut -d'"' -f4)

            print_success "Service principal created: ${sp_name}"
            print_info "Client ID: ${CFG_client_id}"
            print_warning "Save the client secret securely - it won't be shown again"
        else
            print_error "Failed to create service principal"
            print_info "${sp_output}"
            print_info "You may need additional permissions or can enter credentials manually"

            echo -ne "  ${BOLD}Client ID (App ID)${NC}: "
            read -r CFG_client_id
            echo -ne "  ${BOLD}Client Secret${NC}: "
            read -rs CFG_client_secret
            echo ""
        fi
    fi
}

# Configure general settings
configure_general() {
    print_section "General Configuration" "⚙️"

    echo -ne "  ${BOLD}Resource group name${NC} ${DIM}[coder-rg]${NC}: "
    read -r input
    CFG_resource_group_name="${input:-coder-rg}"

    echo -ne "  ${BOLD}Department name (shown on login)${NC} ${DIM}[Research]${NC}: "
    read -r input
    CFG_department_name="${input:-Research}"

    # Location selection
    echo ""
    echo -e "  ${BOLD}Select Azure region:${NC}"
    local regions=("eastus" "eastus2" "westus2" "westus3" "centralus" "canadacentral" "northeurope" "westeurope" "uksouth" "southeastasia" "australiaeast")
    local i=1
    for region in "${regions[@]}"; do
        if [[ $i -le 5 ]]; then
            printf "    ${DIM}%d)${NC} %-15s" "$i" "$region"
        else
            printf "    ${DIM}%d)${NC} %-15s\n" "$i" "$region"
        fi
        ((i++)) || true
    done
    echo ""
    echo -ne "  ${CYAN}Select region${NC} ${DIM}[1 for eastus]${NC}: "
    read -r region_choice

    if [[ -z "${region_choice}" ]]; then
        region_choice=1
    fi

    if [[ "${region_choice}" =~ ^[0-9]+$ ]] && [[ "${region_choice}" -ge 1 ]] && [[ "${region_choice}" -le "${#regions[@]}" ]]; then
        CFG_location="${regions[$((region_choice-1))]}"
    else
        CFG_location="eastus"
    fi

    print_success "Region: ${CFG_location}"
}

# Configure AKS settings
configure_aks() {
    print_section "Kubernetes Cluster Configuration" "☸️"

    # Node size
    echo -e "  ${BOLD}Select node VM size:${NC}"
    echo -e "    ${DIM}1)${NC} Standard_D2s_v3  ${DIM}(2 vCPU, 8GB  - Small team ≤10, ~\$70/mo)${NC} ${GREEN}(recommended)${NC}"
    echo -e "    ${DIM}2)${NC} Standard_D4s_v3  ${DIM}(4 vCPU, 16GB - Medium team, ~\$140/mo)${NC}"
    echo -e "    ${DIM}3)${NC} Standard_D8s_v3  ${DIM}(8 vCPU, 32GB - Large team, ~\$280/mo)${NC}"
    echo -e "    ${DIM}4)${NC} Standard_D16s_v3 ${DIM}(16 vCPU, 64GB - Enterprise, ~\$560/mo)${NC}"
    echo -ne "  ${CYAN}Select size${NC} ${DIM}[1]${NC}: "
    read -r size_choice

    case "${size_choice}" in
        2) CFG_node_vm_size="Standard_D4s_v3" ;;
        3) CFG_node_vm_size="Standard_D8s_v3" ;;
        4) CFG_node_vm_size="Standard_D16s_v3" ;;
        *) CFG_node_vm_size="Standard_D2s_v3" ;;
    esac

    echo -ne "  ${BOLD}Initial node count${NC} ${DIM}[1]${NC}: "
    read -r input
    CFG_node_count="${input:-1}"

    echo -ne "  ${BOLD}Enable cluster autoscaling?${NC} ${DIM}[Y/n]${NC}: "
    read -r input
    if [[ "${input}" =~ ^[Nn]$ ]]; then
        CFG_enable_autoscaling="false"
    else
        CFG_enable_autoscaling="true"
        echo -ne "  ${BOLD}Minimum nodes${NC} ${DIM}[1]${NC}: "
        read -r input
        CFG_min_node_count="${input:-1}"
        echo -ne "  ${BOLD}Maximum nodes${NC} ${DIM}[5]${NC}: "
        read -r input
        CFG_max_node_count="${input:-5}"
    fi

    echo -ne "  ${BOLD}Kubernetes version${NC} ${DIM}[1.28]${NC}: "
    read -r input
    CFG_kubernetes_version="${input:-1.28}"
}

# Configure PostgreSQL
configure_postgres() {
    print_section "Database Configuration" "🗄️"

    echo -e "  ${BOLD}Select PostgreSQL size:${NC}"
    echo -e "    ${DIM}1)${NC} B_Standard_B1ms    ${DIM}(1 vCPU, 2GB  - Small team ≤10, ~\$15/mo)${NC} ${GREEN}(recommended)${NC}"
    echo -e "    ${DIM}2)${NC} GP_Standard_D2s_v3 ${DIM}(2 vCPU, 8GB  - Medium team, ~\$125/mo)${NC}"
    echo -e "    ${DIM}3)${NC} GP_Standard_D4s_v3 ${DIM}(4 vCPU, 16GB - Large team, ~\$250/mo)${NC}"
    echo -ne "  ${CYAN}Select size${NC} ${DIM}[1]${NC}: "
    read -r pg_choice

    case "${pg_choice}" in
        2) CFG_postgres_sku="GP_Standard_D2s_v3" ;;
        3) CFG_postgres_sku="GP_Standard_D4s_v3" ;;
        *) CFG_postgres_sku="B_Standard_B1ms" ;;
    esac

    echo -ne "  ${BOLD}Storage size in MB${NC} ${DIM}[32768]${NC}: "
    read -r input
    CFG_postgres_storage_mb="${input:-32768}"
}

# Configure network access
configure_network() {
    print_section "Network Access Configuration" "🌐"

    echo -e "  ${BOLD}How should Coder be accessed?${NC}"
    echo ""
    echo -e "    ${DIM}1)${NC} ${GREEN}LoadBalancer${NC}       ${DIM}(Public IP + Entra ID auth, ~\$20/mo)${NC} ${GREEN}(recommended)${NC}"
    echo -e "    ${DIM}2)${NC} WireGuard VPN     ${DIM}(Requires VPN client, ~\$5/mo for LB)${NC}"
    echo -e "    ${DIM}3)${NC} ClusterIP only     ${DIM}(\$0, requires kubectl port-forward)${NC}"
    echo ""
    echo -ne "  ${CYAN}Select access method${NC} ${DIM}[1]${NC}: "
    read -r network_choice

    case "${network_choice}" in
        2)
            CFG_network_access_type="wireguard"
            print_success "WireGuard VPN will be configured"
            print_info "After deployment, run: ./scripts/setup-wireguard-client.sh"
            echo ""
            echo -ne "  ${BOLD}WireGuard UDP port${NC} ${DIM}[51820]${NC}: "
            read -r input
            CFG_wireguard_port="${input:-51820}"
            echo -ne "  ${BOLD}VPN network CIDR${NC} ${DIM}[10.10.0.0/24]${NC}: "
            read -r input
            CFG_wireguard_network_cidr="${input:-10.10.0.0/24}"
            ;;
        3)
            CFG_network_access_type="clusterip"
            print_info "Access via: kubectl port-forward -n coder svc/coder 8080:80"
            ;;
        *)
            CFG_network_access_type="loadbalancer"
            print_info "Coder will be accessible via public LoadBalancer IP"
            print_info "Authentication provided by Entra ID"
            ;;
    esac
}

# Configure domain
configure_domain() {
    print_section "Domain Configuration" "🌐"

    print_info "A custom domain is recommended for production"
    print_info "Without a domain, Coder will be accessible via LoadBalancer IP"
    echo ""

    echo -ne "  ${BOLD}Configure a custom domain?${NC} ${DIM}[y/N]${NC}: "
    read -r use_domain

    if [[ "${use_domain}" =~ ^[Yy]$ ]]; then
        echo -ne "  ${BOLD}Domain name (e.g., coder.example.com)${NC}: "
        read -r CFG_coder_domain
        CFG_coder_wildcard_domain="${CFG_coder_domain}"
        CFG_enable_ingress="true"

        print_info "After deployment, create DNS A record:"
        print_info "${CFG_coder_domain} → <LoadBalancer IP>"
    else
        CFG_coder_domain=""
        CFG_coder_wildcard_domain=""
        CFG_enable_ingress="false"
    fi
}

# Configure Entra ID
configure_entra() {
    print_section "Entra ID (Azure AD) Configuration" "🔐"

    print_info "Entra ID integration is configured automatically"
    print_info "Users will sign in with their organizational accounts"
    echo ""

    echo -ne "  ${BOLD}Restrict login to specific email domains?${NC} ${DIM}[y/N]${NC}: "
    read -r restrict_domains

    if [[ "${restrict_domains}" =~ ^[Yy]$ ]]; then
        echo -ne "  ${BOLD}Allowed domains (comma-separated, e.g., example.com,corp.example.com)${NC}: "
        read -r CFG_email_domains
    else
        CFG_email_domains=""
    fi

    echo -ne "  ${BOLD}Sync Entra ID groups to Coder for RBAC?${NC} ${DIM}[y/N]${NC}: "
    read -r group_sync
    if [[ "${group_sync}" =~ ^[Yy]$ ]]; then
        CFG_enable_group_sync="true"
    else
        CFG_enable_group_sync="false"
    fi
}

# Configure backups
configure_backups() {
    print_section "Backup Configuration" "💾"

    print_info "PostgreSQL automated backups are always enabled"
    echo ""

    echo -ne "  ${BOLD}Backup retention days (7-35)${NC} ${DIM}[14]${NC}: "
    read -r input
    CFG_backup_retention_days="${input:-14}"

    echo -ne "  ${BOLD}Enable geo-redundant backups (cross-region DR)?${NC} ${DIM}[y/N]${NC}: "
    read -r geo_backup
    if [[ "${geo_backup}" =~ ^[Yy]$ ]]; then
        CFG_geo_redundant_backup="true"
    else
        CFG_geo_redundant_backup="false"
    fi

    echo -ne "  ${BOLD}Export backups to Blob Storage (long-term retention)?${NC} ${DIM}[Y/n]${NC}: "
    read -r blob_backup
    if [[ "${blob_backup}" =~ ^[Nn]$ ]]; then
        CFG_enable_backup_export="false"
    else
        CFG_enable_backup_export="true"
        echo -ne "  ${BOLD}Blob storage retention days${NC} ${DIM}[365]${NC}: "
        read -r input
        CFG_backup_blob_retention_days="${input:-365}"
    fi
}

# Configure external provisioners
configure_provisioners() {
    print_section "External Provisioners (Local Endpoints)" "💻"

    print_info "External provisioners allow laptops and desktops"
    print_info "to run workspaces locally using Docker"
    echo ""

    echo -ne "  ${BOLD}Enable external provisioners?${NC} ${DIM}[y/N]${NC}: "
    read -r ext_prov

    if [[ "${ext_prov}" =~ ^[Yy]$ ]]; then
        CFG_enable_external_provisioners="true"
        print_success "External provisioners will be enabled"
        print_info "After deployment, run setup-provisioner.sh on local machines"
    else
        CFG_enable_external_provisioners="false"
    fi
}

# Generate terraform.tfvars
generate_tfvars() {
    print_section "Generating Configuration" "📝"

    # Backup existing file
    if [[ -f "${TFVARS_FILE}" ]]; then
        local backup_file="${TFVARS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        cp "${TFVARS_FILE}" "${backup_file}"
        print_info "Existing config backed up to: $(basename "${backup_file}")"
    fi

    cat > "${TFVARS_FILE}" <<EOF
# Coder on Azure AKS - Configuration
# Generated by configure.sh on $(date)

# =============================================================================
# Azure Authentication
# =============================================================================

subscription_id = "${CFG_subscription_id}"
tenant_id       = "${CFG_tenant_id}"
client_id       = "${CFG_client_id}"
client_secret   = "${CFG_client_secret}"

# =============================================================================
# General Configuration
# =============================================================================

resource_group_name = "${CFG_resource_group_name}"
location            = "${CFG_location}"
department_name     = "${CFG_department_name}"

tags = {
  Environment = "Production"
  Department  = "${CFG_department_name}"
  ManagedBy   = "Terraform"
  Application = "Coder"
}

# =============================================================================
# AKS Configuration
# =============================================================================

kubernetes_version = "${CFG_kubernetes_version}"
node_count         = ${CFG_node_count}
node_vm_size       = "${CFG_node_vm_size}"
enable_autoscaling = ${CFG_enable_autoscaling}
EOF

    if [[ "${CFG_enable_autoscaling}" == "true" ]]; then
        cat >> "${TFVARS_FILE}" <<EOF
min_node_count     = ${CFG_min_node_count}
max_node_count     = ${CFG_max_node_count}
EOF
    fi

    cat >> "${TFVARS_FILE}" <<EOF

# =============================================================================
# PostgreSQL Configuration
# =============================================================================

postgres_sku        = "${CFG_postgres_sku}"
postgres_storage_mb = ${CFG_postgres_storage_mb}

# =============================================================================
# Backup Configuration
# =============================================================================

backup_retention_days      = ${CFG_backup_retention_days}
geo_redundant_backup       = ${CFG_geo_redundant_backup}
enable_backup_export       = ${CFG_enable_backup_export}
EOF

    if [[ "${CFG_enable_backup_export}" == "true" ]]; then
        cat >> "${TFVARS_FILE}" <<EOF
backup_blob_retention_days = ${CFG_backup_blob_retention_days:-365}
EOF
    fi

    cat >> "${TFVARS_FILE}" <<EOF

# =============================================================================
# Network Access Configuration
# =============================================================================

network_access_type = "${CFG_network_access_type}"
EOF

    if [[ "${CFG_network_access_type}" == "wireguard" ]]; then
        cat >> "${TFVARS_FILE}" <<EOF
wireguard_port         = ${CFG_wireguard_port:-51820}
wireguard_network_cidr = "${CFG_wireguard_network_cidr:-10.10.0.0/24}"
wireguard_peers        = []  # Add peers with: ./scripts/setup-wireguard-client.sh
EOF
    fi

    cat >> "${TFVARS_FILE}" <<EOF

# =============================================================================
# External Provisioners
# =============================================================================

enable_external_provisioners = ${CFG_enable_external_provisioners}

# =============================================================================
# Coder Configuration
# =============================================================================

coder_version = "2.16.0"
EOF

    if [[ -n "${CFG_coder_domain}" ]]; then
        cat >> "${TFVARS_FILE}" <<EOF
coder_domain          = "${CFG_coder_domain}"
coder_wildcard_domain = "${CFG_coder_wildcard_domain}"
enable_ingress        = ${CFG_enable_ingress}
EOF
    else
        cat >> "${TFVARS_FILE}" <<EOF
coder_domain          = ""
coder_wildcard_domain = ""
enable_ingress        = false
EOF
    fi

    cat >> "${TFVARS_FILE}" <<EOF

# =============================================================================
# Entra ID Configuration
# =============================================================================

EOF

    if [[ -n "${CFG_email_domains}" ]]; then
        # Convert comma-separated to array
        echo -n "allowed_email_domains = [" >> "${TFVARS_FILE}"
        local first=true
        IFS=',' read -ra DOMAINS <<< "${CFG_email_domains}"
        for domain in "${DOMAINS[@]}"; do
            domain=$(echo "${domain}" | xargs) # trim whitespace
            if [[ "${first}" == "true" ]]; then
                echo -n "\"${domain}\"" >> "${TFVARS_FILE}"
                first=false
            else
                echo -n ", \"${domain}\"" >> "${TFVARS_FILE}"
            fi
        done
        echo "]" >> "${TFVARS_FILE}"
    else
        echo "allowed_email_domains = []" >> "${TFVARS_FILE}"
    fi

    cat >> "${TFVARS_FILE}" <<EOF

enable_group_sync = ${CFG_enable_group_sync}
EOF

    print_success "Configuration saved to: terraform/terraform.tfvars"
}

# Show summary
show_summary() {
    print_section "Configuration Summary" "📋"

    echo ""
    echo -e "  ${BOLD}Azure${NC}"
    echo -e "    Subscription:  ${CFG_subscription_id:0:8}..."
    echo -e "    Region:        ${CFG_location}"
    echo -e "    Resource Group: ${CFG_resource_group_name}"
    echo ""
    echo -e "  ${BOLD}Kubernetes${NC}"
    echo -e "    Node Size:     ${CFG_node_vm_size}"
    echo -e "    Nodes:         ${CFG_node_count} (autoscale: ${CFG_enable_autoscaling})"
    echo ""
    echo -e "  ${BOLD}Network Access${NC}"
    echo -e "    Type:          ${CFG_network_access_type}"
    if [[ "${CFG_network_access_type}" == "wireguard" ]]; then
        echo -e "    VPN Port:      ${CFG_wireguard_port:-51820}/UDP"
        echo -e "    VPN Network:   ${CFG_wireguard_network_cidr:-10.10.0.0/24}"
    fi
    echo ""
    echo -e "  ${BOLD}Database${NC}"
    echo -e "    SKU:           ${CFG_postgres_sku}"
    echo -e "    Backup:        ${CFG_backup_retention_days} days"
    echo ""
    echo -e "  ${BOLD}Features${NC}"
    echo -e "    Domain:        ${CFG_coder_domain:-<via LoadBalancer IP>}"
    echo -e "    Provisioners:  ${CFG_enable_external_provisioners}"
    echo -e "    Group Sync:    ${CFG_enable_group_sync}"
    echo ""
}

# Estimate costs
show_cost_estimate() {
    print_section "Estimated Monthly Cost" "💰"

    local aks_cost=0
    local pg_cost=0
    local nodes="${CFG_node_count}"

    case "${CFG_node_vm_size}" in
        "Standard_D2s_v3")  aks_cost=$((nodes * 70)) ;;
        "Standard_D4s_v3")  aks_cost=$((nodes * 140)) ;;
        "Standard_D8s_v3")  aks_cost=$((nodes * 280)) ;;
        "Standard_D16s_v3") aks_cost=$((nodes * 560)) ;;
    esac

    case "${CFG_postgres_sku}" in
        "B_Standard_B1ms")    pg_cost=15 ;;
        "GP_Standard_D2s_v3") pg_cost=125 ;;
        "GP_Standard_D4s_v3") pg_cost=250 ;;
    esac

    local lb_cost=0
    local lb_desc=""
    case "${CFG_network_access_type}" in
        "loadbalancer")
            lb_cost=20
            lb_desc="LoadBalancer (public IP)"
            ;;
        "wireguard")
            lb_cost=5
            lb_desc="WireGuard LB (UDP only)"
            ;;
        *)
            lb_cost=0
            lb_desc="ClusterIP (no LB)"
            ;;
    esac

    local storage_cost=5
    local total=$((aks_cost + pg_cost + lb_cost + storage_cost))

    echo ""
    printf "    %-25s %s\n" "AKS Nodes (${nodes}x):" "~\$${aks_cost}/mo"
    printf "    %-25s %s\n" "PostgreSQL:" "~\$${pg_cost}/mo"
    printf "    %-25s %s\n" "${lb_desc}:" "~\$${lb_cost}/mo"
    printf "    %-25s %s\n" "Storage & Backups:" "~\$${storage_cost}/mo"
    echo -e "    ${DIM}────────────────────────────────────────${NC}"
    printf "    ${BOLD}%-25s ~\$%d/mo${NC}\n" "Estimated Total:" "${total}"
    echo ""
    echo -e "  ${DIM}* Costs vary by region and usage. Autoscaling may increase costs.${NC}"
}

# Prompt for next action
prompt_next_action() {
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║${NC}              ${GREEN}Configuration Complete!${NC}                        ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Check if there's an existing deployment
    local has_deployment=false
    if [[ -f "${TERRAFORM_DIR}/terraform.tfstate" ]]; then
        local resource_count
        resource_count=$(cd "${TERRAFORM_DIR}" && terraform state list 2>/dev/null | wc -l || echo "0")
        if [[ "${resource_count}" -gt 0 ]]; then
            has_deployment=true
        fi
    fi

    if [[ "${has_deployment}" == "true" ]]; then
        echo -e "  ${YELLOW}${BOLD}Existing deployment detected${NC}"
        echo ""
        echo -e "  ${BOLD}What would you like to do?${NC}"
        echo -e "    ${DIM}1)${NC} Update deployment with new configuration"
        echo -e "    ${DIM}2)${NC} Teardown existing deployment"
        echo -e "    ${DIM}3)${NC} Exit (save configuration only)"
        echo -ne "  ${CYAN}Select option${NC} ${DIM}[1]${NC}: "
        read -r action_choice
        echo ""

        case "${action_choice}" in
            2)
                echo ""
                echo -e "  ${RED}${BOLD}Warning: This will destroy all Coder infrastructure!${NC}"
                echo -ne "  ${BOLD}Are you sure?${NC} ${DIM}[y/N]${NC}: "
                read -r confirm_teardown
                echo ""
                if [[ "${confirm_teardown}" =~ ^[Yy]$ ]]; then
                    exec "${SCRIPT_DIR}/teardown.sh"
                else
                    print_info "Teardown cancelled"
                    show_next_steps
                fi
                ;;
            3)
                show_next_steps
                ;;
            *)
                echo ""
                exec "${SCRIPT_DIR}/deploy.sh"
                ;;
        esac
    else
        echo -ne "  ${BOLD}Would you like to deploy now?${NC} ${DIM}[Y/n]${NC}: "
        read -r deploy_answer
        echo ""

        if [[ ! "${deploy_answer}" =~ ^[Nn]$ ]]; then
            echo ""
            exec "${SCRIPT_DIR}/deploy.sh"
        else
            show_next_steps
        fi
    fi
}

# Show next steps
show_next_steps() {
    echo ""
    echo -e "  ${CYAN}${BOLD}Available Commands:${NC}"
    echo ""
    echo -e "    ${GREEN}Deploy${NC}"
    echo -e "      ${DIM}./scripts/deploy.sh${NC}"
    echo ""
    echo -e "    ${YELLOW}Reconfigure${NC}"
    echo -e "      ${DIM}./scripts/configure.sh${NC}"
    echo ""
    echo -e "    ${RED}Teardown${NC}"
    echo -e "      ${DIM}./scripts/teardown.sh${NC}"
    echo ""
    echo -e "    ${BLUE}Backup Management${NC}"
    echo -e "      ${DIM}./scripts/backup-database.sh${NC}"
    echo ""
    if [[ "${CFG_network_access_type:-}" == "wireguard" ]]; then
        echo -e "    ${CYAN}Setup WireGuard Client${NC}"
        echo -e "      ${DIM}./scripts/setup-wireguard-client.sh${NC}"
        echo ""
    fi
    echo -e "    ${MAGENTA}Add Local Provisioner${NC}"
    echo -e "      ${DIM}./scripts/setup-provisioner.sh --help${NC}"
    echo ""
}

# Main
main() {
    print_header

    # Check prerequisites
    if ! check_azure_cli; then
        echo ""
        print_error "Please install Azure CLI and login before continuing"
        exit 1
    fi

    # Auto-detect Azure values
    auto_detect_azure

    # Run configuration sections
    configure_service_principal
    configure_general
    configure_aks
    configure_postgres
    configure_network
    configure_domain
    configure_entra
    configure_backups
    configure_provisioners

    # Generate configuration
    generate_tfvars

    # Show summary
    show_summary
    show_cost_estimate

    # Offer next action
    prompt_next_action
}

main "$@"
