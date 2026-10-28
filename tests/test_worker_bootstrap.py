"""Run the self-extractor against fixtures, never the real installation entrypoint."""
import base64
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHELL = os.environ.get("PO0_TEST_SHELL") or shutil.which("bash") or "bash"
spec = importlib.util.spec_from_file_location("worker_builder", ROOT / "tools/build-worker.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

FAKE_INSTALLER = b'''#!/usr/bin/env bash
set -eu
if [ "${1:-}" = --help ]; then
    echo 'Usage: reinstall.sh distro [version]'
    exit 1
fi
test -f ./relative-key
printf '%s\\0' "$@" >"$TEST_ARGUMENTS"
IFS= read -r answer
printf '%s\\n' "$answer" >"$TEST_STDIN"
pwd >"$TEST_CWD"
umask >"$TEST_UMASK"
printf '%s\\n' "$0" >"$TEST_CALLED"
exit "${TEST_EXIT_CODE:-0}"
'''


def archive_with_installer(content=FAKE_INSTALLER, name="reinstall-Po0/reinstall.sh"):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        item = tarfile.TarInfo(name)
        item.size = len(content)
        item.mode = 0o755
        archive.addfile(item, io.BytesIO(content))
    return output.getvalue()


class WorkerBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="po0 worker tests ", dir=ROOT.parent)
        self.addCleanup(self.temporary.cleanup)
        self.scratch = Path(self.temporary.name)
        self.caller = self.scratch / "caller cwd"
        self.caller.mkdir()
        self.temp_parent = self.scratch / "temporary parent with spaces"
        self.temp_parent.mkdir()
        self.launcher = self.caller / "reinstall.sh"
        (self.caller / "relative-key").write_text("public fixture key\n")
        self.env = dict(os.environ, TMPDIR=self.temp_parent.as_posix())
        for variable, filename in (("TEST_ARGUMENTS", "arguments"), ("TEST_STDIN", "stdin"),
                                   ("TEST_CWD", "cwd"), ("TEST_CALLED", "called"),
                                   ("TEST_UMASK", "umask")):
            self.env[variable] = (self.scratch / filename).as_posix()

    def run_launcher(self, *arguments):
        return subprocess.run([SHELL, self.launcher.as_posix(), *arguments],
                              cwd=self.caller, env=self.env, input="interactive answer\n",
                              text=True, capture_output=True, encoding="utf-8")

    def test_complete_release_is_embedded_without_private_configuration(self):
        builder.build(self.launcher)
        script = self.launcher.read_text(encoding="utf-8")
        encoded = script.split("<<'PO0_EMBEDDED_BUNDLE'\n", 1)[1].split("\nPO0_EMBEDDED_BUNDLE", 1)[0]
        bundle = base64.b64decode(encoded)
        self.assertIn(hashlib.sha256(bundle).hexdigest(), script)
        self.assertNotRegex(script, r"(?m)^\s*(curl|wget)\b")
        with tarfile.open(fileobj=io.BytesIO(bundle)) as archive:
            files = {item.name.removeprefix("reinstall-Po0/"): archive.extractfile(item).read()
                     for item in archive.getmembers()}
        self.assertIn("reinstall.sh", files)
        self.assertIn("po0-lib.sh", files)
        self.assertNotIn("po0.conf", files)
        self.assertNotIn("po0-mirrors.conf", files)
        for entry in files["SHA256SUMS"].decode().splitlines():
            digest, name = entry.split("  ", 1)
            self.assertEqual(hashlib.sha256(files[name]).hexdigest(), digest, name)
        parsed = subprocess.run([SHELL, "-n", self.launcher.as_posix()], capture_output=True)
        self.assertEqual(parsed.returncode, 0, parsed.stderr)

    def test_arguments_stdin_relative_paths_and_exit_status_survive(self):
        script = builder.render_bootstrap(archive_with_installer())
        self.launcher.write_bytes(script)
        self.env["TEST_EXIT_CODE"] = "7"
        expected_umask = subprocess.run([SHELL, "-c", "umask"], env=self.env,
                                        text=True, capture_output=True, check=True).stdout
        arguments = ["debian", "--ssh-key", "./relative-key", "a b", "literal$(nope);`nope`", ""]
        result = self.run_launcher(*arguments)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual((self.scratch / "arguments").read_bytes().split(b"\0")[:-1],
                         [argument.encode() for argument in arguments])
        self.assertEqual((self.scratch / "stdin").read_text(), "interactive answer\n")
        self.assertIn("caller cwd", (self.scratch / "cwd").read_text())
        self.assertEqual((self.scratch / "umask").read_text(), expected_umask)
        self.assertEqual(self.launcher.read_bytes(), script)
        self.assertEqual((self.caller / "relative-key").read_text(), "public fixture key\n")
        stages = list(self.temp_parent.glob("reinstall-PO0.*"))
        self.assertEqual(len(stages), 1)
        self.assertTrue((stages[0] / "reinstall-Po0/reinstall.sh").is_file())
        self.assertFalse((stages[0] / "bundle.tar.gz").exists())

    def test_help_is_forwarded_without_installation(self):
        self.launcher.write_bytes(builder.render_bootstrap(archive_with_installer()))
        result = self.run_launcher("--help")
        self.assertEqual(result.returncode, 1)  # Existing installer usage() convention.
        self.assertIn("Usage:", result.stdout)
        self.assertFalse((self.scratch / "called").exists())

    def test_corruption_stops_before_extraction_or_execution(self):
        original = archive_with_installer()
        damaged = original[:-1] + bytes([original[-1] ^ 1])
        script = builder.render_bootstrap(original)
        start = script.index(b"<<'PO0_EMBEDDED_BUNDLE'\n") + len(b"<<'PO0_EMBEDDED_BUNDLE'\n")
        end = script.index(b"\nPO0_EMBEDDED_BUNDLE", start)
        self.launcher.write_bytes(script[:start] + base64.b64encode(damaged) + script[end:])
        result = self.run_launcher("debian")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertFalse((self.scratch / "called").exists())
        self.assertEqual(list(self.temp_parent.iterdir()), [])

    def test_invalid_encoding_and_missing_installer_stop_safely(self):
        script = builder.render_bootstrap(archive_with_installer())
        self.launcher.write_bytes(script.replace(b"<<'PO0_EMBEDDED_BUNDLE'\n", b"<<'PO0_EMBEDDED_BUNDLE'\n!", 1))
        result = self.run_launcher("debian")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.scratch / "called").exists())
        self.assertEqual(list(self.temp_parent.iterdir()), [])
        self.launcher.write_bytes(builder.render_bootstrap(archive_with_installer(name="reinstall-Po0/other.sh")))
        result = self.run_launcher("debian")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no installer", result.stderr)
        self.assertFalse((self.scratch / "called").exists())
        self.assertEqual(list(self.temp_parent.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
