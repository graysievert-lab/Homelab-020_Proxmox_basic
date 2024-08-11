########################################
## DISCLAIMER
## This file is the complete opposite of the best-practices for terraform.
## Everyting is piled up for illustration purposes only
########################################

########################################
## Variables. Use TF_VAR_xxxx shell vars to set/override
########################################

variable "pvetoken" {
  ## set this var via environment variable TF_VAR_pvetoken
  description = "Proxmox API token for TF to use"
  type        = string
}

########################################
## Provider config
########################################

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">=0.61.1"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://pve.lan:8006/"
  api_token = var.pvetoken
  ssh {
    agent    = true
    username = "iac"
  }
}

########################################
## resources
########################################

resource "proxmox_virtual_environment_file" "test_snippet" {
  node_name    = "pve"
  content_type = "snippets"
  datastore_id = "local"
  source_raw {
    file_name = "vault_secrets_test.txt"
    data      = "It works!"
  }
}
