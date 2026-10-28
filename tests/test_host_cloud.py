"""Exercise cloud-only host preparation without running the installer entrypoint."""
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
        self.env = dict(os.environ, TEST_TMP=self.scratch.as_posix())

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

    def test_internal_image_does_not_probe_rsync(self):
        self.scratch.joinpath('po0-cloud-image.meta').write_text('old metadata\n')
        script = self.definitions('po0_prepare_cloud_image') + '''
po0_cloud_resolve() { echo http://mirrors.tencentyun.com/almalinux/image.qcow2; }
po0_cloud_probe() { echo 'Unexpected rsync probe' >&2; exit 92; }
po0_prepare_cloud_image http://mirrors.tencentyun.com/almalinux/image.qcow2
printf 'selected=%s\n' "$finalos_img"
'''
        result = self.shell(script)
        self.assertIn('selected=http://mirrors.tencentyun.com/almalinux/image.qcow2', result.stdout)
        self.assertFalse(self.scratch.joinpath('po0-cloud-image.meta').exists())

    def test_rsync_preparation_pins_metadata_without_fetching_image(self):
        script = self.definitions('po0_prepare_cloud_image', 'po0_cloud_expected_type',
                                  'test_url_real', 'po0_finish_cloud_metadata') + '''
po0_cloud_resolve() { echo rsync://first.example/images/image.qcow2; }
po0_cloud_probe() {
    printf 'url=rsync://second.example/images/image.qcow2\nsize=1234\nchecksum=unavailable\n' >"$2"
    printf '%s\n' rsync://second.example/images/image.qcow2
}
po0_cloud_stage() { echo 'Unexpected full staging' >&2; exit 92; }
po0_cloud_fetch() { echo 'Unexpected payload transfer' >&2; exit 92; }
file_enhanced() { echo 'Unexpected content inspection' >&2; exit 92; }
install_pkg() { echo 'Unexpected package installation' >&2; exit 92; }
po0_prepare_cloud_image http://mirrors.tencentyun.com/images/image.qcow2
test_url_real false "$finalos_img" qemu finalos_img_type
po0_finish_cloud_metadata
printf 'selected=%s\ntype=%s\n' "$finalos_img" "$finalos_img_type"
'''
        result = self.shell(script)
        self.assertIn('selected=rsync://second.example/images/image.qcow2', result.stdout)
        self.assertIn('type=qemu', result.stdout)
        self.assertFalse(self.scratch.joinpath('cached-image.qcow2').exists())
        self.assertFalse(self.scratch.joinpath('img-test').exists())
        metadata = self.scratch.joinpath('po0-cloud-image.meta').read_text()
        self.assertIn('type=qemu\n', metadata)
        self.assertNotIn('expanded_size=', metadata)

    def test_supported_filenames_only_record_expected_type_without_unpacking(self):
        metadata = self.scratch / 'po0-cloud-image.meta'
        for filename, expected in (
            ('image.img', 'qemu'), ('image.qcow2c', 'qemu'),
            ('image.qcow2.gz', 'qemu.gzip'), ('image.img.gzip', 'qemu.gzip'),
            ('image.qcow2.xz', 'qemu.xz'), ('image.img.zst', 'qemu.zstd'),
            ('image.qcow2.zstd', 'qemu.zstd'),
        ):
            with self.subTest(filename=filename):
                url = 'rsync://mirror.example/' + filename
                metadata.write_text(f'url={url}\nsize=1234\nchecksum=unavailable\n')
                script = self.definitions('po0_cloud_expected_type', 'test_url_real',
                                          'po0_finish_cloud_metadata') + f'''
finalos_img={url}
install_pkg() {{ echo 'Unexpected package installation' >&2; exit 92; }}
file_enhanced() {{ echo 'Unexpected content inspection' >&2; exit 92; }}
gzip() {{ echo 'Unexpected decompression' >&2; exit 92; }}
xz() {{ echo 'Unexpected decompression' >&2; exit 92; }}
zstd() {{ echo 'Unexpected decompression' >&2; exit 92; }}
test_url_real false "$finalos_img" 'qemu qemu.gzip qemu.xz qemu.zstd' finalos_img_type
po0_finish_cloud_metadata
'''
                self.shell(script)
                self.assertIn(f'type={expected}\n', metadata.read_text())
                self.assertNotIn('expanded_size=', metadata.read_text())
                self.assertFalse(self.scratch.joinpath('img-test').exists())

    def test_unprobed_rsync_and_wrong_source_are_rejected_without_download(self):
        script = self.definitions('po0_cloud_expected_type', 'test_url_real') + '''
test_url_real false rsync://mirror.example/a.qcow2 qemu finalos_img_type
'''
        for content in ('', 'url=rsync://other.example/a.qcow2\n'):
            self.scratch.joinpath('po0-cloud-image.meta').write_text(content)
            result = self.shell(script, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('must be probed', result.stderr)
            self.assertFalse(self.scratch.joinpath('img-test').exists())

    def test_unknown_or_unsupported_compression_suffix_stops_before_boot(self):
        for filename in ('download', 'image.raw', 'image.qcow2.zip', 'image.tar.xz'):
            with self.subTest(filename=filename):
                url = 'rsync://mirror.example/' + filename
                self.scratch.joinpath('po0-cloud-image.meta').write_text(f'url={url}\nsize=1234\n')
                script = self.definitions('po0_cloud_expected_type', 'test_url_real') + f'''
test_url_real false {url} 'qemu qemu.gzip qemu.xz qemu.zstd' finalos_img_type
'''
                result = self.shell(script, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('filename must identify QCOW2', result.stderr)
                self.assertFalse(self.scratch.joinpath('img-test').exists())

    def test_rsync_probe_failure_stops_preparation(self):
        script = self.definitions('po0_prepare_cloud_image') + '''
po0_cloud_resolve() { echo rsync://mirror.example/image.qcow2; }
po0_cloud_probe() { return 1; }
po0_prepare_cloud_image rsync://mirror.example/image.qcow2
'''
        result = self.shell(script, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not read the rsync cloud image metadata', result.stderr)

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
        self.assertLess(guard, SOURCE.index('# 用户名密码\nif ! is_netboot_xyz'))


if __name__ == '__main__':
    unittest.main()
