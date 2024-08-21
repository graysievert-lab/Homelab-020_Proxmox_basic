# Configuring Proxmox VE to be managed via Terraform

To create resources via Terraform we will use [bpg](https://registry.terraform.io/providers/bpg/proxmox/latest/docs) provider as it is currently the most feature-rich one. A lot of the resources could be configured just via Proxmox API token, but some resources cannot be configured through Proxmopx API and require SSH access to be managed.

We are going to create a separate Proxmox user for IaC management in the `pam` realm, grant it access via both SSH and API token, and configure a simple test VM through Terraform.

## Creating a user

Using Proxmox shell Create a user `iac`:

```bash
$ useradd --create-home iac
```

Install sudo

```bash
$ apt install sudo
```

Then add `iac` user to the sudoers file while limiting its access to necessary commands:

```bash
$ cat <<EOF>/etc/sudoers.d/iac
iac ALL=(root) NOPASSWD: /sbin/pvesm
iac ALL=(root) NOPASSWD: /sbin/qm
iac ALL=(root) NOPASSWD: /usr/bin/tee /var/lib/vz/*
EOF
```

NOTE: The user needs to be created on each Proxmox node we are going to control through Terraform.

## Registering the user in Proxmox access manager

Let's make Proxmox aware about the user we have created:

```bash
$ pveum user add iac@pam -comment "User for administering IaC"
```

Now let's create a role and populate it with [privileges](https://pve.proxmox.com/pve-docs/pveum.1.html#_privileges) we would need:

```bash
$ pveum role add "iac-role" \
-privs "Datastore.Allocate \
Datastore.AllocateSpace \
Datastore.AllocateTemplate \
Datastore.Audit \
Pool.Allocate \
Pool.Audit \
Sys.Audit \
Sys.Console \
Sys.Modify \
SDN.Use \
VM.Allocate \
VM.Audit \
VM.Clone \
VM.Config.CDROM \
VM.Config.Cloudinit \
VM.Config.CPU \
VM.Config.Disk \
VM.Config.HWType \
VM.Config.Memory \
VM.Config.Network \
VM.Config.Options \
VM.Migrate \
VM.Monitor \
VM.PowerMgmt \
User.Modify"
```

To edit the role one may use the following command, adding or removing privileges as needed:

```bash
$ pveum role modify "iac-role" \
-privs "modify the list as needed"
```

Assign the role to the user:

```bash
$ pveum aclmod "/" \
-roles "iac-role" \
-users "iac@pam"
```

## Creating API token

Now let's generate an API token for the user:

```bash
$ pveum user token add iac@pam iac-token --privsep 0 --output-format=yaml
---
full-tokenid: iac@pam!iac-token
info:
  privsep: '0'
value: bded1189-0ec4-46c6-9a15-f10d9764f5c8
```

Test access from the machine we are going to run Terraform on:

```bash
$ curl \
--header 'Authorization: PVEAPIToken=iac@pam!iac-token=bded1189-0ec4-46c6-9a15-f10d9764f5c8' \
https://pve.lan:8006/api2/json/nodes | jq .
```

## Enabling SSH

NOTE: SSH public key needs to be uploaded to each Proxmox node we are going to control through Terraform.

There are several options which key to use:

- A key with material stored in a file generated with `ssh-keygen -t ed25519`
- Fetch short-lived SSH certificates (and keys) each time we need them from some SSH authority.
- FIDO2 hardware token that can generate and store key material.
- PIV hardware token and pkcs11 library to generate and store key material.

The best option is SSH CA with short-lived certificates. We will build SSH CA later, but for now, we need an interim solution.

The least appealing option seems to be a key with material in a file on disk, which could leak or be lost.

Hardware tokens look cool, but there is a usability consideration: you might need to touch it and/or enter the PIN each time the SSH is used during resource creation, which is annoying and does not seem to work well with the chosen Terraform provider.

FIDO2 token is very easy to set up and it could be configured in a way that touch and pin are not required, though there are two caveats:

1. It might err on Windows OpenSSH client (as of `OpenSSH_for_Windows_9.5p1`)
`sign_and_send_pubkey: signing failed for ED25519-SK: requested feature not supported`
2. It will most probably work on Linux client where the key was generated, but as of now [no-touch-required flag not restored from hardware token](https://bugzilla.mindrot.org/show_bug.cgi?id=3355), so the key won't transition well to another machine.

PIV tokens also could be configured in a way that touch and pin are not required. While it works on Windows/macOS/Linux, and touchless mode can be used on many machines, the PIV token requires the installation of additional libraries, needs more steps to generate a key, and does not support 4096-bit keys.

### FIDO2 hardware token

Let's use the FIDO2 token to generate and store a private SSH key. Launch the keygen on the machine that will be used for terraform:

```bash
$ ssh-keygen -t ed25519-sk -O resident -O application=ssh:proxmox -O no-touch-required -N "" -C "yubikey:ssh:graysievert" -f iac_proxmox
```

NOTE: Contents of `iac_proxmox` may look similar to an actual private key material, but it is just a proxy to the actual key in the FIDO2 token.

NOTE: As generation was with the `resident` option, the proxy to the private key and the public key can always be fetched from the FIDO2 token with the `ssh-keygen -K` command.

Now on Proxmox node let's create `authorized_keys` file:

```bash
$ mkdir -p /home/iac/.ssh
$ touch /home/iac/.ssh/authorized_keys
$ chown -R iac /home/iac/.ssh
```

Copy the public SSH key that was generated into `authorized_keys` (press `ctl+d` on an empty line to finalize input):

```bash
$ cat ->> /home/iac/.ssh/authorized_keys
no-touch-required sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIL/L9aKIdi0HNCIMUPhv9TE8aFx1605NnaR0IMiUmz6EAAAAC3NzaDpwcm94bW94 yubikey:ssh:graysievert
```

NOTE: While the public key above corresponds to a private key stored on a pin-protected hardware token, such direct management of ssh keys might become cumbersome very quickly. Later, when the lab's infrastructure contains an SSH Certificate Authority we might replace it with `cert-authority` record in `authorized_keys` and generate short-lived SSH certificates for access only when such is required.

Now  let's test from the machine we are going to run terraform on

```bash
ssh iac@pve.lan -i iac_proxmox -o IdentitiesOnly=yes
```

Let's add the key proxy to ssh-agent:

```bash
$ eval "$(ssh-agent)"
$ ssh-add iac_proxmox
```

Test

```bash
$ ssh iac@pve.lan
```

### PIV hardware token

For YubiKey tokens the following policies are available

PIN policies:

- Never: the PIN is never needed
- Always: the PIN needed for every use
- Once: the PIN is needed once per session

Touch policies:

- Never: a touch is never needed
- Always: a touch is needed for every use
- Cached: a touch is not needed if the YubiKey has been touched in the last 15 seconds

To generate a key that could be used for ssh we would need to perform 3 steps:

1. Generate private key material
2. Create a self-signed X.509 certificate for that key
3. Load the certificate to the key.

The last two steps are required for the extraction of public keys from the token.

Generate a key in slot `9a` redirecting the public key into a file

```bash
$ yubico-piv-tool \
--slot=9a \
--action=generate \
--algorithm=RSA2048 \
--hash=SHA256 \
--password="" \
--pin-policy=once \
--touch-policy=never \
--output=public.pem
```

Create a self-signed certificate.

```bash
$ yubico-piv-tool \
--slot=9a \
--action=verify-pin \
--action=selfsign-certificate \
--subject='/CN=yubikey:ssh:graysievert/' \
--input=public.pem \
--output=cert.pem
```

Upload the certificate to the key

```bash
yubico-piv-tool \
--slot=9a \
--action=import-certificate \
--input=cert.pem
```

NOTE: For the next steps we would need the location of the YubiKey libykcs11 library.

- On Linux, it is usually stored at `/usr/local/lib/libykcs11`
- On MacOS, it is in `/usr/local/lib/libykcs11.dylib`
- On windows (git-bash) `/C/Program\ Files/Yubico/Yubico\ PIV\ Tool/bin/libykcs11.dll`

Let's download the SSH public key from the token.

NOTE: The command below will export all keys stored on the YubiKey. The slot order should remain the same, so the key in `9a` will be the first, and last one is Yubico's `Public key for PIV Attestation`:

```bash
$ ssh-keygen -D /C/Program\ Files/Yubico/Yubico\ PIV\ Tool/bin/libykcs11.dll -e

ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCgdUzNLqD2np2EhMRNpM8lmQn+FCfnsnXJCnCny1/DXnxCjegzmzwOabszShDlUQL6MpGfylO7doG7sbrGCC/eAWdeoc61rLnrfflswfXw4jDCQbmUmNcK67LlNp9/bXhGznRF+zBYOhuQglpcPZLSLiB63C/r2QAjICns+44qQSr8ibNExDhC62viMzPb3VayOGL3D3PiHTgC0mgyTwPeNf0ozoVaV4drS5cbclAm/y/OhYw34G87aX8tgY9Dh4I/lHm2srZ0a/Hs5qAAXZARkrdkYWnW6Uo6dA4cDZrWkuw2nsfLUIVvhY6pR3V9ACwQrCptEteAV2/57XHwJsHT Public key for PIV Authentication
...
```

Place it into `/home/iac/.ssh/authorized_keys` on Proxmox nodes (`ctrl+d` on the new line to close stdin):

```bash
$ cat ->> /home/iac/.ssh/authorized_keys
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCgdUzNLqD2np2EhMRNpM8lmQn+FCfnsnXJCnCny1/DXnxCjegzmzwOabszShDlUQL6MpGfylO7doG7sbrGCC/eAWdeoc61rLnrfflswfXw4jDCQbmUmNcK67LlNp9/bXhGznRF+zBYOhuQglpcPZLSLiB63C/r2QAjICns+44qQSr8ibNExDhC62viMzPb3VayOGL3D3PiHTgC0mgyTwPeNf0ozoVaV4drS5cbclAm/y/OhYw34G87aX8tgY9Dh4I/lHm2srZ0a/Hs5qAAXZARkrdkYWnW6Uo6dA4cDZrWkuw2nsfLUIVvhY6pR3V9ACwQrCptEteAV2/57XHwJsHT yubikey:piv:graysievert
```

Let's test the ssh connection:

```bash
$ ssh -I /C/Program\ Files/Yubico/Yubico\ PIV\ Tool/bin/libykcs11.dll iac@pve.lan
```

Now let's populate ssh-agent:

```bash
$ eval $(ssh-agent -s)
$ ssh-add -s /C/Program\ Files/Yubico/Yubico\ PIV\ Tool/bin/libykcs11.dll
```

Test

```bash
$ ssh iac@pve.lan
```

NOTE: To clear the SSH agent from all keys, including hardware ones, use both -D and -e options.

```bash
$ ssh-add -D
$ ssh-add -e /C/Program\ Files/Yubico/Yubico\ PIV\ Tool/bin/libykcs11.dll
```

## Configuring Terraform provider

In the example below the following parameters are used:

- Name of Proxmox node: `pve`
- Node's API endpoint `https://pve.lan:8006/`
- Node's local storage is `local-zfs`
- It is implied that `Rocky-9-GenericCloud-Base.latest.x86_64.qcow2.img` was prepared and snippets storage was configured as described in [120-Simple_image_updater](https://github.com/graysievert-lab/Homelab-020_Proxmox_basic/tree/master/120-Simple_image_updater)
- VM ID `999` is available

For the provider to work we would need to configure:

- Proxmox node endpoint (`https://pve.lan:8006/`),
- API token in the format `username@realm!tokenID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
- Linux username registered on the node for SSH access (`iac`)

Let's fetch a test `.tf` file that will create a few resources through both API and ssh.

```bash
$ curl -LO https://raw.githubusercontent.com/graysievert/Homelab-020_Proxmox_basic/master/130-Terraform_access/terraform/test.tf
```

Now, from stdin let's declare the shell variable `TF_VAR_pvetoken` with API token (enter `ctrl+d` on the new line to finish):

```bash
$ export TF_VAR_pvetoken=$(</dev/stdin)
iac@pam!iac-token=bded1189-0ec4-46c6-9a15-f10d9764f5c8
```

Also, let's declare a variable for the public SSH key that will be later used to access the VM. We may reuse the key already stored in the ssh-agent:

```bash
$ export TF_VAR_public_ssh_key_for_VM=$(</dev/stdin)
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCgdUzNLqD2np2EhMRNpM8lmQn+FCfnsnXJCnCny1/DXnxCjegzmzwOabszShDlUQL6MpGfylO7doG7sbrGCC/eAWdeoc61rLnrfflswfXw4jDCQbmUmNcK67LlNp9/bXhGznRF+zBYOhuQglpcPZLSLiB63C/r2QAjICns+44qQSr8ibNExDhC62viMzPb3VayOGL3D3PiHTgC0mgyTwPeNf0ozoVaV4drS5cbclAm/y/OhYw34G87aX8tgY9Dh4I/lHm2srZ0a/Hs5qAAXZARkrdkYWnW6Uo6dA4cDZrWkuw2nsfLUIVvhY6pR3V9ACwQrCptEteAV2/57XHwJsHT yubikey:piv:graysievert
```

Now let's run terraform:

```bash
$ terraform init
$ terraform plan
$ terraform apply
```

Terraform should create the following resources

```text
proxmox_virtual_environment_file.cloudinit_user_config: Creation complete after 3s [id=local:snippets/newhost-user-config.yaml]
proxmox_virtual_environment_file.cloudinit_meta_config: Creation complete after 3s [id=local:snippets/newhost-meta-config.yaml]
proxmox_virtual_environment_file.cloudinit_vendor_config: Creation complete after 3s [id=local:snippets/newhost-vendor-config.yaml]
proxmox_virtual_environment_vm.vm_node: Creation complete after 1m2s [id=999]
```

In the Proxmox shell, one may track what is going on by executing

```bash
$ qm terminal 999
```

As the final test, let's log in to VM:

```bash
$ ssh rocky@newhost.lan
```

To clean up just use:

```bash
$ terraform destroy
```
