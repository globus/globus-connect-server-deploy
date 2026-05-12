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

  logger "Establishing GCS CLI Envs"
  set_gcs_cli_envs "${ssm_id}"

  while read -r role
  do
    logger "Processing role '${role}'"
    while read -r user
    do
      if ! output="$(globus-connect-server -F json endpoint role create "${role}" "${user}" 2>&1)"
      then
        if "$(jq -er '.message | contains("already exists")' <<< "${output}" 2>&1)"
        then
          logger "User ${user} already assigned role ${role}"
        else
          logger "WARNING" "Failed to assign ${role} to user ${user}"
        fi
      else
        logger "Assigned ${role} to user ${user}"
      fi
    done < <(jq -r --arg r "${role}" '.role[$r]|.[]' <<< "${endpoint_config}")
  done < <(jq -r '.role | keys | .[]' <<< "${endpoint_config}")
}

logger "Running create-roles"
main "$@"
