#!/bin/bash
set -euo pipefail

# deploy.sh - Full deployment from the bastion (3 masters, no workers)
#
# Builds ISOs and boots all target servers via iDRAC.
# Idempotent — safe to run multiple times.
#
# Usage: deploy.sh <pull_secret> <idrac_host> [idrac_host...] [ssh_key]
#
#   pull_secret    Path to the pull secret JSON file
#   idrac_host     iDRAC hostname or IP (one per server)
#   ssh_key        Path to an SSH public key file (optional, must be last arg)
#
# Environment:
#   IDRAC_USER     iDRAC username (default: root)
#   IDRAC_PASS     iDRAC password (default: calvin)

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pull_secret="${1:-}"
shift || true

if [[ -z "${pull_secret}" || $# -eq 0 ]]; then
	echo "Usage: $0 <pull_secret> <idrac_host> [idrac_host...] [ssh_key]"
	exit 1
fi

if [[ ! -f "${pull_secret}" ]]; then
	echo "ERROR: Pull secret not found: ${pull_secret}"
	exit 1
fi

# Collect iDRAC hosts and optional ssh_key (last arg if it's a file)
idrac_hosts=()
ssh_key=""
for arg in "$@"; do
	if [[ -f "${arg}" ]] && [[ "${arg}" == *.pub ]]; then
		ssh_key="${arg}"
	else
		idrac_hosts+=("${arg}")
	fi
done

if [[ ${#idrac_hosts[@]} -eq 0 ]]; then
	echo "ERROR: At least one iDRAC host is required"
	exit 1
fi

BASTION=$(hostname -f)

# ============================================================
# Step 1: Build appliance ISO (skip if exists)
# ============================================================
appliance_iso="${SCRIPTDIR}/appliance/appliance.iso"

if [[ ! -f "${appliance_iso}" ]]; then
	echo "==> Building appliance ISO..."
	if [[ -n "${ssh_key}" ]]; then
		"${SCRIPTDIR}/appliance/generate_appliance.sh" "${pull_secret}" "${ssh_key}"
	else
		"${SCRIPTDIR}/appliance/generate_appliance.sh" "${pull_secret}"
	fi
fi

# ============================================================
# Step 2: Generate MachineConfig manifests
# ============================================================
config_image_dir="${SCRIPTDIR}/configimage/configimage"
extra_manifests_dir="${config_image_dir}/openshift"

rm -rf "${config_image_dir}/.openshift_install_state.json" \
	"${config_image_dir}/auth" \
	"${config_image_dir}/agentconfig.noarch.iso" \
	"${extra_manifests_dir}"

"${SCRIPTDIR}/configimage/generate_machineconfigs.sh" "${extra_manifests_dir}"

# ============================================================
# Step 3: Patch appliance ISO with MachineConfig + extras
# ============================================================
"${SCRIPTDIR}/appliance/patch_appliance.sh" "${appliance_iso}" \
	"${SCRIPTDIR}/appliance" "${extra_manifests_dir}"

# ============================================================
# Step 4: Build config-image ISO
# ============================================================
echo "==> Generating config-image ISO..."

if [[ -n "${ssh_key}" ]]; then
	"${SCRIPTDIR}/configimage/generate_config_image.sh" "${pull_secret}" "${config_image_dir}" "${ssh_key}"
else
	"${SCRIPTDIR}/configimage/generate_config_image.sh" "${pull_secret}" "${config_image_dir}"
fi

config_iso="${config_image_dir}/agentconfig.noarch.iso"

# ============================================================
# Step 5: Export ISOs via NFS
# ============================================================
NFS_DIR="/srv/nfs/iso"
echo "==> Exporting ISOs via NFS..."

mkdir -p "${NFS_DIR}"
ln -f "$(realpath "${appliance_iso}")" "${NFS_DIR}/appliance.iso"
ln -f "$(realpath "${config_iso}")" "${NFS_DIR}/config.iso"
chcon -t public_content_ro_t -l s0 "${NFS_DIR}"/*.iso

if ! grep -q "${NFS_DIR}" /etc/exports 2>/dev/null; then
	echo "${NFS_DIR} *(ro,no_root_squash)" >> /etc/exports
fi
exportfs -ra

# ============================================================
# Step 6: Boot all servers via iDRAC
# ============================================================
for idrac_host in "${idrac_hosts[@]}"; do
	echo "==> Booting ${idrac_host} from virtual media..."
	"${SCRIPTDIR}/../idrac-boot.sh" "${idrac_host}" \
		"${BASTION}:${NFS_DIR}/appliance.iso" \
		"${BASTION}:${NFS_DIR}/config.iso"
done

# ============================================================
# Done
# ============================================================
echo ""
echo "==> Deployment started (${#idrac_hosts[@]} servers)."
echo "  Monitor install progress:"
echo "    ssh core@<node-ip> 'sudo journalctl -u bootkube -f'"
echo "  Wait for bootstrap:"
openshift_install=$(find "${SCRIPTDIR}/appliance/cache" -name openshift-install -type f 2>/dev/null | head -1)
if [[ -n "${openshift_install}" ]]; then
	echo "    ${openshift_install} --dir=${config_image_dir} agent wait-for bootstrap-complete"
fi
