# Correct the actual KVM descriptor audit omission — 2026-09-10

The approved exact initial run executed once and stopped before QMP cont because
allowed_fd did not recognize the observed anon_inode:kvm-vcpu-stats:0. Actual
unprivileged UID/GIDs, capabilities0, NoNewPrivs1 and Seccomp2 were verified.
The owned QEMU was terminated, console0 bytes, no guest execution. This was our
source predicate's ValueError, not a tool/device denial or nested capability
failure. No prior denied operation is retried or rerouted. Full raw failed receipt,
parent invocation and original source/freeze are preserved.

Primary KVM API/Linux6.8/QEMU8.2.2 sources explain this read-only statistics
interface. The correction recognizes only exact anon_inode:kvm-vcpu-stats:0–3
for the four configured CPUs AND actual fdinfo flags equal O_CLOEXEC (access
mode read-only), bounded4096 bytes. Unknown indices, missing/duplicate flags,
write access, absent CLOEXEC, sockets and other prior disallowed objects fail.
Read only the new owned QEMU fdinfo metadata; no data from the descriptor itself,
no old Android maps/proc/run-as operation. The kernel object has no write/ioctl
operations. All existing KVM device identity, argv, privilege, seccomp, PCI/block,
image/hash and resource checks remain. No sandbox/host permission change.

Genuine new RED (missing metadata-aware API) preceded the change; all13 tests now
pass. This adds expected kernel-object recognition with tighter metadata checks,
not a bypass. New output directory and source/dropper hashes prevent overwriting
or repeating the old source. Image bytes, guest script and scope are unchanged.
Request exact independent review before ONE corrected new base observation.
If approved it remains only base prerequisites; no relay/AVD/current-call gate.
