#!/usr/bin/env bash
# Format and populate the two data volumes. Run as root on the worker, once, with the
# volumes attached. Datasets come from https://yt-project.org/data/<name>.tar.gz.
#
# usage: seed-volume.sh format            # mkfs + label both volumes (destructive)
#        seed-volume.sh fetch datasets.txt # download+extract each listed dataset into /mnt/yt-data
#        seed-volume.sh verify datasets.txt
#
# TODO: produce datasets.txt. The authoritative list is every name passed to requires_ds /
# data_dir_load / can_run_ds across yt's test modules; see docs/operations.md "dataset pre-flight".
set -euo pipefail

DATA_DEV="${DATA_DEV:-}"       # e.g. /dev/vdb; required for `format`
ANSWERS_DEV="${ANSWERS_DEV:-}" # e.g. /dev/vdc
BASE_URL="${BASE_URL:-https://yt-project.org/data}"

format_volumes() {
    : "${DATA_DEV:?set DATA_DEV}" "${ANSWERS_DEV:?set ANSWERS_DEV}"
    lsblk "$DATA_DEV" "$ANSWERS_DEV"
    read -r -p "mkfs.ext4 on $DATA_DEV and $ANSWERS_DEV, destroying contents. type yes: " ok
    [ "$ok" = yes ] || exit 1
    mkfs.ext4 -L yt-data "$DATA_DEV"
    mkfs.ext4 -L yt-answers "$ANSWERS_DEV"
    mkdir -p /mnt/yt-data /mnt/yt-answers
    mount LABEL=yt-data /mnt/yt-data
    mount LABEL=yt-answers /mnt/yt-answers
    mkdir -p /mnt/yt-answers/answers
    chown -R runner:runner /mnt/yt-answers
}

fetch_datasets() {
    local list="$1"
    mountpoint -q /mnt/yt-data || mount -o rw LABEL=yt-data /mnt/yt-data
    cd /mnt/yt-data
    while read -r name; do
        [ -z "$name" ] || [ "${name:0:1}" = "#" ] && continue
        if [ -e "$name" ]; then echo "have   $name"; continue; fi
        echo "fetch  $name"
        curl -fsSL "${BASE_URL}/${name}.tar.gz" | tar -xz
    done <"$list"
}

verify_datasets() {
    local list="$1" missing=0
    while read -r name; do
        [ -z "$name" ] || [ "${name:0:1}" = "#" ] && continue
        [ -e "/mnt/yt-data/$name" ] || { echo "MISSING $name"; missing=$((missing + 1)); }
    done <"$list"
    echo "$missing missing"
    [ "$missing" -eq 0 ]
}

case "${1:-}" in
    format) format_volumes ;;
    fetch)  fetch_datasets "${2:?datasets list}" ;;
    verify) verify_datasets "${2:?datasets list}" ;;
    *) echo "usage: $0 {format|fetch LIST|verify LIST}" >&2; exit 64 ;;
esac
