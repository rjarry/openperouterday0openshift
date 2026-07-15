#!/bin/bash
set -euo pipefail

# apply-manifests.sh - Apply DaemonSet manifests after kubelet is ready
#
# Waits for the API server to become available, creates the perouter
# namespace, substitutes configurable resource values in the manifest
# templates, and applies them.

MANIFEST_DIR="${MANIFEST_DIR:-/var/lib/openperouter/manifests}"
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig}"
export KUBECONFIG

source /etc/openperouter/grout.env

# Write system CPU list for the reservation pod to use as control CPUs.
grep Cpus_allowed_list /proc/1/status | cut -f2 > /etc/openperouter/system-cpus

echo "apply-manifests: waiting for API server..."
until oc get ns >/dev/null 2>&1; do
	sleep 5
done
echo "apply-manifests: API server is ready"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

for f in "$MANIFEST_DIR"/*.yaml; do
	sed \
		-e "s/__GROUT_CPUS__/$GROUT_CPUS/g" \
		-e "s/__GROUT_HUGEPAGES_1G__/$GROUT_HUGEPAGES_1G/g" \
		"$f" > "$TMPDIR/$(basename "$f")"
done

NODE_NAME=$(hostname)

echo "apply-manifests: applying manifests from $MANIFEST_DIR"
echo "  NODE_NAME=$NODE_NAME"
echo "  GROUT_CPUS=$GROUT_CPUS"
echo "  GROUT_HUGEPAGES_1G=$GROUT_HUGEPAGES_1G"

oc apply -f "$TMPDIR/namespace.yaml"
oc adm policy add-scc-to-user privileged -z default -n openperouter-system
oc apply -f "$TMPDIR/"

oc label node "$NODE_NAME" openperouter.io/role=router --overwrite

echo "apply-manifests: done"
