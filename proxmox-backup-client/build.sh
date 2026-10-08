#!/usr/bin/env bash
# Run as root in the pinned Debian container; all source/output directories are disposable.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
recipe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir=${1:?usage: build.sh SOURCE_DIR OUTPUT_DIR}
output_dir=${2:?usage: build.sh SOURCE_DIR OUTPUT_DIR}
: "${UPSTREAM_TAG:?}" "${UPSTREAM_COMMIT:?}"
mkdir -p "$output_dir"
output_dir=$(realpath "$output_dir")
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
cd "$source_dir"
[[ $(git rev-parse HEAD) == "$UPSTREAM_COMMIT" ]]
git apply --check "$recipe_dir/no-fuse.patch"
git apply "$recipe_dir/no-fuse.patch"

# Proxmox publishes its Rust crates as Debian source packages, not all on crates.io.
# Keep upstream's /usr/share/cargo/registry source replacement and use signed APT.
curl --fail --silent --show-error --location \
  https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
  -o /usr/share/keyrings/proxmox-archive-keyring.gpg
printf '%s\n' \
  'deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] http://download.proxmox.com/debian/devel trixie main' \
  > /etc/apt/sources.list.d/proxmox-devel.list
apt-get update

# Make a client-only virtual workspace. Otherwise Cargo resolves unused server,
# pxar-bin and file-restore members too, bringing FUSE back into Cargo.lock.
# Discover the local dependency closure rather than maintaining a duplicated list.
python3 - "$work_dir" <<'PY'
import pathlib
import re
import sys
import tomllib

root = pathlib.Path('Cargo.toml')
original = root.read_text()
workspace = tomllib.loads(original)
shared = workspace['workspace']['dependencies']
local = {name: spec['path'] for name, spec in shared.items()
         if isinstance(spec, dict) and 'path' in spec}
members = set()
external = set()
pending = ['proxmox-backup-client']
while pending:
    member = pending.pop()
    if member in members:
        continue
    members.add(member)
    manifest = tomllib.loads((pathlib.Path(member) / 'Cargo.toml').read_text())
    for section in ('dependencies', 'build-dependencies', 'dev-dependencies'):
        for name, spec in manifest.get(section, {}).items():
            if name in local:
                pending.append(local[name])
            else:
                external.add(name)

# Retain upstream version constraints and workspace.package verbatim.
def table(name):
    match = re.search(r'^\[' + re.escape(name) + r'\]\n(.*?)(?=^\[|\Z)',
                      original, re.M | re.S)
    if not match:
        raise RuntimeError(f'missing [{name}]')
    return match.group(0).rstrip() + '\n'

root.write_text(table('workspace.package') + '\n[workspace]\nresolver = "2"\nmembers = [\n'
                + ''.join(f'    "{member}",\n' for member in sorted(members))
                + ']\n\n' + table('workspace.dependencies'))

# Install the Debian feature packages declared by this exact upstream tag,
# filtered to the external crates used by the client workspace. APT brings in
# their transitive dependencies. Never install FUSE or the FUSE Rust bindings.
control = pathlib.Path('debian/control').read_text().split('\n\n', 1)[0]
packages = sorted(set(re.findall(r'\blibrust-[a-z0-9.+-]+-dev\b', control)))
required = []
for package in packages:
    if 'fuse' in package:
        continue
    if any(re.match(r'librust-' + re.escape(name.replace('_', '-')) + r'-\d', package)
           for name in external):
        required.append(package)
if not required:
    raise RuntimeError('no Debian Rust dependencies found')
pathlib.Path(sys.argv[1], 'rust-build-packages.txt').write_text('\n'.join(required) + '\n')
print('Client-only workspace:', ', '.join(sorted(members)))
PY

mapfile -t rust_packages < "$work_dir/rust-build-packages.txt"
apt-get install -y --no-install-recommends \
  cargo rustc build-essential pkg-config clang libclang-dev \
  libssl-dev libacl1-dev libsystemd-dev libudev-dev uuid-dev libpam0g-dev \
  libzstd-dev liblzma-dev libcrypt-dev binutils file \
  "${rust_packages[@]}"

# Do not reuse a lockfile produced against a different source registry.
rm -f Cargo.lock
cargo generate-lockfile --offline
cargo tree --offline --locked -p proxmox-backup-client --prefix none \
  | tee "$work_dir/cargo-tree.txt"
if grep -Eiq '(^|[ /_-])fuse([ _-]|$|[0-9])' "$work_dir/cargo-tree.txt"; then
  echo 'ERROR: FUSE remains in the client dependency graph' >&2
  exit 1
fi
if dpkg-query -W -f='${binary:Package}\n' | grep -E '^(libfuse|fuse3|librust-proxmox-fuse)'; then
  echo 'ERROR: FUSE was installed in the build environment' >&2
  exit 1
fi

# Follow upstream's GNU/glibc static build strategy, not a musl cross-build.
# proxmox-systemd declares a broad libsystemd link even though this client only
# uses its pure Rust helpers; upstream uses an empty archive to avoid that link.
# This provides NO replacement functions: any live systemd FFI reference would
# fail at link time rather than silently becoming a no-op.
target=x86_64-unknown-linux-gnu
stub_dir="$PWD/target/static-stubs"
mkdir -p "$stub_dir"
printf '!<arch>\n' > "$stub_dir/libsystemd.a"
export OPENSSL_STATIC=1
export RUSTFLAGS="-C target-feature=+crt-static -L native=$stub_dir"
export CARGO_PROFILE_RELEASE_DEBUG=0
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-2}
cargo build --offline --locked --release --target "$target" \
  -p proxmox-backup-client --bin proxmox-backup-client
binary="target/$target/release/proxmox-backup-client"
strip --strip-unneeded "$binary"
file "$binary"
readelf -d "$binary" | tee "$work_dir/elf-dynamic.txt"
readelf -l "$binary" | tee "$work_dir/elf-program-headers.txt"
if grep -Eq 'NEEDED' "$work_dir/elf-dynamic.txt" || \
   grep -Eq 'INTERP' "$work_dir/elf-program-headers.txt"; then
  echo 'ERROR: binary is not fully static (shared library or interpreter present)' >&2
  exit 1
fi
ldd "$binary" > "$work_dir/runtime-libraries.txt" 2>&1 || true
# glibc ldd returns 0 for static PIE, but 1 for some other static ELF files.
if ! grep -Eq 'statically linked|not a dynamic executable' "$work_dir/runtime-libraries.txt"; then
  echo 'ERROR: ldd did not recognize a static binary' >&2
  exit 1
fi
# Smoke-test inside an empty rootfs: no shared libraries, loader, or libfuse.
rootfs="$work_dir/rootfs"
mkdir -p "$rootfs/tmp"
install -m755 "$binary" "$rootfs/proxmox-backup-client"
chroot "$rootfs" /proxmox-backup-client help > "$work_dir/client-help.txt" 2>&1
chroot "$rootfs" /proxmox-backup-client help backup > "$work_dir/backup-help.txt" 2>&1
chroot "$rootfs" /proxmox-backup-client help restore > /dev/null 2>&1
chroot "$rootfs" /proxmox-backup-client help catalog shell > /dev/null 2>&1
rm -rf "$rootfs"
if grep -Eq '(^|[[:space:]])(mount|map|unmap)([[:space:]]|$)' "$work_dir/client-help.txt"; then
  echo 'ERROR: FUSE commands remain in CLI help' >&2
  exit 1
fi

# Publish only the executable; reports remain in CI logs or temporary files.
install -m755 "$binary" "$output_dir/proxmox-backup-client"
sha256sum "$output_dir/proxmox-backup-client"
