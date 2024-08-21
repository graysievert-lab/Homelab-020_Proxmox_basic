# Image processing machine

Eventually we would need some VM image to create our VMs from. Such images could be easily fetched from the internet, but they tend to accumulate the backlog of packages to update.

At this very early stage of our lab we will create a simple VM whose sole purpose is to get the base cloud image from the internet, and update it with guest-tools.

## Creating `goldmine` VM

Log into proxmox shell.

Ensure snippets are enabled in `local` storage.
CAUTION: the command below will configure `local` storage to store `ISO images`, `Container templates`, `VZDump backup files`, `snippets`:

```bash
$ pvesm set local --content vztmpl,backup,iso,snippets
```

Download Fedora cloud image:

```bash
$ wget -c \
-O /var/lib/vz/template/iso/Fedora-Cloud-Base-Generic.x86_64-40-1.14.qcow2.img \
https://download.fedoraproject.org/pub/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-Generic.x86_64-40-1.14.qcow2
```

Note: Adding `.img` after `qcow2` extension to make the file visible in UI, so it is easier to delete it one day.

Create folder for scripts:

```bash
$ mkdir -p /root/goldmine && cd /root/goldmine/
```

Download script from repo:

```bash
$ curl -LO https://raw.githubusercontent.com/graysievert/Homelab-020_Proxmox_basic/master/120-Simple_image_updater/goldmine.sh
```

Set execution bit:

```bash
$ chmod +x goldmine.sh
```

Create, configure and start VM (I'm using VM ID = 20000):

```bash
$ ./goldmine.sh /var/lib/vz/template/iso/Fedora-Cloud-Base-Generic.x86_64-40-1.14.qcow2.img 20000

$ qm start 20000 ; qm terminal 20000
```

one may leave the terminal by pressing `ctrl+o`.

Now it should be possible to ssh into VM:

```bash
$ ssh fedora@goldmine.lan -i goldmine_key -o IdentitiesOnly=yes
```

### Troubleshooting

If ssh can't login, check name resolution and if necessary ssh using IP. One may check what IP VM got by:

```bash
$ qm guest cmd 20000 network-get-interfaces | jq '.[1]."ip-addresses"[0]."ip-address"'
```

If ssh does not work,change the password for `fedora` user

```bash
$ qm guest passwd 20000 fedora
```

and login via terminal

```bash
$ qm terminal 20000
```

to leave terminal press `ctrl+o`.

## Dig the golden image

Cloud-init should install `guestfs-tools`:

```bash
[fedora@goldmine ~]$ virt-sysprep --version
```

Download rocky linux 9.3 cloud image

```bash
[fedora@goldmine ~]$ wget -c https://dl.rockylinux.org/vault/rocky/9.3/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2
```

and update it (updating packages may take a long time but it also will save a ton later):

```bash
[fedora@goldmine ~]$ virt-sysprep -a ./Rocky-9-GenericCloud-Base.latest.x86_64.qcow2 --update --network
[   0.0] Examining the guest ...
[  15.3] Performing "abrt-data" ...
[  15.3] Performing "backup-files" ...
[  16.4] Performing "bash-history" ...
[  16.5] Performing "blkid-tab" ...
[  16.5] Performing "crash-data" ...
[  16.5] Performing "cron-spool" ...
[  16.6] Performing "dhcp-client-state" ...
[  16.6] Performing "dhcp-server-state" ...
[  16.6] Performing "dovecot-data" ...
[  16.6] Performing "ipa-client" ...
[  16.6] Performing "kerberos-hostkeytab" ...
[  16.6] Performing "logfiles" ...
[  16.8] Performing "lvm-system-devices" ...
[  16.8] Performing "machine-id" ...
[  16.8] Performing "mail-spool" ...
[  16.8] Performing "net-hostname" ...
[  16.8] Performing "net-hwaddr" ...
[  16.8] Performing "net-nmconn" ...
[  16.9] Performing "pacct-log" ...
[  16.9] Performing "package-manager-cache" ...
[  16.9] Performing "pam-data" ...
[  16.9] Performing "passwd-backups" ...
[  17.0] Performing "puppet-data-log" ...
[  17.0] Performing "rh-subscription-manager" ...
[  17.0] Performing "rhn-systemid" ...
[  17.0] Performing "rpm-db" ...
[  17.0] Performing "samba-db-log" ...
[  17.0] Performing "script" ...
[  17.0] Performing "smolt-uuid" ...
[  17.1] Performing "ssh-hostkeys" ...
[  17.1] Performing "ssh-userdir" ...
[  17.1] Performing "sssd-db-log" ...
[  17.1] Performing "tmp-files" ...
[  17.1] Performing "udev-persistent-net" ...
[  17.1] Performing "utmp" ...
[  17.2] Performing "yum-uuid" ...
[  17.2] Performing "customize" ...
[  17.2] Setting a random seed
[  17.2] Setting the machine ID in /etc/machine-id
[  17.2] Updating packages
[ 249.1] SELinux relabelling
[ 270.9] Performing "lvm-uuids" ...
```

After update is finished, log out from `goldmine` and fetch updated image to proxmox image storage:

```bash
$ scp -i goldmine_key -o IdentitiesOnly=yes \
fedora@goldmine.lan:Rocky-9-GenericCloud-Base.latest.x86_64.qcow2 \
/var/lib/vz/template/iso/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2.img
```

Create test machine (VM ID =20100)

```bash
$ qm create 20100 \
	--name "rocky-test" \
	--description "testvm" \
	\
	--agent enabled=1,freeze-fs-on-backup=1,fstrim_cloned_disks=0,type=virtio \
	--protection 0 \
	\
	--machine type=q35 \
	--ostype l26 \
	--acpi 1 \
	--bios ovmf \
	--efidisk0 file="local-zfs":4,efitype=4m,pre-enrolled-keys=0 \
	--rng0 source=/dev/urandom,max_bytes=1024,period=1000 \
	\
	--cpu cputype="host" \
	--sockets 1 \
	--cores 2 \
	\
	--memory 4096 \
	--balloon 1024 \
	\
	--vga type=serial0 \
	--serial0 socket \
	\
	--boot order=scsi0 \
	--cdrom "local-zfs":cloudinit \
	--scsihw virtio-scsi-single \
	--scsi0 file="local-zfs":0,import-from="/var/lib/vz/template/iso/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2.img",aio=native,iothread=on,queues=2 \
	\
	--net0 model=virtio,bridge=vmbr0,firewall=1,link_down=0,mtu=1
```

and check boot process

```bash
$ qm start 20100 ; qm terminal 20100
```

exit terminal with `ctrl+o`

As there was no cloud-init customization, let's hack into the machine.

Change password:

```bash
$ qm guest passwd 20100 rocky
Enter new password:
Retype new password:
```

then reconnect the terminal and login

```bash
$ qm terminal 20100
starting serial terminal on interface serial0 (press Ctrl+O to exit)
rocky-test login: rocky
Password:
[rocky@rocky-test ~]$
```

and check that packages are recent

```bash
[rocky@rocky-test ~]$ sudo dnf upgrade
```

Leave terminal with `ctrl+o` and destroy the test vm:

```bash
$ qm stop 20100 && qm destroy 20000
```

Now we should have a base image prepared for the next steps.

## Cleanup

To remove cloud-init snippets and ssh key, check `goldmine_cleanup.sh`
