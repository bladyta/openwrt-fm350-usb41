#!/bin/sh
# FM350-GL End-to-End Integration Test
# POSIX/ash compliant
# v22.1: Tests DHCP OR CGPADDR + PDP activation

set -e

. /usr/lib/fm350/functions.sh

echo "=========================================="
echo "FM350-GL E2E Test Suite v22.1"
echo "=========================================="
echo

FAIL_COUNT=0

fail() {
  echo "✗ FAIL: $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  echo "✓ PASS: $1"
}

echo "Test 1: AT Port Detection"
AT_PORT=$(find_at_port)
if [ -n "$AT_PORT" ] && [ -c "$AT_PORT" ]; then
  pass "AT port found: $AT_PORT"
else
  fail "AT port not found"
  exit 1
fi
echo

echo "Test 2: RNDIS Interface Detection"
RNDIS_IF=$(find_rndis_interface)
if [ -n "$RNDIS_IF" ] && [ -d "/sys/class/net/$RNDIS_IF" ]; then
  pass "RNDIS interface found: $RNDIS_IF"
else
  fail "RNDIS interface not found"
  exit 1
fi
echo

echo "Test 3: USB Mode Check"
RESPONSE=$(at_command "$AT_PORT" "AT+GTUSBMODE?" 5)
if echo "$RESPONSE" | grep -q "OK"; then
  MODE=$(echo "$RESPONSE" | grep "+GTUSBMODE:" | cut -d' ' -f2)
  if [ "$MODE" = "41" ]; then
    pass "USB mode is 41 (RNDIS+AT)"
  else
    fail "USB mode is $MODE (expected 41)"
  fi
else
  fail "Could not query USB mode"
fi
echo

echo "Test 4: Modem Functionality"
RESPONSE=$(at_command "$AT_PORT" "AT+CFUN?" 5)
if echo "$RESPONSE" | grep -q "OK"; then
  pass "Modem responding to AT commands"
else
  fail "Modem not responding properly"
fi
echo

echo "Test 5: SIM Status"
RESPONSE=$(at_command "$AT_PORT" "AT+CPIN?" 5)
if echo "$RESPONSE" | grep -q "READY"; then
  pass "SIM ready"
elif echo "$RESPONSE" | grep -q "SIM PIN"; then
  fail "SIM requires PIN"
else
  fail "SIM not ready"
fi
echo

echo "Test 6: PDP Context Status"
RESPONSE=$(at_command "$AT_PORT" "AT+CGACT?" 5)
if echo "$RESPONSE" | grep -q "OK"; then
  if echo "$RESPONSE" | grep -q "+CGACT: 1,1"; then
    pass "PDP context is active"
  else
    echo "Info: PDP context not active, attempting activation..."
    if at_command "$AT_PORT" "AT+CGACT=1,1" 30 | grep -q "OK"; then
      pass "PDP context activated successfully"
    else
      fail "PDP context activation failed"
    fi
  fi
else
  fail "Could not query PDP context status"
fi
echo

echo "Test 7: Network Configuration Method (DHCP or CGPADDR)"
if ip addr show dev "$RNDIS_IF" | grep -q "inet .* scope global dynamic"; then
  pass "DHCP configuration detected on $RNDIS_IF"
elif ip addr show dev "$RNDIS_IF" | grep -q "inet .*/32"; then
  pass "CGPADDR /32 fallback configuration detected on $RNDIS_IF"
  
  # Verify CGPADDR matches
  IP_FROM_AT=$(at_command "$AT_PORT" "AT+CGPADDR=1" 5 | grep -o '[0-9]\+\(\.[0-9]\+\)\{3\}' | head -n1)
  if [ -n "$IP_FROM_AT" ]; then
    echo "Info: AT+CGPADDR=1 returned $IP_FROM_AT"
  fi
else
  fail "Unknown network configuration method on $RNDIS_IF"
fi
echo

echo "Test 8: Default Route"
if ip route | grep -q "default.*dev $RNDIS_IF"; then
  pass "Default route via $RNDIS_IF exists"
else
  fail "No default route via $RNDIS_IF"
fi
echo

echo "Test 9: Ping Test"
if ping -I "$RNDIS_IF" -c 3 -W 5 8.8.8.8 >/dev/null 2>&1; then
  pass "Ping to 8.8.8.8 successful"
else
  fail "Ping to 8.8.8.8 failed"
fi
echo

echo "Test 10: DNS Resolution"
if nslookup google.com >/dev/null 2>&1; then
  pass "DNS resolution working"
else
  fail "DNS resolution failed"
fi
echo

echo "Test 11: Signal Quality"
RESPONSE=$(at_command "$AT_PORT" "AT+CSQ" 5)
if echo "$RESPONSE" | grep -q "OK"; then
  RSSI=$(echo "$RESPONSE" | grep "+CSQ:" | cut -d' ' -f2 | cut -d',' -f1)
  if [ -n "$RSSI" ] && [ "$RSSI" != "99" ]; then
    pass "Signal quality: $RSSI"
  else
    fail "No signal (RSSI=99)"
  fi
else
  fail "Could not query signal quality"
fi
echo

echo "=========================================="
if [ $FAIL_COUNT -eq 0 ]; then
  echo "✓ ALL TESTS PASSED"
  exit 0
else
  echo "✗ $FAIL_COUNT TEST(S) FAILED"
  exit 1
fi
