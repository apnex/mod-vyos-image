#!/bin/bash
## module:  build/remaster
## purpose: add VyOS cloud-init (GCE datasource) and the raw-build activation hint to a VyOS ISO
## inputs:  WORKDIR (holds vyos.iso and vyos-build/) VYOS_MIRROR VYOS_TRAIN SSH_PASSWORD_AUTH (true|false)
## outputs: ${WORKDIR}/vyos-gce.iso ${WORKDIR}/remaster/packages.txt
## needs:   root, privileged container, loop devices (runs inside vyos/vyos-build)
set -euo pipefail

W="${WORKDIR:-/work}"
R="${W}/remaster"
ROOT="${R}/rootfs"
VYOS_MIRROR="${VYOS_MIRROR:-https://packages.vyos.net/repositories/rolling}"
VYOS_TRAIN="${VYOS_TRAIN:-rolling}"
REMASTER_TAG="mod-vyos-image-remaster"

cleanup() {
	for m in dev/pts dev proc sys; do
		mountpoint -q "${ROOT}/${m}" && umount -l "${ROOT}/${m}" || true
	done
	mountpoint -q "${R}/iso" && umount "${R}/iso" || true
}
trap cleanup EXIT

rm -rf "${R}"; mkdir -p "${R}/iso"
mount -o loop,ro "${W}/vyos.iso" "${R}/iso"
echo "[ REMASTER ] unpacking squashfs" >&2
unsquashfs -no-progress -d "${ROOT}" "${R}/iso/live/filesystem.squashfs"

## chroot preparation
for m in dev dev/pts proc sys; do mount --bind "/${m}" "${ROOT}/${m}"; done
if [[ -e "${ROOT}/etc/resolv.conf" || -L "${ROOT}/etc/resolv.conf" ]]; then
	mv "${ROOT}/etc/resolv.conf" "${ROOT}/etc/resolv.conf.${REMASTER_TAG}"
fi
cp /etc/resolv.conf "${ROOT}/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "${ROOT}/usr/sbin/policy-rc.d"
chmod +x "${ROOT}/usr/sbin/policy-rc.d"

## temporary apt sources: debian bookworm + vyos train, same pin priority as build-vyos-image
mkdir -p "${ROOT}/etc/apt/keyrings" "${ROOT}/etc/apt/sources.list.d" "${ROOT}/etc/apt/preferences.d"
cp "${W}/vyos-build/data/live-build-config/archives/vyos-dev.key.chroot" "${ROOT}/etc/apt/keyrings/${REMASTER_TAG}.asc"
cat > "${ROOT}/etc/apt/sources.list.d/${REMASTER_TAG}.list" <<-EOF
	deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
	deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
	deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
	deb [signed-by=/etc/apt/keyrings/${REMASTER_TAG}.asc] ${VYOS_MIRROR} ${VYOS_TRAIN} main
EOF
cat > "${ROOT}/etc/apt/preferences.d/${REMASTER_TAG}" <<-EOF
	Package: *
	Pin: release n=${VYOS_TRAIN}
	Pin-Priority: 600
EOF

echo "[ REMASTER ] installing cloud-init" >&2
export DEBIAN_FRONTEND=noninteractive
chroot "${ROOT}" apt-get update
chroot "${ROOT}" apt-get -s install --no-install-recommends cloud-init | grep -E '^(Inst|Remv) ' | tee "${R}/apt-plan.txt" >&2
if grep -qE '^Inst vyos-1x ' "${R}/apt-plan.txt"; then
	echo "[ REMASTER ] WARNING: cloud-init install would upgrade vyos-1x (image/package drift)" >&2
fi
chroot "${ROOT}" apt-get install -y --no-install-recommends cloud-init

## GCE datasource, as the retired upstream tools/cloud-init/GCE/90_dpkg.cfg did
## metadata_url uses the link-local IP: the ephemeral DHCP lease in init-local
## configures no resolver, so metadata.google.internal is not resolvable (spike S3)
cat > "${ROOT}/etc/cloud/cloud.cfg.d/90_dpkg.cfg" <<-EOF
	# written by ${REMASTER_TAG}
	datasource_list: [ GCE, None ]
	datasource:
	  GCE:
	    metadata_url: http://169.254.169.254/computeMetadata/v1/
EOF

## the default config carries user vyos with the well-known password; keep it for
## the serial console but refuse it over SSH (cc_vyos_userdata applies this last)
if [[ "${SSH_PASSWORD_AUTH:-false}" != "true" ]]; then
	cat > "${ROOT}/etc/cloud/cloud.cfg.d/91_vyos_gce.cfg" <<-EOF
		# written by ${REMASTER_TAG}
		vyos_config_commands:
		  - set service ssh disable-password-authentication
	EOF
	echo "[ REMASTER ] SSH password authentication disabled" >&2
else
	echo "[ REMASTER ] WARNING: SSH password authentication left enabled" >&2
fi

## raw-build activation hint: build-vyos-image only writes this for live-build raw builds
## (vyos-1x python/vyos/utils/activate.py:init_activation_list)
touch "${ROOT}/usr/share/vyos/.activation_hint"

chroot "${ROOT}" dpkg-query -W -f='${Package} ${Version}\n' cloud-init vyos-1x | tee "${R}/packages.txt" >&2

## remove every trace of the temporary build configuration
chroot "${ROOT}" apt-get clean
rm -rf "${ROOT}/var/lib/apt/lists/"*
rm -f "${ROOT}/etc/apt/keyrings/${REMASTER_TAG}.asc" \
	"${ROOT}/etc/apt/sources.list.d/${REMASTER_TAG}.list" \
	"${ROOT}/etc/apt/preferences.d/${REMASTER_TAG}" \
	"${ROOT}/usr/sbin/policy-rc.d" \
	"${ROOT}/etc/resolv.conf"
if [[ -e "${ROOT}/etc/resolv.conf.${REMASTER_TAG}" || -L "${ROOT}/etc/resolv.conf.${REMASTER_TAG}" ]]; then
	mv "${ROOT}/etc/resolv.conf.${REMASTER_TAG}" "${ROOT}/etc/resolv.conf"
fi
cleanup

echo "[ REMASTER ] repacking squashfs" >&2
mksquashfs "${ROOT}" "${R}/filesystem.squashfs" -noappend -no-progress \
	-comp xz -Xbcj x86 -b 256k -always-use-fragments
echo "[ REMASTER ] rebuilding ISO" >&2
xorriso -indev "${W}/vyos.iso" -outdev "${W}/vyos-gce.iso" \
	-boot_image any replay \
	-map "${R}/filesystem.squashfs" /live/filesystem.squashfs
rm -rf "${ROOT}"
ls -la "${W}/vyos.iso" "${W}/vyos-gce.iso" >&2
