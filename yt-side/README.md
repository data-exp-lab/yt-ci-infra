# yt-side files

Reference copies of the two files that live in the **yt repo**, not here. GitHub only reads
workflows from the repository they run in, so the canonical versions are:

- `yt/.github/workflows/answer-tests.yml`
- `yt/tests/run_answer_tests.sh`

They are kept here because they are the contract between the yt repo and this
infrastructure: the runner label, the mount paths, the Python version, the status context.
When any of those change, change both copies. During v0/v1 the live copies are on the fork
`chrishavlin/yt`; see `docs/deploy.md` step 5.

## What the workflow does

- Triggers: `workflow_dispatch` (anyone with write access, via the Actions tab) and an
  `issue_comment` containing `/run-answer-tests` on a PR. Comment-triggered runs use the
  workflow file from the default branch, so a PR cannot alter the gate.
- `authorize` (on `ubuntu-latest`, free): for comments, requires the commenter to have
  `admin`, `maintain`, or `write` permission (not `triage`, not `author_association`). Pins
  the SHA to test at that moment, so a later push to the PR does not run. Reacts 🚀 to the
  comment.
- `answer-tests` (on `[self-hosted, jetstream]`): checks out exactly that SHA, runs
  `tests/run_answer_tests.sh`, uploads the per-group xunit XML, and posts a commit status
  `answer-tests` on the SHA so the result appears in the PR's checks.

Dispatch inputs:

| input | meaning |
|-------|---------|
| `pr` | PR number; tests its current head SHA |
| `ref` | any ref or SHA (for bisecting, tags, the last-known-good commit); ignored if `pr` is set |
| `groups` | comma-separated `tests/tests.yaml` answer-test keys to run; blank = everything |

## What the script does

Mirrors the nose answer job in `build-test.yaml`, minus the `sudo apt-get` line in
`ci_install.sh` (the runner user has no sudo; `libfuse2` is installed by `worker/provision.sh`).
Fresh `uv sync` every run on Python 3.10, the nose `collections.Callable` patch, test data dir
set to `/mnt/yt-data`, then `tests/nose_runner.py` with `NUM_WORKERS` sized to the flavor.

`GROUPS` filters `tests/tests.yaml` in the scratch checkout before the runner reads it. That
keeps per-group bisects to minutes without touching `nose_runner.py`.
