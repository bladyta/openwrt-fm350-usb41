#!/bin/sh
# FM350-GL AT Command Sender
# POSIX/ash compliant

. /usr/lib/fm350/functions.sh

if [ $# -lt 1 ]; then
  echo "Usage: $0 'AT+COMMAND' [timeout]"
  echo
  echo "Examples:"
  echo "  $0 'AT+CGSN'          # Get IMEI"
  echo "  $0 'AT+CSQ'           # Signal quality"
  echo "  $0 'AT+CGPADDR=1'     # PDP address"
  echo "  $0 'AT+GTUSBMODE?'    # USB mode"
  exit 1
fi

AT_CMD="$1"
TIMEOUT="${2:-5}"

AT_PORT=$(find_at_port)

if [ -z "$AT_PORT" ]; then
  echo "ERROR: AT port not found"
  exit 1
fi

echo "Using AT port: $AT_PORT"
echo "Sending: $AT_CMD"
echo "Timeout: ${TIMEOUT}s"
echo

RESPONSE=$(at_command "$AT_PORT" "$AT_CMD" "$TIMEOUT")
EXIT_CODE=$?

echo "Response:"
echo "$RESPONSE"
echo

if [ $EXIT_CODE -eq 0 ]; then
  echo "✓ Command successful"
  exit 0
else
  echo "✗ Command failed"
  exit 1
fi
