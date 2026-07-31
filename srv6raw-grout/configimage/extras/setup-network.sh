#!/bin/bash
set -euo pipefail

# setup-network.sh - Network infrastructure setup for SRv6 + L2 EVPN
#
# This script creates the network infrastructure (VRF, L2 VXLAN, bridge)
# via grout. L3VPN is handled by SRv6 (no L3VNI VXLAN needed).
# L2VPN still uses VXLAN overlay.
#
# Usage: Executed by setup-network.service after setup-underlay.service

die() { echo "error: $*" >&2; exit 1; }

# Load variables
source /etc/openperouter/openperouter.env
source /var/lib/openperouter/vpn-setup.vars

[ -n "$VTEP_IP" ] || die "VTEP_IP not set -- run setup-underlay.service first"

grcli() {
	echo "+ grcli $*" >&2
	podman exec grout grcli "$@"
}

L2_BRIDGE="br-pe-${L2_VNI}"
L2_VXLAN="vni${L2_VNI}"

echo "Setting up network infrastructure via grout"

# Assign VTEP address to underlay port to allow creation of the VXLAN interface
grcli address add ${VTEP_IP}/32 iface underlay0

# Create VRF, bridge, VXLAN (VLAN bridge port is added later by
# bridge-refresher after zebra has learned the VNI -- FRR #21190).
grcli interface add vrf $VRF_NAME
grcli interface add bridge $L2_BRIDGE vrf $VRF_NAME
grcli interface add vxlan $L2_VXLAN vni $L2_VNI local $VTEP_IP encap_vrf main domain $L2_BRIDGE

# Assign gateway IPs on bridge
grcli address add $L2_GATEWAY_IP iface $L2_BRIDGE
if [ -n "${L2_GATEWAY_IP_V6}" ]; then
	grcli address add $L2_GATEWAY_IP_V6 iface $L2_BRIDGE
fi

# Force GARP to be sent.
grcli interface set port underlay0 up
