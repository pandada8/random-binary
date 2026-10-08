# random-binary

Build recipes and patches for standalone binaries. Upstream source and compiled
binaries are not committed; artifacts are published through manually triggered
GitHub Actions to GitHub Releases.

## Recipes

- [proxmox-backup-client](proxmox-backup-client/): fully static Linux x86_64
  client, pinned to Proxmox Backup v4.2.0, with FUSE dependencies and commands
  removed. Backup, restore and catalog shell are retained.

Run **Actions → Build proxmox-backup-client (static, no FUSE) → Run workflow**.
See the recipe README for architecture, checks, licensing and update instructions.
