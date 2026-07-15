#!/usr/bin/env bash
# Wait for configure-ovs.sh AND the subsequent NM OVS migration to finish
# before allowing the controller to start.
#
# On first boot (no OVS), ovs-configuration.service won't be present,
# so we skip the wait. On subsequent boots, we wait for:
#   1. The sentinel file that configure-ovs.sh creates on exit
#   2. The ovs-if-phys0 NM connection to become active on ${HOST_VF}
#      (NM processes the OVS migration asynchronously after the script exits,
#       so the sentinel alone is not enough)

set -euo pipefail

SENTINEL="/run/configure-ovs-boot-done"
OVS_CONNECTION="ovs-if-phys0"
HOST_VF="${HOST_VF:-eno12399v2}"
MAX_WAIT=300

if ! systemctl list-unit-files ovs-configuration.service &>/dev/null; then
  echo "ovs-configuration.service not found, skipping wait (first boot)"
  exit 0
fi

echo "Waiting for configure-ovs.sh to complete..."
for (( i=1; i<=MAX_WAIT; i++ )); do
  if [ -f "${SENTINEL}" ]; then
    echo "configure-ovs.sh completed (sentinel found)."
    break
  fi
  sleep 1
done

if [ ! -f "${SENTINEL}" ]; then
  echo "ERROR: ${SENTINEL} not found after ${MAX_WAIT}s" >&2
  exit 1
fi

echo "Waiting for NM to finish OVS migration (${OVS_CONNECTION} active on ${HOST_VF} or br-ex)..."
for (( i=1; i<=60; i++ )); do
  ACTIVE=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null || true)
  if echo "$ACTIVE" | grep -q "^${OVS_CONNECTION}:${HOST_VF}$" ||
     echo "$ACTIVE" | grep -q "^br-ex:br-ex$"; then
    echo "OVS migration complete, proceeding."
    exit 0
  fi
  sleep 1
done

echo "ERROR: neither ${OVS_CONNECTION} on ${HOST_VF} nor br-ex active after 60s" >&2
exit 1
