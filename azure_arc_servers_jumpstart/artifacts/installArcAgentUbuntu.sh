#!/bin/sh
set -eu
stage=guest-start
installer_log=/var/log/arcbox-install-agent.log
record() (
    umask 077
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$installer_log"
)
finish() {
    code=$?
    trap - 0
    record "Stopped at $stage with exit $code." || :
    exit "$code"
}
trap finish 0
record 'Ubuntu-01 installer started.'

# Host-to-guest transport remains stdin; the agent retains its original authentication flag.
stage=input
IFS= read -r access_token
case "$access_token" in ''|*[!A-Za-z0-9._-]*) exit 1 ;; esac
test "$#" -eq 4

stage=firewall
record 'Applying the nested Azure IMDS firewall baseline.'
sudo ufw --force enable >/dev/null 2>&1
sudo ufw deny out from any to 169.254.169.254 >/dev/null 2>&1
sudo ufw default allow incoming >/dev/null 2>&1

stage=download
record 'Downloading the Connected Machine agent installer.'
wget https://aka.ms/azcmagent -O ~/install_linux_azcmagent.sh >/dev/null 2>&1

stage=package-install
record 'Running the vendor package install; check the guest package manager logs if it fails.'
bash ~/install_linux_azcmagent.sh >/dev/null 2>&1
resource_name=$(hostname | sed -e "s/\b\(.\)/\u\1/g")

stage=agent-connect
record 'Calling azcmagent connect; see /var/opt/azcmagent/log/azcmagent.log for agent diagnostics.'
command -v azcmagent >/dev/null || exit 127
code=0
output=$(azcmagent connect --access-token "$access_token" --resource-group "$1" --tenant-id "$2" --location "$3" \
    --subscription-id "$4" --resource-name "$resource_name" --cloud AzureCloud --tags 'Project=jumpstart_arcbox' \
    --correlation-id 'd009f5dd-dba8-4ac7-bac9-b54ef3a6671a' 2>&1) || code=$?
unset access_token
printf 'ArcBoxConnectExit:%d\n' "$code"
# No free text or query strings leave this command. The client still verifies the resource and tenant.
printf '%s\n' "$output" | grep -Eio \
    '\bAZCM[0-9]{4}\b|(^|[[:space:]])https://portal\.azure\.com/#(@[a-f0-9-]{36})?/resource/subscriptions/[a-f0-9-]{36}/resourceGroups/[a-z0-9._()-]+/providers/Microsoft\.HybridCompute/machines/[a-z0-9._-]+(/overview)?([[:space:]]|$)' || :
unset output
if [ "$code" -eq 0 ]; then stage=completed; fi
exit "$code"
