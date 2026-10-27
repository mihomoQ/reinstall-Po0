"""Exercise cloud-only host preparation without running the installer entrypoint."""
import gzip
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'reinstall.sh').read_text(encoding='utf-8')
SHELL = os.environ.get('PO0_TEST_SHELL') or shutil.which('bash') or 'bash'


def function(name):
    match = re.search(r'(?ms)^' + re.escape(name) + r'\(\) \{\n.*?^\}', SOURCE)
    if not match:
        raise AssertionError('Missing function: ' + name)
    return match.group(0)


class CloudHostPreparation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='po0 cloud tests ', dir=ROOT.parent)
        self.addCleanup(self.temp.cleanup)
        self.scratch = Path(self.temp.name)
        self.fixture = self.scratch / 'fixture.qcow2'
        self.payload = b'QFI\xfb' + b'known-image-payload\n' * 100000
        self.fixture.write_bytes(self.payload)
        self.env = dict(os.environ, TEST_TMP=self.scratch.as_posix(),
                        TEST_IMAGE=self.fixture.as_posix())

    def shell(self, code, check=True):
        return subprocess.run([SHELL], input=code, text=True, capture_output=True,
                              cwd=ROOT, env=self.env, check=check)

    def definitions(self, *names):
        return '''set -e
tmp=$TEST_TMP
info() { :; }
error_and_exit() { printf '%s\n' "$*" >&2; exit 91; }
install_pkg() { :; }
po0_rewrite_url() { printf '%s\n' "$1"; }
po0_cloud_meta_get() { sed -n "s/^$1=//p" "$2"; }
''' + '\n'.join(function(name) for name in names) + '\n'

    def test_internal_image_does_not_stage_full_file(self):
        self.scratch.joinpath('po0-cloud-image.meta').write_text('old metadata\n')
        script = self.definitions('po0_prepare_cloud_image') + '''
po0_cloud_resolve() { echo http://mirrors.tencentyun.com/almalinux/image.qcow2; }
po0_cloud_stage() { echo 'Unexpected staging' >&2; exit 92; }
po0_prepare_cloud_image http://mirrors.tencentyun.com/almalinux/image.qcow2
printf 'selected=%s\ncache=%s\n' "$finalos_img" "$po0_cloud_cache"
'''
        result = self.shell(script)
        self.assertIn('selected=http://mirrors.tencentyun.com/almalinux/image.qcow2', result.stdout)
        self.assertIn('cache=\n', result.stdout)
        self.assertFalse(self.scratch.joinpath('po0-cloud-image.meta').exists())

    def test_rsync_transfer_source_is_pinned_and_header_copy_can_be_modified(self):
        script = self.definitions('po0_prepare_cloud_image', 'test_url_real', 'po0_finish_cloud_metadata') + '''
po0_cloud_resolve() { echo rsync://first.example/images/image.qcow2; }
po0_cloud_stage() {
    cp "$TEST_IMAGE" "$tmp/cached-image.qcow2"
    printf 'url=rsync://second.example/images/image.qcow2\nsize=%s\nsha256=fixture\n' \
        "$(wc -c <"$TEST_IMAGE" | tr -d ' ')" >"$3"
    printf '%s\n' "$tmp/cached-image.qcow2"
}
file_enhanced() { printf 'header-is-consumed\n' >"$1"; echo qemu; }
po0_prepare_cloud_image http://mirrors.tencentyun.com/images/image.qcow2
test_url_real false "$finalos_img" qemu finalos_img_type
po0_finish_cloud_metadata
printf 'selected=%s\ntype=%s\n' "$finalos_img" "$finalos_img_type"
'''
        result = self.shell(script)
        self.assertIn('selected=rsync://second.example/images/image.qcow2', result.stdout)
        self.assertEqual(self.scratch.joinpath('cached-image.qcow2').read_bytes(), self.payload)
        self.assertEqual(self.scratch.joinpath('img-test').read_text(), 'header-is-consumed\n')
        metadata = self.scratch.joinpath('po0-cloud-image.meta').read_text()
        self.assertIn('type=qemu\n', metadata)
        self.assertIn(f'expanded_size={len(self.payload)}\n', metadata)

    def test_real_decompression_size_and_corrupt_archive_failure(self):
        cache = self.scratch / 'cached-image.gz'
        cache.write_bytes(gzip.compress(self.payload))
        metadata = self.scratch / 'po0-cloud-image.meta'
        metadata.write_text(f'url=rsync://mirror.example/image.gz\nsize={cache.stat().st_size}\n')
        script = self.definitions('po0_finish_cloud_metadata') + '''
finalos_img=rsync://mirror.example/image.gz
finalos_img_type=qemu
finalos_img_type_warp=gzip
po0_cloud_cache="$tmp/cached-image.gz"
po0_finish_cloud_metadata
'''
        self.shell(script)
        self.assertIn(f'expanded_size={len(self.payload)}\n', metadata.read_text())
        cache.write_bytes(cache.read_bytes()[:-8])
        metadata.write_text('url=rsync://mirror.example/image.gz\nsize=1\n')
        result = self.shell(script, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('expanded_size=', metadata.read_text())

    def test_unstaged_rsync_and_wrong_source_are_rejected_without_curl(self):
        script = self.definitions('test_url_real') + '''
po0_cloud_cache="$TEST_IMAGE"
test_url_real false rsync://mirror.example/a.qcow2 qemu finalos_img_type
'''
        self.scratch.joinpath('po0-cloud-image.meta').write_text('url=rsync://other.example/a.qcow2\n')
        result = self.shell(script, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must be staged', result.stderr)
        self.assertFalse(self.scratch.joinpath('img-test').exists())

    def test_cloud_directory_discovery_uses_cloud_only_transport(self):
        script = self.definitions('set_var', 'setos') + '''
is_in_china() { return 0; }
is_use_cloud_image() { return 0; }
is_distro_like_debian() { return 1; }
is_in_windows() { return 1; }
po0_prepare_cloud_image() { :; }
po0_finish_cloud_metadata() { :; }
test_url() { :; }
curl() { echo 'Generic curl was used for cloud discovery' >&2; exit 93; }
po0_cloud_text() {
    echo "$1" >>"$tmp/lookups"
    case "$1" in
      *fedora*) echo Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2 ;;
      *opencloudos*) echo OpenCloudOS-GenericCloud-9.6-20261001.x86_64.qcow2 ;;
      *anolis*) echo AnolisOS-8.10-x86_64-ANCK.qcow2 ;;
      *openeuler*) echo openEuler-24.03-LTS-SP2 ;;
    esac
}
basearch=x86_64
basearch_alt=amd64
ram_size=2048
img=
setos finalos fedora 43
img=
setos finalos opencloudos 9
img=
setos finalos anolis 8
img=
setos finalos openeuler 24.03
'''
        self.shell(script)
        lookups = self.scratch.joinpath('lookups').read_text().splitlines()
        self.assertEqual(len(lookups), 4)
        self.assertTrue(any('fedora' in url for url in lookups))
        self.assertTrue(any('opencloudos' in url for url in lookups))
        self.assertTrue(any('openanolis' in url for url in lookups))
        self.assertTrue(any('openeuler' in url for url in lookups))

    def test_metadata_is_embedded_and_raw_dd_is_rejected_before_boot(self):
        embedding = function('po0_embed_assets')
        self.assertIn('"$tmp/po0-cloud-image.meta" "$root/configs/po0-cloud-image.meta"', embedding)
        guard = SOURCE.index('Rsync URLs are supported for cloud-image installation, not raw DD.')
        self.assertLess(guard, SOURCE.index('# 用户名\nif ! is_netboot_xyz'))


if __name__ == '__main__':
    unittest.main()
