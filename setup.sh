#!/bin/bash
# Load variables from .env
if [ -f .env ]; then
    set -a; source .env; set +a
else
    echo "❌ Error: .env file not found."
    exit 1
fi

# 1. Validation: Check for required .env variables
REQUIRED_VARS=(
    "DIGITALOCEAN_TOKEN"
    "CLOUDFLARE_API_TOKEN"
    "CLOUDFLARE_ZONE_ID"
    "DOMAIN_NAME"
    "JOPLIN_SUBDOMAIN"
    "TRILIUM_SUBDOMAIN"
    "POSTGRES_PASSWORD"
    "SPACES_ACCESS_KEY_ID"
    "SPACES_SECRET_ACCESS_KEY"
    "SPACES_BUCKET_NAME"
    "DO_REGION"
    "SSH_PRIVATE_KEY_PATH"
    "SSH_PUBLIC_KEY_PATH"
    "CERTBOT_MODE"
    "ACME_EMAIL"
)

MISSING_VARS=()
for VAR in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!VAR}" ]]; then
        MISSING_VARS+=("$VAR")
    fi
done

if [ ${#MISSING_VARS[@]} -ne 0 ]; then
    echo "❌ Error: The following required variables are missing from .env:"
    for MISSING in "${MISSING_VARS[@]}"; do
        echo "  - $MISSING"
    done
    exit 1
fi

# 2. Security Check: Private Key Permissions
PRIVATE_KEY=$(eval echo $SSH_PRIVATE_KEY_PATH)
PUBLIC_KEY=$(eval echo $SSH_PUBLIC_KEY_PATH)

if [ ! -f "$PRIVATE_KEY" ]; then
    echo "❌ Error: Private key not found at $PRIVATE_KEY"
    exit 1
fi

# Security Check: Verify Private Key Permissions
# Use 'stat' to get octal permissions (works on macOS and Linux)
if [[ "$OSTYPE" == "darwin"* ]]; then
    PERMS=$(stat -f %Lp "$PRIVATE_KEY")
else
    PERMS=$(stat -c "%a" "$PRIVATE_KEY")
fi

if [[ "$PERMS" != "600" && "$PERMS" != "400" ]]; then
    echo "❌ SECURITY ALARM: Private key $PRIVATE_KEY has unsafe permissions ($PERMS)."
    echo "SSH requires private keys to be accessible ONLY by the owner."
    echo "Please run: chmod 600 $PRIVATE_KEY"
    exit 1
fi

echo "🛡️ SSH Key permissions verified ($PERMS). Proceeding..."

# 3. Provision Hardware & DNS
echo "🚀 Step 1: Provisioning hardware via Terraform..."
cd terraform
terraform init
terraform apply -auto-approve \
  -var="do_token=$DIGITALOCEAN_TOKEN" \
  -var="ssh_public_key_path=$PUBLIC_KEY" \
  -var="enable_block_storage=$ENABLE_BLOCK_STORAGE" \
  -var="cloudflare_api_token=$CLOUDFLARE_API_TOKEN" \
  -var="cloudflare_zone_id=$CLOUDFLARE_ZONE_ID" \
  -var="joplin_subdomain=$JOPLIN_SUBDOMAIN" \
  -var="trilium_subdomain=$TRILIUM_SUBDOMAIN"

# Get the new IP from Terraform output
IP=$(terraform output -raw droplet_ip)
cd ..

# Optional: A tiny sleep to ensure Cloudflare's 60s TTL is respected by LE
echo "⏳ Waiting 60 seconds for DNS propagation..."
sleep 60

# 4. Configure Server via Ansible
echo "🛠️ Step 2: Configuring Server and SSL..."
ansible-playbook -i "$IP," ansible/playbook.yml \
  --private-key "$PRIVATE_KEY" \
  --extra-vars "postgres_pwd=$POSTGRES_PASSWORD enable_block_storage=$ENABLE_BLOCK_STORAGE enable_s3_storage=$ENABLE_S3_STORAGE s3_key=$SPACES_ACCESS_KEY_ID s3_secret=$SPACES_SECRET_ACCESS_KEY s3_bucket=$SPACES_BUCKET_NAME s3_region=$DO_REGION domain=$DOMAIN_NAME joplin_sub=$JOPLIN_SUBDOMAIN trilium_sub=$TRILIUM_SUBDOMAIN certbot_mode=$CERTBOT_MODE acme_email=$ACME_EMAIL"

echo "✅ Success!"
