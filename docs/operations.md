# Operations: recurring tasks

For first-time setup see `deploy.md`.

## Where things are

| what | where |
|------|-------|
| controller code | `/opt/yt-controller` (symlink into the `/opt/yt-ci-infra` checkout) |
| worker scripts | `/opt/yt-ci-infra` checkout (owned by the login user); `provision.sh` installs `boot-runner.sh` into `/opt/yt-runner` |
| controller secrets | `/etc/yt-controller/env`, `~yt-controller/.config/openstack/clouds.yaml` |
| controller state | `/var/lib/yt-controller/state.json` (last-activity timestamp; safe to delete) |
| controller logs | `journalctl -u yt-controller`, `journalctl -u yt-controller-idle-shelver` |
| worker runner | `/opt/yt-runner`, job workspaces under `_work/`, diagnostics under `_diag/` |
| worker config | `/etc/yt-runner/env` (`CONTROLLER_URL`, `YT_TEST_DATA_DIR`, `YT_ANSWERS_DIR`). The two mount paths are the single source: `boot-runner.sh` mounts there and exports `YT_TEST_DATA_DIR` into the runner's environment, which every job inherits. |
| worker logs | `journalctl -u yt-runner` |
| datasets | `/mnt/yt-data` on the worker, volume `yt-data`, always read-only |
| answer stores | `/mnt/yt-answers/answers` on the worker, volume `yt-answers`, always read-write; reached via the symlink `/mnt/yt-data/answers` because `nose_runner.py` hardcodes `<test_data_dir>/answers` |
| yt-side files | `yt-side/` here; canonical copies in the yt repo |

## Controller

### Running the controller CLI

`yt-controller` is not on anyone's PATH. It lives in the service venv and needs the service
user's environment: the token and repo settings from `/etc/yt-controller/env`, and the OpenStack
application credential in `~yt-controller/.config/openstack/clouds.yaml`. Run it as that user
from the checkout, with the env file loaded:

```
cd /opt/yt-controller && sudo -u yt-controller env $(sudo grep -E '^[A-Z_]+=' /etc/yt-controller/env) .venv/bin/yt-controller status
```

Every `yt-controller <subcommand>` below means this invocation. Run as the login user it fails
on OpenStack auth, because that user has no `clouds.yaml`. In normal operation the service and
timer run `serve` and `idle-shelver` for you; the manual subcommands are for maintenance windows.

### Stop and start the controller

Two systemd units run the automation on the controller. `yt-controller.service` polls GitHub
for queued answer-test jobs, unshelves the worker when one appears, hands the worker its
one-time runner registration when it boots, and shelves it again once it has been idle for
`GRACE_SECONDS`. `yt-controller-idle-shelver.timer` is a backstop that shelves a worker the
service has somehow left running. Stop both before any maintenance that needs the worker up
without a job, such as the manual baseline run or re-provisioning the worker scripts;
otherwise a worker you unshelved by hand looks idle and gets shelved under you.

```
sudo systemctl stop yt-controller-idle-shelver.timer yt-controller
systemctl is-active yt-controller yt-controller-idle-shelver.timer   # both: inactive
```

Stop, not disable: `disable` also drops them from boot, and they should come back if the
controller reboots. While stopped, nothing unshelves the worker; a dispatched job sits queued
until the loop is back, and a worker left ACTIVE keeps billing. Resume with:

```
sudo systemctl start yt-controller yt-controller-idle-shelver.timer
systemctl is-active yt-controller yt-controller-idle-shelver.timer   # both: active
```

The loop's first pass runs at once, so a queued job is picked up within `POLL_SECONDS` and an
idle ACTIVE worker is shelved once its grace period has elapsed.

### Is it healthy?

Healthy means two things: the controller loop is running, and the worker is in the state the
GitHub queue calls for (shelved when nothing is queued, active when something is). Check both.

**1. The controller units are up.** On the controller:

```
systemctl is-active yt-controller yt-controller-idle-shelver.timer   # both: active
journalctl -u yt-controller -n 5                                     # a reconcile line within the last POLL_SECONDS
```

Each reconcile line looks like `queued=0 busy=False worker=SHELVED_OFFLOADED idle=n/a -> none`.
A `reconcile cycle failed` traceback means the loop is alive but a GitHub or OpenStack call is
failing; the exception says which.

**2. The worker state matches the queue.** On the controller:

```
cd /opt/yt-controller && sudo -u yt-controller env $(sudo grep -E '^[A-Z_]+=' /etc/yt-controller/env) .venv/bin/yt-controller status
```

It prints `queued` (jobs waiting for our label), `busy` (a runner is executing), `worker` (the
OpenStack status), `idle` (seconds since the last queued or busy observation), and `would` (what
the next reconcile pass will do). The normal combinations:

| situation | queued / busy | worker | would |
|---|---|---|---|
| resting, nothing dispatched | 0 / False | `SHELVED_OFFLOADED` | `none` |
| job dispatched, worker waking | >0 / False | `UNSHELVING` then `ACTIVE` | `none` |
| job running | 0 / True | `ACTIVE` | `none` |
| job finished, grace period | 0 / False, idle < `GRACE_SECONDS` | `ACTIVE` | `none` |
| job finished, grace elapsed | 0 / False, idle > `GRACE_SECONDS` | `ACTIVE` | `shelve` (the loop does it on its next pass) |

Anything else is a fault. The usual ones:

- `queued > 0` and `worker=SHELVED_OFFLOADED` for longer than `POLL_SECONDS` plus a few minutes
  of unshelve: the loop is not acting. Check step 1.
- `worker=ACTIVE`, `would=none`, nothing queued or busy for much longer than `GRACE_SECONDS`:
  the idle counter is stuck or the loop is dead. The idle-shelver timer should catch this after
  `IDLE_SHELVE_SECONDS`; if the worker is still up past that, shelve by hand (next section) and
  read both journals.
- `worker=ACTIVE` and a job sits "Waiting for a runner" for more than a few minutes: the worker
  is up but no runner registered. `journalctl -u yt-runner` on the worker; see "Runner lifecycle
  on the worker" and the JIT gotcha.
- `worker=ERROR` or a transitional state (`SHELVING`, `UNSHELVING`) that does not clear within
  a few minutes: an OpenStack problem. `openstack server show yt-worker` from a laptop.

Cross-checks that do not need the controller box, with your own `clouds.yaml` and `gh` login:

```
openstack server show yt-worker -c status -c updated_at
gh api repos/<owner>/<repo>/actions/runners --jq '.runners[] | {name, status, busy}'
```

The runner list is empty when the worker is shelved; an ACTIVE worker shows exactly one runner,
`online`, busy or not. Two or more runners, or an `offline` one that persists, means stale
registrations GitHub has not yet dropped; harmless but worth a look if jobs are not matching.

### Force a shelve / unshelve

```
cd /opt/yt-controller
sudo -u yt-controller env $(sudo grep -E '^[A-Z_]+=' /etc/yt-controller/env) .venv/bin/yt-controller shelve      # waits for SHELVED_OFFLOADED
sudo -u yt-controller env $(sudo grep -E '^[A-Z_]+=' /etc/yt-controller/env) .venv/bin/yt-controller unshelve    # waits for ACTIVE; the worker boots and fetches a runner config
```

Or `openstack server shelve|unshelve yt-worker` from anywhere with a `clouds.yaml`, including a
laptop; that returns at once, so poll `openstack server show yt-worker -c status` for the
transition. Never `stop` or `suspend`: those bill at 50% and 75% respectively. Shelved bills zero.

If you need the worker up for interactive work, stop both controller units first ("Stop and
start the controller"); otherwise the loop or the idle-shelver timer shelves it under you.

### Rotate the GitHub token

1. Mint the new token (same permissions: Administration r/w, Actions read, scoped to the repo).
2. Edit `GITHUB_TOKEN` in `/etc/yt-controller/env`.
3. `systemctl restart yt-controller`; check `yt-controller status` (full form under "Running the controller CLI") works.
4. Revoke the old token on GitHub.

Nothing on the worker changes: it never holds the token, only one-shot just-in-time (JIT)
runner configs.

### Rotate the OpenStack application credential

1. Horizon → Identity → Application Credentials → create a new one, download `clouds.yaml`.
2. Replace `~yt-controller/.config/openstack/clouds.yaml` (mode 600, owned by `yt-controller`).
3. `systemctl restart yt-controller`; `yt-controller status` (full form under "Running the controller CLI") must show the worker.
4. Delete the old credential in Horizon.

### Update the controller code

The controller's checkout is owned by `yt-controller`, so run git as that user; as the login
user or root, git refuses with "dubious ownership" (do not add the `safe.directory` exception
it suggests, and do not pull as root, which leaves root-owned files in the service user's tree).

```
sudo -u yt-controller git -C /opt/yt-ci-infra pull
cd /opt/yt-controller && sudo -u yt-controller ~yt-controller/.local/bin/uv sync --no-dev
sudo systemctl restart yt-controller
```

Skip the `uv sync` and restart when only docs or worker files changed.

If a systemd unit changed: copy it to `/etc/systemd/system/` and `systemctl daemon-reload` first.

## Worker

### Stop and start the runner

`yt-runner.service` is the only unit on the worker. It starts at every boot (so at every
unshelve), mounts the two volumes, registers one single-use GitHub runner, takes one job, and
restarts itself for the next. Stop it when you need the worker up but must not have a dispatched
job land on it: the manual baseline run, or anything else that writes to the answers volume.
Stop the controller first ("Stop and start the controller") or the worker gets shelved under you.

```
sudo systemctl stop yt-runner
systemctl is-active yt-runner                      # inactive
```

The stop sends SIGINT, which the runner answers by deregistering from GitHub; it can take up
to `TimeoutStopSec` (5 min) if a job is mid-flight, so stop it only when nothing is running.
The mounts are made by the service's `ExecStartPre` and survive the stop, so `/mnt/yt-data`
and `/mnt/yt-answers` stay usable. If you remounted `yt-data` read-write while the runner was
down, the next start puts it back to read-only.

```
sudo systemctl start yt-runner
systemctl is-active yt-runner                      # active
journalctl -u yt-runner -n 20                      # "mounted: ..." then the listener waiting for a job
```

Or skip the start and shelve the worker instead; the service runs at the next unshelve anyway.
Stop, not disable: `disable` would keep the runner from coming up at the next unshelve, and
the controller would wake a worker that never registers.

### Runner lifecycle on the worker

`yt-runner.service` fetches a single-use config, takes one job, exits, and restarts itself to
fetch the next. So an ACTIVE worker normally has one idle runner registered and waiting; that
is not a fault. The controller shelves the instance once nothing has been queued or busy for
`GRACE_SECONDS`, which kills the idle runner; GitHub drops the dead registration on its own.
Small race: a job dispatched in the seconds between the shelve decision and the kill fails
and must be re-run. Acceptable for v1.

If the config fetch fails (controller down, security group wrong), the service exits non-zero
and stays down until the next unshelve. `journalctl -u yt-runner` on the worker says why.

### Update the worker scripts

The worker has its own checkout at `/opt/yt-ci-infra`, owned by the login user. `provision.sh`
is safe to re-run and is the simplest way to install a changed `boot-runner.sh`, unit file, or
`/etc/yt-runner/env` (it rewrites that file). Do it with the controller stopped ("Stop and start
the controller") and the worker unshelved by hand, so nothing shelves it or dispatches a job
mid-provision.

`provision.sh` needs `CONTROLLER_URL`, which the previous provision already wrote to the worker's
env file. Read it from there rather than looking up the controller's private IP again:

```
sudo cat /etc/yt-runner/env                      # CONTROLLER_URL, YT_TEST_DATA_DIR, YT_ANSWERS_DIR
cd /opt/yt-ci-infra && git pull
sudo CONTROLLER_URL=$(sudo grep '^CONTROLLER_URL=' /etc/yt-runner/env | cut -d= -f2-) ./worker/provision.sh
sudo cat /etc/yt-runner/env                      # same three variables; nothing stale left over
```

For a change to `boot-runner.sh` alone, `sudo install -m 0755 worker/boot-runner.sh /opt/yt-runner/`
and restart `yt-runner.service` (or just shelve; it runs at every boot).

### Rebuild the worker from clean

Reasons: a job left the root disk in a bad state, a runner-version bump, or periodic hygiene
(the worker runs maintainer-approved but still third-party code with network access).

```
openstack server unshelve yt-worker         # if shelved
openstack server remove volume yt-worker yt-data
openstack server remove volume yt-worker yt-answers
openstack server delete yt-worker
IMAGE=... ./infra/create.sh                  # recreates only the missing worker, re-attaches volumes
# then clone the repo and run worker/provision.sh as in deploy.md steps 2 and 3, and shelve
```

The volumes are untouched by this. Alternative with less downtime: snapshot the provisioned
worker once (`openstack server image create yt-worker --name yt-worker-golden`) and rebuild from
that image instead of re-provisioning. TODO: decide after the first rebuild whether the snapshot
is worth maintaining.

## Answer tests

### Answer stores: baselines and bumps

The answers volume is always mounted read-write. There is no read-only mode: yt's answer plugin
opens a store with `shelve.open` in its default create mode, which needs write access even to
compare (gdbm refuses to open an existing file read-write on a read-only filesystem). The guard
against untrusted code writing a baseline is that the workflow runs only on `workflow_dispatch`,
which GitHub restricts to users with write access, the same trust the Jenkins box ran on.

Writing a store is opt-in per dispatch: the `store_missing` input (default off; `--store-missing`
or `YT_STORE_MISSING=true` for `nose_runner.py` by hand). What a run does with stores, per
group (`yt-side/nose_runner.py`):

- Store exists (`<answers>/<py3XX_group>/<py3XX_group>*`): compare against it. Nothing is written.
- No store: run the group once with `--answer-store`. That pass is the only way to find out
  whether the group's datasets are on the volume, so it runs whatever `store_missing` is. Then:
  - It writes a store and `store_missing` is on: compare against it. The log and the job summary
    end with `STORED new answers (N): ...` naming every group this run generated.
  - It writes a store and `store_missing` is off: the store is discarded and the group fails,
    with a log line saying to dispatch again with `store_missing` to accept it. The group's
    runtime was spent once for nothing; that is the cost of the forgotten checkbox, and the
    re-dispatch is the approval.
  - It writes no file: a dataset in the group is missing. The runner turns on yt's
    `internals.strict_requires` before forking its workers, so a missing dataset is a
    collection error that taints the results and suppresses the dump, instead of a silent skip
    that writes an empty or partial store. The group is skipped, not failed, and the run ends
    with `SKIPPED, datasets missing (N): ...`. Seed the data (see "Dataset pre-flight") and it
    stores on the next dispatch with `store_missing`. A skipped group says nothing about the
    ref, so keep that list short. With `groups` blank a skip is not a failure; with `groups`
    naming the skipped group the run fails, so the usual new-frontend case (new group, data not
    seeded yet, dispatched by name) is red on the PR instead of a skip only the log mentions.
  - It fails: the group fails and its directory is removed, so the next run tries again instead
    of comparing against an empty or partial store forever. The compare pass is not run.

**Bumping answers** is the yt convention: increment the group's suffix in `tests/tests.yaml`
(`local_art_004` to `local_art_005`) in the PR that changes the answers. The new name has no
store. Review the diff, then dispatch the PR with `store_missing` on: that generates the store
from the PR's code and the compare pass is trivially green. Dispatching without it fails the
bumped group and keeps nothing, so a maintainer testing a PR never approves a baseline by
accident. The old store stays on the volume, so reverting the bump reverts the baseline. A store
generated by mistake is undone by deleting its directory on the worker; the next dispatch with
`store_missing` regenerates it.

**Baseline** (empty volume, or a new Python prefix): dispatch with `groups` blank and
`store_missing` on from a trusted ref. Every group stores and compares. Groups with missing
datasets are skipped and leave nothing behind; seed the data and dispatch those groups again
with `store_missing`. If the trusted ref predates the harness files, dispatch cannot check it
out as-is; see "Manual baseline run" below.

**Snapshot** the volume after the baseline and after each bump, so a bad store or a broken PR
with write access can be rolled back without regenerating everything:

```
openstack volume snapshot create --volume yt-answers --force yt-answers-$(date +%F)
```

`--force` because the volume is attached to the (shelved) worker. Old snapshots can be deleted
once a later one exists.

Shelve files are dbm-backend dependent: generate stores on the worker, never copy from a laptop.

### Manual baseline run (outside the workflow)

Use this when the trusted ref predates the harness, which is the case for the first baseline:
the last known good commit is `66af53cedb7af599faf3c2471bcd380d961e37a6` (merge of PR #5143,
2025-03-24, the final green Jenkins build), and at that SHA `tests/ci_install.sh` is the pip-era
script, `pyproject.toml` has no `nosetest` dependency group, and `tests/nose_runner.py` detects
stores by directory (never matches a shelve file) and always exits 0. Dispatching `ref=66af53c`
checks out all of that and fails at the install step. Running by hand on the worker sidesteps
the dispatch requirements too (workflow file on the dispatch branch, SHA reachable from
yt-project/yt): only the store files matter, and they are the same files either way.

**1. Build the branch (laptop).** yt's code at the trusted ref, the harness files on top:

```
git checkout -b last-known-jenkins-pass-66af53c 66af53cedb7af599faf3c2471bcd380d961e37a6
git checkout <harness-branch> -- tests/nose_runner.py tests/ci_install.sh tests/tests.yaml
```

Then add the `nosetest` block under `[dependency-groups]` in `pyproject.toml` by hand (copy the
seven lines from the harness branch; `[dependency-groups]` itself does not exist at this SHA
either). Do not take the whole `pyproject.toml` or `uv.lock`: those carry every dependency change
since the ref. Commit and push the branch to your fork. The two extra `tests.yaml` lines are
`--ignore-file` entries for the unittests job; harmless if the files do not exist.

**2. Keep the worker up, and alone.** On the controller, stop both units ("Stop and start the
controller"), then unshelve:

```
sudo systemctl stop yt-controller-idle-shelver.timer yt-controller
cd /opt/yt-controller && sudo -u yt-controller env $(sudo grep -E '^[A-Z_]+=' /etc/yt-controller/env) .venv/bin/yt-controller unshelve
```

Both shelvers decide "idle" from GitHub (queued jobs, runner busy), so a run outside the runner
looks idle and the VM is shelved under it after `IDLE_SHELVE_SECONDS`. On the worker, once it is
up:

```
sudo systemctl stop yt-runner
mountpoint /mnt/yt-data && mountpoint /mnt/yt-answers && ls -ld /mnt/yt-answers/answers
```

Stopping the runner ("Stop and start the runner") guarantees no dispatched job writes stores at
the same time. The mounts survive the stop; the answers directory must be owned by `runner`.

Then put the datasets volume in write mode for the run:

```
sudo mount -o remount,rw /mnt/yt-data
sudo chown -R runner /mnt/yt-data
```

yt writes side files next to some datasets the first time it loads them: smoothing lengths
for SPH data (`TipsyGalaxy/galaxy.00300-hsml`, `snipshot_399_z000p000/*.hsml.hdf5`). On the
read-only mount those loads raise `OSError: Read-only file system`, which fails the tipsy group
and several unittests. The remount alone is not enough: root's `tar` keeps the tarball's
owner, so the tree is not writable by `runner` until the chown. Both are undone by the next
boot, which mounts the volume read-only (`worker/boot-runner.sh`); the side files stay, and
later runs only read them.

**3. Run as `runner`, in tmux.** Store files are owned by whoever writes them and the dbm format
is the interpreter's, so this has to be the runner user with its own uv and Python 3.10, not
`ubuntu`:

```
sudo -iu runner
tmux new -s baseline
. /etc/yt-runner/env
export PATH="$HOME/.local/bin:$PATH" MPLCONFIGDIR=tests
git clone --recurse-submodules --branch last-known-jenkins-pass-66af53c https://github.com/chrishavlin/yt ~/baseline
cd ~/baseline
sync_args="--extra=full --group=nosetest" UV_PYTHON=3.10 YT_CI_SKIP_SYSTEM_DEPS=1 source tests/ci_install.sh
find .venv/lib/python3.10/site-packages/nose -name '*.py' -exec sed -i -e 's/collections.Callable/collections.abc.Callable/g' '{}' ';'
uv run --no-sync yt config set --local yt test_data_dir "$YT_TEST_DATA_DIR"
uv run --no-sync yt config set --local yt supp_data_dir "$YT_TEST_DATA_DIR/supp_data"
export NUM_WORKERS=$(( $(nproc) > 2 ? $(nproc) - 2 : 1 ))
uv run --no-sync python tests/nose_runner.py --no-unittests --store-missing 2>&1 | tee ~/baseline-$(date +%F).log
```
This is the workflow's job, step for step, minus the xunit upload and commit status.
`--no-unittests` skips the `other_tests` job, which writes no stores; drop the flag to also get
a unittest result for the ref. Every group runs twice (store, then compare), so expect the run
to take about twice as long as a normal compare run. Detach with `Ctrl-b` then `d`.

**4. Check, snapshot, restore.** The log ends with `STORED new answers (N): ...`, a
`SKIPPED, datasets missing (N): ...` line if any group had no data, and either
`all nose runs passed` or `FAILED (N): ...`. A skipped or failed group left nothing behind. For
the skipped ones, find which datasets (the grep in "Dataset pre-flight"), seed them, and rerun
just those groups with `--groups a,b --store-missing` from the same shell. Then:

```
ls /mnt/yt-answers/answers            # one py310_<group> directory per answer_tests key, owned by runner
openstack volume snapshot create --volume yt-answers --force yt-answers-$(date +%F)
```

Restore the services: on the worker `sudo mount -o remount,ro /mnt/yt-data` (the next boot
does this anyway), then start the runner ("Stop and start the runner"), or just
shelve it with the full `yt-controller shelve` form from "Force a shelve / unshelve", which the
next unshelve boots clean; then on the controller start both units ("Stop and start the
controller"). The clone
under `~runner/baseline` can be deleted; the `.venv` in it is not reused by jobs.

### Dataset pre-flight

With `strict_requires` on (the runner sets it), a missing dataset errors at collection and
the group writes no store; the run reports it under `SKIPPED, datasets missing`. With it off,
yt's default, the test silently skips and an empty or partial store is written, which would
then be the baseline. So `infra/datasets.json` has to be right before the first baseline run.
A group that already has a store and loses a dataset (or gains a test whose data is not
seeded) fails its compare pass for the same reason, rather than skipping green. It is a list, one entry per file to download from
https://yt-project.org/data/:

```json
{"datafile": "ExodusII_tests.tar.gz", "note": "unpacks to ExodusII"}
{"datafile": "grs-50-cube.fits.gz", "unpack_to": "radio_fits", "note": "bare file on the site"}
```

`datafile` is the file name, fetched from `https://yt-project.org/data/<datafile>` unless
`url` gives a full download URL instead, for files that never reached the server. `unpack_to`
is a directory under the volume root to unpack into, for the few files that are not a tarball
of one top-level directory; omitted, the file unpacks at the root. `note` is free text. `infra/seed-data-volume.sh` extracts
tarballs, gunzips any other `.gz`, keeping the compressed copy (one FITS test wants the
`.fits.gz`, another wants the `.fits`), and copies anything else as-is. The list is copied to the worker alongside the
seeding script (`deploy.md` step 2) and is the input to both `fetch` and `verify`.

Two kinds of entry are not datasets. The x-ray emissivity tables (`*_emissivity_v*.h5`) go
under `supp_data/`: yt looks for them in its `supp_data_dir` config key, not the test data
dir, so every place that sets `test_data_dir` also sets `supp_data_dir` to
`$YT_TEST_DATA_DIR/supp_data` (the workflow, the manual run above, `yt-side/README.md`).
`owls_ion_data.tar.gz` is a table yt would otherwise download into the test data dir on the
first OWLS or EAGLE load, which the read-only mount refuses.

**DD0010 is not on the server.** The enzo and pw groups, the cookbook and several unittests
load `DD0010/moving7_0010`, which ships inside the yt repo under `tests/DD0010`. yt resolves a
dataset name against the current directory and then `test_data_dir`, and the job runs from
the repo root, so the copy in `tests/` is never found. Copy it onto the volume once, from any
yt checkout on the worker (the baseline clone, or a job's work tree):

```
sudo mount -o remount,rw /mnt/yt-data
sudo cp -r <checkout>/tests/DD0010 /mnt/yt-data/ && sudo chmod -R a+rX /mnt/yt-data/DD0010
sudo mount -o remount,ro /mnt/yt-data
```

`verify` does not know about it; check `ls /mnt/yt-data/DD0010` by hand.

**Keeping it current.** The normal path is incremental. After a run, look for datasets the
suite wanted and did not find. `requires_file` skips with a reason naming the file;
`requires_ds` under `strict_requires` raises `FileNotFoundError` naming the path at import,
so only the first missing dataset per test module shows up per run:

```
grep -hoE "Missing required file [^ ]+|No such file or directory: '[^']+'" <run log> | sort -u
```

Find the tarball on the data page, add an entry, re-run `fetch` on the worker (it skips what
is already seeded). Also re-check the "known gaps" list below.

**Rebuilding from scratch** (laptop, how the 2026-11-03 list was made; the first-run skip
check above is the safety net for anything this misses):

1. Names the tests reference: every string literal in `yt/**/test_*.py`, and every `load`
   argument in `doc/source/cookbook/*.py` (the cookbook job runs each recipe; the first list
   missed seven tarballs this way), first path component. Grep the literals rather than the
   `requires_ds` / `requires_file` calls; most go through a module-level constant. `DD0010`
   ships with yt in `tests/` and is copied by hand (above), not fetched.
2. The site manifest: `curl -sL https://yt-project.org/data/datafiles.json`. The data page is
   rendered from it. Use each entry's `url`; the `filename` field is a display name and differs
   from the URL basename in a few cases.
3. What each tarball unpacks to, without downloading it: `curl -sL <url> | tar tzf - | head -1`
   reads the first gzip block and drops the connection. About ten tarballs unpack to a name
   other than their stem, two unpack to a bare file.
4. Match step 1 against step 3. Each match is an entry. A test name with no match is inside a
   tarball under another name (step 3 shows it), a bare file on the site (write `unpack_to`),
   or not in the manifest at all. For the last case, search the website repo's pull requests
   for the name: datasets arrive through a companion PR there, and the file often sits on the
   server unlisted, or only as an attachment on the PR (write `url`).
5. `curl -sI` each URL once. The manifest has carried dead links.

The manifest is not the server. `yt upload` (use.yt) has returned 500s for years, so files
reach the server unevenly. The rule for what goes in the list: anything in the manifest, plus
anything a website PR added that never got copied to the server (`url` entries: the two
boxlib files attached to PR 129, `riot_sedov_curvlinear` from the author's share on PR 141,
`quokka` attached to PR 142), plus files that are on the server but were never in the
manifest (`no_fields`, `no_particles`, `singleParticle`, uploaded for yt PR 1645). Not
anything a website PR deliberately removed from the manifest, since the old Jenkins runner
fetched what the manifest listed and removal was a decision.

Known gaps as of 2026-11-03, all tests that skip:

- amrvac. The tests load `amrvac/bw_2d0000.dat` and friends, the layout of the pre-2021
  tarballs (`amrvac_*.tar.gz`, no longer on the server). Website PR 97 replaced those
  manifest entries with nine per-run tarballs (`bw_polar_2d.tar.gz`, `kh2d.tar.gz`,
  `riemann1d.tar.gz` and so on, about 40 MB in all, on the server but not in the list) that
  unpack to different names and files, and the tests were never updated to match. The fix is
  in the yt tests; add the nine entries when it lands. Until then the amrvac group skips, and
  the amrvac units-override unittests and one plot-modifications unittest error.
- `output_00080_new_halos` (AdaptaHOP, website PR 109): its only copy was on use.yt and is
  gone.

**Permissions.** Everything on the volume must be world-readable and directories world-
searchable (`a+rX`): the runner user reads it, root seeded it, and tarball modes are preserved
by root's `tar`. The seed script applies `chmod -R a+rX` per entry; a volume seeded before that
was added, or anything copied on by hand, needs it run once over the whole mount with the
volume remounted read-write:

```
sudo mount -o remount,rw /mnt/yt-data && sudo chmod -R a+rX /mnt/yt-data && sudo mount -o remount,ro /mnt/yt-data
```

**Verifying the volume (worker).** After seeding, and again before any baseline run:

```
cd /opt/yt-ci-infra && sudo ./infra/seed-data-volume.sh verify infra/datasets.json
```

### Change the Python version the suite runs on

Starting point is 3.10 because that is what the last Jenkins run used. The ceiling for the
nose suite is **3.11**: nose 1.3.7's `importer.py` does `from imp import ...`, and `imp` was
removed in Python 3.12. Beyond that means the pytest migration, not a version bump.

Preferred order is pytest first, then 3.11, so the store regeneration below never has to
happen for nose. Whether that holds depends on dev time against yt 4.5.0, which drops 3.10
support: if 4.5.0 lands while the suite is still on nose, the worker has to move to 3.11 to
test `main` at all, and the procedure below is the cost of that.

The version is wired in three places, plus one consequence on the answers volume:

| where | what |
|-------|------|
| `worker/provision.sh` | `uv python install 3.10` puts the interpreter on the worker. Add the new one (keep the old until its stores are retired): `sudo -u runner ~runner/.local/bin/uv python install 3.11` on the live worker, and bump the script for the next rebuild. |
| yt: `.github/workflows/answer-tests.yml` | `PYTHON_VERSION` job env. Drives `UV_PYTHON` for `ci_install.sh` and the path of the nose patch (`.venv/lib/python3.X/site-packages/nose`). Reference copy: `yt-side/answer-tests.yml`. |
| yt: `.github/workflows/build-test.yaml` | the nose jobs pin `python-version: '3.10'`. Not required for the worker, but keep them in step so one version of nose is in use. |
| answers volume | `nose_runner.py` prefixes every store with the interpreter version: `py310_local_art_004` becomes `py311_local_art_004`. Nothing carries over. Every group is a missing store under the new prefix. |

That last row is the real cost. The procedure:

1. Pick a trusted ref (a green run on the current version, or the last-known-good commit).
2. Dispatch with `ref=<trusted>`, `store_missing` on, and the new `PYTHON_VERSION`: a one-line
   change to the job env in `.github/workflows/answer-tests.yml` on the ref you dispatch from.
   Every group generates under the new prefix; compare pass runs against its own output and
   should be green. Snapshot the volume.
3. Dispatch `main` on the new version. Differences here are interpreter or
   dependency effects (a different numpy wheel resolves for 3.11), not code drift. Triage
   before merging the version bump into the yt repo.
4. Merge the bump in yt. The old `py310_*` directories on the volume are dead weight; delete
   them once nobody needs to compare against the old version (or wipe the whole volume with
   `infra/seed-answers-volume.sh format` and regenerate; it never touches the datasets).

Both prefixes can coexist on the volume, so there is no cut-over moment: a PR that bumps the
version just runs against the new stores, and a PR that does not still runs against the old.

## Known gotchas

- The controller's floating IP is stable as long as the controller is never shelved: Jetstream2
  reclaims floating IPs from instances shelved more than 45 days. Safe to hard-code in your SSH
  config. If SSH ever stops resolving, check in Horizon (Network → Floating IPs) that the
  address is still associated. Background in `infra/networking.md`.
- Unshelve takes 1–3 min; polling adds up to `POLL_SECONDS`. A queued job sits for a few minutes
  before the runner appears. That is expected.
- JIT configs expire in about an hour and are single-use. If the worker boots but the runner
  never appears, check `journalctl -u yt-runner` on the worker and `journalctl -u yt-controller`
  for `generate-jitconfig failed` (usually a token permission problem).
- Usage reporting to ACCESS (the NSF program that allocates Jetstream2 time) lags 12–24 h;
  `openstack` status is the source of truth for whether the worker is burning service units
  (SUs) right now.
