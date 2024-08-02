########################################
## DISCLAIMER
## This file is the complete opposite of the best-practices for terraform.
## Everyting is piled up for illustration purposes only
########################################


########################################
## Variables. Use TF_VAR_xxxx shell vars to set/override
########################################
variable "node_name" {
  description = "name of proxmox node"
  type        = string
  default     = "pve"
}

variable "pveusername" {
  description = "PAM username for ssh use"
  type        = string
  default     = "iac"
}

variable "pvetoken" {
  description = "Proxmox API token for TF to use"
  type        = string
  ## see readme for setting token via shell variable
}

variable "public_ssh_key_for_VM" {
  description = "Public ssh key to use in cloud-init config for test vm"
  type        = string
  ## see readme for setting token via shell variable
}

########################################
## Provider config
########################################

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.61.1"
    }
  }
}

provider "proxmox" {
  endpoint  = "https://pve.lan:8006/"
  api_token = var.pvetoken

  ssh {
    agent    = true
    username = var.pveusername
  }
}

########################################
## Local variables
########################################


locals {
  datastore_id = "local-zfs"
  image        = "local:iso/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2.img"
  hostname     = "newhost"
  vm_id        = 999
  vm_tags      = ["test"]
  ssh_key      = var.public_ssh_key_for_VM
}

########################################
## Cloud-init custom configs
########################################


resource "proxmox_virtual_environment_file" "cloudinit_meta_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.node_name

  source_raw {
    file_name = "${local.hostname}-meta-config.yaml"
    data      = <<EOF
#cloud-config
local-hostname: ${local.hostname}
instance-id: ${md5(local.hostname)}
EOF
  }
}

resource "proxmox_virtual_environment_file" "cloudinit_user_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.node_name

  source_raw {
    file_name = "${local.hostname}-user-config.yaml"
    data      = <<EOF
#cloud-config
ssh_authorized_keys:
  - "${local.ssh_key}"
user:
  name: rocky
users:
  - default
EOF
  }
}

resource "proxmox_virtual_environment_file" "cloudinit_vendor_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.node_name

  source_raw {
    file_name = "${local.hostname}-vendor-config.yaml"
    data      = <<EOF
#cloud-config

packages:
    - qemu-guest-agent

runcmd:
  - echo "I am $(whoami), myenv is \n $(printenv)"
EOF
  }
}


########################################
## Virtual Machine
########################################

resource "proxmox_virtual_environment_vm" "vm_node" {
  description = "project node"
  tags        = local.vm_tags
  name        = local.hostname
  node_name   = var.node_name
  vm_id       = local.vm_id
  started     = true
  on_boot     = true
  acpi        = true
  
  ## cloud-init section.
  initialization {
    datastore_id        = local.datastore_id
    user_data_file_id   = proxmox_virtual_environment_file.cloudinit_user_config.id
    vendor_data_file_id = proxmox_virtual_environment_file.cloudinit_vendor_config.id
    meta_data_file_id   = proxmox_virtual_environment_file.cloudinit_meta_config.id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  ## VM parameters.
  agent {
    enabled = true
    timeout = "15m"
    trim    = false
    type    = "virtio"
  }
  bios       = "ovmf"
  boot_order = ["scsi0"]
  machine    = "q35"
  operating_system {
    type = "l26"
  }

  memory {
    dedicated = 4096
    floating  = 1024
  }
  cpu {
    architecture = "x86_64"
    type         = "host"
    cores        = 2
    numa         = false
    sockets      = 1
  }

  disk {
    aio          = "native"
    datastore_id = local.datastore_id
    file_format  = "raw"
    file_id      = local.image
    interface    = "scsi0"
    iothread     = true
    size         = 15
  }
  efi_disk {
    datastore_id      = local.datastore_id
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = false
  }
  tpm_state {
    datastore_id = local.datastore_id
    version      = "v2.0"
  }


  serial_device {
    device = "socket"
  }
  scsi_hardware = "virtio-scsi-single"
  tablet_device = true

  vga {
    type = "serial0"
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
    mtu    = 1
  }

  lifecycle {
    ignore_changes = [
      # vm_id,
      # id,
      # name,
      # tags,
      # cpu,
      # template,
      initialization
    ]
  }

}
