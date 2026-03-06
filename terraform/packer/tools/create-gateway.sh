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

  while read -r gateway
  do
    {
      name="$(jq -er '.name' <<< "${gateway}")"
      domain="$(jq -er '.domain' <<< "${gateway}")"
      type="$(jq -er '.type' <<< "${gateway}")"
      paths="$(jq -er '.restrict_paths' <<< "${gateway}")"
    } || fail "Failed to parse json: ${gateway}" 
    if ! output="$(globus-connect-server -F json storage-gateway create "${type}" --domain "${domain}" --restrict-paths "${paths}" "${name}" 2>&1)"
    then
      if "$(jq -er '.message | contains("already exist")' <<< "${output}" 2>&1)"
      then
        logger "storage-gateway already exists: '${name}'"
      else
        fail "Failed to create storage-gateway '${name}'" "${output}"
      fi
    else
      logger "Created storage-gateway: '${name}'"
    fi
  done < <(jq -rc '.gateways[]' <<< "${endpoint_config}")
}

logger "Running create-gateway"
main "$@"
