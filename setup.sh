#!/bin/bash
# Load variables from .env
if [ -f .env ]; then
    set -a; source .env; set +a
else
    echo "❌ Error: .env file not found."
    exit 1
fi

# 1. Validation: Check for required .env variables
# 1. Validation: Define Variable Groups
CORE_VARS=(
    "DIGITALOCEAN_TOKEN"
    "CLOUDFLARE_API_TOKEN"
    "CLOUDFLARE_ZONE_ID"
    "DOMAIN_NAME"
    "JOPLIN_SUBDOMAIN"
    "TRILIUM_SUBDOMAIN"
    "POSTGRES_PASSWORD"
    "DO_REGION"
    "SSH_PRIVATE_KEY_PATH"
    "SSH_PUBLIC_KEY_PATH"
    "CERTBOT_MODE"
    "ACME_EMAIL"
)

# Variables only needed if S3 is enabled
S3_VARS=(
    "SPACES_ACCESS_KEY_ID"
    "SPACES_SECRET_ACCESS_KEY"
    "SPACES_BUCKET_NAME"
)

MISSING_VARS=()

# Check Core Variables
for VAR in "${CORE_VARS[@]}"; do
    if [[ -z "${!VAR}" ]]; then
        MISSING_VARS+=("$VAR")
    fi
done

# Check S3 Variables ONLY if ENABLE_S3_STORAGE is true
if [[ "$ENABLE_S3_STORAGE" == "true" ]]; then
    for VAR in "${S3_VARS[@]}"; do
        if [[ -z "${!VAR}" ]]; then
            MISSING_VARS+=("$VAR (Required because ENABLE_S3_STORAGE is true)")
        fi
    done
fi

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
  -var="domain=$DOMAIN_NAME" \
  -var="joplin_subdomain=$JOPLIN_SUBDOMAIN" \
  -var="trilium_subdomain=$TRILIUM_SUBDOMAIN"

# Check the exit status of the last command ($?)
if [ $? -ne 0 ]; then
    echo "❌ Error: Terraform failed to provision resources. Exiting."
    exit 1
fi

# Get the new IP from Terraform output
IP=$(terraform output -raw droplet_ip)
echo "📡 Droplet IP: $IP"

# Go back to the root directory
cd ..

echo "⏳ Waiting for SSH to become available..."
# Try to connect every 5 seconds, up to 20 times (100 seconds total)
MAX_RETRIES=10
WAIT_INTERVAL=10    # Seconds to wait between tries
COUNT=0
# nc -w flag is the "timeout" for the individual attempt. 
# It should be less than or equal to your WAIT_INTERVAL.
until nc -z -v -w10 "$IP" 22 2>/dev/null; do
    ((COUNT++))
    if [ $COUNT -ge $MAX_RETRIES ]; then
        echo "❌ Error: SSH timed out after $((MAX_RETRIES * WAIT_INTERVAL)) seconds."
        exit 1
    fi
    echo "  - Attempt $COUNT/$MAX_RETRIES: Server still booting (waiting ${WAIT_INTERVAL}s)..."
    sleep $WAIT_INTERVAL
done

echo "🔓 SSH is up! Giving the system 30 more seconds to initialize keys..."
sleep 30

# 4. Configure Server via Ansible
echo "🛠️ Step 2: Configuring Server via Ansible..."
# We add ANSIBLE_HOST_KEY_CHECKING=False so you don't have to type 'yes'
export ANSIBLE_HOST_KEY_CHECKING=False

ansible-playbook -i "$IP," ansible/playbook.yml \
  --user root \
  --private-key "$PRIVATE_KEY" \
  --ssh-common-args='-o IdentitiesOnly=yes' \
  --extra-vars "postgres_pwd=$POSTGRES_PASSWORD enable_block_storage=$ENABLE_BLOCK_STORAGE enable_s3_storage=$ENABLE_S3_STORAGE s3_key=$SPACES_ACCESS_KEY_ID s3_secret=$SPACES_SECRET_ACCESS_KEY s3_bucket=$SPACES_BUCKET_NAME s3_region=$DO_REGION domain=$DOMAIN_NAME joplin_sub=$JOPLIN_SUBDOMAIN trilium_sub=$TRILIUM_SUBDOMAIN certbot_mode=$CERTBOT_MODE acme_email=$ACME_EMAIL"

# Add this check right after the ansible-playbook command
if [ $? -ne 0 ]; then
    echo "❌ Error: Ansible provisioning failed. Check the logs above."
    exit 1
fi

echo "🔍 Verifying Nginx is running..."
if ! ssh -i "$PRIVATE_KEY" root@$IP "docker ps | grep -q reverse-proxy"; then
    echo "❌ Error: Nginx (reverse-proxy) is not running. Check 'docker logs reverse-proxy' on the server."
    exit 1
fi

echo "🔒 Step 3: Checking SSL Certificates on Remote Server..."

# 1. Check if certificates exist ON THE SERVER
# We use SSH to check the directory status on the remote IP
if ! ssh -i "$PRIVATE_KEY" -o IdentitiesOnly=yes root@$IP "[ -d /etc/letsencrypt/live/$JOPLIN_SUBDOMAIN.$DOMAIN_NAME ]"; then
    echo "📜 No certificates found. Requesting new SSL certificates..."
    
    # 2. Run Certbot via Docker ON THE SERVER
    # Note the escaped quotes and variables so they pass through SSH correctly
    ssh -i "$PRIVATE_KEY" -o IdentitiesOnly=yes root@$IP "docker run --rm \
      -v /etc/letsencrypt:/etc/letsencrypt \
      -v /opt/notes-stack/certbot-www:/var/www/certbot \
      certbot/certbot certonly --webroot \
      -w /var/www/certbot \
      -d $JOPLIN_SUBDOMAIN.$DOMAIN_NAME \
      -d $TRILIUM_SUBDOMAIN.$DOMAIN_NAME \
      --email $ACME_EMAIL --agree-tos --no-eff-email --non-interactive"

    if [ $? -ne 0 ]; then
        echo "❌ Error: Certbot failed to obtain certificates."
        exit 1
    fi

    echo "🔄 Certificates obtained. Re-running Ansible to enable SSL..."
    
else
    echo "✅ Certificates already exist. Skipping Certbot."
fi

    # 3. Final Ansible Pass (Enabling SSL)
    # We pass enable_ssl=true as an extra-var so the playbook picks the .ssl.j2 templates
    ansible-playbook -i "$IP," ansible/playbook.yml \
      --user root \
      --private-key "$PRIVATE_KEY" \
      --ssh-common-args='-o IdentitiesOnly=yes' \
      --extra-vars "enable_ssl=true postgres_pwd=$POSTGRES_PASSWORD enable_block_storage=$ENABLE_BLOCK_STORAGE enable_s3_storage=$ENABLE_S3_STORAGE s3_key=$SPACES_ACCESS_KEY_ID s3_secret=$SPACES_SECRET_ACCESS_KEY s3_bucket=$SPACES_BUCKET_NAME s3_region=$DO_REGION domain=$DOMAIN_NAME joplin_sub=$JOPLIN_SUBDOMAIN trilium_sub=$TRILIUM_SUBDOMAIN certbot_mode=$CERTBOT_MODE acme_email=$ACME_EMAIL"

echo "🎉 DEPLOYMENT COMPLETE!"
echo "------------------------------------------------"
echo "Joplin:  https://$JOPLIN_SUBDOMAIN.$DOMAIN_NAME"
echo "Trilium: https://$TRILIUM_SUBDOMAIN.$DOMAIN_NAME"
echo "------------------------------------------------"
