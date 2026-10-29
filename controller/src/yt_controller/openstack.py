"""Shelve / unshelve one named server via openstacksdk."""

from __future__ import annotations

import time
from datetime import datetime, timezone

import openstack


class WorkerNotFound(RuntimeError):
    pass


class OpenStack:
    def __init__(self, cloud: str, worker_name: str):
        self.conn = openstack.connect(cloud=cloud)
        self.worker_name = worker_name

    def server(self):
        srv = self.conn.compute.find_server(self.worker_name)
        if srv is None:
            raise WorkerNotFound(self.worker_name)
        return srv

    def status(self) -> str:
        return self.server().status

    def updated_at(self) -> datetime:
        """Time of the last change to the server record (status transitions included)."""
        raw = self.server().updated_at
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(timezone.utc)

    def shelve(self) -> None:
        self.conn.compute.shelve_server(self.server())

    def unshelve(self) -> None:
        self.conn.compute.unshelve_server(self.server())

    def wait_for(self, statuses: set[str], timeout: float = 600, interval: float = 10) -> str:
        deadline = time.monotonic() + timeout
        while True:
            status = self.status()
            if status in statuses:
                return status
            if time.monotonic() > deadline:
                raise TimeoutError(f"{self.worker_name} still {status} after {timeout}s")
            time.sleep(interval)
