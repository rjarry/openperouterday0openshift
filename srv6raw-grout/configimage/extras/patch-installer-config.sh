#!/bin/bash
# Patch assisted-service.env with settings required by openperouter.
# Runs before assisted-service-pod.service.
#
# - ENABLE_VIRTUAL_INTERFACES=true: tells assisted-service to include virtual
#   interfaces (bridges, etc.) in its inventory, which is required for the
#   bridge IP to pass the belongs-to-machine-cidr validation.
#
# - DISABLED_HOST_VALIDATIONS=belongs-to-majority-group: the agent's
#   connectivity checker (assisted-installer-agent/src/connectivity_check/util.go)
#   only uses physical, bonding, or VLAN interfaces for outgoing L2 checks.
#   Bridge interfaces are explicitly excluded. When the machine network IP
#   lives on br0, arping is never performed on that subnet, so the
#   "belongs-to-majority-group" validation always fails.
#   ENABLE_VIRTUAL_INTERFACES only affects inventory reporting on the
#   assisted-service side — it has no effect on the agent-side connectivity
#   checker. Until the agent is patched to support bridge interfaces, we
#   must disable this validation.
#
# The env file is initially created by the appliance ignition, then
# overwritten by load-config-iso.sh when the config-image ISO is mounted.
# We wait for load-config-iso to finish (indicated by SERVICE_IMAGE being
# set in the file) before injecting, to avoid being overwritten.

ENV_FILE="/usr/local/share/assisted-service/assisted-service.env"

echo "Waiting for load-config-iso to finish..."
for i in $(seq 1 60); do
	# Find the active load-config-iso instance and check if it completed
	unit=$(systemctl list-units 'load-config-iso@*' --no-legend --no-pager 2>/dev/null | awk '{print $1}' | head -1)
	if [ -n "$unit" ] && systemctl is-active --quiet "$unit" 2>/dev/null; then
		echo "load-config-iso ($unit) has completed."
		break
	fi
	sleep 5
done

if [ ! -f "$ENV_FILE" ]; then
	echo "ERROR: $ENV_FILE does not exist after waiting. Failing."
	exit 1
fi

if grep -q "^ENABLE_VIRTUAL_INTERFACES=" "$ENV_FILE"; then
	echo "ENABLE_VIRTUAL_INTERFACES already set. Skipping."
else
	echo "Injecting ENABLE_VIRTUAL_INTERFACES=true..."
	if echo "ENABLE_VIRTUAL_INTERFACES=true" >> "$ENV_FILE"; then
		echo "SUCCESS: ENABLE_VIRTUAL_INTERFACES injection complete."
	else
		echo "ERROR: Failed to write ENABLE_VIRTUAL_INTERFACES to $ENV_FILE."
		exit 1
	fi
fi

if grep -q "^DISABLED_HOST_VALIDATIONS=" "$ENV_FILE"; then
	echo "DISABLED_HOST_VALIDATIONS already set. Skipping."
else
	echo "Injecting DISABLED_HOST_VALIDATIONS=belongs-to-majority-group..."
	if echo "DISABLED_HOST_VALIDATIONS=belongs-to-majority-group" >> "$ENV_FILE"; then
		echo "SUCCESS: DISABLED_HOST_VALIDATIONS injection complete."
	else
		echo "ERROR: Failed to write DISABLED_HOST_VALIDATIONS to $ENV_FILE."
		exit 1
	fi
fi

if grep -q "^HOST_STAGE_WRITING_IMAGE_TO_DISK_TIMEOUT=" "$ENV_FILE"; then
	echo "HOST_STAGE_WRITING_IMAGE_TO_DISK_TIMEOUT already set. Skipping."
else
	echo "Injecting HOST_STAGE_WRITING_IMAGE_TO_DISK_TIMEOUT=120m..."
	if echo "HOST_STAGE_WRITING_IMAGE_TO_DISK_TIMEOUT=120m" >> "$ENV_FILE"; then
		echo "SUCCESS: HOST_STAGE_WRITING_IMAGE_TO_DISK_TIMEOUT injection complete."
	else
		echo "ERROR: Failed to write HOST_STAGE_WRITING_IMAGE_TO_DISK_TIMEOUT to $ENV_FILE."
		exit 1
	fi
fi

exit 0
