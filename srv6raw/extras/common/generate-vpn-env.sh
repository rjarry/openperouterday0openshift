#!/bin/bash
# generate-vpn-env.sh - Generate /etc/openperouter/vpn-setup.env at boot time.
#
# Reads cluster-wide defaults from vpn-setup.env.defaults, auto-detects
# SR-IOV VF names from sysfs, and writes the final env file.
#
# Usage: Executed by systemd service generate-vpn-env.service

set -euo pipefail

DEFAULTS_FILE="${DEFAULTS_FILE:-/etc/openperouter/vpn-setup.env.defaults}"
ENV_FILE="${ENV_FILE:-/etc/openperouter/vpn-setup.env}"

log() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Start with cluster-wide defaults
if [[ -f "$DEFAULTS_FILE" ]]; then
	log "Loading defaults from $DEFAULTS_FILE"
	cp "$DEFAULTS_FILE" "$ENV_FILE"
else
	log "No defaults file found at $DEFAULTS_FILE, starting empty"
	: > "$ENV_FILE"
fi

# Find the SR-IOV PF: look for a net device with sriov_numvfs > 0
PF_NAME=""
for numvfs_path in /sys/class/net/*/device/sriov_numvfs; do
	[[ -f "$numvfs_path" ]] || continue
	numvfs=$(cat "$numvfs_path" 2>/dev/null) || continue
	if [[ "$numvfs" -gt 0 ]]; then
		pf_dir=$(dirname "$(dirname "$numvfs_path")")
		PF_NAME=$(basename "$pf_dir")
		break
	fi
done

if [[ -z "$PF_NAME" ]]; then
	log "WARNING: no SR-IOV PF found, skipping NIC detection"
	chmod 644 "$ENV_FILE"
	exit 0
fi

log "Detected SR-IOV PF: $PF_NAME"

# Enumerate VFs and map by index:
#   VF0 = UNDERLAY_NIC
#   VF1 = TRUNK_NIC
#   VF2 = HOST_VF
pf_device="/sys/class/net/$PF_NAME/device"
UNDERLAY_NIC=""
TRUNK_NIC=""
HOST_VF=""

for virtfn in "$pf_device"/virtfn*; do
	[[ -d "$virtfn" ]] || continue
	idx=$(basename "$virtfn" | sed 's/virtfn//')
	vf_net_dir="$virtfn/net"
	[[ -d "$vf_net_dir" ]] || continue
	vf_name=$(ls "$vf_net_dir" | head -1)
	[[ -n "$vf_name" ]] || continue
	case "$idx" in
	0) UNDERLAY_NIC="$vf_name" ;;
	1) TRUNK_NIC="$vf_name" ;;
	2) HOST_VF="$vf_name" ;;
	esac
done

# Append detected NIC names to the env file
{
	echo ""
	echo "# Auto-detected SR-IOV VF names (PF: $PF_NAME)"
	[[ -n "$UNDERLAY_NIC" ]] && echo "UNDERLAY_NIC=$UNDERLAY_NIC"
	[[ -n "$TRUNK_NIC" ]] && echo "TRUNK_NIC=$TRUNK_NIC"
	[[ -n "$HOST_VF" ]] && echo "HOST_VF=$HOST_VF"
} >> "$ENV_FILE"

chmod 644 "$ENV_FILE"

log "Generated $ENV_FILE (UNDERLAY_NIC=$UNDERLAY_NIC, TRUNK_NIC=$TRUNK_NIC, HOST_VF=$HOST_VF)"
