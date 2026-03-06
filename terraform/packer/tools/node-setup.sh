#!/usr/bin/env bash

# shellcheck source=/dev/null
source /opt/automation/gcs/lib.sh

function main() {
  local ssm_id="${1}"
  if [[ -z "${ssm_id}" ]]
  then
    fail "The SSM ID for the endpoint was not provided"
  fi

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

  logger "Fetch deployment-key and GCS CLI Envs"
  fetch_deployment_key "${ssm_id}"
  set_gcs_cli_envs "${ssm_id}"

  logger "Running Node Setup"
  if ! output="$(sudo -E globus-connect-server -F json node setup 2>&1)"
  then
    fail "Failed to run node setup" "${output}"
  fi

  sudo rm -f ./deployment-key.json
  logger "Node setup complete"
}

logger "Running node-setup"
main "$@"
