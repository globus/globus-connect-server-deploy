#!/usr/bin/env bash

# shellcheck source=/dev/null
source /opt/automation/gcs/lib.sh

function main() {
  local instance_id
  local skip_node_cleanup="false"
  local ssm_id="${1}"
  local ssm_path="${SSM_PREFIX}/endpoint/${ssm_id}"
  local token

  if [[ -z "${ssm_id}" ]]
  then
    fail "The SSM ID for the endpoint was not provided"
  fi

  if output="$(stat -c '%b' /var/lib/globus-connect-server/info.json 2>&1)"
  then
    if (( output == 0 ))
    then
      skip_node_cleanup="true"
    fi
  else
    fail "Was globus-connect-server installed?"
  fi

  logger "Fetch deployment-key and GCS CLI Envs"
  fetch_deployment_key "${ssm_id}"
  set_gcs_cli_envs "${ssm_id}"

  if ! "${skip_node_cleanup}"
  then
    logger "Running Node Cleanup"
    if ! output="$(echo "y" | sudo -E globus-connect-server -F json node cleanup 2>&1)"
    then
      fail "Failed to run node cleanup" "${output}"
    else
      token="$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")"
      instance_id="$(curl -H "X-aws-ec2-metadata-token: ${token}" http://169.254.169.254/latest/meta-data/instance-id)"
      if ! output="$(aws ec2 create-tags --resources "${instance_id}" --tags "Key=cleaned,Value=true")"
      then
        # We'll treat this as a warning rather than an error"
        logger "WARNING" "Failed to set tag cleaned to true" 
        logger "ERROR" "${output}"
      fi
    fi
  else
    logger "Skipping node cleanup"
  fi

  logger "Running Endpoint Cleanup"
  # node cleanup removes the key so we need to refetch it
  fetch_deployment_key "${ssm_id}"
  if ! output="$(sudo -E globus-connect-server -F json endpoint cleanup --agree-to-delete-endpoint 2>&1)"
  then
    fail "Failed to run endpoint cleanup" "${output}"
  fi

  logger "Clearing SSM Parameters"
  if ! output="$(aws ssm put-parameter --name "${ssm_path}/id" --overwrite --value "-" 2>&1)"
  then
    fail "Failed to clear SSM Param '${ssm_path}/id'" "${output}"
  fi
  if ! output="$(aws ssm put-parameter --name "${ssm_path}/deployment_key" --overwrite --value "-" 2>&1)"
  then
    fail "Failed to clear SSM Param '${ssm_path}/deployment_key'" "${output}"
  fi

  logger "Finished running cleanup"
}

logger "Running cleanup"
main "$@"
