#!/bin/bash
#
# GCS container entrypoint.
#
# Validates the environment, runs 'globus-connect-server node setup' (which
# starts all GCS services via the systemctl mock), then monitors those services
# until the container receives SIGTERM.
#
# Required environment variables:
#   DEPLOYMENT_KEY        — JSON content of the endpoint deployment key
#
# Optional environment variables:
#   NODE_SETUP_ARGS       — extra arguments passed to 'node setup'
#   GLOBUS_SDK_ENVIRONMENT — target a non-production Globus environment

# ── Capability check ──────────────────────────────────────────────────────────
#
# Verify that the container has the Linux capabilities the systemctl mock
# requires to drop privileges when starting services.  This runs first so that
# a missing capability produces a clear message rather than an obscure
# permission error buried in service startup output.

systemctl check-capabilities || exit 1

# ── Required environment variables ───────────────────────────────────────────

if [ -z "${DEPLOYMENT_KEY}" ]; then
    echo "Error: required environment variable DEPLOYMENT_KEY is not set" >&2
    exit 1
fi

# ── Deployment key ────────────────────────────────────────────────────────────
#
# node setup expects the deployment key in a file.  Write the env var content
# to a temporary location and restrict access to root only.

deployment_key=/run/deployment-key.json
echo "$DEPLOYMENT_KEY" > "$deployment_key"
chmod 600 "$deployment_key"

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
