#!/bin/bash

cat <<EOF >/etc/motd
The primary service is agent.service. To watch its status, run:

  journalctl -u agent.service

To view the agent log, run:

  journalctl TAG=agent
EOF
echo "Waiting for network to determine if this is the rendezvous host." > /etc/motd.d/60-rendezvous-host

HOSTNAMES_PATH=/etc/assisted/hostnames
MAX_WAIT=120
WAIT_COUNT=0

echo "Waiting for ${HOSTNAMES_PATH} to exist..." 1>&2
while [ ! -d "${HOSTNAMES_PATH}" ]; do
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo "ERROR: ${HOSTNAMES_PATH} did not appear after ${MAX_WAIT} seconds" 1>&2
        exit 1
    fi
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

echo "Found ${HOSTNAMES_PATH}" 1>&2

WAIT_COUNT=0
while [ -z "$(ls -A ${HOSTNAMES_PATH} 2>/dev/null)" ]; do
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo "ERROR: No files found in ${HOSTNAMES_PATH} after ${MAX_WAIT} seconds" 1>&2
        exit 1
    fi
    echo "Waiting for files in ${HOSTNAMES_PATH}..." 1>&2
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

FILES=$(ls $HOSTNAMES_PATH)
echo "Found hostname files: ${FILES}" 1>&2

for filename in ${FILES}; do
    MATCHED_MAC_ADDRESS_WITH_HOST=$(ip address | grep "${filename}")
    if [ "$MATCHED_MAC_ADDRESS_WITH_HOST" != "" ]; then
        HOSTNAME="$(cat "${HOSTNAMES_PATH}/${filename}")"
        echo "Host has matching MAC address: ${filename}" 1>&2
        echo "Setting hostname to ${HOSTNAME}" 1>&2
        hostnamectl set-hostname "${HOSTNAME}"
        exit 0
    else
        echo "MAC address, ${filename}, does not exist on this host" 1>&2
    fi
done

echo "WARNING: No matching MAC address found" 1>&2
exit 0
