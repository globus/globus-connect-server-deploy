#!/usr/bin/env bash

# shellcheck source=/dev/null
source /opt/automation/gcs/lib.sh

function main() {
  local endpoint_config
  local existing_collections
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

  logger "Checking for existing collections"
  existing_collections="$(globus-connect-server collection list -F json 2>&1 | jq -r '.[].display_name')"
  logger "Creating POSIX collection(s)"
  while read -r collection
  do
    name="$(jq -r '.name' <<< "${collection}")"

    if grep -Eq "^${name}$" <<< "${existing_collections}"
    then
      logger "Collection exists: ${name}"
      continue
    fi

    # First we need the ID of the gateway associated with this collection
    gateway="$(jq -r '.gateway_name' <<< "${collection}")"
    base_path="$(jq -r '.base_path' <<< "${collection}")"
    if ! output="$(globus-connect-server -F json storage-gateway list 2>&1)"
    then
      fail "Failed to list storage-gateways" "${output}"
    elif ! output="$(jq -er --arg gw "${gateway}" '.[0].data[]|select(.display_name == $gw)|.id' <<< "${output}" 2>&1)"
    then
      fail "Failed to find storage gateways" "${output}"
    else
      gateway_id="${output}"
    fi

    # Create the collection
    if ! output="$(globus-connect-server -F json collection create "${gateway_id}" "${base_path}" "${name}" 2>&1)"
    then
      fail "Failed to create collection '${name}'"
    else
      logger "Created collection: ${name}"
    fi
  done < <(jq -rc '.collection.posix[]' <<< "${endpoint_config}")
}

logger "Running create-collections"
main "$@"
