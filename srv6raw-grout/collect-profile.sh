#!/bin/bash
set -euo pipefail

# collect-profile.sh - Collect install timing and profiling data from all nodes
#
# Usage:
#   collect-profile.sh live [output-dir]   Continuously collect from live ISO nodes
#   collect-profile.sh post [output-dir]   Collect post-install journals and timing
#
# Nodes are reached via their east-west IPs (192.168.110.{2,3,4}).
# SSH as core with sudo.

NODES=(
	"master-0:192.168.110.2"
	"master-1:192.168.110.3"
	"master-2:192.168.110.4"
)

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
SSH_USER=core

usage() {
	echo "Usage: $0 {live|post} [output-dir]"
	echo ""
	echo "  live   Continuously poll nodes during live ISO phase (Ctrl-C to stop)"
	echo "  post   Collect journals and timing from installed RHCOS nodes"
	exit 1
}

node_ssh() {
	local ip="$1"
	shift
	ssh $SSH_OPTS "${SSH_USER}@${ip}" "$@"
}

ts() {
	date '+%Y-%m-%d %H:%M:%S'
}

# ============================================================
# live: continuous collection during the live ISO phase
# ============================================================
do_live() {
	local outdir="$1"
	echo "$(ts) Collecting live ISO data to ${outdir}/"
	echo "$(ts) Press Ctrl-C to stop"

	for entry in "${NODES[@]}"; do
		local name="${entry%%:*}"
		mkdir -p "${outdir}/${name}/live"
	done

	local iteration=0
	while true; do
		iteration=$((iteration + 1))
		for entry in "${NODES[@]}"; do
			local name="${entry%%:*}"
			local ip="${entry#*:}"
			local ndir="${outdir}/${name}/live"

			if ! node_ssh "$ip" true 2>/dev/null; then
				echo "$(ts) [${name}] unreachable"
				continue
			fi

			echo "$(ts) [${name}] collecting snapshot #${iteration}"

			# Journal since boot (incremental: full dump each time, diff later)
			node_ssh "$ip" "sudo journalctl -b --no-pager -o short-precise 2>/dev/null" \
				> "${ndir}/journal-${iteration}.log" 2>/dev/null || true

			# hackagent log
			node_ssh "$ip" "cat /tmp/ignition-hack.log 2>/dev/null" \
				> "${ndir}/hackagent-${iteration}.log" 2>/dev/null || true

			# iostat snapshot
			node_ssh "$ip" "iostat -x 1 2 2>/dev/null || true" \
				> "${ndir}/iostat-${iteration}.log" 2>/dev/null || true

			# Disk activity (check if coreos-installer or dd is running)
			node_ssh "$ip" "ps auxww 2>/dev/null | grep -E 'coreos-installer|dd |assisted-installer' | grep -v grep" \
				> "${ndir}/procs-${iteration}.log" 2>/dev/null || true

			# podman containers
			node_ssh "$ip" "sudo podman ps --format '{{.Names}} {{.Status}}' 2>/dev/null" \
				> "${ndir}/containers-${iteration}.log" 2>/dev/null || true
		done

		sleep 30
	done
}

# ============================================================
# post: collect from installed RHCOS nodes
# ============================================================
do_post() {
	local outdir="$1"
	echo "$(ts) Collecting post-install data to ${outdir}/"

	for entry in "${NODES[@]}"; do
		local name="${entry%%:*}"
		local ip="${entry#*:}"
		local ndir="${outdir}/${name}/post"
		mkdir -p "${ndir}"

		echo ""
		echo "========================================"
		echo "$(ts) [${name}] (${ip})"
		echo "========================================"

		if ! node_ssh "$ip" true 2>/dev/null; then
			echo "$(ts) [${name}] unreachable, skipping"
			continue
		fi

		# List available boots
		echo "$(ts) [${name}] listing boots..."
		node_ssh "$ip" "sudo journalctl --list-boots 2>/dev/null" \
			> "${ndir}/boots.txt" 2>/dev/null || true
		cat "${ndir}/boots.txt"

		# Collect journal for each boot
		local boot_ids
		boot_ids=$(awk '{print $1}' "${ndir}/boots.txt" 2>/dev/null || true)
		for boot_id in $boot_ids; do
			echo "$(ts) [${name}] collecting journal boot ${boot_id}..."
			node_ssh "$ip" "sudo journalctl -b ${boot_id} --no-pager -o short-precise 2>/dev/null" \
				> "${ndir}/journal-boot${boot_id}.log" 2>/dev/null || true
		done

		# dmesg (disk/SATA info)
		echo "$(ts) [${name}] collecting dmesg..."
		node_ssh "$ip" "sudo dmesg 2>/dev/null" \
			> "${ndir}/dmesg.log" 2>/dev/null || true

		# Disk info
		echo "$(ts) [${name}] collecting disk info..."
		node_ssh "$ip" "lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,ROTA 2>/dev/null; echo '---'; sudo hdparm -I /dev/sda 2>/dev/null | head -30 || true" \
			> "${ndir}/disk-info.txt" 2>/dev/null || true

		# iostat
		node_ssh "$ip" "iostat -x 1 3 2>/dev/null || true" \
			> "${ndir}/iostat.log" 2>/dev/null || true

		# hackagent log (may still be on /tmp if node hasn't been rebooted
		# from live ISO, or gone after RHCOS install)
		node_ssh "$ip" "cat /tmp/ignition-hack.log 2>/dev/null || echo 'not found'" \
			> "${ndir}/hackagent.log" 2>/dev/null || true

		# assisted-installer container logs (if still available)
		node_ssh "$ip" "sudo podman logs assisted-installer 2>/dev/null || echo 'not found'" \
			> "${ndir}/assisted-installer.log" 2>/dev/null || true

		# Extract timeline from journals
		echo "$(ts) [${name}] extracting timeline..."
		extract_timeline "${ndir}" "${name}"
	done

	echo ""
	echo "$(ts) Collection complete: ${outdir}/"
	echo ""
	echo "Per-node timelines:"
	for entry in "${NODES[@]}"; do
		local name="${entry%%:*}"
		local tl="${outdir}/${name}/post/timeline.txt"
		if [ -f "$tl" ]; then
			echo ""
			echo "=== ${name} ==="
			cat "$tl"
		fi
	done
}

extract_timeline() {
	local ndir="$1"
	local name="$2"
	local tl="${ndir}/timeline.txt"

	{
		echo "# Timeline for ${name}"
		echo "# Extracted $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo ""

		for journal in "${ndir}"/journal-boot*.log; do
			[ -f "$journal" ] || continue
			local boot
			boot=$(basename "$journal" .log | sed 's/journal-//')
			echo "--- ${boot} ---"

			grep -iE \
				'(Starting|Reached|ignition|coreos-installer|assisted-installer|Rebooting node|Writing image|image written|bootstrap|bootkube|machineconfig|kubelet|api-server|etcd|ignition-hack|reboot.target|configure-ovs|setup-network|setup-underlay|perouter|grout)' \
				"$journal" 2>/dev/null \
			| grep -v 'audit\|COMMAND=' \
			| head -200 \
			|| echo "  (no matching entries)"

			echo ""
		done

		# SATA/disk performance from dmesg
		if [ -f "${ndir}/dmesg.log" ]; then
			echo "--- disk info from dmesg ---"
			grep -iE '(ata|sata|sd[a-z]|link up|SATA link|transfer mode)' \
				"${ndir}/dmesg.log" 2>/dev/null \
			| head -20 \
			|| echo "  (no disk info in dmesg)"
			echo ""
		fi
	} > "$tl"
}

# ============================================================
# main
# ============================================================
if [ $# -lt 1 ]; then
	usage
fi

cmd="$1"
shift
outdir="${1:-/tmp/install-profile-$(date '+%Y%m%d-%H%M%S')}"

case "$cmd" in
	live)
		mkdir -p "$outdir"
		do_live "$outdir"
		;;
	post)
		mkdir -p "$outdir"
		do_post "$outdir"
		;;
	*)
		usage
		;;
esac
