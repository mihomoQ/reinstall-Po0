#!/usr/bin/env python3
"""Build a single downloadable script containing the complete PO0 bundle."""
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import textwrap

ROOT = Path(__file__).resolve().parents[1]


def render_bootstrap(bundle: bytes) -> bytes:
    """Keep code and assets in one response; no second download is required."""
    digest = hashlib.sha256(bundle).hexdigest()
    payload = "\n".join(textwrap.wrap(base64.b64encode(bundle).decode("ascii"), 76))
    return f'''#!/usr/bin/env bash
# Generated PO0 installer. The embedded bundle contains the sources and license.
set -euo pipefail
original_umask=$(umask)
umask 077

for program in bash base64 sha256sum tar mktemp; do
    command -v "$program" >/dev/null 2>&1 || {{
        printf 'Required command not found: %s\\n' "$program" >&2
        exit 1
    }}
done

# Only the directory created by this invocation may be removed on failure.
stage_parent=$(cd "${{TMPDIR:-/tmp}}" && pwd -P)
stage=$(mktemp -d "$stage_parent/reinstall-PO0.XXXXXXXX")
case "$stage" in "$stage_parent"/reinstall-PO0.*) ;; *) exit 1 ;; esac
trap 'rm -rf -- "$stage"' EXIT
archive=$stage/bundle.tar.gz

base64 -d >"$archive" <<'PO0_EMBEDDED_BUNDLE'
{payload}
PO0_EMBEDDED_BUNDLE

actual=$(sha256sum "$archive")
if [ "${{actual%% *}}" != '{digest}' ]; then
    echo 'PO0 bundle checksum mismatch; download reinstall.sh again.' >&2
    exit 1
fi
tar -xzf "$archive" -C "$stage"
installer=$stage/reinstall-Po0/reinstall.sh
[ -s "$installer" ] || {{ echo 'PO0 bundle has no installer.' >&2; exit 1; }}
rm -f -- "$archive"

# Retain these small files for retries/debugging, including asynchronous users.
# Preserve the caller's cwd, stdin and arguments (relative paths stay relative).
trap - EXIT
umask "$original_umask"
exec bash "$installer" "$@"
'''.encode("utf-8")


def build(destination: Path) -> Path:
    spec = importlib.util.spec_from_file_location("po0_bundle_builder", ROOT / "tools/build-bundle.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("Cannot load the bundle builder")
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    with tempfile.TemporaryDirectory(prefix="po0-worker-build-") as temporary:
        archive = builder.build(Path(temporary) / "bundle.tar.gz")
        script = render_bootstrap(archive.read_bytes())
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(script)
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, nargs="?", default=ROOT / "dist/worker/reinstall.sh")
    print(build(parser.parse_args().output).resolve())
