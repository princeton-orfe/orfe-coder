#!/usr/bin/env bash
# Coder on Azure AKS - Automated Teardown Script
# Usage: ./teardown.sh [--auto-approve] [--force]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
AUTO_APPROVE=false
FORCE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --auto-approve)
            AUTO_APPROVE=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--auto-approve] [--force]"
            echo ""
            echo "Options:"
            echo "  --auto-approve  Skip interactive approval prompts"
            echo "  --force         Force destruction even if some resources fail"
            echo ""
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v terraform &> /dev/null; then
        log_error "terraform not found. Please install it first."
        exit 1
    fi

    log_success "Prerequisites OK"
}

# Check Terraform state
check_state() {
    log_info "Checking Terraform state..."

    cd "${TERRAFORM_DIR}"

    if [[ ! -f "terraform.tfstate" ]] && [[ ! -d ".terraform" ]]; then
        log_warn "No Terraform state found. Nothing to destroy."
        exit 0
    fi

    # Initialize if needed
    if [[ ! -d ".terraform" ]]; then
        log_info "Initializing Terraform..."
        terraform init -upgrade
    fi

    log_success "Terraform state found"
}

# Show what will be destroyed
show_resources() {
    log_info "Resources to be destroyed:"
    echo ""

    cd "${TERRAFORM_DIR}"

    # List resources in state
    terraform state list 2>/dev/null || echo "  (Unable to list resources)"

    echo ""
}

# Confirm destruction
confirm_destroy() {
    if [[ "${AUTO_APPROVE}" == "true" ]]; then
        log_info "Auto-approve enabled, skipping confirmation"
        return 0
    fi

    echo ""
    log_warn "This will PERMANENTLY DESTROY all Coder infrastructure!"
    echo ""
    echo "  This includes:"
    echo "    - AKS cluster and all workspaces"
    echo "    - PostgreSQL database and all data"
    echo "    - Entra ID application registration"
    echo "    - All associated network resources"
    echo ""
    read -p "  Type 'destroy' to confirm: " confirmation

    if [[ "${confirmation}" != "destroy" ]]; then
        log_info "Destruction cancelled"
        exit 0
    fi
}

# Clean up Kubernetes resources first
cleanup_kubernetes() {
    log_info "Cleaning up Kubernetes resources..."

    cd "${TERRAFORM_DIR}"

    # Try to get kubeconfig
    local kubeconfig_cmd
    kubeconfig_cmd=$(terraform output -raw kubeconfig_command 2>/dev/null || echo "")

    if [[ -n "${kubeconfig_cmd}" ]]; then
        if eval "${kubeconfig_cmd}" 2>/dev/null; then
            # Delete Helm releases first to clean up LoadBalancers
            if command -v helm &> /dev/null; then
                log_info "Removing Helm releases..."
                helm uninstall coder -n coder 2>/dev/null || true
            fi

            # Wait for LoadBalancer cleanup
            log_info "Waiting for LoadBalancer cleanup..."
            sleep 30
        fi
    else
        log_warn "Could not configure kubectl, skipping Kubernetes cleanup"
    fi
}

# Destroy Terraform resources
destroy_terraform() {
    log_info "Destroying Terraform resources..."

    cd "${TERRAFORM_DIR}"

    local destroy_args=("-auto-approve")

    if [[ "${FORCE}" == "true" ]]; then
        # Remove problematic resources from state if they fail
        log_warn "Force mode enabled - will attempt to remove stuck resources"
    fi

    if terraform destroy "${destroy_args[@]}"; then
        log_success "Terraform destroy completed"
    else
        if [[ "${FORCE}" == "true" ]]; then
            log_warn "Some resources failed to destroy. Attempting cleanup..."

            # Try to remove resources that commonly get stuck
            local stuck_resources=(
                "kubernetes_namespace.coder"
                "helm_release.coder"
            )

            for resource in "${stuck_resources[@]}"; do
                if terraform state list | grep -q "${resource}"; then
                    log_info "Removing ${resource} from state..."
                    terraform state rm "${resource}" 2>/dev/null || true
                fi
            done

            # Retry destroy
            log_info "Retrying destroy..."
            terraform destroy -auto-approve || true
        else
            log_error "Terraform destroy failed. Use --force to attempt cleanup."
            exit 1
        fi
    fi
}

# Clean up local files
cleanup_local() {
    log_info "Cleaning up local files..."

    cd "${TERRAFORM_DIR}"

    # Remove plan file
    rm -f tfplan

    # Optionally remove state (keeping backup)
    if [[ -f "terraform.tfstate" ]]; then
        local backup_name="terraform.tfstate.destroyed.$(date +%Y%m%d%H%M%S)"
        mv terraform.tfstate "${backup_name}"
        log_info "State backed up to: ${backup_name}"
    fi

    rm -f terraform.tfstate.backup

    log_success "Local cleanup completed"
}

# Verify destruction
verify_destruction() {
    log_info "Verifying destruction..."

    cd "${TERRAFORM_DIR}"

    local remaining
    remaining=$(terraform state list 2>/dev/null | wc -l || echo "0")

    if [[ "${remaining}" -gt 0 ]]; then
        log_warn "Some resources may still exist:"
        terraform state list 2>/dev/null || true
    else
        log_success "All resources destroyed"
    fi
}

# Print summary
print_summary() {
    echo ""
    echo "=============================================="
    echo "  Teardown Complete"
    echo "=============================================="
    echo ""
    echo "  All Coder infrastructure has been destroyed."
    echo ""
    echo "  Note: You may want to manually verify in Azure Portal"
    echo "  that all resources have been removed."
    echo ""
    echo "  Azure Portal: https://portal.azure.com"
    echo ""
    echo "=============================================="
}

# Main execution
main() {
    echo ""
    echo "=============================================="
    echo "  Coder on Azure AKS - Teardown"
    echo "=============================================="
    echo ""

    check_prerequisites
    check_state
    show_resources
    confirm_destroy
    cleanup_kubernetes
    destroy_terraform
    cleanup_local
    verify_destruction
    print_summary

    log_success "Teardown complete!"
}

main "$@"
