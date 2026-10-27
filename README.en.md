# reinstall-Po0

A Po0-specific fork of [bin456789/reinstall](https://github.com/bin456789/reinstall), retaining multiple OS choices and the GPL-3.0 license. See the [Chinese guide](README.md) for configuration, observed resource availability, and limitations.

This is a **development candidate with one live-tested path**: Debian 12 on a Po0 x86_64/BIOS VM has completed a full disk reinstall, first boot, public-key SSH login, and internal APT update. Other systems and hardware paths remain unvalidated. See the [live-test record](docs/live-test-2026-10-27.md).

- No public geolocation or Internet-connectivity probes, and no address/route deletion based on them.
- Private DHCP networking, original DNS fallback, and internal mirror mappings.
- Chrony with Tencent's five internal time servers on integrated Debian/Kali, Ubuntu/RPM cloud-image and Alpine paths. The same configuration helper has been live-tested on the installed Debian 12 server; other chrony integrations are isolated-test coverage only.
- SSH/screen installation logs only; no Web log service or Web port options.
- Version-matched local helpers and Debian preseed embedded into initrd. Transfer the complete source directory or bundle, not a single script.
- Debian/Ubuntu APT (including security) and mapped RPM repositories are adapted. OS menu retention is not a claim that every resource or installation path works.

Build the portable bundle on a computer with Python:

```sh
python3 tools/build-bundle.py
```

Transfer `dist/reinstall-Po0.tar.gz` to the server using SCP/SFTP and extract it. The bundle contains checksums and excludes private operator configuration. Follow README.md before preparing any installation; installation erases the selected disk after reboot.

Observed internal resources include Debian 12 netboot, Alpine 3.24 netboot, and AlmaLinux 9 GenericCloud. Ubuntu cloud-image and Debian cdimage default paths return 404; use an accessible `--img` URL or a custom prefix mapping. Legacy `--installer` paths stop before boot changes until their second-stage configuration transport is adapted. Windows source bootstrap and optional third-party resources remain unverified.

Source baseline: `01e1e259968c3b9c5ee5d6aea7253392b5eafe92`. Original documentation is retained in `README.upstream.md` and `README.upstream.en.md` for reference; upstream Web logging and single-file download instructions do not apply here.
