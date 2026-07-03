#!/bin/bash

# Enable strict bash mode to stop the script if an uninitialized variable is used, if a command fails, or if a command with a pipe fails
# Not working in some setups : https://github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh
source constants.sh

# Failsafe watchdog state (see ipmi() and track_ipmi_result() in functions.sh)
IPMI_FAIL_COUNT=0
GRACEFUL_EXIT_IN_PROGRESS=false

# Trap the signals for container exit and run graceful_exit function
trap 'graceful_exit' SIGINT SIGQUIT SIGTERM

# Check that nvidia-smi is available when GPU monitoring is enabled
if $ENABLE_GPU_MONITORING && ! command -v nvidia-smi &> /dev/null; then
  print_error_and_exit "ENABLE_GPU_MONITORING is true but nvidia-smi was not found (did you run the container with GPU access, e.g. --gpus all ?)"
fi

# Prepare, format and define initial variables

# readonly DELL_FRESH_AIR_COMPLIANCE=45

# Check if FAN_SPEED variable is in hexadecimal format. If not, convert it to hexadecimal
if [[ "$FAN_SPEED" == 0x* ]]; then
  readonly DECIMAL_LOW_FAN_SPEED_OBJECTIVE=$(convert_hexadecimal_value_to_decimal "$FAN_SPEED")
  # Unused
  # readonly HEXADECIMAL_FAN_SPEED="$FAN_SPEED"
else
  readonly DECIMAL_LOW_FAN_SPEED_OBJECTIVE="$FAN_SPEED"
  # Unused
  # readonly HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$FAN_SPEED")
fi

# Check if fan speed interpolation is enabled
if [[ "$FAN_SPEED" -gt "$HIGH_FAN_SPEED" ]]; then
  echo "Error : \"$FAN_SPEED\" have to be less or equal to \"$HIGH_FAN_SPEED\". Exiting."
  exit 1
elif [ -z "$HIGH_FAN_SPEED" ] || [ -z "$CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION" ] || [ "$CPU_TEMPERATURE_THRESHOLD" -eq "$CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION" ]; then
  readonly FAN_SPEED_INTERPOLATION_ENABLED=false
  
  # We define these variables to the same values than user fan control profile
  readonly HIGH_FAN_SPEED="$FAN_SPEED"
  readonly CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION="$CPU_TEMPERATURE_THRESHOLD"
else
  readonly FAN_SPEED_INTERPOLATION_ENABLED=true
fi

# Check if HIGH_FAN_SPEED variable is in hexadecimal format. If not, convert it to hexadecimal
if [[ "$HIGH_FAN_SPEED" == 0x* ]]; then
  readonly DECIMAL_HIGH_FAN_SPEED_OBJECTIVE=$(convert_hexadecimal_value_to_decimal "$HIGH_FAN_SPEED")
  # Unused
  # readonly HEXADECIMAL_HIGH_FAN_SPEED="$HIGH_FAN_SPEED"
else
  readonly DECIMAL_HIGH_FAN_SPEED_OBJECTIVE="$HIGH_FAN_SPEED"
  # Unused
  # readonly HEXADECIMAL_HIGH_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$HIGH_FAN_SPEED")
fi

set_iDRAC_login_string "$IDRAC_HOST" "$IDRAC_USERNAME" "$IDRAC_PASSWORD"

get_Dell_server_model

if [[ ! $SERVER_MANUFACTURER == "DELL" ]]; then
  print_error_and_exit "Your server isn't a Dell product"
fi

# If server model is Gen 14 (*40) or newer
if [[ $SERVER_MODEL =~ .*[RT][[:space:]]?[0-9][4-9]0.* ]]; then
  readonly DELL_POWEREDGE_GEN_14_OR_NEWER=true
  readonly CPU1_TEMPERATURE_INDEX=2
  readonly CPU2_TEMPERATURE_INDEX=4
else
  readonly DELL_POWEREDGE_GEN_14_OR_NEWER=false
  readonly CPU1_TEMPERATURE_INDEX=1
  readonly CPU2_TEMPERATURE_INDEX=2
fi

# Log main informations
echo "Server model: $SERVER_MANUFACTURER $SERVER_MODEL"
echo "iDRAC/IPMI host: $IDRAC_HOST"

# Log the check interval, fan speed objective and CPU temperature threshold
echo "Check interval: ${CHECK_INTERVAL}s"
echo "IPMI watchdog: ${IPMI_COMMAND_TIMEOUT}s timeout, exit after $IPMI_MAX_CONSECUTIVE_FAILURES consecutive failures"
echo "GPU monitoring enabled: $ENABLE_GPU_MONITORING"
if $ENABLE_GPU_MONITORING; then
  echo "GPU temperature threshold offset: ${GPU_TEMPERATURE_THRESHOLD_OFFSET}°C (subtracted from GPU temperatures before threshold comparison)"
fi
if [ -n "$METRICS_EXPORT_PATH" ]; then
  echo "Metrics export path: $METRICS_EXPORT_PATH"
fi
echo "Fan speed interpolation enabled: $FAN_SPEED_INTERPOLATION_ENABLED"
if $FAN_SPEED_INTERPOLATION_ENABLED; then
  echo "Fan speed lower value: $DECIMAL_LOW_FAN_SPEED_OBJECTIVE%"
  echo "Fan speed higher value: $DECIMAL_HIGH_FAN_SPEED_OBJECTIVE%"
  echo "CPU lower temperature threshold: \"$CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION\"°C"
  echo "CPU higher temperature threshold: \"$CPU_TEMPERATURE_THRESHOLD\"°C"
  echo ""
  # Print interpolated fan speeds for demonstration
  print_interpolated_fan_speeds "$CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION" "$CPU_TEMPERATURE_THRESHOLD" "$DECIMAL_LOW_FAN_SPEED_OBJECTIVE" "$DECIMAL_HIGH_FAN_SPEED_OBJECTIVE"
else
  echo "Fan speed objective: $DECIMAL_LOW_FAN_SPEED_OBJECTIVE%"
  echo "CPU temperature threshold: $CPU_TEMPERATURE_THRESHOLD°C"
fi
echo ""

TABLE_HEADER_PRINT_COUNTER=$TABLE_HEADER_PRINT_INTERVAL
# Set the flag used to check if the active fan control profile has changed
IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true

# State tracking : cache of the last values actually sent to the iDRAC, so identical IPMI commands are not re-sent every loop
# Holds "DELL_DEFAULT", a hexadecimal fan speed (0x*), or "" (unknown state, next command will always be sent)
LAST_APPLIED_FAN_SPEED=""
LAST_APPLIED_THIRD_PARTY_PCIE_COOLING_RESPONSE=""

# GPU temperature state, kept valid even when GPU monitoring is disabled
GPU_TEMPERATURE="-"
ADJUSTED_GPU_TEMPERATURE=0

# Check present sensors
IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=true
IS_CPU2_TEMPERATURE_SENSOR_PRESENT=true
retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
if [ -z "$EXHAUST_TEMPERATURE" ]; then
  echo "No exhaust temperature sensor detected."
  IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=false
fi
if [ -z "$CPU2_TEMPERATURE" ]; then
  echo "No CPU2 temperature sensor detected."
  IS_CPU2_TEMPERATURE_SENSOR_PRESENT=false
fi
# Output new line to beautify output if one of the previous conditions have echoed
if ! $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT || ! $IS_CPU2_TEMPERATURE_SENSOR_PRESENT; then
  echo ""
fi

#readonly NUMBER_OF_DETECTED_CPUS=(${CPUS_TEMPERATURES//;/ })
# TODO : write "X CPU sensors detected." and remove previous ifs
readonly HEADER=$(build_header $NUMBER_OF_DETECTED_CPUS)

# Start monitoring
while true; do
  # Sleep for the specified interval before taking another reading
  sleep "$CHECK_INTERVAL" &
  SLEEP_PROCESS_PID=$!

  retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT

  # Retrieve the highest GPU temperature if GPU monitoring is enabled
  if $ENABLE_GPU_MONITORING; then
    retrieve_gpu_temperature
  fi

  # Compute the highest CPU temperature, used for interpolation and metrics export
  HIGHEST_CPU_TEMPERATURE=$CPU1_TEMPERATURE
  if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT; then
    HIGHEST_CPU_TEMPERATURE=$(max $CPU1_TEMPERATURE $CPU2_TEMPERATURE)
  fi

  # Initialize a variable to store the comments displayed when the fan control profile changed
  COMMENT=" -"
  # Check if CPU 1 is overheating then apply Dell default dynamic fan control profile if true
  if CPU1_OVERHEATING; then
    apply_Dell_default_fan_control_profile

    if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true

      # If CPU 2 temperature sensor is present, check if it is overheating too.
      # Do not apply Dell default dynamic fan control profile as it has already been applied before
      if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && CPU2_OVERHEATING; then
        COMMENT="CPU 1 and CPU 2 temperatures are too high, Dell default dynamic fan control profile applied for safety"
      else
        COMMENT="CPU 1 temperature is too high, Dell default dynamic fan control profile applied for safety"
      fi
    fi
  # If CPU 2 temperature sensor is present, check if it is overheating then apply Dell default dynamic fan control profile if true
  elif $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && CPU2_OVERHEATING; then
    apply_Dell_default_fan_control_profile

    if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
      COMMENT="CPU 2 temperature is too high, Dell default dynamic fan control profile applied for safety"
    fi
  # Check if a GPU is overheating (offset already applied) then apply Dell default dynamic fan control profile if true
  elif GPU_OVERHEATING; then
    apply_Dell_default_fan_control_profile

    if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
      COMMENT="GPU temperature is too high (${GPU_TEMPERATURE}°C), Dell default dynamic fan control profile applied for safety"
    fi
  elif CPU1_HEATING || { $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && CPU2_HEATING; } || GPU_HEATING; then
    # Reference temperature for interpolation : hottest device, GPU temperature taken after offset adjustment
    REFERENCE_TEMPERATURE=$HIGHEST_CPU_TEMPERATURE
    if $ENABLE_GPU_MONITORING; then
      REFERENCE_TEMPERATURE=$(max $HIGHEST_CPU_TEMPERATURE $ADJUSTED_GPU_TEMPERATURE)
    fi

    DECIMAL_FAN_SPEED_TO_APPLY=$(calculate_interpolated_fan_speed $DECIMAL_LOW_FAN_SPEED_OBJECTIVE $DECIMAL_HIGH_FAN_SPEED_OBJECTIVE $REFERENCE_TEMPERATURE $CPU_TEMPERATURE_THRESHOLD_FOR_FAN_SPEED_INTERPOLATION $CPU_TEMPERATURE_THRESHOLD)
    apply_user_fan_control_profile 2 $DECIMAL_FAN_SPEED_TO_APPLY
  else
    apply_user_fan_control_profile 1 $DECIMAL_LOW_FAN_SPEED_OBJECTIVE

    # Check if user fan control profile is applied then apply it if not
    if $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=false
      COMMENT="CPU temperature decreased and is now OK (<= $CPU_TEMPERATURE_THRESHOLD°C), user's fan control profile applied."
    fi
  fi

  # If server model is not Gen 14 (*40) or newer
  if ! $DELL_POWEREDGE_GEN_14_OR_NEWER; then
    # Enable or disable, depending on the user's choice, third-party PCIe card Dell default cooling response
    # No comment will be displayed on the change of this parameter since it is not related to the temperature of any device (CPU, GPU, etc...) but only to the settings made by the user when launching this Docker container
    if "$DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE"; then
      disable_third_party_PCIe_card_Dell_default_cooling_response
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Disabled"
    else
      enable_third_party_PCIe_card_Dell_default_cooling_response
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Enabled"
    fi
  fi

  # Print temperatures, active fan control profile and comment if any change happened during last time interval
  if [ $TABLE_HEADER_PRINT_COUNTER -eq $TABLE_HEADER_PRINT_INTERVAL ]; then
    printf "%s\n" "$HEADER"
    TABLE_HEADER_PRINT_COUNTER=0
  fi
  print_temperature_array_line "$INLET_TEMPERATURE" "$CPUS_TEMPERATURES" "$GPU_TEMPERATURE" "$EXHAUST_TEMPERATURE" "$CURRENT_FAN_CONTROL_PROFILE" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$COMMENT"
  ((TABLE_HEADER_PRINT_COUNTER++))

  # Export metrics as JSON for external monitoring agents, if enabled
  export_metrics

  wait $SLEEP_PROCESS_PID
done
