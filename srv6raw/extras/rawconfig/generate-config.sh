#!/bin/bash
set -euo pipefail

# generate-config.sh - Generate OpenPERouter FRR configuration (flat / ISIS routing)
#
# This script:
# 1. Loads variables from setup-underlay.sh
# 2. Determines node role (EVPN route reflector vs client)
# 3. Selects the appropriate template (RR or client)
# 4. Renders configuration via envsubst
#
# Usage: Executed by systemd service generate-config.service
#
# Exit codes:
#   0   - Success
#   1   - General error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities
if [[ ! -f "$SCRIPT_DIR/openperouter-common.sh" ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: openperouter-common.sh not found" >&2
    exit 1
fi

source "$SCRIPT_DIR/openperouter-common.sh"

# Load environment configuration file
ENV_FILE="${ENV_FILE:-/etc/openperouter/vpn-setup.env}"
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
fi

# Load environment variables with defaults
BGP_AS="${BGP_AS:-65500}"
RR_NODE_IDX="${RR_NODE_IDX:-2}"
TOR_LOOPBACK="${TOR_LOOPBACK:-fc00:0:20::1}"
VRF_NAME="${VRF_NAME:-red}"
L2_VNI="${L2_VNI:-210}"
L2_GATEWAY_IP="${L2_GATEWAY_IP:-192.168.110.1/24}"
L2_GATEWAY_IP_V6="${L2_GATEWAY_IP_V6:-fd00:110::1/64}"

UNDERLAY_NIC="${UNDERLAY_NIC:-eno12399v0}"

# Paths
VARS_FILE="${VARS_FILE:-/var/lib/openperouter/vpn-setup.vars}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/etc/openperouter/templates}"
CONFIG_OUTPUT="${CONFIG_OUTPUT:-/var/lib/openperouter/configs/openpe_evpn.yaml}"

# Start main execution
log "Starting configuration generation (ISIS + SRv6 mode)"

#
# STEP 1: Load variables from setup-underlay.sh
#
log_step "Loading variables from underlay setup"

if [[ ! -f "$VARS_FILE" ]]; then
    error "Variables file not found: $VARS_FILE"
    error "setup-underlay.service must run first"
    exit_error "Missing variables file"
fi

source "$VARS_FILE"

log "Loaded variables from $VARS_FILE"
log "  NODE_NAME=$NODE_NAME, LAST_OCTET=$LAST_OCTET"
log "  ROUTER_ID=$ROUTER_ID, LOOPBACK_V6=$LOOPBACK_V6"
log "  SRV6_SOURCE=$SRV6_SOURCE, SRV6_PREFIX=$SRV6_PREFIX, SRV6_NODE_ID=$SRV6_NODE_ID"
log "  ISIS_NET=$ISIS_NET"

#
# STEP 2: Determine role and select template
#
log_step "Determining node role"

if [[ "$LAST_OCTET" == "$RR_NODE_IDX" ]]; then
    log "This node is the EVPN/VPN Route Reflector (idx=$LAST_OCTET)"
    CONFIG_TEMPLATE="${TEMPLATE_DIR}/openpe_evpn.yaml_rr.template"

    EVPN_LISTEN_RANGE="${EVPN_LISTEN_RANGE:-fc00::/16}"
    export EVPN_LISTEN_RANGE

    log "  EVPN listen range: $EVPN_LISTEN_RANGE"
else
    log "This node is an EVPN/VPN client (idx=$LAST_OCTET, RR=$RR_NODE_IDX)"
    CONFIG_TEMPLATE="${TEMPLATE_DIR}/openpe_evpn.yaml.template"

    RR_LOOPBACK="fc00:0:${RR_NODE_IDX}::1"
    export RR_LOOPBACK

    log "  RR loopback: $RR_LOOPBACK"
fi

export TOR_LOOPBACK
log "  TOR: $TOR_LOOPBACK"

#
# STEP 3: Verify template exists
#
log_step "Checking configuration template"

if [[ ! -f "$CONFIG_TEMPLATE" ]]; then
    error "Configuration template not found: $CONFIG_TEMPLATE"
    exit_error "Missing configuration template"
fi

log "Using template: $CONFIG_TEMPLATE"

#
# STEP 4: Render configuration from template using envsubst
#
log_step "Rendering configuration from template"

mkdir -p "$(dirname "$CONFIG_OUTPUT")"

# Export all variables for envsubst
export NODE_NAME UNDERLAY_NIC BGP_AS ROUTER_ID LOOPBACK_V6 UNDERLAY_V6
export SRV6_SOURCE SRV6_PREFIX SRV6_NODE_ID ISIS_NET
export VRF_NAME HOST_SUBNET HOST_SUBNET_V6 L2_GATEWAY_IP L2_GATEWAY_IP_V6 L2_VNI

envsubst < "$CONFIG_TEMPLATE" > "$CONFIG_OUTPUT" || {
    error "Failed to render configuration template"
    exit_error "Template rendering failed"
}

log "Configuration written to: $CONFIG_OUTPUT"

#
# STEP 5: Validate generated configuration
#
log_step "Validating generated configuration"

for section in "rawfrrconfigs:" "router isis PE" "segment-routing" "router bgp"; do
    if ! grep -q "$section" "$CONFIG_OUTPUT"; then
        error "Generated config is missing required section: $section"
        exit_error "Invalid generated configuration"
    fi
done

if ! grep -q "${ROUTER_ID}" "$CONFIG_OUTPUT"; then
    error "Generated config is missing Router ID"
    exit_error "Invalid Router ID in configuration"
fi

log "Configuration validated successfully"

# Show preview
log "Configuration preview (first 30 lines):"
head -30 "$CONFIG_OUTPUT" | while IFS= read -r line; do log "  $line"; done
log "  ..."

exit_success "Configuration generation completed successfully"
