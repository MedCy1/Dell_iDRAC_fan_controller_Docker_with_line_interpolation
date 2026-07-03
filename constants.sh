#!/bin/bash

# Define the interval for printing temperature table header
readonly TABLE_HEADER_PRINT_INTERVAL=10

# Default values for optional features, all overridable via environment variables

# GPU monitoring : take Nvidia GPU temperatures into account (requires nvidia-smi inside the container, e.g. Docker --gpus all)
readonly ENABLE_GPU_MONITORING="${ENABLE_GPU_MONITORING:-false}"
# Subtracted from the raw GPU temperature before comparison with the CPU thresholds (GPUs tolerate more heat than CPUs)
readonly GPU_TEMPERATURE_THRESHOLD_OFFSET="${GPU_TEMPERATURE_THRESHOLD_OFFSET:-0}"

# Failsafe watchdog : timeout (seconds) applied to every ipmitool call, and number of consecutive failures before giving fan control back to the Dell hardware controller
readonly IPMI_COMMAND_TIMEOUT="${IPMI_COMMAND_TIMEOUT:-5}"
readonly IPMI_MAX_CONSECUTIVE_FAILURES="${IPMI_MAX_CONSECUTIVE_FAILURES:-3}"
