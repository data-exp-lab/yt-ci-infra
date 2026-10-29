#!/usr/bin/env bash
# Format and populate the datasets volume (`yt-data`). Run as root on the worker, once, with the
# volume attached. After seeding it is only ever mounted read-only; see worker/boot-runner.sh.
# Datasets come from https://yt-project.org/data/<name>.tar.gz.
#
# usage: DATA_DEV=/dev/vdb seed-data-volume.sh format   # mkfs + label (destructive)
#        seed-data-volume.sh fetch datasets.txt         # download+extract each listed dataset
#        seed-data-volume.sh verify datasets.txt
#
# TODO: produce datasets.txt. The authoritative list is every name passed to requires_ds /
# data_dir_load / can_run_ds across yt's test modules; see docs/operations.md "dataset pre-flight".
set -euo pipefail

DATA_DEV="${DATA_DEV:-}"
BASE_URL="${BASE_URL:-https://yt-project.org/data}"
MNT=/mnt/yt-data

format_volume() {
    : "${DATA_DEV:?set DATA_DEV, e.g. /dev/vdb}"
    lsblk "$DATA_DEV"
    read -r -p "mkfs.ext4 on $DATA_DEV, destroying contents. type yes: " ok
    [ "$ok" = yes ] || exit 1
    mkfs.ext4 -L yt-data "$DATA_DEV"
    mkdir -p "$MNT"
    mount LABEL=yt-data "$MNT"
    # nose_runner.py hardcodes <test_data_dir>/answers. This link lives on the (later read-only)
    # data volume and points across to the answers volume; writes follow it there.
    ln -sfn /mnt/yt-answers/answers "$MNT/answers"
}

mount_rw() {
    if mountpoint -q "$MNT"; then
        mount -o remount,rw "$MNT"
    else
        mount -o rw LABEL=yt-data "$MNT"
    fi
}

fetch_datasets() {
    local list="$1"
    mount_rw
    cd "$MNT"
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
        [ -e "$MNT/$name" ] || { echo "MISSING $name"; missing=$((missing + 1)); }
    done <"$list"
    echo "$missing missing"
    [ "$missing" -eq 0 ]
}

case "${1:-}" in
    format) format_volume ;;
    fetch)  fetch_datasets "${2:?datasets list}" ;;
    verify) verify_datasets "${2:?datasets list}" ;;
    *) echo "usage: $0 {format|fetch LIST|verify LIST}" >&2; exit 64 ;;
esac
