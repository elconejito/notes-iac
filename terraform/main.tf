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
variable "trilium_subdomain" {}
variable "enable_block_storage" { type = bool }

# 3. DIGITALOCEAN HARDWARE
resource "digitalocean_ssh_key" "project_key" {
  name       = "Notes-System-Key"
  # terraform expands the ~ automatically if passed correctly from the shell
  public_key = file(var.ssh_public_key_path)
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
  size   = "s-1vcpu-2gb"
  # This assumes you have an SSH key added to your DO account
  # Replace with your actual key name or ID
  ssh_keys = [digitalocean_ssh_key.project_key.id] 
}

resource "digitalocean_volume_attachment" "notes_attach" {
  count      = var.enable_block_storage ? 1 : 0
  droplet_id = digitalocean_droplet.note_server.id
  volume_id  = digitalocean_volume.notes_data[0].id
}

# 4. CLOUDFLARE DNS RECORDS
resource "cloudflare_record" "joplin" {
  zone_id = var.cloudflare_zone_id
  name    = var.joplin_subdomain
  value   = digitalocean_droplet.note_server.ipv4_address
  type    = "A"
  proxied = false
  ttl     = 60
}

resource "cloudflare_record" "trilium" {
  zone_id = var.cloudflare_zone_id
  name    = var.trilium_subdomain
  value   = digitalocean_droplet.note_server.ipv4_address
  type    = "A"
  proxied = false
  ttl     = 60
}

# 5. OUTPUTS
output "droplet_ip" {
  value = digitalocean_droplet.note_server.ipv4_address
}
