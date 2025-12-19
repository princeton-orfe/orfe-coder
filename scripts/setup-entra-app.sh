#!/usr/bin/env bash
# Coder on Azure AKS - Entra ID App Registration Setup
# Creates the Entra ID app registration using Azure CLI (user credentials)
# This separates Entra ID permissions from the service principal's Azure permissions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
ENTRA_CONFIG_FILE="${TERRAFORM_DIR}/entra-app.auto.tfvars"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse arguments
APP_NAME=""
TENANT_ID=""
FORCE_RECREATE=false
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
            APP_NAME="$2"
            shift 2
            ;;
        --tenant)
            TENANT_ID="$2"
            shift 2
            ;;
        --force)
            FORCE_RECREATE=true
            shift
            ;;
        -h|--help)
            SHOW_HELP=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ "${SHOW_HELP}" == "true" ]]; then
    echo ""
    echo -e "${CYAN}${BOLD}Entra ID App Registration Setup${NC}"
    echo ""
    echo "Creates an Entra ID app registration for Coder OIDC authentication."
    echo "Uses your Azure CLI credentials (not the service principal)."
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --name NAME    App registration name (default: derived from resource group)"
    echo "  --tenant ID    Azure AD tenant ID (default: auto-detect)"
    echo "  --force        Recreate app even if it already exists"
    echo "  -h, --help     Show this help message"
    echo ""
    echo "The script will:"
    echo "  1. Create an Entra ID app registration"
    echo "  2. Configure OIDC settings (redirect URIs, claims, etc.)"
    echo "  3. Create a client secret"
    echo "  4. Save credentials to terraform/entra-app.auto.tfvars"
    echo ""
    exit 0
fi

# Check Azure CLI login
check_azure_login() {
    log_info "Checking Azure CLI authentication..."

    if ! az account show &> /dev/null; then
        log_error "Not logged into Azure CLI"
        echo ""
        echo "Please login with: az login"
        exit 1
    fi

    local account_name
    account_name=$(az account show --query "name" -o tsv)
    log_success "Logged in as: ${account_name}"

    # Get tenant ID if not provided
    if [[ -z "${TENANT_ID}" ]]; then
        TENANT_ID=$(az account show --query "tenantId" -o tsv)
    fi
    log_info "Tenant ID: ${TENANT_ID}"
}

# Derive app name from terraform.tfvars if not provided
get_app_name() {
    if [[ -n "${APP_NAME}" ]]; then
        return
    fi

    if [[ -f "${TERRAFORM_DIR}/terraform.tfvars" ]]; then
        local rg_name
        rg_name=$(grep -E "^resource_group_name" "${TERRAFORM_DIR}/terraform.tfvars" | sed 's/.*=.*"\(.*\)".*/\1/' || echo "")
        if [[ -n "${rg_name}" ]]; then
            APP_NAME="${rg_name%-rg}-coder-app"
            log_info "Derived app name from resource group: ${APP_NAME}"
            return
        fi
    fi

    # Default name
    APP_NAME="coder-entra-app-$(date +%s)"
    log_warn "Using default app name: ${APP_NAME}"
}

# Check if app already exists
check_existing_app() {
    log_info "Checking for existing app registration..."

    local existing_app
    existing_app=$(az ad app list --display-name "${APP_NAME}" --query "[0].appId" -o tsv 2>/dev/null || echo "")

    if [[ -n "${existing_app}" ]]; then
        if [[ "${FORCE_RECREATE}" == "true" ]]; then
            log_warn "App '${APP_NAME}' exists, deleting for recreation..."
            az ad app delete --id "${existing_app}"
            sleep 2
        else
            log_info "App '${APP_NAME}' already exists (ID: ${existing_app})"

            # Check if we have the config file
            if [[ -f "${ENTRA_CONFIG_FILE}" ]]; then
                log_success "Entra app configuration already exists"
                echo ""
                echo -e "${YELLOW}To recreate the app, run: $0 --force${NC}"
                echo ""
                exit 0
            else
                log_warn "App exists but no local config. Use --force to recreate."
                exit 1
            fi
        fi
    fi
}

# Create the app registration
create_app_registration() {
    log_info "Creating Entra ID app registration: ${APP_NAME}"

    # Create the app with basic settings
    local app_output
    app_output=$(az ad app create \
        --display-name "${APP_NAME}" \
        --sign-in-audience "AzureADMyOrg" \
        --web-redirect-uris "http://localhost:3000/api/v2/users/oidc/callback" \
        --enable-id-token-issuance true \
        --query "{appId: appId, id: id}" \
        -o json)

    APP_ID=$(echo "${app_output}" | grep -o '"appId": "[^"]*"' | cut -d'"' -f4)
    OBJECT_ID=$(echo "${app_output}" | grep -o '"id": "[^"]*"' | cut -d'"' -f4)

    log_success "App created with Client ID: ${APP_ID}"

    # Wait for propagation
    sleep 3
}

# Configure app permissions and claims
configure_app() {
    log_info "Configuring app permissions and claims..."

    # Add required Microsoft Graph permissions
    # User.Read, email, profile, openid
    az ad app permission add \
        --id "${APP_ID}" \
        --api "00000003-0000-0000-c000-000000000000" \
        --api-permissions "e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope 64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0=Scope 14dad69e-099b-42c9-810b-d002981feec1=Scope 37f7f235-527c-4136-accd-4a02d197296e=Scope" \
        2>/dev/null || true

    log_success "Graph API permissions configured"

    # Configure optional claims using Graph API
    log_info "Configuring optional claims..."

    az rest --method PATCH \
        --uri "https://graph.microsoft.com/v1.0/applications/${OBJECT_ID}" \
        --headers "Content-Type=application/json" \
        --body '{
            "api": {
                "requestedAccessTokenVersion": 2
            },
            "optionalClaims": {
                "idToken": [
                    {"name": "email", "essential": true},
                    {"name": "preferred_username", "essential": true},
                    {"name": "groups", "additionalProperties": ["emit_as_roles"]}
                ]
            }
        }' 2>/dev/null || log_warn "Could not set optional claims (non-critical)"

    log_success "App configuration complete"
}

# Create client secret
create_client_secret() {
    log_info "Creating client secret..."

    local secret_output
    secret_output=$(az ad app credential reset \
        --id "${APP_ID}" \
        --display-name "coder-oidc-secret" \
        --years 1 \
        --query "password" \
        -o tsv)

    CLIENT_SECRET="${secret_output}"

    log_success "Client secret created (valid for 1 year)"
}

# Create service principal for the app
create_service_principal() {
    log_info "Creating service principal..."

    # Check if SP already exists
    local existing_sp
    existing_sp=$(az ad sp show --id "${APP_ID}" --query "id" -o tsv 2>/dev/null || echo "")

    if [[ -z "${existing_sp}" ]]; then
        az ad sp create --id "${APP_ID}" > /dev/null
        log_success "Service principal created"
    else
        log_info "Service principal already exists"
    fi
}

# Save configuration to tfvars
save_configuration() {
    log_info "Saving configuration to ${ENTRA_CONFIG_FILE}..."

    cat > "${ENTRA_CONFIG_FILE}" <<EOF
# Entra ID App Registration Configuration
# Generated by setup-entra-app.sh on $(date)
#
# This file is auto-loaded by Terraform (.auto.tfvars)
# The app was created using your Azure CLI credentials, separate from
# the service principal used for infrastructure deployment.

use_existing_entra_app  = true
entra_app_client_id     = "${APP_ID}"
entra_app_client_secret = "${CLIENT_SECRET}"

# App Details:
# - Display Name: ${APP_NAME}
# - Object ID: ${OBJECT_ID}
# - Tenant ID: ${TENANT_ID}
EOF

    chmod 600 "${ENTRA_CONFIG_FILE}"

    log_success "Configuration saved"
}

# Print summary
print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}============================================${NC}"
    echo -e "${GREEN}${BOLD}  Entra ID App Registration Complete${NC}"
    echo -e "${GREEN}${BOLD}============================================${NC}"
    echo ""
    echo -e "  ${BOLD}App Name:${NC}      ${APP_NAME}"
    echo -e "  ${BOLD}Client ID:${NC}     ${APP_ID}"
    echo -e "  ${BOLD}Tenant ID:${NC}     ${TENANT_ID}"
    echo -e "  ${BOLD}Object ID:${NC}     ${OBJECT_ID}"
    echo ""
    echo -e "  ${BOLD}OIDC Issuer:${NC}   https://login.microsoftonline.com/${TENANT_ID}/v2.0"
    echo ""
    echo -e "  ${DIM}Credentials saved to: terraform/entra-app.auto.tfvars${NC}"
    echo ""
    echo -e "  ${CYAN}${BOLD}Next Steps:${NC}"
    echo -e "  1. Run ${GREEN}./scripts/deploy.sh${NC} to deploy infrastructure"
    echo -e "  2. After deployment, add the LoadBalancer IP redirect URI:"
    echo -e "     ${DIM}http://<LB_IP>/api/v2/users/oidc/callback${NC}"
    echo ""
    echo -e "  ${YELLOW}Note:${NC} The client secret expires in 1 year."
    echo -e "  ${DIM}Set a reminder to rotate it before expiration.${NC}"
    echo ""
}

# Add redirect URI after deployment
add_redirect_uri() {
    local ip="$1"

    if [[ -z "${ip}" ]]; then
        echo "Usage: $0 add-redirect <IP_ADDRESS>"
        exit 1
    fi

    # Load config
    if [[ ! -f "${ENTRA_CONFIG_FILE}" ]]; then
        log_error "Entra app config not found. Run setup first."
        exit 1
    fi

    local app_id
    app_id=$(grep "entra_app_client_id" "${ENTRA_CONFIG_FILE}" | sed 's/.*= *"\(.*\)".*/\1/')

    log_info "Adding redirect URI for IP: ${ip}"

    # Get current redirect URIs
    local current_uris
    current_uris=$(az ad app show --id "${app_id}" --query "web.redirectUris" -o json)

    # Add new URI
    local new_uri="http://${ip}/api/v2/users/oidc/callback"

    # Check if already exists
    if echo "${current_uris}" | grep -q "${new_uri}"; then
        log_info "Redirect URI already exists"
        return
    fi

    # Update using Graph API
    local object_id
    object_id=$(az ad app show --id "${app_id}" --query "id" -o tsv)

    az rest --method PATCH \
        --uri "https://graph.microsoft.com/v1.0/applications/${object_id}" \
        --headers "Content-Type=application/json" \
        --body "{
            \"web\": {
                \"redirectUris\": $(echo "${current_uris}" | sed "s/]/, \"${new_uri}\"]/" )
            }
        }"

    log_success "Redirect URI added: ${new_uri}"
}

# Main
main() {
    echo ""
    echo -e "${CYAN}${BOLD}Entra ID App Registration Setup${NC}"
    echo -e "${DIM}────────────────────────────────────────${NC}"
    echo ""

    # Handle add-redirect subcommand
    if [[ "${1:-}" == "add-redirect" ]]; then
        add_redirect_uri "${2:-}"
        exit 0
    fi

    check_azure_login
    get_app_name
    check_existing_app
    create_app_registration
    configure_app
    create_client_secret
    create_service_principal
    save_configuration
    print_summary
}

main "$@"
