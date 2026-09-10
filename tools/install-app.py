#!/usr/bin/env python3
"""Replace the local developer build without leaving discoverable app backups.
Usage: install-app.py /path/to/Hemdiff.app
Uses ad-hoc signing for local validation, not a notarized public release.
"""
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

source = Path(sys.argv[1]).resolve()
target = Path('/Applications/Hemdiff.app')
def info(path):
    with (path / 'Contents/Info.plist').open('rb') as file:
        return plistlib.load(file)
metadata = info(source)
assert metadata['CFBundleIdentifier'] == 'com.adrians.Disksift', 'Unexpected source bundle'
assert not target.is_symlink(), 'Refusing a linked installation target'
if target.exists():
    assert info(target)['CFBundleIdentifier'] == metadata['CFBundleIdentifier'], 'Unexpected installed app'
stage = Path(tempfile.mkdtemp(prefix='.hemdiff-install-', dir=target.parent))
old = stage / 'previous-bundle'  # No .app suffix; removed immediately after replacement.
try:
    prepared = stage / 'Hemdiff.app'
    subprocess.run(['/usr/bin/ditto', str(source), str(prepared)], check=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(prepared)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(prepared)], check=True)
    executable = str(target / 'Contents/MacOS' / metadata['CFBundleExecutable'])
    for line in subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True).splitlines():
        pieces = line.strip().split(None, 1)
        if len(pieces) != 2 or pieces[1] != executable: continue
        pid = int(pieces[0])
        os.kill(pid, signal.SIGTERM)
        for _ in range(100):
            try: os.kill(pid, 0)
            except ProcessLookupError: break
            time.sleep(0.05)
        else: raise RuntimeError('Hemdiff did not exit; installation left unchanged')
    if target.exists(): target.rename(old)
    try: prepared.rename(target)
    except BaseException:
        if old.exists(): old.rename(target)
        raise
finally:
    if old.exists() and not target.exists():
        print(f'Recovery bundle retained at {old}', file=sys.stderr)
    else:
        shutil.rmtree(stage)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(target)], check=True)
subprocess.run(['/usr/bin/open', str(target)], check=True)
print(f'Installed and reopened {target}')
