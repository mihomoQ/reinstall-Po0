"""Exercise selected host functions; never execute the installer entrypoint.

All writes are to disposable fixture directories. Boot staging is checked
structurally because executing it would change the host's boot configuration.
"""

import importlib.util
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "reinstall.sh").read_text(encoding="utf-8")
SHELL = os.environ.get("PO0_TEST_SHELL") or shutil.which("bash") or "bash"
ASSETS = [name for name in (ROOT / "po0-assets.list").read_text().splitlines()
          if name and not name.startswith("#")]


def function(name):
    # Upstream uses column-zero closing braces for top-level functions only.
    match = re.search(r"(?ms)^" + re.escape(name) + r"\(\) \{\n.*?^\}", SOURCE)
    if not match:
        raise AssertionError(f"Missing host function: {name}")
    return match.group(0)


class HostPreparation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="po0 host tests ", dir=ROOT.parent)
        self.addCleanup(self.temp.cleanup)
        self.scratch = Path(self.temp.name)
        self.bundle = self.scratch / "complete release with spaces"
        self.bundle.mkdir()
        spec = importlib.util.spec_from_file_location("host_test_bundle", ROOT / "tools/build-bundle.py")
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        archive = builder.build(self.scratch / "release.tar.gz")
        with tarfile.open(archive) as package:
            for member in package.getmembers():
                name = member.name.removeprefix("reinstall-Po0/")
                self.assertNotIn("..", Path(name).parts)
                destination = self.bundle / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(package.extractfile(member).read())
        self.env = dict(os.environ, PO0_ASSET_DIR=self.bundle.as_posix())
        self.env["LC_ALL"] = "C"
        self.env.pop("PO0_MIRROR_BASE", None)
        self.env.pop("PO0_MIRROR_HOST", None)

    def shell(self, script, *args, check=True, env=None):
        return subprocess.run([SHELL, "-s", "--", *map(str, args)], input=script,
                              cwd=ROOT, env=env or self.env, text=True,
                              encoding="utf-8", capture_output=True, check=check)

    def test_bootstrap_finds_complete_release_in_directory_with_spaces(self):
        start = SOURCE.index('THIS_SCRIPT=$(readlink -f "$0")')
        end = SOURCE.index("trap 'trap_err", start)
        # Run only the extracted local bundle bootstrap, not the entrypoint.
        probe = self.bundle / "bootstrap probe.sh"
        probe.write_text("set -e\n" + SOURCE[start:end] +
                         'printf "asset-dir=%s\\n" "$PO0_ASSET_DIR"\n', encoding="utf-8", newline="\n")
        result = subprocess.run([SHELL, probe.as_posix()], env=self.env,
                                text=True, encoding="utf-8", capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.strip().endswith("/complete release with spaces"))
        self.bundle.joinpath("debian.cfg").unlink()
        result = subprocess.run([SHELL, probe.as_posix()], env=self.env,
                                text=True, encoding="utf-8", capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Incomplete Po0 bundle: debian.cfg", result.stderr)

    def embed(self, env=None):
        resolver = self.scratch / "saved resolv.conf"
        resolver.write_text("nameserver 192.0.2.53\n", encoding="utf-8", newline="\n")
        target = self.scratch / "extracted initrd with spaces"
        # Substitute only the absolute read-only resolver input with a fixture.
        embed = function("po0_embed_assets").replace(
            "/run/systemd/resolve/resolv.conf", shlex.quote(resolver.as_posix())).replace(
            "/etc/resolv.conf", shlex.quote(resolver.as_posix()))
        script = 'set -e\n. ./po0-lib.sh\n' + embed + '\npo0_embed_assets "$1"\n'
        # Relative writes avoid mkdir walking ancestors outside the workspace
        # on restricted Windows hosts; both paths still include spaces.
        target_argument = Path(os.path.relpath(target, ROOT)).as_posix()
        result = self.shell(script, target_argument, env=env, check=False)
        return target, resolver, result

    def test_embed_preserves_complete_asset_bytes_dns_and_mirror_rules(self):
        rules = "https://images.example/ http://mirror.internal:8080/images/\n"
        self.bundle.joinpath("po0-mirrors.conf").write_text(rules, encoding="utf-8", newline="\n")
        env = dict(self.env, PO0_MIRROR_BASE="http://mirror.internal:8080")
        target, resolver, result = self.embed(env)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ASSETS:
            with self.subTest(asset=name):
                self.assertEqual((target / "po0-assets" / name).read_bytes(),
                                 (self.bundle / name).read_bytes())
        self.assertEqual((target / "configs/po0-resolv.conf").read_bytes(), resolver.read_bytes())
        self.assertEqual((target / "po0-assets/po0-mirrors.conf").read_text(), rules)
        embedded_env = dict(self.env, PO0_ASSET_DIR=(target / "po0-assets").as_posix())
        self.assertEqual(self.shell(
            '. "$PO0_ASSET_DIR/po0-lib.sh"\npo0_rewrite_url https://deb.debian.org/debian/\n',
            env=embedded_env).stdout, "http://mirror.internal:8080/debian/\n")

    def test_bundle_configuration_is_resolved_before_embedding(self):
        self.bundle.joinpath("po0.conf").write_text(
            "PO0_MIRROR_BASE=http://configured.internal:8081\n", encoding="utf-8", newline="\n")
        target, _, result = self.embed()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((target / "po0-assets/po0.conf").read_text(),
                         "PO0_MIRROR_BASE='http://configured.internal:8081'\n")

    def test_missing_asset_aborts_embedding(self):
        self.bundle.joinpath("debian.cfg").unlink()
        target, _, result = self.embed()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing Po0 bundle asset: debian.cfg", result.stderr)
        self.assertFalse((target / "po0-assets/po0.conf").exists())

    def test_debian_12_and_13_urls_and_security_cmdline(self):
        names = ("set_var", "setos", "is_in_china", "is_use_cloud_image",
                 "is_distro_like_debian", "is_distro_like_redhat", "is_need_quote",
                 "build_nextos_cmdline", "build_extra_cmdline")
        script = 'set -e\n. ./po0-lib.sh\n' + "\n".join(map(function, names))
        script += """
info() { :; }
is_virt() { return 0; }
is_in_windows() { return 1; }
is_grub_dir_linked() { return 1; }
error_and_exit() { printf '%s\\n' "$*" >&2; exit 1; }
basearch=x86_64
basearch_alt=amd64
ram_size=2048
cloud_image=
distro=debian
releasever=$1
setos nextos "$distro" "$releasever"
"""
        security = re.search(
            r'(?ms)^# Only Debian stable uses.*?^fi$', SOURCE)
        self.assertIsNotNone(security)
        script += security.group(0) + """
build_nextos_cmdline
build_extra_cmdline
printf 'kernel=%s\\ninitrd=%s\\nmirror=%s\\npreseed=%s\\ncmdline=%s%s\\n' \
    "$nextos_vmlinuz" "$nextos_initrd" "$nextos_deb_mirror" "$nextos_ks" \
    "$nextos_cmdline" "$extra_cmdline"
"""
        for version, suite in (("12", "bookworm"), ("13", "trixie")):
            with self.subTest(version=version):
                result = self.shell(script, version)
                values = dict(line.split("=", 1) for line in result.stdout.splitlines())
                base = ("http://mirrors.tencentyun.com/debian/dists/" + suite +
                        "/main/installer-amd64/current/images/netboot/debian-installer/amd64/")
                self.assertEqual(values["kernel"], base + "linux")
                self.assertEqual(values["initrd"], base + "initrd.gz")
                self.assertEqual(values["mirror"], "mirrors.tencentyun.com/debian")
                self.assertEqual(values["preseed"], "file:///po0-assets/debian.cfg")
                self.assertIn("url=file:///po0-assets/debian.cfg", values["cmdline"])
                self.assertIn("mirror/http/hostname=mirrors.tencentyun.com", values["cmdline"])
                self.assertIn("extra_po0_security_host=mirrors.tencentyun.com", values["cmdline"])
                self.assertIn("extra_deb_mirror=mirrors.tencentyun.com/debian", values["cmdline"])
                self.assertNotIn("mirror.nju.edu.cn", values["cmdline"])

    def test_all_existing_distribution_choices_remain_parseable(self):
        choices = {
            "centos": "7|9|10", "anolis": "7|8|23", "opencloudos": "8|9|23",
            "almalinux": "8|9|10", "rocky": "8|9|10", "oracle": "8|9|10",
            "fnos": "1", "fygoos": "1", "fedora": "43|44", "nixos": "26.05",
            "debian": "9|10|11|12|13", "opensuse": "16.0|tumbleweed",
            "alpine": "3.21|3.22|3.23|3.24", "openeuler": "20.03|22.03|24.03|26.09",
            "ubuntu": "18.04|20.04|22.04|24.04|26.04|26.10",
            "kali": "last-snapshot|rolling", "redhat": "", "arch": "", "gentoo": "",
            "aosc": "", "windows": "", "dd": "", "netboot.xyz": "", "reset": "",
        }
        script = function("verify_os_name") + "\n" + function("to_lower") + """
error() { printf '%s\\n' "$*" >&2; }
usage_and_exit() { exit 91; }
"""
        expected = []
        for distro, versions in choices.items():
            for version in versions.split("|"):
                script += f"verify_os_name {shlex.quote(distro)} {shlex.quote(version)}\n"
                script += 'printf "%s:%s\\n" "$distro" "$releasever"\n'
                expected.append(("fnos" if distro == "fygoos" else distro) + ":" + version)
        self.assertEqual(self.shell(script).stdout.splitlines(), expected)

    def test_boot_payloads_are_validated_before_existing_entry_is_removed(self):
        staging = SOURCE[SOURCE.index("# Stage payloads"):SOURCE.index("# Disable kexec")]
        removal = staging.index("\nremove_exist_reinstall\n")
        self.assertLess(staging.index("\n    mod_initrd\n"), removal)
        self.assertLess(staging.index("Empty kernel payload."), removal)
        self.assertLess(staging.index("Empty initrd payload."), removal)
        self.assertLess(removal, staging.index('mv "$tmp/reinstall-vmlinuz" /reinstall-vmlinuz'))
        self.assertLess(removal, staging.index('mv "$tmp/reinstall-initrd" /reinstall-initrd'))
        for line in staging[:removal].splitlines():
            if line.lstrip().startswith("curl "):
                self.assertIn('"$tmp/', line)
        packing = function("mod_initrd")
        self.assertIn('gzip -t "$tmp/reinstall-initrd"', packing)
        self.assertIn('gzip -t "$tmp/reinstall-initrd.new"', packing)
        self.assertLess(packing.index('gzip -t "$tmp/reinstall-initrd.new"'),
                        packing.index('mv "$tmp/reinstall-initrd.new" "$tmp/reinstall-initrd"'))
        self.assertGreaterEqual(packing.count("set -o pipefail"), 2)


if __name__ == "__main__":
    unittest.main()
