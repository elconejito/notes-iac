# Notes Infrastructure as Code

A complete Infrastructure as Code (IaC) solution for deploying a self-hosted notes stack on DigitalOcean. This project automates the provisioning and configuration of **Joplin Server** and **Trilium Notes** using Terraform and Ansible.

## What This Project Does

This project deploys a production-ready notes hosting stack that includes:

- **Joplin Server**: A note-taking and to-do application with synchronization capabilities
- **Trilium Notes**: A hierarchical note-taking application with advanced features
- **PostgreSQL**: Database backend for Joplin
- **Nginx Reverse Proxy**: SSL termination and routing with Let's Encrypt certificates
- **Optional Block Storage**: Persistent volume for data storage
- **Optional S3 Storage**: DigitalOcean Spaces integration for Joplin attachments

Both applications are accessible via HTTPS with automatic SSL certificate management.

## How It Works

The deployment process follows these steps:

1. **Terraform** provisions the infrastructure:
   - Creates a DigitalOcean Droplet (Ubuntu 24.04)
   - Configures firewall rules (SSH, HTTP, HTTPS)
   - Sets up Cloudflare DNS records for your subdomains
   - Optionally creates and attaches a block storage volume

2. **Ansible** configures the server:
   - Installs Docker and Docker Compose
   - Sets up the Docker Compose stack
   - Configures Nginx reverse proxy
   - Handles data migration if block storage is enabled
   - Manages SSL certificate deployment

3. **Docker Compose** runs the services:
   - Joplin Server (port 22300)
   - Trilium Notes (port 8080)
   - PostgreSQL database
   - Nginx reverse proxy (ports 80/443)

4. **Certbot** obtains SSL certificates:
   - Automatically requests Let's Encrypt certificates
   - Configures Nginx for HTTPS

## Prerequisites

Before you begin, ensure you have:

- A DigitalOcean account with an API token
- A Cloudflare account with API access
- A domain name with DNS managed by Cloudflare
- SSH key pair for server access
- (Optional) DigitalOcean Spaces credentials for S3 storage

## Installation

### 1. Install Terraform

**Windows:**
```powershell
# Using Chocolatey
choco install terraform

# Or download from: https://www.terraform.io/downloads
```

**macOS:**
```bash
# Using Homebrew
brew install terraform
```

**Linux:**
```bash
# Download and install
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform
```

**Verify installation:**
```bash
terraform --version
```

### 2. Install Ansible

**Windows:**
```powershell
# Using pip (requires Python)
pip install ansible

# Or using WSL (Windows Subsystem for Linux)
```

**macOS:**
```bash
# Using Homebrew
brew install ansible
```

**Linux:**
```bash
# Ubuntu/Debian
sudo apt update
sudo apt install ansible

# Or using pip
pip install ansible
```

**Verify installation:**
```bash
ansible --version
```

### 3. Clone the Repository

```bash
git clone <your-repo-url>
cd notes-iac
```

### 4. Configure Environment Variables

Create a `.env` file in the project root with the following variables:

```bash
# DigitalOcean Configuration
DIGITALOCEAN_TOKEN=your_do_api_token
DO_REGION=nyc3

# Cloudflare Configuration
CLOUDFLARE_API_TOKEN=your_cloudflare_api_token
CLOUDFLARE_ZONE_ID=your_cloudflare_zone_id

# Domain Configuration
DOMAIN_NAME=yourdomain.com
JOPLIN_SUBDOMAIN=joplin
TRILIUM_SUBDOMAIN=trilium

# Database Configuration
POSTGRES_PASSWORD=your_secure_password

# SSH Key Configuration
SSH_PRIVATE_KEY_PATH=/path/to/your/private/key
SSH_PUBLIC_KEY_PATH=/path/to/your/public/key.pub

# SSL Certificate Configuration
CERTBOT_MODE=webroot
ACME_EMAIL=your-email@example.com

# Optional: Block Storage (set to true to enable)
ENABLE_BLOCK_STORAGE=false

# Optional: S3 Storage for Joplin (set to true to enable)
ENABLE_S3_STORAGE=false
SPACES_ACCESS_KEY_ID=your_spaces_key
SPACES_SECRET_ACCESS_KEY=your_spaces_secret
SPACES_BUCKET_NAME=your-bucket-name

# Optional: Email Configuration for Joplin (set MAILER_ENABLED=true to enable)
MAILER_ENABLED=false
MAILER_HOST=smtp.example.com
MAILER_PORT=587
MAILER_SECURE=false
MAILER_USER=your_smtp_username
MAILER_PASSWORD=your_smtp_password
MAILER_FROM_EMAIL=noreply@yourdomain.com
MAILER_FROM_NAME=Joplin Server
```

### 5. Set SSH Key Permissions

**Linux/macOS:**
```bash
chmod 600 /path/to/your/private/key
```

**Windows (PowerShell):**
```powershell
# SSH keys should be in your .ssh directory
icacls C:\Users\YourUser\.ssh\id_rsa /inheritance:r
icacls C:\Users\YourUser\.ssh\id_rsa /grant:r "$($env:USERNAME):(R)"
```

### 6. Deploy the Infrastructure

Make the setup script executable and run it:

**Linux/macOS:**
```bash
chmod +x setup.sh
./setup.sh
```

**Windows (Git Bash or WSL):**
```bash
chmod +x setup.sh
./setup.sh
```

The script will:
1. Validate your `.env` file
2. Provision infrastructure with Terraform
3. Configure the server with Ansible
4. Obtain SSL certificates
5. Start all services

## Environment Variables Explained

### Required Variables

| Variable | Description |
|----------|-------------|
| `DIGITALOCEAN_TOKEN` | Your DigitalOcean API token. Create one at: https://cloud.digitalocean.com/account/api/tokens |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token with DNS edit permissions for your zone |
| `CLOUDFLARE_ZONE_ID` | Your Cloudflare zone ID (found in domain overview page) |
| `DOMAIN_NAME` | Your root domain (e.g., `example.com`) |
| `JOPLIN_SUBDOMAIN` | Subdomain for Joplin (e.g., `joplin` creates `joplin.example.com`) |
| `TRILIUM_SUBDOMAIN` | Subdomain for Trilium (e.g., `trilium` creates `trilium.example.com`) |
| `POSTGRES_PASSWORD` | Strong password for the PostgreSQL database |
| `DO_REGION` | DigitalOcean region (e.g., `nyc3`, `sfo3`, `sgp1`) |
| `SSH_PRIVATE_KEY_PATH` | Full path to your SSH private key file |
| `SSH_PUBLIC_KEY_PATH` | Full path to your SSH public key file |
| `CERTBOT_MODE` | Certbot validation mode (use `webroot`) |
| `ACME_EMAIL` | Email address for Let's Encrypt certificate notifications |

### Optional Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ENABLE_BLOCK_STORAGE` | Enable 20GB block storage volume for persistent data | `false` |
| `ENABLE_S3_STORAGE` | Enable S3 storage for Joplin attachments | `false` |
| `SPACES_ACCESS_KEY_ID` | DigitalOcean Spaces access key (required if `ENABLE_S3_STORAGE=true`) | - |
| `SPACES_SECRET_ACCESS_KEY` | DigitalOcean Spaces secret key (required if `ENABLE_S3_STORAGE=true`) | - |
| `SPACES_BUCKET_NAME` | DigitalOcean Spaces bucket name (required if `ENABLE_S3_STORAGE=true`) | - |
| `MAILER_ENABLED` | Enable email functionality for Joplin Server (user registration, password reset, etc.) | `false` |
| `MAILER_HOST` | SMTP server hostname (required if `MAILER_ENABLED=true`) | - |
| `MAILER_PORT` | SMTP server port (typically 587 for TLS, 465 for SSL, 25 for unencrypted) | - |
| `MAILER_SECURE` | Use TLS/SSL for SMTP connection (`true` for SSL, `false` for STARTTLS) | `false` |
| `MAILER_USER` | SMTP authentication username (required if `MAILER_ENABLED=true`) | - |
| `MAILER_PASSWORD` | SMTP authentication password (required if `MAILER_ENABLED=true`) | - |
| `MAILER_FROM_EMAIL` | Email address to send emails from (required if `MAILER_ENABLED=true`) | - |
| `MAILER_FROM_NAME` | Display name for sent emails (e.g., "Joplin Server") | - |

## Permissions

### SSH Key Permissions

Your SSH private key **must** have restricted permissions (600 or 400) for security. The setup script will verify this before proceeding.

**Required permissions:**
- Private key: `600` (read/write for owner only)
- Public key: Can be `644` (readable by all)

### File Permissions

The setup script requires execute permissions:
```bash
chmod +x setup.sh
```

### Server Permissions

The Ansible playbook runs with `sudo` privileges to:
- Install system packages
- Configure Docker
- Mount block storage volumes
- Create directories and files

## Docker Instructions

### Service Management

All services run via Docker Compose. SSH into your server to manage them:

```bash
# SSH into the server
ssh root@your-droplet-ip

# Navigate to the stack directory
cd /opt/notes-stack

# View service status
docker-compose ps

# View logs
docker-compose logs -f

# View logs for a specific service
docker-compose logs -f joplin-server
docker-compose logs -f trilium-server

# Restart a service
docker-compose restart joplin-server

# Restart all services
docker-compose restart

# Stop all services
docker-compose stop

# Start all services
docker-compose start

# Rebuild and restart
docker-compose up -d --force-recreate
```

### Updating Services

To update to the latest container images:

```bash
cd /opt/notes-stack
docker-compose pull
docker-compose up -d
docker image prune -f  # Clean up old images
```

### Backup and Restore

**Backup Joplin Database:**
```bash
docker exec joplin-db pg_dump -U joplin joplin > ~/joplin_backup_$(date +%F).sql
```

**Backup Trilium:**
```bash
cp /opt/notes-stack/data/trilium/document.db ~/trilium_backup_$(date +%F).db
```

**Restore Joplin:**
```bash
cat ~/joplin_backup_2024-01-01.sql | docker exec -i joplin-db psql -U joplin joplin
```

**Restore Trilium:**
```bash
cp ~/trilium_backup_2024-01-01.db /opt/notes-stack/data/trilium/document.db
docker-compose restart trilium-server
```

### Data Locations

- **Local storage**: `/opt/notes-stack/data/`
  - Joplin database: `/opt/notes-stack/data/joplin-db/`
  - Trilium data: `/opt/notes-stack/data/trilium/`

- **Block storage** (if enabled): `/mnt/notes_data/`
  - Joplin database: `/mnt/notes_data/joplin-db/`
  - Trilium data: `/mnt/notes_data/trilium/`

## Application Links

### Joplin

- **Official Website**: https://joplinapp.org/
- **Server Documentation**: https://joplinapp.org/help/apps/server/
- **GitHub Repository**: https://github.com/laurent22/joplin
- **Docker Image**: https://hub.docker.com/r/joplin/server

After deployment, access your Joplin Server at: `https://joplin.yourdomain.com`

### Trilium Notes

- **Official Website**: https://trilium.app/
- **Documentation**: https://github.com/zadam/trilium/wiki
- **GitHub Repository**: https://github.com/zadam/trilium
- **Docker Image**: https://hub.docker.com/r/triliumnext/notes

After deployment, access your Trilium instance at: `https://trilium.yourdomain.com`

## Destroying Infrastructure

To tear down all resources:

```bash
./setup.sh --destroy
```

**Warning**: This will destroy the droplet, volumes, and DNS records. Make sure you have backups!

## Troubleshooting

### SSH Connection Issues

- Verify your SSH key permissions are correct (600)
- Ensure the key path in `.env` is absolute and correct
- Check that the droplet firewall allows SSH (port 22)

### SSL Certificate Issues

- Verify DNS records are pointing to the correct IP
- Check that ports 80 and 443 are open in the firewall
- Review Certbot logs: `docker logs reverse-proxy`

### Service Not Starting

- Check Docker logs: `docker-compose logs`
- Verify disk space: `df -h`
- Check container status: `docker-compose ps`

### Database Connection Issues

- Verify PostgreSQL is running: `docker ps | grep joplin-db`
- Check database logs: `docker logs joplin-db`
- Verify password in environment variables

## Support

For issues related to:
- **Joplin**: https://discourse.joplinapp.org/
- **Trilium**: https://github.com/zadam/trilium/issues
- **This project**: Open an issue in the repository
