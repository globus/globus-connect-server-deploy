#!/usr/bin/env bash

# shellcheck source=/dev/null
source /opt/automation/gcs/lib.sh

function main() {
  local endpoint_config
  local ssm_id="${1}"
  local ssm_path="${SSM_PREFIX}/endpoint/${ssm_id}"

  if [[ -z "${ssm_id}" ]]
  then
    fail "The SSM ID for the endpoint was not provided"
  fi

  if ! output="$(get_parameter_value "${ssm_path}/config" 2>&1)"
  then
    fail "Failed to obtain the endpoint config" "${output}"
  else
    endpoint_config="${output}"
  fi

  subscription_id="$(jq -er '.subscription_id' <<< "${endpoint_config}")"

  logger "Establishing GCS CLI Envs"
  set_gcs_cli_envs "${ssm_id}"

  if ! output="$(globus-connect-server -F json endpoint set-subscription-id "${subscription_id}" 2>&1)"
  then
    fail "Failed to set subscription ID" "${output}"
  fi
}

logger "Running set-subscription"
main "$@"
