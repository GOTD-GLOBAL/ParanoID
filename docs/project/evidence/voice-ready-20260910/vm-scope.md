# Exact RAM-only VM capability scope — 2026-09-10

Purpose: establish a genuinely isolated disposable development guest before any
relay exposure or defensive packet tests. This phase acquires official tools and
boots ONE guest that only reports isolation and powers off. No relay/server,
socket, sink, packet probe or production data enters this guest.

Prior refusals remain stopped. media_discovery was rejected before execution;
never reissued or routed elsewhere. web.open refused two dated cloud-image
checksum/signature URLs as unsafe (non-retryable); cloud-signature-fetch-refusal.json
records the exact outcomes. Neither those resources nor any equivalent cloud
image acquisition will be fetched with another tool/provider. The new design has
NO cloud image, no cloud-init, seed, disk, cloud metadata client, or downloaded
root filesystem: a small custom initramfs contains only an official signed-package
BusyBox binary and the supplied fixed init script, booted with an official Ubuntu
kernel. It is materially smaller and has no discovery/network configuration code.
Do not interpret an approval as permission to revisit the refused operation.

Host: local development65.108.43.251, not production157.180.49.125. Read-only
vm-host-preflight.json records identity, ext4/dev/md2 with249056808960 free bytes,
uid1003 and no accessible KVM. Owner explicitly authorized pinned local tooling
extraction and disposable development VM. Necessary official HTTPS acquisition
is within that request; host firewall/accounts/auth/package configuration and
production services are not changed. Do not invent a new general host permission.

Tool inputs: tooling-plan-v2.json selects19 official Ubuntu .deb files totaling
34870568 bytes including qemu8.2.2+ds-0ubuntu1.18, its missing dependencies,
SeaBIOS, linux-image-6.8.0-139-generic6.8.0-139.139, and
busybox-static1:1.36.1-6ubuntu3.1. No download has run. Actual apt-chain-v2.json
records gpgv validation against root-controlled Ubuntu archive keyring pinned to
F6ECB3762474EDA9D21B7022871920D1991BC93C, signed InRelease→decompressed Packages
size/SHA256→exact version/Filename/Size/SHA256 stanza for every package. Local
keyring is the trust anchor; its hash, verifier and plan hashes are recorded.
Installed-status `now` is not a downloadable package source; initial selection
assertion and correction are preserved in tooling-v2-origin-observation.json.
No trust flag was overridden; actual signed archive stanzas are independently matched.

acquire_vm_tools_v2.py: unprivileged uid1003, owned exclusive directory, HTTPS
canonical archive origin, one attempt per pinned package, exact streamed byte/hash
limits and partial-file deletion on failure. Downloads≤64MiB, per-file OS cap128MiB,
expanded files≤256MiB; tar data filter never disabled, absolute compatibility
symlinks omitted and recorded (no omitted link used to boot). No install or
maintainer scripts. Run version/library inspection only, record executable,
firmware/kernel/BusyBox and resolved library hashes, reject nontrusted/writable
libraries or setuid/setgid extracted files. Root-controlled existing host libraries
are an explicit part of the QEMU trust boundary. Every failure stops; no retry to PASS.

boot_ram_vm.py: run exactly once after source freeze, successful tools receipt,
all input/library hash checks and >=64GiB free-space margin. TCG only,512MiB/2CPU,
300sec maximum after isolation checks, no guest disk (RAM-only initramfs≤8MiB),
console monitored≤8MiB and OS file-size limit1GiB. Fixed write targets below owned
vm-tooling-v2/ram-vm-runtime, maximum additional fixed files under2GiB including
stderr/QMP/log caps, free-space monitored. No host quota/firewall/mount manipulation.

Boot PAUSED (-S), exact running/proc PID cmdline and executable hash, four UID
fields1003/CapEff0, fd inventory (no socket, KVM, outside-tree file except trusted
libraries/devnull/urandom), QMPquery-pci/query-block via inherited stdio pipes.
QEMU sandbox on (no fallback), no default devices/user config/display/NIC/monitor;
explicit serial goes to one owned file. No netdev/tap/bridge/slirp, vsock/usb-net,
9p/fsdev/virtfs/virtiofsd, guest agent, passthrough, host root/key share or external
control listener. QMP must show no network-class PCI device and zero guest disks
BEFORE guest cont. Then actual guest output must report only lo, no external
or default route, no network PCI class, no production markers, with unique nonce.
Terminate only owned child on error, preserve outcome; no repeat-to-green.

Limits of the claim: five pure offline VM tests validate parser/initramfs rules,
not runtime isolation. Successful actual boot means ISOLATION_OBSERVED only,
not rendered configuration equalling enforcement or a capability removal from
QEMU. Inventory is point-in-time, source/argv and QEMU trusted. Future defensive
verification uses ONE guest and guest-only loopback/dummy destinations/nftables,
never a second VM/host TCP pair. Full systemd/PG/coturn fixture and exact finite
packet scripts need separate source review before execution. TURN-RT01/TURN-ACL02,
CLI closure, persistent production unit, full coordinated installer, CALL-CURRENT01,
deployment and artifact review remain NOT RUN. No synthetic PASS receipts.
