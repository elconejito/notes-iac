# 1. TERRAFORM & PROVIDERS
terraform {
  required_providers {
    digitalocean = { source = "digitalocean/digitalocean" }
    cloudflare   = { source = "cloudflare/cloudflare" }
  }
}

provider "digitalocean" {
  token = var.do_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# 2. VARIABLES (Passed from setup.sh)
variable "ssh_public_key_path" {}
variable "do_token" {}
variable "do_region" { default = "nyc3" }
variable "cloudflare_api_token" {}
variable "cloudflare_zone_id" {}
variable "domain" {}
variable "joplin_subdomain" {}
variable "enable_block_storage" { type = bool }
variable "cloudflare_proxy_domain" { type = bool; default = false }

# 3. DIGITALOCEAN HARDWARE
# 1. Get the fingerprint of your local public key
# This uses a local-exec or a simple provider function to calculate it
locals {
  # Terraform can't natively calculate MD5 fingerprints easily, 
  # so we will use the data source to filter all keys.
}

# 2. Look for the key by its public_key content
data "digitalocean_ssh_keys" "filter" {
  filter {
    key    = "public_key"
    values = [trimspace(file(var.ssh_public_key_path))]
  }
}

# 3. Use the existing key if found, otherwise create a new one
resource "digitalocean_ssh_key" "project_key" {
  count      = length(data.digitalocean_ssh_keys.filter.ssh_keys) > 0 ? 0 : 1
  name       = "Notes-System-Key"
  public_key = file(var.ssh_public_key_path)
}

# 4. Use the ID from the search or the new resource
locals {
  final_ssh_key_id = length(data.digitalocean_ssh_keys.filter.ssh_keys) > 0 ? data.digitalocean_ssh_keys.filter.ssh_keys[0].id : digitalocean_ssh_key.project_key[0].id
}

resource "digitalocean_volume" "notes_data" {
  # If false, count is 0. If true, count is 1.
  count                   = var.enable_block_storage ? 1 : 0
  region                  = var.do_region
  name                    = "notes-data-vol"
  size                    = 20
  initial_filesystem_type = "ext4"
}

resource "digitalocean_droplet" "note_server" {
  image  = "ubuntu-24-04-x64"
  name   = "notes-cabinet"
  region = var.do_region
  size   = "s-1vcpu-1gb"
  # This assumes you have an SSH key added to your DO account
  # Replace with your actual key name or ID
  ssh_keys = [local.final_ssh_key_id]

  # Force replacement instead of resize when size changes
  # DigitalOcean cannot resize when current disk is larger than target droplet's disk
  lifecycle {
    create_before_destroy = false
  }
}

resource "digitalocean_volume_attachment" "notes_attach" {
  count      = var.enable_block_storage ? 1 : 0
  droplet_id = digitalocean_droplet.note_server.id
  volume_id  = digitalocean_volume.notes_data[0].id
}

resource "digitalocean_firewall" "notes_firewall" {
  name = "notes-stack-firewall"
  droplet_ids = [digitalocean_droplet.note_server.id]

  # 1. ALLOW SSH (Don't skip this!)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # 2. ALLOW HTTP (For Let's Encrypt and Redirects)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # 3. ALLOW HTTPS (Your main traffic)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # 4. ALLOW ALL OUTBOUND
  # Servers need to talk to the internet to download updates/Docker images
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# 4. CLOUDFLARE DNS RECORDS
resource "cloudflare_dns_record" "joplin" {
  zone_id = var.cloudflare_zone_id
  name    = var.joplin_subdomain
  content = digitalocean_droplet.note_server.ipv4_address # "value" changed to "content"
  type    = "A"
  proxied = var.cloudflare_proxy_domain
  ttl     = 60
}

# 5. OUTPUTS
output "droplet_ip" {
  value = digitalocean_droplet.note_server.ipv4_address
}
