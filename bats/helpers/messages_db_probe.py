#!/usr/bin/env python3
"""Silently probe whether the standard Messages database can be read."""

import errno
import os
from pathlib import Path
import pwd


def main() -> int:
    try:
        descriptor = os.open(
            Path(pwd.getpwuid(os.getuid()).pw_dir)
            / "Library"
            / "Messages"
            / "chat.db",
            os.O_RDONLY,
        )
        try:
            os.read(descriptor, 1)
        finally:
            os.close(descriptor)
    except OSError as error:
        if error.errno in {errno.EACCES, errno.EPERM, errno.ENOENT}:
            return 77
        return 1
    except Exception:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
