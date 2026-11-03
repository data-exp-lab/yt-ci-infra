#!/usr/bin/env bash
# One-time setup of the yt answer-test worker. Run as root on a fresh Ubuntu 24.04 m3.xl.
# Everything here lands on the root disk, which shelving preserves, so it runs once.
# Re-run after a rebuild from image; see docs/operations.md.
set -euo pipefail

RUNNER_VERSION="${RUNNER_VERSION:-2.321.0}"   # TODO: bump to current before first provision
RUNNER_USER=runner
RUNNER_HOME=/opt/yt-runner
CONTROLLER_URL="${CONTROLLER_URL:?set CONTROLLER_URL=http://<controller-private-ip>:8080}"

apt-get update
apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential pkg-config \
    libhdf5-dev libopenmpi-dev libnetcdf-dev \
    libfuse2 jq rsync bc

id -u "$RUNNER_USER" >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/$RUNNER_USER --shell /bin/bash "$RUNNER_USER"

# Actions runner binary (ephemeral mode is a flag at run time, not install time).
mkdir -p "$RUNNER_HOME"
if [ ! -x "$RUNNER_HOME/run.sh" ]; then
    curl -fsSL -o /tmp/runner.tgz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
    tar -xzf /tmp/runner.tgz -C "$RUNNER_HOME"
    rm /tmp/runner.tgz
    "$RUNNER_HOME/bin/installdependencies.sh"
fi
install -m 0755 "$(dirname "$0")/boot-runner.sh" "$RUNNER_HOME/boot-runner.sh"
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"

# uv + the pinned interpreter the nose answer job needs (answer stores are py310_* prefixed).
# uv searches the cwd and its parents for uv.toml, so run from a directory the runner can read.
(cd "/home/$RUNNER_USER" && sudo -u "$RUNNER_USER" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh')
(cd "/home/$RUNNER_USER" && sudo -u "$RUNNER_USER" "/home/$RUNNER_USER/.local/bin/uv" python install 3.10)

# Mount points. Volumes are labelled by infra/seed-*-volume.sh; boot-runner.sh mounts by label.
# The answers volume is written by the runner on baseline runs; the seed script leaves it
# root-owned because this user does not exist yet when the volumes are seeded.
mkdir -p /mnt/yt-data /mnt/yt-answers
if ! mountpoint -q /mnt/yt-answers; then
    mount LABEL=yt-answers /mnt/yt-answers
fi
chown -R "$RUNNER_USER:$RUNNER_USER" /mnt/yt-answers

# Worker-side config: where the controller is, and how to mount the answers volume.
mkdir -p /etc/yt-runner
cat > /etc/yt-runner/env <<ENV
CONTROLLER_URL=${CONTROLLER_URL}
# ro for PR compare runs (default). rw only for baseline/store runs; see docs/operations.md.
ANSWERS_MODE=ro
ENV
chmod 0644 /etc/yt-runner/env

install -m 0644 "$(dirname "$0")/systemd/yt-runner.service" /etc/systemd/system/yt-runner.service
systemctl daemon-reload
systemctl enable yt-runner.service

echo "provisioned. shelve this instance when done: openstack server shelve yt-worker"
