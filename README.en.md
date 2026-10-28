# reinstall-Po0

A Po0-specific fork of [bin456789/reinstall](https://github.com/bin456789/reinstall), retaining multiple OS choices and the GPL-3.0 license. See the [Chinese guide](README.md) for configuration, observed resource availability, and limitations.

Debian 12, Ubuntu 24.04.5, AlmaLinux 9.8 and Ubuntu 22.04.5 have completed real disk reinstalls, first boot, public-key SSH, internal package-source refresh and chrony synchronization on one Po0 x86_64/BIOS VM. Other targets and hardware remain unverified. See the [current live-test record](docs/live-test-2026-10-28.md).

- No public geolocation or Internet-connectivity probes, and no address/route deletion based on them.
- Private DHCP networking, original DNS fallback, and internal mirror mappings.
- Package repositories stay internal. QCOW2 cloud images prefer the internal mirror, then use bounded rsync failover through bundled campus endpoints. MirrorZ's HTTP 302 service is not a runtime dependency or a rsync redirector.
- Chrony with Tencent's five internal time servers on integrated Debian/Kali, Ubuntu/RPM cloud-image and Alpine paths. The same configuration helper has been live-tested on the installed Debian 12 server; Alpine and other unlisted chrony targets retain isolated-test coverage only.
- SSH/screen installation logs only; no Web log service or Web port options.
- Version-matched local helpers and Debian preseed embedded into initrd. Transfer the complete source directory or bundle, not a single script.
- Debian/Ubuntu APT (including security) and mapped RPM repositories are adapted. OS menu retention is not a claim that every resource or installation path works.

Build the portable bundle on a computer with Python:

```sh
python3 tools/build-bundle.py
```

Transfer `dist/reinstall-Po0.tar.gz` to the server using SCP/SFTP and extract it. The bundle contains checksums and excludes private operator configuration. Follow README.md before preparing any installation; installation erases the selected disk after reboot.

Observed internal resources include Debian 12 netboot, Alpine 3.24 netboot, and AlmaLinux 9 GenericCloud. Missing Ubuntu/Debian/Rocky cloud-image files can fall back to rsync. A complete Ubuntu 24.04 image has been downloaded and type/hash-checked on the test VM; the Ubuntu and AlmaLinux cloud-image paths have also completed full reinstalls and first-boot checks.

Preparation for both HTTP and rsync reads image metadata and bounded SHA256 manifests; the installer transfers the complete image once. It checks size, any available pinned manifest hash, and explicit QCOW2 structure before using the file. Without a matching manifest, available size and structural checks still apply, with a visible notice. Mirror-provided checksums do not authenticate publisher identity. Plain images are downloaded after repartitioning, so a failure can leave the old system erased. Compressed images are cached in installer RAM, fully counted before repartitioning, and expanded from that cache without a second transfer. They need RAM for the archive plus 512 MiB of headroom, sufficient RAM-filesystem space, and no more than 256 MiB of xz/zstd decoder memory; insufficient resources stop before partitioning. Legacy `--installer` is rejected; its disabled implementation and dedicated assets have been removed. The installer runs from Linux only; Windows/Cygwin host bootstrap has been removed. Windows remains an optional installation target with unverified drivers and third-party resources.

Initial source baseline: `01e1e259968c3b9c5ee5d6aea7253392b5eafe92`. Upstream was merged through `54fae2067557b3c0ca49e7c9ce03bca63c793f8c` on 2026-10-28, including installation messages, network diagnostics and DNS configuration interfaces. Po0 keeps DHCP and saved-resolver fallback without public connectivity probes. Original documentation is retained in `README.upstream.md` and `README.upstream.en.md` for reference; upstream Web logging and single-file download instructions do not apply here.
