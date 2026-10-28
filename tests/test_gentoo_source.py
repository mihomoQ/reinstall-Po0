"""Gentoo source setup fixtures: no chroot, package install or network access."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'trans.sh').read_text(encoding='utf-8')
SHELL = os.environ.get('PO0_TEST_SHELL') or shutil.which('bash') or 'bash'


def function(name):
    match = re.search(r'(?ms)^' + re.escape(name) + r'\(\) \{\n.*?^\}', SOURCE)
    if not match:
        raise AssertionError('Missing function: ' + name)
    return match.group(0)


class GentooSources(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='po0 gentoo ', dir=ROOT.parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ('usr/bin', 'usr/share/openpgp-keys', 'etc/portage'):
            self.root.joinpath(directory).mkdir(parents=True)
        self.root.joinpath('usr/bin/getuto').write_text('GETUTO_EXTERNAL_REFRESH=0\n')
        self.root.joinpath('usr/share/openpgp-keys/gentoo-release.asc').write_text('key fixture\n')
        self.root.joinpath('etc/portage/make.conf').write_text('CFLAGS="-O2"\n')

    def run_shell(self, script, check=True):
        return subprocess.run([SHELL], input=script, text=True, encoding='utf-8', capture_output=True,
                              cwd=self.root.parent,
                              env=dict(os.environ, TEST_ROOT=self.root.name), check=check)

    def config_script(self):
        return '''set -e
PO0_MIRROR_BASE=http://internal.example:8080
error_and_exit() { printf '%s\n' "$*" >&2; return 1; }
''' + function('po0_configure_gentoo_sources') + '\npo0_configure_gentoo_sources "$TEST_ROOT"\n'

    def test_internal_sources_before_sync_preserve_signature_verification(self):
        script = self.config_script()
        self.run_shell(script)
        make = self.root.joinpath('etc/portage/make.conf')
        once = make.read_text()
        self.assertIn('CFLAGS="-O2"', once)
        self.assertIn('GENTOO_MIRRORS="http://internal.example:8080/gentoo"', once)
        self.assertIn('FEATURES="getbinpkg force-mirror webrsync-gpg"', once)
        self.assertIn('GETUTO_EXTERNAL_REFRESH=0', once)
        self.assertIn('PORTAGE_GPG_DIR="/etc/portage/webrsync-gnupg"', once)
        self.assertNotIn('PORTAGE_TRUST_HELPER=true', once)
        repo = self.root.joinpath('etc/portage/repos.conf/gentoo.conf').read_text()
        self.assertIn('sync-type = webrsync', repo)
        self.assertIn('sync-webrsync-verify-signature = true', repo)
        self.assertNotIn('sync-uri', repo)
        self.run_shell(script)
        self.assertEqual(make.read_text(), once)

    def test_missing_keys_or_unsupported_getuto_fail_before_config_changes(self):
        for invalid in ('keys', 'getuto'):
            with self.subTest(invalid=invalid):
                if invalid == 'keys':
                    self.root.joinpath('usr/share/openpgp-keys/gentoo-release.asc').write_text('')
                else:
                    self.root.joinpath('usr/share/openpgp-keys/gentoo-release.asc').write_text('key fixture\n')
                    self.root.joinpath('usr/bin/getuto').write_text('old getuto\n')
                result = self.run_shell(self.config_script(), check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.root.joinpath('etc/portage/make.conf').read_text(), 'CFLAGS="-O2"\n')

    def test_key_setup_uses_local_package_keys_without_public_refresh(self):
        script = '''set -e
chroot() {
    printf '%s|%s|%s\n' "${TERM:-}" "${GETUTO_EXTERNAL_REFRESH:-}" "$*" >>"$TEST_ROOT/chroot.log"
    case "$*" in *'/bin/bash -s') cat >"$TEST_ROOT/key-setup.sh" ;; esac
}
''' + function('po0_initialize_gentoo_keys') + '\npo0_initialize_gentoo_keys "$TEST_ROOT"\n'
        self.run_shell(script)
        calls = self.root.joinpath('chroot.log').read_text().splitlines()
        self.assertTrue(calls[0].startswith('dumb|0|'))
        body = self.root.joinpath('key-setup.sh').read_text()
        self.assertIn('--import /usr/share/openpgp-keys/gentoo-release.asc', body)
        self.assertIn('--import-ownertrust', body)
        self.assertIn('/etc/portage/webrsync-gnupg', body)
        for forbidden in ('--keyserver', '--recv-keys', '--refresh-keys', '--no-pgp-verify'):
            self.assertNotIn(forbidden, body)
        subprocess.run([SHELL, '-n'], input=body, text=True, check=True)

    def test_install_order_keeps_snapshot_and_binpkg_sources_internal(self):
        start = SOURCE.index('    install_gentoo() {')
        end = SOURCE.index('    install_aosc() {', start)
        install = SOURCE[start:end]
        self.assertLess(install.index('po0_configure_gentoo_sources'), install.index('emerge-webrsync'))
        self.assertLess(install.index('po0_initialize_gentoo_keys'), install.index('emerge-webrsync'))
        self.assertIn('mirror_long=$PO0_MIRROR_BASE/gentoo/releases/$mirror_arch', install)
        self.assertNotIn('emerge --sync', install)
        self.assertNotIn('emerge dev-vcs/git', install)
        self.assertNotIn('rm -rf $os_dir/var/db/repos/gentoo', install)
        self.assertNotIn('git_uri=', install)


if __name__ == '__main__':
    unittest.main()
