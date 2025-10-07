#!/bin/sh
# FM350-GL One-Click Builder
# POSIX compliant - PRODUCTION READY
# v22.1-STABLE

set -eu

################################################################################
# CONFIGURATION
################################################################################

OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.0}"
OPENWRT_GIT_REF="${OPENWRT_GIT_REF:-v24.10.0}"
BOARD="${BOARD:-x86}"
SUBTARGET="${SUBTARGET:-64}"
PROFILE="${PROFILE:-generic}"
REPO_URL="${REPO_URL:-https://github.com/bladyta/openwrt-fm350-usb41.git}"

BUILD_MODE="imagebuilder"

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

install_deps() {
  log "Installing dependencies..."
  
  if ! command -v apt-get >/dev/null 2>&1; then
    die "This script requires Ubuntu/Debian with apt-get"
  fi
  
  sudo apt-get update
  
  if [ "$BUILD_MODE" = "imagebuilder" ]; then
    sudo apt-get install -y wget tar make git
  else
    # Full build deps
    sudo apt-get install -y build-essential clang flex bison g++ gawk \
      gcc-multilib gettext git libncurses-dev libssl-dev \
      python3 python3-setuptools rsync unzip zlib1g-dev file wget curl
  fi
  
  log "✓ Dependencies installed"
}

################################################################################
# MAIN
################################################################################

log "=========================================="
log "FM350-GL One-Click Builder v22.1-STABLE"
log "=========================================="
echo

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --full)
      BUILD_MODE="full"
      
      # Warn about root
      if [ "$(id -u)" = "0" ]; then
        log "=========================================="
        log "⚠️  WARNING: Full build as root"
        log "=========================================="
        log "Full buildroot doesn't work well as root."
        log "Recommended: Use Image Builder instead (default)"
        log ""
        log "To continue anyway, run:"
        log "  export FORCE_UNSAFE_CONFIGURE=1"
        log "  ./oneclick.sh --full"
        log ""
        log "Or create non-root user:"
        log "  adduser builder"
        log "  su - builder"
        log "=========================================="
        
        if [ -z "${FORCE_UNSAFE_CONFIGURE:-}" ]; then
          die "Full build as root requires FORCE_UNSAFE_CONFIGURE=1"
        fi
        
        log "FORCE_UNSAFE_CONFIGURE set, continuing..."
        export FORCE_UNSAFE_CONFIGURE=1
      fi
      shift
      ;;
    *)
      shift
      ;;
  esac
done

log "Build mode: $BUILD_MODE"
log "OpenWrt version: $OPENWRT_VERSION"
log "Target: $BOARD/$SUBTARGET"
log "Profile: $PROFILE"
echo

# Clone repo if needed
if [ ! -f "../files/usr/sbin/fm350-manager" ] && [ ! -f "files/usr/sbin/fm350-manager" ]; then
  if [ -n "$REPO_URL" ]; then
    log "Cloning repository..."
    git clone "$REPO_URL" openwrt-fm350-usb41
    cd openwrt-fm350-usb41/build
  else
    die "Repository not found. Run from repo directory or set REPO_URL"
  fi
fi

install_deps

# Call appropriate builder
if [ "$BUILD_MODE" = "imagebuilder" ]; then
  log "Using Image Builder (recommended)..."
  exec ./build-local.sh
else
  log "Using full buildroot (advanced)..."
  
  SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
  
  mkdir -p "$REPO_ROOT/build-output"
  cd "$REPO_ROOT/build-output"
  
  if [ ! -d "openwrt" ]; then
    log "Cloning OpenWrt..."
    git clone https://git.openwrt.org/openwrt/openwrt.git
    cd openwrt
    git checkout "$OPENWRT_GIT_REF"
  else
    cd openwrt
  fi
  
  log "Updating feeds..."
  ./scripts/feeds update -a
  ./scripts/feeds install -a
  
  if [ -f "$REPO_ROOT/.config" ]; then
    cp "$REPO_ROOT/.config" .config
  else
    die "No .config in repository"
  fi
  
  make defconfig
  
  rm -rf files
  cp -r "$REPO_ROOT/files" .
  
  chmod +x files/usr/sbin/fm350-manager 2>/dev/null || true
  chmod +x files/usr/lib/fm350/functions.sh 2>/dev/null || true
  chmod +x files/lib/netifd/proto/fm350.sh 2>/dev/null || true
  chmod +x files/etc/init.d/fm350-manager 2>/dev/null || true
  chmod +x files/etc/hotplug.d/usb/* 2>/dev/null || true
  chmod +x files/etc/uci-defaults/99-fm350 2>/dev/null || true
  chmod +x files/scripts/*.sh 2>/dev/null || true
  
  log "Building (60+ minutes)..."
  make -j$(($(nproc) + 1)) download world
  
  log "✓ Full build complete!"
  log "Artifacts: $(pwd)/bin/targets/$BOARD/$SUBTARGET/"
fi
