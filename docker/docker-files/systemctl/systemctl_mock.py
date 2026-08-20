#!/usr/bin/env python3
"""
systemctl-mock — systemctl replacement for GCS Docker containers.

Implements the subset of systemctl needed to install, start, stop, and manage
GCS services in containers where systemd is unavailable.

Installed at /gcs-deploy/systemctl-mock with /bin/systemctl symlinked there.
State is stored in /run/systemctl-mock/ (ephemeral tmpfs in Docker).

Supported subcommands:
    start, stop, restart, try-restart, reload
    enable, disable, is-active, is-enabled, status
    daemon-reload
    check-capabilities      (called by the GCS entrypoint at startup)

Unit types handled:
    .service  — Type=simple/notify/exec, Type=forking, Type=oneshot
    .socket   — marked active; no fd-passing / socket activation
    .path     — background polling watcher; triggers a target .service on change
"""

import grp
import os
import pwd
import re
import shlex
import signal
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path


# ── Constants ─────────────────────────────────────────────────────────────────

STATE_DIR     = Path('/run/systemctl-mock')
UNIT_DIRS     = [
    Path('/etc/systemd/system'),
    Path('/run/systemd/system'),
    Path('/lib/systemd/system'),
    Path('/usr/lib/systemd/system'),
]
POLL_INTERVAL = 3       # seconds between path-watcher polls
STOP_TIMEOUT  = 10      # seconds to wait after SIGTERM before SIGKILL

# Linux capability bit positions (from linux/capability.h)
_CAP_SETGID = 6
_CAP_SETUID = 7
REQUIRED_CAPS = {
    _CAP_SETGID: ('CAP_SETGID', 'needed to start services with non-root group'),
    _CAP_SETUID: ('CAP_SETUID', 'needed to start services as non-root users'),
}

# Module-level quiet flag; set by _parse_args()
QUIET = False


# ── Logging helpers ───────────────────────────────────────────────────────────

def log(msg):
    if not QUIET:
        print(msg, flush=True)

def warn(msg):
    print(f'systemctl-mock: {msg}', file=sys.stderr, flush=True)

def die(msg, code=1):
    print(f'systemctl-mock: error: {msg}', file=sys.stderr, flush=True)
    sys.exit(code)


# ── Unit file parsing ─────────────────────────────────────────────────────────

def parse_unit_file(path):
    """
    Parse one systemd unit file into {section: {key: [values]}}.

    An empty assignment (e.g. ExecStart=) appends a None sentinel.  During
    merge_unit_data() these sentinels clear the receiving list, implementing
    systemd's drop-in "clear then replace" semantics:

        ExecStart=                  # clears previous ExecStart
        ExecStart=/new/command      # sets the new value
    """
    sections = defaultdict(lambda: defaultdict(list))
    section = None
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith('#') or line.startswith(';'):
                continue
            if line.startswith('['):
                section = line[1:line.index(']')]
                continue
            if section is None or '=' not in line:
                continue
            key, _, val = line.partition('=')
            key = key.strip()
            val = val.strip()
            sections[section][key].append(None if val == '' else val)
    return sections


def merge_unit_data(base, overlay):
    """
    Merge overlay into base (mutates base).

    A None sentinel in overlay[section][key] clears base[section][key] before
    the subsequent values are appended — this is systemd's drop-in semantics.
    """
    for section, keys in overlay.items():
        for key, values in keys.items():
            for val in values:
                if val is None:
                    base[section][key].clear()
                else:
                    base[section][key].append(val)


def load_unit(name):
    """
    Find and parse a unit file, then merge all applicable drop-ins.

    Base file search order: /etc/systemd/system takes priority over
    /lib/systemd/system and /usr/lib/systemd/system.

    Drop-in files (*.conf) are gathered from every <name>.d/ directory across
    all UNIT_DIRS, deduplicated by filename with /etc winning, then applied in
    alphabetical filename order.
    """
    merged = defaultdict(lambda: defaultdict(list))

    # Base file: first match wins (UNIT_DIRS is ordered highest→lowest priority)
    for d in UNIT_DIRS:
        path = d / name
        if path.exists():
            merge_unit_data(merged, parse_unit_file(path))
            break

    # Drop-ins: iterate in reverse priority so that higher-priority directories
    # overwrite lower-priority ones when filenames collide.
    dropin_files = {}   # basename → Path  (/etc wins: iterated last)
    for d in reversed(UNIT_DIRS):
        dropin_dir = d / (name + '.d')
        if dropin_dir.is_dir():
            for conf in dropin_dir.glob('*.conf'):
                dropin_files[conf.name] = conf

    for conf_name in sorted(dropin_files):
        merge_unit_data(merged, parse_unit_file(dropin_files[conf_name]))

    return merged


def unit_suffix(name):
    """Return 'service', 'socket', 'path', etc. from a unit name."""
    return name.rsplit('.', 1)[-1] if '.' in name else 'service'


def get_first(unit_data, section, key, default=None):
    """Return the first value for section/key, or default."""
    vals = unit_data.get(section, {}).get(key, [])
    return vals[0] if vals else default


def get_all(unit_data, section, key):
    """Return all values for section/key as a list."""
    return list(unit_data.get(section, {}).get(key, []))


# ── State management (/run/systemctl-mock/) ───────────────────────────────────

def _ensure_state_dir():
    STATE_DIR.mkdir(parents=True, exist_ok=True)


def _state(unit, suffix):
    """Return a Path for a per-unit state file."""
    return STATE_DIR / f'{unit}.{suffix}'


def write_pid(unit, pid):
    _ensure_state_dir()
    _state(unit, 'pid').write_text(str(pid))


def read_pid(unit):
    try:
        return int(_state(unit, 'pid').read_text().strip())
    except (FileNotFoundError, ValueError):
        return None


def clear_pid(unit):
    _state(unit, 'pid').unlink(missing_ok=True)


def mark_active_no_pid(unit):
    """Mark a unit active without a tracked process (e.g. socket units)."""
    _ensure_state_dir()
    _state(unit, 'active').touch()


def clear_active_no_pid(unit):
    _state(unit, 'active').unlink(missing_ok=True)


def mark_enabled(unit):
    _ensure_state_dir()
    _state(unit, 'enabled').touch()


def mark_disabled(unit):
    _state(unit, 'enabled').unlink(missing_ok=True)


def is_enabled_unit(unit):
    return _state(unit, 'enabled').exists()


def pid_alive(pid):
    """Return True if a process with this PID exists."""
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def is_active_unit(unit):
    """Return True if the unit has a live PID or an active marker."""
    pid = read_pid(unit)
    if pid is not None:
        return pid_alive(pid)
    return _state(unit, 'active').exists()


# ── Conditions ────────────────────────────────────────────────────────────────

def check_conditions(unit_data):
    """
    Return True if all ConditionPathExists= conditions are satisfied.

    A leading '!' negates the condition (path must NOT exist).
    Unsatisfied conditions are normal — the unit simply does not start.
    """
    for spec in get_all(unit_data, 'Unit', 'ConditionPathExists'):
        negate = spec.startswith('!')
        path = spec.lstrip('!').strip()
        exists = Path(path).exists()
        if negate and exists:
            return False
        if not negate and not exists:
            return False
    return True


# ── Process helpers ───────────────────────────────────────────────────────────

def _resolve_uid_gid(unit_data):
    """Return (uid, gid) from User=/Group= directives, or (None, None)."""
    user  = get_first(unit_data, 'Service', 'User')
    group = get_first(unit_data, 'Service', 'Group')
    uid = gid = None
    if user:
        try:
            pw = pwd.getpwnam(user)
            uid, gid = pw.pw_uid, pw.pw_gid
        except KeyError:
            die(f'User={user!r} not found in /etc/passwd')
    if group:
        try:
            gid = grp.getgrnam(group).gr_gid
        except KeyError:
            die(f'Group={group!r} not found in /etc/group')
    return uid, gid


def _make_preexec(uid, gid):
    """Return a preexec_fn that drops privileges to (uid, gid)."""
    def preexec():
        if gid is not None:
            os.setgid(gid)
        if uid is not None:
            os.setuid(uid)
    return preexec


def _build_env(unit_data):
    """
    Build the environment for a service process.

    Starts from os.environ, then applies Environment= entries, then
    EnvironmentFile= entries in order.  A leading '-' on EnvironmentFile=
    makes the file optional (skip silently if missing).
    """
    env = os.environ.copy()

    for entry in get_all(unit_data, 'Service', 'Environment'):
        entry = entry.strip('"\'')
        k, _, v = entry.partition('=')
        env[k.strip()] = v

    for spec in get_all(unit_data, 'Service', 'EnvironmentFile'):
        optional = spec.startswith('-')
        fpath = spec.lstrip('-').strip()
        if optional and not Path(fpath).exists():
            continue
        try:
            with open(fpath) as f:
                for raw in f:
                    line = raw.strip()
                    if not line or line.startswith('#'):
                        continue
                    k, _, v = line.partition('=')
                    env[k.strip()] = v.strip().strip('"\'')
        except FileNotFoundError:
            if not optional:
                die(f'EnvironmentFile={fpath} not found')

    return env


def _expand_vars(s, extra=None):
    """
    Expand $VAR and ${VAR} using os.environ merged with extra.
    Unknown variables are left unexpanded (matching shell behaviour).
    """
    mapping = {**os.environ, **(extra or {})}
    def replace(m):
        name = m.group(1) or m.group(2)
        return mapping.get(name, m.group(0))
    return re.sub(r'\$\{(\w+)\}|\$(\w+)', replace, s)


def run_exec(cmdline, unit_data, extra_vars=None, wait=False):
    """
    Parse and run one ExecStart / ExecStartPre / ExecStop / etc. line.

    A leading '-' means ignore a non-zero exit code (systemd convention).
    Returns the Popen object; returns None when wait=True (process has exited).
    """
    # Strip leading modifiers (order matters: '-' before '+' to handle '+-...')
    ignore_error = cmdline.startswith('-')
    if ignore_error:
        cmdline = cmdline[1:].strip()

    # '+' prefix: run with root privileges regardless of User=/Group=.
    # Used in ExecStartPre for setup steps (mkdir, chown) that need root.
    run_as_root = cmdline.startswith('+')
    if run_as_root:
        cmdline = cmdline[1:].strip()

    cmdline = _expand_vars(cmdline, extra_vars)
    args = shlex.split(cmdline)
    if not args:
        return None

    uid, gid = (None, None) if run_as_root else _resolve_uid_gid(unit_data)
    preexec = _make_preexec(uid, gid) if (uid is not None or gid is not None) else None
    cwd     = get_first(unit_data, 'Service', 'WorkingDirectory')
    env     = _build_env(unit_data)

    proc = subprocess.Popen(args, cwd=cwd, env=env, preexec_fn=preexec)

    if wait:
        proc.wait()
        if proc.returncode != 0 and not ignore_error:
            die(f'Command failed (exit {proc.returncode}): {" ".join(args)}')
        return None

    return proc


# ── ExecStartPre / ExecStartPost helpers ─────────────────────────────────────

def _run_pre_exec(unit_data):
    for cmd in get_all(unit_data, 'Service', 'ExecStartPre'):
        run_exec(cmd, unit_data, wait=True)


def _run_post_exec(unit_data, main_pid):
    extra = {'MAINPID': str(main_pid)}
    for cmd in get_all(unit_data, 'Service', 'ExecStartPost'):
        run_exec(cmd, unit_data, extra_vars=extra, wait=True)


# ── Service type start handlers ───────────────────────────────────────────────

def start_simple(unit, unit_data):
    """
    Type=simple / notify / exec.

    Start the process and track its PID directly.  Type=notify is treated as
    simple: we do not implement the sd_notify protocol.
    """
    _run_pre_exec(unit_data)
    cmd = get_first(unit_data, 'Service', 'ExecStart')
    if not cmd:
        die(f'{unit}: no ExecStart defined')
    proc = run_exec(cmd, unit_data)
    write_pid(unit, proc.pid)
    _run_post_exec(unit_data, proc.pid)
    log(f'Started {unit}  (PID {proc.pid})')


def start_forking(unit, unit_data):
    """
    Type=forking.

    Start the process, wait for PIDFile= to appear (the daemon has forked and
    written its PID), then reap the original process.
    """
    _run_pre_exec(unit_data)
    cmd = get_first(unit_data, 'Service', 'ExecStart')
    if not cmd:
        die(f'{unit}: no ExecStart defined')
    orig = run_exec(cmd, unit_data)

    pid_file = get_first(unit_data, 'Service', 'PIDFile')
    if pid_file:
        deadline = time.monotonic() + 30
        while not Path(pid_file).exists():
            if time.monotonic() > deadline:
                die(f'{unit}: timed out waiting for PIDFile {pid_file}')
            time.sleep(0.5)
        pid = int(Path(pid_file).read_text().strip())
        write_pid(unit, pid)
        orig.wait()     # reap the original process now that it has forked
    else:
        write_pid(unit, orig.pid)

    _run_post_exec(unit_data, read_pid(unit) or 0)
    log(f'Started {unit}  (PID {read_pid(unit)})')


def start_oneshot(unit, unit_data):
    """
    Type=oneshot.

    Run all ExecStart= commands sequentially and wait for each to exit.
    Oneshot services have no ongoing process after completion.
    """
    _run_pre_exec(unit_data)
    for cmd in get_all(unit_data, 'Service', 'ExecStart'):
        run_exec(cmd, unit_data, wait=True)
    log(f'Completed {unit}')


def start_socket_unit(unit, unit_data):
    """
    .socket units.

    No fd-passing or socket activation.  Mark the unit active so that
    is-active queries return the expected result.
    """
    mark_active_no_pid(unit)
    log(f'Started (mock) {unit}')


def start_path_watcher(unit, unit_data):
    """
    .path units.

    Spawn a detached background process that polls the watched path.  The
    watcher outlives this systemctl invocation.  It appears in ps(1) as:

        python3 /bin/systemctl __watch-path <unit> <path> <target>

    making its purpose immediately visible to admins.
    """
    watch_path = (get_first(unit_data, 'Path', 'PathChanged') or
                  get_first(unit_data, 'Path', 'PathModified') or
                  get_first(unit_data, 'Path', 'PathExists'))
    target = (get_first(unit_data, 'Path', 'Unit') or
              unit.removesuffix('.path') + '.service')

    if not watch_path:
        die(f'{unit}: no PathChanged or PathExists defined')

    proc = subprocess.Popen(
        [sys.executable, sys.argv[0], '__watch-path', unit, watch_path, target],
        stdin=subprocess.DEVNULL,
        start_new_session=True,     # detach: survives parent exit
    )
    write_pid(unit, proc.pid)
    log(f'Started path watcher for {unit}  (PID {proc.pid})')

    # If the watched path already exists, trigger the target immediately
    if Path(watch_path).exists():
        log(f'{unit}: {watch_path} already present — starting {target}')
        subprocess.run([sys.argv[0], 'start', target], check=False)


# ── Internal: path watcher loop ───────────────────────────────────────────────

def _cmd_watch_path(unit, watch_path, target_unit):
    """
    Internal subcommand: __watch-path <unit> <watch_path> <target_unit>

    Polls watch_path every POLL_INTERVAL seconds.  When the file appears or
    its mtime changes, calls 'systemctl start <target_unit>'.  Exits cleanly
    on SIGTERM (which systemctl stop sends when stopping the .path unit).
    """
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    try:
        last_mtime = Path(watch_path).stat().st_mtime if Path(watch_path).exists() else None
    except OSError:
        last_mtime = None

    while True:
        time.sleep(POLL_INTERVAL)
        try:
            mtime = Path(watch_path).stat().st_mtime if Path(watch_path).exists() else None
        except OSError:
            mtime = None

        if mtime is not None and mtime != last_mtime:
            last_mtime = mtime
            warn(f'[{unit}] {watch_path} changed — starting {target_unit}')
            subprocess.run([sys.argv[0], 'start', target_unit], check=False)


# ── Start dispatcher ──────────────────────────────────────────────────────────

def _start_unit(unit):
    unit_data = load_unit(unit)

    if not check_conditions(unit_data):
        log(f'Skipping {unit}: condition not met')
        return                      # exit 0; unsatisfied condition is normal

    if is_active_unit(unit):
        log(f'{unit} is already active')
        return

    log(f'Starting {unit}...')

    suffix = unit_suffix(unit)
    if suffix == 'socket':
        start_socket_unit(unit, unit_data)
        return
    if suffix == 'path':
        start_path_watcher(unit, unit_data)
        return

    svc_type = get_first(unit_data, 'Service', 'Type', 'simple').lower()
    if svc_type in ('simple', 'notify', 'exec'):
        start_simple(unit, unit_data)
    elif svc_type == 'forking':
        start_forking(unit, unit_data)
    elif svc_type == 'oneshot':
        start_oneshot(unit, unit_data)
    else:
        die(f'{unit}: unsupported Type={svc_type}')


# ── Stop ──────────────────────────────────────────────────────────────────────

def _stop_unit(unit):
    suffix = unit_suffix(unit)

    if suffix == 'socket':
        clear_active_no_pid(unit)
        log(f'Stopped (mock) {unit}')
        return

    pid = read_pid(unit)
    if pid is None or not pid_alive(pid):
        clear_pid(unit)
        return                      # already stopped; not an error

    log(f'Stopping {unit}  (PID {pid})...')

    unit_data = load_unit(unit)
    exec_stop = get_first(unit_data, 'Service', 'ExecStop')
    if exec_stop:
        run_exec(exec_stop, unit_data, extra_vars={'MAINPID': str(pid)}, wait=True)
    else:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + STOP_TIMEOUT
        while pid_alive(pid) and time.monotonic() < deadline:
            time.sleep(0.5)
        if pid_alive(pid):
            warn(f'{unit}: did not exit after SIGTERM — sending SIGKILL')
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    clear_pid(unit)
    log(f'Stopped {unit}')


# ── Commands ──────────────────────────────────────────────────────────────────

def cmd_start(units):
    for u in units:
        _start_unit(u)


def cmd_stop(units):
    for u in units:
        _stop_unit(u)


def cmd_restart(units):
    for u in units:
        _stop_unit(u)
        _start_unit(u)


def cmd_try_restart(units):
    """Restart only if the unit is currently active."""
    for u in units:
        if is_active_unit(u):
            _stop_unit(u)
            _start_unit(u)


def cmd_reload(units):
    """Send ExecReload= command, or SIGHUP if none is defined."""
    for u in units:
        pid = read_pid(u)
        if pid is None or not pid_alive(pid):
            warn(f'{u}: not active, cannot reload')
            continue
        unit_data = load_unit(u)
        exec_reload = get_first(unit_data, 'Service', 'ExecReload')
        if exec_reload:
            run_exec(exec_reload, unit_data, extra_vars={'MAINPID': str(pid)}, wait=True)
        else:
            try:
                os.kill(pid, signal.SIGHUP)
            except ProcessLookupError:
                warn(f'{u}: process {pid} not found for reload')


def cmd_enable(units):
    for u in units:
        mark_enabled(u)
        log(f'Enabled {u}')


def cmd_disable(units):
    for u in units:
        mark_disabled(u)
        log(f'Disabled {u}')


def cmd_is_active(units):
    """Exit 0 if all given units are active, 3 otherwise (mirrors systemctl)."""
    results = [is_active_unit(u) for u in units]
    if not QUIET:
        for active in results:
            print('active' if active else 'inactive')
    sys.exit(0 if all(results) else 3)


def cmd_is_enabled(units):
    """Exit 0 if all given units are enabled, 1 otherwise."""
    results = [is_enabled_unit(u) for u in units]
    if not QUIET:
        for enabled in results:
            print('enabled' if enabled else 'disabled')
    sys.exit(0 if all(results) else 1)


def cmd_status(units):
    """Print a brief status block for each unit."""
    all_active = True
    for u in units:
        active   = is_active_unit(u)
        pid      = read_pid(u)
        unit_data = load_unit(u)
        desc     = get_first(unit_data, 'Unit', 'Description', u)
        state    = 'active (running)' if active else 'inactive (dead)'
        lines    = [
            f'● {u} [systemctl-mock]',
            f'   Description: {desc}',
            f'   Active:      {state}',
        ]
        if pid:
            lines.append(f'   Main PID:    {pid}')
        print('\n'.join(lines))
        if not active:
            all_active = False
    sys.exit(0 if all_active else 3)


def cmd_daemon_reload():
    """No-op: unit files are re-read on every invocation."""
    log('daemon-reload: no-op (systemctl-mock)')


def cmd_check_capabilities():
    """
    Verify that required Linux capabilities are present.

    Called by the GCS entrypoint before doing anything else, so that a missing
    capability produces a clear, actionable message rather than an obscure
    permission error deep in service startup.
    """
    try:
        cap_eff = 0
        with open('/proc/self/status') as f:
            for line in f:
                if line.startswith('CapEff:'):
                    cap_eff = int(line.split()[1], 16)
                    break
    except OSError as e:
        die(f'Cannot read /proc/self/status: {e}')

    missing = [(name, desc)
               for bit, (name, desc) in REQUIRED_CAPS.items()
               if not (cap_eff >> bit & 1)]

    if not missing:
        return      # all required capabilities present

    print('Container is missing required capabilities:', file=sys.stderr)
    for name, desc in missing:
        print(f'  {name:<16} — {desc}', file=sys.stderr)
    print(file=sys.stderr)
    flags = ' '.join(f'--cap-add={name}' for name, _ in missing)
    print(f'Relaunch with:  docker run {flags} ...', file=sys.stderr)
    sys.exit(1)


# ── Argument parsing + dispatch ───────────────────────────────────────────────

def _parse_args(argv):
    """
    Extract flags and return positional arguments [command, unit, ...].

    Unknown flags (e.g. --system, --no-pager) are silently ignored so that
    GCS scripts that pass extra flags do not break.
    """
    global QUIET
    positional = []
    for a in argv:
        if a in ('-q', '--quiet'):
            QUIET = True
        elif a.startswith('-'):
            pass    # silently ignore unrecognised flags
        else:
            positional.append(a)
    return positional


def main():
    args = _parse_args(sys.argv[1:])

    if not args:
        # Called with flags only (e.g. `systemctl --version` or `systemctl --system`
        # by invoke-rc.d probing for systemd).  Exit 0 so callers treat us as present
        # but do nothing — same policy as unknown subcommands.
        sys.exit(0)

    command, units = args[0], args[1:]

    # Internal subcommand: spawned by start_path_watcher()
    if command == '__watch-path':
        if len(units) != 3:
            die('__watch-path requires exactly 3 arguments')
        _cmd_watch_path(*units)
        return

    COMMANDS = {
        'daemon-reload':      lambda: cmd_daemon_reload(),
        'check-capabilities': lambda: cmd_check_capabilities(),
        'start':              lambda: cmd_start(units),
        'stop':               lambda: cmd_stop(units),
        'restart':            lambda: cmd_restart(units),
        'try-restart':        lambda: cmd_try_restart(units),
        'reload':             lambda: cmd_reload(units),
        'enable':             lambda: cmd_enable(units),
        'disable':            lambda: cmd_disable(units),
        'is-active':          lambda: cmd_is_active(units),
        'is-enabled':         lambda: cmd_is_enabled(units),
        'status':             lambda: cmd_status(units),
    }

    if command not in COMMANDS:
        # Unknown commands exit 0 — avoids breaking GCS scripts that call
        # systemctl subcommands we have not implemented.
        warn(f'unknown command {command!r} — ignoring')
        sys.exit(0)

    COMMANDS[command]()


if __name__ == '__main__':
    main()
