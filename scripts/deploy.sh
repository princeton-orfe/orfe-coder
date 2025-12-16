#!/usr/bin/env bash
# Coder on Azure AKS - Automated Deployment Script
# Usage: ./deploy.sh [--plan-only] [--auto-approve]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"
PLAN_ONLY=false
AUTO_APPROVE=false

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
        --plan-only)
            PLAN_ONLY=true
            shift
            ;;
        --auto-approve)
            AUTO_APPROVE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--plan-only] [--auto-approve]"
            echo ""
            echo "Options:"
            echo "  --plan-only     Run terraform plan only, do not apply"
            echo "  --auto-approve  Skip interactive approval prompts"
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

    local missing_tools=()

    if ! command -v terraform &> /dev/null; then
        missing_tools+=("terraform")
    fi

    if ! command -v az &> /dev/null; then
        missing_tools+=("az (Azure CLI)")
    fi

    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi

    if ! command -v helm &> /dev/null; then
        missing_tools+=("helm")
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        echo ""
        echo "Install instructions:"
        echo "  terraform: https://developer.hashicorp.com/terraform/install"
        echo "  az:        https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        echo "  kubectl:   https://kubernetes.io/docs/tasks/tools/"
        echo "  helm:      https://helm.sh/docs/intro/install/"
        exit 1
    fi

    log_success "All prerequisites installed"
}

# Check Azure authentication
check_azure_auth() {
    log_info "Checking Azure authentication..."

    if [[ -z "${ARM_CLIENT_ID:-}" ]] || [[ -z "${ARM_CLIENT_SECRET:-}" ]] || \
       [[ -z "${ARM_SUBSCRIPTION_ID:-}" ]] || [[ -z "${ARM_TENANT_ID:-}" ]]; then

        log_warn "ARM_* environment variables not set. Checking Azure CLI login..."

        if ! az account show &> /dev/null; then
            log_error "Not authenticated to Azure. Please either:"
            echo "  1. Set environment variables: ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_SUBSCRIPTION_ID, ARM_TENANT_ID"
            echo "  2. Run: az login"
            exit 1
        fi

        log_info "Using Azure CLI authentication"
    else
        log_success "Using service principal authentication"
    fi
}

# Check tfvars file
check_tfvars() {
    log_info "Checking Terraform configuration..."

    if [[ ! -f "${TERRAFORM_DIR}/terraform.tfvars" ]]; then
        if [[ -f "${TERRAFORM_DIR}/terraform.tfvars.example" ]]; then
            log_error "terraform.tfvars not found. Copy and customize the example:"
            echo "  cp ${TERRAFORM_DIR}/terraform.tfvars.example ${TERRAFORM_DIR}/terraform.tfvars"
            echo "  # Edit terraform.tfvars with your values"
        else
            log_error "terraform.tfvars not found"
        fi
        exit 1
    fi

    log_success "terraform.tfvars found"
}

# Initialize Terraform
init_terraform() {
    log_info "Initializing Terraform..."

    cd "${TERRAFORM_DIR}"

    if ! terraform init -upgrade; then
        log_error "Terraform init failed"
        exit 1
    fi

    log_success "Terraform initialized"
}

# Validate Terraform configuration
validate_terraform() {
    log_info "Validating Terraform configuration..."

    cd "${TERRAFORM_DIR}"

    if ! terraform validate; then
        log_error "Terraform validation failed"
        exit 1
    fi

    log_success "Terraform configuration is valid"
}

# Plan Terraform changes
plan_terraform() {
    log_info "Planning Terraform changes..."

    cd "${TERRAFORM_DIR}"

    terraform plan -out=tfplan

    log_success "Terraform plan completed"

    if [[ "${PLAN_ONLY}" == "true" ]]; then
        log_info "Plan-only mode. Exiting without applying."
        exit 0
    fi
}

# Apply Terraform changes
apply_terraform() {
    log_info "Applying Terraform changes..."

    cd "${TERRAFORM_DIR}"

    local apply_args=()
    if [[ "${AUTO_APPROVE}" == "true" ]]; then
        apply_args+=("-auto-approve")
    fi

    if ! terraform apply "${apply_args[@]}" tfplan; then
        log_error "Terraform apply failed"
        exit 1
    fi

    log_success "Terraform apply completed"
}

# Configure kubectl
configure_kubectl() {
    log_info "Configuring kubectl..."

    cd "${TERRAFORM_DIR}"

    local kubeconfig_cmd
    kubeconfig_cmd=$(terraform output -raw kubeconfig_command 2>/dev/null || echo "")

    if [[ -n "${kubeconfig_cmd}" ]]; then
        eval "${kubeconfig_cmd}"
        log_success "kubectl configured"
    else
        log_warn "Could not retrieve kubeconfig command from Terraform outputs"
    fi
}

# Wait for Coder deployment
wait_for_coder() {
    log_info "Waiting for Coder deployment to be ready..."

    local max_attempts=60
    local attempt=1

    while [[ ${attempt} -le ${max_attempts} ]]; do
        if kubectl get pods -n coder -l app.kubernetes.io/name=coder 2>/dev/null | grep -q "Running"; then
            log_success "Coder pods are running"
            break
        fi

        echo -ne "\r  Waiting for pods... (attempt ${attempt}/${max_attempts})"
        sleep 5
        ((attempt++))
    done

    echo ""

    if [[ ${attempt} -gt ${max_attempts} ]]; then
        log_warn "Timeout waiting for Coder pods. Check with: kubectl get pods -n coder"
    fi
}

# Wait for LoadBalancer IP
wait_for_lb() {
    log_info "Waiting for LoadBalancer IP..."

    local max_attempts=30
    local attempt=1
    local lb_ip=""

    while [[ ${attempt} -le ${max_attempts} ]]; do
        lb_ip=$(kubectl get svc -n coder coder -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

        if [[ -n "${lb_ip}" ]]; then
            log_success "LoadBalancer IP: ${lb_ip}"
            break
        fi

        echo -ne "\r  Waiting for IP... (attempt ${attempt}/${max_attempts})"
        sleep 10
        ((attempt++))
    done

    echo ""

    if [[ -z "${lb_ip}" ]]; then
        log_warn "Could not get LoadBalancer IP. Check with: kubectl get svc -n coder"
    fi
}

# Print deployment summary
print_summary() {
    log_info "Deployment Summary"
    echo ""

    cd "${TERRAFORM_DIR}"

    echo "=============================================="
    echo "  Coder Deployment Complete"
    echo "=============================================="
    echo ""

    local coder_url
    coder_url=$(terraform output -raw coder_access_url 2>/dev/null || echo "Unknown")
    echo "  Coder URL: ${coder_url}"

    local lb_ip
    lb_ip=$(terraform output -raw coder_load_balancer_ip 2>/dev/null || echo "Unknown")
    echo "  LoadBalancer IP: ${lb_ip}"

    local client_id
    client_id=$(terraform output -raw entra_id_app_client_id 2>/dev/null || echo "Unknown")
    echo "  Entra ID App Client ID: ${client_id}"

    echo ""
    echo "  Next Steps:"
    echo "  1. Configure DNS (if using custom domain):"
    terraform output -raw dns_configuration 2>/dev/null || echo "     No custom domain configured"
    echo ""
    echo "  2. Access Coder and create initial admin account"
    echo "  3. Import Kubernetes workspace template"
    echo ""
    echo "  Useful Commands:"
    echo "    kubectl get pods -n coder     # Check pod status"
    echo "    kubectl logs -n coder -l app.kubernetes.io/name=coder  # View logs"
    echo "    ./scripts/teardown.sh         # Destroy infrastructure"
    echo ""
    echo "=============================================="
}

# Main execution
main() {
    echo ""
    echo "=============================================="
    echo "  Coder on Azure AKS - Deployment"
    echo "=============================================="
    echo ""

    check_prerequisites
    check_azure_auth
    check_tfvars
    init_terraform
    validate_terraform
    plan_terraform
    apply_terraform
    configure_kubectl
    wait_for_coder
    wait_for_lb
    print_summary

    log_success "Deployment complete!"
}

main "$@"
