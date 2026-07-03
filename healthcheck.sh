#!/bin/bash

# Enable strict bash mode to stop the script if an uninitialized variable is used, if a command fails, or if a command with a pipe fails
# Not working in some setups : https://github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh
source constants.sh

set_iDRAC_login_string "$IDRAC_HOST" "$IDRAC_USERNAME" "$IDRAC_PASSWORD"

# 1. The iDRAC must answer an IPMI query within IPMI_COMMAND_TIMEOUT seconds (output kept visible in "docker inspect" health log)
ipmi sdr type temperature || exit 1

# 2. When GPU monitoring drives the fans, a persistent nvidia-smi failure means the GPUs silently stopped being taken into account
if $ENABLE_GPU_MONITORING; then
  nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader > /dev/null 2>&1 || { echo "nvidia-smi failed while ENABLE_GPU_MONITORING is true"; exit 1; }
fi

# 3. When metrics export is enabled, the file must exist and be fresh : a stale file means the main loop is stuck
if [ -n "$METRICS_EXPORT_PATH" ]; then
  if [ ! -f "$METRICS_EXPORT_PATH" ]; then
    echo "Metrics file $METRICS_EXPORT_PATH not found"
    exit 1
  fi
  METRICS_FILE_AGE=$(( $(date +%s) - $(stat -c %Y "$METRICS_EXPORT_PATH") ))
  if [ "$METRICS_FILE_AGE" -gt $(( ${CHECK_INTERVAL:-60} * 3 )) ]; then
    echo "Metrics file is ${METRICS_FILE_AGE}s old (main loop stuck?)"
    exit 1
  fi
fi

exit 0
