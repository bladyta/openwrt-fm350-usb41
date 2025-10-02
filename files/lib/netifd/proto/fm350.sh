#!/bin/sh
# FM350-GL netifd protocol handler
# POSIX/ash compliant - NO bashisms
# OpenWrt 24.10.x

# CRITICAL: Initialize protocol infrastructure
. /lib/functions.sh
. /lib/netifd/netifd-proto.sh
init_proto "$@"

proto_fm350_init_config() {
  no_device=1
  available=1
  
  proto_config_add_string "apn"
  proto_config_add_int "metric"
  proto_config_add_string "dns1"
  proto_config_add_string "dns2"
}

proto_fm350_setup() {
  local interface="$1"
  local apn metric dns1 dns2
  
  json_get_vars apn metric dns1 dns2
  
  # Wait for manager to create interface info
  local timeout=60 rndis_if
  
  logger -t fm350-proto -p daemon.info "Setting up interface $interface"
  
  while [ $timeout -gt 0 ]; do
    if [ -f /tmp/fm350/rndis_if ]; then
      rndis_if=$(cat /tmp/fm350/rndis_if 2>/dev/null)
      
      if [ -n "$rndis_if" ] && [ -d "/sys/class/net/$rndis_if" ]; then
        logger -t fm350-proto -p daemon.info "Found RNDIS interface: $rndis_if"
        
        # Report interface to netifd
        proto_init_update "$rndis_if" 1
        proto_send_update "$interface"
        
        return 0
      fi
    fi
    
    sleep 1
    timeout=$((timeout - 1))
  done
  
  logger -t fm350-proto -p daemon.err "Timeout waiting for RNDIS interface"
  proto_notify_error "$interface" "NO_INTERFACE"
  proto_block_restart "$interface"
  return 1
}

proto_fm350_teardown() {
  local interface="$1"
  
  logger -t fm350-proto -p daemon.info "Tearing down interface $interface"
  
  proto_kill_command "$interface"
}

add_protocol fm350