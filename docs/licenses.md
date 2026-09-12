# Binary component license record

This file is an audit index, not a replacement for upstream license terms.

## StarFive IMG BXE-4-32 PVR DDK

- Component: `img-gpu-powervr-bin-1.19.6345021.tar.gz`
- Source: [StarFive soft_3rdpart](https://github.com/starfive-tech/soft_3rdpart)
- Source commit: `b60da16be1b36453aa46599889c28310fd148fb8`
- SHA256: `9dcaf2084b13e59c4e50a4a288f5de56f8e9ee631627a3e818591675bf61311a`
- License class: proprietary vendor binary; see the applicable StarFive/Imagination terms.
- Redistribution status: project owner confirmed authorization for inclusion in
  this project's Debian package, image, Actions artifact and Release.
- Packaging: `scripts/build-gpu-package.sh`
- Debian package: `jh7110-pvr-rogue`
- Installed content: PVR firmware, userspace libraries, Vulkan/OpenCL ICD and
  test utilities. The archive's `rc.pvr` init script is deliberately not
  shipped - it loads the retired `drm_starfive` module; the package enables
  `jh7110-pvr.service`, which loads `pvrsrvkm`.
- Audit record in artifact: `/usr/share/doc/jh7110-pvr-rogue/SOURCE`

The payload is intentionally downloaded from the locked source and is not
committed to Git. Any change of archive, DDK version, source commit or
redistribution scope requires updating `sources.lock`, this record and the
release review before publishing.

## Other components

Linux, U-Boot, OpenSBI, Mesa, FFmpeg, GStreamer, Debian packages and board
firmware retain their respective upstream or vendor licenses. New binary
components must be added here before they are included in an image or release.
