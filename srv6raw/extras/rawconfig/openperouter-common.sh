#!/bin/bash

# openperouter-common.sh - Convenience functions for working with the FRR container
# Source this file: source openperouter-common.sh
#
# These functions are meant to be run on the node where podman runs
# the frr container (e.g. inside a kind node).

# Logging functions
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log_step() {
    local step="$1"
    log "=== Step: $step ==="
}

exit_success() {
    log "${1:-Operation completed successfully}"
    exit 0
}

exit_error() {
    local msg="$1"
    error "$msg"
    exit 1
}

exit_timeout() {
    error "Operation timed out"
    exit 124
}

_FRR_PID_CACHE=""

# frr_netns_pid returns the PID of the frr container, which shares
# the routerpod network namespace. Caches the result and revalidates
# only when the cached PID is gone.
frr_netns_pid() {
    if [[ -n "$_FRR_PID_CACHE" ]] && [[ -d "/proc/$_FRR_PID_CACHE" ]]; then
        echo "$_FRR_PID_CACHE"
        return 0
    fi
    _FRR_PID_CACHE=$(podman inspect frr --format '{{.State.Pid}}' 2>/dev/null)
    if [[ -z "$_FRR_PID_CACHE" || "$_FRR_PID_CACHE" == "0" ]]; then
        _FRR_PID_CACHE=""
        return 1
    fi
    echo "$_FRR_PID_CACHE"
}

# inns runs a command in the frr container's network namespace.
# Usage: inns ip addr show
#        inns ping 10.0.0.1
inns() {
    local pid
    pid=$(frr_netns_pid)
    if [[ -z "$pid" || "$pid" == "0" ]]; then
        echo "Error: frr container is not running" >&2
        return 1
    fi
    nsenter -t "$pid" -n -m "$@"
}

# isfrr_ready checks that the frr container is running and bgpd is active.
# Returns 0 if ready, 1 otherwise.
isfrr_ready() {
    local pid
    pid=$(frr_netns_pid)
    if [[ -z "$pid" || "$pid" == "0" ]]; then
        echo "frr container is not running" >&2
        return 1
    fi

    local daemons
    daemons=$(podman exec frr vtysh -c "show daemons" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "vtysh is not responding" >&2
        return 1
    fi

    if echo "$daemons" | grep -q "bgpd" && echo "$daemons" | grep -q "isisd"; then
        echo "frr is ready (bgpd + isisd running)"
        return 0
    else
        echo "frr is running but bgpd/isisd not both active" >&2
        return 1
    fi
}
