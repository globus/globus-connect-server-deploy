#!/usr/bin/env bash

# shellcheck source=/dev/null
source /opt/automation/gcs/lib.sh

cd /opt/automation/gcs/ || { fail "Failed to cd into script directory" ; }

function main() {
  local ssm_id="${1}"

  if [[ -z "${ssm_id}" ]]
  then
    fail "The SSM ID for the endpoint was not provided"
  fi

  set -- "${ssm_id}"
  ./endpoint-setup.sh "$@"
  ./node-setup.sh "$@"
  ./set-subscription.sh "$@"
  ./create-roles.sh "$@"
  ./create-gateway.sh "$@"
  ./create-collections.sh "$@"
}

main "$@"
