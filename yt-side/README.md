# yt-side files

Reference copies of the files that live in the **yt repo**, not here. GitHub only reads
workflows from the repository they run in, so the canonical versions are:

| copy here | destination in yt | status |
|-----------|-------------------|--------|
| `answer-tests.yml` | `.github/workflows/answer-tests.yml` | new file |
| `nose_runner.py` | `tests/nose_runner.py` | modified; replace the whole file |
| `ci_install.sh` | `tests/ci_install.sh` | modified; replace the whole file |

They are kept here because they are the contract between the yt repo and this
infrastructure: the runner label, the mount paths, the Python version, the status context,
and the tools the job expects on the worker (`gh` for the status steps, `uv`, `libfuse2`),
which `worker/provision.sh` installs. GitHub-hosted runners have `gh` preinstalled; a
self-hosted one does not.
When any of those change, change both copies. During v0/v1 the live copies are on the fork
`chrishavlin/yt`; see `docs/deploy.md` step 5.

## What the workflow does

- Trigger: `workflow_dispatch` only, from the Actions tab or `gh workflow run`. GitHub
  restricts dispatch to users with write access, so that is the whole authorization story:
  untrusted code never reaches the worker unless a maintainer chooses to run it.
- `resolve` (on `ubuntu-latest`, free): turns the `pr` or `ref` input into a SHA and pins it,
  so a later push to the PR does not change what runs. A bad PR number or ref fails here
  before the worker is woken up.
- `answer-tests` (on `[self-hosted, jetstream]`): checks out exactly that SHA, then mirrors
  the nose answer job that `build-test.yaml` used to have: `ci_install.sh` with
  `--extra=full --group=nosetest` on `PYTHON_VERSION`, the nose `collections.Callable`
  patch, `test_data_dir` set from `$YT_TEST_DATA_DIR`, `tests/nose_runner.py` with
  `NUM_WORKERS` sized to the flavor. Uploads the per-group xunit XML and posts a commit status
  `answer-tests` on the SHA so the result appears in the PR's checks.

Dispatch inputs:

| input | meaning |
|-------|---------|
| `pr` | PR number; tests its current head SHA |
| `ref` | any ref or SHA (for bisecting, tags, the last-known-good commit); ignored if `pr` is set |
| `groups` | comma-separated `tests/tests.yaml` answer-test keys to run; blank = everything |
| `store_missing` | boolean, default off. On: a group with no answer store keeps the answers this run generates, and they are the baseline from then on. Off: such a group fails (its generated store is discarded). Either way a group with no store whose datasets are missing is skipped, not failed (the runner sets yt's `strict_requires` so missing data cannot produce an empty store). A group that has a store and is missing a dataset fails its compare pass. |

The workflow does not know where the data lives. `YT_TEST_DATA_DIR` and the `PATH` entry for
`uv` are exported into the runner's environment by `boot-runner.sh` on the worker, from
`/etc/yt-runner/env`, and jobs inherit that environment. yt itself does not read
`YT_TEST_DATA_DIR`, which is why the run step still calls `yt config set`.

`PYTHON_VERSION` is a job-level env in the workflow. It drives `UV_PYTHON` for the install and
the path of the nose patch. Answer stores on the worker are prefixed `py310_`, so bumping it
means regenerating them (`docs/operations.md`, "Change the Python version the suite runs on").

## Changes to the two yt files

**`tests/nose_runner.py`** gets an argument parser and a real exit code; the job list is
otherwise built exactly as before.

| flag | env fallback | effect |
|------|--------------|--------|
| `--groups a,b` | `YT_TEST_GROUPS` | run only those `answer_tests` keys; unknown keys exit nonzero before anything runs |
| `--unittests` / `--no-unittests` | | run `other_tests` (the unittests job). Default: yes, unless `--groups` is given |
| `--store-missing` / `--no-store-missing` | `YT_STORE_MISSING` | keep the stores generated for groups that have none (default off: those groups fail). `docs/operations.md`, "Answer stores" |
| `--num-workers N` | `NUM_WORKERS` | parallel nose processes (default 6) |

The filter is applied in memory; `tests/tests.yaml` is never rewritten. The unittests job
still excludes every answer test from the full file, not just the selected groups. Each
`nose.run` result is collected and the script exits 1 naming the failed runs, so the workflow
step fails without parsing xunit XML. (Upstream always exits 0.) Groups whose datasets are
missing are listed as skipped. In a full run they do not affect the exit code; when `--groups`
names them, the run fails, so a new group dispatched by name before its data is seeded is red
rather than a quiet skip.

The install step passes `--reinstall-package yt`. yt's editable install compiles its Cython
extensions in place in the source tree; on a self-hosted runner the work directory persists
between jobs, checkout's clean removes those `.so` files, and uv reuses its cached build
without recompiling (`ModuleNotFoundError: yt.geometry.selection_routines` on the second run).
Forcing the rebuild costs a Cython compile per job and is also what makes a `.pyx` change in a
PR take effect.

**`tests/ci_install.sh`** skips its `sudo apt-get` step when `YT_CI_SKIP_SYSTEM_DEPS=1`. The
worker has `libfuse2` from `worker/provision.sh` and the runner user has no sudo. The variable
is unset in every existing workflow, so GitHub-hosted jobs are unchanged.

## Running it by hand on the worker

From a yt checkout as the `runner` user (cwd must be readable by `runner`, see the uv gotcha
in `docs/deploy.md`):

```
. /etc/yt-runner/env
export PATH="$HOME/.local/bin:$PATH" MPLCONFIGDIR=tests
sync_args="--extra=full --group=nosetest" UV_PYTHON=3.10 YT_CI_SKIP_SYSTEM_DEPS=1 source tests/ci_install.sh
find .venv/lib/python3.10/site-packages/nose -name '*.py' -exec sed -i -e 's/collections.Callable/collections.abc.Callable/g' '{}' ';'
uv run --no-sync yt config set --local yt test_data_dir "$YT_TEST_DATA_DIR"
uv run --no-sync yt config set --local yt supp_data_dir "$YT_TEST_DATA_DIR/supp_data"
uv run --no-sync python tests/nose_runner.py --groups local_art_004
```
