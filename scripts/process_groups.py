"""Terminate subprocess trees started by the release checks with start_new_session=True."""

import os
import signal
import subprocess
import time


def stop_process(process: subprocess.Popen, grace_seconds: float = 5) -> None:
    """Give the whole owned process group time to exit, then kill survivors and reap the leader."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
        deadline = time.monotonic() + grace_seconds
        while True:
            process.poll()  # Reap the leader so its zombie alone cannot keep the group alive.
            try:
                os.killpg(process.pid, 0)
            except PermissionError:
                # Darwin can report EPERM during exit before the group disappears on the next poll.
                pass
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                os.killpg(process.pid, signal.SIGKILL)
                break
            time.sleep(min(0.05, remaining))
    except ProcessLookupError:
        pass  # The group exited before the signal or liveness check.
    process.wait()
