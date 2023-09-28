#!/bin/bash

###############################################################################
# WARNING: Launching GCS without systemd is experimental. Use at your own risk.
# Compatible with GCS 5.4.21+
###############################################################################

#
# The parameters we need to launch 'node setup' are passed in via environment
# variables.
#

# $GLOBUS_CLIENT_ID = <client_id>
# $GLOBUS_CLIENT_SECRET = <client_secret>
# $DEPLOYMENT_KEY = <endpoint_deployment_key>
# $NODE_SETUP_ARGS = optional args for 'node setup' (ex. --ip-address)
# $GLOBUS_SDK_ENVIRONMENT = optional development environment

if [ -z "$GLOBUS_CLIENT_ID" ]
then
    echo "Missing environment variable 'GLOBUS_CLIENT_ID'. Exitting."
    exit 1
fi

if [ -z "$GLOBUS_CLIENT_SECRET" ]
then
    echo "Missing environment variable 'GLOBUS_CLIENT_SECRET'. Exitting."
    exit 1
fi

if [ -z "$DEPLOYMENT_KEY" ]
then
    echo "Missing environment variable 'DEPLOYMENT_KEY'. Exitting."
    exit 1
fi

###############################################################################
# STEP 1: Configure the node for Globus by running 'node setup'
###############################################################################

#
# Normally, 'globus-connect-server node setup' will pull down the node's Globus
# configuration and launch all necessary local services. However, since we are
# working around the use of systemd in order to have an unprivileged container,
# we have to handle these steps ourselves.
#

# GCS will check for the existence of this file to make sure this is
# a supported platform. Make it a fake so that we can handle service
# launch ourselves.
rm -f /bin/systemctl
ln -s /bin/true /bin/systemctl

# Put our deployment key into a file where 'node setup' can reach it
deployment_key="/deployment-key.json"
echo $DEPLOYMENT_KEY > $deployment_key
chmod 600 $deployment_key

globus-connect-server node setup     \
    --deployment-key $deployment_key \
    $NODE_SETUP_ARGS

if [ $? -ne 0 ]
then
    echo "node setup failed. Exiting."
    exit 1
fi

###############################################################################
# STEP 2: Launch and monitor services in lieu of systemd
###############################################################################

###
### Launch GCS Manager
###
echo 'Launching GCS Manager'

#
# This is the API process that allows you to administer the endpoint
# configuration as well as authorizing users that are accessing your endpoint
# using the Transfer service.
#

# systemd executes gcs_manager.socket and creates /run/gcs_manager.sock on our
# behalf. It is used for communication between apache/httpd and the GCS Manager.
# /run/ is not writable by gcsweb though so it can not create the socket itself.
# Therefore, we move the socket (and pid file) to a sub directory and give GCSM
# write access. Then we create a symlink between the old and new locations so
# that apache/httpd can still find the socket.

mkdir /run/gcs_manager
chown gcsweb:gcsweb /run/gcs_manager
ln -s /run/gcs_manager/sock /run/gcs_manager.sock

# Launch the service. See /lib/systemd/system/gcs_manager.service
(
    cd /opt/globus/share/web;
    sudo -u gcsweb -g gcsweb /opt/globus/bin/gunicorn \
        --workers 4                                   \
	--preload api_app                             \
	--daemon                                      \
	--bind=unix:/run/gcs_manager/sock             \
	--pid /run/gcs_manager/pid
)

# Wait for the pid file which signals successful launch
while [ ! -f /run/gcs_manager/pid ]
do
    sleep 0.5
done
gcs_manager_pid=`cat /run/gcs_manager/pid`

# Now change ownership of the socket so that apache can use it.
# See /lib/systemd/system/gcs_manager.socket
chmod 600 /var/run/gcs_manager/sock
if [ -f /usr/sbin/apache2 ]
then
    # Debian/Ubuntu variants.
    chown www-data:www-data /var/run/gcs_manager/sock
else
    # Redhat/CentOS/Fedora variants.
    chown apache:apache /var/run/gcs_manager/sock
fi

###
### Launch GCS Assistant
###
echo 'Launching GCS Assistant'

# This process syncs Globus configuration between nodes. It will send log
# messages to stdout which are usually caught by systemd and sent onto 
# syslog. Instead, you'll see these log messages with 'docker logs'.
sudo -u gcsweb -g gcsweb /opt/globus/bin/globus-connect-server assistant &
gcs_manager_assistant_pid=$!


###
### Launch Apache httpd
###
echo 'Launching Apache httpd'

if [ -f /usr/sbin/apache2 ]
then
    # Debian/Ubuntu variants. It is safe to use apachectl
    /usr/sbin/apachectl start
    pidfile=/var/run/apache2/apache2.pid
else
    # Redhat/CentOS/Fedora variants
    if [ ! -f /etc/pki/tls/certs/localhost.crt ]
    then
        # CentOS 8 would have called this through systemctl
        /usr/libexec/httpd-ssl-gencerts
    fi
    # apachectl uses systemctl
    /usr/sbin/httpd
    pidfile=/var/run/httpd/httpd.pid
fi

while [ ! -f $pidfile ]
do
    sleep 0.5
done
httpd_pid=`cat $pidfile`

###
### Launch GridFTP
###
echo 'Launching GridFTP Server'
sudo -u gcsweb -g gcsweb touch /var/lib/globus-connect-server/gcs-manager/gridftp-key
/usr/sbin/globus-gridftp-server \
    -S \
    -c /etc/gridftp.conf \
    -C /etc/gridftp.d \
    -pidfile /run/globus-gridftp-server.pid

while [ ! -f /run/globus-gridftp-server.pid ]
do
    sleep 0.5
done
gridftp_pid=`cat /run/globus-gridftp-server.pid`


###############################################################################
# There is currently no support for OIDC without systemd.
###############################################################################

function is_process_alive()
{
    kill -0 $1 > /dev/null 2>&1
}

function check_process()
{
    # $1 - Name
    # $2 - PID

    is_process_alive $2
    if [ $? -ne 0 ]
    then
        echo "$1 exitted unexpectedly"
        return 1
    fi
    return 0
}

shutting_down=0
function cleanup()
{
    echo "Shutting down..."
    shutting_down=1
    trap - TERM
    trap - EXIT

    shutdown_gcs_manager=0
    is_process_alive $gcs_manager_pid && shutdown_gcs_manager=1
    if [ $shutdown_gcs_manager -eq 1 ]
    then
        echo "Terminating GCS Manager (pid $gcs_manager_pid)"
        kill -TERM $gcs_manager_pid

        first_pass=1
        while :
        do
            is_process_alive $gcs_manager_pid && break
	    (($first_pass)) && echo "Waiting on GCS Manager to exit"
	    first_pass=0
        done
        echo "GCS Manager has exitted"
    fi

    ###########################################################################
    # We do not wait for GridFTP transfers to complete.
    ###########################################################################

    echo "Running node cleanup ..."
    globus-connect-server node cleanup
}

trap cleanup TERM
trap cleanup EXIT
trap '' HUP
trap '' INT

echo "GCS container successfully deployed"
while [ $shutting_down -eq 0 ]
do
    check_process "Apache httpd" $httpd_pid || shutting_down=1
    check_process "GCS Manager" $gcs_manager_pid || shutting_down=1
    check_process "GCS Manager Assistant" $gcs_manager_assistant_pid || shutting_down=1

    if [ $shutting_down -eq 1 ]
    then
        cleanup
    else
        sleep 1
    fi
done
