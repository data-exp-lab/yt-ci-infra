"""Backstop against a stuck reconciler: shelve a worker that has been ACTIVE and idle too long.

Deliberately does not import `reconcile` or share its state file. Idle time comes from the
OpenStack server record's `updated_at`, which changes on every status transition, so an
unshelve resets the clock without any cooperation from the reconciler. If GitHub cannot be
queried the worker is treated as unwanted: jobs cannot be dispatched without GitHub either,
and shelving is the cheap failure mode.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from .config import Settings
from .github import GitHub
from .openstack import OpenStack

log = logging.getLogger(__name__)


def should_shelve(status: str, wanted: bool, idle_seconds: float, limit: float) -> bool:
    return status.upper() == "ACTIVE" and not wanted and idle_seconds > limit


def run(settings: Settings, gh: GitHub, os_: OpenStack, dry_run: bool = False) -> bool:
    status = os_.status()
    idle = (datetime.now(timezone.utc) - os_.updated_at()).total_seconds()
    try:
        wanted = gh.queued_jobs(settings.runner_label) > 0 or gh.runner_busy(settings.runner_label)
    except Exception:
        log.exception("GitHub unreachable; treating worker as unwanted")
        wanted = False
    shelve = should_shelve(status, wanted, idle, settings.idle_shelve_seconds)
    log.info(
        "worker=%s wanted=%s idle=%.0fs -> %s", status, wanted, idle, "shelve" if shelve else "none"
    )
    if shelve and not dry_run:
        os_.shelve()
    return shelve
