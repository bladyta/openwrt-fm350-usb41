#!/bin/sh
# FM350-GL USB41 Core Functions Library
# POSIX/ash compliant - NO bashisms
# OpenWrt 24.10.x / kernel 6.6
# VERSION: 22.1 (Master Prompt validated)

################################################################################
# MUST-USE FUNCTIONS (DO NOT MODIFY - REQUIRED BY SPEC)
################################################################################

log_limited() {
  local level="$1" msg="$2" now hash stamp last
  now=$(date +%s); hash=$(echo "$level:$msg" | md5sum | cut -d' ' -f1)
  stamp="/tmp/fm350.logstamp/$hash"; mkdir -p /tmp/fm350.logstamp
  if [ -f "$stamp" ]; then last=$(cat "$stamp" 2>/dev/null)
    [ -n "$last" ] && [ $((now - last)) -lt 5 ] && return
  fi; echo "$now" > "$stamp"; logger -t fm350 -p "daemon.$level" "$msg"
}

find_at_port() {
  local port response
  for port in /dev/ttyUSB* /dev/ttyACM*; do
    [ -c "$port" ] || continue
    stty -F "$port" 115200 raw -echo 2>/dev/null || true
    timeout 1 cat "$port" >/dev/null 2>&1
    printf "AT\r\n" > "$port" 2>/dev/null
    response=$(timeout 2 cat "$port" 2>/dev/null | head -n 10)
    if echo "$response" | grep -q "OK"; then
      timeout 1 cat "$port" >/dev/null 2>&1
      printf "ATE0\r\n" > "$port" 2>/dev/null; sleep 1
      timeout 1 cat "$port" >/dev/null 2>&1
      printf "AT+CMEE=2\r\n" > "$port" 2>/dev/null; sleep 1
      timeout 1 cat "$port" >/dev/null 2>&1
      echo "$port"; return 0
    fi
  done; return 1
}

find_rndis_interface() {
  local d drv
  for d in /sys/class/net/*; do
    [ -d "$d/device/driver" ] || continue
    drv=$(basename "$(readlink "$d/device/driver" 2>/dev/null)" 2>/dev/null)
    [ "$drv" = "rndis_host" ] || continue
    basename "$d"; return 0
  done; return 1
}

wait_for_dual_endpoints() {
  local timeout="${1:-30}" at="" ifc=""
  while [ $timeout -gt 0 ]; do
    [ -z "$at" ] && at=$(find_at_port)
    [ -z "$ifc" ] && ifc=$(find_rndis_interface)
    if [ -n "$at" ] && [ -n "$ifc" ]; then
      mkdir -p /tmp/fm350
      echo "$at"  > /tmp/fm350/at_port
      echo "$ifc" > /tmp/fm350/rndis_if
      return 0
    fi
    sleep 1; timeout=$((timeout-1))
  done; return 1
}

usb_reset_device() {
  local dev bus
  for dev in /sys/bus/usb/devices/*; do
    [ -f "$dev/idVendor" ] && [ -f "$dev/idProduct" ] || continue
    [ "$(cat "$dev/idVendor" 2>/dev/null)" = "0e8d" ] || continue
    grep -qE '^712[567]$' "$dev/idProduct" 2>/dev/null || continue
    if [ -f "$dev/authorized" ]; then
      echo 0 > "$dev/authorized" 2>/dev/null; sleep 3; echo 1 > "$dev/authorized" 2>/dev/null
    else
      bus=$(basename "$dev")
      echo "$bus" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null; sleep 3
      echo "$bus" > /sys/bus/usb/drivers/usb/bind  2>/dev/null
    fi; return 0
  done; return 1
}

at_command() {
  local port="$1" cmd="$2" to="${3:-5}" lock="/var/lock/fm350-at.lock" out waited=0
  mkdir -p /var/lock
  while [ $waited -lt 10 ]; do
    if mkdir "$lock" 2>/dev/null; then
      trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM
      timeout 1 cat "$port" >/dev/null 2>&1
      printf "%s\r\n" "$cmd" > "$port" 2>/dev/null
      out=$(timeout "$to" awk '
        /^OK$|^ERROR$|^\+CME ERROR:/ { print; exit }
        /^$/ { next } /^AT/ { next } { print }
      ' < "$port" 2>/dev/null)
      trap - EXIT INT TERM; rmdir "$lock" 2>/dev/null
      echo "$out"; echo "$out" | grep -q "^OK$" && return 0; return 1
    fi; sleep 1; waited=$((waited+1))
  done; return 1
}

setup_fallback_route() { ip route replace default dev "$1" metric "${2:-50}"; }

setup_dns_uci() {
  local d1="${1:-8.8.8.8}" d2="${2:-8.8.4.4}"
  uci delete network.wwan.dns 2>/dev/null || true
  uci add_list network.wwan.dns="$d1"; uci add_list network.wwan.dns="$d2"
  uci set network.wwan.peerdns='0'; uci commit network
  [ -f /var/run/dnsmasq.pid ] && kill -HUP "$(cat /var/run/dnsmasq.pid)" 2>/dev/null || true
  echo "$d1" > /tmp/fm350/dns1; echo "$d2" > /tmp/fm350/dns2
}

################################################################################
# OPTIONAL HELPER FUNCTIONS (POSIX COMPLIANT)
################################################################################

# Extract IPv4 from AT+CGPADDR response
get_pdp_ipv4() {
  local port="$1" response ip
  response=$(at_command "$port" "AT+CGPADDR=1" 5)
  if echo "$response" | grep -q "OK"; then
    ip=$(echo "$response" | grep -o '[0-9]\+\(\.[0-9]\+\)\{3\}' | head -n1)
    [ -n "$ip" ] && echo "$ip" && return 0
  fi
  return 1
}

# Apply IPv4 with /32 mask
apply_ipv4_addr() {
  local iface="$1" ip="$2"
  [ -z "$iface" ] || [ -z "$ip" ] && return 1
  ip addr flush dev "$iface" 2>/dev/null || true
  ip addr replace "$ip/32" dev "$iface" 2>/dev/null
  return $?
}

# Check recovery cooldown
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
  echo "$now" > "$last_file"
  return 0
}

# Check recovery budget (2/hour for L2/L3 only)
check_recovery_budget() {
  local level="$1" now count_file="/tmp/fm350/reset_count" count=0 ts
  local lock="/var/lock/fm350-budget.lock" waited=0
  
  [ "$level" != "L2" ] && [ "$level" != "L3" ] && return 0
  
  mkdir -p /var/lock /tmp/fm350
  now=$(date +%s)
  
  while [ $waited -lt 5 ]; do
    if mkdir "$lock" 2>/dev/null; then
      trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  
  [ $waited -ge 5 ] && return 1
  
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
  
  if [ $count -ge 2 ]; then
    log_limited err "Recovery budget exceeded: $count resets in last hour"
    trap - EXIT INT TERM
    rmdir "$lock" 2>/dev/null
    return 1
  fi
  
  echo "$now" >> "$count_file"
  
  trap - EXIT INT TERM
  rmdir "$lock" 2>/dev/null
  return 0
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

# Save/get/transition state
save_state() {
  mkdir -p /tmp/fm350
  echo "$1" > /tmp/fm350/state
}

get_state() {
  [ -f /tmp/fm350/state ] && cat /tmp/fm350/state || echo "UNKNOWN"
}

transition_state() {
  local new_state="$1" old_state
  old_state=$(get_state)
  save_state "$new_state"
  log_limited info "State transition: $old_state -> $new_state"
}
