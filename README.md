# ORFE Coder

Automated deployment of [Coder](https://coder.com) for departmental development environments on Azure Kubernetes Service (AKS) with Entra ID (Azure AD) authentication.

## Architecture

```
                           ┌──────────────────────────────────────────────────────┐
                           │                    Azure Cloud                        │
                           │  ┌────────────────────────────────────────────────┐  │
                           │  │              Resource Group                     │  │
┌──────────────┐           │  │                                                 │  │
│    Users     │──OIDC────▶│  │  ┌─────────────────────────────────────────┐   │  │
└──────────────┘           │  │  │           AKS Cluster                    │   │  │
                           │  │  │  ┌─────────────────────────────────┐    │   │  │
                           │  │  │  │  Coder Control Plane            │    │   │  │
                           │  │  │  │  - API Server                   │    │   │  │
                           │  │  │  │  - Built-in Provisioner         │    │   │  │
                           │  │  │  └─────────────────────────────────┘    │   │  │
                           │  │  │              │                           │   │  │
                           │  │  │              ▼                           │   │  │
                           │  │  │  ┌─────────────────────────────────┐    │   │  │
                           │  │  │  │  Cloud Workspaces (K8s pods)    │    │   │  │
                           │  │  │  └─────────────────────────────────┘    │   │  │
                           │  │  └─────────────────────────────────────────┘   │  │
                           │  │              │                                  │  │
                           │  │              ▼                                  │  │
                           │  │  ┌─────────────────────┐  ┌─────────────────┐  │  │
                           │  │  │  PostgreSQL Server  │  │  Blob Storage   │  │  │
                           │  │  │  (Private Network)  │  │  (Backups)      │  │  │
                           │  │  └─────────────────────┘  └─────────────────┘  │  │
                           │  └────────────────────────────────────────────────┘  │
                           └──────────────────────────────────────────────────────┘
                                               ▲
                                               │ External Provisioners
                           ┌───────────────────┼───────────────────┐
                           │                   │                   │
                    ┌──────┴──────┐     ┌──────┴──────┐     ┌──────┴──────┐
                    │   Desktop   │     │   Laptop    │     │  Workstation│
                    │ (Docker)    │     │ (Docker)    │     │  (Docker)   │
                    └─────────────┘     └─────────────┘     └─────────────┘
                       Local Workspaces (containers on user machines)
```

## Features

- **Entra ID Integration**: SSO with your organization's Azure AD / Entra ID (no VPN required)
- **Azure-Managed PostgreSQL**: Flexible Server with private networking
- **AKS with Autoscaling**: Scale nodes based on workspace demand
- **Secure by Default**: Private database, network policies, Entra ID authentication
- **Fully Automated**: Deploy and teardown with single commands
- **Backup & Recovery**: Automated PostgreSQL backups with blob storage export
- **Local Endpoints**: Run workspaces on laptops/desktops via external provisioners
- **Optional WireGuard VPN**: Additional network-level security if needed

## Prerequisites

1. **Azure Subscription** with permissions to create resources
2. **Service Principal** with `Contributor` role on the subscription
3. **Tools installed**:
   - [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.3.0
   - [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`)
   - [kubectl](https://kubernetes.io/docs/tasks/tools/)
   - [Helm](https://helm.sh/docs/intro/install/)

## Quick Start

### Option A: Interactive Configuration (Recommended)

```bash
# Run the interactive configuration wizard
./scripts/configure.sh
```

The wizard will:
- Check prerequisites (Azure CLI, Terraform)
- Auto-detect your Azure subscription and tenant
- Create or configure a service principal
- Guide you through all configuration options
- Generate `terraform/terraform.tfvars`
- Optionally start deployment

### Option B: Manual Configuration

#### 1. Create Service Principal

```bash
# Login to Azure
az login

# Create service principal with Contributor role
az ad sp create-for-rbac \
  --name "coder-terraform-sp" \
  --role Contributor \
  --scopes /subscriptions/<SUBSCRIPTION_ID>

# Output:
# {
#   "appId": "<CLIENT_ID>",
#   "displayName": "coder-terraform-sp",
#   "password": "<CLIENT_SECRET>",
#   "tenant": "<TENANT_ID>"
# }
```

#### 2. Configure Terraform

```bash
# Copy example configuration
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

# Edit with your values
# Required: subscription_id, tenant_id, client_id, client_secret
```

#### 3. Deploy

```bash
# Full automated deployment
./scripts/deploy.sh

# Or preview changes first
./scripts/deploy.sh --plan-only

# Or skip confirmation prompts
./scripts/deploy.sh --auto-approve
```

### 4. Access Coder

After deployment:
1. Get the LoadBalancer IP from the Terraform output
2. Navigate to `http://<LOADBALANCER_IP>`
3. Create your first admin account
4. Team members sign in with Entra ID via "Sign in with [Department] Entra ID"

No VPN or special software required - Entra ID provides authentication.

### 5. Teardown

```bash
# Interactive teardown with confirmation
./scripts/teardown.sh

# Automated teardown (for CI/CD)
./scripts/teardown.sh --auto-approve

# Force teardown (if resources are stuck)
./scripts/teardown.sh --auto-approve --force
```

## Configuration

### Required Variables

| Variable | Description |
|----------|-------------|
| `subscription_id` | Azure Subscription ID |
| `tenant_id` | Entra ID Tenant ID |
| `client_id` | Service Principal Application ID |
| `client_secret` | Service Principal Secret |

### Common Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `resource_prefix` | `coder` | Prefix for resource names |
| `location` | `eastus` | Azure region |
| `department_name` | `Research` | Shown on OIDC login button |
| `node_vm_size` | `Standard_D2s_v3` | AKS node VM size (2 vCPU, 8GB - good for ≤10 users) |
| `node_count` | `1` | Initial node count |
| `max_node_count` | `5` | Max nodes for autoscaler |
| `postgres_sku` | `B_Standard_B1ms` | PostgreSQL SKU (burstable, ~$15/mo) |
| `coder_version` | `2.16.0` | Coder Helm chart version |

### Network Access Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `network_access_type` | `loadbalancer` | Access method: `loadbalancer`, `wireguard`, or `clusterip` |

### Entra ID Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `allowed_email_domains` | `[]` | Restrict login to specific domains |
| `enable_group_sync` | `false` | Sync Entra ID groups to Coder |
| `aks_admin_group_ids` | `[]` | Groups with AKS admin access |

### Custom Domain (Optional)

For production, configure a custom domain:

```hcl
coder_domain          = "coder.example.com"
coder_wildcard_domain = "coder.example.com"
enable_ingress        = true
```

Then create DNS A records pointing to the LoadBalancer IP.

### Backup Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `backup_retention_days` | `14` | PostgreSQL automated backup retention (7-35 days) |
| `geo_redundant_backup` | `false` | Enable cross-region disaster recovery |
| `enable_backup_export` | `true` | Export backups to Blob Storage for long-term retention |
| `backup_blob_retention_days` | `365` | Blob storage backup retention |

### External Provisioners (Local Endpoints)

| Variable | Default | Description |
|----------|---------|-------------|
| `enable_external_provisioners` | `false` | Enable PSK auth for external provisioners |
| `provisioner_tags` | `""` | Default tags for provisioner organization |

## Entra ID Setup Details

The Terraform configuration automatically:

1. Creates an App Registration in Entra ID
2. Configures OIDC redirect URIs
3. Requests Microsoft Graph permissions (User.Read, email, profile, openid)
4. Creates a client secret (valid 1 year)
5. Configures Coder with OIDC settings

### Manual Entra ID Steps (if needed)

If you need to configure additional settings in Entra ID:

1. Navigate to **Azure Portal** > **Entra ID** > **App registrations**
2. Find the app named `<resource_prefix>-coder-app`
3. Common adjustments:
   - **Token configuration**: Add optional claims
   - **API permissions**: Grant admin consent if required
   - **Enterprise applications**: Assign users/groups

## Outputs

After deployment, Terraform provides:

| Output | Description |
|--------|-------------|
| `coder_access_url` | URL to access Coder |
| `coder_load_balancer_ip` | LoadBalancer external IP |
| `kubeconfig_command` | Command to configure kubectl |
| `entra_id_app_client_id` | Entra ID Application ID |

View outputs:
```bash
cd terraform
terraform output
terraform output -raw coder_access_url
```

## Troubleshooting

### Pods not starting

```bash
kubectl get pods -n coder
kubectl describe pod <pod-name> -n coder
kubectl logs -n coder -l app.kubernetes.io/name=coder
```

### Database connection issues

```bash
# Check database secret
kubectl get secret -n coder coder-db-credentials -o jsonpath='{.data.url}' | base64 -d

# Check Coder logs for connection errors
kubectl logs -n coder deployment/coder | grep -i postgres
```

### OIDC login not working

1. Verify redirect URI in Entra ID matches Coder URL
2. Check Coder logs for OIDC errors:
   ```bash
   kubectl logs -n coder deployment/coder | grep -i oidc
   ```
3. Ensure the domain in `coder_domain` matches the App Registration redirect URI

### Destroy stuck on resources

```bash
# Force destroy
./scripts/teardown.sh --auto-approve --force

# Or manually remove stuck resources from state
cd terraform
terraform state rm kubernetes_namespace.coder
terraform destroy -auto-approve
```

## Backup & Disaster Recovery

### Backup Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Backup Strategy                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  PostgreSQL Flexible Server                                          │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Automated Backups (Azure-managed)                          │    │
│  │  • Full backup: Daily                                       │    │
│  │  • Transaction logs: Every 5 minutes                        │    │
│  │  • Retention: 7-35 days (configurable)                      │    │
│  │  • Point-in-time restore: Any second within retention       │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                              │                                       │
│                              ▼                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Azure Blob Storage (Optional long-term)                    │    │
│  │  • pg_dump exports                                          │    │
│  │  • Retention: 365 days (configurable)                       │    │
│  │  • Lifecycle: Hot → Cool (30d) → Archive (90d) → Delete     │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  Optional: Geo-Redundant Backup                                      │
│  • Cross-region replication for disaster recovery                    │
│  • Enable with: geo_redundant_backup = true                          │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### What's Backed Up

| Data | Backup Method | Retention | Recovery Time |
|------|---------------|-----------|---------------|
| PostgreSQL (users, templates, workspace metadata) | Azure automated + blob export | 14 days (automated) / 365 days (blob) | Minutes |
| Workspace state | Stored in PostgreSQL | Same as above | Same as above |
| Template definitions | Stored in PostgreSQL | Same as above | Same as above |
| Workspace contents | User responsibility (in workspace) | N/A | N/A |

### Backup Management Script

```bash
# View current backup status and configuration
./scripts/backup-database.sh

# List all available restore points
./scripts/backup-database.sh --list-backups

# Export database to blob storage (for long-term retention)
./scripts/backup-database.sh --export-to-blob

# Interactive restore wizard
./scripts/backup-database.sh --restore
```

### Point-in-Time Restore

Restore the database to any point within the retention window:

```bash
# 1. Find available restore window
az postgres flexible-server show \
  --resource-group <rg-name> \
  --name <server-name> \
  --query "backup.earliestRestoreDate"

# 2. Restore to a NEW server (non-destructive)
az postgres flexible-server restore \
  --resource-group <rg-name> \
  --name <new-server-name> \
  --source-server <original-server> \
  --restore-time "2024-01-15T10:30:00Z"

# 3. Update Coder to use the new database
# Edit the coder-db-credentials secret or redeploy with new connection string
```

### Restore from Blob Export

For restores beyond the automated backup window:

```bash
# 1. List available exports
az storage blob list \
  --account-name <backup-storage-account> \
  --container-name database-backups \
  --output table

# 2. Download the backup
az storage blob download \
  --account-name <backup-storage-account> \
  --container-name database-backups \
  --name coder_backup_20240115_103000.sql.gz \
  --file backup.sql.gz

# 3. Restore to database
gunzip -c backup.sql.gz | psql "${DATABASE_URL}"
```

### Disaster Recovery Scenarios

| Scenario | Recovery Method | RTO | RPO |
|----------|----------------|-----|-----|
| Accidental data deletion | Point-in-time restore | ~10 min | Seconds |
| Database corruption | Point-in-time restore | ~10 min | Seconds |
| Region outage | Geo-redundant restore | ~1 hour | ~5 min |
| Long-term recovery (>35 days) | Blob export restore | ~30 min | Last export |

## External Provisioners (Local Endpoints)

Run workspaces on local laptops and desktops instead of (or in addition to) AKS. This enables hybrid deployments where some workspaces run in the cloud and others run on local hardware.

### How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                    External Provisioner Flow                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. Local machine runs provisioner daemon                            │
│     └── Connects OUTBOUND to Coder (no inbound firewall needed)      │
│                                                                      │
│  2. User creates workspace targeting local provisioner tags          │
│     └── Coder routes the job to matching provisioner                 │
│                                                                      │
│  3. Provisioner executes Terraform on local machine                  │
│     └── Creates Docker containers, VMs, or native processes          │
│                                                                      │
│  4. Workspace runs locally with full Coder integration               │
│     └── Web terminal, IDE, port forwarding all work normally         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Prerequisites for Local Machines

| Requirement | Description |
|-------------|-------------|
| **Docker** | Required for container-based workspaces |
| **Network access** | Outbound HTTPS to Coder control plane |
| **Coder CLI** | Installed by setup script |
| **Disk space** | For workspace containers/images |

### Step 1: Enable External Provisioners

```hcl
# In terraform.tfvars
enable_external_provisioners = true
```

Then apply: `./scripts/deploy.sh` or `terraform apply`

### Step 2: Get the Pre-Shared Key (PSK)

```bash
cd terraform
terraform output -raw provisioner_psk
```

Keep this key secure - it authenticates provisioners to the control plane.

### Step 3: Set Up Local Machines

**Option A: Interactive (foreground)**
```bash
./scripts/setup-provisioner.sh \
  --coder-url https://coder.example.com \
  --psk "$(cd terraform && terraform output -raw provisioner_psk)" \
  --name "alice-macbook" \
  --tags "owner:alice,location:home,type:laptop"
```

**Option B: Background service (macOS)**
```bash
./scripts/setup-provisioner.sh \
  --coder-url https://coder.example.com \
  --psk "<PSK>" \
  --name "alice-macbook" \
  --tags "owner:alice,location:home,type:laptop" \
  --launchd

# Manage the service
launchctl list | grep coder
launchctl stop com.coder.provisioner
launchctl start com.coder.provisioner
```

**Option C: Background service (Linux)**
```bash
./scripts/setup-provisioner.sh \
  --coder-url https://coder.example.com \
  --psk "<PSK>" \
  --name "dev-workstation" \
  --tags "owner:shared,location:office,type:desktop,gpu:nvidia-rtx4090" \
  --systemd

# Manage the service
sudo systemctl status coder-provisioner
sudo systemctl stop coder-provisioner
sudo systemctl start coder-provisioner
sudo journalctl -u coder-provisioner -f
```

**Option D: Windows (manual)**
```powershell
# Install Coder CLI
winget install Coder.Coder

# Run provisioner (in PowerShell)
$env:CODER_URL = "https://coder.example.com"
coder provisionerd start --psk "<PSK>" --name "win-desktop" --tag "owner:bob,type:desktop"
```

### Step 4: Create Templates for Local Workspaces

Create a Terraform template that targets local provisioners:

```hcl
terraform {
  required_providers {
    coder  = { source = "coder/coder" }
    docker = { source = "kreuzwerker/docker" }
  }
}

# Target provisioners with specific tags
data "coder_provisioner" "local" {
  tags = {
    owner = "local"
    type  = "endpoint"
  }
}

data "coder_workspace" "me" {}

# This container runs on the LOCAL machine, not AKS
resource "docker_image" "workspace" {
  name = "codercom/enterprise-base:ubuntu"
}

resource "docker_container" "workspace" {
  name  = "coder-${data.coder_workspace.me.name}"
  image = docker_image.workspace.image_id

  # Mount local directories if needed
  volumes {
    host_path      = "/home/${data.coder_workspace.me.owner}/projects"
    container_path = "/home/coder/projects"
  }

  # Expose ports
  ports {
    internal = 8080
    external = 8080
  }
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
}
```

### Provisioner Tags Strategy

Organize provisioners with meaningful tags for routing:

| Tag | Example Values | Use Case |
|-----|---------------|----------|
| `owner` | `alice`, `shared`, `team-platform` | Who owns/manages the machine |
| `location` | `office`, `home`, `datacenter-east` | Physical/network location |
| `type` | `laptop`, `desktop`, `server`, `workstation` | Machine type |
| `gpu` | `nvidia-rtx4090`, `nvidia-a100`, `none` | GPU availability |
| `os` | `macos`, `linux`, `windows` | Operating system |
| `arch` | `amd64`, `arm64` | CPU architecture |

### Use Cases for Local Provisioners

| Use Case | Configuration |
|----------|---------------|
| **Personal laptop** | `owner:<username>,type:laptop` - User's own machine |
| **Shared workstation** | `owner:shared,location:office,gpu:nvidia-rtx4090` - GPU workstation in office |
| **Home lab server** | `owner:team-ml,location:home,gpu:nvidia-a100` - ML training server |
| **Build machine** | `owner:shared,type:server,arch:arm64` - ARM build server |

### Troubleshooting Provisioners

```bash
# Check if provisioner is connected (from Coder UI or API)
coder provisioner list

# View provisioner logs (macOS)
tail -f ~/Library/Logs/coder-provisioner/stdout.log

# View provisioner logs (Linux)
sudo journalctl -u coder-provisioner -f

# Test connectivity from local machine
curl -sf https://coder.example.com/healthz

# Restart provisioner (macOS)
launchctl stop com.coder.provisioner && launchctl start com.coder.provisioner

# Restart provisioner (Linux)
sudo systemctl restart coder-provisioner
```

### Security Considerations for Local Provisioners

- **PSK rotation**: Rotate the pre-shared key periodically by updating `random_password.provisioner_psk` in Terraform
- **Network security**: Provisioners only need outbound HTTPS access; no inbound ports required
- **Resource isolation**: Docker provides container isolation; consider resource limits in templates
- **Machine security**: Local machines should follow your organization's endpoint security policies

## WireGuard VPN Access (Optional)

WireGuard is an **optional** feature for environments that require additional network-level security beyond Entra ID authentication. Most deployments won't need this - Entra ID provides sufficient access control.

**When to use WireGuard:**
- Compliance requirements mandate VPN access
- You want to prevent the Coder login page from being publicly visible
- Defense-in-depth security posture

**When LoadBalancer + Entra ID is sufficient (default):**
- Team members only need their Entra ID credentials
- No client software to install or configure
- Simpler onboarding for new team members

### How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                      WireGuard VPN Architecture                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Team Member's Machine                    Azure AKS Cluster          │
│  ┌──────────────────┐                    ┌──────────────────────┐   │
│  │  WireGuard Client │◀═══Encrypted═════▶│  WireGuard Server    │   │
│  │  10.10.0.2/24     │    UDP Tunnel      │  10.10.0.1/24        │   │
│  └──────────────────┘                    │  (LoadBalancer:51820)│   │
│          │                                └──────────┬───────────┘   │
│          │                                           │               │
│          │ Can access:                               ▼               │
│          │  • Coder (10.1.x.x)           ┌──────────────────────┐   │
│          │  • K8s Services               │  Coder Service       │   │
│          │  • Pod IPs                    │  (ClusterIP)         │   │
│          └──────────────────────────────▶│  http://10.1.x.x     │   │
│                                          └──────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Advantages over LoadBalancer

| Aspect | WireGuard | Public LoadBalancer |
|--------|-----------|---------------------|
| **Security** | No public exposure | Publicly accessible |
| **Cost** | ~$5/mo (LB for WG only) | ~$20/mo (standard LB) |
| **Access** | VPN required | Anyone with URL |
| **Speed** | Fast (modern crypto) | Direct |
| **Best for** | Small teams, security-conscious | Large teams, public access |

### Setting Up Team Members

#### Step 1: Generate Client Configuration

Run on any machine with access to the Terraform state:

```bash
./scripts/setup-wireguard-client.sh
```

This interactive script will:
- Read the WireGuard server configuration from Terraform
- Generate a key pair for the new team member
- Create a `.conf` file for the WireGuard client
- Show the peer config to add to `terraform.tfvars`

#### Step 2: Add Peer to Server

Add the peer to `terraform/terraform.tfvars`:

```hcl
wireguard_peers = [
  {
    name       = "alice"
    public_key = "abc123..."
  },
  {
    name       = "bob"
    public_key = "def456..."
  },
]
```

Then apply: `./scripts/deploy.sh`

#### Step 3: Install WireGuard Client

**macOS:**
```bash
brew install wireguard-tools
# Or download WireGuard app from App Store
```

**Ubuntu/Debian:**
```bash
sudo apt install wireguard-tools
```

**Windows:**
Download from https://www.wireguard.com/install/

#### Step 4: Import and Connect

**macOS/Windows (GUI):**
1. Open WireGuard app
2. Click "Import tunnel from file"
3. Select the generated `.conf` file
4. Click "Activate"

**Linux (CLI):**
```bash
sudo cp wireguard-alice.conf /etc/wireguard/coder.conf
sudo wg-quick up coder

# To disconnect
sudo wg-quick down coder

# Check status
sudo wg show
```

#### Step 5: Access Coder

Once connected:
- **Via VPN IP:** `http://10.10.0.1`
- **Via Kubernetes DNS:** `http://coder.coder.svc.cluster.local`
- **Find ClusterIP:** `kubectl get svc -n coder`

### Managing WireGuard Peers

**List configured peers:**
```bash
./scripts/setup-wireguard-client.sh --list
```

**Remove a peer:**
1. Remove from `wireguard_peers` in `terraform.tfvars`
2. Run `./scripts/deploy.sh`

**Rotate server keys:**
```bash
# Force recreation of WireGuard secrets
cd terraform
terraform taint random_password.wireguard_private_key[0]
terraform apply

# All team members will need new client configs
```

### Troubleshooting WireGuard

**Can't connect:**
```bash
# Check if UDP 51820 is reachable
nc -vzu <wireguard-endpoint-ip> 51820

# Check WireGuard status
sudo wg show

# Check server logs
kubectl logs -n wireguard deployment/wireguard
```

**Connected but can't access Coder:**
```bash
# Verify tunnel is up
ping 10.10.0.1

# Check routing
ip route | grep 10.10

# Ensure DNS is configured (check /etc/resolv.conf or WireGuard DNS setting)
```

**Handshake not completing:**
- Verify public key in server config matches your client's public key
- Check if NAT/firewall is blocking UDP 51820
- Try `PersistentKeepalive = 25` in client config

## Cost Estimate

### Default Configuration (Small Team ≤10 users)

| Resource | SKU | Estimated Cost |
|----------|-----|----------------|
| AKS Nodes (1-5x) | Standard_D2s_v3 | ~$70 (1 node) |
| PostgreSQL | B_Standard_B1ms (Burstable) | ~$15 |
| Load Balancer | Standard | ~$20 |
| Storage | 32GB | ~$3 |
| Blob Storage (Backups) | LRS | ~$2 |
| **Total** | | **~$110/month** |

### Larger Team Configuration

For teams requiring higher capacity:

| Resource | SKU | Estimated Cost |
|----------|-----|----------------|
| AKS Nodes (2-10x) | Standard_D4s_v3 | ~$280 (2 nodes) |
| PostgreSQL | GP_Standard_D2s_v3 | ~$125 |
| Load Balancer | Standard | ~$20 |
| Storage | 32GB Premium | ~$5 |
| Blob Storage (Backups) | LRS | ~$2 |
| **Total** | | **~$432/month** |

*Costs vary by region and actual usage. Autoscaling adjusts node count based on demand. Local provisioners add no Azure cost.*

## Security Considerations

- Database uses private networking (no public access)
- Secrets stored in Kubernetes secrets
- Network policies enabled (Calico)
- OIDC for authentication (no password-based login)
- Service principal credentials should be rotated regularly

## Contributing

1. Fork the repository
2. Create a feature branch
3. Submit a pull request

## License

MIT License - see LICENSE file for details.
