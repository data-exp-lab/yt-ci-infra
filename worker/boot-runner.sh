#!/usr/bin/env bash
# Runs at every boot (unshelve) via yt-runner.service.
#   mount : as root (ExecStartPre=+), mount the data volumes.
#   run   : as the runner user, fetch a single-use config from the controller and take one job.
# Holds no secrets. The jitconfig it receives is good for one registration and expires in ~1h.
set -euo pipefail

RUNNER_HOME=/opt/yt-runner
ENV_FILE=/etc/yt-runner/env
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${CONTROLLER_URL:?CONTROLLER_URL not set in $ENV_FILE}"
: "${ANSWERS_MODE:=ro}"

mount_volumes() {
    mountpoint -q /mnt/yt-data    || mount -o ro,noatime LABEL=yt-data /mnt/yt-data
    mountpoint -q /mnt/yt-answers || mount -o "${ANSWERS_MODE},noatime" LABEL=yt-answers /mnt/yt-answers
    echo "mounted: yt-data ro, yt-answers ${ANSWERS_MODE}"
}

run_one_job() {
    cd "$RUNNER_HOME"
    local cfg
    # Controller may still be settling or the private network may lag the boot; retry briefly.
    for attempt in $(seq 1 12); do
        if cfg=$(curl -fsS --max-time 20 "${CONTROLLER_URL}/runner-config"); then
            break
        fi
        echo "runner-config fetch failed (attempt $attempt); retrying" >&2
        sleep 10
        cfg=""
    done
    [ -n "$cfg" ] || { echo "could not obtain runner config from ${CONTROLLER_URL}" >&2; exit 1; }

    local name blob
    name=$(jq -r .runner_name <<<"$cfg")
    blob=$(jq -r .encoded_jit_config <<<"$cfg")
    echo "registering as ${name}; taking one job"
    # The JIT config is ephemeral by construction: register, run one job, deregister, exit.
    exec ./run.sh --jitconfig "$blob"
}

case "${1:-}" in
    mount) mount_volumes ;;
    run)   run_one_job ;;
    *) echo "usage: $0 {mount|run}" >&2; exit 64 ;;
esac
