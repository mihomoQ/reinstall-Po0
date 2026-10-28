"""Exercise actual mirror rules, local asset failures, and release contents."""
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHELL = os.environ.get('PO0_TEST_SHELL', shutil.which('bash') or 'bash')


class Resources(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.assets = Path(self.temp.name)
        self.env = dict(os.environ, PO0_ASSET_DIR=self.assets.as_posix())
        self.env.pop('PO0_MIRROR_BASE', None)

    def shell(self, body, *args, check=True, env=None):
        return subprocess.run([SHELL, '-c', '. ./po0-lib.sh || exit; ' + body, 'test', *args],
                              cwd=ROOT, env=env or self.env, text=True, capture_output=True, check=check)

    def test_distro_paths_and_security(self):
        cases = {
            'https://mirror.nju.edu.cn/debian/dists/bookworm/Release': '/debian/dists/bookworm/Release',
            'http://security.debian.org/debian-security/dists/trixie-security/Release': '/debian-security/dists/trixie-security/Release',
            'https://security.debian.org/dists/bookworm-security/Release': '/debian-security/dists/bookworm-security/Release',
            'http://cn.archive.ubuntu.com/ubuntu/dists/noble/Release': '/ubuntu/dists/noble/Release',
            'https://ports.ubuntu.com/ubuntu-ports/dists/jammy/Release': '/ubuntu-ports/dists/jammy/Release',
            'https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/repodata/repomd.xml': '/almalinux/9/BaseOS/x86_64/os/repodata/repomd.xml',
            'https://dl-cdn.alpinelinux.org/alpine/v3.24/main/x86_64/APKINDEX.tar.gz': '/alpine/v3.24/main/x86_64/APKINDEX.tar.gz',
            'https://archive.debian.org/debian/dists/stretch/Release': '/debian-archive/debian/dists/stretch/Release',
        }
        for url, path in cases.items():
            with self.subTest(url=url):
                self.assertEqual(self.shell('po0_rewrite_url "$1"', url).stdout.strip(), 'http://mirrors.tencentyun.com' + path)

    def test_custom_urls_not_replaced(self):
        url = 'http://images.example:8080/custom.qcow2?token=a&version=9'
        self.assertEqual(self.shell('po0_rewrite_url "$1"', url).stdout.strip(), url)

    def test_operator_rule_without_final_newline(self):
        self.assets.joinpath('po0-mirrors.conf').write_text(
            'https://mirror.nju.edu.cn/ubuntu-cloud-images/ http://images.example:8080/ubuntu/', encoding='utf-8')
        result = self.shell('po0_rewrite_url "$1"', 'https://mirror.nju.edu.cn/ubuntu-cloud-images/releases/noble/release/image.img')
        self.assertEqual(result.stdout.strip(), 'http://images.example:8080/ubuntu/releases/noble/release/image.img')

    def test_malformed_rule_fails(self):
        self.assets.joinpath('po0-mirrors.conf').write_text('https://old/ not-a-url\n', encoding='utf-8')
        self.assertNotEqual(self.shell('po0_rewrite_url https://old/a', check=False).returncode, 0)

    def test_custom_origin_and_invalid_base(self):
        env = dict(self.env, PO0_MIRROR_BASE='http://mirror.example:8080')
        self.assertEqual(self.shell('po0_rewrite_url https://deb.debian.org/debian/', env=env).stdout.strip(),
                         'http://mirror.example:8080/debian/')
        env['PO0_MIRROR_BASE'] = 'http://mirror.example/private-path'
        self.assertNotEqual(self.shell(':', env=env, check=False).returncode, 0)
        env['PO0_MIRROR_BASE'] = 'https://mirror.example:443'
        self.assertNotEqual(self.shell(':', env=env, check=False).returncode, 0)

    def test_copy_is_local_and_rejects_missing_or_traversal(self):
        self.assets.joinpath('helper.sh').write_text('test-bundle-content\n', encoding='utf-8')
        self.assertEqual(self.shell('po0_copy_asset helper.sh -').stdout, 'test-bundle-content\n')
        for path in ['missing.sh', '../outside', '/etc/passwd']:
            self.assertNotEqual(self.shell('po0_copy_asset "$1" -', path, check=False).returncode, 0)

    def test_incomplete_bundle_fails(self):
        self.assets.joinpath('po0-assets.list').write_text('missing.sh', encoding='utf-8')
        self.assertNotEqual(self.shell('po0_check_bundle', check=False).returncode, 0)

    def test_bundle_hashes_and_excluded_operator_state(self):
        spec = importlib.util.spec_from_file_location('bundle', ROOT / 'tools/build-bundle.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        archive = module.build(self.assets / 'test.tar.gz')
        with tarfile.open(archive) as tf:
            members = {m.name.removeprefix('reinstall-Po0/'): tf.extractfile(m).read() for m in tf.getmembers()}
        self.assertNotIn('po0.conf', members)
        self.assertNotIn('po0-mirrors.conf', members)
        self.assertNotIn('logviewer.html', members)
        for line in members['SHA256SUMS'].decode().splitlines():
            expected, name = line.split('  ', 1)
            self.assertEqual(hashlib.sha256(members[name]).hexdigest(), expected, name)
        for name, content in members.items():
            if name.endswith('.sh'):
                self.assertNotIn(b'\r\n', content, name)


if __name__ == '__main__':
    unittest.main()
