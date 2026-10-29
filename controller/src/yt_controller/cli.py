"""yt-controller command line."""

from __future__ import annotations

import argparse
import logging
import sys

from . import __version__, idle_shelver, reconcile, tokens
from .config import ConfigError, Settings
from .github import GitHub
from .openstack import OpenStack
from .state import State


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="yt-controller", description=__doc__)
    p.add_argument("--version", action="version", version=__version__)
    p.add_argument("-v", "--verbose", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="print GitHub queue, runner, and worker state")
    once = sub.add_parser("reconcile-once", help="one reconcile cycle")
    once.add_argument("--dry-run", action="store_true", help="decide but do not act")
    sub.add_parser("run", help="reconcile loop plus runner-config endpoint (the systemd service)")
    sub.add_parser("serve", help="runner-config endpoint only")
    shelver = sub.add_parser(
        "idle-shelver", help="shelve the worker if ACTIVE and idle past IDLE_SHELVE_SECONDS"
    )
    shelver.add_argument("--dry-run", action="store_true")
    sub.add_parser("shelve", help="shelve the worker now and wait")
    sub.add_parser("unshelve", help="unshelve the worker now and wait")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    try:
        settings = Settings.from_env()
    except ConfigError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    gh = GitHub(settings.github_repo, settings.github_token)
    os_ = OpenStack(settings.os_cloud, settings.worker_name)
    state = State(settings.state_file)

    if args.cmd == "status":
        obs = reconcile.observe(gh, os_, state, settings.runner_label)
        print(f"repo:    {settings.github_repo}")
        print(f"queued:  {obs.queued_jobs}")
        print(f"busy:    {obs.runner_busy}")
        print(f"worker:  {settings.worker_name} {obs.worker_status}")
        print(f"idle:    {'n/a' if obs.idle_seconds is None else f'{obs.idle_seconds:.0f}s'}")
        print(f"would:   {reconcile.decide(obs, settings.grace_seconds).value}")
    elif args.cmd == "reconcile-once":
        reconcile.run_once(settings, gh, os_, state, dry_run=args.dry_run)
    elif args.cmd == "run":
        tokens.serve(settings, gh, background=True)
        reconcile.run_forever(settings, gh, os_, state)
    elif args.cmd == "serve":
        tokens.serve(settings, gh)
    elif args.cmd == "idle-shelver":
        idle_shelver.run(settings, gh, os_, dry_run=args.dry_run)
    elif args.cmd == "shelve":
        os_.shelve()
        print(os_.wait_for({"SHELVED_OFFLOADED", "SHELVED", "ERROR"}))
    elif args.cmd == "unshelve":
        os_.unshelve()
        state.touch()
        print(os_.wait_for({"ACTIVE", "ERROR"}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
