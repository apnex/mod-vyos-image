#!/bin/bash
## module:  build/ingest
## purpose: resolve the VyOS nightly release and stage its ISO, using the bucket as a cache
## inputs:  RELEASE (latest|<tag>) BUCKET PREFIX WORKDIR
## outputs: ${WORKDIR}/vyos.iso ${WORKDIR}/release.env (TAG ISO_NAME ISO_URI ISO_SHA256)
set -euo pipefail

NIGHTLY_REPO_URL="https://github.com/vyos/vyos-nightly-build"

if [[ "${RELEASE}" == "latest" ]]; then
	# the /releases/latest redirect is not subject to GitHub API rate limits
	TAG=$(curl -fsSI "${NIGHTLY_REPO_URL}/releases/latest" \
		| awk -F/ 'tolower($1) ~ /^location: / {print $NF}' | tr -d '\r')
else
	TAG="${RELEASE}"
fi
[[ -n "${TAG}" ]] || { echo "[ INGEST ] ERROR: could not resolve release [ ${RELEASE} ]" >&2; exit 1; }

ISO_NAME="vyos-${TAG}-generic-amd64.iso"
ISO_URI="gs://${BUCKET}/${PREFIX}iso/${TAG}/${ISO_NAME}"
echo "[ INGEST ] release [ ${RELEASE} ] resolved to [ ${TAG} ]" >&2

if gcloud storage objects describe "${ISO_URI}" >/dev/null 2>&1; then
	echo "[ INGEST ] cache HIT [ ${ISO_URI} ]" >&2
	gcloud storage cp "${ISO_URI}" "${WORKDIR}/vyos.iso"
else
	echo "[ INGEST ] cache MISS - downloading from upstream" >&2
	curl -fsSL --retry 5 --retry-delay 10 -o "${WORKDIR}/vyos.iso" \
		"${NIGHTLY_REPO_URL}/releases/download/${TAG}/${ISO_NAME}"
	gcloud storage cp "${WORKDIR}/vyos.iso" "${ISO_URI}"
fi

ISO_SHA256=$(sha256sum "${WORKDIR}/vyos.iso" | cut -d' ' -f1)
cat > "${WORKDIR}/release.env" <<-EOF
	TAG=${TAG}
	ISO_NAME=${ISO_NAME}
	ISO_URI=${ISO_URI}
	ISO_SHA256=${ISO_SHA256}
EOF
cat "${WORKDIR}/release.env" >&2
