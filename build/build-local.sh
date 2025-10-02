#!/bin/sh
# FM350-GL Local Image Builder Script
# POSIX compliant

set -eu

################################################################################
# CONFIGURATION
################################################################################

OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.0}"
BOARD="${BOARD:-x86}"
SUBTARGET="${SUBTARGET:-64}"
PROFILE="${PROFILE:-generic}"

IB_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${BOARD}/${SUBTARGET}/openwrt-imagebuilder-${OPENWRT_VERSION}-${BOARD}-${SUBTARGET}.Linux-x86_64.tar.xz"

# Package lists
PACKAGES_RUNTIME="kmod-usb-core kmod-usb2 kmod-usb3 kmod-usb-serial kmod-usb-serial-wwan kmod-usb-serial-option kmod-usb-net kmod-usb-net-rndis ip-full coreutils-timeout dnsmasq ca-bundle ca-certificates"

PACKAGES_DIAG="ethtool tcpdump iperf3 mtr traceroute curl wget-ssl bind-dig socat picocom comgt usbutils pciutils htop nano vim jq less screen minicom atinout lsof mc"

PACKAGES_LUCI="luci luci-ssl luci-app-firewall luci-i18n-base-pl luci-i18n-firewall-pl uhttpd uhttpd-mod-ubus firewall4 nftables"

PACKAGES_ALL="$PACKAGES_RUNTIME $PACKAGES_DIAG $PACKAGES_LUCI"

################################################################################
# FUNCTIONS
################################################################################

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

################################################################################
# MAIN
################################################################################

log "FM350-GL Image Builder v21.1-ULTIMATE"
log "OpenWrt: $OPENWRT_VERSION"
log "Target: $BOARD/$SUBTARGET"
log "Profile: $PROFILE"
echo

# Check prerequisites
command -v wget >/dev/null 2>&1 || die "wget not found"
command -v tar >/dev/null 2>&1 || die "tar not found"
command -v make >/dev/null 2>&1 || die "make not found"

# Get script directory
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

log "Repository root: $REPO_ROOT"

# Create build directory
BUILD_DIR="$REPO_ROOT/build-output"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Download Image Builder
IB_FILE="$(basename "$IB_URL")"
IB_DIR="${IB_FILE%.tar.xz}"

if [ ! -f "$IB_FILE" ]; then
  log "Downloading Image Builder..."
  wget -q --show-progress "$IB_URL" || die "Failed to download Image Builder"
else
  log "Image Builder already downloaded"
fi

# Extract Image Builder
if [ ! -d "$IB_DIR" ]; then
  log "Extracting Image Builder..."
  tar -Jxf "$IB_FILE" || die "Failed to extract Image Builder"
else
  log "Image Builder already extracted"
fi

cd "$IB_DIR"

# Copy files
log "Copying overlay files..."
rm -rf files
cp -r "$REPO_ROOT/files" . || die "Failed to copy files"

# Make scripts executable
chmod +x files/usr/sbin/fm350-manager
chmod +x files/usr/lib/fm350/functions.sh
chmod +x files/lib/netifd/proto/fm350.sh
chmod +x files/etc/init.d/fm350-manager
chmod +x files/etc/hotplug.d/usb/*
chmod +x files/etc/uci-defaults/99-fm350
chmod +x files/scripts/*.sh

# Build image
log "Building image..."
log "Packages: $PACKAGES_ALL"
echo

make image \
  PROFILE="$PROFILE" \
  PACKAGES="$PACKAGES_ALL" \
  FILES=files/ \
  || die "Build failed"

echo
log "Build complete!"
log "Artifacts location: $BUILD_DIR/$IB_DIR/bin/targets/$BOARD/$SUBTARGET/"
echo

# List artifacts
ls -lh "bin/targets/$BOARD/$SUBTARGET/"/*.img.gz "bin/targets/$BOARD/$SUBTARGET/"/*.tar.gz 2>/dev/null || true

echo
log "Flash image to device:"
log "  dd if=openwrt-*-generic-ext4-combined.img.gz of=/dev/sdX bs=4M status=progress"
log "  # or use web upgrade: openwrt-*-generic-squashfs-combined.img.gz"