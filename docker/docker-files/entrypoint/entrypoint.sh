#!/bin/bash
#
# GCS container entrypoint.
#
# Validates the environment, runs 'globus-connect-server node setup' (which
# starts all GCS services via the systemctl mock), then monitors those services
# until the container receives SIGTERM.
#
# Required — bind-mount the endpoint deployment key into the container:
#   docker run -v /path/to/deployment-key.json:/deployment-key.json:ro ...
#
# Optional environment variables:
#   NODE_SETUP_ARGS        — extra arguments passed to 'node setup'
#   GLOBUS_SDK_ENVIRONMENT — target a non-production Globus environment

# ── Capability check ──────────────────────────────────────────────────────────
#
# Verify that the container has the Linux capabilities the systemctl mock
# requires to drop privileges when starting services.  This runs first so that
# a missing capability produces a clear message rather than an obscure
# permission error buried in service startup output.

systemctl check-capabilities || exit 1

# ── Deployment key ────────────────────────────────────────────────────────────
#
# The deployment key must be bind-mounted into the container at a well-known
# path.  Using a bind mount rather than an environment variable keeps the key
# contents out of 'ps' output on the host.

deployment_key=/deployment-key.json

if [ ! -f "$deployment_key" ]; then
    echo "Error: deployment key not found at ${deployment_key}" >&2
    echo "       Mount it with: docker run -v /path/to/deployment-key.json:${deployment_key}:ro ..." >&2
    exit 1
fi

# ── Node setup ────────────────────────────────────────────────────────────────
#
# node setup configures this GCS node and starts all required services by
# calling 'systemctl enable' and 'systemctl start' — handled by the mock.

globus-connect-server node setup      \
    --deployment-key "$deployment_key" \
    ${NODE_SETUP_ARGS}

if [ $? -ne 0 ]; then
    echo "Error: node setup failed" >&2
    exit 1
fi

# ── Signal handling ───────────────────────────────────────────────────────────

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

# ── Monitor ───────────────────────────────────────────────────────────────────
#
# Poll all tracked service PIDs.  If any service exits unexpectedly, log it
# and trigger a graceful shutdown of the remaining services.

echo "GCS container successfully deployed"

while [ "$shutting_down" -eq 0 ]; do
    sleep 1

    for pidfile in /run/systemctl-mock/*.service.pid; do
        [ -f "$pidfile" ] || continue
        unit=$(basename "$pidfile" .pid)
        pid=$(cat "$pidfile")
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "Error: $unit (PID $pid) exited unexpectedly" >&2
            shutting_down=1
            break
        fi
    done
done

cleanup
