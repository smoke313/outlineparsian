#!/bin/bash
# =====================================================================
#  OutlineParsian Panel v3.8 - full installer / upgrader
#  Ubuntu 22.04+ / Debian 11+ , run as root
#
#  - Fresh install, OR upgrade of an existing /root/ssh-panel install.
#    Existing panel.db (users, inbounds, clients) is KEPT.
#  - Backup of the old install is taken first in /root/op-backup-<ts>
#
#  Usage:  bash op-panel-v3.8-install.sh
# =====================================================================
set -o pipefail

PANEL=/root/ssh-panel
TS=$(date +%s)
BK=/root/op-backup-$TS
SYNC=$PANEL/sync_xray.py

GREEN='\033[32m'; RED='\033[31m'; YEL='\033[33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YEL}!${NC} $*"; }
fail() { echo -e "${RED}✗ $*${NC}"; exit 1; }
step() { echo -e "\n== [$1] $2"; }

[ "$(id -u)" = "0" ] || fail "Run as root"

# ---------------------------------------------------------------------
step "1/9" "System packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
apt-get install -y python3 python3-pip nginx ipset iptables iptables-persistent \
  netfilter-persistent curl unzip sqlite3 iproute2 procps openssh-server \
  certbot python3-certbot-nginx >/dev/null 2>&1 || warn "some apt packages failed (continuing)"
pip3 install -q --break-system-packages flask psutil requests grpcio grpcio-tools protobuf qrcode pillow 2>/dev/null \
  || pip3 install -q flask psutil requests grpcio grpcio-tools protobuf qrcode pillow \
  || fail "pip install failed"
ok "packages installed"

# ---------------------------------------------------------------------
step "2/9" "SSH: allow password login (drop-in, main sshd_config untouched)"
mkdir -p /etc/ssh/sshd_config.d
# 00- prefix so it is read before cloud-init drop-ins (first value wins in sshd)
printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/00-op.conf
if sshd -t 2>/dev/null; then
  systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
  ok "sshd ready"
else
  warn "sshd config test failed, drop-in not applied"
fi

# ---------------------------------------------------------------------
step "3/9" "Backup and stop old services"
mkdir -p "$BK"
if [ -d "$PANEL" ]; then
  cp -a "$PANEL" "$BK/ssh-panel" 2>/dev/null
  [ -f "$PANEL/panel.db" ] && sqlite3 "$PANEL/panel.db" ".backup '$BK/panel.db'"
  ok "old install backed up to $BK"
fi
[ -f /usr/local/etc/xray/config.json ] && cp /usr/local/etc/xray/config.json "$BK/xray_config.json"

systemctl disable --now ssh-panel-worker ssh-panel-ip-manager 2>/dev/null
systemctl stop ssh-panel ssh-panel-collector 2>/dev/null
rm -f /etc/systemd/system/ssh-panel-worker.service /etc/systemd/system/ssh-panel-ip-manager.service
rm -f "$PANEL/traffic_worker.py" "$PANEL/ip_manager.py"

# Remove DROP rules left by the old per-IP limiter (it used -s <ip> -j DROP on INPUT)
iptables -S INPUT 2>/dev/null | grep -E -- '-s [^ ]+ -j DROP' | sed 's/^-A /-D /' | while read -r rule; do
  iptables $rule 2>/dev/null
done
rm -f /tmp/ip_manager_state.json /tmp/ssh_sessions.json /tmp/xray_log_pos.txt /tmp/xray_log_pos_ip.txt /tmp/xray_access.log
ok "old services and rules cleaned"

# ---------------------------------------------------------------------
step "4/9" "Xray core"
if [ ! -x /usr/local/bin/xray ]; then
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
    || fail "Xray install failed"
fi
[ -x /usr/local/bin/xray ] || fail "xray binary not found at /usr/local/bin/xray"
ok "Xray: $(/usr/local/bin/xray version 2>/dev/null | head -1)"

mkdir -p "$PANEL/templates" "$PANEL/grpc_proto" "$PANEL/downloads" /usr/local/etc/xray /var/log/xray
touch /tmp/xray_error.log /var/log/panel.log
chmod 666 /tmp/xray_error.log /var/log/panel.log

# gRPC stubs for Xray StatsService
cat > "$PANEL/grpc_proto/stats.proto" <<'EOF'
syntax = "proto3";
package xray.app.stats.command;
message QueryStatsRequest { string pattern = 1; bool reset = 2; }
message Stat { string name = 1; int64 value = 2; }
message QueryStatsResponse { repeated Stat stat = 1; }
service StatsService { rpc QueryStats(QueryStatsRequest) returns (QueryStatsResponse); }
EOF
(cd "$PANEL/grpc_proto" && python3 -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. stats.proto) \
  || fail "protoc failed"
ok "gRPC stubs generated"

# ---------------------------------------------------------------------
step "5/9" "Database (keeps existing data, creates missing tables/settings)"
python3 - <<'PYDB' || fail "database init failed"
import sqlite3, subprocess, secrets, os
DB = '/root/ssh-panel/panel.db'
conn = sqlite3.connect(DB)
conn.execute('PRAGMA journal_mode=WAL')
conn.executescript('''
CREATE TABLE IF NOT EXISTS users (
  username TEXT PRIMARY KEY, password TEXT, expire_date TEXT, total_traffic REAL,
  used_traffic REAL DEFAULT 0.0, status INTEGER DEFAULT 1, max_connections INTEGER DEFAULT 2, created_at TEXT);
CREATE TABLE IF NOT EXISTS xray_inbounds (
  id INTEGER PRIMARY KEY AUTOINCREMENT, tag TEXT UNIQUE, protocol TEXT, port INTEGER,
  network TEXT DEFAULT 'tcp', security TEXT DEFAULT 'none', server_name TEXT DEFAULT '',
  fingerprint TEXT DEFAULT 'chrome', short_id TEXT DEFAULT '', public_key TEXT DEFAULT '',
  private_key TEXT DEFAULT '', path TEXT DEFAULT '/', status INTEGER DEFAULT 1, created_at TEXT);
CREATE TABLE IF NOT EXISTS xray_clients (
  id INTEGER PRIMARY KEY AUTOINCREMENT, inbound_id INTEGER, username TEXT, uuid TEXT, email TEXT,
  enable INTEGER DEFAULT 1, created_at TEXT,
  FOREIGN KEY (inbound_id) REFERENCES xray_inbounds(id) ON DELETE CASCADE,
  FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS user_groups (
  id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, description TEXT, created_at TEXT);
CREATE TABLE IF NOT EXISTS group_members (
  id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER, username TEXT,
  FOREIGN KEY (group_id) REFERENCES user_groups(id) ON DELETE CASCADE,
  FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
CREATE INDEX IF NOT EXISTS idx_clients_inbound ON xray_clients(inbound_id);
CREATE INDEX IF NOT EXISTS idx_clients_username ON xray_clients(username);
''')
c = conn.cursor()

def get(k):
    r = c.execute('SELECT value FROM settings WHERE key=?', (k,)).fetchone()
    return r[0] if r else None

def put(k, v):
    c.execute('INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)', (k, v))

for k, v in {'domain': '', 'panel_port': '5000', 'ssl_domain': '', 'block_iran': '0',
             'reality_public_key': '', 'reality_private_key': ''}.items():
    c.execute('INSERT OR IGNORE INTO settings(key,value) VALUES(?,?)', (k, v))

if get('admin_username') is None:
    put('admin_username', 'admin')
if get('admin_password') is None:
    pw = secrets.token_urlsafe(12)
    put('admin_password', pw)
    with open('/root/ssh-panel/admin.txt', 'w') as f:
        f.write(f'username: admin\npassword: {pw}\n')
    os.chmod('/root/ssh-panel/admin.txt', 0o600)
    print('  new admin password saved to /root/ssh-panel/admin.txt')

if not get('reality_private_key') or not get('reality_public_key'):
    out = subprocess.run(['/usr/local/bin/xray', 'x25519'], capture_output=True, text=True).stdout
    priv = pub = ''
    for line in out.splitlines():
        low = line.lower()
        if ':' not in line or 'hash32' in low:
            continue
        val = line.split(':', 1)[1].strip()
        if 'private' in low:
            priv = val
        elif 'public' in low or 'password' in low:
            pub = val
    if priv and pub:
        put('reality_private_key', priv)
        put('reality_public_key', pub)
        print('  reality keys generated')
    else:
        print('  WARNING: could not generate reality keys (xray x25519 failed)')

conn.commit()
conn.close()
print('  database ready')
PYDB
ok "database ready"

# ---------------------------------------------------------------------
step "6/9" "Writing panel files"

# ---------- sync_xray.py ----------
cat > "$SYNC" <<'EOF'
#!/usr/bin/env python3
# Builds Xray config from panel DB. Validates before applying, restarts only on change.
import sqlite3, json, os, subprocess, sys

DB_PATH = '/root/ssh-panel/panel.db'
XRAY_CONFIG = '/usr/local/etc/xray/config.json'
XRAY_TMP = XRAY_CONFIG + '.new'
XRAY_BIN = '/usr/local/bin/xray'

API_INBOUND = {"tag": "api", "listen": "127.0.0.1", "port": 10085,
               "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}}


def get_setting(c, key):
    row = c.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return row[0] if row and row[0] else ''


def make_client(proto, sec, uid, email):
    obj = {"password": uid, "email": email} if proto == 'trojan' else {"id": uid, "email": email}
    if proto == 'vmess':
        obj["alterId"] = 0
    if sec == 'reality' and proto in ('vless', 'trojan'):
        obj["flow"] = "xtls-rprx-vision"
    return obj


def make_inbound(ib, clients, default_priv, ssl_domain):
    proto = ib['protocol']
    sec = ib['security'] or 'none'
    net = ib['network'] or 'tcp'
    settings = {"clients": clients}
    if proto == 'vless':
        settings["decryption"] = "none"

    stream = {"network": net}
    sn = ib['server_name'] or 'www.microsoft.com'
    if sec == 'reality':
        stream['security'] = 'reality'
        stream['realitySettings'] = {
            "show": False,
            "dest": f"{sn}:443",
            "serverNames": [sn],
            "privateKey": ib['private_key'] or default_priv,
            "shortIds": [ib['short_id'] or ""],
            "fingerprint": ib['fingerprint'] or 'chrome',
        }
    elif sec == 'tls':
        domain = ssl_domain or sn
        stream['security'] = 'tls'
        stream['tlsSettings'] = {
            "serverName": domain,
            "certificates": [{
                "certificateFile": f"/etc/letsencrypt/live/{domain}/fullchain.pem",
                "keyFile": f"/etc/letsencrypt/live/{domain}/privkey.pem",
            }],
        }

    path = ib['path'] or '/'
    if net == 'ws':
        stream['wsSettings'] = {"path": path}
    elif net == 'grpc':
        stream['grpcSettings'] = {"serviceName": path.strip('/') or 'grpc'}

    return {"tag": ib['tag'], "port": ib['port'], "protocol": proto,
            "settings": settings, "streamSettings": stream}


def generate():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    default_priv = get_setting(c, 'reality_private_key')
    ssl_domain = get_setting(c, 'ssl_domain')

    inbounds_out = [API_INBOUND]
    routed = []
    for ib in [dict(r) for r in c.execute("SELECT * FROM xray_inbounds WHERE status=1 ORDER BY id")]:
        rows = c.execute("""SELECT cl.uuid, cl.username FROM xray_clients cl
                            JOIN users u ON cl.username = u.username
                            WHERE cl.inbound_id=? AND cl.enable=1 AND u.status=1
                            ORDER BY cl.id""", (ib['id'],)).fetchall()
        if not rows:
            continue
        sec = ib['security'] or 'none'
        clients = [make_client(ib['protocol'], sec, r['uuid'], r['username']) for r in rows]
        inbounds_out.append(make_inbound(ib, clients, default_priv, ssl_domain))
        routed.append(ib['tag'])
    conn.close()

    rules = [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}]
    if routed:
        rules.append({"type": "field", "inboundTag": routed, "outboundTag": "direct"})

    return {
        "log": {"loglevel": "warning", "error": "/tmp/xray_error.log"},
        "inbounds": inbounds_out,
        "outbounds": [{"protocol": "freedom", "tag": "direct"},
                      {"protocol": "blackhole", "tag": "block"},
                      {"protocol": "blackhole", "tag": "api"}],
        "routing": {"rules": rules},
        "api": {"tag": "api", "services": ["StatsService"]},
        "stats": {},
        "policy": {
            "system": {"statsInboundUplink": True, "statsInboundDownlink": True,
                       "statsOutboundUplink": True, "statsOutboundDownlink": True},
            "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
        },
    }


def write_and_validate(config):
    """True = changed and applied, False = unchanged, None = invalid (old kept)."""
    new_text = json.dumps(config, indent=2)
    old_text = open(XRAY_CONFIG).read() if os.path.exists(XRAY_CONFIG) else ''
    if new_text == old_text:
        return False
    with open(XRAY_TMP, 'w') as f:
        f.write(new_text)
    r = subprocess.run([XRAY_BIN, 'run', '-test', '-config', XRAY_TMP],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        print('Xray config test FAILED, keeping old config:', flush=True)
        print((r.stdout + r.stderr)[-1500:], flush=True)
        os.remove(XRAY_TMP)
        return None
    os.replace(XRAY_TMP, XRAY_CONFIG)
    return True


if __name__ == '__main__':
    result = write_and_validate(generate())
    if result is None:
        sys.exit(1)
    if result:
        subprocess.run(['systemctl', 'restart', 'xray'], timeout=60)
        print('Xray config updated and restarted', flush=True)
    else:
        print('Xray config unchanged', flush=True)
EOF
chmod +x "$SYNC"

# ---------- collector.py ----------
cat > "$PANEL/collector.py" <<'EOF'
#!/usr/bin/env python3
# OutlineParsian collector: SSH + Xray traffic, online state, SSH session limit, deactivation.
import os, re, sys, json, time, signal, sqlite3, subprocess, collections
from datetime import datetime

sys.path.insert(0, '/root/ssh-panel/grpc_proto')
try:
    import grpc
    import stats_pb2
    import stats_pb2_grpc
    HAS_GRPC = True
except Exception as e:
    print('grpc unavailable:', e, flush=True)
    HAS_GRPC = False

DB_PATH = '/root/ssh-panel/panel.db'
ONLINE_FILE = '/tmp/online_users.json'
STATE_FILE = '/tmp/collector_state.json'
SYNC_SCRIPT = '/root/ssh-panel/sync_xray.py'
XRAY_API = '127.0.0.1:10085'

INTERVAL = 5              # seconds between polls
XRAY_ONLINE_WINDOW = 45   # Xray user is online if traffic was seen this recently
XRAY_SEEN_KEEP = 300
MB = 1024.0 * 1024.0

SESSION_RE = re.compile(r'^sshd: ([A-Za-z0-9_.\-]+)@')


def run(cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ''


def load_state():
    try:
        with open(STATE_FILE) as f:
            s = json.load(f)
    except Exception:
        s = {}
    s.setdefault('ssh_bytes', {})
    s.setdefault('xray_seen', {})
    return s


def atomic_write(path, obj):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(obj, f)
    os.replace(tmp, path)


# ---------- SSH ----------
def ssh_pid_users():
    """pid -> username, one entry per real login session (sshd: user@pts/N)."""
    result = {}
    for line in run(['ps', '-eo', 'pid=,args=']).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        m = SESSION_RE.match(parts[1])
        if m:
            result[int(parts[0])] = m.group(1)
    return result


def ssh_sockets(pid_users):
    """'user|peer' -> (username, total_bytes) for established SSH sockets."""
    lines = run(['ss', '-tnpi', 'state', 'established', '( sport = :22 )']).splitlines()
    sockets = {}
    for i, line in enumerate(lines):
        pm = re.search(r'pid=(\d+)', line)
        if not pm or int(pm.group(1)) not in pid_users:
            continue
        user = pid_users[int(pm.group(1))]
        parts = line.split()
        peer = parts[4] if len(parts) > 4 else '?'
        info = lines[i + 1] if i + 1 < len(lines) else ''
        a = re.search(r'bytes_acked:(\d+)', info)
        r = re.search(r'bytes_received:(\d+)', info)
        total = (int(a.group(1)) if a else 0) + (int(r.group(1)) if r else 0)
        sockets[f'{user}|{peer}'] = (user, total)
    return sockets


# ---------- Xray ----------
def collect_xray():
    """username -> MB since last read (Xray stats are reset on read)."""
    traffic = {}
    if not HAS_GRPC:
        return traffic
    try:
        ch = grpc.insecure_channel(XRAY_API)
        stub = stats_pb2_grpc.StatsServiceStub(ch)
        resp = stub.QueryStats(stats_pb2.QueryStatsRequest(pattern='user>>>', reset=True), timeout=5)
        ch.close()
    except Exception:
        return traffic
    for stat in resp.stat:
        p = stat.name.split('>>>')
        if len(p) == 4 and p[0] == 'user' and p[2] == 'traffic' and stat.value > 0:
            traffic[p[1]] = traffic.get(p[1], 0.0) + stat.value / MB
    return traffic


# ---------- DB ----------
def apply_usage(conn, traffic):
    """Add usage; deactivate users over quota or expired. Returns deactivated usernames."""
    deactivated = []
    now = datetime.now()
    c = conn.cursor()
    for user, mb in traffic.items():
        c.execute("UPDATE users SET used_traffic = used_traffic + ? WHERE username = ?", (mb, user))
        row = c.execute("SELECT total_traffic, used_traffic, expire_date, status FROM users WHERE username = ?",
                        (user,)).fetchone()
        if not row:
            continue
        total, used, exp, status = row
        over = bool(total) and float(total) > 0 and float(used) >= float(total)
        expired = False
        try:
            expired = now > datetime.strptime(exp, '%Y-%m-%d %H:%M')
        except Exception:
            pass
        if (over or expired) and int(status) == 1:
            c.execute("UPDATE users SET status = 0 WHERE username = ?", (user,))
            deactivated.append(user)
    conn.commit()
    return deactivated


# ---------- Main loop ----------
def loop_once(state, now):
    conn = sqlite3.connect(DB_PATH, timeout=15)
    try:
        limits = {u: int(m or 0) for u, m in
                  conn.execute("SELECT username, max_connections FROM users WHERE status = 1")}

        # 1) SSH sessions and per-socket traffic
        pid_users = ssh_pid_users()
        sockets = ssh_sockets(pid_users)
        traffic = collections.defaultdict(float)
        new_bytes = {}
        for key, (user, total) in sockets.items():
            last = state['ssh_bytes'].get(key, 0)
            delta = total - last if total >= last else total   # counter reset
            new_bytes[key] = total
            if delta > 0:
                traffic[user] += delta / MB
        state['ssh_bytes'] = new_bytes

        sessions = collections.defaultdict(list)
        for pid, user in pid_users.items():
            sessions[user].append(pid)

        # 2) SSH limit: close the newest sessions beyond max_connections
        for user, pids in list(sessions.items()):
            lim = limits.get(user, 0)
            if lim > 0 and len(pids) > lim:
                keep = sorted(pids)[:lim]
                for pid in sorted(pids)[lim:]:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except OSError:
                        pass
                sessions[user] = keep

        # 3) Xray traffic (also marks Xray online)
        for u, mb in collect_xray().items():
            traffic[u] += mb
            state['xray_seen'][u] = now

        # 4) Usage and deactivation
        deactivated = apply_usage(conn, dict(traffic))
    finally:
        conn.close()

    for u in deactivated:
        subprocess.run(['pkill', '-KILL', '-u', u], capture_output=True)
    if deactivated:
        subprocess.run(['python3', SYNC_SCRIPT], timeout=120)

    # 5) Online list
    state['xray_seen'] = {u: t for u, t in state['xray_seen'].items() if now - t <= XRAY_SEEN_KEEP}
    xray_on = {u for u, t in state['xray_seen'].items() if now - t <= XRAY_ONLINE_WINDOW}
    online = {}
    for user in set(sessions) | xray_on:
        online[user] = {'ssh': len(sessions.get(user, [])), 'xray': user in xray_on, 'ts': now}
    atomic_write(ONLINE_FILE, {'ts': now, 'users': online})
    atomic_write(STATE_FILE, state)


def main():
    print('[*] OutlineParsian collector v3.8 started', flush=True)
    state = load_state()
    while True:
        now = time.time()
        try:
            loop_once(state, now)
        except Exception as e:
            print('collector error:', e, flush=True)
        time.sleep(INTERVAL)


if __name__ == '__main__':
    main()
EOF
chmod +x "$PANEL/collector.py"

# ---------- app.py ----------
cat > "$PANEL/app.py" <<'EOF'
#!/usr/bin/env python3
# OutlineParsian Panel v3.8 - web application
import os, re, io, sqlite3, subprocess, time, json, uuid, base64, random, functools, logging, secrets, threading
from datetime import datetime, timedelta
from urllib.parse import quote
from flask import (Flask, render_template, request, redirect, url_for, session,
                   send_file, flash, Response, jsonify)
import psutil

PANEL = '/root/ssh-panel'
DB_PATH = f'{PANEL}/panel.db'
SECRET_FILE = f'{PANEL}/.secret'
XRAY_BIN = '/usr/local/bin/xray'
SYNC_SCRIPT = f'{PANEL}/sync_xray.py'
IRAN_SCRIPT = '/usr/local/bin/iran-block.sh'
ONLINE_FILE = '/tmp/online_users.json'
NGINX_SITE = '/etc/nginx/sites-available/op-panel'
TSF = '%Y-%m-%d %H:%M'
RESERVED_PORTS = {22, 80, 443, 10085}
USER_RE = re.compile(r'[a-z_][a-z0-9_-]{1,31}')
TAG_RE = re.compile(r'[A-Za-z0-9_-]{2,40}')
FP_CHOICES = ('chrome', 'firefox', 'safari', 'edge', 'random')

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger('OP')

app = Flask(__name__, template_folder=f'{PANEL}/templates')
if not os.path.exists(SECRET_FILE):
    with open(SECRET_FILE, 'w') as f:
        f.write(secrets.token_hex(32))
    os.chmod(SECRET_FILE, 0o600)
app.secret_key = open(SECRET_FILE).read().strip()
app.permanent_session_lifetime = timedelta(hours=12)

# ---------------- system stats ----------------
_stats = {'cpu': 0.0, 'ram': 0.0}


def _stats_loop():
    while True:
        try:
            _stats['cpu'] = psutil.cpu_percent(interval=2)
            _stats['ram'] = psutil.virtual_memory().percent
        except Exception:
            time.sleep(2)


threading.Thread(target=_stats_loop, daemon=True).start()


@app.context_processor
def inject_stats():
    return {'cpu': round(_stats['cpu']), 'ram': round(_stats['ram'])}


# ---------------- DB helpers ----------------
def db():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA foreign_keys=ON')
    return conn


def q(sql, args=(), one=False, write=False):
    conn = db()
    try:
        cur = conn.execute(sql, args)
        if write:
            conn.commit()
            return cur.lastrowid
        rows = cur.fetchall()
        if one:
            return dict(rows[0]) if rows else None
        return [dict(r) for r in rows]
    finally:
        conn.close()


def setting(key, default=''):
    r = q("SELECT value FROM settings WHERE key=?", (key,), one=True)
    return r['value'] if r and r['value'] is not None else default


def set_setting(key, value):
    q("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)", (key, str(value)), write=True)


def safe_int(v, d=0):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return d


def safe_float(v, d=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return d


def panel_port():
    return safe_int(setting('panel_port', '5000'), 5000)


def host():
    return setting('domain') or request.host.split(':')[0]


def run(cmd, timeout=30, inp=None):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=inp)


def login_required(f):
    @functools.wraps(f)
    def wrapper(*a, **kw):
        if not session.get('ok'):
            return redirect(url_for('login'))
        return f(*a, **kw)
    return wrapper


# ---------------- system users / xray / iran block ----------------
def sys_user_upsert(username, password):
    if run(['id', username], 5).returncode != 0:
        run(['useradd', '-m', '-s', '/bin/bash', username], 10)
    run(['chpasswd'], 10, inp=f'{username}:{password}\n')


def sys_user_kill(username):
    run(['pkill', '-KILL', '-u', username], 5)


def sync_xray():
    r = run(['python3', SYNC_SCRIPT], timeout=150)
    if r.returncode != 0:
        log.error('sync_xray failed: %s', (r.stdout + r.stderr)[-500:])
    return r.returncode == 0


def gen_reality_keys():
    out = run([XRAY_BIN, 'x25519'], 15).stdout
    priv = pub = ''
    for line in out.splitlines():
        low = line.lower()
        if ':' not in line or 'hash32' in low:
            continue
        val = line.split(':', 1)[1].strip()
        if 'private' in low:
            priv = val
        elif 'public' in low or 'password' in low:
            pub = val
    return priv, pub


def apply_iran_block():
    mode = 'enable' if setting('block_iran') == '1' else 'disable'
    run([IRAN_SCRIPT, mode], timeout=180)


def apply_iran_block_async():
    threading.Thread(target=apply_iran_block, daemon=True).start()


def write_nginx(port):
    conf = (
        "server {\n"
        "    listen 80 default_server;\n"
        "    server_name _;\n"
        "    client_max_body_size 100M;\n"
        "    location / {\n"
        f"        proxy_pass http://127.0.0.1:{port};\n"
        "        proxy_http_version 1.1;\n"
        "        proxy_set_header Host $host;\n"
        "        proxy_set_header X-Real-IP $remote_addr;\n"
        "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n"
        "        proxy_read_timeout 300s;\n"
        "    }\n"
        "}\n")
    with open(NGINX_SITE, 'w') as f:
        f.write(conf)
    run(['systemctl', 'reload', 'nginx'], 20)


# ---------------- links / configs ----------------
def effective_sni(ib):
    if (ib.get('security') or 'none') == 'tls':
        return setting('ssl_domain') or ib.get('server_name') or ''
    return ib.get('server_name') or ''


def build_link(ib, uid, user, dom, dpub):
    proto = ib['protocol']
    port = ib['port']
    net = ib.get('network') or 'tcp'
    sec = ib.get('security') or 'none'
    sni = effective_sni(ib)
    fp = ib.get('fingerprint') or 'chrome'
    sid = ib.get('short_id') or ''
    pub = ib.get('public_key') or dpub
    path = ib.get('path') or '/'

    if proto == 'vmess':
        cnf = {"v": "2", "ps": f"OP-{user}", "add": dom, "port": str(port), "id": uid,
               "aid": "0", "scy": "auto", "net": net, "type": "none",
               "host": sni if sec == 'tls' else "", "path": path,
               "tls": "tls" if sec == 'tls' else "none", "sni": sni if sec == 'tls' else ""}
        return 'vmess://' + base64.b64encode(json.dumps(cnf).encode()).decode()

    p = {'security': sec, 'type': net}
    if proto == 'vless':
        p['encryption'] = 'none'
    if sec == 'reality':
        p.update(fp=fp, sni=sni, pbk=pub, sid=sid)
        if proto in ('vless', 'trojan'):
            p['flow'] = 'xtls-rprx-vision'
    elif sec == 'tls':
        p.update(sni=sni, fp=fp)
    if net == 'ws':
        p['path'] = path
    if net == 'grpc':
        p['serviceName'] = path.strip('/') or 'grpc'
    qs = '&'.join(f'{k}={quote(str(v), safe="/")}' for k, v in p.items() if v not in ('', None))
    return f'{proto}://{quote(uid, safe="")}@{dom}:{port}?{qs}#{quote("OP-" + user)}'


@functools.lru_cache(maxsize=1024)
def qr_b64(data):
    try:
        import qrcode
        qr = qrcode.QRCode(box_size=8, border=2)
        qr.add_data(data)
        qr.make(fit=True)
        buf = io.BytesIO()
        qr.make_image(fill_color='black', back_color='white').save(buf, format='PNG')
        return base64.b64encode(buf.getvalue()).decode()
    except Exception as e:
        log.warning('qr failed: %s', e)
        return ''


def user_configs(username):
    dom = host()
    dpub = setting('reality_public_key')
    rows = q("""SELECT cl.uuid AS uuid, ib.* FROM xray_clients cl
                JOIN xray_inbounds ib ON cl.inbound_id = ib.id
                WHERE cl.username=? AND cl.enable=1 AND ib.status=1
                ORDER BY cl.id""", (username,))
    out = []
    for r in rows:
        link = build_link(r, r['uuid'], username, dom, dpub)
        out.append({'row': r, 'link': link, 'qr': qr_b64(link), 'protocol': r['protocol'],
                    'tag': r['tag'], 'port': r['port'], 'net': r['network'], 'sec': r['security']})
    return out


def cfg_info(r, username):
    return {
        "name": f"OP-{username}", "protocol": r['protocol'], "server": host(), "port": r['port'],
        "uuid": r['uuid'], "network": r['network'], "security": r['security'],
        "sni": effective_sni(r), "fingerprint": r['fingerprint'], "short_id": r['short_id'],
        "public_key": r['public_key'] or setting('reality_public_key'), "path": r['path'],
        "flow": "xtls-rprx-vision" if r['security'] == 'reality' and r['protocol'] in ('vless', 'trojan') else "",
    }


# ---------------- online / dashboard data ----------------
def get_online():
    try:
        with open(ONLINE_FILE) as f:
            data = json.load(f)
        if time.time() - data.get('ts', 0) > 30:
            return {}          # collector not running / stale
        return data.get('users', {})
    except Exception:
        return {}


def build_user_rows():
    online = get_online()
    dom = host()
    rows = []
    for u in q("SELECT * FROM users ORDER BY created_at DESC"):
        o = online.get(u['username'], {})
        total = u['total_traffic'] or 0
        used = u['used_traffic'] or 0
        rows.append({
            'username': u['username'], 'password': u['password'], 'expire': u['expire_date'],
            'status': u['status'], 'max_conn': u['max_connections'],
            'total_gb': round(total / 1024, 2), 'used_gb': round(used / 1024, 2),
            'pct': min(100, int(used / total * 100)) if total > 0 else 0,
            'ssh': o.get('ssh', 0), 'xray': bool(o.get('xray', False)),
            'online': bool(o.get('ssh') or o.get('xray')),
            'sub_public': f"http://{dom}/sub/{u['username']}",
        })
    return rows


# ---------------- auth ----------------
@app.route('/', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        ok_user = secrets.compare_digest(request.form.get('username', ''), setting('admin_username', 'admin'))
        ok_pass = secrets.compare_digest(request.form.get('password', ''), setting('admin_password', ''))
        if ok_user and ok_pass:
            session.permanent = True
            session['ok'] = True
            return redirect(url_for('dashboard'))
        time.sleep(1)
        return render_template('login.html', error='اطلاعات نادرست')
    if session.get('ok'):
        return redirect(url_for('dashboard'))
    return render_template('login.html')


@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))


# ---------------- API ----------------
@app.route('/api/stats')
def api_stats():
    if not session.get('ok'):
        return jsonify({'error': 'unauthorized'}), 401
    return jsonify({'cpu': _stats['cpu'], 'ram': _stats['ram']})


@app.route('/api/online')
def api_online():
    if not session.get('ok'):
        return jsonify({'error': 'unauthorized'}), 401
    return jsonify(get_online())


# ---------------- dashboard & users ----------------
@app.route('/dashboard')
@login_required
def dashboard():
    users = build_user_rows()
    s = q("""SELECT COUNT(*) AS total,
                    COALESCE(SUM(CASE WHEN status=1 THEN 1 ELSE 0 END),0) AS active,
                    COALESCE(SUM(used_traffic),0) AS used FROM users""", one=True)
    inbound_count = q("SELECT COUNT(*) AS c FROM xray_inbounds WHERE status=1", one=True)['c']
    client_count = q("SELECT COUNT(*) AS c FROM xray_clients WHERE enable=1", one=True)['c']
    return render_template('dashboard.html', users=users, total=s['total'], active=s['active'],
                           used_gb=round((s['used'] or 0) / 1024, 2),
                           inbound_count=inbound_count, client_count=client_count)


@app.route('/users/new', methods=['GET', 'POST'])
@login_required
def user_new():
    if request.method == 'GET':
        return render_template('user_form.html')
    u = request.form.get('username', '').strip().lower()
    p = request.form.get('password', '').strip()
    if not USER_RE.fullmatch(u) or u == 'root':
        flash('نام کاربری فقط حروف کوچک انگلیسی، عدد، _ و - (حداقل ۲ کاراکتر)', 'error')
        return redirect(url_for('user_new'))
    if len(p) < 4:
        flash('کلمه عبور حداقل ۴ کاراکتر باشد', 'error')
        return redirect(url_for('user_new'))
    if q("SELECT 1 FROM users WHERE username=?", (u,), one=True):
        flash('این کاربر وجود دارد', 'error')
        return redirect(url_for('user_new'))
    days = max(1, safe_int(request.form.get('expire_days'), 30))
    traffic_mb = max(0.0, safe_float(request.form.get('traffic_gb'), 0)) * 1024
    mc = max(1, safe_int(request.form.get('max_connections'), 2))
    exp = (datetime.now() + timedelta(days=days)).strftime(TSF)
    sys_user_upsert(u, p)
    q("""INSERT INTO users(username,password,expire_date,total_traffic,used_traffic,status,max_connections,created_at)
         VALUES(?,?,?,?,0,1,?,?)""",
      (u, p, exp, traffic_mb, mc, datetime.now().strftime(TSF)), write=True)
    flash(f'کاربر {u} ایجاد شد', 'success')
    return redirect(url_for('dashboard'))


@app.route('/users/edit', methods=['POST'])
@login_required
def user_edit():
    u = request.form.get('username', '')
    row = q("SELECT * FROM users WHERE username=?", (u,), one=True)
    if not row:
        flash('کاربر یافت نشد', 'error')
        return redirect(url_for('dashboard'))
    p = request.form.get('password', '').strip() or row['password']
    if len(p) < 4:
        flash('کلمه عبور حداقل ۴ کاراکتر باشد', 'error')
        return redirect(url_for('dashboard'))
    try:
        exp = datetime.strptime(request.form.get('expire_date', '').strip(), TSF)
    except ValueError:
        flash('فرمت تاریخ انقضا باید YYYY-MM-DD HH:MM باشد', 'error')
        return redirect(url_for('dashboard'))

    tg = max(0.0, safe_float(request.form.get('traffic_gb'), 0)) * 1024
    mc = max(1, safe_int(request.form.get('max_connections'), 2))
    status = 1 if request.form.get('status') == '1' else 0
    msgs = []

    if request.form.get('reset_expire') == 'on':
        exp = datetime.now() + timedelta(days=max(1, safe_int(request.form.get('reset_days'), 30)))
        msgs.append('تاریخ انقضا ریست شد')
    else:
        ext = safe_int(request.form.get('extend_days'), 0)
        if ext > 0:
            exp = exp + timedelta(days=ext)
            msgs.append(f'{ext} روز اضافه شد')

    reset_used = request.form.get('reset_traffic') == 'on'
    if reset_used:
        msgs.append('مصرف صفر شد')

    sys_user_upsert(u, p)
    if status == 0:
        run(['usermod', '-L', u], 5)
        sys_user_kill(u)
    else:
        run(['usermod', '-U', u], 5)

    used_sql = ', used_traffic=0' if reset_used else ''
    q(f"""UPDATE users SET password=?, total_traffic=?, max_connections=?, status=?, expire_date=?{used_sql}
          WHERE username=?""",
      (p, tg, mc, status, exp.strftime(TSF), u), write=True)

    if not sync_xray():
        flash('⚠️ کانفیگ Xray نامعتبر بود؛ کانفیگ قبلی حفظ شد', 'warning')
    flash(' · '.join([f'کاربر {u} بروز شد'] + msgs), 'success')
    return redirect(url_for('dashboard'))


@app.route('/users/<username>/delete', methods=['POST'])
@login_required
def user_delete(username):
    if username == 'root':
        flash('حذف root مجاز نیست', 'error')
        return redirect(url_for('dashboard'))
    sys_user_kill(username)
    run(['userdel', '-r', username], 10)
    q("DELETE FROM users WHERE username=?", (username,), write=True)
    sync_xray()
    flash(f'{username} حذف شد', 'success')
    return redirect(url_for('dashboard'))


# ---------------- inbounds ----------------
@app.route('/inbounds')
@login_required
def inbounds_page():
    rows = q("""SELECT i.*, (SELECT COUNT(*) FROM xray_clients c WHERE c.inbound_id=i.id) AS cnt
                FROM xray_inbounds i ORDER BY i.id DESC""")
    return render_template('inbounds.html', inbounds=rows)


def random_port():
    used = {r['port'] for r in q("SELECT port FROM xray_inbounds")}
    listening = run(['ss', '-tln'], 5).stdout
    for _ in range(300):
        p = random.randint(10000, 60000)
        if p in used or p in RESERVED_PORTS or p == panel_port():
            continue
        if re.search(rf':{p}\b', listening):
            continue
        return p
    return 20000


@app.route('/inbounds/new', methods=['GET', 'POST'])
@login_required
def inbound_new():
    if request.method == 'GET':
        return render_template('inbound_form.html', random_port=random_port(), fp_choices=FP_CHOICES)

    f = request.form
    tag = f.get('tag', '').strip()
    proto = f.get('protocol', 'vless')
    net = f.get('network', 'tcp')
    sec = f.get('security', 'none')
    port = safe_int(f.get('port'), 0)
    path = f.get('path', '/').strip() or '/'
    if not path.startswith('/'):
        path = '/' + path
    sni = f.get('server_name', '').strip() or 'www.microsoft.com'
    fp = f.get('fingerprint', 'chrome')
    sid = f.get('short_id', '').strip().lower()

    def back(msg):
        flash(msg, 'error')
        return redirect(url_for('inbound_new'))

    if not TAG_RE.fullmatch(tag):
        return back('Tag فقط حروف انگلیسی، عدد، _ و - (۲ تا ۴۰ کاراکتر)')
    if proto not in ('vless', 'vmess', 'trojan') or net not in ('tcp', 'ws', 'grpc') \
            or sec not in ('none', 'tls', 'reality') or fp not in FP_CHOICES:
        return back('مقادیر فرم نامعتبر است')
    if proto == 'vmess' and sec == 'reality':
        return back('VMess با Reality پشتیبانی نمی‌شود (از VLESS یا Trojan استفاده کنید)')
    if sec == 'tls':
        domain = setting('ssl_domain')
        if not domain or not os.path.exists(f'/etc/letsencrypt/live/{domain}/fullchain.pem'):
            return back('برای TLS ابتدا در تنظیمات، دامنه SSL را ثبت و گواهی بگیرید')
    if not (1024 <= port <= 65535) or port in RESERVED_PORTS or port == panel_port():
        return back('پورت نامعتبر یا رزرو شده است')
    if sid and (not re.fullmatch(r'[0-9a-f]{2,16}', sid) or len(sid) % 2):
        return back('Short ID باید هگز و طول زوج (حداکثر ۱۶) باشد')
    if q("SELECT 1 FROM xray_inbounds WHERE tag=?", (tag,), one=True):
        return back('این Tag قبلاً استفاده شده')
    if q("SELECT 1 FROM xray_inbounds WHERE port=?", (port,), one=True):
        return back('این پورت قبلاً استفاده شده')

    pub = priv = ''
    if sec == 'reality':
        pub, priv = setting('reality_public_key'), setting('reality_private_key')
        if not pub or not priv:
            priv, pub = gen_reality_keys()
            if not (pub and priv):
                return back('ساخت کلیدهای Reality ناموفق بود')
            set_setting('reality_public_key', pub)
            set_setting('reality_private_key', priv)

    q("""INSERT INTO xray_inbounds(tag,protocol,port,network,security,server_name,fingerprint,short_id,
                                  public_key,private_key,path,created_at)
         VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
      (tag, proto, port, net, sec, sni, fp, sid, pub, priv, path, datetime.now().strftime(TSF)), write=True)
    if not sync_xray():
        flash('⚠️ کانفیگ Xray نامعتبر بود؛ اینباند ذخیره شد ولی اعمال نشد', 'warning')
    flash(f'اینباند {tag}:{port} ساخته شد', 'success')
    return redirect(url_for('inbounds_page'))


@app.route('/inbounds/<int:iid>/delete', methods=['POST'])
@login_required
def inbound_delete(iid):
    q("DELETE FROM xray_inbounds WHERE id=?", (iid,), write=True)
    sync_xray()
    flash('اینباند حذف شد', 'success')
    return redirect(url_for('inbounds_page'))


# ---------------- clients ----------------
@app.route('/inbounds/<int:iid>/clients')
@login_required
def clients_page(iid):
    ib = q("SELECT * FROM xray_inbounds WHERE id=?", (iid,), one=True)
    if not ib:
        flash('اینباند یافت نشد', 'error')
        return redirect(url_for('inbounds_page'))
    dom = host()
    dpub = setting('reality_public_key')
    clients = []
    for c in q("SELECT * FROM xray_clients WHERE inbound_id=? ORDER BY id", (iid,)):
        c['link'] = build_link(ib, c['uuid'], c['username'], dom, dpub)
        clients.append(c)
    available = [r['username'] for r in q(
        "SELECT username FROM users WHERE username NOT IN (SELECT username FROM xray_clients WHERE inbound_id=?) ORDER BY username",
        (iid,))]
    return render_template('clients.html', inbound=ib, clients=clients, available=available)


@app.route('/inbounds/<int:iid>/clients/add', methods=['POST'])
@login_required
def clients_add(iid):
    added = 0
    for uname in request.form.getlist('usernames'):
        if q("SELECT 1 FROM users WHERE username=?", (uname,), one=True):
            q("INSERT OR IGNORE INTO xray_clients(inbound_id,username,uuid,email,created_at) VALUES(?,?,?,?,?)",
              (iid, uname, str(uuid.uuid4()), uname, datetime.now().strftime(TSF)), write=True)
            added += 1
    sync_xray()
    flash(f'{added} کاربر اضافه شد', 'success')
    return redirect(url_for('clients_page', iid=iid))


@app.route('/clients/<int:cid>/delete', methods=['POST'])
@login_required
def client_delete(cid):
    row = q("SELECT inbound_id FROM xray_clients WHERE id=?", (cid,), one=True)
    q("DELETE FROM xray_clients WHERE id=?", (cid,), write=True)
    sync_xray()
    flash('کلاینت حذف شد', 'success')
    if row:
        return redirect(url_for('clients_page', iid=row['inbound_id']))
    return redirect(url_for('inbounds_page'))


# ---------------- groups ----------------
@app.route('/groups')
@login_required
def groups_page():
    groups = q("""SELECT g.*, (SELECT COUNT(*) FROM group_members m WHERE m.group_id=g.id) AS member_count
                  FROM user_groups g ORDER BY g.id DESC""")
    return render_template('groups.html', groups=groups)


@app.route('/groups/new', methods=['POST'])
@login_required
def group_new():
    name = request.form.get('name', '').strip()
    if not name:
        flash('نام گروه لازم است', 'error')
    elif q("SELECT 1 FROM user_groups WHERE name=?", (name,), one=True):
        flash('گروه تکراری است', 'error')
    else:
        q("INSERT INTO user_groups(name,description,created_at) VALUES(?,?,?)",
          (name, request.form.get('description', '').strip(), datetime.now().strftime(TSF)), write=True)
        flash('گروه ساخته شد', 'success')
    return redirect(url_for('groups_page'))


@app.route('/groups/<int:gid>/delete', methods=['POST'])
@login_required
def group_delete(gid):
    q("DELETE FROM user_groups WHERE id=?", (gid,), write=True)
    flash('گروه حذف شد', 'success')
    return redirect(url_for('groups_page'))


@app.route('/groups/<int:gid>')
@login_required
def group_members_page(gid):
    group = q("SELECT * FROM user_groups WHERE id=?", (gid,), one=True)
    if not group:
        return redirect(url_for('groups_page'))
    members = [r['username'] for r in q("SELECT username FROM group_members WHERE group_id=? ORDER BY username", (gid,))]
    available = [r['username'] for r in q(
        "SELECT username FROM users WHERE username NOT IN (SELECT username FROM group_members WHERE group_id=?) ORDER BY username",
        (gid,))]
    return render_template('group_members.html', group=group, members=members, available=available)


@app.route('/groups/<int:gid>/add', methods=['POST'])
@login_required
def group_add(gid):
    for uname in request.form.getlist('usernames'):
        q("INSERT INTO group_members(group_id,username) VALUES(?,?)", (gid, uname), write=True)
    flash('اعضا اضافه شدند', 'success')
    return redirect(url_for('group_members_page', gid=gid))


@app.route('/groups/<int:gid>/remove/<username>', methods=['POST'])
@login_required
def group_remove(gid, username):
    q("DELETE FROM group_members WHERE group_id=? AND username=?", (gid, username), write=True)
    flash('عضو حذف شد', 'success')
    return redirect(url_for('group_members_page', gid=gid))


# ---------------- reports ----------------
@app.route('/reports')
@login_required
def reports():
    s = q("""SELECT COUNT(*) AS total_users,
                    COALESCE(SUM(total_traffic)/1024,0) AS total_gb,
                    COALESCE(SUM(used_traffic)/1024,0) AS used_gb,
                    COALESCE(SUM(CASE WHEN status=1 THEN 1 ELSE 0 END),0) AS active_users
             FROM users""", one=True)
    ib = q("SELECT COUNT(*) AS c FROM xray_inbounds WHERE status=1", one=True)['c']
    cl = q("SELECT COUNT(*) AS c FROM xray_clients WHERE enable=1", one=True)['c']
    return render_template('reports.html', s=s, ib=ib, cl=cl)


# ---------------- settings ----------------
SETTING_KEYS = ['domain', 'admin_username', 'panel_port', 'ssl_domain', 'block_iran',
                'reality_public_key', 'reality_private_key']


@app.route('/settings')
@login_required
def settings_page():
    s = {k: setting(k) for k in SETTING_KEYS}
    sd = s['ssl_domain']
    cert = bool(sd) and os.path.exists(f'/etc/letsencrypt/live/{sd}/fullchain.pem')
    return render_template('settings.html', s=s, cert=cert)


@app.route('/settings', methods=['POST'])
@login_required
def settings_save():
    f = request.form
    old_port = panel_port()
    dom = f.get('domain', '').strip()
    ssl_dom = f.get('ssl_domain', '').strip()
    if ssl_dom and not re.fullmatch(r'[A-Za-z0-9.-]{3,253}', ssl_dom):
        flash('دامنه SSL نامعتبر است', 'error')
        return redirect(url_for('settings_page'))
    new_port = safe_int(f.get('panel_port'), old_port)
    if not (1024 <= new_port <= 65535) or new_port in RESERVED_PORTS:
        flash('پورت پنل نامعتبر است', 'error')
        return redirect(url_for('settings_page'))

    set_setting('domain', dom)
    set_setting('ssl_domain', ssl_dom)
    set_setting('admin_username', f.get('admin_username', '').strip() or 'admin')
    if f.get('admin_password', '').strip():
        set_setting('admin_password', f.get('admin_password').strip())
    set_setting('block_iran', '1' if f.get('block_iran') else '0')
    set_setting('panel_port', new_port)
    apply_iran_block_async()
    if new_port != old_port:
        write_nginx(new_port)
        flash(f'پورت پنل به {new_port} تغییر کرد؛ برای اعمال، سرویس پنل را ری‌استارت کنید: systemctl restart ssh-panel', 'warning')
    else:
        flash('تنظیمات ذخیره شد', 'success')
    return redirect(url_for('settings_page'))


@app.route('/settings/ssl', methods=['POST'])
@login_required
def settings_ssl():
    d = setting('ssl_domain')
    if not d:
        flash('ابتدا دامنه SSL را ذخیره کنید', 'error')
        return redirect(url_for('settings_page'))
    r = run(['certbot', 'certonly', '--nginx', '-d', d, '--non-interactive', '--agree-tos',
             '--register-unsafely-without-email'], timeout=240)
    if r.returncode == 0:
        flash('گواهی SSL دریافت شد', 'success')
    else:
        flash('دریافت گواهی ناموفق بود: ' + (r.stderr or r.stdout)[-300:], 'error')
    return redirect(url_for('settings_page'))


@app.route('/settings/keys', methods=['POST'])
@login_required
def settings_keys():
    priv, pub = gen_reality_keys()
    if priv and pub:
        set_setting('reality_private_key', priv)
        set_setting('reality_public_key', pub)
        sync_xray()
        flash('کلیدهای Reality تولید شد (اینباندهای موجود هم به‌روز شدند)', 'success')
    else:
        flash('تولید کلید ناموفق بود', 'error')
    return redirect(url_for('settings_page'))


@app.route('/backup')
@login_required
def backup_download():
    dst_path = '/tmp/OutlineParsian_backup.db'
    src = sqlite3.connect(DB_PATH)
    dst = sqlite3.connect(dst_path)
    src.backup(dst)
    dst.close()
    src.close()
    return send_file(dst_path, as_attachment=True,
                     download_name=f'OutlineParsian_{datetime.now():%Y%m%d_%H%M}.db')


@app.route('/restore', methods=['POST'])
@login_required
def restore_upload():
    f = request.files.get('backup_file')
    if not f or not f.filename:
        flash('فایلی انتخاب نشده', 'error')
        return redirect(url_for('settings_page'))
    tmp = '/tmp/op_restore.db'
    f.save(tmp)
    try:
        c = sqlite3.connect(tmp)
        integrity = c.execute('PRAGMA integrity_check').fetchone()[0]
        n = c.execute('SELECT COUNT(*) FROM users').fetchone()[0]
        c.close()
        if integrity != 'ok':
            raise ValueError('integrity check failed')
    except Exception as e:
        if os.path.exists(tmp):
            os.remove(tmp)
        flash(f'فایل بکاپ نامعتبر است: {e}', 'error')
        return redirect(url_for('settings_page'))

    script = f"""#!/bin/bash
sleep 2
systemctl stop ssh-panel ssh-panel-collector
cp {DB_PATH} {DB_PATH}.before_restore_$(date +%s) 2>/dev/null
rm -f {DB_PATH}-wal {DB_PATH}-shm
cp {tmp} {DB_PATH} && rm -f {tmp}
python3 {SYNC_SCRIPT} >/dev/null 2>&1
systemctl start ssh-panel-collector ssh-panel
"""
    with open('/tmp/op_restore.sh', 'w') as fh:
        fh.write(script)
    run(['systemd-run', f'--unit=op-restore-{int(time.time())}', '/bin/bash', '/tmp/op_restore.sh'], 15)
    flash(f'بازیابی شروع شد ({n} کاربر). پنل چند ثانیه قطع و خودکار برمی‌گردد.', 'success')
    return redirect(url_for('settings_page'))


# ---------------- subscription ----------------
@app.route('/sub/<username>')
def sub_page(username):
    u = q("SELECT * FROM users WHERE username=?", (username,), one=True)
    if not u:
        return render_template('sub_error.html', msg='کاربر یافت نشد'), 404
    if u['status'] == 0:
        return render_template('sub_error.html', msg='اکانت شما غیرفعال شده است'), 403

    total = u['total_traffic'] or 0
    used = u['used_traffic'] or 0
    pct = min(100, int(used / total * 100)) if total > 0 else 0
    try:
        days_left = max(0, (datetime.strptime(u['expire_date'], TSF) - datetime.now()).days)
    except Exception:
        days_left = 0
    dom = host()
    ssh_uri = f"ssh://{username}:{u['password']}@{dom}:22#OP-{username}"
    return render_template(
        'sub.html', u=u, username=username, dom=dom,
        total_gb=round(total / 1024, 2), used_gb=round(used / 1024, 2),
        remain_gb=round(max(0, total - used) / 1024, 2) if total > 0 else None,
        pct=pct, days_left=days_left, ssh_uri=ssh_uri, ssh_qr=qr_b64(ssh_uri),
        configs=user_configs(username))


@app.route('/download/<kind>/<username>/<int:idx>')
def download_config(kind, username, idx):
    u = q("SELECT status FROM users WHERE username=?", (username,), one=True)
    if not u or u['status'] != 1:
        return 'Not found', 404
    cfgs = user_configs(username)
    if idx < 0 or idx >= len(cfgs):
        return 'Not found', 404
    r = cfgs[idx]['row']
    body = json.dumps(cfg_info(r, username), indent=2, ensure_ascii=False)
    if kind == 'nepster':
        return Response(body, mimetype='application/octet-stream',
                        headers={'Content-Disposition': f'attachment; filename=OP_{username}_{r["protocol"]}.npvt'})
    if kind == 'netmod':
        return Response(body, mimetype='application/json',
                        headers={'Content-Disposition': f'attachment; filename=OP_{username}_{r["protocol"]}.json'})
    return 'Not found', 404


# ---------------- errors ----------------
@app.errorhandler(404)
def not_found(e):
    return render_template('error.html', msg='صفحه یافت نشد'), 404


@app.errorhandler(500)
def server_error(e):
    log.exception('server error')
    return render_template('error.html', msg='خطای داخلی سرور (جزئیات در لاگ)'), 500


if __name__ == '__main__':
    sync_xray()
    apply_iran_block_async()
    port = panel_port()
    log.info('Panel starting on port %s', port)
    app.run(host='0.0.0.0', port=port, debug=False, threaded=True)
EOF

# ---------- templates ----------
mkdir -p "$PANEL/templates"

cat > "$PANEL/templates/base.html" <<'EOF'
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OutlineParsian</title>
<script src="https://cdn.tailwindcss.com"></script>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
<link href="https://fonts.googleapis.com/css2?family=Vazirmatn:wght@400;500;700;900&display=swap" rel="stylesheet">
<style>
  * { font-family: 'Vazirmatn', sans-serif; }
  body { background: radial-gradient(circle at top, #1a0000 0%, #000 60%); color: #f3f4f6; min-height: 100vh; }
  .glass { background: rgba(20,0,0,.8); backdrop-filter: blur(12px); border: 1px solid rgba(255,0,0,.15); }
  .btn { background: linear-gradient(90deg, #b91c1c, #7f1d1d); color: #fee2e2; border: 1px solid rgba(248,113,113,.3); }
  .btn:hover { filter: brightness(1.15); }
  .inp { background: #000; border: 1px solid rgba(127,29,29,.6); color: #fca5a5; border-radius: .75rem; padding: .6rem .8rem; outline: none; width: 100%; }
  .inp:focus { border-color: #ef4444; }
  .tbl th, .tbl td { padding: .75rem; }
</style>
</head>
<body class="pb-10">
{% if session.get('ok') %}
<nav class="glass sticky top-0 z-40 px-4 py-3 border-b border-red-900/30">
  <div class="max-w-7xl mx-auto flex flex-wrap items-center justify-between gap-3">
    <a href="{{ url_for('dashboard') }}" class="flex items-center gap-2">
      <span class="w-9 h-9 rounded-xl btn flex items-center justify-center font-black">OP</span>
      <span class="font-bold text-red-400">OutlineParsian</span>
    </a>
    <div class="flex items-center gap-2 text-xs">
      <span class="px-3 py-1 rounded-full bg-red-900/20 border border-red-800/30"><i class="fa-solid fa-microchip text-red-500"></i> <span data-stat="cpu">{{ cpu }}</span>%</span>
      <span class="px-3 py-1 rounded-full bg-red-900/20 border border-red-800/30"><i class="fa-solid fa-memory text-red-400"></i> <span data-stat="ram">{{ ram }}</span>%</span>
    </div>
    <div class="flex items-center gap-1.5 flex-wrap text-xs">
      {% for ep, label, icon in [('dashboard','داشبورد','fa-gauge-high'), ('inbounds_page','اینباند','fa-server'), ('groups_page','گروه‌ها','fa-layer-group'), ('reports','گزارش','fa-chart-bar'), ('settings_page','تنظیمات','fa-gear')] %}
      <a href="{{ url_for(ep) }}" class="px-3 py-1.5 rounded-lg border {% if request.endpoint == ep %}bg-red-900/40 text-red-300 border-red-700{% else %}text-red-300/70 border-transparent hover:bg-red-900/20{% endif %}">
        <i class="fa-solid {{ icon }}"></i> {{ label }}
      </a>
      {% endfor %}
      <a href="{{ url_for('logout') }}" class="px-3 py-1.5 rounded-lg bg-red-900/30 text-red-400 border border-red-800/50"><i class="fa-solid fa-right-from-bracket"></i></a>
    </div>
  </div>
</nav>
{% endif %}

<main class="p-4 md:p-6 max-w-7xl mx-auto">
  {% with messages = get_flashed_messages(with_categories=true) %}
    {% for cat, msg in messages %}
    <div class="mb-4 p-4 rounded-2xl text-sm border {% if cat == 'success' %}bg-emerald-900/30 border-emerald-700/50 text-emerald-400{% elif cat == 'warning' %}bg-amber-900/30 border-amber-700/50 text-amber-300{% else %}bg-red-900/30 border-red-700/50 text-red-400{% endif %}">{{ msg }}</div>
    {% endfor %}
  {% endwith %}
  {% block content %}{% endblock %}
</main>

<script>
function toast(m){const d=document.createElement('div');d.textContent=m;d.className='fixed top-5 left-1/2 -translate-x-1/2 bg-emerald-600 text-white px-5 py-2 rounded-full text-sm z-50 shadow-lg';document.body.appendChild(d);setTimeout(()=>d.remove(),1500);}
function copyText(t){
  if(navigator.clipboard && window.isSecureContext){navigator.clipboard.writeText(t).then(()=>toast('کپی شد'));}
  else{const a=document.createElement('textarea');a.value=t;document.body.appendChild(a);a.select();document.execCommand('copy');a.remove();toast('کپی شد');}
}
document.addEventListener('click',e=>{const b=e.target.closest('[data-copy]');if(b)copyText(b.dataset.copy);});
setInterval(()=>fetch('/api/stats').then(r=>r.ok?r.json():null).then(d=>{if(!d)return;
  document.querySelectorAll('[data-stat=cpu]').forEach(e=>e.textContent=Math.round(d.cpu));
  document.querySelectorAll('[data-stat=ram]').forEach(e=>e.textContent=Math.round(d.ram));}).catch(()=>{}),3000);
</script>
{% block scripts %}{% endblock %}
</body>
</html>
EOF

cat > "$PANEL/templates/login.html" <<'EOF'
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ورود | OutlineParsian</title>
<script src="https://cdn.tailwindcss.com"></script>
<link href="https://fonts.googleapis.com/css2?family=Vazirmatn:wght@400;700;900&display=swap" rel="stylesheet">
<style>*{font-family:'Vazirmatn',sans-serif}body{background:radial-gradient(circle at top,#1a0000,#000 60%);min-height:100vh}</style>
</head>
<body class="flex items-center justify-center p-4 text-gray-100">
<div class="w-full max-w-md bg-gradient-to-b from-[#1a0000] to-[#0a0000] border border-red-900/50 rounded-3xl p-8 shadow-2xl">
  <div class="text-center mb-8">
    <div class="w-20 h-20 mx-auto rounded-2xl bg-gradient-to-br from-red-700 to-red-900 flex items-center justify-center text-3xl font-black text-red-100 mb-4">OP</div>
    <h1 class="text-2xl font-bold text-red-400">OutlineParsian</h1>
    <p class="text-xs text-red-700/80">Panel v3.8</p>
  </div>
  {% if error %}<div class="mb-5 p-3 rounded-xl bg-red-900/30 border border-red-700/50 text-red-400 text-sm">{{ error }}</div>{% endif %}
  <form method="post" class="space-y-4">
    <input name="username" required autocomplete="username" placeholder="نام کاربری ادمین" dir="ltr"
           class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 outline-none focus:border-red-500">
    <input name="password" type="password" required autocomplete="current-password" placeholder="کلمه عبور" dir="ltr"
           class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 outline-none focus:border-red-500">
    <button class="w-full py-3.5 rounded-2xl font-bold text-red-100 bg-gradient-to-r from-red-700 to-red-900 border border-red-500/30">ورود به پنل</button>
  </form>
</div>
</body>
</html>
EOF

cat > "$PANEL/templates/error.html" <<'EOF'
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>خطا | OutlineParsian</title>
<script src="https://cdn.tailwindcss.com"></script>
<link href="https://fonts.googleapis.com/css2?family=Vazirmatn:wght@400;700&display=swap" rel="stylesheet">
<style>*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6;min-height:100vh}</style>
</head>
<body class="flex items-center justify-center p-4">
<div class="max-w-md w-full bg-red-950/40 border border-red-900/50 rounded-2xl p-8 text-center">
  <h1 class="text-xl font-bold text-red-400 mb-3">خطا</h1>
  <p class="text-gray-400 text-sm mb-6 break-all">{{ msg }}</p>
  <a href="/dashboard" class="inline-block px-6 py-2.5 rounded-xl bg-red-800 text-red-100 text-sm font-bold">بازگشت به داشبورد</a>
</div>
</body>
</html>
EOF

cat > "$PANEL/templates/sub_error.html" <<'EOF'
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>خطا | OutlineParsian</title>
<script src="https://cdn.tailwindcss.com"></script>
<link href="https://fonts.googleapis.com/css2?family=Vazirmatn:wght@400;700&display=swap" rel="stylesheet">
<style>*{font-family:'Vazirmatn',sans-serif}body{background:radial-gradient(circle at top,#1a0000,#000 60%);min-height:100vh}</style>
</head>
<body class="flex items-center justify-center p-4 text-gray-100">
<div class="max-w-md w-full bg-red-950/40 border border-red-900/50 rounded-2xl p-8 text-center">
  <div class="text-4xl text-red-500 mb-4"><i class="fa-solid fa-triangle-exclamation"></i></div>
  <h1 class="text-xl font-bold text-red-400 mb-2">خطا</h1>
  <p class="text-gray-400 text-sm">{{ msg }}</p>
</div>
</body>
</html>
EOF

cat > "$PANEL/templates/dashboard.html" <<'EOF'
{% extends 'base.html' %}
{% block content %}
<div class="grid grid-cols-2 md:grid-cols-5 gap-3 mb-6">
  {% for label, val, icon, color in [
      ('کل کاربران', total, 'fa-users', 'text-red-400'),
      ('کاربران فعال', active, 'fa-user-check', 'text-emerald-400'),
      ('اینباندها', inbound_count, 'fa-server', 'text-purple-400'),
      ('کلاینت‌ها', client_count, 'fa-plug', 'text-blue-400'),
      ('ترافیک مصرفی (GB)', used_gb, 'fa-database', 'text-amber-400')] %}
  <div class="glass rounded-2xl p-4">
    <i class="fa-solid {{ icon }} {{ color }} text-xl"></i>
    <div class="text-2xl font-black mt-2 {{ color }}">{{ val }}</div>
    <div class="text-[11px] text-gray-400">{{ label }}</div>
  </div>
  {% endfor %}
</div>

<div class="flex flex-wrap items-center justify-between gap-3 mb-4">
  <h2 class="text-lg font-bold text-red-400"><i class="fa-solid fa-list"></i> مدیریت کاربران</h2>
  <div class="flex gap-2 flex-wrap">
    <input id="q" class="inp w-40 text-xs" placeholder="جستجو...">
    <select id="f" class="inp w-auto text-xs">
      <option value="all">همه</option><option value="online">آنلاین</option>
      <option value="active">فعال</option><option value="inactive">غیرفعال</option>
    </select>
    <a href="{{ url_for('user_new') }}" class="btn px-4 py-2 rounded-xl text-xs font-bold"><i class="fa-solid fa-plus"></i> کاربر جدید</a>
  </div>
</div>

<div class="glass rounded-2xl overflow-x-auto">
<table class="tbl w-full text-right text-sm min-w-[900px]">
  <thead class="bg-black/50 text-red-400/70 text-xs">
    <tr><th>کاربر</th><th>پسورد</th><th>دستگاه‌ها (SSH)</th><th>ترافیک</th><th>انقضا</th><th class="text-center">وضعیت</th><th class="text-center">عملیات</th></tr>
  </thead>
  <tbody class="divide-y divide-red-900/20" id="rows">
  {% for u in users %}
    <tr class="row hover:bg-red-900/10" data-name="{{ u.username }}" data-online="{{ '1' if u.online else '0' }}" data-status="{{ u.status }}">
      <td>
        <div class="flex items-center gap-2 flex-wrap">
          <span class="w-2.5 h-2.5 rounded-full {{ 'bg-emerald-500' if u.online else 'bg-gray-700' }}"></span>
          <b class="text-red-400">{{ u.username }}</b>
          {% if u.ssh %}<span class="text-[10px] px-1.5 rounded bg-emerald-900/40 text-emerald-400">SSH {{ u.ssh }}</span>{% endif %}
          {% if u.xray %}<span class="text-[10px] px-1.5 rounded bg-purple-900/40 text-purple-400">V2Ray</span>{% endif %}
        </div>
      </td>
      <td class="font-mono text-xs text-red-300/70">{{ u.password }}</td>
      <td class="font-mono text-xs">{{ u.ssh }} / {{ u.max_conn }}</td>
      <td class="w-40">
        <div class="flex justify-between text-[10px] text-gray-400"><span>{{ u.used_gb }}</span><span>{{ u.total_gb if u.total_gb else '∞' }} GB</span></div>
        <div class="h-1.5 bg-red-900/30 rounded-full overflow-hidden"><div class="h-1.5 bg-gradient-to-r from-red-600 to-red-400" style="width: {{ u.pct }}%"></div></div>
      </td>
      <td class="font-mono text-xs text-gray-400">{{ u.expire }}</td>
      <td class="text-center">
        <span class="px-2 py-1 rounded-full text-xs {{ 'bg-emerald-900/30 text-emerald-400' if u.status == 1 else 'bg-red-900/50 text-red-400' }}">{{ 'فعال' if u.status == 1 else 'غیرفعال' }}</span>
      </td>
      <td>
        <div class="flex gap-1.5 justify-center">
          <button type="button" data-copy="{{ u.sub_public }}" class="p-2 rounded-lg bg-blue-900/20 text-blue-400" title="کپی لینک اشتراک"><i class="fa-solid fa-copy"></i></button>
          <button type="button" class="p-2 rounded-lg bg-amber-900/20 text-amber-400 edit-btn" title="ویرایش"
                  data-username="{{ u.username }}" data-password="{{ u.password }}" data-traffic="{{ u.total_gb }}"
                  data-max="{{ u.max_conn }}" data-status="{{ u.status }}" data-expire="{{ u.expire }}">
            <i class="fa-solid fa-pen"></i>
          </button>
          <form method="post" action="{{ url_for('user_delete', username=u.username) }}" onsubmit="return confirm('حذف {{ u.username }}؟')">
            <button class="p-2 rounded-lg bg-red-900/30 text-red-400" title="حذف"><i class="fa-solid fa-trash"></i></button>
          </form>
        </div>
      </td>
    </tr>
  {% else %}
    <tr><td colspan="7" class="p-8 text-center text-gray-500">کاربری وجود ندارد</td></tr>
  {% endfor %}
  </tbody>
</table>
</div>

<!-- Edit modal -->
<div id="editModal" class="hidden fixed inset-0 bg-black/90 items-center justify-center z-50 p-4">
  <div class="glass rounded-3xl w-full max-w-lg p-6 max-h-[90vh] overflow-y-auto">
    <div class="flex items-center justify-between mb-5">
      <h3 class="text-lg font-bold text-red-400">ویرایش <span id="e_label" class="text-emerald-400"></span></h3>
      <button type="button" onclick="closeEdit()" class="text-red-400/70 hover:text-red-400 text-xl"><i class="fa-solid fa-xmark"></i></button>
    </div>
    <form method="post" action="{{ url_for('user_edit') }}" class="space-y-4">
      <input type="hidden" name="username" id="e_username">
      <div class="grid grid-cols-2 gap-4">
        <div><label class="block text-xs text-red-400/70 mb-1">کلمه عبور</label><input class="inp font-mono" name="password" id="e_password" required></div>
        <div><label class="block text-xs text-red-400/70 mb-1">وضعیت</label>
          <select class="inp" name="status" id="e_status"><option value="1">فعال</option><option value="0">غیرفعال</option></select></div>
      </div>
      <div class="grid grid-cols-2 gap-4">
        <div><label class="block text-xs text-red-400/70 mb-1">حجم کل (GB) - 0 = نامحدود</label><input class="inp font-mono" type="number" step="0.1" min="0" name="traffic_gb" id="e_traffic" required></div>
        <div><label class="block text-xs text-red-400/70 mb-1">حداکثر دستگاه (SSH)</label><input class="inp font-mono" type="number" min="1" name="max_connections" id="e_max" required></div>
      </div>
      <div><label class="block text-xs text-red-400/70 mb-1">تاریخ انقضا</label><input class="inp font-mono" name="expire_date" id="e_expire" required placeholder="YYYY-MM-DD HH:MM" dir="ltr"></div>

      <div class="border-t border-red-900/30 pt-4 space-y-3">
        <h4 class="text-sm font-bold text-amber-400">عملیات (اختیاری)</h4>
        <label class="flex items-center gap-3 bg-black/50 border border-red-900/30 p-3 rounded-xl cursor-pointer">
          <input type="checkbox" name="reset_traffic" class="w-4 h-4"> <span class="text-sm text-red-300">صفر کردن مصرف ترافیک</span>
        </label>
        <div class="bg-black/50 border border-red-900/30 p-3 rounded-xl">
          <label class="flex items-center gap-3 cursor-pointer">
            <input type="checkbox" name="reset_expire" id="reset_expire" class="w-4 h-4" onchange="document.getElementById('rd').classList.toggle('hidden', !this.checked)">
            <span class="text-sm text-red-300">ریست تاریخ انقضا از همین الان</span>
          </label>
          <div id="rd" class="hidden mt-3 mr-7"><label class="text-xs text-amber-400/70">تعداد روز:</label>
            <input class="inp w-32 mt-1" type="number" name="reset_days" value="30" min="1"></div>
        </div>
        <div class="bg-black/50 border border-red-900/30 p-3 rounded-xl flex items-center gap-2">
          <span class="text-sm text-emerald-300">تمدید تاریخ فعلی +</span>
          <input class="inp w-24" type="number" name="extend_days" value="0" min="0"> <span class="text-xs text-emerald-400/70">روز</span>
        </div>
      </div>
      <div class="flex justify-end gap-3 pt-4 border-t border-red-900/30">
        <button type="button" onclick="closeEdit()" class="px-5 py-2.5 bg-red-900/30 text-red-400 rounded-xl text-sm">انصراف</button>
        <button type="submit" class="btn px-5 py-2.5 rounded-xl text-sm font-bold">ذخیره</button>
      </div>
    </form>
  </div>
</div>
{% endblock %}

{% block scripts %}
<script>
function closeEdit(){document.getElementById('editModal').classList.add('hidden');document.getElementById('editModal').classList.remove('flex');}
document.querySelectorAll('.edit-btn').forEach(function(b){
  b.addEventListener('click',function(){
    var d=b.dataset;
    document.getElementById('e_label').textContent=d.username;
    document.getElementById('e_username').value=d.username;
    document.getElementById('e_password').value=d.password;
    document.getElementById('e_traffic').value=d.traffic;
    document.getElementById('e_max').value=d.max;
    document.getElementById('e_status').value=d.status;
    document.getElementById('e_expire').value=d.expire;
    document.getElementById('reset_expire').checked=false;
    document.getElementById('rd').classList.add('hidden');
    var m=document.getElementById('editModal');m.classList.remove('hidden');m.classList.add('flex');
  });
});
var qEl=document.getElementById('q'), fEl=document.getElementById('f');
function filt(){
  var q=qEl.value.toLowerCase(), s=fEl.value;
  document.querySelectorAll('#rows tr.row').forEach(function(r){
    var okQ=!q||r.dataset.name.indexOf(q)!==-1;
    var okF=s==='all'||(s==='online'&&r.dataset.online==='1')||(s==='active'&&r.dataset.status==='1')||(s==='inactive'&&r.dataset.status==='0');
    r.style.display=(okQ&&okF)?'':'none';
  });
}
qEl.addEventListener('input',filt); fEl.addEventListener('change',filt);
</script>
{% endblock %}
EOF

cat > "$PANEL/templates/user_form.html" <<'EOF'
{% extends 'base.html' %}
{% block content %}
<div class="max-w-xl mx-auto glass rounded-3xl p-6 md:p-8">
  <div class="flex items-center justify-between mb-6">
    <h2 class="text-lg font-bold text-red-400"><i class="fa-solid fa-user-plus"></i> ایجاد اکانت SSH</h2>
    <a href="{{ url_for('dashboard') }}" class="text-sm text-red-300/70 hover:text-red-300"><i class="fa-solid fa-arrow-right"></i> بازگشت</a>
  </div>
  <form method="post" class="space-y-5">
    <div>
      <label class="block text-sm text-red-400/70 mb-2">نام کاربری (حروف کوچک انگلیسی، عدد، _ و -)</label>
      <input class="inp font-mono" name="username" required pattern="[a-z_][a-z0-9_-]{1,31}" dir="ltr" autocomplete="off">
    </div>
    <div>
      <label class="block text-sm text-red-400/70 mb-2">کلمه عبور (حداقل ۴ کاراکتر)</label>
      <input class="inp font-mono" name="password" required minlength="4" dir="ltr" autocomplete="off">
    </div>
    <div class="grid grid-cols-3 gap-3">
      <div><label class="block text-xs text-red-400/70 mb-2">مدت (روز)</label><input class="inp text-center" type="number" name="expire_days" value="30" min="1"></div>
      <div><label class="block text-xs text-red-400/70 mb-2">حجم (GB، ۰=نامحدود)</label><input class="inp text-center" type="number" step="0.1" min="0" name="traffic_gb" value="50"></div>
      <div><label class="block text-xs text-red-400/70 mb-2">حداکثر دستگاه</label><input class="inp text-center" type="number" name="max_connections" value="2" min="1"></div>
    </div>
    <button type="submit" class="btn w-full py-3.5 rounded-2xl font-bold"><i class="fa-solid fa-circle-plus"></i> ساخت اکانت</button>
  </form>
</div>
{% endblock %}
EOF

cat > "$PANEL/templates/inbounds.html" <<'EOF'
{% extends 'base.html' %}
{% block content %}
<div class="flex items-center justify-between mb-4">
  <h2 class="text-lg font-bold text-red-400"><i class="fa-solid fa-server"></i> اینباندها</h2>
  <a href="{{ url_for('inbound_new') }}" class="btn px-4 py-2 rounded-xl text-xs font-bold"><i class="fa-solid fa-plus"></i> اینباند جدید</a>
</div>
<div class="glass rounded-2xl overflow-x-auto">
<table class="tbl w-full text-right text-sm min-w-[800px]">
  <thead class="bg-black/50 text-red-400/70 text-xs">
    <tr><th>Tag</th><th>پروتکل</th><th>پورت</th><th>شبکه</th><th>امنیت</th><th>SNI / FP</th><th class="text-center">کلاینت</th><th class="text-center">عملیات</th></tr>
  </thead>
  <tbody class="divide-y divide-red-900/20">
  {% for ib in inbounds %}
    <tr class="hover:bg-red-900/10">
      <td class="font-bold text-red-400">{{ ib.tag }}</td>
      <td><span class="text-xs px-2 py-0.5 rounded-full bg-blue-900/30 text-blue-400">{{ ib.protocol|upper }}</span></td>
      <td class="font-mono text-red-300">{{ ib.port }}</td>
      <td class="text-xs text-red-400/70">{{ ib.network|upper }}</td>
      <td class="text-xs">
        {% if ib.security == 'reality' %}<span class="text-emerald-400">Reality</span>
        {% elif ib.security == 'tls' %}<span class="text-blue-400">TLS</span>
        {% else %}<span class="text-gray-500">—</span>{% endif %}
      </td>
      <td class="text-[10px] text-red-400/50">{% if ib.security != 'none' %}{{ ib.server_name }} / {{ ib.fingerprint }}{% else %}—{% endif %}</td>
      <td class="text-center"><a href="{{ url_for('clients_page', iid=ib.id) }}" class="px-3 py-1 rounded-lg bg-red-900/20 text-red-400 text-xs font-bold">{{ ib.cnt }}</a></td>
      <td class="text-center">
        <div class="inline-flex gap-1.5">
          <a href="{{ url_for('clients_page', iid=ib.id) }}" class="p-2 rounded-lg bg-blue-900/20 text-blue-400"><i class="fa-solid fa-users"></i></a>
          <form method="post" action="{{ url_for('inbound_delete', iid=ib.id) }}" onsubmit="return confirm('حذف {{ ib.tag }}؟')">
            <button class="p-2 rounded-lg bg-red-900/30 text-red-400"><i class="fa-solid fa-trash"></i></button>
          </form>
        </div>
      </td>
    </tr>
  {% else %}
    <tr><td colspan="8" class="p-8 text-center text-gray-500">اینباندی وجود ندارد</td></tr>
  {% endfor %}
  </tbody>
</table>
</div>
{% endblock %}
EOF

cat > "$PANEL/templates/inbound_form.html" <<'EOF'
{% extends 'base.html' %}
{% block content %}
<form method="post" class="max-w-4xl mx-auto space-y-5">
  <div class="flex items-center justify-between">
    <h2 class="text-lg font-bold text-red-400"><i class="fa-solid fa-circle-plus"></i> اینباند جدید</h2>
    <a href="{{ url_for('inbounds_page') }}" class="text-sm text-red-300/70"><i class="fa-solid fa-arrow-right"></i> بازگشت</a>
  </div>

  <div class="glass rounded-3xl p-6 grid grid-cols-1 md:grid-cols-3 gap-4">
    <div><label class="block text-xs text-red-400/70 mb-2">Tag</label><input class="inp font-mono" name="tag" required dir="ltr" placeholder="inbound-1"></div>
    <div><label class="block text-xs text-red-400/70 mb-2">پروتکل</label>
      <select class="inp" name="protocol"><option value="vless">VLESS</option><option value="vmess">VMess</option><option value="trojan">Trojan</option></select></div>
    <div><label class="block text-xs text-red-400/70 mb-2">پورت</label>
      <div class="flex gap-2">
        <input class="inp font-mono text-center" type="number" name="port" id="port" value="{{ random_port }}" required>
        <button type="button" onclick="document.getElementById('port').value=Math.floor(Math.random()*50000+10000)" class="px-3 rounded-xl bg-emerald-900/30 text-emerald-400 border border-emerald-700/50"><i class="fa-solid fa-shuffle"></i></button>
      </div></div>
  </div>

  <div class="glass rounded-3xl p-6 grid grid-cols-1 md:grid-cols-2 gap-4">
    <div><label class="block text-xs text-red-400/70 mb-2">انتقال (Network)</label>
      <select class="inp" name="network"><option value="tcp">TCP</option><option value="ws">WebSocket</option><option value="grpc">gRPC</option></select></div>
    <div><label class="block text-xs text-red-400/70 mb-2">Path / ServiceName</label>
      <input class="inp font-mono" name="path" value="/" dir="ltr"></div>
    <div class="md:col-span-2"><label class="block text-xs text-red-400/70 mb-2">امنیت</label>
      <select class="inp" name="security" id="sec">
        <option value="none">بدون امنیت</option>
        <option value="tls">TLS (نیازمند گواهی دامنه پنل)</option>
        <option value="reality">Reality</option>
      </select></div>
  </div>

  <div class="glass rounded-3xl p-6 grid grid-cols-1 md:grid-cols-3 gap-4">
    <div><label class="block text-xs text-red-400/70 mb-2">SNI / Server Name</label>
      <input class="inp font-mono" name="server_name" value="www.microsoft.com" dir="ltr">
      <div class="flex flex-wrap gap-1 mt-2">
        {% for d in ['www.microsoft.com','www.google.com','www.cloudflare.com','www.amazon.com'] %}
        <button type="button" class="text-[10px] px-2 py-1 rounded bg-gray-900/60 text-gray-300" onclick="document.querySelector('[name=server_name]').value='{{ d }}'">{{ d }}</button>
        {% endfor %}
      </div></div>
    <div><label class="block text-xs text-red-400/70 mb-2">Short ID (هگز، اختیاری)</label>
      <input class="inp font-mono" name="short_id" maxlength="16" dir="ltr" placeholder="مثلا 6ba85179"></div>
    <div><label class="block text-xs text-red-400/70 mb-2">Fingerprint</label>
      <select class="inp" name="fingerprint">
        {% for fp in fp_choices %}<option value="{{ fp }}">{{ fp }}</option>{% endfor %}
      </select></div>
  </div>

  <button type="submit" class="btn w-full py-4 rounded-2xl font-bold text-lg"><i class="fa-solid fa-circle-plus"></i> ساخت اینباند</button>
</form>
{% endblock %}
EOF

cat > "$PANEL/templates/clients.html" <<'EOF'
{% extends 'base.html' %}
{% block content %}
<div class="flex items-center justify-between mb-4">
  <h2 class="text-lg font-bold text-red-400"><i class="fa-solid fa-users"></i> کلاینت‌های {{ inbound.tag }} <span class="text-xs text-red-300/60">({{ inbound.protocol|upper }}:{{ inbound.port }})</span></h2>
  <a href="{{ url_for('inbounds_page') }}" class="text-sm text-red-300/70"><i class="fa-solid fa-arrow-right"></i> بازگشت</a>
</div>

{% if available %}
<form method="post" action="{{ url_for('clients_add', iid=inbound.id) }}" class="glass rounded-2xl p-4 mb-4">
  <h3 class="text-sm font-bold text-red-400 mb-3">افزودن کاربر به این اینباند</h3>
  <div class="grid grid-cols-2 md:grid-cols-4 gap-2 mb-3 max-h-48 overflow-y-auto">
    {% for u in available %}
    <label class="flex items-center gap-2 bg-black border border-red-900/30 p-2 rounded-xl cursor-pointer">
      <input type="checkbox" name="usernames" value="{{ u }}"><span class="text-xs text-red-300">{{ u }}</span>
    </label>
    {% endfor %}
  </div>
  <button class="btn px-5 py-2 rounded-xl text-xs font-bold">افزودن انتخاب‌شده‌ها</button>
</form>
{% endif %}

<div class="space-y-3">
{% for c in clients %}
  <div class="glass rounded-2xl p-4">
    <div class="flex items-center justify-between mb-3">
      <div class="flex items-center gap-2"><b class="text-red-400">{{ c.username }}</b>
        <span class="text-[10px] font-mono text-red-400/50">{{ c.uuid[:18] }}…</span></div>
      <form method="post" action="{{ url_for('client_delete', cid=c.id) }}" onsubmit="return confirm('حذف از این اینباند؟')">
        <button class="p-2 rounded-xl bg-red-900/30 text-red-400"><i class="fa-solid fa-trash"></i></button>
      </form>
    </div>
    <div class="flex gap-2">
      <code class="flex-1 bg-black border border-red-900/30 rounded-xl p-3 text-[11px] text-red-300 break-all" dir="ltr">{{ c.link }}</code>
      <button type="button" data-copy="{{ c.link }}" class="px-3 rounded-xl bg-blue-900/30 text-blue-400"><i class="fa-solid fa-copy"></i></button>
    </div>
  </div>
{% else %}
  <div class="glass rounded-2xl p-8 text-center text-gray-500">هیچ کلاینتی در این اینباند نیست</div>
{% endfor %}
</div>
{% endblock %}
EOF

cat > "$PANEL/templates/groups.html" <<'EOF'
{% extends 'base.html' %}
{% block content %}
<h2 class="text-lg font-bold text-red-400 mb-4"><i class="fa-solid fa-layer-group"></i> گروه‌ها</h2>
<form method="post" action="{{ url_for('group_new') }}" class="glass rounded-2xl p-4 mb-4 flex flex-col md:flex-row gap-3 items-end">
  <div class="flex-1 w-full"><label class="block text-xs text-red-400/70 mb-1">نام گروه</label><input class="inp" name="name" required></div>
  <div class="flex-1 w-full"><label class="block text-xs text-red-400/70 mb-1">توضیحات</label><input class="inp" name="description"></div>
  <button class="btn px-6 py-3 rounded-xl text-sm font-bold">ایجاد</button>
</form>
<div class="glass rounded-2xl overflow-x-auto">
<table class="tbl w-full text-right text-sm">
  <thead class="bg-black/50 text-red-400/70 text-xs"><tr><th>نام</th><th>توضیحات</th><th>اعضا</th><th class="text-center">عملیات</th></tr></thead>
  <tbody class="divide-y divide-red-900/20">
  {% for g in groups %}
    <tr class="hover:bg-red-900/10">
      <td class="font-bold text-red-400">{{ g.name }}</td>
      <td class="text-xs text-red-300/70">{{ g.description or '—' }}</td>
      <td><span class="px-3 py-1 rounded-lg bg-red-900/20 text-red-400 text-xs">{{ g.member_count }}</span></td>
      <td class="text-center">
        <div class="inline-flex gap-1.5">
          <a href="{{ url_for('group_members_page', gid=g.id) }}" class="p-2 rounded-xl bg-blue-900/20 text-blue-400"><i class="fa-solid fa-users"></i></a>
          <form method="post" action="{{ url_for('group_delete', gid=g.id) }}" onsubmit="return confirm('حذف گروه؟')">
            <button class="p-2 rounded-xl bg-red-900/30 text-red-400"><i class="fa-solid fa-trash"></i></button>
          </form>
        </div>
      </td>
    </tr>
  {% else %}
    <tr><td colspan="4" class="p-8 text-center text-gray-500">گروهی وجود ندارد</td></tr>
  {% endfor %}
  </tbody>
</table>
</div>
{% endblock %}
EOF

cat > "$PANEL/templates/group_members.html" <<'EOF'
{% extends 'base.html' %}
{% block content %}
<div class="flex items-center justify-between mb-4">
  <h2 class="text-lg font-bold text-red-400">اعضای گروه {{ group.name }}</h2>
  <a href="{{ url_for('groups_page') }}" class="text-sm text-red-300/70"><i class="fa-solid fa-arrow-right"></i> بازگشت</a>
</div>
{% if available %}
<form method="post" action="{{ url_for('group_add', gid=group.id) }}" class="glass rounded-2xl p-4 mb-4">
  <div class="grid grid-cols-2 md:grid-cols-4 gap-2 mb-3 max-h-48 overflow-y-auto">
    {% for u in available %}
    <label class="flex items-center gap-2 bg-black border border-red-900/30 p-2 rounded-xl cursor-pointer">
      <input type="checkbox" name="usernames" value="{{ u }}"><span class="text-xs text-red-300">{{ u }}</span>
    </label>
    {% endfor %}
  </div>
  <button class="btn px-5 py-2 rounded-xl text-xs font-bold">افزودن</button>
</form>
{% endif %}
<div class="glass rounded-2xl p-4 grid grid-cols-2 md:grid-cols-4 gap-2">
  {% for u in members %}
  <div class="flex items-center justify-between bg-black border border-red-900/30 p-3 rounded-xl">
    <span class="text-sm text-red-300">{{ u }}</span>
    <form method="post" action="{{ url_for('group_remove', gid=group.id, username=u) }}">
      <button class="text-red-400 text-xs"><i class="fa-solid fa-xmark"></i></button>
    </form>
  </div>
  {% else %}
  <p class="col-span-4 text-center text-gray-500 py-4">گروه خالی است</p>
  {% endfor %}
</div>
{% endblock %}
EOF

cat > "$PANEL/templates/reports.html" <<'EOF'
{% extends 'base.html' %}
{% block content %}
<h2 class="text-lg font-bold text-red-400 mb-4"><i class="fa-solid fa-chart-bar"></i> گزارش</h2>
<div class="grid grid-cols-2 md:grid-cols-4 gap-3">
  <div class="glass rounded-2xl p-5 text-center"><div class="text-[11px] text-gray-400 mb-1">کل کاربران</div><div class="text-2xl font-black text-red-400">{{ s.total_users }}</div></div>
  <div class="glass rounded-2xl p-5 text-center"><div class="text-[11px] text-gray-400 mb-1">کاربران فعال</div><div class="text-2xl font-black text-emerald-400">{{ s.active_users }}</div></div>
  <div class="glass rounded-2xl p-5 text-center"><div class="text-[11px] text-gray-400 mb-1">ظرفیت کل (GB)</div><div class="text-2xl font-black text-blue-400">{{ '%.2f'|format(s.total_gb) }}</div></div>
  <div class="glass rounded-2xl p-5 text-center"><div class="text-[11px] text-gray-400 mb-1">مصرف کل (GB)</div><div class="text-2xl font-black text-amber-400">{{ '%.2f'|format(s.used_gb) }}</div></div>
  <div class="glass rounded-2xl p-5 text-center"><div class="text-[11px] text-gray-400 mb-1">اینباند فعال</div><div class="text-2xl font-black text-purple-400">{{ ib }}</div></div>
  <div class="glass rounded-2xl p-5 text-center"><div class="text-[11px] text-gray-400 mb-1">کلاینت فعال</div><div class="text-2xl font-black text-purple-400">{{ cl }}</div></div>
</div>
{% endblock %}
EOF

cat > "$PANEL/templates/settings.html" <<'EOF'
{% extends 'base.html' %}
{% block content %}
<div class="grid grid-cols-1 lg:grid-cols-2 gap-6">

  <form method="post" action="{{ url_for('settings_save') }}" class="glass rounded-2xl p-6 space-y-4">
    <h3 class="text-lg font-bold text-red-400"><i class="fa-solid fa-sliders"></i> تنظیمات پنل</h3>
    <div><label class="block text-xs text-red-400/70 mb-1">دامنه / IP عمومی (برای لینک‌ها)</label>
      <input class="inp font-mono" name="domain" value="{{ s.domain }}" dir="ltr" placeholder="example.com"></div>
    <div class="grid grid-cols-2 gap-3">
      <div><label class="block text-xs text-red-400/70 mb-1">پورت پنل</label>
        <input class="inp font-mono" type="number" name="panel_port" value="{{ s.panel_port or 5000 }}"></div>
      <div><label class="block text-xs text-red-400/70 mb-1">نام کاربری ادمین</label>
        <input class="inp font-mono" name="admin_username" value="{{ s.admin_username }}" dir="ltr"></div>
    </div>
    <div><label class="block text-xs text-red-400/70 mb-1">کلمه عبور جدید (خالی = بدون تغییر)</label>
      <input class="inp font-mono" type="password" name="admin_password" dir="ltr" autocomplete="new-password"></div>
    <div><label class="block text-xs text-red-400/70 mb-1">دامنه SSL (برای TLS)</label>
      <input class="inp font-mono" name="ssl_domain" value="{{ s.ssl_domain }}" dir="ltr" placeholder="sub.example.com"></div>
    <label class="flex items-center gap-3 text-sm text-red-300">
      <input type="checkbox" name="block_iran" class="w-4 h-4" {% if s.block_iran == '1' %}checked{% endif %}>
      بلاک خروجی به IPهای ایران
    </label>
    <button class="btn w-full py-3 rounded-xl font-bold">ذخیره تنظیمات</button>
  </form>

  <div class="space-y-6">
    <div class="glass rounded-2xl p-6 space-y-3">
      <h3 class="text-lg font-bold text-red-400"><i class="fa-solid fa-certificate"></i> گواهی SSL</h3>
      <p class="text-xs text-gray-400">وضعیت: {% if cert %}<span class="text-emerald-400">گواهی موجود است</span>{% else %}<span class="text-amber-400">گواهی موجود نیست</span>{% endif %}</p>
      <form method="post" action="{{ url_for('settings_ssl') }}">
        <button class="px-4 py-2 rounded-xl bg-blue-900/30 text-blue-300 border border-blue-800/50 text-sm">دریافت گواهی (Let's Encrypt)</button>
      </form>
      <p class="text-[10px] text-gray-500">دامنه باید به IP این سرور اشاره کند و پورت ۸۰ در دسترس باشد.</p>
    </div>

    <div class="glass rounded-2xl p-6 space-y-3">
      <h3 class="text-lg font-bold text-red-400"><i class="fa-solid fa-key"></i> کلیدهای Reality</h3>
      <div><label class="block text-[10px] text-gray-400 mb-1">Public Key</label>
        <input class="inp font-mono text-xs" value="{{ s.reality_public_key }}" readonly dir="ltr"></div>
      <div><label class="block text-[10px] text-gray-400 mb-1">Private Key</label>
        <input class="inp font-mono text-xs" value="{{ s.reality_private_key }}" readonly dir="ltr"></div>
      <form method="post" action="{{ url_for('settings_keys') }}" onsubmit="return confirm('کلیدهای جدید ساخته شود؟ کلاینت‌ها باید کانفیگ جدید بگیرند.')">
        <button class="px-4 py-2 rounded-xl bg-red-900/30 text-red-400 border border-red-800/50 text-sm">تولید کلید جدید</button>
      </form>
    </div>

    <div class="glass rounded-2xl p-6 space-y-4">
      <h3 class="text-lg font-bold text-red-400"><i class="fa-solid fa-database"></i> پشتیبان‌گیری</h3>
      <a href="{{ url_for('backup_download') }}" class="block text-center btn py-2.5 rounded-xl font-bold"><i class="fa-solid fa-download"></i> دانلود بکاپ</a>
      <form method="post" action="{{ url_for('restore_upload') }}" enctype="multipart/form-data" class="space-y-3"
            onsubmit="return confirm('بازیابی، دیتای فعلی را جایگزین می‌کند. ادامه می‌دهید؟')">
        <input type="file" name="backup_file" accept=".db" required class="w-full text-xs text-gray-400 bg-black p-2 rounded-lg border border-red-900/30">
        <button class="w-full py-2.5 rounded-xl bg-amber-700 text-black font-bold text-sm"><i class="fa-solid fa-upload"></i> بازیابی بکاپ</button>
      </form>
    </div>
  </div>
</div>
{% endblock %}
EOF

cat > "$PANEL/templates/sub.html" <<'EOF'
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>اشتراک {{ username }} | OutlineParsian</title>
<script src="https://cdn.tailwindcss.com"></script>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
<link href="https://fonts.googleapis.com/css2?family=Vazirmatn:wght@400;700;900&display=swap" rel="stylesheet">
<style>
  *{font-family:'Vazirmatn',sans-serif}
  body{background:radial-gradient(circle at top,#1a0000 0%,#0a0a0a 60%);color:#fff;min-height:100vh}
  .card{background:rgba(20,0,0,.7);border:1px solid rgba(220,38,38,.15);border-radius:20px}
  .btn{background:linear-gradient(90deg,#b91c1c,#7f1d1d);color:#fee2e2;border:1px solid rgba(248,113,113,.3)}
</style>
</head>
<body class="p-4 md:p-8">
<div class="max-w-3xl mx-auto space-y-5">

  <div class="text-center">
    <div class="w-20 h-20 mx-auto rounded-3xl bg-gradient-to-br from-red-700 to-red-950 flex items-center justify-center text-3xl font-black mb-3">OP</div>
    <h1 class="text-2xl font-bold text-red-400">{{ username }}</h1>
    <div class="flex justify-center gap-3 mt-2 text-xs text-red-300/70 flex-wrap">
      <span><i class="fa-solid fa-calendar"></i> {{ u.expire_date }}</span>
      <span>•</span>
      <span class="{{ 'text-emerald-400' if u.status == 1 else 'text-red-400' }}">{{ 'فعال' if u.status == 1 else 'غیرفعال' }}</span>
      <span>•</span>
      <span><i class="fa-solid fa-hourglass-half"></i> {{ days_left }} روز مانده</span>
    </div>
  </div>

  <div class="card p-5">
    <div class="grid grid-cols-3 gap-3 text-center mb-4">
      <div class="bg-black/40 rounded-xl p-3"><p class="text-[10px] text-blue-300/70">حجم کل</p><p class="text-lg font-black text-blue-400">{{ total_gb if total_gb else '∞' }}<span class="text-xs"> GB</span></p></div>
      <div class="bg-black/40 rounded-xl p-3"><p class="text-[10px] text-amber-300/70">مصرف شده</p><p class="text-lg font-black text-amber-400">{{ used_gb }}<span class="text-xs"> GB</span></p></div>
      <div class="bg-black/40 rounded-xl p-3"><p class="text-[10px] text-emerald-300/70">باقی‌مانده</p><p class="text-lg font-black text-emerald-400">{{ remain_gb if remain_gb is not none else '∞' }}<span class="text-xs"> GB</span></p></div>
    </div>
    <div class="w-full bg-red-900/20 h-2.5 rounded-full overflow-hidden">
      <div class="h-full bg-gradient-to-r from-red-600 to-red-400 rounded-full" style="width: {{ pct }}%"></div>
    </div>
    <div class="text-[10px] text-red-400/60 mt-1 text-left" dir="ltr">{{ pct }}%</div>
  </div>

  <div class="card p-5">
    <h3 class="text-sm font-bold text-emerald-400 mb-3"><i class="fa-solid fa-terminal"></i> اتصال SSH</h3>
    <div class="flex flex-col md:flex-row gap-4 items-center">
      <div class="flex-1 w-full">
        <div class="bg-black/50 rounded-xl p-4 font-mono text-xs text-emerald-300 break-all border border-emerald-900/30" dir="ltr">{{ ssh_uri }}</div>
        <div class="grid grid-cols-3 gap-2 mt-3 text-center text-[11px]">
          <div class="bg-black/30 rounded-lg p-2"><p class="text-emerald-400/60">Host</p><p class="font-mono text-emerald-400">{{ dom }}</p></div>
          <div class="bg-black/30 rounded-lg p-2"><p class="text-emerald-400/60">Port</p><p class="font-mono text-emerald-400">22</p></div>
          <div class="bg-black/30 rounded-lg p-2"><p class="text-emerald-400/60">User</p><p class="font-mono text-emerald-400">{{ username }}</p></div>
        </div>
        <button type="button" data-copy="{{ ssh_uri }}" class="btn mt-3 w-full py-2 rounded-xl text-xs font-bold"><i class="fa-solid fa-copy"></i> کپی</button>
      </div>
      {% if ssh_qr %}<img src="data:image/png;base64,{{ ssh_qr }}" class="w-32 h-32 bg-white p-1 rounded-xl">{% endif %}
    </div>
  </div>

  <div class="space-y-3">
    <h3 class="text-sm font-bold text-purple-400"><i class="fa-solid fa-bolt"></i> کانفیگ‌های V2Ray ({{ configs|length }})</h3>
    {% for c in configs %}
    <div class="card p-5">
      <div class="flex flex-wrap items-center gap-2 mb-3">
        <span class="text-[11px] px-2 py-0.5 rounded-full bg-blue-900/30 text-blue-300">{{ c.protocol|upper }}</span>
        <span class="text-[10px] font-mono text-gray-400">{{ c.tag }}:{{ c.port }}</span>
        {% if c.sec != 'none' %}<span class="text-[10px] px-2 py-0.5 rounded-full bg-emerald-900/30 text-emerald-300">{{ c.sec|upper }}</span>{% endif %}
        {% if c.net != 'tcp' %}<span class="text-[10px] px-2 py-0.5 rounded-full bg-gray-800 text-gray-300">{{ c.net|upper }}</span>{% endif %}
      </div>
      <div class="flex flex-col md:flex-row gap-4">
        <div class="flex-1 min-w-0">
          <div class="bg-black/50 rounded-xl p-3 font-mono text-[10px] text-gray-300 break-all border border-red-900/30" dir="ltr">{{ c.link }}</div>
          <div class="flex flex-wrap gap-2 mt-3">
            <button type="button" data-copy="{{ c.link }}" class="btn px-3 py-1.5 rounded-lg text-xs"><i class="fa-solid fa-copy"></i> کپی</button>
            <a href="{{ url_for('download_config', kind='nepster', username=username, idx=loop.index0) }}" class="px-3 py-1.5 rounded-lg text-xs bg-red-900/20 text-red-300 border border-red-800/30"><i class="fa-solid fa-file-arrow-down"></i> Nepster</a>
            <a href="{{ url_for('download_config', kind='netmod', username=username, idx=loop.index0) }}" class="px-3 py-1.5 rounded-lg text-xs bg-red-900/20 text-red-300 border border-red-800/30"><i class="fa-solid fa-file-code"></i> NetMod</a>
          </div>
        </div>
        {% if c.qr %}<img src="data:image/png;base64,{{ c.qr }}" class="w-28 h-28 bg-white p-1 rounded-xl mx-auto">{% endif %}
      </div>
    </div>
    {% else %}
    <div class="card p-8 text-center text-red-300/60 text-sm">هیچ کانفیگ V2Ray برای شما تنظیم نشده است</div>
    {% endfor %}
  </div>

  <div class="text-center text-[10px] text-red-900/80 mt-6">Powered by OutlineParsian v3.8</div>
</div>
<script>
function toast(m){const d=document.createElement('div');d.textContent=m;d.className='fixed top-5 left-1/2 -translate-x-1/2 bg-emerald-600 text-white px-5 py-2 rounded-full text-sm z-50';document.body.appendChild(d);setTimeout(()=>d.remove(),1500);}
function copyText(t){
  if(navigator.clipboard && window.isSecureContext){navigator.clipboard.writeText(t).then(()=>toast('کپی شد'));}
  else{const a=document.createElement('textarea');a.value=t;document.body.appendChild(a);a.select();document.execCommand('copy');a.remove();toast('کپی شد');}
}
document.addEventListener('click',e=>{const b=e.target.closest('[data-copy]');if(b)copyText(b.dataset.copy);});
</script>
</body>
</html>
EOF
ok "panel files written"

# ---------------------------------------------------------------------
step "7/9" "Iran block script, systemd services, nginx"
cat > /usr/local/bin/iran-block.sh <<'EOF'
#!/bin/bash
# Blocks OUTPUT traffic to Iranian IP ranges (ipdeny list). Inbound is not touched.
IPSET_NAME="iran_ips"
case "$1" in
  enable)
    ipset create $IPSET_NAME hash:net maxelem 200000 2>/dev/null
    curl -fsSL https://www.ipdeny.com/ipblocks/data/countries/ir.zone -o /tmp/ir.zone
    if [ -s /tmp/ir.zone ]; then
      ipset flush $IPSET_NAME 2>/dev/null
      while read -r line; do [ -n "$line" ] && ipset add $IPSET_NAME "$line" 2>/dev/null; done < /tmp/ir.zone
    fi
    iptables -C OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
      iptables -I OUTPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -C OUTPUT -m set --match-set $IPSET_NAME dst -j DROP 2>/dev/null || \
      iptables -A OUTPUT -m set --match-set $IPSET_NAME dst -j DROP
    netfilter-persistent save 2>/dev/null ;;
  disable)
    while iptables -D OUTPUT -m set --match-set $IPSET_NAME dst -j DROP 2>/dev/null; do :; done
    netfilter-persistent save 2>/dev/null ;;
  *) echo "Usage: $0 enable|disable"; exit 1 ;;
esac
EOF
chmod +x /usr/local/bin/iran-block.sh

cat > /etc/systemd/system/ssh-panel.service <<'EOF'
[Unit]
Description=OutlineParsian Panel
After=network.target xray.service

[Service]
Type=simple
User=root
WorkingDirectory=/root/ssh-panel
ExecStart=/usr/bin/python3 /root/ssh-panel/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/ssh-panel-collector.service <<'EOF'
[Unit]
Description=OutlineParsian Collector (traffic, online, limits)
After=network.target xray.service ssh.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /root/ssh-panel/collector.py
Restart=always
RestartSec=5
Nice=10
CPUQuota=25%
MemoryMax=200M

[Install]
WantedBy=multi-user.target
EOF

ok "systemd units written"

# nginx: port from DB
PP=$(sqlite3 "$PANEL/panel.db" "SELECT value FROM settings WHERE key='panel_port'" 2>/dev/null)
PP=${PP:-5000}
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/op-panel <<EOF
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 100M;
    location / {
        proxy_pass http://127.0.0.1:${PP};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }
}
EOF
ln -sf /etc/nginx/sites-available/op-panel /etc/nginx/sites-enabled/op-panel
nginx -t >/dev/null 2>&1 && ok "nginx config ok" || warn "nginx config test failed"

# ---------------------------------------------------------------------
step "8/9" "Xray config, start services"
rm -f /etc/systemd/system/ssh-panel-worker.service /etc/systemd/system/ssh-panel-ip-manager.service 2>/dev/null
systemctl daemon-reload
python3 "$SYNC" || warn "Xray config not applied (see message above)"
systemctl enable xray ssh-panel ssh-panel-collector nginx 2>/dev/null
systemctl restart xray ssh-panel-collector ssh-panel nginx
sleep 4
# Apply Iran block according to saved setting (panel also does this on start)
[ "$(sqlite3 "$PANEL/panel.db" "SELECT value FROM settings WHERE key='block_iran'")" = "1" ] \
  && /usr/local/bin/iran-block.sh enable >/dev/null 2>&1
ok "services started"

# ---------------------------------------------------------------------
step "9/9" "Health check"
for svc in xray ssh-panel ssh-panel-collector nginx ssh; do
  if systemctl is-active --quiet "$svc" 2>/dev/null || systemctl is-active --quiet "${svc/ssh/sshd}" 2>/dev/null; then
    ok "$svc"
  else
    warn "$svc is NOT active"
    journalctl -u "$svc" -n 5 --no-pager 2>/dev/null | tail -5
  fi
done

IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
PANEL_PORT=$(sqlite3 "$PANEL/panel.db" "SELECT value FROM settings WHERE key='panel_port'" 2>/dev/null)
echo ""
echo "=============================================================="
echo " OutlineParsian Panel v3.8 installed"
echo "  Panel:  http://${IP}/        (direct: http://${IP}:${PANEL_PORT:-5000})"
if [ -f "$PANEL/admin.txt" ]; then
  echo "  Admin credentials are in: $PANEL/admin.txt"
else
  echo "  Admin: existing credentials kept (change in Settings if still admin123)"
fi
echo "  Backup of previous install: $BK"
echo "=============================================================="
