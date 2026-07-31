#!/bin/bash
set -euo pipefail

# setup-underlay.sh - Create grout ports from perouter-bind state
#
# Iterates /run/perouter-bind/* (populated by perouter-bind.sh via
# nmstate dispatch) and creates grout ports named underlay0, underlay1, ...
# Reads PF MTU from sysfs and mirrors it in the grout port.
#
# Address derivation and variable saving are handled by nmstate dispatch
# scripts on the host VF.
#
# Usage: Executed by systemd service setup-underlay.service (After=grout)

die() { echo "error: $*" >&2; exit 1; }

grcli() {
	echo "+ grcli $*" >&2
	podman exec grout grcli "$@"
}

STATE_DIR=/run/perouter-bind

echo "Creating grout ports from $STATE_DIR"

n=0
for state in "$STATE_DIR"/*; do
	[ -f "$state" ] || continue

	name=$(basename "$state")
	read -r type driver pci_addr < "$state"

	# Derive PF MTU from the VF's PCI parent.
	pf_mtu=1500
	for m in /sys/bus/pci/devices/$pci_addr/physfn/net/*/mtu; do
		if [ -f "$m" ]; then
			read -r pf_mtu < "$m" || continue
			break
		fi
	done

	port="underlay$n"
	echo "  $port: pci=$pci_addr type=$type driver=$driver pf_mtu=$pf_mtu"
	grcli interface add port "$port" devargs "$pci_addr" down mtu "$pf_mtu"

	n=$((n + 1))
done

[ $n -gt 0 ] || die "No devices found in $STATE_DIR"
echo "$n grout port(s) created"
