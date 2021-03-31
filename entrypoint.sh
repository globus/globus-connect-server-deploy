#!/bin/bash

# $GLOBUS_CLIENT_ID = <client_id>
# $GLOBUS_CLIENT_SECRET = <client_secret>
# $DEPLOYMENT_KEY = <endpoint_deployment_key>

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

deployment_key="/deployment-key.json"
echo $DEPLOYMENT_KEY > $deployment_key
chmod 600 $deployment_key

if [ ! -e /systemctl ]
then
    ln -s /bin/true /systemctl
fi

PATH=/:$PATH globus-connect-server node setup --client-id $GLOBUS_CLIENT_ID --deployment-key $deployment_key $NODE_SETUP_ARGS
if [ $? -ne 0 ]
then
    echo "node setup failed. Exiting."
    exit 1
fi

#
# Launch Services
#
echo 'Launching Apache httpd'
/usr/sbin/apachectl start

while [ ! -f /var/run/apache2/apache2.pid ]
do
    sleep 0.5
done
apache_httpd_pid=`cat /var/run/apache2/apache2.pid`


echo 'Launching GCS Manager'
/var/lib/globus-connect-server/gcs-manager/etc/httpd/mod-wsgi.d/apachectl start

while [ ! -f /var/lib/globus-connect-server/gcs-manager/etc/httpd/mod-wsgi.d/httpd.pid ]
do
    sleep 0.5
done
gcs_manager_pid=`cat /var/lib/globus-connect-server/gcs-manager/etc/httpd/mod-wsgi.d/httpd.pid`

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


echo 'Launching GCS Assistant'
sudo -u gcsweb -g gcsweb /opt/globus/bin/globus-connect-server assistant &

function wait_on_pid()
{
    while :
    do
        kill -0 $1 > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            break
        fi
    done
}

function wait_on_process()
{
    while :
    do
        killall -0 $1 > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            break
        fi
    done
}

shutting_down=0
function cleanup()
{
    echo "Shutting down..."
    shutting_down=1
    trap - TERM
    trap - EXIT

    echo 'Terminating Apache httpd'
    /usr/sbin/apachectl stop

    echo 'Terminating GCS Manager'
    /var/lib/globus-connect-server/gcs-manager/etc/httpd/mod-wsgi.d/apachectl stop

    echo 'Terminating GCS Assistant'
    killall -TERM 'globus-connect-server assistant'

    echo Waiting on GCS Assistant
    wait_on_process 'globus-connect-server assistant'

    echo Waiting on GCS Manager
    wait_on_pid $gcs_manager_pid

    echo "Running node cleanup ..."
    PATH=/:$PATH globus-connect-server node cleanup
}

trap cleanup TERM
trap cleanup EXIT
trap '' HUP
trap '' INT

echo "GCS container successfully deployed"
while [ $shutting_down -eq 0 ]
do
    wait
done
