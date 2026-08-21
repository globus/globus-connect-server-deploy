#!/bin/bash
#
# GCS test container entrypoint.
#
# Starts a container with the systemctl mock in place but without running
# GCS node setup.  Use 'docker exec -it <container> bash' to connect and
# install / configure GCS interactively.
#
# This entrypoint is intentional — it is not a fallback for a misconfigured
# production container.  To run a production GCS container use entrypoint.sh.

echo "GCS test container ready."
echo "Connect with:  docker exec -it $(hostname) bash"

exec sleep infinity
