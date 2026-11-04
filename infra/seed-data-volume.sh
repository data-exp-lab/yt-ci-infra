#!/usr/bin/env bash
# Format and populate the datasets volume (`yt-data`). Run as root on the worker, once, with the
# volume attached. After seeding it is only ever mounted read-only; see worker/boot-runner.sh.
#
# usage: DATA_DEV=/dev/sdc seed-data-volume.sh format    # mkfs + label (destructive)
#        seed-data-volume.sh fetch datasets.json          # download+unpack every entry not yet seeded
#        seed-data-volume.sh verify datasets.json         # every entry seeded and its paths present
#
# datasets.json is infra/datasets.json in yt-ci-infra: a list of
# {"datafile", "unpack_to"?, "url"?, "note"?}. datafile is a file name, fetched from
# https://yt-project.org/data/<datafile> unless url gives a full download URL instead. Tarballs
# (.tar.gz, .tgz) are extracted; any other .gz is gunzipped with the compressed copy kept.
# unpack_to is a directory under the volume root to unpack into; omitted, the entry unpacks at
# the root. How the list was built: docs/operations.md, "Dataset pre-flight".
#
# Each file is downloaded whole to <volume>/.tmp before unpacking, so a failed download leaves
# nothing half-extracted. A seeded entry leaves <volume>/.seeded/<datafile> listing the top-level
# paths it produced; fetch skips entries with a marker, so it can be re-run after a failure, and
# verify checks the listed paths exist. A failed download does not stop the run; failures are
# listed at the end.
set -euo pipefail

DATA_DEV="${DATA_DEV:-}"
BASE_URL="${BASE_URL:-https://yt-project.org/data}"
MNT=/mnt/yt-data
MARK="$MNT/.seeded"
TMP="$MNT/.tmp"

format_volume() {
    : "${DATA_DEV:?set DATA_DEV, the 200G device in lsblk, e.g. /dev/sdc}"
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

# Prints one "datafile|unpack_to|url" line per entry, '|' standing for the ASCII unit separator;
# optional fields empty when absent. (A tab would collapse empty fields in `read`.)
SEP=$'\x1f'
entries() {
    python3 -c '
import json, sys
for e in json.load(open(sys.argv[1])):
    print(chr(31).join([e["datafile"], e.get("unpack_to", ""), e.get("url", "")]))' "$1"
}

fetch_one() {
    local df="$1" dest="$2" url="${3:-$BASE_URL/$1}" dir="$MNT/${2:-.}" prefix="${2:+$2/}" tmp="$TMP/$1"
    case "$df" in
        *.gz) ;;
        *) echo "don't know how to unpack $df" >&2; return 1 ;;
    esac
    mkdir -p "$dir" "$TMP"
    curl -fsSL -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }
    case "$df" in
        *.tar.gz|*.tgz)
            tar --warning=no-unknown-keyword -tzf "$tmp" | cut -d/ -f1 | sort -u | sed "s|^|$prefix|" >"$MARK/$df.tmp" || return 1
            tar --warning=no-unknown-keyword -xzf "$tmp" -C "$dir" || return 1
            rm -f "$tmp"
            ;;
        *.gz)
            mv "$tmp" "$dir/$df"
            gunzip -kf "$dir/$df" || return 1
            printf '%s\n' "$prefix$df" "$prefix${df%.gz}" >"$MARK/$df.tmp"
            ;;
    esac
    # tar as root keeps the archive's modes, and laptop-made tarballs carry 700 directories
    # that the runner user cannot enter. Open everything this entry produced for reading.
    while IFS= read -r path; do chmod -R a+rX "$MNT/$path"; done <"$MARK/$df.tmp"
    mv "$MARK/$df.tmp" "$MARK/$df"
}

fetch_datasets() {
    local list="$1" df dest url failed=()
    mount_rw
    mkdir -p "$MARK"
    while IFS="$SEP" read -r df dest url; do
        if [ -e "$MARK/$df" ]; then echo "have   $df"; continue; fi
        echo "fetch  $df${dest:+ -> $dest/}${url:+ from $url}"
        fetch_one "$df" "$dest" "$url" || { echo "FAILED $df"; rm -f "$MARK/$df.tmp" "$TMP/$df"; failed+=("$df"); }
    done < <(entries "$list")
    echo "${#failed[@]} failed${failed[*]:+: ${failed[*]}}"
    [ "${#failed[@]}" -eq 0 ]
}

verify_datasets() {
    local list="$1" df dest url p bad=0
    while IFS="$SEP" read -r df dest url; do
        if [ ! -e "$MARK/$df" ]; then echo "MISSING $df (never seeded)"; bad=$((bad + 1)); continue; fi
        while read -r p; do
            [ -e "$MNT/$p" ] || { echo "MISSING $df: $p"; bad=$((bad + 1)); }
        done <"$MARK/$df"
    done < <(entries "$list")
    echo "$bad missing"
    [ "$bad" -eq 0 ]
}

case "${1:-}" in
    format) format_volume ;;
    fetch)  fetch_datasets "${2:?datasets.json}" ;;
    verify) verify_datasets "${2:?datasets.json}" ;;
    *) echo "usage: $0 {format|fetch datasets.json|verify datasets.json}" >&2; exit 64 ;;
esac
