#!/usr/bin/env bash
# Coder PostgreSQL Database Backup Script
# Exports database to Azure Blob Storage for long-term retention
#
# Usage: ./backup-database.sh [options]
#   --export-to-blob    Export backup to Azure Blob Storage
#   --list-backups      List available point-in-time restore points
#   --restore           Restore to a new server from backup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

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

ACTION=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --export-to-blob)
            ACTION="export"
            shift
            ;;
        --list-backups)
            ACTION="list"
            shift
            ;;
        --restore)
            ACTION="restore"
            shift
            ;;
        -h|--help)
            echo "Coder PostgreSQL Database Backup Management"
            echo ""
            echo "Usage: $0 [action]"
            echo ""
            echo "Actions:"
            echo "  --export-to-blob  Export current database to Azure Blob Storage"
            echo "  --list-backups    List available restore points"
            echo "  --restore         Restore database to a new server"
            echo ""
            echo "Without arguments: Shows backup status and options"
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

    if ! command -v az &> /dev/null; then
        log_error "Azure CLI not found. Install from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi

    if ! az account show &> /dev/null; then
        log_error "Not logged into Azure CLI. Run: az login"
        exit 1
    fi

    log_success "Prerequisites OK"
}

# Get Terraform outputs
get_terraform_outputs() {
    cd "${TERRAFORM_DIR}"

    if [[ ! -f "terraform.tfstate" ]]; then
        log_error "Terraform state not found. Deploy infrastructure first."
        exit 1
    fi

    RESOURCE_GROUP=$(terraform output -raw resource_group_name 2>/dev/null)
    POSTGRES_SERVER=$(terraform output -json postgres_backup_info 2>/dev/null | jq -r '.restore_command' | grep -oP '(?<=--source-server )\S+' || echo "")

    # Extract server name from the restore command
    if [[ -z "${POSTGRES_SERVER}" ]]; then
        # Fallback: get from postgres FQDN
        local fqdn
        fqdn=$(terraform output -raw postgres_server_fqdn 2>/dev/null || echo "")
        POSTGRES_SERVER=$(echo "${fqdn}" | cut -d. -f1)
    fi

    STORAGE_ACCOUNT=$(terraform output -raw backup_storage_account_name 2>/dev/null || echo "")

    if [[ -z "${RESOURCE_GROUP}" ]] || [[ -z "${POSTGRES_SERVER}" ]]; then
        log_error "Could not retrieve infrastructure details from Terraform state"
        exit 1
    fi
}

# Show backup status
show_status() {
    log_info "PostgreSQL Backup Status"
    echo ""

    cd "${TERRAFORM_DIR}"
    local backup_info
    backup_info=$(terraform output -json postgres_backup_info 2>/dev/null || echo "{}")

    echo "  Server: ${POSTGRES_SERVER}"
    echo "  Resource Group: ${RESOURCE_GROUP}"
    echo "  Retention: $(echo "${backup_info}" | jq -r '.retention_days // "N/A"') days"
    echo "  Geo-Redundant: $(echo "${backup_info}" | jq -r '.geo_redundant // "N/A"')"
    echo ""

    # Get backup info from Azure
    log_info "Querying Azure for backup details..."

    local earliest_restore
    earliest_restore=$(az postgres flexible-server show \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${POSTGRES_SERVER}" \
        --query "backup.earliestRestoreDate" -o tsv 2>/dev/null || echo "N/A")

    echo "  Earliest Restore Point: ${earliest_restore}"
    echo "  Latest Restore Point: Now (continuous backup)"
    echo ""

    if [[ -n "${STORAGE_ACCOUNT}" ]] && [[ "${STORAGE_ACCOUNT}" != "Backup export not enabled" ]]; then
        log_info "Blob Storage Exports"
        echo "  Storage Account: ${STORAGE_ACCOUNT}"

        local blob_count
        blob_count=$(az storage blob list \
            --account-name "${STORAGE_ACCOUNT}" \
            --container-name "database-backups" \
            --query "length(@)" -o tsv 2>/dev/null || echo "0")
        echo "  Exported Backups: ${blob_count}"
    fi

    echo ""
    echo "Available Actions:"
    echo "  $0 --list-backups       Show restore points"
    echo "  $0 --export-to-blob     Export database to blob storage"
    echo "  $0 --restore            Restore to new server"
}

# List available backups
list_backups() {
    log_info "Available Restore Points"
    echo ""

    # Point-in-time restore window
    local earliest_restore
    earliest_restore=$(az postgres flexible-server show \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${POSTGRES_SERVER}" \
        --query "backup.earliestRestoreDate" -o tsv 2>/dev/null || echo "N/A")

    echo "Point-in-Time Restore Window:"
    echo "  From: ${earliest_restore}"
    echo "  To: $(date -u +"%Y-%m-%dT%H:%M:%SZ") (now)"
    echo ""

    # Blob storage backups
    if [[ -n "${STORAGE_ACCOUNT}" ]] && [[ "${STORAGE_ACCOUNT}" != "Backup export not enabled" ]]; then
        echo "Blob Storage Exports:"
        az storage blob list \
            --account-name "${STORAGE_ACCOUNT}" \
            --container-name "database-backups" \
            --query "[].{Name:name, Created:properties.creationTime, Size:properties.contentLength}" \
            --output table 2>/dev/null || echo "  No exports found"
    fi
}

# Export database to blob storage
export_to_blob() {
    log_info "Exporting database to Azure Blob Storage..."

    if [[ -z "${STORAGE_ACCOUNT}" ]] || [[ "${STORAGE_ACCOUNT}" == "Backup export not enabled" ]]; then
        log_error "Blob storage export not enabled. Set enable_backup_export = true in terraform.tfvars"
        exit 1
    fi

    # Get database connection info
    cd "${TERRAFORM_DIR}"
    local db_url
    db_url=$(terraform output -raw postgres_admin_password 2>/dev/null || echo "")

    if [[ -z "${db_url}" ]]; then
        log_error "Could not retrieve database credentials"
        exit 1
    fi

    # Create backup filename
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="coder_backup_${timestamp}.sql.gz"
    local temp_file="/tmp/${backup_file}"

    log_info "Creating database dump..."

    # Get connection details
    local pg_host
    pg_host=$(terraform output -raw postgres_server_fqdn 2>/dev/null)
    local pg_pass
    pg_pass=$(terraform output -raw postgres_admin_password 2>/dev/null)

    # Note: For Azure PostgreSQL Flexible Server with private networking,
    # you need to run this from within the VNet or use a jump host
    log_warn "Note: Database export requires network access to PostgreSQL"
    log_info "For private networking, run from AKS or configure VPN access"
    echo ""

    # Option 1: Use kubectl to exec into a pod
    log_info "Attempting export via kubectl..."

    # Check if we can reach the cluster
    if ! kubectl get pods -n coder &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        log_info "Run: $(terraform output -raw kubeconfig_command)"
        exit 1
    fi

    # Create a job to perform the backup
    local job_name="db-backup-${timestamp}"

    kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: coder
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: backup
        image: postgres:15
        command:
        - /bin/bash
        - -c
        - |
          pg_dump "\${DATABASE_URL}" | gzip > /backup/backup.sql.gz
          echo "Backup complete: \$(ls -lh /backup/backup.sql.gz)"
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: coder-db-credentials
              key: url
        volumeMounts:
        - name: backup
          mountPath: /backup
      volumes:
      - name: backup
        emptyDir: {}
EOF

    log_info "Waiting for backup job to complete..."
    kubectl wait --for=condition=complete --timeout=300s job/${job_name} -n coder

    # Copy backup from pod
    local pod_name
    pod_name=$(kubectl get pods -n coder -l job-name=${job_name} -o jsonpath='{.items[0].metadata.name}')
    kubectl cp "coder/${pod_name}:/backup/backup.sql.gz" "${temp_file}"

    # Upload to blob storage
    log_info "Uploading to blob storage..."
    az storage blob upload \
        --account-name "${STORAGE_ACCOUNT}" \
        --container-name "database-backups" \
        --name "${backup_file}" \
        --file "${temp_file}" \
        --overwrite

    # Cleanup
    rm -f "${temp_file}"
    kubectl delete job ${job_name} -n coder

    log_success "Backup exported to: ${STORAGE_ACCOUNT}/database-backups/${backup_file}"
}

# Restore database
restore_database() {
    log_info "Database Restore"
    echo ""

    echo "Restore Options:"
    echo ""
    echo "1. Point-in-Time Restore (recommended for recent data)"
    echo "   Creates a new PostgreSQL server from backup"
    echo ""
    echo "2. Restore from Blob Export (for older backups)"
    echo "   Restores from a pg_dump export"
    echo ""

    read -p "Select option [1/2]: " restore_option

    case ${restore_option} in
        1)
            restore_point_in_time
            ;;
        2)
            restore_from_blob
            ;;
        *)
            log_error "Invalid option"
            exit 1
            ;;
    esac
}

restore_point_in_time() {
    log_info "Point-in-Time Restore"
    echo ""

    local earliest_restore
    earliest_restore=$(az postgres flexible-server show \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${POSTGRES_SERVER}" \
        --query "backup.earliestRestoreDate" -o tsv 2>/dev/null)

    echo "Available restore window:"
    echo "  From: ${earliest_restore}"
    echo "  To: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo ""

    read -p "Enter restore point (ISO8601 format, e.g., 2024-01-15T10:30:00Z): " restore_time
    read -p "Enter new server name: " new_server_name

    log_info "Creating new server from point-in-time backup..."

    az postgres flexible-server restore \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${new_server_name}" \
        --source-server "${POSTGRES_SERVER}" \
        --restore-time "${restore_time}"

    log_success "Restore complete. New server: ${new_server_name}"
    log_info "Update Coder's DATABASE_URL to point to the new server"
}

restore_from_blob() {
    log_info "Restore from Blob Export"
    echo ""

    if [[ -z "${STORAGE_ACCOUNT}" ]] || [[ "${STORAGE_ACCOUNT}" == "Backup export not enabled" ]]; then
        log_error "No blob exports available"
        exit 1
    fi

    echo "Available backups:"
    az storage blob list \
        --account-name "${STORAGE_ACCOUNT}" \
        --container-name "database-backups" \
        --query "[].name" -o tsv

    echo ""
    read -p "Enter backup filename: " backup_file

    log_info "To restore from blob export:"
    echo ""
    echo "1. Download the backup:"
    echo "   az storage blob download --account-name ${STORAGE_ACCOUNT} \\"
    echo "     --container-name database-backups --name ${backup_file} \\"
    echo "     --file backup.sql.gz"
    echo ""
    echo "2. Restore to database:"
    echo "   gunzip -c backup.sql.gz | psql \"\${DATABASE_URL}\""
    echo ""
    echo "Note: This will overwrite existing data in the target database"
}

# Main
main() {
    check_prerequisites
    get_terraform_outputs

    case "${ACTION}" in
        "")
            show_status
            ;;
        "export")
            export_to_blob
            ;;
        "list")
            list_backups
            ;;
        "restore")
            restore_database
            ;;
    esac
}

main "$@"
