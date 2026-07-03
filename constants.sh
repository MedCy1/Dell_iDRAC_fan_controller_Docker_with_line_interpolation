#!/bin/bash

# Define the interval for printing temperature table header
readonly TABLE_HEADER_PRINT_INTERVAL=10

# Default values for optional features, all overridable via environment variables

# Failsafe watchdog : timeout (seconds) applied to every ipmitool call, and number of consecutive failures before giving fan control back to the Dell hardware controller
readonly IPMI_COMMAND_TIMEOUT="${IPMI_COMMAND_TIMEOUT:-5}"
readonly IPMI_MAX_CONSECUTIVE_FAILURES="${IPMI_MAX_CONSECUTIVE_FAILURES:-3}"
