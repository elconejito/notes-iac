#!/bin/bash

# Show usage/help
if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]] || [[ "$1" == "help" ]]; then
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (no args)        Deploy infrastructure and configure server"
    echo "  --destroy        Destroy all infrastructure"
    echo "  --help, -h       Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                # Deploy infrastructure"
    echo "  $0 --destroy      # Destroy infrastructure"
    exit 0
fi

# Check for destroy argument
if [[ "$1" == "--destroy" ]]; then
    echo "🗑️  Destroying all infrastructure..."
    
    # Load minimal variables from .env for tear-down
    if [ -f .env ]; then
        set -a; source .env; set +a
    else
        echo "❌ Error: .env file not found."
        exit 1
    fi
    
    # Get SSH key paths (needed for terraform)
    PRIVATE_KEY=$(eval echo ${SSH_PRIVATE_KEY_PATH:-""})
    PUBLIC_KEY=$(eval echo ${SSH_PUBLIC_KEY_PATH:-""})
    
    # Navigate to terraform directory
    cd terraform
    
    # Check if terraform is initialized
    if [ ! -d ".terraform" ]; then
        echo "⚠️  Terraform not initialized. Running terraform init..."
        terraform init
    fi
    
    # Destroy infrastructure with same variables as apply
    echo "🔥 Destroying infrastructure..."
    terraform destroy -auto-approve \
      -var="do_token=${DIGITALOCEAN_TOKEN}" \
      -var="ssh_public_key_path=${PUBLIC_KEY}" \
      -var="enable_block_storage=${ENABLE_BLOCK_STORAGE}" \
      -var="cloudflare_api_token=${CLOUDFLARE_API_TOKEN}" \
      -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}" \
      -var="domain=${DOMAIN_NAME}" \
      -var="joplin_subdomain=${JOPLIN_SUBDOMAIN}" \
      -var="cloudflare_proxy_domain=${CLOUDFLARE_PROXY_DOMAIN:-false}"
    
    if [ $? -eq 0 ]; then
        echo "✅ Infrastructure successfully destroyed!"
        echo "💡 Note: DNS records and any manually created resources may need cleanup."
    else
        echo "❌ Error: Terraform destroy failed. Check the logs above."
        exit 1
    fi
    
    exit 0
fi

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

# Variables only needed if email is enabled
# Note: MAILER_SECURE is optional (defaults to false), others are required
MAILER_VARS=(
    "MAILER_HOST"
    "MAILER_PORT"
    "MAILER_USER"
    "MAILER_PASSWORD"
    "MAILER_FROM_EMAIL"
    "MAILER_FROM_NAME"
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

# Check Mailer Variables ONLY if MAILER_ENABLED is true
if [[ "$MAILER_ENABLED" == "true" ]]; then
    for VAR in "${MAILER_VARS[@]}"; do
        if [[ -z "${!VAR}" ]]; then
            MISSING_VARS+=("$VAR (Required because MAILER_ENABLED is true)")
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

# Try normal apply first
echo "📋 Applying Terraform configuration..."
TERRAFORM_OUTPUT=$(terraform apply -auto-approve \
  -var="do_token=$DIGITALOCEAN_TOKEN" \
  -var="ssh_public_key_path=$PUBLIC_KEY" \
  -var="enable_block_storage=$ENABLE_BLOCK_STORAGE" \
  -var="cloudflare_api_token=$CLOUDFLARE_API_TOKEN" \
  -var="cloudflare_zone_id=$CLOUDFLARE_ZONE_ID" \
  -var="domain=$DOMAIN_NAME" \
  -var="joplin_subdomain=$JOPLIN_SUBDOMAIN" \
  -var="cloudflare_proxy_domain=${CLOUDFLARE_PROXY_DOMAIN:-false}" 2>&1)
TERRAFORM_EXIT=$?

# Check if the error is related to droplet resize (DigitalOcean limitation)
if [ $TERRAFORM_EXIT -ne 0 ]; then
    # Check for resize-related errors
    if echo "$TERRAFORM_OUTPUT" | grep -qi "smaller disk\|cannot.*resize\|disk.*larger\|resize.*not.*supported\|This size is not available\|Error resizing droplet"; then
        echo ""
        echo "⚠️  Detected droplet resize error. DigitalOcean cannot resize when target has smaller disk."
        echo "🔄 Automatically forcing replacement (destroy and recreate)..."
        echo "💡 This will delete the existing droplet and create a new one with the new size."
        echo ""
        terraform apply -auto-approve -replace=digitalocean_droplet.note_server \
          -var="do_token=$DIGITALOCEAN_TOKEN" \
          -var="ssh_public_key_path=$PUBLIC_KEY" \
          -var="enable_block_storage=$ENABLE_BLOCK_STORAGE" \
          -var="cloudflare_api_token=$CLOUDFLARE_API_TOKEN" \
          -var="cloudflare_zone_id=$CLOUDFLARE_ZONE_ID" \
          -var="domain=$DOMAIN_NAME" \
          -var="joplin_subdomain=$JOPLIN_SUBDOMAIN" \
          -var="cloudflare_proxy_domain=${CLOUDFLARE_PROXY_DOMAIN:-false}"
        TERRAFORM_EXIT=$?
    else
        # Different error, show the output
        echo "$TERRAFORM_OUTPUT"
    fi
fi

# Check the exit status
if [ $TERRAFORM_EXIT -ne 0 ]; then
    echo "❌ Error: Terraform failed to provision resources."
    echo "💡 If you're trying to resize the droplet, you may need to manually destroy and recreate:"
    echo "   ./setup.sh --destroy"
    echo "   ./setup.sh"
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
  --extra-vars "postgres_pwd=$POSTGRES_PASSWORD enable_block_storage=$ENABLE_BLOCK_STORAGE enable_s3_storage=$ENABLE_S3_STORAGE s3_key=$SPACES_ACCESS_KEY_ID s3_secret=$SPACES_SECRET_ACCESS_KEY s3_bucket=$SPACES_BUCKET_NAME s3_region=$DO_REGION domain=$DOMAIN_NAME joplin_sub=$JOPLIN_SUBDOMAIN certbot_mode=$CERTBOT_MODE acme_email=$ACME_EMAIL mailer_enabled=${MAILER_ENABLED:-false} mailer_host=${MAILER_HOST:-} mailer_port=${MAILER_PORT:-} mailer_secure=${MAILER_SECURE:-false} mailer_user=${MAILER_USER:-} mailer_password=${MAILER_PASSWORD:-} mailer_from_email=${MAILER_FROM_EMAIL:-} mailer_from_name=${MAILER_FROM_NAME:-} mailer_noreply_email=${MAILER_NOREPLY_EMAIL:-} mailer_noreply_name=${MAILER_NOREPLY_NAME:-}"

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

# Validate CERTBOT_MODE
if [ "$CERTBOT_MODE" != "dry-run" ] && [ "$CERTBOT_MODE" != "staging" ] && [ "$CERTBOT_MODE" != "production" ]; then
    echo "❌ Error: CERTBOT_MODE must be one of: dry-run, staging, or production"
    echo "   Current value: $CERTBOT_MODE"
    exit 1
fi

# 1. Check if certificates exist ON THE SERVER
# We use SSH to check the directory status on the remote IP
JOPLIN_CERT_EXISTS=$(ssh -i "$PRIVATE_KEY" -o IdentitiesOnly=yes root@$IP "[ -d /etc/letsencrypt/live/$JOPLIN_SUBDOMAIN.$DOMAIN_NAME ] && echo 'yes' || echo 'no'")

if [ "$JOPLIN_CERT_EXISTS" != "yes" ]; then
    echo "📜 Missing certificate. Requesting SSL certificate..."
    
    # 2. Run Certbot via Docker ON THE SERVER for Joplin domain (if missing)
    if [ "$JOPLIN_CERT_EXISTS" != "yes" ]; then
        # Build certbot command with appropriate flags based on CERTBOT_MODE
        CERTBOT_CMD="certbot/certbot certonly --webroot -w /var/www/certbot -d $JOPLIN_SUBDOMAIN.$DOMAIN_NAME --email $ACME_EMAIL --agree-tos --no-eff-email --non-interactive"
        
        # Add appropriate flags based on CERTBOT_MODE
        if [ "$CERTBOT_MODE" = "dry-run" ]; then
            CERTBOT_CMD="$CERTBOT_CMD --dry-run"
            echo "  - Running DRY-RUN for certificate request for $JOPLIN_SUBDOMAIN.$DOMAIN_NAME..."
        elif [ "$CERTBOT_MODE" = "staging" ]; then
            CERTBOT_CMD="$CERTBOT_CMD --staging"
            echo "  - Requesting STAGING certificate for $JOPLIN_SUBDOMAIN.$DOMAIN_NAME..."
        else
            # production mode (default)
            echo "  - Requesting PRODUCTION certificate for $JOPLIN_SUBDOMAIN.$DOMAIN_NAME..."
        fi
        
        ssh -i "$PRIVATE_KEY" -o IdentitiesOnly=yes root@$IP "docker run --rm \
          -v /etc/letsencrypt:/etc/letsencrypt \
          -v /opt/notes-stack/certbot-www:/var/www/certbot \
          $CERTBOT_CMD"

        if [ $? -ne 0 ]; then
            echo "❌ Error: Certbot failed to obtain certificate for $JOPLIN_SUBDOMAIN.$DOMAIN_NAME."
            exit 1
        fi
    else
        echo "  - Certificate for $JOPLIN_SUBDOMAIN.$DOMAIN_NAME already exists."
    fi

    if [ "$CERTBOT_MODE" = "dry-run" ]; then
        echo "⚠️  DRY-RUN completed. No real certificates were created."
        echo "💡 Set CERTBOT_MODE=staging or CERTBOT_MODE=production in your .env file to create real certificates."
        SSL_ENABLED="false"
    elif [ "$CERTBOT_MODE" = "staging" ]; then
        echo "🔄 Staging certificates obtained. Re-running Ansible to enable SSL..."
        echo "⚠️  Note: Staging certificates are for testing only and will show warnings in browsers."
        SSL_ENABLED="true"
    else
        # production mode
        echo "🔄 Production certificates obtained. Re-running Ansible to enable SSL..."
        SSL_ENABLED="true"
    fi
    
else
    echo "✅ Certificates already exist. Skipping Certbot."
    SSL_ENABLED="true"
fi

    # 3. Final Ansible Pass (Enabling SSL only if not dry-run and certificates exist)
    if [ "$SSL_ENABLED" = "true" ]; then
        # We pass enable_ssl=true as an extra-var so the playbook picks the .ssl.j2 templates
        ansible-playbook -i "$IP," ansible/playbook.yml \
          --user root \
          --private-key "$PRIVATE_KEY" \
          --ssh-common-args='-o IdentitiesOnly=yes' \
          --extra-vars "enable_ssl=true postgres_pwd=$POSTGRES_PASSWORD enable_block_storage=$ENABLE_BLOCK_STORAGE enable_s3_storage=$ENABLE_S3_STORAGE s3_key=$SPACES_ACCESS_KEY_ID s3_secret=$SPACES_SECRET_ACCESS_KEY s3_bucket=$SPACES_BUCKET_NAME s3_region=$DO_REGION domain=$DOMAIN_NAME joplin_sub=$JOPLIN_SUBDOMAIN certbot_mode=$CERTBOT_MODE acme_email=$ACME_EMAIL mailer_enabled=${MAILER_ENABLED:-false} mailer_host=${MAILER_HOST:-} mailer_port=${MAILER_PORT:-} mailer_secure=${MAILER_SECURE:-false} mailer_user=${MAILER_USER:-} mailer_password=${MAILER_PASSWORD:-} mailer_from_email=${MAILER_FROM_EMAIL:-} mailer_from_name=${MAILER_FROM_NAME:-} mailer_noreply_email=${MAILER_NOREPLY_EMAIL:-} mailer_noreply_name=${MAILER_NOREPLY_NAME:-}"
    else
        echo "⏭️  Skipping SSL enablement (dry-run mode or no certificates)."
    fi

echo "🎉 DEPLOYMENT COMPLETE!"
echo "------------------------------------------------"
echo "Joplin:  https://$JOPLIN_SUBDOMAIN.$DOMAIN_NAME"
echo "------------------------------------------------"
