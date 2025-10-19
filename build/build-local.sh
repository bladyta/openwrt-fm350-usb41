#!/bin/bash
set -eu

# Configuration
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.3}"
BOARD="x86"
SUBTARGET="64"
PROFILE="generic"
IB_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${BOARD}/${SUBTARGET}/openwrt-imagebuilder-${OPENWRT_VERSION}-${BOARD}-${SUBTARGET}.Linux-x86_64.tar.zst"

# Package sets
PACKAGES_RUNTIME="kmod-usb-core kmod-usb2 kmod-usb3 kmod-usb-serial kmod-usb-serial-wwan kmod-usb-serial-option kmod-usb-net kmod-usb-net-rndis ip-full coreutils-timeout dnsmasq ca-bundle ca-certificates"

PACKAGES_DIAG="ethtool tcpdump iperf3 mtr curl wget-ssl bind-dig socat picocom comgt usbutils pciutils htop nano vim jq less screen minicom lsof mc"

PACKAGES_LUCI="luci luci-ssl luci-app-firewall luci-i18n-base-pl luci-i18n-firewall-pl uhttpd uhttpd-mod-ubus firewall4 nftables"

PACKAGES_ALL="$PACKAGES_RUNTIME $PACKAGES_DIAG $PACKAGES_LUCI"

# Helper functions
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
  for cmd in wget tar make zstd; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing="$missing $cmd"
    fi
  done
  if [ -n "$missing" ]; then
    die "Missing dependencies:$missing"
  fi
  log "✓ All dependencies present"
}

# Main build process
log "=========================================="
log "FM350-GL Image Builder v22.1-STABLE"
log "=========================================="
log "OpenWrt: $OPENWRT_VERSION"
log "Target: $BOARD/$SUBTARGET"
log "Profile: $PROFILE"
echo

check_deps

# Determine repository root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
log "Repository root: $REPO_ROOT"

# Verify repo structure
if [ ! -d "$REPO_ROOT/files" ]; then
  die "Repository structure invalid - missing files/ directory"
fi

BUILD_DIR="$REPO_ROOT/build-output"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

IB_FILE="$(basename "$IB_URL")"
IB_DIR="${IB_FILE%.tar.zst}"

# Download Image Builder
if [ ! -f "$IB_FILE" ]; then
  log "Downloading Image Builder..."
  wget -q --show-progress "$IB_URL" || die "Failed to download Image Builder"
else
  log "✓ Image Builder already downloaded"
fi

# Extract Image Builder
if [ ! -d "$IB_DIR" ]; then
  log "Extracting Image Builder..."
  tar -xf "$IB_FILE" || die "Failed to extract Image Builder"
else
  log "✓ Image Builder already extracted"
fi

cd "$IB_DIR"

# Copy overlay files
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

# Build image
log "Building image..."
log "Packages: $(echo "$PACKAGES_ALL" | wc -w) total"
echo

make image \
  PROFILE="$PROFILE" \
  PACKAGES="$PACKAGES_ALL" \
  FILES="files" \
  || die "Build failed"

# Success!
log "=========================================="
log "✓ BUILD COMPLETE!"
log "=========================================="
log "Build artifacts:"
ls -lh bin/targets/${BOARD}/${SUBTARGET}/*.img.gz

log "Artifacts location:"
log "  $(pwd)/bin/targets/${BOARD}/${SUBTARGET}/"

echo
log "Flash to device:"
log "  gunzip openwrt-*-ext4-combined.img.gz"
log "  dd if=openwrt-*-ext4-combined.img of=/dev/sdX bs=4M status=progress"

echo
log "Download to local machine:"
log "  scp root@vps:$(pwd)/bin/targets/${BOARD}/${SUBTARGET}/*-ext4-combined.img.gz ~/"

echo
log "Or flash directly from VPS to device:"
log "  ssh root@vps 'gunzip -c $(pwd)/bin/targets/${BOARD}/${SUBTARGET}/*-ext4-combined.img.gz' | sudo dd of=/dev/sdX bs=4M status=progress"
