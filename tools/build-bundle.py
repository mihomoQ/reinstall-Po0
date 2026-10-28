#!/usr/bin/env python3
"""Create a portable release without operator configuration or machine data."""
from __future__ import annotations

import argparse
import hashlib
import io
from pathlib import Path, PurePosixPath
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def build(destination: Path) -> Path:
    names = ROOT.joinpath('po0-assets.list').read_text(encoding='utf-8').splitlines()
    names += ['LICENSE', 'README.md', 'README.en.md', 'README.upstream.md',
              'README.upstream.en.md', 'po0.conf.example', 'po0-mirrors.conf.example',
              'docs/live-test-2026-10-27.md', 'docs/live-test-2026-10-28.md']
    members: dict[str, bytes] = {}
    for name in dict.fromkeys(names):
        if not name or name.startswith('#'):
            continue
        relative = PurePosixPath(name)
        if relative.is_absolute() or '..' in relative.parts or '\\' in name:
            raise ValueError(f'Unsafe bundle path: {name}')
        path = ROOT / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f'Missing or symlinked asset: {name}')
        content = path.read_bytes()
        if not content:
            raise ValueError(f'Empty asset: {name}')
        if path.suffix in {'.sh', '.cfg', '.list', '.service', '.initd', '.yaml'}:
            content = content.replace(b'\r\n', b'\n')
        members[name] = content
    sums = ''.join(f'{hashlib.sha256(data).hexdigest()}  {name}\n' for name, data in sorted(members.items()))
    members['SHA256SUMS'] = sums.encode()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(destination, 'w:gz') as archive:
        for name, content in sorted(members.items()):
            entry = tarfile.TarInfo(f'reinstall-Po0/{name}')
            entry.size = len(content)
            entry.mode = 0o755 if name.endswith('.sh') else 0o644
            entry.mtime = 0
            archive.addfile(entry, io.BytesIO(content))
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, nargs='?', default=ROOT / 'dist' / 'reinstall-Po0.tar.gz')
    print(build(parser.parse_args().output).resolve())
