#!/usr/bin/env bash
# Reference copy. Canonical location: yt/tests/run_answer_tests.sh
#
# Run yt's nose answer-test suite the way the Jenkins job and the build-test.yaml "answer"
# job did: fresh env on Python 3.10, then tests/nose_runner.py. Run from the repo root.
#
#   YT_TEST_DATA_DIR  dataset root; <root>/answers must be writable for store runs (default /mnt/yt-data)
#   GROUPS            comma-separated answer_tests keys from tests/tests.yaml; blank = all
#   NUM_WORKERS       parallel nose processes (default: nproc - 2)
#   PYTHON_VERSION    default 3.10; answer stores are prefixed py310_ so keep it
set -euo pipefail

: "${YT_TEST_DATA_DIR:=/mnt/yt-data}"
: "${GROUPS:=}"
: "${PYTHON_VERSION:=3.10}"
: "${NUM_WORKERS:=$(( $(nproc) > 2 ? $(nproc) - 2 : 1 ))}"
export PATH="$HOME/.local/bin:$PATH"
export MPLCONFIGDIR=tests

[ -f tests/nose_runner.py ] || { echo "run from the yt repo root" >&2; exit 64; }
[ -d "$YT_TEST_DATA_DIR" ] || { echo "no test data at $YT_TEST_DATA_DIR" >&2; exit 1; }

# tests/ci_install.sh minus its sudo apt-get (libfuse2 is provisioned on the worker).
uv sync --python "$PYTHON_VERSION" --extra=test --extra=full --group=nosetest
uv run --no-sync yt config set --local yt log_level 50
uv run --no-sync yt config set --local yt test_data_dir "$YT_TEST_DATA_DIR"

# nose is unmaintained and still references collections.Callable; same patch as build-test.yaml.
find ".venv/lib/python${PYTHON_VERSION}/site-packages/nose" -name '*.py' \
    -exec sed -i -e 's/collections.Callable/collections.abc.Callable/g' '{}' ';'

if [ -n "$GROUPS" ]; then
    # Restrict tests/tests.yaml (scratch checkout) to the requested answer groups.
    # Drops other_tests (the unittests job) too: a group filter means a targeted run.
    uv run --no-sync python - "$GROUPS" <<'PY'
import sys, yaml
want = {g.strip() for g in sys.argv[1].split(",") if g.strip()}
with open("tests/tests.yaml") as f:
    tests = yaml.safe_load(f)
unknown = want - set(tests["answer_tests"])
if unknown:
    sys.exit(f"unknown answer-test groups: {sorted(unknown)}")
tests["answer_tests"] = {k: v for k, v in tests["answer_tests"].items() if k in want}
tests["other_tests"] = {}
with open("tests/tests.yaml", "w") as f:
    yaml.safe_dump(tests, f)
print("running groups:", sorted(want))
PY
fi

rm -f ./*.xml
echo "NUM_WORKERS=$NUM_WORKERS test_data_dir=$YT_TEST_DATA_DIR"
NUM_WORKERS="$NUM_WORKERS" uv run --no-sync python tests/nose_runner.py

# nose_runner.py always exits 0; the xunit files carry the verdict.
fails=0
for f in ./*.xml; do
    [ -e "$f" ] || continue
    n=$(grep -oE 'errors="[0-9]+"|failures="[0-9]+"' "$f" | grep -oE '[0-9]+' | paste -sd+ - | bc)
    [ "${n:-0}" -eq 0 ] || { echo "FAIL $f ($n)"; fails=$((fails + 1)); }
done
echo "$fails group(s) with failures"
[ "$fails" -eq 0 ]
