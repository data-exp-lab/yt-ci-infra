#!/usr/bin/env bash
# Create the Jetstream2 resources for the yt answer-test runner, once per allocation.
# Equivalent to the Horizon click-through in docs/deploy.md step 1A; use whichever you prefer.
# Because every step is skipped when the named resource exists, this is also the rebuild path
# for a deleted worker (docs/operations.md).
# Requires: python-openstackclient, OS_CLOUD pointing at an application credential in clouds.yaml.
# Every step is idempotent-ish by name lookup; re-run after fixing a failure.
#
# TODO before first run (values from the live allocation / Horizon):
#   - IMAGE: current Featured-Ubuntu24 image name
#   - PUBLIC_NET: the shared external network name (usually "public")
#   - ADMIN_CIDR: your SSH source range
#   - KEYPAIR: an existing keypair name, or let this script create one
set -euo pipefail

PREFIX="${PREFIX:-yt}"
IMAGE="${IMAGE:-Featured-Ubuntu24}"
PUBLIC_NET="${PUBLIC_NET:-public}"
ADMIN_CIDR="${ADMIN_CIDR:?set ADMIN_CIDR=a.b.c.d/32}"
KEYPAIR="${KEYPAIR:-${PREFIX}-key}"
CONTROLLER_FLAVOR="${CONTROLLER_FLAVOR:-m3.tiny}"
WORKER_FLAVOR="${WORKER_FLAVOR:-m3.xl}"
DATA_VOLUME_GB="${DATA_VOLUME_GB:-200}"
ANSWERS_VOLUME_GB="${ANSWERS_VOLUME_GB:-50}"
TOKEN_PORT="${TOKEN_PORT:-8080}"

exists() { openstack "$1" show "$2" >/dev/null 2>&1; }

# --- network ---------------------------------------------------------------
exists network "${PREFIX}-net" || openstack network create "${PREFIX}-net"
exists subnet "${PREFIX}-subnet" || openstack subnet create "${PREFIX}-subnet" \
    --network "${PREFIX}-net" --subnet-range 10.0.42.0/24 --dns-nameserver 8.8.8.8
exists router "${PREFIX}-router" || {
    openstack router create "${PREFIX}-router"
    openstack router set "${PREFIX}-router" --external-gateway "$PUBLIC_NET"
    openstack router add subnet "${PREFIX}-router" "${PREFIX}-subnet"
}

# --- security groups (see networking.md) -----------------------------------
exists "security group" "${PREFIX}-controller-sg" || {
    openstack security group create "${PREFIX}-controller-sg" --description "yt controller: ssh from admin, token port from worker"
    openstack security group rule create "${PREFIX}-controller-sg" --proto tcp --dst-port 22 --remote-ip "$ADMIN_CIDR"
}
exists "security group" "${PREFIX}-worker-sg" || {
    openstack security group create "${PREFIX}-worker-sg" --description "yt worker: ssh from controller only"
}
# Cross-group rules, added after both groups exist.
openstack security group rule create "${PREFIX}-controller-sg" \
    --proto tcp --dst-port "$TOKEN_PORT" --remote-group "${PREFIX}-worker-sg" 2>/dev/null || true
openstack security group rule create "${PREFIX}-worker-sg" \
    --proto tcp --dst-port 22 --remote-group "${PREFIX}-controller-sg" 2>/dev/null || true

# --- keypair ---------------------------------------------------------------
exists keypair "$KEYPAIR" || openstack keypair create --public-key ~/.ssh/id_ed25519.pub "$KEYPAIR"

# --- volumes (from the free 1 TB quota) ------------------------------------
exists volume "${PREFIX}-data"    || openstack volume create --size "$DATA_VOLUME_GB"    "${PREFIX}-data"
exists volume "${PREFIX}-answers" || openstack volume create --size "$ANSWERS_VOLUME_GB" "${PREFIX}-answers"

# --- controller: tiny, always on, the only floating IP ---------------------
exists server "${PREFIX}-controller" || {
    openstack server create "${PREFIX}-controller" \
        --image "$IMAGE" --flavor "$CONTROLLER_FLAVOR" --key-name "$KEYPAIR" \
        --network "${PREFIX}-net" --security-group "${PREFIX}-controller-sg" --wait
    fip=$(openstack floating ip create "$PUBLIC_NET" -f value -c floating_ip_address)
    openstack server add floating ip "${PREFIX}-controller" "$fip"
    echo "controller floating ip: $fip"
}

# --- worker: big, shelved by default, no floating IP, no credentials -------
exists server "${PREFIX}-worker" || {
    openstack server create "${PREFIX}-worker" \
        --image "$IMAGE" --flavor "$WORKER_FLAVOR" --key-name "$KEYPAIR" \
        --network "${PREFIX}-net" --security-group "${PREFIX}-worker-sg" --wait
    openstack server add volume "${PREFIX}-worker" "${PREFIX}-data"
    openstack server add volume "${PREFIX}-worker" "${PREFIX}-answers"
}

cat <<MSG

created. next:
  1. ssh to the controller via its floating ip; install controller/ per docs/deploy.md
  2. ssh to the worker via the controller (ProxyJump); run infra/seed-data-volume.sh and infra/seed-answers-volume.sh, then worker/provision.sh
  3. openstack server shelve ${PREFIX}-worker
controller private ip: $(openstack server show "${PREFIX}-controller" -f value -c addresses)
MSG
