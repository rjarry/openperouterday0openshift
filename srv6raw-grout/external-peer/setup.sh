#!/bin/bash
set -euo pipefail

# setup.sh - Configure the bastion as an SRv6 L3VPN gateway, DNS and NTP server
#
# Idempotent — safe to run multiple times.
#
# Host: dell-r450-nfv2023-04.lab.eng.brq2.redhat.com
# Private NIC: eno12399np0 (connected to switch et-0/0/6)
# Public NIC:  eno8303 (10.37.146.46/23, internet access)
#
# Architecture:
#   perouter netns:  FRR + ISIS + SRv6 on eno12399np0, VRF red with veth-frr
#   default netns:   veth-host (gateway), DNS/NTP on loopback, NAT via eno8303
#
# SRv6 decap → VRF red → veth → default netns → DNS/NTP or NAT → internet
# No cross-VRF NAT needed.
#
# Network setup uses ip commands (ephemeral). Re-run after reboot.

PRIVATE_NIC="eno12399np0"
PUBLIC_NIC="eno8303"
PRIVATE_NET="192.168.110.0/24"
PRIVATE_NET_V6="fd00:110::/64"
FRR_IMAGE="quay.io/frrouting/frr:10.6.1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DNS_LISTEN_IP="10.100.0.1"
DNS_LISTEN_IP6="fd00:100::1"

# Cluster
CLUSTER_DOMAIN="sno-lab.example.com"

CONTAINER_NAME="frr"
NETNS="perouter"

# --- Tell NetworkManager to leave the private NIC alone ---

cat > /etc/NetworkManager/conf.d/99-unmanaged-private.conf <<NM
[keyfile]
unmanaged-devices=interface-name:${PRIVATE_NIC};interface-name:veth-*
NM
nmcli general reload

# --- Cleanup stale services ---

systemctl disable dnsmasq --now 2>/dev/null || true
for net in $(virsh net-list --name 2>/dev/null); do
	virsh net-destroy "$net" 2>/dev/null || true
	virsh net-undefine "$net" 2>/dev/null || true
done
systemctl disable libvirtd --now 2>/dev/null || true
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

# --- IP forwarding and SRv6 sysctls ---

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0

# --- Create perouter network namespace ---

ip netns add $NETNS 2>/dev/null || true
ip netns exec $NETNS ip link set lo up
ip netns exec $NETNS sysctl -qw net.ipv4.ip_forward=1
ip netns exec $NETNS sysctl -qw net.ipv6.conf.all.forwarding=1
ip netns exec $NETNS sysctl -qw net.ipv6.conf.all.seg6_enabled=1
ip netns exec $NETNS sysctl -qw net.ipv6.conf.default.seg6_enabled=1
ip netns exec $NETNS sysctl -qw net.ipv6.conf.lo.seg6_enabled=1
ip netns exec $NETNS sysctl -qw net.ipv6.seg6_flowlabel=1 2>/dev/null || true
ip netns exec $NETNS sysctl -qw net.ipv4.conf.all.rp_filter=0
ip netns exec $NETNS sysctl -qw net.ipv4.conf.default.rp_filter=0
ip netns exec $NETNS sysctl -qw net.vrf.strict_mode=1

# --- Move private NIC into perouter netns ---

ip link set "$PRIVATE_NIC" down || true
ip link set "$PRIVATE_NIC" netns $NETNS || true
ip netns exec $NETNS ip link set "$PRIVATE_NIC" up
ip netns exec $NETNS sysctl -qw "net.ipv6.conf.${PRIVATE_NIC}.seg6_enabled=1"
ip netns exec $NETNS sysctl -qw "net.ipv4.conf.${PRIVATE_NIC}.rp_filter=0"

# --- Create VRF red in perouter netns ---
# FRR expects the kernel VRF device to exist before it can activate
# the "vrf red" config block.

ip netns exec $NETNS ip link add red type vrf table 1100 2>/dev/null || true
ip netns exec $NETNS ip link set red up

# --- Create veth pair between perouter and default netns ---

ip link add veth-host type veth peer name veth-frr 2>/dev/null || true
ip link set veth-frr netns $NETNS || true
ip netns exec $NETNS ip link set veth-frr master red
ip link set veth-host up
ip netns exec $NETNS ip link set veth-frr up

# Default netns side: gateway for VRF red traffic
ip addr add 10.200.0.2/30 dev veth-host 2>/dev/null || true
ip -6 addr add fd00:200::2/126 dev veth-host 2>/dev/null || true

# DNS/NTP loopback addresses (reachable from cluster via SRv6 → veth)
ip addr add $DNS_LISTEN_IP/32 dev lo 2>/dev/null || true
ip -6 addr add $DNS_LISTEN_IP6/128 dev lo 2>/dev/null || true
ip addr add 10.10.20.1/32 dev lo 2>/dev/null || true
ip -6 addr add fc00:10:20::1/128 dev lo 2>/dev/null || true
ip addr add 127.0.0.100/32 dev lo 2>/dev/null || true

# Routes for VRF red subnets back through the veth
ip route add $PRIVATE_NET via 10.200.0.1 2>/dev/null || true
ip -6 route add $PRIVATE_NET_V6 via fd00:200::1 2>/dev/null || true

# --- NAT (firewalld) ---

PUBLIC_NM_CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$PUBLIC_NIC" '$2==d{print $1}')
if [[ -n "$PUBLIC_NM_CON" ]]; then
	nmcli con mod "$PUBLIC_NM_CON" connection.zone external
	nmcli con up "$PUBLIC_NM_CON"
fi

firewall-cmd --zone=external --add-masquerade --permanent
firewall-cmd --zone=external --add-service=nfs --permanent
firewall-cmd --zone=external --add-service=mountd --permanent
firewall-cmd --zone=external --add-service=rpc-bind --permanent
firewall-cmd --zone=trusted --add-source="$PRIVATE_NET" --permanent
firewall-cmd --zone=trusted --add-source="$PRIVATE_NET_V6" --permanent
firewall-cmd --zone=trusted --add-source=10.0.0.0/24 --permanent
firewall-cmd --zone=trusted --add-source=10.100.0.0/24 --permanent
firewall-cmd --zone=trusted --add-source=10.200.0.0/30 --permanent
firewall-cmd --permanent --direct --add-rule ipv6 nat POSTROUTING 0 \
	-s "$PRIVATE_NET_V6" -o "$PUBLIC_NIC" -j MASQUERADE 2>/dev/null || true
firewall-cmd --reload

# --- Containerized FRR (in perouter netns) ---

systemctl disable frr --now 2>/dev/null || true

mkdir -p /etc/frr
cp "${SCRIPT_DIR}/frr.conf" /etc/frr/frr.conf

cat > /etc/frr/daemons <<DAEMONS
zebra=yes
bgpd=yes
isisd=yes
staticd=yes
bfdd=yes
DAEMONS

cat > /etc/frr/vtysh.conf <<VTYSH
service integrated-vtysh-config
VTYSH

podman pull "$FRR_IMAGE"
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
podman run -d --name "$CONTAINER_NAME" --rm \
	--network=ns:/run/netns/$NETNS \
	--privileged \
	-v /etc/frr:/etc/frr:Z \
	"$FRR_IMAGE"

# Wait for FRR to program VRF red and veth address
echo "Waiting for FRR to configure veth-frr..."
while ! ip netns exec $NETNS ip addr show dev veth-frr 2>/dev/null | grep -q 10.200.0.1; do
	sleep 1
done

# --- DNS server ---

pkill dnsmasq 2>/dev/null || true
sleep 1

cp "${SCRIPT_DIR}/dnsmasq.conf" /etc/dnsmasq.d/sno.conf

dnsmasq --pid-file=/run/dnsmasq-sno.pid \
	--conf-file=/etc/dnsmasq.d/sno.conf

# Point NM at our dnsmasq for cluster domain resolution
mkdir -p /etc/NetworkManager/dnsmasq.d
cat > /etc/NetworkManager/dnsmasq.d/sno-lab.conf <<DNSMASQ
server=/${CLUSTER_DOMAIN}/127.0.0.100
DNSMASQ

if ! grep -q 'dns=dnsmasq' /etc/NetworkManager/NetworkManager.conf; then
	sed -i '/^\[main\]/a dns=dnsmasq' /etc/NetworkManager/NetworkManager.conf
fi
nmcli general reload

# --- NTP server ---

pkill -f "chronyd.*chrony-sno" 2>/dev/null || true

cat > /etc/chrony-sno.conf <<CHRONY
local stratum 3 orphan
allow all
bindaddress ${DNS_LISTEN_IP}
port 123
driftfile /var/run/chrony-sno.drift
pidfile /run/chronyd-sno.pid
CHRONY

chronyd -f /etc/chrony-sno.conf -x

# --- NFS (serve ISOs to iDRAC virtual media) ---

dnf install -y nfs-utils
mkdir -p /srv/nfs/iso
semanage fcontext -a -t public_content_ro_t '/srv/nfs/iso(/.*)?' 2>/dev/null || true
restorecon -Rv /srv/nfs/iso
setsebool -P nfs_export_all_ro on
if ! grep -q '/srv/nfs/iso' /etc/exports 2>/dev/null; then
	echo '/srv/nfs/iso *(ro,no_root_squash)' >> /etc/exports
fi
systemctl enable --now nfs-server
exportfs -ra

echo ""
echo "==> Bastion setup complete (ISIS + SRv6 L3VPN)"
echo ""
echo "Useful commands:"
echo "  podman exec -it $CONTAINER_NAME vtysh -c 'show isis neighbor'"
echo "  podman exec -it $CONTAINER_NAME vtysh -c 'show bgp summary'"
echo "  podman exec -it $CONTAINER_NAME vtysh -c 'show bgp ipv4 vpn'"
echo "  podman exec -it $CONTAINER_NAME vtysh -c 'show segment-routing srv6 locator'"
echo ""
echo "L3VPN test:"
echo "  ping 192.168.110.2"
echo "  oc get nodes"
