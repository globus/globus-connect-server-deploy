#!/usr/bin/env bash

# shellcheck source=/dev/null
source /opt/automation/gcs/lib.sh

function endpoint_setup() {
  local endpoint_config
  local endpoint_domain
  local endpoint_id
  local endpoint_name
  local output

  endpoint_config="$(get_parameter_value "${ssm_path}/config")"
  endpoint_name="$(jq -r '.name' <<< "${endpoint_config}")"

  if output="$(stat -c '%b' /var/lib/globus-connect-server/info.json 2>&1)"
  then
    if (( output > 1 ))
    then
      # Return 0 so the `deploy.sh` script can continue.
      logger "Both endpoint and node setup were already ran on this host"
      return 0
    fi
  else
    fail "Was globus-connect-server installed?"
  fi

  # Passing in the arguments to the GCS CLI is quite tricky with
  # quoting and is not as straightforward as one thinks. So we loop
  # through and add each flag and its argument to an array. Account
  # for the flags that don't have arguments (e.g. --public).
  mapfile -t args < <(jq -r '.arguments | to_entries[] | if .key == .value then .key else .key,.value end' <<< "${endpoint_config}")

  endpoint_id=$(get_parameter_value "${ssm_path}/id")
  if grep -Eq '[a-z0-9-]{4,}' <<< "${endpoint_id}"
  then
    logger "Endpoint was already setup"
    return 0
  fi

  # shellcheck disable=SC2086
  if ! output="$(sudo -E globus-connect-server endpoint setup "${args[@]}" "${endpoint_name}" 2>&1)"
  then
    fail "Failed to register the endpoint" "${output}"
  else
    # Ensure file is present and valid json; note it's owned by root
    if ! sudo jq -e '.' ./deployment-key.json > /dev/null 2>&1
    then
      fail "File not found or invalid JSON detected in deployment-key.json"
    fi

    logger "Endpoint Name: ${endpoint_name}"
    if ! endpoint_id="$(grep '^Created endpoint' <<< "${output}" | cut -d ' ' -f 3)"
    then
      fail "Failed to parse for the endpoint ID"
    fi
    logger "Endpoint ID: ${endpoint_id}"
    if ! endpoint_domain="$(grep '^Endpoint domain_name' <<< "${output}" | cut -d ' ' -f 3)"
    then
      fail "Failed to parse for endpoint domain name"
    fi
    logger "Endpoint Domain: ${endpoint_domain}"
  fi

  logger "Storing Endpoint ID"
  if ! output="$(aws ssm put-parameter --name "${ssm_path}/id" --overwrite --value "${endpoint_id}" 2>&1)"
  then
    fail "Failed to update SSM Param '${ssm_path}/id'" "${output}"
  fi

  logger "Storing deployment-key.json"
  if ! output="$(aws ssm put-parameter --name "${ssm_path}/deployment_key" --overwrite --value "$(sudo jq -rc '.' ./deployment-key.json)" 2>&1)"
  then
    fail "Failed to update SSM Param '${ssm_path}/deployment_key'" "${output}"
  else
    sudo rm -f ./deployment-key.json
  fi

  logger "Endpoint setup complete"
}

function main() {
  local args=()
  local output
  local ssm_id="${1}"
  ssm_path="${SSM_PREFIX}/endpoint/${ssm_id}"

  if [[ -z "${ssm_id}" ]]
  then
    fail "The SSM ID for the endpoint was not provided"
  fi

  logger "Running endpoint-setup"

  if output="$(stat -c '%b' /var/lib/globus-connect-server/info.json 2>&1)"
  then
    if (( output > 1 ))
    then
      logger "Existing configured endpoint/node found"
    fi
  else
    fail "Was globus-connect-server installed?"
  fi

  logger "Establishing GCS Client credentials"
  set_client_session

  endpoint_setup
}

main "$@"