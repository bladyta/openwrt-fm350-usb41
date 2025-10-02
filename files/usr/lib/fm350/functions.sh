#!/bin/sh
# FM350-GL USB41 Core Functions Library
# POSIX/ash compliant - NO bashisms
# OpenWrt 24.10.x / kernel 6.6
# VERSION: 21.1-ULTIMATE (All optimizations applied)

################################################################################
# MUST-USE FUNCTIONS (DO NOT MODIFY - REQUIRED BY SPEC)
################################################################################

# Rate-limited logging via syslog
log_limited() {
  local level="$1" msg="$2" now hash stamp last
  now=$(date +%s)
  hash=$(echo "$level:$msg" | md5sum | cut -d' ' -f1)
  stamp="/tmp/fm350.logstamp/$hash"
  mkdir -p /tmp/fm350.logstamp
  
  if [ -f "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null)
    [ -n "$last" ] && [ $((now - last)) -lt 5 ] && return
  fi
  
  echo "$now" > "$stamp"
  logger -t fm350 -p "daemon.$level" "$msg"
}

# Find AT-capable serial port
find_at_port() {
  local port response
  
  for port in /dev/ttyUSB* /dev/ttyACM*; do
    [ -c "$port" ] || continue
    
    # Configure port
    stty -F "$port" 115200 raw -echo 2>/dev/null || true
    
    # Flush input
    timeout 1 cat "$port" >/dev/null 2>&1
    
    # Test AT
    printf "AT\r\n" > "$port" 2>/dev/null
    response=$(timeout 2 cat "$port" 2>/dev/null | head -n 10)
    
    if echo "$response" | grep -q "OK"; then
      # Initialize port
      timeout 1 cat "$port" >/dev/null 2>&1
      printf "ATE0\r\n" > "$port" 2>/dev/null; sleep 1
      
      timeout 1 cat "$port" >/dev/null 2>&1
      printf "AT+CMEE=2\r\n" > "$port" 2>/dev/null; sleep 1
      
      timeout 1 cat "$port" >/dev/null 2>&1
      
      echo "$port"; return 0
    fi
  done
  
  return 1
}

# Find RNDIS interface (rndis_host driver only, FM350 VID:PID verified)
find_rndis_interface() {
  local d drv vid pid
  
  for d in /sys/class/net/*; do
    [ -d "$d/device/driver" ] || continue
    
    drv=$(basename "$(readlink "$d/device/driver" 2>/dev/null)" 2>/dev/null)
    [ "$drv" = "rndis_host" ] || continue
    
    # Verify this is FM350 by checking USB VID:PID
    vid=$(cat "$d/device/../idVendor" 2>/dev/null)
    pid=$(cat "$d/device/../idProduct" 2>/dev/null)
    
    if [ "$vid" = "0e8d" ]; then
      case "$pid" in
        7127|7126|7125)
          basename "$d"
          return 0
          ;;
      esac
    fi
  done
  
  return 1
}

# Wait for both AT port and RNDIS interface
wait_for_dual_endpoints() {
  local timeout="${1:-30}" at="" ifc=""
  
  while [ $timeout -gt 0 ]; do
    [ -z "$at" ] && at=$(find_at_port)
    [ -z "$ifc" ] && ifc=$(find_rndis_interface)
    
    if [ -n "$at" ] && [ -n "$ifc" ]; then
      # Re-validate before saving (prevent race condition)
      if [ -c "$at" ] && [ -d "/sys/class/net/$ifc" ]; then
        mkdir -p /tmp/fm350
        echo "$at" > /tmp/fm350/at_port
        echo "$ifc" > /tmp/fm350/rndis_if
        return 0
      fi
      # If re-validate fails, clear and retry
      at=""
      ifc=""
    fi
    
    sleep 1
    timeout=$((timeout - 1))
  done
  
  return 1
}

# USB reset via sysfs
usb_reset_device() {
  local dev bus vid pid
  
  for dev in /sys/bus/usb/devices/*; do
    [ -f "$dev/idVendor" ] && [ -f "$dev/idProduct" ] || continue
    vid=$(cat "$dev/idVendor" 2>/dev/null)
    pid=$(cat "$dev/idProduct" 2>/dev/null)
    
    [ "$vid" = "0e8d" ] || continue
    grep -qE '^712[567]$' "$dev/idProduct" 2>/dev/null || continue
    
    log_limited info "USB reset: VID=$vid PID=$pid device=$(basename "$dev")"
    
    if [ -f "$dev/authorized" ]; then
      echo 0 > "$dev/authorized" 2>/dev/null
      sleep 3
      echo 1 > "$dev/authorized" 2>/dev/null
    else
      bus=$(basename "$dev")
      echo "$bus" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null; sleep 3
      echo "$bus" > /sys/bus/usb/drivers/usb/bind 2>/dev/null
    fi
    
    return 0
  done
  
  return 1
}

# Send AT command with lock and proper termination
at_command() {
  local port="$1" cmd="$2" to="${3:-5}"
  local lock="/var/lock/fm350-at.lock" out waited=0
  
  mkdir -p /var/lock
  
  # Acquire lock with timeout
  while [ $waited -lt 10 ]; do
    if mkdir "$lock" 2>/dev/null; then
      trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM
      
      # Flush input buffer
      timeout 1 cat "$port" >/dev/null 2>&1
      
      # Send command
      printf "%s\r\n" "$cmd" > "$port" 2>/dev/null
      
      # Read response until OK/ERROR/CME (with fflush for better buffering)
      out=$(timeout "$to" awk '
        /^OK$|^ERROR$|^\+CME ERROR:/ { print; fflush(); exit }
        /^$/ { next }
        /^AT/ { next }
        { print; fflush() }
      ' < "$port" 2>/dev/null)
      
      trap - EXIT INT TERM
      rmdir "$lock" 2>/dev/null
      
      echo "$out"
      echo "$out" | grep -q "^OK$" && return 0
      return 1
    fi
    
    sleep 1
    waited=$((waited + 1))
  done
  
  # Failed to acquire lock - ensure cleanup
  rmdir "$lock" 2>/dev/null || true
  return 1
}

# Setup fallback device route (no gateway)
setup_fallback_route() {
  ip route replace default dev "$1" metric "${2:-50}"
}

# Configure DNS via UCI (no interface restart)
setup_dns_uci() {
  local d1="${1:-8.8.8.8}" d2="${2:-8.8.4.4}"
  
  # Validate DNS IPs (reject invalid format)
  if ! echo "$d1" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    log_limited warn "Invalid DNS1 format: $d1, using 8.8.8.8"
    d1="8.8.8.8"
  fi
  
  if ! echo "$d2" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    log_limited warn "Invalid DNS2 format: $d2, using 8.8.4.4"
    d2="8.8.4.4"
  fi
  
  # Reject reserved IPs
  case "$d1" in
    0.0.0.0|127.*|255.255.255.255|169.254.*)
      log_limited warn "Invalid DNS1 (reserved): $d1, using 8.8.8.8"
      d1="8.8.8.8"
      ;;
  esac
  
  case "$d2" in
    0.0.0.0|127.*|255.255.255.255|169.254.*)
      log_limited warn "Invalid DNS2 (reserved): $d2, using 8.8.4.4"
      d2="8.8.4.4"
      ;;
  esac
  
  uci delete network.wwan.dns 2>/dev/null || true
  uci add_list network.wwan.dns="$d1"
  uci add_list network.wwan.dns="$d2"
  uci set network.wwan.peerdns='0'
  uci commit network
  
  # Reload dnsmasq without restarting interfaces
  [ -f /var/run/dnsmasq.pid ] && kill -HUP "$(cat /var/run/dnsmasq.pid)" 2>/dev/null || true
  
  # Cache DNS for monitoring
  echo "$d1" > /tmp/fm350/dns1
  echo "$d2" > /tmp/fm350/dns2
}

################################################################################
# OPTIONAL HELPER FUNCTIONS (POSIX COMPLIANT)
################################################################################

# Extract IPv4 address from AT+CGPADDR response
get_pdp_ipv4() {
  local port="$1" response ip
  
  response=$(at_command "$port" "AT+CGPADDR=1" 5)
  
  if echo "$response" | grep -q "OK"; then
    # Parse IP from response, handling quotes and commas
    ip=$(echo "$response" | grep "+CGPADDR:" | sed 's/[",]/ /g' | awk '{print $3}')
    
    # Validate IP format
    if echo "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
      echo "$ip"
      return 0
    fi
  fi
  
  return 1
}

# Apply IPv4 address with /32 mask
apply_ipv4_addr() {
  local iface="$1" ip="$2"
  
  [ -z "$iface" ] || [ -z "$ip" ] && return 1
  
  # Flush old addresses first
  ip addr flush dev "$iface" 2>/dev/null || true
  
  # Apply new address
  ip addr replace "$ip/32" dev "$iface" 2>/dev/null
  return $?
}

# Warn if USB3 detected (5 Gb/s link)
warn_if_usb3() {
  local iface="$1" syspath speed prev_path
  
  [ -z "$iface" ] && return 1
  
  syspath="/sys/class/net/$iface/device"
  [ -d "$syspath" ] || return 1
  
  # Navigate up to USB device (max 10 levels to prevent infinite loop)
  local level=0
  while [ -n "$syspath" ] && [ "$syspath" != "/" ] && [ $level -lt 10 ]; do
    if [ -f "$syspath/speed" ]; then
      speed=$(cat "$syspath/speed" 2>/dev/null)
      
      if [ "$speed" = "5000" ]; then
        log_limited warn "USB3 (5 Gb/s) detected on $iface - consider using USB2 port for stability"
        return 0
      fi
      break
    fi
    
    prev_path="$syspath"
    syspath=$(dirname "$syspath")
    
    # Prevent infinite loop
    [ "$syspath" = "$prev_path" ] && break
    level=$((level + 1))
  done
  
  return 1
}

# Check if recovery budget exceeded (2/hour for L2/L3) - WITH LOCK
check_recovery_budget() {
  local level="$1" now count_file="/tmp/fm350/reset_count" count=0 ts
  local lock="/var/lock/fm350-budget.lock" waited=0
  
  [ "$level" != "L2" ] && [ "$level" != "L3" ] && return 0
  
  mkdir -p /var/lock /tmp/fm350
  now=$(date +%s)
  
  # Acquire lock with timeout
  while [ $waited -lt 5 ]; do
    if mkdir "$lock" 2>/dev/null; then
      trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  
  [ $waited -ge 5 ] && return 1  # Lock acquisition failed
  
  # Count and rewrite valid timestamps (avoid subshell)
  if [ -f "$count_file" ]; then
    > "$count_file.tmp"
    while IFS= read -r ts; do
      if [ -n "$ts" ] && [ $((now - ts)) -lt 3600 ]; then
        echo "$ts" >> "$count_file.tmp"
        count=$((count + 1))
      fi
    done < "$count_file"
    mv "$count_file.tmp" "$count_file" 2>/dev/null
  else
    count=0
    > "$count_file"
  fi
  
  # Check budget
  if [ $count -ge 2 ]; then
    log_limited err "Recovery budget exceeded: $count resets in last hour"
    trap - EXIT INT TERM
    rmdir "$lock" 2>/dev/null
    return 1
  fi
  
  # Add current timestamp
  echo "$now" >> "$count_file"
  
  trap - EXIT INT TERM
  rmdir "$lock" 2>/dev/null
  return 0
}

# Check cooldown for L2/L3 recovery (1800s)
check_recovery_cooldown() {
  local level="$1" now last_file="/tmp/fm350/last_recovery_$level" last
  
  [ "$level" != "L2" ] && [ "$level" != "L3" ] && return 0
  
  mkdir -p /tmp/fm350
  now=$(date +%s)
  
  if [ -f "$last_file" ]; then
    last=$(cat "$last_file" 2>/dev/null)
    
    if [ -n "$last" ] && [ $((now - last)) -lt 1800 ]; then
      log_limited warn "$level recovery in cooldown: $((1800 - (now - last)))s remaining"
      return 1
    fi
  fi
  
  # Update timestamp
  echo "$now" > "$last_file"
  return 0
}

# Register FM350 VID:PID to option driver
register_usb_ids() {
  local new_id="/sys/bus/usb-serial/drivers/option1/new_id"
  local generic_id="/sys/bus/usb-serial/drivers/generic/new_id"
  
  # Try option driver first
  if [ -f "$new_id" ]; then
    echo "0e8d 7127 ff" > "$new_id" 2>/dev/null || true
    echo "0e8d 7126 ff" > "$new_id" 2>/dev/null || true
    echo "0e8d 7125 ff" > "$new_id" 2>/dev/null || true
    return 0
  fi
  
  # Fallback to generic
  if [ -f "$generic_id" ]; then
    echo "0e8d 7127" > "$generic_id" 2>/dev/null || true
    echo "0e8d 7126" > "$generic_id" 2>/dev/null || true
    echo "0e8d 7125" > "$generic_id" 2>/dev/null || true
    return 0
  fi
  
  return 1
}

# Validate modem is ready (SIM + registration)
validate_modem_ready() {
  local port="$1" response retries=10
  
  [ -z "$port" ] && return 1
  
  # Check SIM with retries
  while [ $retries -gt 0 ]; do
    response=$(at_command "$port" "AT+CPIN?" 3)
    
    if echo "$response" | grep -q "READY"; then
      log_limited info "SIM ready"
      return 0
    fi
    
    if echo "$response" | grep -q "SIM PIN"; then
      log_limited err "SIM PIN required"
      return 1
    fi
    
    sleep 2
    retries=$((retries - 1))
  done
  
  log_limited err "SIM not ready after 10 attempts"
  return 1
}

# Get signal quality
get_signal_quality() {
  local port="$1" response rssi
  
  [ -z "$port" ] && return 1
  
  response=$(at_command "$port" "AT+CSQ" 3)
  
  if echo "$response" | grep -q "OK"; then
    rssi=$(echo "$response" | grep "+CSQ:" | cut -d' ' -f2 | cut -d',' -f1)
    
    if [ -n "$rssi" ] && [ "$rssi" != "99" ]; then
      echo "$rssi"
      return 0
    fi
  fi
  
  return 1
}

################################################################################
# STATE MACHINE HELPERS
################################################################################

# Save current state
save_state() {
  local state="$1"
  mkdir -p /tmp/fm350
  echo "$state" > /tmp/fm350/state
}

# Get current state
get_state() {
  [ -f /tmp/fm350/state ] && cat /tmp/fm350/state || echo "UNKNOWN"
}

# Transition to new state
transition_state() {
  local new_state="$1" old_state
  
  old_state=$(get_state)
  save_state "$new_state"
  
  log_limited info "State transition: $old_state -> $new_state"
}