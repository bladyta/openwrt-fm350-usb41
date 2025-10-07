#!/bin/sh
# FM350-GL One-Click Builder
# Supports: curl | sh deployment
# POSIX compliant
# v22.1-FIXED

set -eu

################################################################################
# CONFIGURATION
################################################################################

OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.0}"
OPENWRT_GIT_REF="${OPENWRT_GIT_REF:-v24.10.0}"
BOARD="${BOARD:-x86}"
SUBTARGET="${SUBTARGET:-64}"
PROFILE="${PROFILE:-generic}"
REPO_URL="${REPO_URL:-}"
EXTRA_PKGS="${EXTRA_PKGS:-}"

BUILD_MODE="imagebuilder"

################################################################################
# PACKAGE LISTS
################################################################################

PACKAGES_RUNTIME="kmod-usb-core kmod-usb2 kmod-usb3 kmod-usb-serial kmod-usb-serial-wwan kmod-usb-serial-option kmod-usb-net kmod-usb-net-rndis ip-full coreutils-timeout dnsmasq ca-bundle ca-certificates"

PACKAGES_DIAG="ethtool tcpdump iperf3 mtr traceroute curl wget-ssl bind-dig socat picocom comgt usbutils pciutils htop nano vim jq less screen minicom atinout lsof mc"

PACKAGES_LUCI="luci luci-ssl luci-app-firewall luci-i18n-base-pl luci-i18n-firewall-pl uhttpd uhttpd-mod-ubus firewall4 nftables"

PACKAGES_ALL="$PACKAGES_RUNTIME $PACKAGES_DIAG $PACKAGES_LUCI $EXTRA_PKGS"

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

pm_detect() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
    return 0
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
    return 0
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
    return 0
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
    return 0
  elif command -v zypper >/dev/null 2>&1; then
    echo "zypper"
    return 0
  else
    echo "unknown"
    return 1
  fi
}

install_deps() {
  local pm
  pm=$(pm_detect)
  
  log "Detected package manager: $pm"
  
  case "$pm" in
    apt)
      log "Installing dependencies (apt)..."
      sudo apt-get update
      
      if [ "$BUILD_MODE" = "full" ]; then
        # FIXED: Removed python3-distutils, added python3-setuptools
        sudo apt-get install -y build-essential clang flex bison g++ gawk \
          gcc-multilib gettext git libncurses-dev libssl-dev \
          python3 python3-setuptools rsync unzip zlib1g-dev file wget curl
      else
        sudo apt-get install -y wget curl tar gzip rsync make git
      fi
      ;;
      
    dnf)
      log "Installing dependencies (dnf)..."
      
      if [ "$BUILD_MODE" = "full" ]; then
        sudo dnf install -y bash-completion bzip2 gcc gcc-c++ git make \
          ncurses-devel patch rsync tar unzip wget which diffutils \
          python3 perl-base perl-Data-Dumper perl-File-Compare \
          perl-File-Copy perl-FindBin perl-Thread-Queue curl
      else
        sudo dnf install -y wget curl tar gzip rsync make git
      fi
      ;;
      
    yum)
      log "Installing dependencies (yum)..."
      
      if [ "$BUILD_MODE" = "full" ]; then
        sudo yum install -y bash-completion bzip2 gcc gcc-c++ git make \
          ncurses-devel patch rsync tar unzip wget which diffutils \
          python3 perl-Data-Dumper perl-Thread-Queue curl
      else
        sudo yum install -y wget curl tar gzip rsync make git
      fi
      ;;
      
    pacman)
      log "Installing dependencies (pacman)..."
      
      if [ "$BUILD_MODE" = "full" ]; then
        sudo pacman -Sy --needed --noconfirm base-devel ncurses zlib \
          gawk git gettext openssl libxslt wget rsync curl
      else
        sudo pacman -Sy --needed --noconfirm wget curl tar gzip rsync make git
      fi
      ;;
      
    zypper)
      log "Installing dependencies (zypper)..."
      
      if [ "$BUILD_MODE" = "full" ]; then
        sudo zypper install -y --no-recommends bash bc binutils bzip2 \
          fastjar flex git gcc gcc-c++ gettext-tools gtk2-devel \
          intltool jq make ncurses-devel patch perl-ExtUtils-MakeMaker \
          python3 rsync ruby wget xz zlib-devel curl
      else
        sudo zypper install -y wget curl tar gzip rsync make git
      fi
      ;;
      
    *)
      die "Unsupported package manager. Please install dependencies manually."
      ;;
  esac
  
  log "Dependencies installed successfully"
}

clone_repo() {
  if [ -z "$REPO_URL" ]; then
    log "REPO_URL not set, assuming repository already exists"
    return 0
  fi
  
  if [ ! -d "openwrt-fm350-usb41" ]; then
    log "Cloning repository: $REPO_URL"
    git clone "$REPO_URL" openwrt-fm350-usb41 || die "Failed to clone repository"
    cd openwrt-fm350-usb41
  else
    log "Repository already exists"
    cd openwrt-fm350-usb41
    git pull || log "Warning: git pull failed, using existing code"
  fi
}

build_imagebuilder() {
  log "Building with OpenWrt Image Builder..."
  
  IB_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${BOARD}/${SUBTARGET}/openwrt-imagebuilder-${OPENWRT_VERSION}-${BOARD}-${SUBTARGET}.Linux-x86_64.tar.xz"
  IB_FILE="$(basename "$IB_URL")"
  IB_DIR="${IB_FILE%.tar.xz}"
  
  mkdir -p build-output
  cd build-output
  
  if [ ! -f "$IB_FILE" ]; then
    log "Downloading Image Builder..."
    wget -q --show-progress "$IB_URL" || die "Failed to download Image Builder"
  fi
  
  if [ ! -d "$IB_DIR" ]; then
    log "Extracting Image Builder..."
    tar -Jxf "$IB_FILE" || die "Failed to extract Image Builder"
  fi
  
  cd "$IB_DIR"
  
  log "Copying overlay files..."
  rm -rf files
  cp -r ../../files . || die "Failed to copy files"
  
  chmod +x files/usr/sbin/fm350-manager
  chmod +x files/usr/lib/fm350/functions.sh
  chmod +x files/lib/netifd/proto/fm350.sh
  chmod +x files/etc/init.d/fm350-manager
  chmod +x files/etc/hotplug.d/usb/*
  chmod +x files/etc/uci-defaults/99-fm350
  chmod +x files/scripts/*.sh
  
  log "Building image with packages: $PACKAGES_ALL"
  
  make image \
    PROFILE="$PROFILE" \
    PACKAGES="$PACKAGES_ALL" \
    FILES=files/ \
    || die "Build failed"
  
  log "Image Builder build complete!"
  log "Artifacts: $(pwd)/bin/targets/$BOARD/$SUBTARGET/"
  
  ls -lh "bin/targets/$BOARD/$SUBTARGET/"/*.img.gz 2>/dev/null || true
  ls -lh "bin/targets/$BOARD/$SUBTARGET/"/*.tar.gz 2>/dev/null || true
}

build_full() {
  log "Building with full OpenWrt buildroot..."
  
  # Get script directory
  SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
  REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
  
  mkdir -p "$REPO_ROOT/build-output"
  cd "$REPO_ROOT/build-output"
  
  if [ ! -d "openwrt" ]; then
    log "Cloning OpenWrt repository..."
    git clone https://git.openwrt.org/openwrt/openwrt.git || die "Failed to clone OpenWrt"
    cd openwrt
    git checkout "$OPENWRT_GIT_REF" || die "Failed to checkout $OPENWRT_GIT_REF"
  else
    log "OpenWrt repository already exists"
    cd openwrt
  fi
  
  log "Updating feeds..."
  ./scripts/feeds update -a
  ./scripts/feeds install -a
  
  # FIXED: Better .config handling
  if [ -f "$REPO_ROOT/.config" ]; then
    log "Copying .config from repository root..."
    cp "$REPO_ROOT/.config" .config
  else
    die "No .config file found in repository root"
  fi
  
  log "Expanding config..."
  make defconfig
  
  log "Copying overlay files..."
  rm -rf files
  cp -r "$REPO_ROOT/files" . || die "Failed to copy files"
  
  chmod +x files/usr/sbin/fm350-manager
  chmod +x files/usr/lib/fm350/functions.sh
  chmod +x files/lib/netifd/proto/fm350.sh
  chmod +x files/etc/init.d/fm350-manager
  chmod +x files/etc/hotplug.d/usb/*
  chmod +x files/etc/uci-defaults/99-fm350
  chmod +x files/scripts/*.sh
  
  log "Building (this may take a while)..."
  make -j$(($(nproc) + 1)) download world || die "Build failed"
  
  log "Full buildroot build complete!"
  log "Artifacts: $(pwd)/bin/targets/$BOARD/$SUBTARGET/"
  
  ls -lh "bin/targets/$BOARD/$SUBTARGET/"/*.img.gz 2>/dev/null || true
}

################################################################################
# MAIN
################################################################################

log "=========================================="
log "FM350-GL One-Click Builder v22.1-FIXED"
log "=========================================="
echo

while [ $# -gt 0 ]; do
  case "$1" in
    --full)
      BUILD_MODE="full"
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
[ -n "$EXTRA_PKGS" ] && log "Extra packages: $EXTRA_PKGS"
echo

# Check if we're in the repo
if [ ! -f "../files/usr/sbin/fm350-manager" ] && [ ! -f "files/usr/sbin/fm350-manager" ]; then
  log "Not in repository directory, attempting to find it..."
  if [ -n "$REPO_URL" ]; then
    clone_repo
  else
    die "Cannot find repository. Please run from repo directory or set REPO_URL"
  fi
fi

install_deps

case "$BUILD_MODE" in
  imagebuilder)
    build_imagebuilder
    ;;
  full)
    build_full
    ;;
  *)
    die "Invalid build mode: $BUILD_MODE"
    ;;
esac

echo
log "=========================================="
log "BUILD COMPLETE"
log "=========================================="
echo
log "Next steps:"
log "1. Flash image to device (see README.md)"
log "2. Boot device and run: /scripts/validate.sh"
log "3. Run end-to-end test: /scripts/test-e2e.sh"
log "4. Monitor logs: logread -f -e fm350"
