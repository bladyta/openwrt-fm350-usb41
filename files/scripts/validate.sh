#!/bin/sh
# FM350-GL System Validation Script
# POSIX/ash compliant
# VERSION: 21.1-ULTIMATE (All optimizations applied)

set -e

echo "=========================================="
echo "FM350-GL System Validation"
echo "=========================================="
echo

FAIL_COUNT=0

fail() {
  echo "❌ FAIL: $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  echo "✅ PASS: $1"
}

info() {
  echo "ℹ️  INFO: $1"
}

echo "=== Required Commands ==="
REQUIRED_CMDS="udhcpc ip timeout awk grep cat stty modprobe uci logger pidof nslookup"

for cmd in $REQUIRED_CMDS; do
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "Command found: $cmd"
  else
    fail "Command missing: $cmd"
  fi
done
echo

echo "=== Timeout Implementation ==="
if timeout 1 true 2>/dev/null; then
  TIMEOUT_TYPE=$(timeout --help 2>&1 | grep -q busybox && echo "busybox" || echo "coreutils")
  info "timeout: $TIMEOUT_TYPE"
else
  fail "timeout command not working"
fi
echo

echo "=== Kernel Modules ==="
REQUIRED_MODULES="option rndis_host"

for mod in $REQUIRED_MODULES; do
  # Use awk for exact match (more reliable than grep -w with ^)
  if lsmod 2>/dev/null | awk '$1 == "'"$mod"'" { found=1; exit } END { exit !found }'; then
    pass "Module loaded: $mod"
  elif ls /etc/modules.d/*-$mod 2>/dev/null | grep -q .; then
    info "Module available: $mod (not loaded)"
  else
    fail "Module missing: $mod"
  fi
done
echo

echo "=== Forbidden Packages ==="
FORBIDDEN="modemmanager libmbim libqmi umbim uqmi kmod-usb-net-cdc-mbim kmod-usb-net-cdc-ncm kmod-usb-net-cdc-ether"

for pkg in $FORBIDDEN; do
  if opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
    fail "Forbidden package installed: $pkg"
  else
    pass "Forbidden package not found: $pkg"
  fi
done
echo

echo "=== USB Serial Driver ==="
if [ -d /sys/bus/usb-serial/drivers/option1 ]; then
  pass "option driver available"
elif [ -d /sys/bus/usb-serial/drivers/generic ]; then
  info "generic driver available (fallback)"
else
  fail "No USB serial driver found"
fi
echo

echo "=== RNDIS Driver ==="
if [ -d /sys/bus/usb/drivers/rndis_host ]; then
  pass "rndis_host driver loaded"
else
  fail "rndis_host driver not found"
fi
echo

echo "=== FM350 Detection ==="
FM350_FOUND=0

for dev in /sys/bus/usb/devices/*; do
  [ -f "$dev/idVendor" ] || continue
  VENDOR=$(cat "$dev/idVendor" 2>/dev/null)
  PRODUCT=$(cat "$dev/idProduct" 2>/dev/null)
  
  if [ "$VENDOR" = "0e8d" ]; then
    case "$PRODUCT" in
      7127|7126|7125)
        pass "FM350-GL detected (VID:PID = 0e8d:$PRODUCT)"
        FM350_FOUND=1
        
        # Check USB speed
        if [ -f "$dev/speed" ]; then
          SPEED=$(cat "$dev/speed" 2>/dev/null)
          info "USB speed: $SPEED Mb/s"
          
          if [ "$SPEED" = "5000" ]; then
            echo "⚠️  WARNING: USB3 detected - consider using USB2 port for stability"
          fi
        fi
        ;;
    esac
  fi
done

[ $FM350_FOUND -eq 0 ] && fail "FM350-GL not detected"
echo

echo "=== Network Configuration ==="
if [ -f /etc/config/network ]; then
  pass "Network config exists"
  
  if uci get network.wwan >/dev/null 2>&1; then
    PROTO=$(uci get network.wwan.proto 2>/dev/null)
    info "wwan interface: proto=$PROTO"
  else
    info "wwan interface not configured (will be created on first boot)"
  fi
else
  fail "Network config missing"
fi
echo

echo "=== Service Status ==="
if [ -x /etc/init.d/fm350-manager ]; then
  pass "fm350-manager service script exists"
  
  if /etc/init.d/fm350-manager enabled; then
    pass "Service enabled"
  else
    info "Service not enabled (will be enabled on first boot)"
  fi
  
  if pidof fm350-manager >/dev/null 2>&1; then
    pass "Service running"
  else
    info "Service not running"
  fi
else
  fail "fm350-manager service script missing"
fi
echo

echo "=== Runtime Files ==="
if [ -f /usr/lib/fm350/functions.sh ]; then
  pass "Function library exists"
else
  fail "Function library missing"
fi

if [ -x /usr/sbin/fm350-manager ]; then
  pass "Manager executable exists"
else
  fail "Manager executable missing"
fi

if [ -f /lib/netifd/proto/fm350.sh ]; then
  pass "Proto handler exists"
else
  fail "Proto handler missing"
fi
echo

echo "=== Security Checks ==="
if [ -d /tmp/fm350 ]; then
  # Normalize stat output (remove leading zeros for cross-platform compatibility)
  PERMS=$(stat -c '%a' /tmp/fm350 2>/dev/null || stat -f '%A' /tmp/fm350 2>/dev/null)
  PERMS=$(echo "$PERMS" | sed 's/^0*//')
  
  if [ "$PERMS" = "700" ]; then
    pass "Runtime directory permissions secure (700)"
  else
    info "Runtime directory permissions: $PERMS (should be 700)"
  fi
fi
echo

echo "=========================================="
if [ $FAIL_COUNT -eq 0 ]; then
  echo "✅ VALIDATION PASSED"
  echo
  echo "System is ready for FM350-GL operation."
  echo "To start the service: /etc/init.d/fm350-manager start"
  exit 0
else
  echo "❌ VALIDATION FAILED ($FAIL_COUNT issue(s))"
  echo
  echo "Please resolve the issues above before using FM350-GL."
  exit 1
fi