# Build Workflow

Phase 2 provides validation only. It does not claim to produce a bootable image yet.

## Host baseline

The supported build host is Ubuntu 24.04 x86_64. The final build will install the cross compiler, qemu-user-static/binfmt, image tools, device-tree compiler, `mmdebstrap`/`debootstrap`, `xz`, `squashfs-tools`, `dosfstools`, `parted`/`sgdisk`, `shellcheck` and Python YAML support in a dedicated CI environment.

## Validate a profile

```sh
./build.sh visionfive2 profile
./build.sh mars profile
```

## Validate the Phase 2 environment and sources

```sh
./build.sh visionfive2 check
./build.sh mars check
```

`verify-source-lock.sh` resolves the recorded branch/tag and rejects a moving or changed revision. Vendor binary artifacts are identified but are not downloaded by this phase.

## Planned build entry points

After Phase 3–5, these commands will become enabled:

```sh
./build.sh visionfive2
./build.sh mars
make BOARD=visionfive2 image
make BOARD=mars image
```

Until then, `image` exits intentionally so a partial scaffold cannot be mistaken for a tested image builder.
