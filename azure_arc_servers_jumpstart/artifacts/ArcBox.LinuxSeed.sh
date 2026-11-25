#!/bin/bash
set -euo pipefail

id='__INSTANCE__'
worker='__WORKER_PUBLIC__'
[[ "$id" =~ ^arcbox-[a-f0-9]{32}$ ]]
[[ "$worker" =~ ^ssh-ed25519\ [a-zA-Z0-9+/]{60,100}={0,2}$ ]]
for nic in /sys/class/net/*/device; do test ! -e "$nic"; done
test -c /dev/ttyS0
stty -F /dev/ttyS0 115200 raw -echo
printf 'ARCBOX-SEED:%s:Started\n' "$id" > /dev/ttyS0

root=$(mktemp -d /tmp/arcbox-seed.XXXXXXXX)
mounted=
active=
key=
cleanup() {
    rc=$?
    trap - EXIT
    if [ "$mounted" ]; then umount "$root" || rc=41; fi
    if [ "$active" ]; then vgchange -an --devices "$pv" ubuntu-vg >/dev/null || rc=42; fi
    rmdir "$root" || rc=43
    if [ "$rc" -eq 0 ] && [ "$key" ]; then
        printf 'ARCBOX-SEED:%s:Ready %s\n' "$id" "$key" > /dev/ttyS0
    else
        printf 'ARCBOX-SEED:%s:Failed %d\n' "$id" "$rc" > /dev/ttyS0
    fi
    systemctl --no-block poweroff
    exit "$rc"
}
trap cleanup EXIT

mapfile -t disk < <(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}')
[ "${#disk[@]}" -eq 1 ] || exit 30
mapfile -t parts < <(lsblk -nrpo NAME,PARTUUID,FSTYPE "${disk[0]}" | awk 'tolower($2)=="8d64fd6c-5b61-408e-904d-74666fe41bff" && $3=="LVM2_member"{print $1}')
[ "${#parts[@]}" -eq 1 ] || exit 31
pv=${parts[0]}
[[ "$pv" =~ ^/dev/sd[a-z]+3$ ]] || exit 32
[ "$(pvs --devices "$pv" --noheadings -o vg_name "$pv" | xargs)" = ubuntu-vg ] || exit 33
vgchange -ay --devices "$pv" ubuntu-vg >/dev/null
active=1
[ "$(lvs --devices "$pv" --noheadings -o lv_path ubuntu-vg | xargs)" = /dev/ubuntu-vg/ubuntu-lv ] || exit 34
mount -t ext4 -o rw,nodev,nosuid,noexec /dev/ubuntu-vg/ubuntu-lv "$root"
mounted=1
for path in etc etc/ssh etc/cloud etc/cloud/cloud.cfg.d home home/jumpstart var var/lib; do
    [ -d "$root/$path" ] && [ ! -L "$root/$path" ] || exit 35
done
account=$(awk -F: '$1=="jumpstart" && $6=="/home/jumpstart" {print $3 ":" $4}' "$root/etc/passwd")
[[ "$account" =~ ^[1-9][0-9]{3,4}:[1-9][0-9]{3,4}$ ]] || exit 36
sshdir=$root/home/jumpstart/.ssh
auth=$sshdir/authorized_keys
receipt=$root/var/lib/arcbox-provisioning
cfg=$root/etc/cloud/cloud.cfg.d/99-zz-arcbox-hostkeys.cfg
for dst in "$sshdir" "$auth" "$receipt" "$cfg"; do
    [ ! -L "$dst" ] || exit 37
done
[ ! -e "$receipt" ] && [ ! -e "$cfg" ] || exit 38
install -d -m 0700 -o "${account%:*}" -g "${account#*:}" "$sshdir"
install -d -m 0700 "$receipt"
if [ -f "$auth" ]; then
    install -m 0600 "$auth" "$receipt/authorized_keys.before"
else
    [ ! -e "$auth" ] || exit 39
    install -m 0600 /dev/null "$receipt/authorized_keys.before"
    install -m 0600 -o "${account%:*}" -g "${account#*:}" /dev/null "$auth"
fi
if ! grep -Fqx -- "$worker" "$auth"; then printf '\n%s\n' "$worker" >> "$auth"; fi
chown "$account" "$auth"
chmod 0600 "$auth"
before=$(stat -c '%s' "$receipt/authorized_keys.before")
if [ "$before" -gt 0 ]; then cmp -n "$before" "$auth" "$receipt/authorized_keys.before"; fi
# systemd-networkd can derive a DHCP DUID from machine-id. Sibling clones need distinct identities.
machine_id=$(tr -d '-' </proc/sys/kernel/random/uuid)
[[ "$machine_id" =~ ^[a-f0-9]{32}$ ]]
test -f "$root/etc/machine-id" && test ! -L "$root/etc/machine-id"
printf '%s\n' "$machine_id" > "$root/etc/machine-id"
chmod 0444 "$root/etc/machine-id"
dbus=$root/var/lib/dbus
if [ -e "$dbus" ]; then
    test -d "$dbus" && test ! -L "$dbus"
    target=$dbus/machine-id
    if [ -L "$target" ]; then
        case "$(readlink "$target")" in
            /etc/machine-id|../../../etc/machine-id) ;;
            *) exit 44 ;;
        esac
    elif [ -e "$target" ]; then
        test -f "$target"
        printf '%s\n' "$machine_id" > "$target"
    fi
fi
for keytype in ed25519 ecdsa rsa; do
    path=$root/etc/ssh/ssh_host_${keytype}_key
    test ! -L "$path" && test ! -L "$path.pub"
    rm -f -- "$path" "$path.pub"
    ssh-keygen -q -t "$keytype" -N '' -C '' -f "$path"
done
umask 077
printf '%s\n' "$id" > "$receipt/instance-id"
printf 'ssh_deletekeys: false\n' > "$cfg"
sync -f "$root"
key=$(awk 'NR==1 {print $1 " " $2}' "$root/etc/ssh/ssh_host_ed25519_key.pub")
[[ "$key" =~ ^ssh-ed25519\ [a-zA-Z0-9+/]{60,100}={0,2}$ ]]
