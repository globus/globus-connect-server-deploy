#!/opt/globus/bin/python

import contextlib
import subprocess
import signal
import atexit
import time
import grp
import pwd
import os
from functools import partial
from enum import Enum


# SIGTERM is sent by 'docker stop' followed by SIGKILL after
# a grace period. On SIGTERM, we need to initiate shutdown
# on all child processes before SIGKILL arrives.

# 'docker kill' can send arbitrary signals that we can use
# to define custom behavior. We can choose to pass the signal
# through to one or more child processes or we can define a
# custom action.

# We are responsible for reaping all child proceses to avoid
# having defunct child processes. It seems that:
#  1) subprocess.run() will not create defunct processes
#  2) subprocess.Popen() will create defunct processes but
#     cleans them up on communicate().
#
# So the only zombie process concern we appear to have is cleaning up
# grandchildren that our child didn't clean up for whatever reason.
# This does not seem to be a big concern.

# We launch our child processes and record their process IDs. Then
# we watch for SIGCHLD and reap zombies. If any of our monitored
# children exists, we begin the shutdown process.

# We do not capture stdout/stderr, we allow that to flow up to
# docker so that users can attach to view output.


#
# Use signal handlers for catching signals we receive while we
# are not expliciting in sigwaitinfo()
#


## ps xao pid,ppid,pgid,sid

@contextlib.contextmanager
def change_effective_identity(uid, gid):
    """
    Temporarily change the processes effective uid and/or gid
    """
    # Probably safe to assume we are root
    eff_uid = os.geteuid()
    eff_gid = os.getegid()

    # Change effective IDs
    if gid is not None:
        os.setegid(gid)
    if uid is not None:
        os.seteuid(uid)

    yield

    # Revert effective IDs
    if uid is not None:
        os.seteuid(eff_uid)
    if gid is not None:
        os.setegid(eff_gid)

class ServiceException(Exception):
    pass

class Service():
    """
    Class for managing services.
    """
    class Status(Enum):
        STOPPED = 1
        RUNNING = 2
        STOPPING = 3

    def __init__(
        self,
        name,
        start_cmd,
        stop_cmd,
        detaches=True,
        pidfile=None,
        user=None,
        group=None 
    ):
        """
        start_cmd: ['cmd.exe', 'arg1']
        stop_cmd: ['cmd.exe', 'arg1'] or signal
        user, group: only used on Start()
        """
        assert not detaches or pidfile

        self._name = name
        self._start_cmd = start_cmd
        self._detaches = detaches
        self._stop_cmd = stop_cmd
        self._pidfile = pidfile
        self._uid = None
        self._gid = None
        self._pid = None
        self._status = self.Status.STOPPED

        if user:
            try:
                self._uid = pwd.getpwnam(user).pw_uid
            except KeyError:
                raise ServiceException(f'Failed to launch the {name} process, user {user} is unknown.')

        if group:
            try:
                self._gid = grp.getgrnam(group).gr_gid
            except KeyError:
                raise ServiceException(f'Failed to launch the {name} process, group {group} is unknown.')

    def Start(self):
        with change_effective_identity(self._uid, self._gid):
            if self._detaches:
                self._pid = self._start_detached()
            else:
                self._popen = self._start_attached()
                self._pid = self._popen.pid
        self._status = self.Status.RUNNING

    def Stop(self):
        if self._status == self.Status.RUNNING:
            if isinstance(self._stop_cmd, signal.Signals):
                self._stop_with_signal()
                if hasattr(self, '_popen'):
                    self._popen.communicate()
            else:
                self._stop_with_cmd()
            self._status = self.Status.STOPPING

    @property
    def name(self):
        return self._name

    @property
    def pid(self):
        return self._pid

    @property
    def status(self):
        print (f'checking status on {self._name} ({self._status.name}, {self._pid})')
        if self._status != self.Status.STOPPED:
            try:
                os.kill(self._pid, 0)
            except ProcessLookupError:
                print ('Lookup failed')
                self._status = self.Status.STOPPED
        return self._status

    def _start_detached(self):
        subprocess.run(self._start_cmd)

        # Get the pid. Wait for the file to exist.
        wait_interval = 0.1
        wait_count = 30

        while not os.path.exists(self._pidfile) and wait_count > 0:
            time.sleep(wait_interval)

        with open(self._pidfile, 'r') as f:
            return int(f.read().strip('\n'))

    def _start_attached(self):
        return subprocess.Popen(self._start_cmd)

    def _stop_with_signal(self):
        try:
            os.kill(self._pid, self._stop_cmd)
        except ProcessLookupError:
            pass

    def _stop_with_cmd(self):
        subprocess.run(self._stop_cmd)


services = [
    Service(
        'Apache httpd',
        ['/usr/sbin/apachectl', 'start'],
        ['/usr/sbin/apachectl', 'stop'],
        pidfile='/var/run/apache2/apache2.pid',
    ),
    Service(
        'GCS Manager',
        ['/var/lib/globus-connect-server/gcs-manager/etc/httpd/mod-wsgi.d/apachectl', 'start'],
        ['/var/lib/globus-connect-server/gcs-manager/etc/httpd/mod-wsgi.d/apachectl', 'stop'],
        pidfile='/var/lib/globus-connect-server/gcs-manager/etc/httpd/mod-wsgi.d/httpd.pid',
    ),
    Service(
        'GridFTP Server',
        [
            '/usr/sbin/globus-gridftp-server', 
            '-S', 
            '-c', '/etc/gridftp.conf', 
            '-C', '/etc/gridftp.d', 
            '-pidfile', '/run/globus-gridftp-server.pid',
        ],
        signal.SIGTERM,
        pidfile='/run/globus-gridftp-server.pid',
    ),
    Service(
        'GCS Assistant',
        ['/opt/globus/bin/globus-connect-server', 'assistant'],
        signal.SIGTERM,
        detaches=False,
        user='gcsweb',
        group='gcsweb',
    ),
]

for service in services:
    print (f'Starting {service.name} ...')
    service.Start()
    print ('DONE')

for service in services:
    print(f'{service.name}: {service.status.name}')

time.sleep(3)

for service in services:
    if service.status == Service.Status.RUNNING:
        print (f'Stopping {service.name} ...')
        service.Stop()

while True:
    running_services = [s for s in services if s.status != Service.Status.STOPPED]
    if not running_services:
        break
    time.sleep(0.2)

#for service in services:
#    print(f'Launching {service["name"]}')
#
#    with change_effective_identity(service.get('user', None), service.get('group', None)):
#        if service.get('pidfile', None):
#            completed_process = subprocess.run(service['start'])
#            if completed_process.returncode != 0:
#                print(f'Failed to the {service["name"]}')
#                break
#
#            # Get the pid. Wait for the file to exist.
#            wait_interval = 0.1
#            wait_count = 30
#
#            while not os.path.exists(service['pidfile']) and wait_count > 0:
#                time.sleep(wait_interval)
#
#            with open('/var/run/apache2/apache2.pid', 'r') as f:
#                service['pid'] = f.read().strip('\n')
#        else:
#            popen = subprocess.Popen(service["start"])
#            service['pid'] = popen.pid
#
#class ProcessState(Enum):
#    STOPPED = 1
#    RUNNING = 2
#
#def get_next_signal(signals_received):
#    if signals_received:
#        return (signals_received.pop(), None)
#
#    si = signal.sigwaitinfo([signal.SIGCHLD, signal.SIGTERM])
#    return (si.si_signo, si.si_pid)
#
#signals_received = []
#
## We can not know the caller from this context
#def signal_handler(signal_number, frame):
#    print(f'signal_handler({signal.Signals(signal_number).name})')
#    signals_received.append(signal_number)
#
#expected_signals = [signal.SIGTERM, signal.SIGCHLD]
#for s in expected_signals:
#    signal.signal(s, signal_handler)
#
#
#while True:
#    (signal_number, pid) = get_next_signal(signals_received)
#
#    if signal_number == signal.SIGTERM:
#        break
#
#    if signal_number == signal.SIGCHLD:
#        if 
#
#for service in services:
#    if service.state is ProcessState.Running:
#        service.stop()
#
#while active_services:
#
#process_list = [service['pid'] for service in services]
#
#state = starting_up
#Launch services unless we have a launch failure, get SIGTERM or run our of services to launch
#proceses go from 'stop' to 'running' to 'stopping' to 'stopped'
#
#state = shutting down
#At any point we get a sigchld for one of our immediate children, we get sigterm, or we fail to launch a service
#
#shutdown each process
#
#print (f'Watching process list: {process_list}')
#while process_list:
#    if signals_received:
#
#    si = signal.sigwaitinfo([signal.SIGCHLD, signal.SIGTERM])
#    print (f'Received signal {si.si_signo}')
#    if si.si_signo == signal.SIGTERM:
#        shutting_down = True
#        for p in process_list:
#  NO!       os.kill(p, signal.SIGTERM)
#    if si.si_signo == signal.SIGCHLD:
#        if si.si_pid in process_list:
#            process_list.remove(si.si_pid)
#            if not shutting_down:
#                for p in process_list:
#                    os.kill(p, signal.SIGTERM)
#                shutting_down = True
