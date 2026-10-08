# Static Proxmox Backup Client without FUSE

Unofficial fully static Linux **x86_64** build of upstream **v4.2.0**, pinned to commit
`035c449897fafc228c8bbf3a5b5ba38564478ac7`.

## What changes

`no-fuse.patch` removes the unconditional `pbs-fuse-loop` and `pbs-pxar-fuse`
dependencies and the `mount`, `map`, and `unmap` commands. Archive access uses
`pxar` types directly, so `backup`, `restore`, and `catalog shell` remain available.
This is not an upload-only CLI: the other non-FUSE commands are retained.

`build.sh` prepares a client-only Cargo workspace from the upstream manifests.
This prevents unused server, file-restore, and pxar CLI workspace members from
pulling FUSE back into dependency resolution. It uses Proxmox's signed Debian
**trixie devel** repository and upstream's Debian Cargo registry configuration.
No FUSE packages or bindings are installed in the build container.

## Build and download

The workflow `.github/workflows/proxmox-backup-client.yml` runs **only manually**:

```sh
gh workflow run proxmox-backup-client.yml --repo pandada8/random-binary
gh run list --repo pandada8/random-binary --workflow proxmox-backup-client.yml
```

Release tags follow the upstream version, e.g. `proxmox-backup-client-v4.2.0`.
Rebuilding the same version replaces its binary and updates its Release notes
without creating another tag. Both the Actions artifact and Release contain
only the `proxmox-backup-client` binary.
No source archive, patch, README, dependency report, or checksum file is uploaded.
The binary SHA256 is recorded in the Release notes.

```sh
gh release download --repo pandada8/random-binary --pattern proxmox-backup-client
chmod +x proxmox-backup-client
```

Install the executable in your PATH. No extraction or shared library installation
is needed.

## Compatibility and limitations

This is a **fully static GNU/glibc Linux binary**, built on Debian 13 (trixie),
not a musl build. It follows upstream's static build approach: `+crt-static`,
`OPENSSL_STATIC=1`, and an empty `libsystemd.a` archive for unused systemd linkage.
That archive implements no functions: live systemd FFI calls would fail to link.
It requires neither shared libraries, libfuse, nor `/dev/fuse`. A compatible
x86_64 Linux kernel and ordinary runtime data (e.g. DNS configuration and CA
certificates for TLS) are still required; static linking does not embed them.
Optional external CLI tools are not bundled. This is not a promise of support
for every Linux kernel/distribution.

CI checks the Cargo dependency tree and installed packages for FUSE. It also
rejects ELF `DT_NEEDED` and `PT_INTERP`, checks `ldd`, and runs help for
backup/restore/catalog shell in an **empty chroot without any shared libraries**.
It does **not** perform a live
backup against a PBS server, because the workflow does not require credentials.

Upstream tag/commit, Actions revisions, and the Debian image digest are pinned.
APT packages are **not** snapshot-pinned: rebuilds may use newer compatible
packaged crates. Dependency installation and verification output remain in the
CI logs; this is not a bit-for-bit reproducible build guarantee.

## Updating the recipe

1. Confirm the new upstream release tag and its commit.
2. Update `UPSTREAM_TAG` and `UPSTREAM_COMMIT` in the workflow.
3. Rebase `no-fuse.patch` onto that tag and test it with `git apply --check`.
4. Run the workflow and inspect its build and no-FUSE verification results.

Only build recipes and patches are committed here, not upstream source or
binaries. Upstream copyright and AGPL licensing remain in force. The pinned
upstream commit, public patch, and build script describe the source changes
and how to build the modified client.
