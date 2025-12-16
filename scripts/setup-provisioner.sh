#!/usr/bin/env bash
# Coder External Provisioner Setup Script
# Run this on local laptops/desktops to add them as provisioner resources
#
# Usage: ./setup-provisioner.sh [options]
#   --coder-url URL     Coder access URL (required)
#   --psk KEY           Pre-shared key (required, or set CODER_PROVISIONER_PSK)
#   --name NAME         Provisioner name (default: hostname)
#   --tags TAGS         Provisioner tags (e.g., "location:office,type:desktop")
#   --install-only      Only install Coder CLI, don't start provisioner
#   --systemd           Install as systemd service (Linux only)
#   --launchd           Install as launchd service (macOS only)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Default values
CODER_URL="${CODER_URL:-}"
PROVISIONER_PSK="${CODER_PROVISIONER_PSK:-}"
PROVISIONER_NAME="${HOSTNAME:-$(hostname)}"
PROVISIONER_TAGS="owner:local,type:endpoint"
INSTALL_ONLY=false
INSTALL_SYSTEMD=false
INSTALL_LAUNCHD=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --coder-url)
            CODER_URL="$2"
            shift 2
            ;;
        --psk)
            PROVISIONER_PSK="$2"
            shift 2
            ;;
        --name)
            PROVISIONER_NAME="$2"
            shift 2
            ;;
        --tags)
            PROVISIONER_TAGS="$2"
            shift 2
            ;;
        --install-only)
            INSTALL_ONLY=true
            shift
            ;;
        --systemd)
            INSTALL_SYSTEMD=true
            shift
            ;;
        --launchd)
            INSTALL_LAUNCHD=true
            shift
            ;;
        -h|--help)
            echo "Coder External Provisioner Setup"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --coder-url URL    Coder access URL (required)"
            echo "  --psk KEY          Pre-shared key (required)"
            echo "  --name NAME        Provisioner name (default: hostname)"
            echo "  --tags TAGS        Provisioner tags (default: owner:local,type:endpoint)"
            echo "  --install-only     Only install Coder CLI"
            echo "  --systemd          Install as systemd service (Linux)"
            echo "  --launchd          Install as launchd service (macOS)"
            echo ""
            echo "Environment variables:"
            echo "  CODER_URL              Alternative to --coder-url"
            echo "  CODER_PROVISIONER_PSK  Alternative to --psk"
            echo ""
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Linux*)  OS=linux ;;
        Darwin*) OS=macos ;;
        MINGW*|MSYS*|CYGWIN*) OS=windows ;;
        *)       OS=unknown ;;
    esac
    echo "${OS}"
}

OS=$(detect_os)

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if [[ "${OS}" == "unknown" ]]; then
        log_error "Unsupported operating system"
        exit 1
    fi

    # Check for Docker (required for most workspace types)
    if ! command -v docker &> /dev/null; then
        log_warn "Docker not found. Install Docker for container-based workspaces."
        log_info "  macOS: brew install --cask docker"
        log_info "  Linux: https://docs.docker.com/engine/install/"
        log_info "  Windows: https://docs.docker.com/desktop/install/windows-install/"
    else
        # Check if Docker daemon is running
        if ! docker info &> /dev/null; then
            log_warn "Docker is installed but not running. Start Docker daemon."
        else
            log_success "Docker is available and running"
        fi
    fi

    log_success "Prerequisites check completed"
}

# Install Coder CLI
install_coder_cli() {
    log_info "Installing Coder CLI..."

    if command -v coder &> /dev/null; then
        local current_version
        current_version=$(coder version 2>/dev/null | head -1 || echo "unknown")
        log_info "Coder CLI already installed: ${current_version}"

        read -p "  Reinstall/update? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Keeping existing installation"
            return 0
        fi
    fi

    case "${OS}" in
        linux|macos)
            curl -fsSL https://coder.com/install.sh | sh
            ;;
        windows)
            log_info "On Windows, install via:"
            log_info "  winget install Coder.Coder"
            log_info "  or download from: https://github.com/coder/coder/releases"
            exit 1
            ;;
    esac

    log_success "Coder CLI installed"
}

# Validate required parameters
validate_params() {
    if [[ "${INSTALL_ONLY}" == "true" ]]; then
        return 0
    fi

    if [[ -z "${CODER_URL}" ]]; then
        log_error "Coder URL is required. Use --coder-url or set CODER_URL"
        exit 1
    fi

    if [[ -z "${PROVISIONER_PSK}" ]]; then
        log_error "Pre-shared key is required. Use --psk or set CODER_PROVISIONER_PSK"
        log_info "Get the PSK from: terraform output -raw provisioner_psk"
        exit 1
    fi
}

# Test connectivity to Coder
test_connectivity() {
    log_info "Testing connectivity to Coder..."

    if curl -sf "${CODER_URL}/healthz" > /dev/null 2>&1; then
        log_success "Connected to Coder at ${CODER_URL}"
    else
        log_error "Cannot reach Coder at ${CODER_URL}"
        log_info "Ensure the URL is correct and accessible from this machine"
        exit 1
    fi
}

# Create systemd service (Linux)
create_systemd_service() {
    log_info "Creating systemd service..."

    local service_file="/etc/systemd/system/coder-provisioner.service"

    sudo tee "${service_file}" > /dev/null <<EOF
[Unit]
Description=Coder External Provisioner Daemon
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=${USER}
Environment="CODER_URL=${CODER_URL}"
ExecStart=$(which coder) provisionerd start --psk="${PROVISIONER_PSK}" --name="${PROVISIONER_NAME}" --tag="${PROVISIONER_TAGS}"
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable coder-provisioner
    sudo systemctl start coder-provisioner

    log_success "Systemd service created and started"
    log_info "  Check status: sudo systemctl status coder-provisioner"
    log_info "  View logs: sudo journalctl -u coder-provisioner -f"
}

# Create launchd service (macOS)
create_launchd_service() {
    log_info "Creating launchd service..."

    local plist_file="${HOME}/Library/LaunchAgents/com.coder.provisioner.plist"
    local log_dir="${HOME}/Library/Logs/coder-provisioner"

    mkdir -p "${log_dir}"

    cat > "${plist_file}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.coder.provisioner</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(which coder)</string>
        <string>provisionerd</string>
        <string>start</string>
        <string>--psk=${PROVISIONER_PSK}</string>
        <string>--name=${PROVISIONER_NAME}</string>
        <string>--tag=${PROVISIONER_TAGS}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CODER_URL</key>
        <string>${CODER_URL}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${log_dir}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${log_dir}/stderr.log</string>
</dict>
</plist>
EOF

    launchctl unload "${plist_file}" 2>/dev/null || true
    launchctl load "${plist_file}"

    log_success "Launchd service created and started"
    log_info "  Check status: launchctl list | grep coder"
    log_info "  View logs: tail -f ${log_dir}/stdout.log"
}

# Run provisioner interactively
run_provisioner() {
    log_info "Starting provisioner daemon..."
    log_info "  Name: ${PROVISIONER_NAME}"
    log_info "  Tags: ${PROVISIONER_TAGS}"
    log_info "  URL: ${CODER_URL}"
    echo ""
    log_info "Press Ctrl+C to stop the provisioner"
    echo ""

    export CODER_URL
    exec coder provisionerd start \
        --psk="${PROVISIONER_PSK}" \
        --name="${PROVISIONER_NAME}" \
        --tag="${PROVISIONER_TAGS}"
}

# Print summary
print_summary() {
    echo ""
    echo "=============================================="
    echo "  Provisioner Setup Complete"
    echo "=============================================="
    echo ""
    echo "  Provisioner Name: ${PROVISIONER_NAME}"
    echo "  Tags: ${PROVISIONER_TAGS}"
    echo "  Coder URL: ${CODER_URL}"
    echo ""
    echo "  Next Steps:"
    echo "  1. Create a template that targets this provisioner's tags"
    echo "  2. In your Terraform template, use:"
    echo ""
    echo "     data \"coder_provisioner\" \"me\" {"
    echo "       tags = {"
    echo "         \"owner\" = \"local\""
    echo "         \"type\"  = \"endpoint\""
    echo "       }"
    echo "     }"
    echo ""
    echo "  3. Users can then create workspaces that run on this machine"
    echo ""
    echo "=============================================="
}

# Main
main() {
    echo ""
    echo "=============================================="
    echo "  Coder External Provisioner Setup"
    echo "=============================================="
    echo ""

    check_prerequisites
    install_coder_cli

    if [[ "${INSTALL_ONLY}" == "true" ]]; then
        log_success "Coder CLI installed. Run again without --install-only to configure provisioner."
        exit 0
    fi

    validate_params
    test_connectivity

    if [[ "${INSTALL_SYSTEMD}" == "true" ]]; then
        if [[ "${OS}" != "linux" ]]; then
            log_error "Systemd is only available on Linux"
            exit 1
        fi
        create_systemd_service
        print_summary
    elif [[ "${INSTALL_LAUNCHD}" == "true" ]]; then
        if [[ "${OS}" != "macos" ]]; then
            log_error "Launchd is only available on macOS"
            exit 1
        fi
        create_launchd_service
        print_summary
    else
        print_summary
        run_provisioner
    fi
}

main "$@"
