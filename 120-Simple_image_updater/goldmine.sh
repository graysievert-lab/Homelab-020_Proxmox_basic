#!/bin/bash
# set -x

default_storage="local-zfs"

print_usage() {
    echo "Usage: $0 <image_path> <vm_id> [local_storage]"
    echo "  <image_path>: Path to the image file"
    echo "  <vm_id>: VM ID"
    echo "  [local_storage]: Optional local storage. Defaults to ${default_storage}"
    exit 1
}

# args check
if [ "$#" -lt 2 ]; then
    echo "Error: Missing required arguments."
    print_usage
fi

# Assign args
image_path="$1"
vm_id="$2"
local_storage="${3:-$default_storage}"

if [ -n "$local_storage" ]; then
    echo "Using local storage: $local_storage"
else
    echo "No local storage specified. Using default ${default_storage}"
fi


check_image(){
    local image=${1}
    local filename=$(basename "${image}")
    if [ ! -f "${image}" ]; then
        echo "Error: Image file '${image}' does not exist."
        exit 1
    fi
    
    if [[ ! $filename =~ ^Fedora-Cloud-Base-.+\.qcow2.img$ ]]; then
        echo "Error: Image doesn't seem to be a fedora cloud image with extension '.qcow2.img'"
        exit 1
    else
        echo "Using image: $filename"
    fi
    
    
}

check_proxmox() {
    if ! command -v qm &> /dev/null; then
        echo "It does not seem the script is being run on a proxmox node. Exiting"
        exit 1
    fi
}

check_vm_id_free() {
    local vm_id=$1
    local used_vms
    
    if [[ ! "$vm_id" =~ ^[0-9]+$ ]]; then
        echo "Error: VM ID must be a number."
        exit 1
    fi
    
    used_vms=$(qm list | awk '{print $1}' | tail -n +2)
    
    # Check if the VM ID is in the list
    if echo "$used_vms" | grep -q "^$vm_id$"; then
        echo "This VM ID=$vm_id is already used. Chose another one."
        exit 1
    fi
}


create_vm(){
    local VM_DISK_IMAGE=$image_path
    local VM_ID=$vm_id
    local VM_NAME="goldmine-fedora"
    local VM_DESCRIPTION="Goldmine to dig golden images"
    local VM_TAGS="temp,infra,DELETEME"
    local FILE_STORAGE=$local_storage
    local CPU_TYPE="host"
    local CPU_SOCKETS=1
    local CPU_CORES=2
    local MAX_MEMORY=8192
    local MIN_MEMORY=1024
    
    qm create ${VM_ID} \
    --name "${VM_NAME}" \
    --description "${VM_DESCRIPTION}" \
    --tags "${VM_TAGS}" \
    \
    --agent enabled=1,freeze-fs-on-backup=1,fstrim_cloned_disks=0,type=virtio \
    --protection 0 \
    \
    --machine type=q35 \
    --ostype l26 \
    --acpi 1 \
    --bios ovmf \
    --efidisk0 file=${FILE_STORAGE}:4,efitype=4m,pre-enrolled-keys=0 \
    --rng0 source=/dev/urandom,max_bytes=1024,period=1000 \
    \
    --cpu cputype=${CPU_TYPE} \
    --sockets ${CPU_SOCKETS} \
    --cores ${CPU_CORES} \
    \
    --memory ${MAX_MEMORY} \
    --balloon ${MIN_MEMORY} \
    \
    --vga type=serial0 \
    --serial0 socket \
    \
    --boot order=scsi0 \
    --cdrom ${FILE_STORAGE}:cloudinit \
    --scsihw virtio-scsi-single \
    --scsi0 file=${FILE_STORAGE}:0,import-from=${VM_DISK_IMAGE},aio=native,iothread=on,queues=$((${CPU_SOCKETS} * ${CPU_CORES})) \
    \
    --net0 model=virtio,bridge=vmbr0,firewall=1,link_down=0,mtu=1
}


create_ssh_key() {
    local key_file="./goldmine_key"
    local pub_key_file="${key_path}.pub"
    
    # Check if key files already exist
    if [ -f "$key_file" ] || [ -f "$pub_key_path" ]; then
        echo "ssh key file 'goldmine_key' already exist. Skipping key generation. Delete keys manually if there is a need to re-generate."
        return 0
    fi
    
    ssh-keygen -t ed25519 -N "" -C "" -f "$key_file"
    
    if [ $? -eq 0 ]; then
        echo "SSH key successfully created."
    else
        echo "Failed to create SSH key."
        exit 1
    fi
}

create_cloudinit_snippets(){
cat << EOF > /var/lib/vz/snippets/goldmine-meta-config.yaml
#cloud-config
instance-id: goldmine-temp-deleteme
local-hostname: goldmine
EOF
    
cat << EOF > /var/lib/vz/snippets/goldmine-user-config.yaml
#cloud-config
ssh_authorized_keys:
  - $(cat ./goldmine_key.pub)
user:
  name: fedora
users:
  - default
EOF
    
cat << 'EOF' >/var/lib/vz/snippets/goldmine-vendor-config.yaml
#cloud-config
package_upgrade: true
packages:
    - wget
    - qemu-guest-agent
    - guestfs-tools
runcmd:
  - echo "I am $(whoami), myenv is \n $(printenv)"
EOF
}

cloudint_config(){
    local VM_ID=$vm_id
    qm set ${VM_ID} \
    --ipconfig0 ip="dhcp" \
    --cicustom user="local:snippets/goldmine-user-config.yaml",meta="local:snippets/goldmine-meta-config.yaml",vendor="local:snippets/goldmine-vendor-config.yaml"
    
    qm cloudinit update ${VM_ID}
}


# Main script
main() {
    local image_path=$1
    local vm_id=$2
    local local_storage="$3"
    
    check_image $image_path
    
    check_proxmox
    
    check_vm_id_free $vm_id
    
    echo "image path: $image_path\nVM ID:$vm_id\nStorage:$local_storage "
    
    create_ssh_key
    
    create_vm
    
    create_cloudinit_snippets
    
    cloudint_config
    
}

# Execute main
main "$image_path" "$vm_id" "$local_storage"
