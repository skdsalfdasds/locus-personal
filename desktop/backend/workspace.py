"""One service owns a workspace at a time, including after an unclean exit."""
import os
from pathlib import Path


class WorkspaceLease:
    def __init__(self, root):
        self.root = Path(root)
        self.handle = None

    def __enter__(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        handle = (self.root / 'workspace.lock').open('a+b')
        try:
            # Windows byte-range locks need an existing byte. Never unlink the
            # file: replacing its inode would allow two different locks.
            handle.seek(0, os.SEEK_END)
            if handle.tell() == 0:
                handle.write(b'\0')
                handle.flush()
            handle.seek(0)
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            handle.close()
            raise RuntimeError('Waypoint Desktop is already using this workspace. Close its other window before reopening it.') from error
        self.handle = handle
        return self

    def __exit__(self, *_):
        if self.handle is not None:
            # Closing the descriptor releases the OS lock, also on process exit.
            self.handle.close()
            self.handle = None
