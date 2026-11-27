#!/bin/sh
set -eu
stage=guest-start
installer_log=/var/log/arcbox-install-agent.log
record() (
    umask 077
    printf '%s %s\n' "${2:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}" "$1" >> "$installer_log"
)
finish() {
    code=$?
    trap - 0
    record "Stopped at $stage with exit $code." "${package_failed_at:-}" || :
    exit "$code"
}

snapshot() {
    if [ ! -e "$1" ]; then printf missing
    elif [ ! -f "$1" ]; then printf unavailable
    else stat -Lc '%d:%i:%s' -- "$1" 2>/dev/null || printf unavailable
    fi
}

capture_append() (
    umask 077
    after=$(snapshot "$1")
    case "$after" in missing|unavailable) printf '%s' "$after"; exit ;; esac
    case "$2" in missing|unavailable) printf unbound; exit ;; esac
    old_size=${2##*:}
    size=${after##*:}
    if [ "${2%:*}" != "${after%:*}" ] || [ "$size" -lt "$old_size" ]; then
        printf unstable
        exit
    fi
    bytes=$((size - old_size))
    state=captured
    if [ "$bytes" -eq 0 ]; then printf unchanged; exit; fi
    if [ "$bytes" -gt 32768 ]; then bytes=32768; state=truncated; fi
    if ! dd if="$1" of="$3" bs=4096 iflag=skip_bytes,count_bytes \
            skip="$((size - bytes))" count="$bytes" status=none 2>/dev/null; then
        printf unavailable
    elif ! copied=$(wc -c 2>/dev/null < "$3"); then
        printf unavailable
    elif [ "$(snapshot "$1")" != "$after" ] || [ "$copied" -ne "$bytes" ]; then
        printf unstable
    else
        printf '%s' "$state"
    fi
)

run_package_installer() {
    bash -c '
        umask 077
        # Drain the stream without limiting or changing the installer exit.
        if { exec 3> >(
            if { exec 4>"$2"; } 2>/dev/null; then exec tail -c 65537 >&4; fi
            cat >/dev/null
            exit 1
        ); }; then
            reader=$!
        else
            bash "$1" </dev/null >/dev/null 2>&1
            native=$?
            failed_at=$(date -u "+%Y-%m-%dT%H:%M:%SZ") || failed_at=unknown
            printf "%s unavailable\n" "$failed_at"
            exit "$native"
        fi
        bash "$1" </dev/null >&3 2>&1 3>&-
        native=$?
        failed_at=$(date -u "+%Y-%m-%dT%H:%M:%SZ") || failed_at=unknown
        exec 3>&-
        # An inherited descriptor must not make diagnostics hold the worker.
        for i in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$reader" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$reader" 2>/dev/null; then
            kill "$reader" 2>/dev/null || :
            state=unavailable
        elif ! wait "$reader" || ! bytes=$(wc -c < "$2"); then state=unavailable
        elif [ "$bytes" -eq 0 ]; then state=empty
        elif [ "$bytes" -eq 65537 ]; then state=truncated-or-limit
        else state=captured
        fi
        printf "%s %s\n" "$failed_at" "$state"
        exit "$native"
    ' arcbox-package "$1" "$2" 2>/dev/null
}

package_clue() {
    for source do
        [ -f "$source" ] || continue
        if LC_ALL=C grep -aiqE '^E: (Could not get lock|Unable to acquire the dpkg frontend lock)' "$source"; then printf apt-lock; return; fi
        if LC_ALL=C grep -aiqE '^E: (Unmet dependencies|Unable to correct problems)' "$source"; then printf apt-dependency; return; fi
        if LC_ALL=C grep -aiqE '^E: (Failed to fetch|Unable to fetch some archives)' "$source"; then printf apt-download; return; fi
        if LC_ALL=C grep -aiqE '^dpkg: error' "$source"; then printf dpkg-error; return; fi
    done
    printf unclassified
}

trap finish 0
record 'Linux Arc installer started.'

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
vendor="$HOME/install_linux_azcmagent.sh"
wget https://aka.ms/azcmagent -O "$vendor" >/dev/null 2>&1

capture=$(umask 077; mktemp -d /var/lib/arcbox-provisioning/package.XXXXXXXXXX 2>/dev/null) || capture=
apt_controlled=false
if command -v apt-get >/dev/null && command -v dpkg >/dev/null; then
    stage=apt-controller
    ARCBOX_APT_HELPER="$(dirname -- "$0")/arcbox_apt.py"
    ARCBOX_APT_WORK=$capture
    export ARCBOX_APT_HELPER ARCBOX_APT_WORK
    if [ -z "$capture" ] || ! python3 "$ARCBOX_APT_HELPER" prepare "$capture" "$vendor" >/dev/null 2>&1; then
        record 'APT controller prerequisites or the reviewed vendor script could not be verified; package installation did not run.' || :
        printf 'ArcBoxAptControllerUnavailable\n'
        exit 125
    fi
    vendor="$capture/vendor-candidate.sh"
    apt_controlled=true
fi

stage=package-install
record 'Running the vendor package install.'
apt_log=/var/log/apt/term.log
dpkg_log=/var/log/dpkg.log
code=0
if [ -n "$capture" ] && command -v tail >/dev/null && command -v cat >/dev/null; then
    apt_before=$(snapshot "$apt_log")
    dpkg_before=$(snapshot "$dpkg_log")
    result=$(run_package_installer "$vendor" "$capture/installer.log") || code=$?
else
    bash "$vendor" </dev/null >/dev/null 2>&1 || code=$?
    failed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || failed_at=unknown
    result="$failed_at unavailable"
fi
if [ "$apt_controlled" = true ]; then
    { rm -f -- "$vendor" && python3 "$ARCBOX_APT_HELPER" emit "$capture"; } 2>/dev/null ||
        record 'Could not return the APT wait summary.' || :
fi

if [ "$code" -ne 0 ]; then
    package_failed_at=${result%% *}
    installer_state=${result#* }
    if [ -z "$installer_state" ] || [ "$result" = "$installer_state" ]; then
        package_failed_at=unknown
        installer_state=unavailable
    fi
    apt_state=unavailable
    dpkg_state=unavailable
    clue=unclassified
    if [ -n "$capture" ]; then
        apt_state=$(capture_append "$apt_log" "${apt_before:-unavailable}" "$capture/apt.log") || apt_state=unavailable
        dpkg_state=$(capture_append "$dpkg_log" "${dpkg_before:-unavailable}" "$capture/dpkg.log") || dpkg_state=unavailable
        for source in installer apt dpkg; do
            case "$source" in installer) state=$installer_state ;; apt) state=$apt_state ;; dpkg) state=$dpkg_state ;; esac
            case "$state" in
                captured|truncated|truncated-or-limit)
                    clue=$(package_clue "$capture/$source.log") || clue=unclassified
                    [ "$clue" = unclassified ] || break
                    ;;
            esac
        done
        (umask 077; printf '%s\n' "$package_failed_at $code $installer_state $apt_state $dpkg_state" > "$capture/result") 2>/dev/null ||
            record 'Could not save package capture metadata.' || :
    fi
    capture_id=${capture##*/}
    printf 'ArcBoxPackageFailure:v1:%s:%s:%s:%s:%s:%s:%s\n' \
        "$code" "$package_failed_at" "${capture_id:-none}" "$installer_state" "$apt_state" "$dpkg_state" "$clue" || :
    exit "$code"
fi
if [ -n "$capture" ]; then
    { rm -f -- "$capture/installer.log" "$capture/first-package-error.log" &&
        { [ -f "$capture/apt-wait.jsonl" ] || rmdir -- "$capture"; }; } 2>/dev/null ||
        record 'Could not discard the private package buffer after success.' || :
fi
resource_name=$(hostname | sed -e "s/\b\(.\)/\u\1/g")

stage=agent-connect
record 'Calling azcmagent connect; see /var/opt/azcmagent/log/azcmagent.log for agent diagnostics.'
command -v azcmagent >/dev/null || exit 127
code=0
output=$(azcmagent connect --access-token "$access_token" --resource-group "$1" --tenant-id "$2" --location "$3" \
    --subscription-id "$4" --resource-name "$resource_name" --cloud AzureCloud --tags 'Project=jumpstart_arcbox,createdBy=copilot' \
    --correlation-id 'd009f5dd-dba8-4ac7-bac9-b54ef3a6671a' 2>&1) || code=$?
unset access_token
printf 'ArcBoxConnectExit:%d\n' "$code"
# No free text or query strings leave this command. The client still verifies the resource and tenant.
printf '%s\n' "$output" | grep -Eio \
    '\bAZCM[0-9]{4}\b|(^|[[:space:]])https://portal\.azure\.com/#(@[a-f0-9-]{36})?/resource/subscriptions/[a-f0-9-]{36}/resourceGroups/[a-z0-9._()-]+/providers/Microsoft\.HybridCompute/machines/[a-z0-9._-]+(/overview)?([[:space:]]|$)' || :
unset output
if [ "$code" -eq 0 ]; then stage=completed; fi
exit "$code"
