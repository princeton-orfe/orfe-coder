#!/usr/bin/env bash
# Coder WireGuard Client Setup Script
# Generates WireGuard client configuration for team members

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

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

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║${NC}          ${CYAN}WireGuard Client Configuration${NC}                    ${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v wg &> /dev/null; then
        log_warn "WireGuard tools not found"
        echo ""
        echo "  Install WireGuard:"
        echo "    macOS:   brew install wireguard-tools"
        echo "    Ubuntu:  sudo apt install wireguard-tools"
        echo "    Windows: Download from https://www.wireguard.com/install/"
        echo ""

        echo -ne "  Continue without wg tools? (keys will need manual generation) [y/N]: "
        read -n 1 continue_answer
        echo ""
        if [[ ! "${continue_answer}" =~ ^[Yy]$ ]]; then
            exit 1
        fi
        WG_AVAILABLE=false
    else
        WG_AVAILABLE=true
        log_success "WireGuard tools installed"
    fi
}

# Get Terraform outputs
get_terraform_outputs() {
    log_info "Reading deployment configuration..."

    cd "${TERRAFORM_DIR}"

    if [[ ! -f "terraform.tfstate" ]]; then
        log_error "Terraform state not found. Deploy infrastructure first."
        exit 1
    fi

    NETWORK_TYPE=$(terraform output -raw network_access_type 2>/dev/null || echo "")

    if [[ "${NETWORK_TYPE}" != "wireguard" ]]; then
        log_error "WireGuard is not enabled in this deployment"
        log_info "Current network_access_type: ${NETWORK_TYPE}"
        log_info "To enable WireGuard, set network_access_type = \"wireguard\" in terraform.tfvars"
        exit 1
    fi

    WG_ENDPOINT=$(terraform output -raw wireguard_endpoint 2>/dev/null || echo "PENDING:51820")
    WG_NETWORK=$(terraform output -json 2>/dev/null | jq -r '.wireguard_client_config_template.value' | grep -oP 'AllowedIPs = \K[^,]+' || echo "10.10.0.0/24")

    # Get server private key to derive public key
    SERVER_PRIVKEY=$(cd "${TERRAFORM_DIR}" && terraform output -json 2>/dev/null | jq -r '.wireguard_server_public_key.value' | grep -oP "echo '\K[^']+")

    if [[ "${WG_AVAILABLE}" == "true" ]] && [[ -n "${SERVER_PRIVKEY}" ]]; then
        SERVER_PUBKEY=$(echo "${SERVER_PRIVKEY}" | wg pubkey)
    else
        SERVER_PUBKEY="<RUN: terraform output -raw wireguard_server_public_key>"
    fi

    log_success "Configuration loaded"
}

# Generate client keys
generate_client_keys() {
    local name="$1"

    if [[ "${WG_AVAILABLE}" == "true" ]]; then
        CLIENT_PRIVKEY=$(wg genkey)
        CLIENT_PUBKEY=$(echo "${CLIENT_PRIVKEY}" | wg pubkey)
    else
        CLIENT_PRIVKEY="<GENERATE WITH: wg genkey>"
        CLIENT_PUBKEY="<GENERATE WITH: echo 'PRIVATE_KEY' | wg pubkey>"
    fi
}

# Get next available IP
get_next_ip() {
    # Simple approach: prompt user for IP assignment
    # In production, you'd want to track assignments
    echo -ne "  ${BOLD}Assign IP address${NC} ${DIM}(e.g., 10.10.0.2)${NC}: "
    read CLIENT_IP

    if [[ -z "${CLIENT_IP}" ]]; then
        CLIENT_IP="10.10.0.2"
    fi
}

# Generate client configuration
generate_config() {
    local name="$1"
    local output_file="$2"

    cat > "${output_file}" <<EOF
# WireGuard Configuration for: ${name}
# Generated: $(date)
#
# Import this file into your WireGuard client:
#   - macOS/iOS: WireGuard app → Import from file
#   - Linux: sudo cp ${output_file} /etc/wireguard/coder.conf
#   - Windows: WireGuard app → Import tunnel from file

[Interface]
# Your private key (keep secret!)
PrivateKey = ${CLIENT_PRIVKEY}

# Your VPN IP address
Address = ${CLIENT_IP}/24

# Use cluster DNS for service discovery
DNS = 10.1.0.10

[Peer]
# Coder WireGuard server
PublicKey = ${SERVER_PUBKEY}

# Server endpoint
Endpoint = ${WG_ENDPOINT}

# Route VPN network and cluster networks through tunnel
AllowedIPs = 10.10.0.0/24, 10.0.0.0/16, 10.1.0.0/16

# Keep connection alive (important for NAT traversal)
PersistentKeepalive = 25
EOF

    log_success "Configuration saved to: ${output_file}"
}

# Print server peer config (to add to server)
print_server_peer_config() {
    local name="$1"

    echo ""
    echo -e "${YELLOW}${BOLD}Add this peer to your Terraform configuration:${NC}"
    echo ""
    echo -e "${DIM}# In terraform.tfvars, add to wireguard_peers:${NC}"
    echo ""
    cat <<EOF
wireguard_peers = [
  # ... existing peers ...
  {
    name       = "${name}"
    public_key = "${CLIENT_PUBKEY}"
  },
]
EOF
    echo ""
    echo -e "${DIM}Then run: ./scripts/deploy.sh to update the server${NC}"
}

# Print connection instructions
print_instructions() {
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║${NC}              ${GREEN}Client Setup Complete!${NC}                          ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Next Steps:${NC}"
    echo ""
    echo -e "  1. ${CYAN}Add peer to server${NC}"
    echo "     Update terraform.tfvars with the peer config shown above"
    echo "     Run: ./scripts/deploy.sh"
    echo ""
    echo -e "  2. ${CYAN}Import client config${NC}"
    echo "     Import the generated .conf file into WireGuard app"
    echo ""
    echo -e "  3. ${CYAN}Connect to VPN${NC}"
    echo "     Activate the tunnel in WireGuard"
    echo ""
    echo -e "  4. ${CYAN}Access Coder${NC}"
    echo "     Open: http://coder.coder.svc.cluster.local"
    echo "     Or:   http://10.1.x.x (find with: kubectl get svc -n coder)"
    echo ""
}

# Interactive client setup
interactive_setup() {
    print_header
    check_prerequisites
    get_terraform_outputs

    echo ""
    echo -ne "  ${BOLD}Team member name${NC} ${DIM}(e.g., alice, bob)${NC}: "
    read CLIENT_NAME

    if [[ -z "${CLIENT_NAME}" ]]; then
        log_error "Name is required"
        exit 1
    fi

    # Sanitize name for filename
    SAFE_NAME=$(echo "${CLIENT_NAME}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-')
    OUTPUT_FILE="${SCRIPT_DIR}/../wireguard-${SAFE_NAME}.conf"

    get_next_ip
    generate_client_keys "${CLIENT_NAME}"
    generate_config "${CLIENT_NAME}" "${OUTPUT_FILE}"
    print_server_peer_config "${CLIENT_NAME}"
    print_instructions

    echo -e "  ${BOLD}Configuration file:${NC} ${OUTPUT_FILE}"
    echo ""

    # Add to gitignore reminder
    log_warn "Remember: Don't commit .conf files to git (they contain private keys)"
}

# Show help
show_help() {
    echo "WireGuard Client Configuration Generator"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -l, --list     List configured peers from terraform.tfvars"
    echo ""
    echo "Run without options for interactive setup."
}

# List existing peers
list_peers() {
    log_info "Configured WireGuard peers:"
    echo ""

    cd "${TERRAFORM_DIR}"

    if [[ -f "terraform.tfvars" ]]; then
        grep -A 10 "wireguard_peers" terraform.tfvars 2>/dev/null || echo "  No peers configured"
    else
        echo "  terraform.tfvars not found"
    fi
}

# Main
case "${1:-}" in
    -h|--help)
        show_help
        ;;
    -l|--list)
        list_peers
        ;;
    *)
        interactive_setup
        ;;
esac
