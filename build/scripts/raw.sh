#!/bin/bash
## module:  build/raw
## purpose: build a raw disk from the remastered ISO using upstream build-vyos-image --reuse-iso
## inputs:  WORKDIR DISK_SIZE (GB)
## outputs: ${WORKDIR}/vyos-build/build/vyos-<version>-gce-amd64.raw
## needs:   root, privileged container, loop + device-mapper (runs inside vyos/vyos-build)
set -euo pipefail

W="${WORKDIR:-/work}"
cd "${W}/vyos-build"
cp "${W}/flavors/gce.toml" data/build-flavors/gce.toml
./build-vyos-image gce \
	--architecture amd64 \
	--reuse-iso "${W}/vyos-gce.iso" \
	--disk-size "${DISK_SIZE:-10}" \
	--build-by "mod-vyos-image"
ls -la build/*.raw >&2
