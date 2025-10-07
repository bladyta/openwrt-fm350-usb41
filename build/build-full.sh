#!/bin/sh
# FM350-GL Full Buildroot Compilation Script
# POSIX compliant - PRODUCTION READY
# v22.1-STABLE
# 
# This script performs a complete OpenWrt compilation from source.
# Use this for kernel modifications or full control.
# For quick builds, use build-local.sh (Image Builder) instead.

set -eu

################################################################################
# CONFIGURATION
################################################################################

OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.0}"
OPENWRT_GIT_REF="${OPENWRT_GIT_REF:-v24.10.0}"
OPENWRT_REPO="${OPENWRT_REPO:-https://git.openwrt.org/openwrt/openwrt.git}"

################################################################################
# FUNCTIONS
################################################################################

log() {
  printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

check_user() {
  if [ "$(id -u)" = "0" ]; then
    log "=========================================="
    log "⚠️  WARNING: Running as root"
    log "=========================================="
    log "Full buildroot compilation as root is not recommended."
    log ""
    log "Recommended: Create and use a non-root user:"
    log "  adduser --disabled-password --gecos \"\" builder"
    log "  echo \"builder ALL=(ALL) NOPASSWD:ALL\" >> /etc/sudoers"
    log "  su - builder"
    log "  cd ~/openwrt-fm350-usb41/build"
    log "  ./build-full.sh"
    log ""
    log "To continue as root anyway, set:"
    log "  export FORCE_UNSAFE_CONFIGURE=1"
    log "  export ALLOW_ROOT_BUILD=1"
    log "=========================================="
    
    if [ -z "${FORCE_UNSAFE_CONFIGURE:-}" ] || [ -z "${ALLOW_ROOT_BUILD:-}" ]; then
      die "Refusing to build as root without explicit confirmation"
    fi
    
    export FORCE_UNSAFE_CONFIGURE=1
    log "⚠️  Continuing as root (not recommended)"
  else
    log "✓ Running as non-root user: $(whoami)"
  fi
}

check_deps() {
  log "Checking dependencies..."
  
  local missing=""
  local required="git wget make gcc g++ python3"
  
  for cmd in $required; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing="$missing $cmd"
    fi
  done
  
  if [ -n "$missing" ]; then
    log "Missing dependencies:$missing"
    log ""
    log "Install with:"
    log "  sudo apt update"
    log "  sudo apt install -y build-essential clang flex bison g++ gawk \\"
    log "    gcc-multilib gettext git libncurses-dev libssl-dev \\"
    log "    python3 python3-setuptools rsync unzip zlib1g-dev file wget curl \\"
    log "    libncurses5-dev autoconf automake libtool pkg-config \\"
    log "    texinfo help2man libelf-dev"
    die "Missing dependencies"
  fi
  
  log "✓ All dependencies present"
}

check_resources() {
  log "Checking system resources..."
  
  # Check RAM (need 6GB minimum, 8GB recommended)
  if [ -f /proc/meminfo ]; then
    local mem_kb
    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_gb=$((mem_kb / 1024 / 1024))
    
    if [ "$mem_gb" -lt 6 ]; then
      log "⚠️  WARNING: Only ${mem_gb}GB RAM detected"
      log "   Recommended: 8GB minimum for full build"
      log "   Build may fail or be very slow"
    else
      log "✓ RAM: ${mem_gb}GB"
    fi
  fi
  
  # Check disk space (need 20GB minimum)
  local disk_avail
  disk_avail=$(df -BG . | tail -1 | awk '{print $4}' | sed 's/G//')
  
  if [ "$disk_avail" -lt 20 ]; then
    die "Insufficient disk space: ${disk_avail}GB available, need 20GB minimum"
  fi
  
  log "✓ Disk space: ${disk_avail}GB available"
}

################################################################################
# MAIN
################################################################################

log "=========================================="
log "FM350-GL Full Buildroot Builder v22.1"
log "=========================================="
log "OpenWrt: $OPENWRT_VERSION"
log "This will take 90-120 minutes"
echo

check_user
check_deps
check_resources

# Detect repository location
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

log "Repository root: $REPO_ROOT"

# Verify repo structure
if [ ! -f "$REPO_ROOT/.config" ]; then
  die "Missing .config in repository root"
fi

if [ ! -d "$REPO_ROOT/files" ]; then
  die "Missing files/ directory in repository"
fi

log "✓ Repository structure validated"

# Create build directory
BUILD_ROOT="$REPO_ROOT/build-output-full"
mkdir -p "$BUILD_ROOT"
cd "$BUILD_ROOT"

log "Build directory: $BUILD_ROOT"

# Clone OpenWrt if needed
if [ ! -d "openwrt" ]; then
  log "Cloning OpenWrt source..."
  git clone "$OPENWRT_REPO" openwrt || die "Failed to clone OpenWrt"
  cd openwrt
  log "Checking out $OPENWRT_GIT_REF..."
  git checkout "$OPENWRT_GIT_REF" || die "Failed to checkout $OPENWRT_GIT_REF"
else
  log "✓ OpenWrt source already exists"
  cd openwrt
fi

# Update feeds
log "Updating feeds..."
./scripts/feeds update -a || die "Failed to update feeds"

log "Installing feeds..."
./scripts/feeds install -a || die "Failed to install feeds"

# Copy configuration
log "Copying .config from repository..."
cp "$REPO_ROOT/.config" .config || die "Failed to copy .config"

# Verify target
log "Verifying configuration..."
if ! grep -q "CONFIG_TARGET_x86_64=y" .config; then
  die "Configuration error: x86/64 target not found in .config"
fi
log "✓ Configuration verified (x86/64 target)"

# Expand config
log "Expanding configuration..."
make defconfig || die "make defconfig failed"

# Verify after defconfig
if ! grep -q "CONFIG_TARGET_x86_64=y" .config; then
  die "Configuration error: x86/64 lost after defconfig"
fi
log "✓ Configuration maintained after defconfig"

# Copy overlay files
log "Copying overlay files..."
rm -rf files
cp -r "$REPO_ROOT/files" . || die "Failed to copy overlay files"

# Set permissions
log "Setting file permissions..."
chmod +x files/usr/sbin/fm350-manager 2>/dev/null || true
chmod +x files/usr/lib/fm350/functions.sh 2>/dev/null || true
chmod +x files/lib/netifd/proto/fm350.sh 2>/dev/null || true
chmod +x files/etc/init.d/fm350-manager 2>/dev/null || true
chmod +x files/etc/hotplug.d/usb/20-fm350-usbids 2>/dev/null || true
chmod +x files/etc/hotplug.d/usb/60-fm350 2>/dev/null || true
chmod +x files/etc/uci-defaults/99-fm350 2>/dev/null || true
chmod +x files/scripts/test-e2e.sh 2>/dev/null || true
chmod +x files/scripts/validate.sh 2>/dev/null || true
chmod +x files/scripts/at-send.sh 2>/dev/null || true

log "✓ Overlay files ready"

# Download sources
log "Downloading source packages..."
log "(This may take 10-15 minutes)"
make -j$(($(nproc) + 1)) download || die "Download failed"

log "✓ All sources downloaded"

# Build
log "=========================================="
log "Starting compilation..."
log "This will take 90-120 minutes"
log "You can monitor progress in another terminal:"
log "  tail -f $BUILD_ROOT/openwrt/logs/package/compile.txt"
log "=========================================="

START_TIME=$(date +%s)

make -j$(($(nproc) + 1)) world || {
  log ""
  log "=========================================="
  log "⚠️  BUILD FAILED"
  log "=========================================="
  log "Check logs:"
  log "  cat $BUILD_ROOT/openwrt/logs/package/error.log"
  log ""
  log "For verbose rebuild:"
  log "  cd $BUILD_ROOT/openwrt"
  log "  make -j1 V=s"
  die "Compilation failed"
}

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
DURATION_MIN=$((DURATION / 60))

log ""
log "=========================================="
log "✓ BUILD COMPLETE!"
log "=========================================="
log "Duration: ${DURATION_MIN} minutes"
echo

# Verify output
OUTPUT_DIR="bin/targets/x86/64"

if [ ! -d "$OUTPUT_DIR" ]; then
  die "Output directory not found: $OUTPUT_DIR"
fi

cd "$OUTPUT_DIR"

if ! ls *.img.gz >/dev/null 2>&1; then
  die "No images found in output directory"
fi

log "Build artifacts:"
ls -lh *.img.gz *.tar.gz 2>/dev/null || true

echo
log "=========================================="
log "SUCCESS!"
log "=========================================="
log ""
log "Images location:"
log "  $BUILD_ROOT/openwrt/$OUTPUT_DIR/"
log ""
log "Main image:"
IMG_FILE=$(ls -1 *-ext4-combined.img.gz 2>/dev/null | head -1)
if [ -n "$IMG_FILE" ]; then
  log "  $IMG_FILE"
fi
log ""
log "Download to local machine:"
log "  scp $(whoami)@\$VPS_IP:$BUILD_ROOT/openwrt/$OUTPUT_DIR/*.img.gz ."
log ""
log "Flash to device:"
log "  gunzip *.img.gz"
log "  sudo dd if=*.img of=/dev/sdX bs=4M status=progress"
log ""
log "After first boot on device:"
log "  /scripts/validate.sh"
log "  /scripts/test-e2e.sh"
log "=========================================="
