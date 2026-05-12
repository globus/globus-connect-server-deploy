#!/usr/bin/env bash

set -euo pipefail

export SSM_PREFIX="/automation/gcs"

function logger() {
  local level
  local message

  if (( $# == 1 ))
  then
    level="INFO"
    message="${1}"
  else
    level="${1}"
    message="${2}"
  fi

  # If it's valid json, print it on one-line otherwise
  # treat it as a regular string and trim newlines.
  if jq 'empty' <<< "${message}" > /dev/null 2>&1
  then
    message="$(jq -rc <<< "${message}")"
  else
    message="$(tr -d '\n' <<< "${message}")"
  fi

  printf "[%s] [%s] %s\n" "$(date +'%F %T')" "${level}" "${message}"
}

function fail() {
  local message
  local output

  message="${1}"

  logger "ERROR" "${message}" >&2

  # A custom error message is typically followed by another
  # erorr message or context involving the error, if so we
  # will log that too.
  if (( $# == 2 ))
  then
    output="${2}"
    logger "ERROR" "${output}" >&2
  fi

  exit 1
}

function get_parameter_value() {
  local output
  local parameter

  if (( $# != 1 ))
  then
    fail "Expected one argument as the name of the SSM Parameter"
  else
    parameter="${1}"
  fi

  if ! output="$(aws ssm get-parameter --name "${parameter}" --query "Parameter.Value" --output text --with-decryption 2>&1)"
  then
    fail "Failed to obtain parameter '${parameter}'" "${output}"
  fi

  echo "${output}"
}

function set_gcs_cli_envs() {
  local ssm_id="${1}"

  if [[ -z "${ssm_id}" ]]
  then
    fail "The SSM ID for the endpoint was not provided"
  fi

  # It's possible we already have the envs set, in which case 
  # we don't need to rerun the whole process. This avoids
  # unnecessary API calls.
  if (( "$(env | grep -Ec 'GCS_CLI_(CLIENT_(ID|SECRET)|ENDPOINT_ID)')" == 3 ))
  then
    return 0
  fi

  set_client_session
  set_endpoint_id "${ssm_id}"
}

function set_client_session() {
  GCS_CLI_CLIENT_ID="$(get_parameter_value "/automation/gcs/client/id")"
  GCS_CLI_CLIENT_SECRET="$(get_parameter_value "/automation/gcs/client/secret")"

  export GCS_CLI_CLIENT_ID
  export GCS_CLI_CLIENT_SECRET
}

function set_endpoint_id() {
  local output
  local ssm_id="${1}"
  local ssm_path="${SSM_PREFIX}/endpoint/${ssm_id}"

  if [[ -z "${ssm_id}" ]]
  then
    fail "The SSM ID for the endpoint was not provided"
  fi

  if ! output="$(get_parameter_value "${ssm_path}/id")"
  then
    fail "Failed to obtain the endpoint ID" "${output}"
  elif [[ "${output}" == " " ]] || [[ "${output}" == "-" ]]
  then
    fail "Endpoint is not setup"
  else
    export GCS_CLI_ENDPOINT_ID="${output}"
  fi
}

function fetch_deployment_key() {
  local ssm_id="${1}"
  local ssm_path="${SSM_PREFIX}/endpoint/${ssm_id}"

  if ! [[ -f "deployment-key.json" ]]
  then
    if ! output="$(get_parameter_value "${ssm_path}/deployment_key")"
    then
      fail "Failed to obtain deployment key" "${output}"
    else
      echo "${output}" > ./deployment-key.json
    fi
  else
    logger "Skipped fetching SSM Parameter as deployment-key.json was found"
  fi
}