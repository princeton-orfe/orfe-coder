#!/usr/bin/env bash
# Coder on Azure AKS - Interactive Configuration Script
# Generates terraform.tfvars based on user input

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

# Configuration values (will be populated by prompts)
declare -A CONFIG

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
    echo -e "${DIM}$(printf '%.0s─' {1..60})${NC}"
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

# Prompt for input with default value
prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-}"
    local is_secret="${4:-false}"
    local value=""

    if [[ -n "${default}" ]]; then
        echo -ne "  ${BOLD}${prompt_text}${NC} ${DIM}[${default}]${NC}: "
    else
        echo -ne "  ${BOLD}${prompt_text}${NC}: "
    fi

    if [[ "${is_secret}" == "true" ]]; then
        read -s value
        echo ""
    else
        read value
    fi

    if [[ -z "${value}" ]] && [[ -n "${default}" ]]; then
        value="${default}"
    fi

    CONFIG["${var_name}"]="${value}"
}

# Prompt for yes/no
prompt_yn() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-n}"

    local default_display
    if [[ "${default}" == "y" ]]; then
        default_display="Y/n"
    else
        default_display="y/N"
    fi

    echo -ne "  ${BOLD}${prompt_text}${NC} ${DIM}[${default_display}]${NC}: "
    read -n 1 answer
    echo ""

    if [[ -z "${answer}" ]]; then
        answer="${default}"
    fi

    if [[ "${answer}" =~ ^[Yy]$ ]]; then
        CONFIG["${var_name}"]="true"
    else
        CONFIG["${var_name}"]="false"
    fi
}

# Prompt with options
prompt_select() {
    local var_name="$1"
    local prompt_text="$2"
    shift 2
    local options=("$@")

    echo -e "  ${BOLD}${prompt_text}${NC}"
    local i=1
    for opt in "${options[@]}"; do
        echo -e "    ${DIM}${i})${NC} ${opt}"
        ((i++))
    done

    echo -ne "  ${CYAN}Select option${NC} ${DIM}[1]${NC}: "
    read selection

    if [[ -z "${selection}" ]]; then
        selection=1
    fi

    if [[ "${selection}" =~ ^[0-9]+$ ]] && [[ "${selection}" -ge 1 ]] && [[ "${selection}" -le "${#options[@]}" ]]; then
        CONFIG["${var_name}"]="${options[$((selection-1))]}"
    else
        CONFIG["${var_name}"]="${options[0]}"
    fi
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
        read -n 1 login_answer
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
        CONFIG["subscription_id"]="${sub_id}"
    fi

    # Get tenant
    local tenant_id
    tenant_id=$(az account show --query "tenantId" -o tsv 2>/dev/null || echo "")
    if [[ -n "${tenant_id}" ]]; then
        print_success "Tenant ID: ${tenant_id:0:8}..."
        CONFIG["tenant_id"]="${tenant_id}"
    fi

    # Check for existing service principal in environment
    if [[ -n "${ARM_CLIENT_ID:-}" ]]; then
        print_success "Found ARM_CLIENT_ID in environment"
        CONFIG["client_id"]="${ARM_CLIENT_ID}"
    fi
    if [[ -n "${ARM_CLIENT_SECRET:-}" ]]; then
        print_success "Found ARM_CLIENT_SECRET in environment"
        CONFIG["client_secret"]="${ARM_CLIENT_SECRET}"
    fi
}

# Create or use existing service principal
configure_service_principal() {
    print_section "Service Principal Configuration" "🔑"

    if [[ -n "${CONFIG[client_id]:-}" ]] && [[ -n "${CONFIG[client_secret]:-}" ]]; then
        print_info "Service principal credentials already configured"
        prompt_yn "sp_reconfigure" "Reconfigure service principal?"
        if [[ "${CONFIG[sp_reconfigure]}" != "true" ]]; then
            return 0
        fi
    fi

    echo -e "  ${BOLD}How would you like to configure the service principal?${NC}"
    echo -e "    ${DIM}1)${NC} Create a new service principal ${DIM}(recommended)${NC}"
    echo -e "    ${DIM}2)${NC} Enter existing service principal credentials"
    echo -ne "  ${CYAN}Select option${NC} ${DIM}[1]${NC}: "
    read sp_choice

    if [[ "${sp_choice}" == "2" ]]; then
        # Manual entry
        prompt "client_id" "Client ID (App ID)"
        while ! validate_uuid "${CONFIG[client_id]}"; do
            print_error "Invalid UUID format"
            prompt "client_id" "Client ID (App ID)"
        done

        prompt "client_secret" "Client Secret" "" "true"
    else
        # Create new service principal
        print_step "Creating service principal..."

        local sp_name="coder-terraform-sp-$(date +%s)"
        local sp_output

        if sp_output=$(az ad sp create-for-rbac \
            --name "${sp_name}" \
            --role Contributor \
            --scopes "/subscriptions/${CONFIG[subscription_id]}" \
            --output json 2>&1); then

            CONFIG["client_id"]=$(echo "${sp_output}" | jq -r '.appId')
            CONFIG["client_secret"]=$(echo "${sp_output}" | jq -r '.password')

            print_success "Service principal created: ${sp_name}"
            print_info "Client ID: ${CONFIG[client_id]}"
            print_warning "Save the client secret securely - it won't be shown again"
        else
            print_error "Failed to create service principal"
            print_info "${sp_output}"
            print_info "You may need additional permissions or can enter credentials manually"

            prompt "client_id" "Client ID (App ID)"
            prompt "client_secret" "Client Secret" "" "true"
        fi
    fi
}

# Configure general settings
configure_general() {
    print_section "General Configuration" "⚙️"

    prompt "resource_prefix" "Resource name prefix" "coder"
    prompt "department_name" "Department name (shown on login)" "Engineering"

    # Location selection
    echo ""
    echo -e "  ${BOLD}Select Azure region:${NC}"
    local regions=("eastus" "eastus2" "westus2" "westus3" "centralus" "northeurope" "westeurope" "uksouth" "southeastasia" "australiaeast")
    local i=1
    for region in "${regions[@]}"; do
        if [[ $i -le 5 ]]; then
            printf "    ${DIM}%d)${NC} %-15s" "$i" "$region"
        else
            printf "    ${DIM}%d)${NC} %-15s\n" "$i" "$region"
        fi
        ((i++))
    done
    echo ""
    echo -ne "  ${CYAN}Select region${NC} ${DIM}[1 for eastus]${NC}: "
    read region_choice

    if [[ -z "${region_choice}" ]]; then
        region_choice=1
    fi

    if [[ "${region_choice}" =~ ^[0-9]+$ ]] && [[ "${region_choice}" -ge 1 ]] && [[ "${region_choice}" -le "${#regions[@]}" ]]; then
        CONFIG["location"]="${regions[$((region_choice-1))]}"
    else
        CONFIG["location"]="eastus"
    fi

    print_success "Region: ${CONFIG[location]}"
}

# Configure AKS settings
configure_aks() {
    print_section "Kubernetes Cluster Configuration" "☸️"

    # Node size
    echo -e "  ${BOLD}Select node VM size:${NC}"
    echo -e "    ${DIM}1)${NC} Standard_D2s_v3  ${DIM}(2 vCPU, 8GB  - Dev/Test)${NC}"
    echo -e "    ${DIM}2)${NC} Standard_D4s_v3  ${DIM}(4 vCPU, 16GB - Small team)${NC}"
    echo -e "    ${DIM}3)${NC} Standard_D8s_v3  ${DIM}(8 vCPU, 32GB - Medium team)${NC}"
    echo -e "    ${DIM}4)${NC} Standard_D16s_v3 ${DIM}(16 vCPU, 64GB - Large team)${NC}"
    echo -ne "  ${CYAN}Select size${NC} ${DIM}[2]${NC}: "
    read size_choice

    case "${size_choice}" in
        1) CONFIG["node_vm_size"]="Standard_D2s_v3" ;;
        3) CONFIG["node_vm_size"]="Standard_D8s_v3" ;;
        4) CONFIG["node_vm_size"]="Standard_D16s_v3" ;;
        *) CONFIG["node_vm_size"]="Standard_D4s_v3" ;;
    esac

    prompt "node_count" "Initial node count" "2"
    prompt_yn "enable_autoscaling" "Enable cluster autoscaling?" "y"

    if [[ "${CONFIG[enable_autoscaling]}" == "true" ]]; then
        prompt "min_node_count" "Minimum nodes" "2"
        prompt "max_node_count" "Maximum nodes" "10"
    fi

    prompt "kubernetes_version" "Kubernetes version" "1.28"
}

# Configure domain
configure_domain() {
    print_section "Domain Configuration" "🌐"

    print_info "A custom domain is recommended for production"
    print_info "Without a domain, Coder will be accessible via LoadBalancer IP"
    echo ""

    prompt_yn "use_custom_domain" "Configure a custom domain?" "n"

    if [[ "${CONFIG[use_custom_domain]}" == "true" ]]; then
        prompt "coder_domain" "Domain name (e.g., coder.example.com)"
        CONFIG["coder_wildcard_domain"]="${CONFIG[coder_domain]}"
        CONFIG["enable_ingress"]="true"

        print_info "After deployment, create DNS A record:"
        print_info "${CONFIG[coder_domain]} → <LoadBalancer IP>"
    else
        CONFIG["coder_domain"]=""
        CONFIG["coder_wildcard_domain"]=""
        CONFIG["enable_ingress"]="false"
    fi
}

# Configure Entra ID
configure_entra() {
    print_section "Entra ID (Azure AD) Configuration" "🔐"

    print_info "Entra ID integration is configured automatically"
    print_info "Users will sign in with their organizational accounts"
    echo ""

    prompt_yn "restrict_domains" "Restrict login to specific email domains?" "n"

    if [[ "${CONFIG[restrict_domains]}" == "true" ]]; then
        prompt "email_domains" "Allowed domains (comma-separated, e.g., example.com,corp.example.com)"
    else
        CONFIG["email_domains"]=""
    fi

    prompt_yn "enable_group_sync" "Sync Entra ID groups to Coder for RBAC?" "n"
}

# Configure backups
configure_backups() {
    print_section "Backup Configuration" "💾"

    print_info "PostgreSQL automated backups are always enabled"
    echo ""

    prompt "backup_retention_days" "Backup retention days (7-35)" "14"

    prompt_yn "geo_redundant_backup" "Enable geo-redundant backups (cross-region DR)?" "n"
    prompt_yn "enable_backup_export" "Export backups to Blob Storage (long-term retention)?" "y"

    if [[ "${CONFIG[enable_backup_export]}" == "true" ]]; then
        prompt "backup_blob_retention_days" "Blob storage retention days" "365"
    fi
}

# Configure external provisioners
configure_provisioners() {
    print_section "External Provisioners (Local Endpoints)" "💻"

    print_info "External provisioners allow laptops and desktops"
    print_info "to run workspaces locally using Docker"
    echo ""

    prompt_yn "enable_external_provisioners" "Enable external provisioners?" "n"

    if [[ "${CONFIG[enable_external_provisioners]}" == "true" ]]; then
        print_success "External provisioners will be enabled"
        print_info "After deployment, run setup-provisioner.sh on local machines"
    fi
}

# Configure PostgreSQL
configure_postgres() {
    print_section "Database Configuration" "🗄️"

    echo -e "  ${BOLD}Select PostgreSQL size:${NC}"
    echo -e "    ${DIM}1)${NC} B_Standard_B1ms   ${DIM}(1 vCPU, 2GB  - Dev/Test, ~\$15/mo)${NC}"
    echo -e "    ${DIM}2)${NC} GP_Standard_D2s_v3 ${DIM}(2 vCPU, 8GB  - Production, ~\$125/mo)${NC}"
    echo -e "    ${DIM}3)${NC} GP_Standard_D4s_v3 ${DIM}(4 vCPU, 16GB - Large scale, ~\$250/mo)${NC}"
    echo -ne "  ${CYAN}Select size${NC} ${DIM}[2]${NC}: "
    read pg_choice

    case "${pg_choice}" in
        1) CONFIG["postgres_sku"]="B_Standard_B1ms" ;;
        3) CONFIG["postgres_sku"]="GP_Standard_D4s_v3" ;;
        *) CONFIG["postgres_sku"]="GP_Standard_D2s_v3" ;;
    esac

    prompt "postgres_storage_mb" "Storage size in MB" "32768"
}

# Generate terraform.tfvars
generate_tfvars() {
    print_section "Generating Configuration" "📝"

    # Backup existing file
    if [[ -f "${TFVARS_FILE}" ]]; then
        local backup_file="${TFVARS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        cp "${TFVARS_FILE}" "${backup_file}"
        print_info "Existing config backed up to: $(basename ${backup_file})"
    fi

    cat > "${TFVARS_FILE}" <<EOF
# Coder on Azure AKS - Configuration
# Generated by configure.sh on $(date)

# =============================================================================
# Azure Authentication
# =============================================================================

subscription_id = "${CONFIG[subscription_id]}"
tenant_id       = "${CONFIG[tenant_id]}"
client_id       = "${CONFIG[client_id]}"
client_secret   = "${CONFIG[client_secret]}"

# =============================================================================
# General Configuration
# =============================================================================

resource_prefix = "${CONFIG[resource_prefix]}"
location        = "${CONFIG[location]}"
department_name = "${CONFIG[department_name]}"

tags = {
  Environment = "Production"
  Department  = "${CONFIG[department_name]}"
  ManagedBy   = "Terraform"
  Application = "Coder"
}

# =============================================================================
# AKS Configuration
# =============================================================================

kubernetes_version = "${CONFIG[kubernetes_version]}"
node_count         = ${CONFIG[node_count]}
node_vm_size       = "${CONFIG[node_vm_size]}"
enable_autoscaling = ${CONFIG[enable_autoscaling]}
EOF

    if [[ "${CONFIG[enable_autoscaling]}" == "true" ]]; then
        cat >> "${TFVARS_FILE}" <<EOF
min_node_count     = ${CONFIG[min_node_count]}
max_node_count     = ${CONFIG[max_node_count]}
EOF
    fi

    cat >> "${TFVARS_FILE}" <<EOF

# =============================================================================
# PostgreSQL Configuration
# =============================================================================

postgres_sku        = "${CONFIG[postgres_sku]}"
postgres_storage_mb = ${CONFIG[postgres_storage_mb]}

# =============================================================================
# Backup Configuration
# =============================================================================

backup_retention_days      = ${CONFIG[backup_retention_days]}
geo_redundant_backup       = ${CONFIG[geo_redundant_backup]}
enable_backup_export       = ${CONFIG[enable_backup_export]}
EOF

    if [[ "${CONFIG[enable_backup_export]}" == "true" ]]; then
        cat >> "${TFVARS_FILE}" <<EOF
backup_blob_retention_days = ${CONFIG[backup_blob_retention_days]:-365}
EOF
    fi

    cat >> "${TFVARS_FILE}" <<EOF

# =============================================================================
# External Provisioners
# =============================================================================

enable_external_provisioners = ${CONFIG[enable_external_provisioners]}

# =============================================================================
# Coder Configuration
# =============================================================================

coder_version = "2.16.0"
EOF

    if [[ -n "${CONFIG[coder_domain]}" ]]; then
        cat >> "${TFVARS_FILE}" <<EOF
coder_domain          = "${CONFIG[coder_domain]}"
coder_wildcard_domain = "${CONFIG[coder_wildcard_domain]}"
enable_ingress        = ${CONFIG[enable_ingress]}
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

    if [[ -n "${CONFIG[email_domains]}" ]]; then
        # Convert comma-separated to array
        local domains_array=""
        IFS=',' read -ra DOMAINS <<< "${CONFIG[email_domains]}"
        for domain in "${DOMAINS[@]}"; do
            domain=$(echo "${domain}" | xargs) # trim whitespace
            domains_array+="  \"${domain}\",\n"
        done
        echo -e "allowed_email_domains = [\n${domains_array}]" >> "${TFVARS_FILE}"
    else
        echo "allowed_email_domains = []" >> "${TFVARS_FILE}"
    fi

    cat >> "${TFVARS_FILE}" <<EOF

enable_group_sync = ${CONFIG[enable_group_sync]}
EOF

    print_success "Configuration saved to: terraform/terraform.tfvars"
}

# Show summary
show_summary() {
    print_section "Configuration Summary" "📋"

    echo ""
    echo -e "  ${BOLD}Azure${NC}"
    echo -e "    Subscription:  ${CONFIG[subscription_id]:0:8}..."
    echo -e "    Region:        ${CONFIG[location]}"
    echo -e "    Prefix:        ${CONFIG[resource_prefix]}"
    echo ""
    echo -e "  ${BOLD}Kubernetes${NC}"
    echo -e "    Node Size:     ${CONFIG[node_vm_size]}"
    echo -e "    Nodes:         ${CONFIG[node_count]} (autoscale: ${CONFIG[enable_autoscaling]})"
    echo ""
    echo -e "  ${BOLD}Database${NC}"
    echo -e "    SKU:           ${CONFIG[postgres_sku]}"
    echo -e "    Backup:        ${CONFIG[backup_retention_days]} days"
    echo ""
    echo -e "  ${BOLD}Features${NC}"
    echo -e "    Domain:        ${CONFIG[coder_domain]:-<LoadBalancer IP>}"
    echo -e "    Provisioners:  ${CONFIG[enable_external_provisioners]}"
    echo -e "    Group Sync:    ${CONFIG[enable_group_sync]}"
    echo ""
}

# Estimate costs
show_cost_estimate() {
    print_section "Estimated Monthly Cost" "💰"

    local aks_cost=0
    local pg_cost=0
    local nodes="${CONFIG[node_count]}"

    case "${CONFIG[node_vm_size]}" in
        "Standard_D2s_v3")  aks_cost=$((nodes * 70)) ;;
        "Standard_D4s_v3")  aks_cost=$((nodes * 140)) ;;
        "Standard_D8s_v3")  aks_cost=$((nodes * 280)) ;;
        "Standard_D16s_v3") aks_cost=$((nodes * 560)) ;;
    esac

    case "${CONFIG[postgres_sku]}" in
        "B_Standard_B1ms")    pg_cost=15 ;;
        "GP_Standard_D2s_v3") pg_cost=125 ;;
        "GP_Standard_D4s_v3") pg_cost=250 ;;
    esac

    local lb_cost=20
    local storage_cost=10
    local total=$((aks_cost + pg_cost + lb_cost + storage_cost))

    echo ""
    printf "    %-25s %s\n" "AKS Nodes (${nodes}x):" "~\$${aks_cost}/mo"
    printf "    %-25s %s\n" "PostgreSQL:" "~\$${pg_cost}/mo"
    printf "    %-25s %s\n" "Load Balancer:" "~\$${lb_cost}/mo"
    printf "    %-25s %s\n" "Storage & Backups:" "~\$${storage_cost}/mo"
    echo -e "    ${DIM}$(printf '%.0s─' {1..40})${NC}"
    printf "    ${BOLD}%-25s ~\$%d/mo${NC}\n" "Estimated Total:" "${total}"
    echo ""
    echo -e "  ${DIM}* Costs vary by region and usage. Autoscaling may increase costs.${NC}"
}

# Prompt to deploy
prompt_deploy() {
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║${NC}              ${GREEN}Configuration Complete!${NC}                        ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -ne "  ${BOLD}Would you like to deploy now?${NC} ${DIM}[Y/n]${NC}: "
    read -n 1 deploy_answer
    echo ""

    if [[ ! "${deploy_answer}" =~ ^[Nn]$ ]]; then
        echo ""
        exec "${SCRIPT_DIR}/deploy.sh"
    else
        echo ""
        echo -e "  ${CYAN}To deploy later, run:${NC}"
        echo -e "    ${DIM}./scripts/deploy.sh${NC}"
        echo ""
        echo -e "  ${CYAN}To modify configuration:${NC}"
        echo -e "    ${DIM}./scripts/configure.sh${NC}"
        echo -e "    ${DIM}# or edit terraform/terraform.tfvars directly${NC}"
        echo ""
    fi
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
    configure_domain
    configure_entra
    configure_backups
    configure_provisioners

    # Generate configuration
    generate_tfvars

    # Show summary
    show_summary
    show_cost_estimate

    # Offer to deploy
    prompt_deploy
}

main "$@"
