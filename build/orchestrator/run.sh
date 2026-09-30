#!/bin/bash
## module:  build/orchestrator
## purpose: ensure the VyOS image for BUILD_TOKEN exists - build it on Cloud Build if needed,
##          register it in Compute Engine, prune old images, and block until done
## inputs:  PROJECT_ID REGION BUCKET PREFIX SOURCE_OBJECT BUILD_TOKEN BUILDER_SA
##          RELEASE DISK_SIZE SSH_PASSWORD_AUTH VYOS_BUILD_REF VYOS_BUILD_IMAGE
##          MACHINE_TYPE BUILD_TIMEOUT (e.g. 3600s) WAIT_TIMEOUT (seconds, 0=unbounded) POLL_INTERVAL
##          IMAGE_NAME IMAGE_FAMILY IMAGE_STORAGE_LOCATION IMAGE_LABELS (k=v,...) IMAGE_RETENTION (0=keep all)
## outputs: gs://${BUCKET}/${PREFIX}builds/${BUILD_TOKEN}/{manifest.json,image.tar.gz}, image ${IMAGE_NAME};
##          on failure a gs://.../builds/${BUILD_TOKEN}/failed-<execution> marker that lets the next apply retry
## needs:   gcloud, python3 (runs in the Cloud Run job as the runner service account)
set -euo pipefail

TAG="[ VYOS/IMAGE-BUILD ]"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-0}"
POLL_INTERVAL="${POLL_INTERVAL:-20}"
BUILD_URI="gs://${BUCKET}/${PREFIX}builds/${BUILD_TOKEN}"
MANIFEST_URI="${BUILD_URI}/manifest.json"
TARBALL_URI="${BUILD_URI}/image.tar.gz"
MANAGED_LABEL="managed-by=mod-vyos-image"
export CLOUDSDK_CORE_PROJECT="${PROJECT_ID}"
export CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED=False
log() { printf "%s %s\n" "${TAG}" "$*" >&2; }

## a failure marker changes the next plan, so a plain re-apply retries this token
function onExit {
	local RC=$?
	if [[ ${RC} -ne 0 ]]; then
		local MARKER="${BUILD_URI}/failed-${CLOUD_RUN_EXECUTION:-manual-$(date +%s)}"
		log "ERROR: exit ${RC} - writing retry marker [ ${MARKER} ]"
		echo "{\"exit_code\": ${RC}}" | gcloud storage cp - "${MARKER}" >/dev/null 2>&1 || true
	fi
}
trap onExit EXIT

function objectExists {
	gcloud storage objects describe "$1" >/dev/null 2>&1
}

function imageExists {
	gcloud compute images describe "${IMAGE_NAME}" >/dev/null 2>&1
}

function runBuild {
	local SRC_DIR BUILD_ID="" STATUS ELAPSED=0
	SRC_DIR=$(mktemp -d)
	# the build config travels inside the source archive
	gcloud storage cp "gs://${BUCKET}/${SOURCE_OBJECT}" "${SRC_DIR}/source.zip"
	python3 -m zipfile -e "${SRC_DIR}/source.zip" "${SRC_DIR}/src"

	local SUBS="_BUCKET=${BUCKET},_PREFIX=${PREFIX},_BUILD_TOKEN=${BUILD_TOKEN},_RELEASE=${RELEASE}"
	SUBS+=",_DISK_SIZE=${DISK_SIZE},_SSH_PASSWORD_AUTH=${SSH_PASSWORD_AUTH}"
	SUBS+=",_VYOS_BUILD_REF=${VYOS_BUILD_REF},_VYOS_BUILD_IMAGE=${VYOS_BUILD_IMAGE}"
	# retry while newly granted IAM propagates
	for ATTEMPT in $(seq 1 10); do
		if BUILD_ID=$(gcloud builds submit "gs://${BUCKET}/${SOURCE_OBJECT}" \
			--config="${SRC_DIR}/src/cloudbuild.yaml" \
			--region="${REGION}" \
			--service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILDER_SA}" \
			--gcs-source-staging-dir="gs://${BUCKET}/${PREFIX}staging" \
			--machine-type="${MACHINE_TYPE}" \
			--timeout="${BUILD_TIMEOUT}" \
			--substitutions="${SUBS}" \
			--async --format='value(id)'); then
			break
		fi
		log "submit attempt ${ATTEMPT} failed.. sleep 30"
		sleep 30
	done
	[[ -n "${BUILD_ID}" ]] || { log "ERROR: could not submit build"; return 1; }
	log "BUILD [ ${BUILD_ID} ] submitted for token [ ${BUILD_TOKEN} ]"

	while true; do
		STATUS=$(gcloud builds describe "${BUILD_ID}" --region="${REGION}" --format='value(status)' || echo "UNKNOWN")
		case "${STATUS}" in
			SUCCESS) break ;;
			FAILURE|INTERNAL_ERROR|TIMEOUT|CANCELLED|EXPIRED)
				log "ERROR: BUILD [ ${BUILD_ID} ] finished with status [ ${STATUS} ]"
				return 1 ;;
		esac
		log "BUILD [ ${BUILD_ID} ] status [ ${STATUS} ] waiting for SUCCESS.. sleep ${POLL_INTERVAL}"
		sleep "${POLL_INTERVAL}"
		ELAPSED=$((ELAPSED + POLL_INTERVAL))
		if [[ ${WAIT_TIMEOUT} -gt 0 && ${ELAPSED} -ge ${WAIT_TIMEOUT} ]]; then
			log "ERROR: BUILD [ ${BUILD_ID} ] not finished after ${WAIT_TIMEOUT}s"
			return 1
		fi
	done
	log "BUILD [ ${BUILD_ID} ] SUCCESS"
}

function registerImage {
	local VERSION_LABEL LABELS
	VERSION_LABEL=$(gcloud storage cat "${MANIFEST_URI}" | python3 -c \
		'import json,re,sys; print(re.sub(r"[^a-z0-9_-]", "-", json.load(sys.stdin)["vyos_version"].lower())[:63])')
	LABELS="${MANAGED_LABEL},build-token=${BUILD_TOKEN},vyos-version=${VERSION_LABEL}"
	[[ -n "${IMAGE_LABELS:-}" ]] && LABELS="${IMAGE_LABELS},${LABELS}"
	log "IMAGE [ ${IMAGE_NAME} ] registering from [ ${TARBALL_URI} ]"
	gcloud compute images create "${IMAGE_NAME}" \
		--source-uri="${TARBALL_URI}" \
		--family="${IMAGE_FAMILY}" \
		--storage-location="${IMAGE_STORAGE_LOCATION}" \
		--guest-os-features=UEFI_COMPATIBLE,GVNIC,VIRTIO_SCSI_MULTIQUEUE \
		--labels="${LABELS}" \
		--description="VyOS ${VERSION_LABEL} (build ${BUILD_TOKEN})"
}

## other module-built images in the exact family, newest first
## (gcloud's family= filter is a pattern match, so the family is enforced afterwards)
function otherFamilyImages {
	gcloud compute images list --no-standard-images --show-deprecated \
		--filter="labels.managed-by=mod-vyos-image" \
		--sort-by=~creationTimestamp --format='value(name,family)' \
		| awk -v family="${IMAGE_FAMILY}" -v current="${IMAGE_NAME}" '$2 == family && $1 != current {print $1}'
}

## the family resolves to the newest non-deprecated image: make that the current image,
## including when inputs revert to an older build
function pinFamily {
	gcloud compute images deprecate "${IMAGE_NAME}" --state=ACTIVE >/dev/null
	for IMAGE in $(otherFamilyImages); do
		gcloud compute images deprecate "${IMAGE}" --state=DEPRECATED --replacement="${IMAGE_NAME}" >/dev/null \
			|| log "WARNING: could not deprecate [ ${IMAGE} ]"
	done
}

function pruneImages {
	[[ "${IMAGE_RETENTION:-0}" -gt 0 ]] || return 0
	for IMAGE in $(otherFamilyImages | tail -n +"${IMAGE_RETENTION}"); do
		log "IMAGE [ ${IMAGE} ] beyond retention ${IMAGE_RETENTION} - deleting"
		gcloud compute images delete "${IMAGE}" --quiet || log "WARNING: could not delete [ ${IMAGE} ]"
	done
}

## converge on: image registered AND manifest present (Terraform reads the manifest)
##   image + manifest            -> nothing to do
##   manifest + tarball          -> register the image if missing
##   otherwise (e.g. new bucket) -> build, then register the image if missing
if imageExists && objectExists "${MANIFEST_URI}"; then
	log "IMAGE [ ${IMAGE_NAME} ] and manifest already present"
else
	if objectExists "${MANIFEST_URI}" && objectExists "${TARBALL_URI}"; then
		log "ARTIFACTS [ ${BUILD_URI}/ ] already present - skipping build"
	else
		runBuild
		objectExists "${MANIFEST_URI}" && objectExists "${TARBALL_URI}" \
			|| { log "ERROR: build succeeded but its manifest or tarball is missing"; exit 1; }
	fi
	if imageExists; then
		log "IMAGE [ ${IMAGE_NAME} ] already present - artifacts restored"
	else
		registerImage
	fi
fi
pinFamily
pruneImages
log "IMAGE [ ${IMAGE_NAME} ] family [ ${IMAGE_FAMILY} ] is ALIVE !!"
