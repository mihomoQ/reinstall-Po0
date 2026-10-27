"""Validate installer hooks without executing any installation operations.

Run with Python 3. Set PO0_TEST_SHELL to a shell executable when bash/sh is not
on PATH. Only the isolated security-mirror helper is executed, with debconf
replaced by a recorder; the full installer hooks are syntax checked only.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
PRESEED = (ROOT / "debian.cfg").read_text(encoding="utf-8")
SHELL = os.environ.get("PO0_TEST_SHELL") or shutil.which("bash") or shutil.which("sh")


def selections(text):
    """Apply d-i's continuation rules, then split owner/key/type/value."""
    pending = ""
    result = {}
    for line in text.splitlines():
        # d-i removes comments at column zero before trimming indentation.
        if line.startswith("#") or not line.strip():
            continue
        line = line.lstrip()
        if line.endswith("\\"):
            pending += line[:-1].rstrip() + " "
            continue
        line = pending + line
        pending = ""
        parts = line.split(None, 3)
        if len(parts) < 3:
            raise ValueError(f"Incomplete preseed entry: {line}")
        owner, key, kind = parts[:3]
        if owner == "d-i":
            result[key] = (kind, parts[3] if len(parts) == 4 else "")
    if pending:
        raise ValueError("Unterminated preseed continuation")
    return result


class PreseedTests(unittest.TestCase):
    def setUp(self):
        self.entries = selections(PRESEED)

    def test_all_installer_hooks_parse(self):
        if not SHELL:
            self.skipTest("Set PO0_TEST_SHELL to bash/sh for syntax checks")
        hooks = ("preseed/early_command", "partman/early_command", "preseed/late_command")
        for name in hooks:
            with self.subTest(hook=name):
                kind, command = self.entries[name]
                self.assertEqual(kind, "string")
                result = subprocess.run([SHELL, "-n"], input=command, text=True,
                                        capture_output=True, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)

    def run_security_helper(self, host):
        if not SHELL:
            self.skipTest("Set PO0_TEST_SHELL to bash/sh for helper checks")
        command = self.entries["preseed/early_command"][1]
        helper = re.search(r"po0_set_security_mirror\(\) \{ .*? \};", command)
        self.assertIsNotNone(helper, "Security mirror helper is not part of early_command")
        script = "set -e\ndi() { printf '%s\\n' \"$*\"; }\n"
        script += helper.group(0) + "\npo0_set_security_mirror\n"
        env = os.environ.copy()
        env["po0_security_host"] = host
        result = subprocess.run([SHELL], input=script, text=True, env=env,
                                capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_debian_security_uses_configured_internal_host(self):
        self.assertEqual(self.run_security_helper("mirrors.tencentyun.com"),
                         "apt-setup/security_host string mirrors.tencentyun.com\n")

    def test_security_host_override_preserves_port(self):
        self.assertEqual(self.run_security_helper("mirror.internal:8080"),
                         "apt-setup/security_host string mirror.internal:8080\n")

    def test_kali_and_elts_do_not_gain_debian_security_source(self):
        # reinstall.sh omits the variable for targets without Debian security.
        self.assertEqual(self.run_security_helper(""), "")

    def test_installer_has_no_web_logging_dependency(self):
        self.assertNotRegex(PRESEED, r"web_port|web_path|websocketd|logviewer|nginx")
        self.assertNotIn("$confhome/", PRESEED)

    def test_chrony_is_installed_and_configured_before_first_boot(self):
        self.assertIn("chrony", self.entries["pkgsel/include"][1].split())
        self.assertEqual(self.entries["clock-setup/ntp-server"][1], "time1.tencentyun.com")
        self.assertIn("sh /po0-assets/po0-chrony.sh /target || exit 1",
                      self.entries["preseed/late_command"][1])


if __name__ == "__main__":
    unittest.main()
