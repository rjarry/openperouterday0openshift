#!/bin/bash
# generate_appliance.sh - Build an OpenShift appliance ISO and embed
# OpenPERouter quadlets, configs, registry mirrors, DNS overrides,
# and the ignition hack agent into it.
#
# Usage: generate_appliance.sh <pull_secret_file> [ssh_key_file]
#
#   pull_secret_file  Path to the pull secret JSON file (required)
#   ssh_key_file      Path to an SSH public key file (optional)
#
# The script generates appliance-config.yaml from the .base template,
# injects the pull secret (and optionally the SSH key), then builds
# and patches the appliance ISO.
#
# Requires: coreos-installer, jq, yq, butane, podman

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APPLIANCE_IMAGE="${APPLIANCE_IMAGE:-quay.io/edge-infrastructure/openshift-appliance:latest}"

pull_secret_file="${1:-}"
ssh_key_file="${2:-}"

if [[ -z "${pull_secret_file}" || ! -f "${pull_secret_file}" ]]; then
    echo "ERROR: Pull secret file not found: ${pull_secret_file:-<not provided>}"
    echo "Usage: $0 <pull_secret_file> [ssh_key_file]"
    exit 1
fi

if [[ -n "${ssh_key_file}" && ! -f "${ssh_key_file}" ]]; then
    echo "ERROR: SSH key file not found: ${ssh_key_file}"
    exit 1
fi

# ============================================================
# Step 1: Generate appliance-config.yaml from base template
# ============================================================
echo "==> Generating appliance-config.yaml..."

base_config="${SCRIPTDIR}/appliance-config.yaml.base"
config="${SCRIPTDIR}/appliance-config.yaml"

if [[ ! -f "${base_config}" ]]; then
    echo "ERROR: Base config not found: ${base_config}"
    exit 1
fi

pull_secret="$(jq -c . "${pull_secret_file}")"

yq -y ".pullSecret = $(echo "${pull_secret}" | jq -R .)" "${base_config}" > "${config}"

if [[ -n "${ssh_key_file}" ]]; then
    ssh_key="$(cat "${ssh_key_file}")"
    yq -y ".sshKey = \"${ssh_key}\"" "${config}" > "${config}.tmp" && mv "${config}.tmp" "${config}"
    export SSH_PUB_KEY=${ssh_key}
fi

# ============================================================
# Step 2: Build the appliance live ISO
# ============================================================
echo "==> Building appliance live ISO..."

asset_dir="$(realpath "${SCRIPTDIR}")"

# Clean any previous build so the appliance tool doesn't skip
sudo podman run -it --rm --privileged --net=host \
    -v "${asset_dir}:/assets:Z" \
    "${APPLIANCE_IMAGE}" clean

sudo podman run -it --rm --privileged --net=host \
    -v "${asset_dir}:/assets:Z" \
    "${APPLIANCE_IMAGE}" build live-iso --log-level=debug

appliance_iso="${asset_dir}/appliance.iso"

if [[ ! -f "${appliance_iso}" ]]; then
    echo "ERROR: Appliance ISO not found after build: ${appliance_iso}"
    exit 1
fi

echo "==> Appliance ISO built: ${appliance_iso}"

# ============================================================
# Step 3: Patch the ISO with OpenPERouter content and hack agent
# ============================================================
# The appliance tool writes cache/*/cluster-resources into asset_dir,
# so it serves as both the config dir and the ocp_dir for patching.
"${SCRIPTDIR}/patch_appliance.sh" "${appliance_iso}" "${asset_dir}"
