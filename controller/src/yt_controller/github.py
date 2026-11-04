"""Minimal GitHub Actions client: queue depth, runner status, JIT runner configs."""

from __future__ import annotations

import time

import httpx

API = "https://api.github.com"


class GitHub:
    def __init__(self, repo: str, token: str, base_url: str = API, timeout: float = 20.0):
        self.repo = repo
        self._client = httpx.Client(
            base_url=base_url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            timeout=timeout,
        )

    def _get(self, path: str, **params) -> dict | list:
        r = self._client.get(path, params=params)
        r.raise_for_status()
        return r.json()

    def _post(self, path: str, json: dict) -> dict:
        r = self._client.post(path, json=json)
        r.raise_for_status()
        return r.json()

    def queued_jobs(self, label: str) -> int:
        """Count jobs waiting for a runner carrying `label`.

        A run whose first job finished and whose heavy job is waiting reports status
        in_progress, not queued, so both run states are scanned.
        """
        count = 0
        for status in ("queued", "in_progress"):
            runs = self._get(f"/repos/{self.repo}/actions/runs", status=status, per_page=50)
            for run in runs.get("workflow_runs", []):
                jobs = self._get(f"/repos/{self.repo}/actions/runs/{run['id']}/jobs", per_page=100)
                for job in jobs.get("jobs", []):
                    if job.get("status") == "queued" and label in job.get("labels", []):
                        count += 1
        return count

    def runner_busy(self, label: str) -> bool:
        """True if any registered runner carrying `label` is currently running a job."""
        data = self._get(f"/repos/{self.repo}/actions/runners", per_page=100)
        for runner in data.get("runners", []):
            labels = {lab["name"] for lab in runner.get("labels", [])}
            if label in labels and runner.get("busy"):
                return True
        return False

    def generate_jitconfig(self, label: str, name: str | None = None) -> dict:
        """Mint a single-use ephemeral runner config. Needs repo Administration write.

        JIT runners carry only the labels requested here; the `self-hosted` label that
        config.sh adds by default is not implied, and the workflow's runs-on names both.
        """
        name = name or f"yt-worker-{int(time.time())}"
        data = self._post(
            f"/repos/{self.repo}/actions/runners/generate-jitconfig",
            json={
                "name": name,
                "runner_group_id": 1,
                "labels": ["self-hosted", label],
                "work_folder": "_work",
            },
        )
        return {"runner_name": name, "encoded_jit_config": data["encoded_jit_config"]}
