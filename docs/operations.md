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

## Is it healthy?

```
yt-controller status
openstack server show yt-worker -c status -c updated_at
gh api repos/$GITHUB_REPO/actions/runners --jq '.runners[] | {name, status, busy}'
```

Shelved worker + no queued jobs + no runners is the normal resting state.

## Force a shelve / unshelve

```
yt-controller shelve      # waits for SHELVED_OFFLOADED
yt-controller unshelve    # waits for ACTIVE; the worker boots and fetches a runner config
```

Or `openstack server shelve|unshelve yt-worker`. Never `stop` or `suspend`: those bill at 50% and
75% respectively. Shelved bills zero.

If the controller is misbehaving, `systemctl stop yt-controller` first so it does not fight you.
The idle shelver timer keeps running and will shelve an idle worker after `IDLE_SHELVE_SECONDS`;
stop `yt-controller-idle-shelver.timer` too if you need the worker up for interactive work.

## Rotate the GitHub token

1. Mint the new token (same permissions: Administration r/w, Actions read, scoped to the repo).
2. Edit `GITHUB_TOKEN` in `/etc/yt-controller/env`.
3. `systemctl restart yt-controller`; check `yt-controller status` works.
4. Revoke the old token on GitHub.

Nothing on the worker changes: it never holds the token, only one-shot just-in-time (JIT)
runner configs.

## Rotate the OpenStack application credential

1. Horizon → Identity → Application Credentials → create a new one, download `clouds.yaml`.
2. Replace `~yt-controller/.config/openstack/clouds.yaml` (mode 600, owned by `yt-controller`).
3. `systemctl restart yt-controller`; `yt-controller status` must show the worker.
4. Delete the old credential in Horizon.

## Answer stores: baselines and bumps

The answers volume is always mounted read-write. There is no read-only mode: yt's answer plugin
opens a store with `shelve.open` in its default create mode, which needs write access even to
compare (gdbm refuses to open an existing file read-write on a read-only filesystem). The guard
against untrusted code writing a baseline is the `authorize` job in the workflow, which only lets
maintainers dispatch, the same trust the Jenkins box ran on.

What a run does with stores, per group (`yt-side/nose_runner.py`):

- Store exists (`<answers>/<py3XX_group>/<py3XX_group>*`): compare against it. Nothing is written.
- No store: run the group once with `--answer-store`, then compare. The log and the job summary
  end with `STORED new answers (N): ...` naming every group this run generated.
- Store pass fails, or writes no file (yt skips the dump when a dataset is missing): the group
  fails and its directory is removed, so the next run tries again instead of comparing against
  an empty or partial store forever. The compare pass is not run.

**Bumping answers** is the yt convention: increment the group's suffix in `tests/tests.yaml`
(`local_art_004` to `local_art_005`) in the PR that changes the answers. The new name has no
store, so the first maintainer dispatch on that PR generates it from the PR's code and the
compare pass is trivially green. Review the diff before dispatching; that is the approval step.
The old store stays on the volume, so reverting the bump reverts the baseline. A store generated
by mistake is undone by deleting its directory on the worker; the next run regenerates it.

**Baseline** (empty volume, or a new Python prefix): dispatch with `groups` blank from a trusted
ref. Every group stores and compares. Groups with missing datasets fail and leave nothing behind;
fix the data and dispatch those groups again. If the trusted ref predates the harness files,
dispatch cannot check it out as-is; see "Manual baseline run" below.

**Snapshot** the volume after the baseline and after each bump, so a bad store or a broken PR
with write access can be rolled back without regenerating everything:

```
openstack volume snapshot create --volume yt-answers --force yt-answers-$(date +%F)
```

`--force` because the volume is attached to the (shelved) worker. Old snapshots can be deleted
once a later one exists.

Shelve files are dbm-backend dependent: generate stores on the worker, never copy from a laptop.

## Manual baseline run (outside the workflow)

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
git checkout -b baseline-66af53c 66af53cedb7af599faf3c2471bcd380d961e37a6
git checkout <harness-branch> -- tests/nose_runner.py tests/ci_install.sh tests/tests.yaml
```

Then add the `nosetest` block under `[dependency-groups]` in `pyproject.toml` by hand (copy the
seven lines from the harness branch; `[dependency-groups]` itself does not exist at this SHA
either). Do not take the whole `pyproject.toml` or `uv.lock`: those carry every dependency change
since the ref. Commit and push the branch to your fork. The two extra `tests.yaml` lines are
`--ignore-file` entries for the unittests job; harmless if the files do not exist.

**2. Keep the worker up, and alone.** On the controller:

```
sudo systemctl stop yt-controller-idle-shelver.timer yt-controller
yt-controller unshelve
```

Both shelvers decide "idle" from GitHub (queued jobs, runner busy), so a run outside the runner
looks idle and the VM is shelved under it after `IDLE_SHELVE_SECONDS`. On the worker, once it is
up:

```
sudo systemctl stop yt-runner
mountpoint /mnt/yt-data && mountpoint /mnt/yt-answers && ls -ld /mnt/yt-answers/answers
```

Stopping the runner guarantees no dispatched job writes stores at the same time. The mounts are
made by the service's `ExecStartPre` and survive stopping it; the answers directory must be
owned by `runner`.

**3. Run as `runner`, in tmux.** Store files are owned by whoever writes them and the dbm format
is the interpreter's, so this has to be the runner user with its own uv and Python 3.10, not
`ubuntu`:

```
sudo -iu runner
tmux new -s baseline
. /etc/yt-runner/env
export PATH="$HOME/.local/bin:$PATH" MPLCONFIGDIR=tests
git clone --recurse-submodules --branch baseline-66af53c https://github.com/<fork>/yt ~/baseline
cd ~/baseline
sync_args="--extra=full --group=nosetest" UV_PYTHON=3.10 YT_CI_SKIP_SYSTEM_DEPS=1 source tests/ci_install.sh
find .venv/lib/python3.10/site-packages/nose -name '*.py' -exec sed -i -e 's/collections.Callable/collections.abc.Callable/g' '{}' ';'
uv run --no-sync yt config set --local yt test_data_dir "$YT_TEST_DATA_DIR"
export NUM_WORKERS=$(( $(nproc) > 2 ? $(nproc) - 2 : 1 ))
uv run --no-sync python tests/nose_runner.py --no-unittests 2>&1 | tee ~/baseline-$(date +%F).log
```

This is the workflow's job, step for step, minus the xunit upload and commit status.
`--no-unittests` skips the `other_tests` job, which writes no stores; drop the flag to also get
a unittest result for the ref. Every group runs twice (store, then compare), so expect the run
to take about twice as long as a normal compare run. Detach with `Ctrl-b` then `d`.

**4. Check, snapshot, restore.** The log ends with `STORED new answers (N): ...` and either
`all nose runs passed` or `FAILED (N): ...`. For each failed group, look for the missing-dataset
skips (the grep in "Dataset pre-flight"); a group that failed left nothing behind, so after
fixing the data rerun just those groups with `--groups a,b` from the same shell. Then:

```
ls /mnt/yt-answers/answers            # one py310_<group> directory per answer_tests key, owned by runner
openstack volume snapshot create --volume yt-answers --force yt-answers-$(date +%F)
```

Restore the services (controller: `systemctl start yt-controller yt-controller-idle-shelver.timer`;
worker: `systemctl start yt-runner`, or just `yt-controller shelve`, which the next unshelve boots
clean). The clone under `~runner/baseline` can be deleted; the `.venv` in it is not reused by
jobs.

## Change the Python version the suite runs on

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
2. Dispatch with `ref=<trusted>` and the new `PYTHON_VERSION`: a one-line change to the job
   env in `.github/workflows/answer-tests.yml` on the ref you dispatch from. Every group generates under the
   new prefix; compare pass runs against its own output and should be green. Snapshot the volume.
3. Dispatch `main` on the new version. Differences here are interpreter or
   dependency effects (a different numpy wheel resolves for 3.11), not code drift. Triage
   before merging the version bump into the yt repo.
4. Merge the bump in yt. The old `py310_*` directories on the volume are dead weight; delete
   them once nobody needs to compare against the old version (or wipe the whole volume with
   `infra/seed-answers-volume.sh format` and regenerate; it never touches the datasets).

Both prefixes can coexist on the volume, so there is no cut-over moment: a PR that bumps the
version just runs against the new stores, and a PR that does not still runs against the old.

## Dataset pre-flight

The answer framework silently skips writing a store if any dataset in the group is missing,
which looks like a store that never appears. So `infra/datasets.json` has to be right before
the first baseline run. It is a list, one entry per file to download from
https://yt-project.org/data/:

```json
{"datafile": "ExodusII_tests.tar.gz", "note": "unpacks to ExodusII"}
{"datafile": "grs-50-cube.fits.gz", "unpack_to": "radio_fits", "note": "bare file on the site"}
```

`datafile` is the file name, fetched from `https://yt-project.org/data/<datafile>` unless
`url` gives a full download URL instead, for files that never reached the server. `unpack_to`
is a directory under the volume root to unpack into, for the few files that are not a tarball
of one top-level directory; omitted, the file unpacks at the root. `note` is free text. `infra/seed-data-volume.sh` extracts
tarballs and gunzips anything else, keeping the compressed copy (one FITS test wants the
`.fits.gz`, another wants the `.fits`). The list is copied to the worker alongside the
seeding script (`deploy.md` step 2) and is the input to both `fetch` and `verify`.

**Keeping it current.** The normal path is incremental. After a run, look for datasets the
suite wanted and did not find; both decorators skip with a reason that names the dataset:

```
grep -hoE "(cannot load dataset|Missing required file) [^ ]+" <run log> | sort -u
```

Find the tarball on the data page, add an entry, re-run `fetch` on the worker (it skips what
is already seeded). Also re-check the "known gaps" list below.

**Rebuilding from scratch** (laptop, how the 2026-11-03 list was made; the first-run skip
check above is the safety net for anything this misses):

1. Names the tests reference: every string literal in `yt/**/test_*.py`, first path
   component. Grep the literals rather than the `requires_ds` / `requires_file` calls; most
   go through a module-level constant. Drop `DD0010`, which ships with yt in `tests/`.
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
  tarballs (`amrvac_*.tar.gz`, still on the server). Website PR 97 replaced those manifest
  entries with per-run tarballs (`bw_polar_2d.tar.gz` and so on, in the list) that unpack to
  different names and files, and the tests were never updated to match. Deliberately not
  added; the fix is in the yt tests.
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


## Rebuild the worker from clean

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

## Update the controller code

```
cd /opt/yt-ci-infra && sudo git pull
cd controller && sudo -u yt-controller ~yt-controller/.local/bin/uv sync --no-dev
sudo systemctl restart yt-controller
```

If a systemd unit changed: copy it to `/etc/systemd/system/` and `systemctl daemon-reload` first.

## Update the worker scripts

The worker has its own checkout at `/opt/yt-ci-infra`, owned by the login user. `provision.sh`
is safe to re-run and is the simplest way to install a changed `boot-runner.sh`, unit file, or
`/etc/yt-runner/env` (it rewrites that file):

```
cd /opt/yt-ci-infra && git pull
sudo CONTROLLER_URL=http://<controller private ip>:8080 ./worker/provision.sh
```

For a change to `boot-runner.sh` alone, `sudo install -m 0755 worker/boot-runner.sh /opt/yt-runner/`
and restart `yt-runner.service` (or just shelve; it runs at every boot).

## Runner lifecycle on the worker

`yt-runner.service` fetches a single-use config, takes one job, exits, and restarts itself to
fetch the next. So an ACTIVE worker normally has one idle runner registered and waiting; that
is not a fault. The controller shelves the instance once nothing has been queued or busy for
`GRACE_SECONDS`, which kills the idle runner; GitHub drops the dead registration on its own.
Small race: a job dispatched in the seconds between the shelve decision and the kill fails
and must be re-run. Acceptable for v1.

If the config fetch fails (controller down, security group wrong), the service exits non-zero
and stays down until the next unshelve. `journalctl -u yt-runner` on the worker says why.

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
