#!/bin/bash

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <rhcos-iso-path> [output-iso-path]"
    exit 1
fi

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_PATH="$1"
OUTPUT_ISO="${2:-$1}"
WORK_DIR=$(mktemp -d)
EXTRACTED_IGN="$WORK_DIR/extracted.ign"
MODIFIED_IGN="$WORK_DIR/modified.ign"
HACK_SCRIPT_FILE="$WORK_DIR/hack-script.sh"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Extracting ignition from ISO: $ISO_PATH"

if sudo coreos-installer iso ignition show "$ISO_PATH" > "$EXTRACTED_IGN" 2>/dev/null && [ -s "$EXTRACTED_IGN" ]; then
    echo "Extracted existing ignition configuration"
else
    echo "No existing ignition found. Aborting"
    exit 1
fi

# Write the hack script to a file to avoid quoting hell
cat > "$HACK_SCRIPT_FILE" << 'HACKSCRIPT_EOF'
#!/bin/bash

LOG_FILE="/tmp/ignition-hack.log"
URL="https://192.168.110.2:22623/config/master"
IGN_FILE="/tmp/master-mcs-server.ign"
LOCAL_IGN_DIR="/opt/install-dir"
CONVERTER_IMAGE="quay.io/mavazque/ign-converter:latest"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

resize_root_for_growfs() {
    # Resize sda4 to 2 TiB and create sda5 with the remaining disk space.
    # On first RHCOS boot, ignition-ostree-growfs.service runs xfs_growfs which
    # grows the XFS to fill sda4 (2 TiB). sda5 blocks growpart from extending
    # sda4 further, keeping agcount ≈ 369 < threshold=400 → autosave-xfs skips.
    local DISK=/dev/sda
    local ROOT_PART_NUM=4
    local ROOT_PART_TYPE=8304
    local DATA_PART_NUM=5
    local DATA_PART_TYPE=8300
    local TARGET_SIZE_TIB=2
    local MIN_DISK_GB=2500

    local DISK_GB
    DISK_GB=$(( $(blockdev --getsize64 "$DISK") / 1000000000 ))
    if [ "$DISK_GB" -lt "$MIN_DISK_GB" ]; then
        log "Partition resize: disk=${DISK_GB}GB < ${MIN_DISK_GB}GB — skipping (not a large BM disk)"
        return 0
    fi

    # Idempotent: skip if sda5 already exists
    if sgdisk -p "$DISK" 2>/dev/null | grep -q "^ *${DATA_PART_NUM} "; then
        log "Partition resize: sda${DATA_PART_NUM} already exists — skipping"
        return 0
    fi

    log "Partition resize: disk=${DISK_GB}GB, resizing sda${ROOT_PART_NUM} to ${TARGET_SIZE_TIB} TiB, creating sda${DATA_PART_NUM}"

    # Move secondary GPT to true disk end (coreos-installer leaves it at ~89 GB mark).
    log "Partition resize: moving secondary GPT to disk end..."
    sgdisk -e "$DISK" 2>&1 | tee -a "$LOG_FILE"

    # Resize sda4: delete and recreate at 2 TiB from the same start sector.
    local ROOT_START
    ROOT_START=$(sgdisk -p "$DISK" | awk "/^ *${ROOT_PART_NUM} / {print \$2}")
    log "Partition resize: resizing sda${ROOT_PART_NUM} (start=${ROOT_START}) to +${TARGET_SIZE_TIB}T..."
    sgdisk -d "$ROOT_PART_NUM" "$DISK" 2>&1 | tee -a "$LOG_FILE"
    sgdisk -n "${ROOT_PART_NUM}:${ROOT_START}:+${TARGET_SIZE_TIB}T" \
           -t "${ROOT_PART_NUM}:${ROOT_PART_TYPE}" \
           "$DISK" 2>&1 | tee -a "$LOG_FILE"

    # Create sda5 with all remaining space.
    log "Partition resize: creating sda${DATA_PART_NUM} with remaining space..."
    sgdisk -n "${DATA_PART_NUM}:0:0" \
           -t "${DATA_PART_NUM}:${DATA_PART_TYPE}" \
           "$DISK" 2>&1 | tee -a "$LOG_FILE"

    # Update kernel partition table.
    partx --update --nr "$ROOT_PART_NUM" "$DISK" 2>&1 | tee -a "$LOG_FILE"
    partx --add    --nr "$DATA_PART_NUM" "$DISK" 2>&1 | tee -a "$LOG_FILE"

    log "Partition resize: complete"
    sgdisk -p "$DISK" 2>&1 | tee -a "$LOG_FILE"
}

log "Starting ignition hack script"

# Mask reboot.target immediately so neither the agent nor the OS can reboot
# the node before we have finished writing config.ign to the boot partition.
# We unmask and reboot explicitly at the end.
log "Masking reboot.target to hold the node until ignition is written"
systemctl mask reboot.target

# Pull the ignition converter image
log "Pulling ignition converter image: $CONVERTER_IMAGE"
if podman pull "$CONVERTER_IMAGE" 2>&1 | tee -a "$LOG_FILE"; then
    log "Successfully pulled converter image"
else
    log "ERROR: Failed to pull converter image"
    exit 1
fi

MASTER_IGN_FILE="/tmp/master-mcs-server.ign"

# Wait for both the local ignition file and the bootstrap MCS ignition
# concurrently.  The bootstrap MCS (192.168.110.2:22623) is available during
# the disk-write phase and must be fetched NOW — it disappears when master-0
# reboots, which happens around the same time workers see "Rebooting node".
log "Waiting for local ignition file and bootstrap MCS ignition..."
LOCAL_IGN_FILE=""
MASTER_IGN_READY=0
while true; do
    if [ -z "$LOCAL_IGN_FILE" ]; then
        LOCAL_IGN_FILE=$(find "$LOCAL_IGN_DIR" -maxdepth 1 \( -name 'master-*.ign' -o -name 'worker-*.ign' \) -type f 2>/dev/null | head -1)
        [ -n "$LOCAL_IGN_FILE" ] && log "Found local ignition file: $LOCAL_IGN_FILE"
    fi
    if [ "$MASTER_IGN_READY" -eq 0 ]; then
        if curl -k -s --connect-timeout 2 --max-time 10 -o "$MASTER_IGN_FILE" "https://192.168.110.2:22623/config/master" 2>/dev/null && \
           [ -s "$MASTER_IGN_FILE" ] && jq -e '.ignition.version' "$MASTER_IGN_FILE" >/dev/null 2>&1; then
            log "Got master ignition from bootstrap MCS ($(wc -c < "$MASTER_IGN_FILE") bytes)"
            MASTER_IGN_READY=1
        else
            rm -f "$MASTER_IGN_FILE"
        fi
    fi
    [ -n "$LOCAL_IGN_FILE" ] && [ "$MASTER_IGN_READY" -eq 1 ] && break
    sleep 5
done

# Detect role from filename
case "$LOCAL_IGN_FILE" in
    *worker*) NODE_ROLE="worker" ;;
    *)        NODE_ROLE="master" ;;
esac

IGN_FILE="/tmp/final-${NODE_ROLE}.ign"
log "Detected node role: $NODE_ROLE"

# Extract ignition version from local file
IGN_VERSION=$(jq -r '.ignition.version' "$LOCAL_IGN_FILE")
if [ -z "$IGN_VERSION" ] || [ "$IGN_VERSION" = "null" ]; then
    log "ERROR: Could not extract ignition version from $LOCAL_IGN_FILE"
    exit 1
fi
log "Ignition version from local file: $IGN_VERSION"

# Resolve the correct hostname from /etc/assisted/hostnames/<mac>.
# The appliance's load-config-iso creates these files from agent-config.yaml.
# The assisted installer uses the runtime hostname (often wrong due to
# DHCP) instead of the one from agent-config.yaml. We fix it here.
CORRECT_HOSTNAME=""
for hfile in /etc/assisted/hostnames/*; do
    [ -f "$hfile" ] || continue
    mac=$(basename "$hfile")
    if ip -o link show | grep -qi "$mac"; then
        CORRECT_HOSTNAME=$(cat "$hfile")
        log "Matched MAC $mac -> hostname $CORRECT_HOSTNAME"
        break
    fi
done

if [ -n "$CORRECT_HOSTNAME" ]; then
    HOSTNAME_CONFIG=$(jq -n --arg hostname "$CORRECT_HOSTNAME" '{
        "path": "/etc/hostname",
        "mode": 420,
        "overwrite": true,
        "contents": {
            "source": ("data:," + $hostname)
        }
    }')
else
    log "WARNING: Could not resolve hostname from /etc/assisted/hostnames, using local ignition"
    HOSTNAME_CONFIG=$(jq '.storage.files[] | select(.path == "/etc/hostname")' "$LOCAL_IGN_FILE" 2>/dev/null)
    if [ -z "$HOSTNAME_CONFIG" ] || [ "$HOSTNAME_CONFIG" = "null" ]; then
        log "WARNING: No /etc/hostname in local ignition either"
        HOSTNAME_CONFIG=""
    fi
fi

if [ "$NODE_ROLE" = "master" ]; then
    # Masters: bootstrap MCS ignition already fetched above — use it directly.

    log "Converting master ignition to spec v3..."
    if podman run --privileged --rm -v /tmp:/tmp "$CONVERTER_IMAGE" -input "$MASTER_IGN_FILE" -output "${MASTER_IGN_FILE%.ign}-v3.ign" 2>&1 | tee -a "$LOG_FILE"; then
        mv "${MASTER_IGN_FILE%.ign}-v3.ign" "$MASTER_IGN_FILE"
        log "Successfully converted master ignition to v3"
    else
        log "ERROR: Failed to convert master ignition to v3"
        exit 1
    fi

    log "Building master ignition..."
    if [ -n "$HOSTNAME_CONFIG" ]; then
        jq --argjson hostname "$HOSTNAME_CONFIG" --arg version "$IGN_VERSION" '
            .ignition.version = $version |
            .storage.files = (
                [.storage.files[]? | select(.path != "/etc/hostname")] + [$hostname]
            )
        ' "$MASTER_IGN_FILE" > "$IGN_FILE"
    else
        jq --arg version "$IGN_VERSION" '.ignition.version = $version' \
            "$MASTER_IGN_FILE" > "$IGN_FILE"
    fi
else
    # Workers: fetch master MCS ignition from the bootstrap MCS early (reachable
    # via direct L2 while bootstrap is running) then merge with the local worker
    # ignition which has node-specific certs, kubeconfig and hostname.
    # FRR does not run on workers in the live ISO (OVS blocks can_start.sh), so
    # the production MCS at the API VIP is not reachable — bootstrap MCS is.
    log "Fetching master ignition from bootstrap MCS for worker merge..."
    while true; do
        if curl -k -s --connect-timeout 5 --max-time 30 -o "$MASTER_IGN_FILE" "https://192.168.110.2:22623/config/master" 2>/dev/null && \
           [ -s "$MASTER_IGN_FILE" ] && jq -e '.ignition.version' "$MASTER_IGN_FILE" >/dev/null 2>&1; then
            log "Got master ignition from bootstrap MCS ($(wc -c < "$MASTER_IGN_FILE") bytes)"
            break
        fi
        rm -f "$MASTER_IGN_FILE"
        log "Bootstrap MCS not ready, retrying in 5 s..."
        sleep 5
    done

    log "Converting master ignition to spec v3..."
    if podman run --privileged --rm -v /tmp:/tmp "$CONVERTER_IMAGE" -input "$MASTER_IGN_FILE" -output "${MASTER_IGN_FILE%.ign}-v3.ign" 2>&1 | tee -a "$LOG_FILE"; then
        mv "${MASTER_IGN_FILE%.ign}-v3.ign" "$MASTER_IGN_FILE"
        log "Successfully converted master ignition to v3"
    else
        log "ERROR: Failed to convert master ignition to v3"
        exit 1
    fi

    log "Building worker ignition: local base + master FRR/quadlet additions..."
    jq -s --arg version "$IGN_VERSION" '
        .[0] as $worker | .[1] as $master |
        ($worker.storage.files // [] | map(.path)) as $workerPaths |
        ($worker.systemd.units // [] | map(.name)) as $workerUnits |
        $worker |
        .ignition.version = $version |
        .storage.files = (.storage.files +
            [$master.storage.files[]? |
             select(.path as $p | $workerPaths | index($p) | not)]) |
        .systemd.units = ((.systemd.units // []) +
            [$master.systemd.units[]? |
             select(.name as $n | $workerUnits | index($n) | not)])
    ' "$LOCAL_IGN_FILE" "$MASTER_IGN_FILE" > "$IGN_FILE"
fi

if [ $? -ne 0 ] || ! jq -e '.ignition.version' "$IGN_FILE" >/dev/null 2>&1; then
    log "ERROR: Failed to build ignition"
    exit 1
fi

# Strip any merge config inherited from the MCS ignition.  The bootstrap MCS
# may include ignition.config.merge pointing to the production MCS (API VIP).
# On first RHCOS boot there is no SRv6 yet so that fetch would fail, causing
# the node to loop looking for ignition from the network.
jq 'del(.ignition.config.merge) | del(.ignition.config.replace)' \
    "$IGN_FILE" > "${IGN_FILE}.tmp" && mv "${IGN_FILE}.tmp" "$IGN_FILE"
log "Stripped merge/replace config from ignition"

log "Successfully built ignition ($(wc -c < "$IGN_FILE") bytes)"

# Inject registry.redhat.io mirror into the registries.conf so that
# toolbox / podman run can resolve images from the appliance registry
# after reboot (the cluster IDMS/ITMS only cover OCP release images).
MIRROR_CONF='
[[registry]]
  prefix = ""
  location = "registry.redhat.io"
  mirror-by-digest-only = false

  [[registry.mirror]]
    location = "registry.appliance.openshift.com:22625"
    insecure = true
'
MIRROR_CONF_B64=$(echo "$MIRROR_CONF" | base64 -w0)
MIRROR_PATH="/etc/containers/registries.conf.d/appliance-redhat-mirror.conf"
log "Injecting $MIRROR_PATH into ignition..."
jq --arg data "$MIRROR_CONF_B64" --arg path "$MIRROR_PATH" '
    .storage.files = (
        [.storage.files[]? | select(.path != $path)] + [{
            "path": $path,
            "mode": 420,
            "overwrite": true,
            "contents": {
                "source": ("data:text/plain;charset=utf-8;base64," + $data),
                "verification": {}
            }
        }]
    )
' "$IGN_FILE" > "${IGN_FILE}.tmp" && mv "${IGN_FILE}.tmp" "$IGN_FILE"
log "Injected registry mirror configuration"

# policy.json is managed by the MCO via the rendered machineconfig — do NOT
# inject it here or MCO will report a content mismatch and fail to converge.

# Detect whether this is the bootstrap/rendezvous node by checking if the
# assisted-service container is running locally.  The bootstrap node must stay
# up until waitForBootstrapComplete; the other nodes only need to wait until
# their own disk operations are done.
if sudo podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^service$'; then
    log "Bootstrap node detected — waiting for assisted-installer to exit (implies bootstrap complete)"
    while sudo podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^assisted-installer$'; do
        log "assisted-installer still running, retrying in 5 seconds..."
        sleep 5
    done
    log "assisted-installer exited, proceeding to write ignition"
else
    # Non-bootstrap node: wait for "Rebooting node" in the journal.
    # The local assisted-installer logs this just before calling shutdown -r,
    # after all disk operations (image write + ostree deployment) are complete.
    # Exclude ignition-hack lines to prevent matching our own log messages.
    log "Waiting for installer reboot signal..."
    while ! journalctl -b --no-pager -q 2>/dev/null | grep -v 'ignition-hack' | grep -q 'Rebooting node'; do
        sleep 5
    done
    log "Rebooting node seen, proceeding to fetch MCS ignition and write"
fi

# Validate ignition before writing
if ! jq -e '.ignition.version' "$IGN_FILE" >/dev/null 2>&1; then
    log "ERROR: Ignition file is invalid, aborting"
    systemctl unmask reboot.target
    exit 1
fi

# Write the MCS ignition to the boot partition.
# The installer mounts sda3 (labeled "boot") via nsenter --mount into the host
# namespace at /var/mnt, then freezes it with FIFREEZE before unmounting its own
# /mnt/boot handle.  Because /var/mnt still holds a reference to the superblock,
# the freeze persists.  Find the existing mount with findmnt instead of trying to
# create a new one (which would fail with EBUSY or succeed on a stale tmpdir).
log "Writing MCS ignition to boot partition..."
BOOT_MNT=$(findmnt -n -o TARGET /dev/disk/by-label/boot 2>/dev/null | head -1)
_OWN_BOOT_MOUNT=0
if [ -z "$BOOT_MNT" ]; then
    BOOT_MNT=$(mktemp -d)
    if mount /dev/disk/by-label/boot "$BOOT_MNT" 2>/dev/null; then
        _OWN_BOOT_MOUNT=1
    else
        rmdir "$BOOT_MNT"
        log "ERROR: Boot partition not found or mountable"
        systemctl unmask reboot.target
        exit 1
    fi
else
    log "Boot partition already mounted at $BOOT_MNT"
fi
fsfreeze --unfreeze "$BOOT_MNT" 2>/dev/null || true
# Use dd conv=fsync to force the ext4 journal to commit before returning.
# For workers especially, ostree holds sda3 open for a long time, so the
# dirty umount during shutdown would lose a plain cp+sync write.
dd if="$IGN_FILE" of="$BOOT_MNT/ignition/config.ign" conv=fsync 2>/dev/null
sync
log "Successfully wrote ignition to boot partition"

# Inject performance-profile kernel args into the installed system's BLS
# entries so that day-1 boots with hugepages and IOMMU before NTO exists.
# The args string is replaced at build time by hackagent.sh.
PERF_KARGS="@@PERF_KARGS@@"
if [ -n "$PERF_KARGS" ]; then
    log "Injecting kernel args into installed BLS entries: $PERF_KARGS"
    for entry in "$BOOT_MNT"/loader/entries/*.conf; do
        [ -f "$entry" ] || continue
        if ! grep -q "default_hugepagesz" "$entry"; then
            sed -i "s/^options /options ${PERF_KARGS} /" "$entry"
            log "Updated $(basename "$entry")"
        fi
    done
    sync
fi

if [ "$_OWN_BOOT_MOUNT" -eq 1 ]; then
    umount "$BOOT_MNT"
    rmdir "$BOOT_MNT"
fi

# Wait for "Rebooting node" before triggering the actual reboot.
# The local assisted-installer logs this just before calling shutdown -r,
# meaning it has already sent the "Rebooting" stage update to the
# assisted-service.  Rebooting before this point causes the service to
# mark the node as disconnected/error.
resize_root_for_growfs || { log "Partition resize failed — aborting reboot"; exit 1; }

log "Rebooting node seen — unmasking reboot.target and rebooting"
systemctl unmask reboot.target
systemctl reboot
HACKSCRIPT_EOF

# Derive kernel args from performance-profile.yaml at build time
PERF_PROFILE="${SCRIPTDIR}/../configimage/performance-profile.yaml"
PERF_KARGS=""
if [[ -f "${PERF_PROFILE}" ]] && command -v yq &>/dev/null; then
    default_sz=$(yq -r '.spec.hugepages.defaultHugepagesSize | values' "${PERF_PROFILE}")
    if [[ -n "${default_sz}" ]]; then
        PERF_KARGS+="default_hugepagesz=${default_sz} "
    fi
    while IFS=$'\t' read -r count size; do
        PERF_KARGS+="hugepagesz=${size} hugepages=${count} "
    done < <(yq -r '.spec.hugepages.pages[]? | [.count, .size] | @tsv' "${PERF_PROFILE}")
    while IFS= read -r arg; do
        PERF_KARGS+="${arg} "
    done < <(yq -r '.spec.additionalKernelArgs[]?' "${PERF_PROFILE}")
    PERF_KARGS="${PERF_KARGS% }"
fi
sed -i "s|@@PERF_KARGS@@|${PERF_KARGS}|" "$HACK_SCRIPT_FILE"

# Base64 encode the script
SCRIPT_B64=$(base64 -w0 < "$HACK_SCRIPT_FILE")

# Systemd unit file
SYSTEMD_UNIT='[Unit]
Description=Ignition Hack Script
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ignition-hack.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
'

# Merge into existing ignition
echo "Merging script and systemd unit into ignition..."
jq --arg script_b64 "$SCRIPT_B64" --arg unit "$SYSTEMD_UNIT" '
    .storage = (.storage // {}) |
    .storage.files = ([(.storage.files // [])[] | select(.path != "/usr/local/bin/ignition-hack.sh")] + [{
        "group": {},
        "overwrite": true,
        "path": "/usr/local/bin/ignition-hack.sh",
        "user": {
          "name": "root"
        },
        "mode": 365,
        "contents": {
            "source": ("data:text/plain;charset=utf-8;base64," + $script_b64),
            "verification": {}
        }
    }]) |
    .systemd = (.systemd // {}) |
    .systemd.units = ([(.systemd.units // [])[] | select(.name != "ignition-hack.service")] + [{
        "name": "ignition-hack.service",
        "enabled": true,
        "contents": $unit
    }])
' "$EXTRACTED_IGN" > "$MODIFIED_IGN"

echo "--- Generated merged ignition ---"

if [ "$OUTPUT_ISO" != "$ISO_PATH" ]; then
    echo "Copying ISO to: $OUTPUT_ISO"
    cp "$ISO_PATH" "$OUTPUT_ISO"
fi

echo "Removing any existing embedded ignition..."
sudo coreos-installer iso ignition remove "$OUTPUT_ISO" 2>/dev/null || true

echo "Embedding modified ignition into ISO..."
sudo coreos-installer iso ignition embed -i "$MODIFIED_IGN" "$OUTPUT_ISO"

echo "Done! Modified ISO: $OUTPUT_ISO"
