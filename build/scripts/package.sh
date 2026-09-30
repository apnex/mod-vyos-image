#!/bin/bash
## module:  build/package
## purpose: package the raw disk in GCE import format and publish it with a manifest
## inputs:  WORKDIR BUCKET PREFIX BUILD_TOKEN BUILD_ID VYOS_BUILD_IMAGE SSH_PASSWORD_AUTH
## outputs: gs://${BUCKET}/${PREFIX}builds/<token>/{image.tar.gz,manifest.json}
set -euo pipefail

W="${WORKDIR:-/workspace}"
source "${W}/release.env"
RAW=$(ls "${W}"/vyos-build/build/*.raw)
VERSION=$(basename "${RAW}" | sed -E 's/^vyos-(.*)-gce-amd64\.raw$/\1/')
# fixed name: consumers can address the tarball from the build token alone
TARBALL="image.tar.gz"
# build-unique path: published artifacts are never overwritten
DEST="gs://${BUCKET}/${PREFIX}builds/${BUILD_TOKEN:-${BUILD_ID}}"
# plain uploads: composite objects need crc32c-aware clients to verify
export CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED=False

mkdir -p "${W}/out"
mv "${RAW}" "${W}/out/disk.raw"
DISK_BYTES=$(stat -c %s "${W}/out/disk.raw")
echo "[ PACKAGE ] ${VERSION} disk.raw ${DISK_BYTES} bytes" >&2
tar --format=oldgnu -Sczf "${W}/out/${TARBALL}" -C "${W}/out" disk.raw
TAR_SHA256=$(sha256sum "${W}/out/${TARBALL}" | cut -d' ' -f1)

python3 - "${W}/out/manifest.json" <<-EOF
	import json, sys
	pkgs = dict(l.split(' ', 1) for l in open("${W}/remaster/packages.txt").read().splitlines() if l)
	json.dump({
	  "vyos_version": "${VERSION}",
	  "release_tag": "${TAG}",
	  "iso": {"name": "${ISO_NAME}", "uri": "${ISO_URI}", "sha256": "${ISO_SHA256}"},
	  "vyos_build": {"commit": open("${W}/vyos-build.sha").read().strip(), "image": "${VYOS_BUILD_IMAGE}"},
	  "packages": pkgs,
	  "ssh_password_authentication": "${SSH_PASSWORD_AUTH:-false}" == "true",
	  "disk": {"bytes": ${DISK_BYTES}, "gb": ${DISK_BYTES} // 1073741824},
	  "tarball": {"name": "${TARBALL}", "uri": "${DEST}/${TARBALL}", "sha256": "${TAR_SHA256}"},
	  "build_token": "${BUILD_TOKEN}",
	  "build_id": "${BUILD_ID}"
	}, open(sys.argv[1], "w"), indent=2)
EOF
cat "${W}/out/manifest.json" >&2

gcloud storage cp "${W}/out/${TARBALL}" "${DEST}/${TARBALL}"
# manifest last: its presence is the completion signal
gcloud storage cp "${W}/out/manifest.json" "${DEST}/manifest.json"
