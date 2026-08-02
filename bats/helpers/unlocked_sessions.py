#!/usr/bin/env python3
"""Print session directories whose .lock is ACQUIRABLE, i.e. whose owning process is gone.

The leak predicate for the snapshot-lifetime test. `flock` is released by the kernel on any process
death, so acquiring it means the owner no longer exists and the directory is an orphan. A directory
belonging to a concurrently-running `apple` still holds its lock and is correctly left alone — which
is why this is used instead of counting directories, a count being racy in both directions.
"""
import fcntl
import os
import sys

root = sys.argv[1]
orphans = []
for name in sorted(os.listdir(root)):
    d = os.path.join(root, name)
    if not name.startswith("s-") or not os.path.isdir(d):
        continue
    lock = os.path.join(d, ".lock")
    if not os.path.exists(lock):
        continue                      # never claimed; the reaper ages these out separately
    try:
        with open(lock, "r+") as f:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            orphans.append(name)      # acquired => owner is dead => leaked
    except OSError:
        pass                          # still held => a live reader
print(" ".join(orphans))
