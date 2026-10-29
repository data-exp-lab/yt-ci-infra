"""Settings loaded from the environment (systemd EnvironmentFile=/etc/yt-controller/env)."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path


class ConfigError(RuntimeError):
    pass


@dataclass(frozen=True)
class Settings:
    github_repo: str
    github_token: str
    os_cloud: str = "jetstream"
    worker_name: str = "yt-worker"
    runner_label: str = "jetstream"
    grace_seconds: int = 300
    poll_seconds: int = 45
    idle_shelve_seconds: int = 1200
    token_bind: str = "0.0.0.0"
    token_port: int = 8080
    state_file: Path = Path("/var/lib/yt-controller/state.json")

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        env = os.environ if env is None else env
        missing = [k for k in ("GITHUB_REPO", "GITHUB_TOKEN") if not env.get(k)]
        if missing:
            raise ConfigError(f"missing required settings: {', '.join(missing)}")
        if "/" not in env["GITHUB_REPO"]:
            raise ConfigError("GITHUB_REPO must be owner/name")
        return cls(
            github_repo=env["GITHUB_REPO"],
            github_token=env["GITHUB_TOKEN"],
            os_cloud=env.get("OS_CLOUD", cls.os_cloud),
            worker_name=env.get("WORKER_NAME", cls.worker_name),
            runner_label=env.get("RUNNER_LABEL", cls.runner_label),
            grace_seconds=int(env.get("GRACE_SECONDS", cls.grace_seconds)),
            poll_seconds=int(env.get("POLL_SECONDS", cls.poll_seconds)),
            idle_shelve_seconds=int(env.get("IDLE_SHELVE_SECONDS", cls.idle_shelve_seconds)),
            token_bind=env.get("TOKEN_BIND", cls.token_bind),
            token_port=int(env.get("TOKEN_PORT", cls.token_port)),
            state_file=Path(env.get("STATE_FILE", str(cls.state_file))),
        )
