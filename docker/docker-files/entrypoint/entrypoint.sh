#!/bin/bash
############################################################################
# GCS container entrypoint
#
# Checks the environment, runs 'globus-connect-server node setup' (which starts
# the GCS services through the systemctl mock), then watches those services
# until the container gets SIGTERM or one of them dies.
#
# You must bind-mount the endpoint's deployment key:
#   docker run -v /path/to/deployment-key.json:/deployment-key.json:ro ...
#
# Optional environment variables:
#   NODE_SETUP_ARGS         extra arguments for 'node setup'
#   GLOBUS_SDK_ENVIRONMENT  target a non-production Globus environment
#
# Steps, in order: capability check, deployment key, node setup, signal
# handling, monitor.
############################################################################

############################################################################
# CAPABILITY CHECK
#
# The systemctl mock needs two Linux capabilities (CAP_SETUID, CAP_SETGID) to
# drop privileges when it starts services.  Check first, so a container started
# without them gets a clear message and not an obscure permission error buried
# in service startup output.
############################################################################
systemctl check-capabilities || exit 1

############################################################################
# DEPLOYMENT KEY
#
# The key is bind-mounted at a fixed path rather than passed in an environment
# variable, which keeps its contents out of 'ps' output on the host.
############################################################################
deployment_key=/deployment-key.json

if [ ! -f "$deployment_key" ]; then
    echo "Error: deployment key not found at ${deployment_key}" >&2
    echo "       Mount it with: docker run -v /path/to/deployment-key.json:${deployment_key}:ro ..." >&2
    exit 1
fi

############################################################################
# NODE SETUP
#
# 'node setup' configures this GCS node and starts every service it needs by
# calling 'systemctl enable' and 'systemctl start', which the mock handles.
############################################################################
globus-connect-server node setup      \
    --deployment-key "$deployment_key" \
    ${NODE_SETUP_ARGS}

if [ $? -ne 0 ]; then
    echo "Error: node setup failed" >&2
    exit 1
fi

############################################################################
# SIGNAL HANDLING
#
# On SIGTERM or exit, stop every service the mock is tracking, then run
# 'node cleanup'.  HUP and INT are ignored.  'shutting_down' stops cleanup from
# running twice: it can be reached from SIGTERM, from the call at the bottom, and
# from the EXIT trap.
############################################################################
shutting_down=0

cleanup() {
    [ "$shutting_down" -eq 1 ] && return
    shutting_down=1

    echo "Shutting down..."

    # Stop all services the mock is tracking
    for pidfile in /run/systemctl-mock/*.service.pid; do
        [ -f "$pidfile" ] || continue
        unit=$(basename "$pidfile" .pid)
        systemctl stop "$unit" 2>/dev/null || true
    done

    echo "Running node cleanup..."
    globus-connect-server node cleanup || true
}

trap cleanup TERM EXIT
trap '' HUP INT

############################################################################
# MONITOR
#
# Once a second, check that every tracked service's process is still alive.  If
# one has exited, say so and shut the rest down, so the container stops instead
# of running half a deployment.
############################################################################
echo "GCS container successfully deployed"

# 'service_died' is separate from 'shutting_down': cleanup() returns at once
# when shutting_down is set, so setting it here would skip the shutdown.
service_died=0
while [ "$shutting_down" -eq 0 ] && [ "$service_died" -eq 0 ]; do
    sleep 1

    for pidfile in /run/systemctl-mock/*.service.pid; do
        [ -f "$pidfile" ] || continue
        unit=$(basename "$pidfile" .pid)
        pid=$(cat "$pidfile")
        [ -n "$pid" ] || continue   # the mock was mid-write
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "Error: $unit (PID $pid) exited unexpectedly" >&2
            service_died=1
            break
        fi
    done
done

cleanup
# Exit 1 when a service died, so 'docker ps' and restart policies see a failure.
[ "$service_died" -eq 0 ] || exit 1
