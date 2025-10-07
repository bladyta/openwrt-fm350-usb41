#!/bin/sh
# FM350-GL Local Image Builder Script
# POSIX compliant - PRODUCTION READY
# v22.1-STABLE

set -eu

################################################################################
# CONFIGURATION (with ENV override support)
################################################################################

OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.0}"
BOARD="${BOARD:-x86}"
SUBTARGET="${SUBTARGET:-64}"
PROFILE="${PROFILE:-generic}"

IB_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${BOARD}/${SUBTARGET}/openwrt-imagebuilder-${OPENWRT_VERSION}-${BOARD}-${SUBTARGET}.Linux-x86_64.tar.xz"

# Package lists (ca-bundle is MUST-HAVE)
PACKAGES_RUNTIME="kmod-usb-core kmod-usb2 kmod-usb3 kmod-usb-serial kmod-usb-serial-wwan kmod-usb-serial-option kmod-usb-net kmod-usb-net-rndis ip-full coreutils-timeout dnsmasq ca-bundle ca-certificates"

PACKAGES_DIAG="ethtool tcpdump iperf3 mtr traceroute curl wget-ssl bind-dig socat picocom comgt usbutils pciutils htop nano vim jq less screen minicom atinout lsof mc"

PACKAGES_LUCI="luci luci-ssl luci-app-firewall luci-i18n-base-pl luci-i18n-firewall-pl uhttpd uhttpd-mod-ubus firewall4 nftables"

PACKAGES_ALL="${PACKAGES_ALL:-$PACKAGES_RUNTIME $PACKAGES_DIAG $PACKAGES_LUCI}"

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

check_deps() {
  log "Checking dependencies..."
  
  local missing=""
  for cmd in wget tar make; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing="$missing $cmd"
    fi
  done
  
  if [ -n "$missing" ]; then
    log "Missing dependencies:$missing"
    log "Installing..."
    
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update
      sudo apt-get install -y wget tar make
    else
      die "Please install:$missing"
    fi
  fi
  
  log "✓ All dependencies present"
}

################################################################################
# MAIN
################################################################################

log "=========================================="
log "FM350-GL Image Builder v22.1-STABLE"
log "=========================================="
log "OpenWrt: $OPENWRT_VERSION"
log "Target: $BOARD/$SUBTARGET"
log "Profile: $PROFILE"
echo

check_deps

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

log "Repository root: $REPO_ROOT"

# Verify repo structure
if [ ! -d "$REPO_ROOT/files" ]; then
  die "Repository structure invalid - missing files/ directory"
fi

BUILD_DIR="$REPO_ROOT/build-output"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

IB_FILE="$(basename "$IB_URL")"
IB_DIR="${IB_FILE%.tar.xz}"

if [ ! -f "$IB_FILE" ]; then
  log "Downloading Image Builder..."
  wget -q --show-progress "$IB_URL" || die "Failed to download Image Builder"
else
  log "✓ Image Builder already downloaded"
fi

if [ ! -d "$IB_DIR" ]; then
  log "Extracting Image Builder..."
  tar -Jxf "$IB_FILE" || die "Failed to extract Image Builder"
else
  log "✓ Image Builder already extracted"
fi

cd "$IB_DIR"

log "Copying overlay files..."
rm -rf files
cp -r "$REPO_ROOT/files" . || die "Failed to copy files"

# Set permissions
chmod +x files/usr/sbin/fm350-manager 2>/dev/null || true
chmod +x files/usr/lib/fm350/functions.sh 2>/dev/null || true
chmod +x files/lib/netifd/proto/fm350.sh 2>/dev/null || true
chmod +x files/etc/init.d/fm350-manager 2>/dev/null || true
chmod +x files/etc/hotplug.d/usb/* 2>/dev/null || true
chmod +x files/etc/uci-defaults/99-fm350 2>/dev/null || true
chmod +x files/scripts/*.sh 2>/dev/null || true

log "Building image..."
log "Packages: $(echo "$PACKAGES_ALL" | wc -w) total"
echo

make image \
  PROFILE="$PROFILE" \
  PACKAGES="$PACKAGES_ALL" \
  FILES=files/ \
  || die "Build failed"

echo
log "=========================================="
log "✓ BUILD COMPLETE!"
log "=========================================="
echo

OUTPUT_DIR="bin/targets/$BOARD/$SUBTARGET"
log "Build artifacts:"
ls -lh "$OUTPUT_DIR"/*.img.gz "$OUTPUT_DIR"/*.tar.gz 2>/dev/null || true

echo
log "Artifacts location:"
log "  $BUILD_DIR/$IB_DIR/$OUTPUT_DIR/"
echo
log "Flash to device:"
log "  gunzip openwrt-*-ext4-combined.img.gz"
log "  dd if=openwrt-*-ext4-combined.img of=/dev/sdX bs=4M status=progress"
echo
log "Download to local machine:"
log "  scp root@vps:$BUILD_DIR/$IB_DIR/$OUTPUT_DIR/*.img.gz ."
