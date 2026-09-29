#!/bin/bash
# ============================================================
#   OutlineParsian Ultimate Panel v4.1
#   Full Bug-Fix Release | SSH + Xray Traffic
#   Accurate PER-USER Online | Limiter | Auto-Expire
#   Self-verifying installer (detects corrupted paste)
# ============================================================

clear
cat << "BANNER"
  ____  _    _ _   _     _     ___  ____   ____   _    ____ ____  _    ____ _   _
 / __ \| |  | | \ | |   | |   / _ \|  _ \ / ___| | |  / ___| _ \/ \  / ___| \ | |
| |  | | |  | |  \| |   | | | | | | |_) | |     | | | |   | |_) / _ \ \___ \  \| |
| |  | | |  | | . ` |   | |  | | | |  __/| |___  | | | |___|  _ < ___ \ ___) | |\  |
| |__| | |__| | |\  |   | |__| |_| | |    \____| | |  \____|_| \_\   \_\____/|_| \_|
 \____/ \____/|_| \_| |_____\___/|_|          |_|
   Ultimate Panel v4.1 — All 24+ bugs fixed
BANNER

echo ""
echo "=========================================================="
echo "  OutlineParsian Ultimate Panel v4.1"
echo "  Per-user online isolation | Traffic accounting | Limiter"
echo "=========================================================="
echo ""

die() { echo ""; echo "❌ نصب متوقف شد: $1"; exit 1; }
verify_py() {
  if python3 -m py_compile "$1" 2>/tmp/verify_err.txt; then
    echo "  ✓ $1 : سالم و کامل"
  else
    echo "  ✗ $1 : خراب/ناقص است! خطا:"
    cat /tmp/verify_err.txt
    die "فایل $1 را دوباره paste کنید (کپی ناقص)"
  fi
}

# ============================================
# [1/14] Prerequisites
# ============================================
echo "[1/14] Installing prerequisites..."
apt update -y || true
apt install -y python3 python3-pip python3-venv ipset iptables curl \
    netfilter-persistent iptables-persistent unzip wget sqlite3 net-tools jq \
    certbot python3-certbot-nginx qrencode openssh-server iproute2 procps 2>/dev/null
pip3 install flask psutil requests grpcio grpcio-tools protobuf qrcode[pil] \
    --break-system-packages 2>/dev/null || \
pip3 install flask psutil requests grpcio grpcio-tools protobuf qrcode[pil] 2>/dev/null
command -v python3 >/dev/null || die "python3 نصب نشد"
python3 -c "import flask" 2>/dev/null || die "flask نصب نشد — pip3 install flask را دستی اجرا کنید"
echo "✓ Prerequisites installed"

# ============================================
# [2/14] SSH Configuration
# ============================================
echo "[2/14] Configuring SSH..."
cat << 'SSHCONF' > /etc/ssh/sshd_config
Port 22
PermitRootLogin yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
AllowTcpForwarding yes
GatewayPorts yes
MaxStartups 10:30:60
MaxSessions 10
SSHCONF
systemctl enable ssh
systemctl restart ssh
iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 22 -j ACCEPT
echo "✓ SSH configured"

# ============================================
# [3/14] Directory Structure
# ============================================
echo "[3/14] Creating directories..."
mkdir -p /root/ssh-panel/templates /root/ssh-panel/static \
         /root/ssh-panel/downloads /root/ssh-panel/backups /root/ssh-panel/grpc_proto \
         /usr/local/etc/xray /var/log/xray
touch /tmp/xray_access.log /tmp/xray_error.log /var/log/panel.log /tmp/worker.log
chmod 666 /tmp/xray_access.log /tmp/xray_error.log /var/log/panel.log /tmp/worker.log
echo "✓ Directories created"

# ============================================
# [4/14] Xray Core + gRPC proto
# ============================================
echo "[4/14] Installing Xray Core..."
if ! command -v xray >/dev/null 2>&1 && [ ! -f /usr/local/bin/xray ]; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
        || die "نصب Xray ناموفق بود (اینترنت را چک کنید)"
fi
systemctl enable xray 2>/dev/null

cat << 'PROTOEOF' > /root/ssh-panel/grpc_proto/stats.proto
syntax = "proto3";
package xray.app.stats.command;
message QueryStatsRequest { string pattern = 1; bool reset = 2; }
message Stat { string name = 1; int64 value = 2; }
message QueryStatsResponse { repeated Stat stat = 1; }
service StatsService { rpc QueryStats(QueryStatsRequest) returns (QueryStatsResponse); }
PROTOEOF

cd /root/ssh-panel/grpc_proto && \
python3 -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. stats.proto \
    && echo "  ✓ gRPC proto compiled" \
    || echo "  ⚠ proto compile نشد — ترافیک Xray ثبت نمی‌شود (بقیه کار می‌کند)"
cd /root
echo "✓ Xray Core installed"

# ============================================
# [5/14] Database (non-destructive: migration)
# ============================================
echo "[5/14] Initializing database..."
python3 << 'PYEOF'
import sqlite3, secrets
DB = '/root/ssh-panel/panel.db'
conn = sqlite3.connect(DB)
conn.execute('PRAGMA journal_mode=WAL')
conn.execute('PRAGMA foreign_keys=ON')
c = conn.cursor()
c.execute('''CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, password TEXT,
    expire_date TEXT, total_traffic REAL, used_traffic REAL DEFAULT 0.0,
    status INTEGER DEFAULT 1, max_connections INTEGER DEFAULT 2, created_at TEXT,
    sub_token TEXT)''')
c.execute('''CREATE TABLE IF NOT EXISTS xray_inbounds (id INTEGER PRIMARY KEY AUTOINCREMENT,
    tag TEXT UNIQUE, protocol TEXT, port INTEGER, network TEXT DEFAULT 'tcp',
    security TEXT DEFAULT 'none', server_name TEXT DEFAULT '', fingerprint TEXT DEFAULT 'chrome',
    short_id TEXT DEFAULT '', public_key TEXT DEFAULT '', private_key TEXT DEFAULT '',
    path TEXT DEFAULT '/', status INTEGER DEFAULT 1, created_at TEXT)''')
c.execute('''CREATE TABLE IF NOT EXISTS xray_clients (id INTEGER PRIMARY KEY AUTOINCREMENT,
    inbound_id INTEGER, username TEXT, uuid TEXT, email TEXT, enable INTEGER DEFAULT 1, created_at TEXT,
    FOREIGN KEY (inbound_id) REFERENCES xray_inbounds(id) ON DELETE CASCADE,
    FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE)''')
c.execute('''CREATE TABLE IF NOT EXISTS user_groups (id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE, description TEXT, created_at TEXT)''')
c.execute('''CREATE TABLE IF NOT EXISTS group_members (id INTEGER PRIMARY KEY AUTOINCREMENT,
    group_id INTEGER, username TEXT,
    FOREIGN KEY (group_id) REFERENCES user_groups(id) ON DELETE CASCADE,
    FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE)''')
c.execute('CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)')
for k, v in [('domain',''),('admin_username','admin'),('admin_password','admin123'),
             ('block_iran_client','0'),('panel_port','5000'),
             ('reality_public_key',''),('reality_private_key',''),
             ('ssl_domain',''),('ssl_status','none')]:
    c.execute('INSERT OR IGNORE INTO settings (key,value) VALUES (?,?)', (k, v))
cols = [r[1] for r in c.execute('PRAGMA table_info(users)')]
if 'sub_token' not in cols:
    c.execute('ALTER TABLE users ADD COLUMN sub_token TEXT')
for (un,) in c.execute('SELECT username FROM users').fetchall():
    c.execute('SELECT sub_token FROM users WHERE username=?', (un,))
    if not c.fetchone()[0]:
        c.execute('UPDATE users SET sub_token=? WHERE username=?', (secrets.token_urlsafe(16), un))
c.execute('CREATE INDEX IF NOT EXISTS idx_clients_inbound ON xray_clients(inbound_id)')
c.execute('CREATE INDEX IF NOT EXISTS idx_clients_username ON xray_clients(username)')
conn.commit(); conn.close()
print('✓ Database ready')
PYEOF
[ $? -eq 0 ] || die "خطای دیتابیس"

# ============================================
# [6/14] sync_xray.py
# ============================================
echo "[6/14] Creating Xray sync script..."
cat << 'EOFSYNC' > /root/ssh-panel/sync_xray.py
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sqlite3, json, os, subprocess, logging, fcntl

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s',
                    handlers=[logging.FileHandler('/var/log/panel.log')])
log = logging.getLogger('sync')

DB_PATH = '/root/ssh-panel/panel.db'
XRAY_CONFIG = '/usr/local/etc/xray/config.json'
XRAY_BIN = '/usr/local/bin/xray'

def get_setting(c, key, default=''):
    c.execute("SELECT value FROM settings WHERE key=?", (key,))
    r = c.fetchone()
    return r[0] if r else default

def generate():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    ssl_domain = get_setting(c, 'ssl_domain')
    cert = f'/etc/letsencrypt/live/{ssl_domain}/fullchain.pem' if ssl_domain else ''
    keyf = f'/etc/letsencrypt/live/{ssl_domain}/privkey.pem' if ssl_domain else ''
    have_certs = bool(ssl_domain and os.path.exists(cert) and os.path.exists(keyf))

    inbounds = [{
        "tag": "api", "listen": "127.0.0.1", "port": 10085,
        "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}
    }]
    tags = []
    for ib in map(dict, c.execute("SELECT * FROM xray_inbounds WHERE status=1").fetchall()):
        c.execute("""SELECT cl.username, cl.uuid, cl.email FROM xray_clients cl
                     JOIN users u ON cl.username=u.username
                     WHERE cl.inbound_id=? AND cl.enable=1 AND u.status=1""", (ib['id'],))
        clients = list(map(dict, c.fetchall()))
        if not clients:
            continue
        sec = ib.get('security') or 'none'
        if sec == 'tls' and not have_certs:
            log.error("inbound %s: tls بدون گواهی معتبر -> skip", ib['tag'])
            continue
        e = {"tag": ib['tag'], "port": ib['port'], "protocol": ib['protocol'],
             "settings": {"clients": []},
             "streamSettings": {"network": ib.get('network') or 'tcp'}}
        if sec != 'none':
            e["streamSettings"]["security"] = sec
        for cl in clients:
            email = cl.get('email') or cl['username']
            if ib['protocol'] == 'trojan':
                obj = {"password": cl['uuid'], "email": email}
            else:
                obj = {"id": cl['uuid'], "email": email}
                if sec == 'reality' and ib['protocol'] == 'vless':
                    obj["flow"] = "xtls-rprx-vision"
            e["settings"]["clients"].append(obj)
        if ib['protocol'] == 'vless':
            e["settings"]["decryption"] = "none"
        if sec == 'reality':
            priv = ib.get('private_key') or get_setting(c, 'reality_private_key')
            sn = ib.get('server_name') or 'www.microsoft.com'
            sid = ib.get('short_id') or ''
            e["streamSettings"]["realitySettings"] = {
                "dest": f"{sn}:443", "serverNames": [sn], "privateKey": priv,
                "shortIds": [sid] if sid else [""]}
        elif sec == 'tls':
            e["streamSettings"]["tlsSettings"] = {
                "serverName": ssl_domain or ib.get('server_name', ''),
                "certificates": [{"certificateFile": cert, "keyFile": keyf}]}
        path = ib.get('path') or '/'
        if ib.get('network') == 'ws':
            e["streamSettings"]["wsSettings"] = {"path": path}
        elif ib.get('network') == 'grpc':
            e["streamSettings"]["grpcSettings"] = {"serviceName": path.strip('/') or 'grpc'}
        inbounds.append(e)
        tags.append(ib['tag'])
    conn.close()

    rules = [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}]
    if tags:
        rules.append({"type": "field", "inboundTag": tags, "outboundTag": "direct"})
    return {
        "log": {"loglevel": "info", "access": "/tmp/xray_access.log",
                "error": "/tmp/xray_error.log"},
        "inbounds": inbounds,
        "outbounds": [{"protocol": "freedom", "tag": "direct"},
                      {"protocol": "blackhole", "tag": "block"}],
        "routing": {"rules": rules},
        "stats": {},
        "api": {"tag": "api", "services": ["StatsService"]},
        "policy": {"system": {"statsInboundUplink": True, "statsInboundDownlink": True,
                              "statsOutboundUplink": True, "statsOutboundDownlink": True},
                   "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}}}
    }

def test_config(path):
    for cmd in ([XRAY_BIN, 'run', '-test', '-c', path], [XRAY_BIN, '-test', '-c', path]):
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=20)
        except Exception:
            continue
        out = ((r.stderr or b'') + (r.stdout or b'')).decode(errors='replace')
        if 'flag provided but not defined' in out or 'unknown command' in out.lower():
            continue
        return r.returncode == 0, out
    return True, 'validation skipped'

def main():
    with open('/tmp/xray_sync.lock', 'w') as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        new = json.dumps(generate(), indent=2)
        try:
            with open(XRAY_CONFIG) as f:
                if f.read() == new:
                    return
        except Exception:
            pass
        tmp = XRAY_CONFIG + '.tmp'
        with open(tmp, 'w') as f:
            f.write(new)
        ok, out = test_config(tmp)
        if not ok:
            log.error("کانفیگ نامعتبر؛ ری‌استارت انجام نشد:\n%s", out[-1200:])
            try:
                os.remove(tmp)
            except Exception:
                pass
            return
        os.replace(tmp, XRAY_CONFIG)
        subprocess.run(['systemctl', 'restart', 'xray'], timeout=30)
        log.info("xray restarted")

if __name__ == '__main__':
    main()
EOFSYNC
chmod +x /root/ssh-panel/sync_xray.py
verify_py /root/ssh-panel/sync_xray.py

# ============================================
# [7/14] app.py
# ============================================
echo "[7/14] Creating panel application..."
cat << 'EOFAPP' > /root/ssh-panel/app.py
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, re, sqlite3, subprocess, time, json, uuid, base64, secrets, hmac
import shutil, threading, traceback, random, logging
from datetime import datetime, timedelta
from flask import (Flask, render_template_string, request, redirect, url_for, session,
                   send_file, flash, Response, jsonify)
try:
    import psutil
    HAS_PSUTIL = True
except Exception:
    HAS_PSUTIL = False

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s',
                    handlers=[logging.FileHandler('/var/log/panel.log'), logging.StreamHandler()])
logger = logging.getLogger('OP')

app = Flask(__name__)
DB_PATH = '/root/ssh-panel/panel.db'
TEMPLATES_DIR = '/root/ssh-panel/templates'
XRAY_BIN = '/usr/local/bin/xray'
DOWNLOADS_DIR = '/root/ssh-panel/downloads'
ONLINE_FILE = '/tmp/online_users.json'
SECRET_FILE = '/root/ssh-panel/.secret_key'

if os.path.exists(SECRET_FILE) and open(SECRET_FILE).read().strip():
    app.secret_key = open(SECRET_FILE).read().strip()
else:
    _k = secrets.token_hex(32)
    with open(SECRET_FILE, 'w') as f:
        f.write(_k)
    try:
        os.chmod(SECRET_FILE, 0o600)
    except Exception:
        pass
    app.secret_key = _k

os.makedirs(DOWNLOADS_DIR, exist_ok=True)

system_stats = {'cpu': 0, 'ram': 0, 'last_update': 0}

def _stats_loop():
    global system_stats
    while True:
        try:
            if HAS_PSUTIL:
                system_stats = {'cpu': psutil.cpu_percent(interval=1),
                                'ram': psutil.virtual_memory().percent,
                                'last_update': time.time()}
        except Exception:
            pass
        time.sleep(2)

threading.Thread(target=_stats_loop, daemon=True).start()
def get_cpu(): return system_stats.get('cpu', 0)
def get_ram(): return system_stats.get('ram', 0)

USERNAME_RE = re.compile(r'^[a-z][a-z0-9_-]{2,31})
RESERVED = {'root','admin','administrator','sshd','daemon','bin','sys','sync','games','man',
            'lp','mail','news','uucp','proxy','www-data','backup','list','irc','gnats',
            'nobody','systemd-network','systemd-resolve','messagebus','mysql','postgres',
            'ubuntu','debian','operator','sshd-session'}

def safe_float(v, d=0):
    try:
        return float(v)
    except Exception:
        return d

def safe_int(v, d=0):
    try:
        return int(v)
    except Exception:
        return d

def run_command(cmd):
    try:
        return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    except Exception:
        return None

def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.row_factory = sqlite3.Row
    return conn

def get_setting(key):
    conn = get_db()
    try:
        r = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return r['value'] if r else ""
    finally:
        conn.close()

def set_setting(key, value):
    conn = get_db()
    try:
        conn.execute("INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)", (key, value))
        conn.commit()
    finally:
        conn.close()

def get_panel_port():
    p = get_setting('panel_port')
    return int(p) if p and p.isdigit() and 1024 <= int(p) <= 65535 else 5000

def ensure_schema():
    conn = get_db()
    try:
        c = conn.cursor()
        for ddl in [
            "CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, password TEXT, expire_date TEXT, total_traffic REAL, used_traffic REAL DEFAULT 0.0, status INTEGER DEFAULT 1, max_connections INTEGER DEFAULT 2, created_at TEXT, sub_token TEXT)",
            "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)",
            "CREATE INDEX IF NOT EXISTS idx_clients_inbound ON xray_clients(inbound_id)",
            "CREATE INDEX IF NOT EXISTS idx_clients_username ON xray_clients(username)"]:
            c.execute(ddl)
        for k, v in [('domain',''),('admin_username','admin'),('admin_password','admin123'),
                     ('block_iran_client','0'),('panel_port','5000'),
                     ('reality_public_key',''),('reality_private_key',''),
                     ('ssl_domain',''),('ssl_status','none')]:
            c.execute("INSERT OR IGNORE INTO settings (key,value) VALUES (?,?)", (k, v))
        cols = [r[1] for r in c.execute('PRAGMA table_info(users)')]
        if 'sub_token' not in cols:
            c.execute('ALTER TABLE users ADD COLUMN sub_token TEXT')
        for r in c.execute('SELECT username, sub_token FROM users').fetchall():
            if not r['sub_token']:
                c.execute('UPDATE users SET sub_token=? WHERE username=?',
                          (secrets.token_urlsafe(16), r['username']))
        conn.commit()
    finally:
        conn.close()

def get_random_port():
    used = set()
    try:
        out = subprocess.run(['ss', '-tlnH'], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, timeout=5).stdout.decode()
        used = {int(m) for m in re.findall(r':(\d+)\s', out)}
    except Exception:
        pass
    conn = get_db()
    try:
        db_ports = {r['port'] for r in conn.execute("SELECT port FROM xray_inbounds").fetchall()}
    finally:
        conn.close()
    for _ in range(200):
        p = random.randint(20000, 60000)
        if p not in used and p not in db_ports:
            return p
    return random.randint(20000, 60000)

def get_online_users():
    data = None
    for _ in range(3):
        try:
            with open(ONLINE_FILE) as f:
                data = json.load(f)
            break
        except Exception:
            time.sleep(0.05)
    if not isinstance(data, dict):
        return {}
    now = time.time()
    online = {}
    for u, info in (data.get('users') or {}).items():
        try:
            if now - float(info.get('ts', 0)) > 60:
                continue
            ssh_count = safe_int(info.get('ssh', 0))
            is_xray = bool(info.get('xray'))
            xray_ips = safe_int(info.get('xray_ips', 0))
            if ssh_count <= 0 and not is_xray:
                continue
            online[u] = {'ssh': ssh_count > 0, 'xray': is_xray,
                         'ssh_count': ssh_count, 'xray_ips': xray_ips,
                         'is_online': True, 'online_count': ssh_count + xray_ips,
                         'over_limit': bool(info.get('over_limit', False))}
        except Exception:
            continue
    return online

def create_system_user(username, password):
    try:
        r = subprocess.run(['id', username], capture_output=True, timeout=5)
        if r.returncode != 0:
            subprocess.run(['useradd', '-m', '-s', '/bin/bash', username],
                           check=True, timeout=10)
        if password:
            p = subprocess.run(['chpasswd'],
                               input=f"{username}:{password}".encode(),
                               capture_output=True, timeout=5)
            if p.returncode != 0:
                return False
        return True
    except Exception as e:
        logger.error("create_system_user(%s): %s", username, e)
        return False

def _user_token(username):
    conn = get_db()
    try:
        r = conn.execute('SELECT sub_token FROM users WHERE username=?', (username,)).fetchone()
        if r and r['sub_token']:
            return r['sub_token']
        tok = secrets.token_urlsafe(16)
        conn.execute('UPDATE users SET sub_token=? WHERE username=?', (tok, username))
        conn.commit()
        return tok
    finally:
        conn.close()

def _token_ok(username):
    tok = request.args.get('token', '')
    real = _user_token(username) or ''
    return bool(tok) and hmac.compare_digest(tok, real)

def generate_qr_base64(data):
    try:
        import qrcode
        from io import BytesIO
        qr = qrcode.QRCode(version=1, box_size=10, border=2)
        qr.add_data(data)
        qr.make(fit=True)
        img = qr.make_image(fill_color="black", back_color="white")
        buf = BytesIO()
        img.save(buf, format="PNG")
        return base64.b64encode(buf.getvalue()).decode()
    except Exception:
        try:
            r = subprocess.run(['qrencode', '-o', '-', data],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            return base64.b64encode(r.stdout).decode()
        except Exception:
            return ""

def sync_xray():
    subprocess.run(["python3", "/root/ssh-panel/sync_xray.py"], timeout=40)

def gen_link(proto, uid, dom, port, net, sec, sni, fp, sid, pub, path, user):
    if proto == 'vless':
        l = f"vless://{uid}@{dom}:{port}?type={net}&security={sec}&encryption=none"
        if sec == 'reality':
            l += f"&fp={fp}&sni={sni}&pbk={pub}&flow=xtls-rprx-vision&sid={sid}"
        if net == 'ws':
            l += f"&path={path}"
        l += f"#OP-{user}"
    elif proto == 'vmess':
        cnf = {"v": "2", "ps": f"OP-{user}", "add": dom, "port": str(port), "id": uid,
               "aid": "0", "net": net, "type": "none", "host": "",
               "path": path if net == 'ws' else "",
               "tls": "tls" if sec in ('tls', 'reality') else "none"}
        if sec == "reality":
            cnf["security"] = "reality"
            cnf["flow"] = "xtls-rprx-vision"
            cnf["sni"] = sni
            cnf["fp"] = fp
            cnf["pbk"] = pub
            cnf["sid"] = sid
        l = "vmess://" + base64.b64encode(json.dumps(cnf).encode()).decode()
    elif proto == 'trojan':
        l = f"trojan://{uid}@{dom}:{port}?security={sec}&type={net}"
        if sec == 'reality':
            l += f"&sni={sni}&flow=xtls-rprx-vision"
        l += f"#OP-{user}"
    else:
        l = f"{proto}://{uid}@{dom}:{port}#OP-{user}"
    return l

def generate_nepster_config(protocol, uuid_, domain, port, network, security, sni, fp,
                           sid, pub_key, path, username):
    return json.dumps({"config_version": "1.0", "name": f"OP-{username}", "type": protocol,
        "server": domain, "port": port, "uuid": uuid_, "network": network,
        "security": security, "sni": sni, "fp": fp, "sid": sid, "pbk": pub_key,
        "path": path, "flow": "xtls-rprx-vision" if security == "reality" else ""}, indent=2)

def generate_netmod_config(protocol, uuid_, domain, port, network, security, sni, fp,
                           sid, pub_key, path, username):
    return json.dumps({"name": f"OP-{username}", "type": protocol, "server": domain,
        "port": port, "uuid": uuid_, "network": network,
        "tls": security if security != "none" else "none", "sni": sni, "fingerprint": fp,
        "shortId": sid, "publicKey": pub_key, "path": path,
        "flow": "xtls-rprx-vision" if security == "reality" else "none"}, indent=2)

def sync_users_from_db():
    conn = get_db()
    try:
        for u in conn.execute("SELECT username, password FROM users WHERE username != 'root'").fetchall():
            if u['username'] in RESERVED:
                continue
            create_system_user(u['username'], u['password'])
    except Exception as e:
        logger.error("sync users: %s", e)
    finally:
        conn.close()

def apply_iran_block():
    try:
        if get_setting('block_iran_client') == '1':
            subprocess.run(['/usr/local/bin/iran-block.sh', 'enable'], timeout=60)
        else:
            subprocess.run(['/usr/local/bin/iran-block.sh', 'disable'], timeout=30)
    except Exception as e:
        logger.error("apply_iran_block: %s", e)

def render_template(name, **kwargs):
    if session.get('logged_in') and not session.get('csrf_token'):
        session['csrf_token'] = secrets.token_hex(16)
    kwargs.setdefault('csrf_token', session.get('csrf_token', ''))
    path = os.path.join(TEMPLATES_DIR, name)
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8') as f:
            return render_template_string(f.read(), **kwargs)
    return render_template_string("""<!DOCTYPE html><html lang="fa" dir="rtl"><head>
<meta charset="UTF-8"><title>Error</title><style>body{background:#0a0a0a;color:#fff;
font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh}
.e{background:rgba(255,0,0,.1);border:1px solid rgba(255,0,0,.3);padding:2rem;
border-radius:1rem}a{color:#f87171}</style></head><body><div class="e">
<h1>Template Not Found</h1><p>{{ name }}</p><a href="/dashboard">Back</a></div></body></html>""",
        name=name)

@app.before_request
def csrf_protect():
    if request.method == 'POST' and session.get('logged_in'):
        tok = request.form.get('csrf_token', '')
        if not tok or not hmac.compare_digest(tok, session.get('csrf_token', '')):
            return Response('CSRF validation failed', 400)
    return None

_login_fail = {}

@app.route('/', methods=['GET', 'POST'])
def login():
    ip = request.remote_addr or '?'
    now = time.time()
    rec = _login_fail.get(ip)
    if rec and rec.get('until', 0) > now:
        return render_template('login.html', error='تلاش زیاد؛ دو دقیقه صبر کنید'), 429
    if request.method == 'POST':
        u = request.form.get('username', '')
        p = request.form.get('password', '')
        if (hmac.compare_digest(u.encode(), get_setting('admin_username').encode()) and
                hmac.compare_digest(p.encode(), get_setting('admin_password').encode())):
            session.clear()
            session['logged_in'] = True
            session['csrf_token'] = secrets.token_hex(16)
            _login_fail.pop(ip, None)
            return redirect(url_for('dashboard'))
        rec = rec or {'count': 0, 'until': 0}
        rec['count'] += 1
        if rec['count'] >= 5:
            rec['until'] = now + 120
        _login_fail[ip] = rec
        return render_template('login.html', error='اطلاعات نادرست')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/dashboard')
def dashboard():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    try:
        conn = get_db()
        c = conn.cursor()
        total_users = c.execute("SELECT COUNT(*) FROM users").fetchone()[0]
        active_users = c.execute("SELECT COUNT(*) FROM users WHERE status=1").fetchone()[0]
        total_inbounds = c.execute("SELECT COUNT(*) FROM xray_inbounds WHERE status=1").fetchone()[0]
        total_clients = c.execute("SELECT COUNT(*) FROM xray_clients WHERE enable=1").fetchone()[0]
        total_used = round(c.execute("SELECT COALESCE(SUM(used_traffic)/1024,0) FROM users").fetchone()[0], 2)
        dom = get_setting('domain') or request.host.split(':')[0]
        pp = get_panel_port()
        online_map = get_online_users()
        users = []
        for row in c.execute("SELECT * FROM users ORDER BY created_at DESC").fetchall():
            u = dict(row)
            oi = online_map.get(u['username'], {})
            tg = round((u['total_traffic'] or 0) / 1024, 2)
            ug = round((u['used_traffic'] or 0) / 1024, 2)
            try:
                dl = (datetime.strptime(u['expire_date'], '%Y-%m-%d %H:%M') - datetime.now()).days
            except Exception:
                dl = None
            users.append({
                'username': u['username'], 'password': u['password'],
                'expire_date': u['expire_date'], 'days_left': dl,
                'total_traffic': tg, 'used_traffic': ug,
                'progress': min(100, int(ug / tg * 100)) if tg > 0 else 0,
                'status': u['status'], 'max_connections': u['max_connections'],
                'is_online': oi.get('is_online', False),
                'ssh_count': oi.get('ssh_count', 0),
                'xray_ips': oi.get('xray_ips', 0),
                'online_count': oi.get('online_count', 0),
                'over_limit': oi.get('over_limit', False),
                'sub_link': f"http://{dom}:{pp}/sub/{u['username']}?token={_user_token(u['username'])}"
            })
        conn.close()
        return render_template('dashboard.html', cpu=get_cpu(), ram=get_ram(),
                               total_users=total_users, active_users=active_users,
                               total_inbounds=total_inbounds, total_clients=total_clients,
                               total_used=total_used, users=users)
    except Exception as e:
        logger.error("dashboard: %s\n%s", e, traceback.format_exc())
        return render_template('error.html', error_message=f'خطا: {e}'), 500

@app.route('/api/stats')
def api_stats():
    if not session.get('logged_in'):
        return jsonify({'error': 'unauthorized'}), 401
    return jsonify({'cpu': get_cpu(), 'ram': get_ram()})

@app.route('/api/online')
def api_online():
    if not session.get('logged_in'):
        return jsonify({'error': 'unauthorized'}), 401
    return jsonify(get_online_users())

@app.route('/add_user_page')
def add_user_page():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    return render_template('add_user.html')

@app.route('/add_user', methods=['POST'])
def add_user():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    try:
        u = (request.form.get('username') or '').strip()
        p = (request.form.get('password') or '').strip()
        if not USERNAME_RE.match(u):
            flash('❌ نام کاربری نامعتبر (حروف کوچک انگلیسی، ۳ تا ۳۲ کاراکتر)', 'error')
            return redirect(url_for('add_user_page'))
        if u in RESERVED:
            flash('❌ این نام کاربری رزرو شده است', 'error')
            return redirect(url_for('add_user_page'))
        if len(p) < 4 or ':' in p or '\n' in p or p != p.strip():
            flash('❌ رمز حداقل ۴ کاراکتر و بدون «:» باشد', 'error')
            return redirect(url_for('add_user_page'))
        conn = get_db()
        try:
            if conn.execute("SELECT 1 FROM users WHERE username=?", (u,)).fetchone():
                conn.close()
                flash('❌ این کاربر قبلاً ثبت شده است', 'error')
                return redirect(url_for('add_user_page'))
            r = subprocess.run(['id', u], capture_output=True, timeout=5)
            if r.returncode == 0:
                conn.close()
                flash('❌ این نام در سیستم موجود است', 'error')
                return redirect(url_for('add_user_page'))
            ed = safe_int(request.form.get('expire_days', 30), 30)
            tg = safe_float(request.form.get('traffic_gb', 0)) * 1024
            mc = safe_int(request.form.get('max_connections', 2), 2)
            exp = (datetime.now() + timedelta(days=max(1, ed))).strftime('%Y-%m-%d %H:%M')
            if not create_system_user(u, p):
                conn.close()
                flash('❌ خطا در ساخت کاربر سیستمی', 'error')
                return redirect(url_for('add_user_page'))
            conn.execute("INSERT INTO users (username,password,expire_date,total_traffic,used_traffic,status,max_connections,created_at,sub_token) VALUES (?,?,?,?,0.0,1,?,?,?)",
                         (u, p, exp, tg, mc, datetime.now().strftime('%Y-%m-%d %H:%M'),
                          secrets.token_urlsafe(16)))
            conn.commit()
        finally:
            try:
                conn.close()
            except Exception:
                pass
        flash(f'✅ کاربر {u} ایجاد شد!', 'success')
    except Exception as e:
        flash(f'❌ خطا: {e}', 'error')
    return redirect(url_for('dashboard'))

@app.route('/edit_user', methods=['POST'])
def edit_user():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    try:
        u = (request.form.get('username') or '').strip()
        new_pass = (request.form.get('password') or '').strip()
        tg = safe_float(request.form.get('traffic_gb', 0)) * 1024
        mc = safe_int(request.form.get('max_connections', 2), 2)
        s = safe_int(request.form.get('status', 1), 1)
        exp = request.form.get('expire_date', '')
        reset_traffic = request.form.get('reset_traffic') == 'on'
        reset_expire = request.form.get('reset_expire') == 'on'
        reset_days = max(1, safe_int(request.form.get('reset_days', 30), 30))
        extend_days = safe_int(request.form.get('extend_days', 0), 0)

        conn = get_db()
        row = conn.execute("SELECT * FROM users WHERE username=?", (u,)).fetchone()
        if not row:
            conn.close()
            flash('❌ کاربر یافت نشد', 'error')
            return redirect(url_for('dashboard'))
        row = dict(row)

        final_exp = exp
        if reset_expire:
            final_exp = (datetime.now() + timedelta(days=reset_days)).strftime('%Y-%m-%d %H:%M')
        elif extend_days > 0:
            try:
                base = datetime.strptime(exp, '%Y-%m-%d %H:%M')
                final_exp = (base + timedelta(days=extend_days)).strftime('%Y-%m-%d %H:%M')
            except Exception:
                pass
        msgs = []
        if s == 1:
            try:
                if datetime.strptime(final_exp, '%Y-%m-%d %H:%M') < datetime.now():
                    final_exp = (datetime.now() + timedelta(days=30)).strftime('%Y-%m-%d %H:%M')
                    msgs.append('📅 تاریخ گذشته بود؛ ۳۰ روز تمدید شد')
            except Exception:
                pass

        create_system_user(u, new_pass or row['password'])

        if s == 0:
            subprocess.run(['usermod', '-L', u], capture_output=True, timeout=5)
            subprocess.run(['pkill', '-KILL', '-u', u], capture_output=True, timeout=5)
        else:
            subprocess.run(['usermod', '-U', u], capture_output=True, timeout=5)

        conn.execute("""UPDATE users SET password=?, total_traffic=?, max_connections=?,
                        status=?, expire_date=? WHERE username=?""",
                     (new_pass or row['password'], tg, mc, s, final_exp, u))
        if reset_traffic:
            conn.execute("UPDATE users SET used_traffic=0 WHERE username=?", (u,))
        conn.commit()
        conn.close()
        sync_xray()

        msgs.insert(0, f'✅ کاربر {u} بروز شد!')
        if reset_traffic:
            msgs.append('♻️ مصرف صفر شد')
        if reset_expire:
            msgs.append(f'📅 تاریخ به {reset_days} روز آینده ریست شد')
        elif extend_days > 0:
            msgs.append(f'➕ {extend_days} روز اضافه شد')
        flash(' · '.join(msgs), 'success')
    except Exception as e:
        flash(f'❌ خطا: {e}', 'error')
    return redirect(url_for('dashboard'))

@app.route('/delete_user/<username>')
def delete_user(username):
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    try:
        subprocess.run(['pkill', '-KILL', '-u', username], capture_output=True, timeout=10)
        time.sleep(0.3)
        subprocess.run(['userdel', '-r', '-f', username], capture_output=True, timeout=15)
        chk = subprocess.run(['id', username], capture_output=True, timeout=5)
        if chk.returncode == 0:
            flash(f'❌ حذف کاربر سیستمی {username} ناموفق بود؛ دوباره تلاش کنید', 'error')
            return redirect(url_for('dashboard'))
        conn = get_db()
        conn.execute("DELETE FROM users WHERE username=?", (username,))
        conn.commit()
        conn.close()
        sync_xray()
        flash(f'✅ {username} کامل حذف شد!', 'success')
    except Exception as e:
        flash(f'❌ خطا: {e}', 'error')
    return redirect(url_for('dashboard'))

@app.route('/inbounds')
def inbounds_page():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    try:
        conn = get_db()
        inbounds = []
        for ib in conn.execute("SELECT * FROM xray_inbounds ORDER BY id DESC").fetchall():
            ib = dict(ib)
            ib['client_count'] = conn.execute(
                "SELECT COUNT(*) FROM xray_clients WHERE inbound_id=?", (ib['id'],)).fetchone()[0]
            inbounds.append(ib)
        conn.close()
        return render_template('inbounds.html', inbounds=inbounds,
                               cpu=get_cpu(), ram=get_ram())
    except Exception:
        return render_template('error.html', error_message='خطا'), 500

@app.route('/add_inbound_page')
def add_inbound_page():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    return render_template('add_inbound.html', random_port=get_random_port())

@app.route('/add_inbound', methods=['POST'])
def add_inbound():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    try:
        tag = (request.form.get('tag') or '').strip()
        if not re.match(r'^[A-Za-z0-9_-]{1,32}, tag):
            flash('❌ نام (Tag) نامعتبر است', 'error')
            return redirect(url_for('add_inbound_page'))
        proto = request.form.get('protocol', 'vless')
        if proto not in ('vless', 'vmess', 'trojan'):
            flash('❌ پروتکل نامعتبر', 'error')
            return redirect(url_for('add_inbound_page'))
        net = request.form.get('network', 'tcp')
        if net not in ('tcp', 'ws', 'grpc'):
            flash('❌ network نامعتبر', 'error')
            return redirect(url_for('add_inbound_page'))
        sec = request.form.get('security', 'none')
        if sec not in ('none', 'tls', 'reality'):
            flash('❌ security نامعتبر', 'error')
            return redirect(url_for('add_inbound_page'))
        try:
            port = int(request.form.get('port', 0))
            assert 1 <= port <= 65535
        except Exception:
            flash('❌ پورت نامعتبر', 'error')
            return redirect(url_for('add_inbound_page'))
        sni = request.form.get('server_name', 'www.microsoft.com')
        fp = request.form.get('fingerprint', 'chrome')
        sid = request.form.get('short_id', '')
        path = request.form.get('path', '/')

        if sec == 'tls':
            dom_ssl = get_setting('ssl_domain')
            cert = f"/etc/letsencrypt/live/{dom_ssl}/fullchain.pem" if dom_ssl else ''
            keyf = f"/etc/letsencrypt/live/{dom_ssl}/privkey.pem" if dom_ssl else ''
            if not (dom_ssl and os.path.exists(cert) and os.path.exists(keyf)):
                flash('❌ برای TLS ابتدا گواهی را با certbot بسازید و دامنه SSL را در تنظیمات ذخیره کنید', 'error')
                return redirect(url_for('add_inbound_page'))

        conn = get_db()
        try:
            if conn.execute("SELECT 1 FROM xray_inbounds WHERE tag=?", (tag,)).fetchone():
                flash('❌ این Tag قبلاً استفاده شده', 'error')
                return redirect(url_for('add_inbound_page'))
            if conn.execute("SELECT 1 FROM xray_inbounds WHERE port=?", (port,)).fetchone():
                flash('❌ این پورت قبلاً استفاده شده', 'error')
                return redirect(url_for('add_inbound_page'))

            pub = priv = ''
            if sec == 'reality':
                pub = get_setting('reality_public_key')
                priv = get_setting('reality_private_key')
                if not pub or not priv:
                    result = run_command([XRAY_BIN, 'x25519'])
                    if result:
                        out = result.stdout.decode() + result.stderr.decode()
                        for line in out.split('\n'):
                            line = line.strip()
                            if ':' not in line:
                                continue
                            k, v = line.split(':', 1)
                            k = k.strip().lower()
                            if 'private' in k:
                                priv = v.strip()
                            elif 'public' in k:
                                pub = v.strip()
                    if pub and priv:
                        set_setting('reality_public_key', pub)
                        set_setting('reality_private_key', priv)
                    else:
                        flash('❌ ساخت کلیدهای Reality ناموفق بود', 'error')
                        return redirect(url_for('add_inbound_page'))
            conn.execute("""INSERT INTO xray_inbounds
                (tag,protocol,port,network,security,server_name,fingerprint,short_id,
                 public_key,private_key,path,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)""",
                (tag, proto, port, net, sec, sni, fp, sid, pub, priv, path,
                 datetime.now().strftime('%Y-%m-%d %H:%M')))
            conn.commit()
        finally:
            try:
                conn.close()
            except Exception:
                pass
        sync_xray()
        flash(f'✅ اینباند {tag}:{port} ایجاد شد!', 'success')
    except Exception as e:
        flash(f'❌ خطا: {e}', 'error')
    return redirect(url_for('inbounds_page'))

@app.route('/delete_inbound/<int:ib_id>')
def delete_inbound(ib_id):
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    try:
        conn = get_db()
        conn.execute("DELETE FROM xray_inbounds WHERE id=?", (ib_id,))
        conn.commit()
        conn.close()
        sync_xray()
        flash('✅ حذف شد!', 'success')
    except Exception:
        flash('❌ خطا', 'error')
    return redirect(url_for('inbounds_page'))

@app.route('/clients/<int:ib_id>')
def clients_page(ib_id):
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    try:
        conn = get_db()
        row = conn.execute("SELECT * FROM xray_inbounds WHERE id=?", (ib_id,)).fetchone()
        if not row:
            conn.close()
            return redirect(url_for('inbounds_page'))
        inbound = dict(row)
        clients_raw = [dict(cl) for cl in conn.execute(
            "SELECT * FROM xray_clients WHERE inbound_id=?", (ib_id,)).fetchall()]
        available = [r['username'] for r in conn.execute(
            "SELECT username FROM users WHERE username NOT IN "
            "(SELECT username FROM xray_clients WHERE inbound_id=?)", (ib_id,)).fetchall()]
        conn.close()
        dom = get_setting('domain') or request.host.split(':')[0]
        dpub = get_setting('reality_public_key')
        for cl in clients_raw:
            cl['link'] = gen_link(inbound['protocol'], cl['uuid'], dom, inbound['port'],
                                  inbound.get('network', 'tcp'), inbound.get('security', 'none'),
                                  inbound.get('server_name', ''), inbound.get('fingerprint', ''),
                                  inbound.get('short_id', ''), inbound.get('public_key') or dpub,
                                  inbound.get('path', '/'), cl['username'])
        return render_template('clients.html', inbound=inbound,
                               clients=clients_raw, available_users=available)
    except Exception:
        return render_template('error.html', error_message='خطا'), 500

@app.route('/add_clients/<int:ib_id>', methods=['POST'])
def add_clients(ib_id):
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    try:
        conn = get_db()
        for uname in request.form.getlist('usernames'):
            conn.execute("""INSERT OR IGNORE INTO xray_clients
                (inbound_id,username,uuid,email,created_at) VALUES (?,?,?,?,?)""",
                (ib_id, uname, str(uuid.uuid4()), uname,
                 datetime.now().strftime('%Y-%m-%d %H:%M')))
        conn.commit()
        conn.close()
        sync_xray()
        flash('✅ اضافه شدند!', 'success')
    except Exception as e:
        flash(f'❌ خطا: {e}', 'error')
    return redirect(url_for('clients_page', ib_id=ib_id))

@app.route('/delete_client/<int:cl_id>')
def delete_client(cl_id):
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    ib_id = None
    try:
        conn = get_db()
        row = conn.execute("SELECT inbound_id FROM xray_clients WHERE id=?", (cl_id,)).fetchone()
        ib_id = row['inbound_id'] if row else None
        conn.execute("DELETE FROM xray_clients WHERE id=?", (cl_id,))
        conn.commit()
        conn.close()
        sync_xray()
        flash('✅ حذف شد!', 'success')
    except Exception as e:
        flash(f'❌ خطا: {e}', 'error')
    if ib_id:
        return redirect(url_for('clients_page', ib_id=ib_id))
    return redirect(url_for('inbounds_page'))

@app.route('/groups')
def groups_page():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    try:
        conn = get_db()
        groups = []
        for g in conn.execute("SELECT * FROM user_groups ORDER BY id DESC").fetchall():
            g = dict(g)
            g['member_count'] = conn.execute(
                "SELECT COUNT(*) FROM group_members WHERE group_id=?", (g['id'],)).fetchone()[0]
            groups.append(g)
        conn.close()
        return render_template('groups.html', groups=groups, cpu=get_cpu(), ram=get_ram())
    except Exception:
        return render_template('error.html', error_message='خطا'), 500

@app.route('/add_group', methods=['POST'])
def add_group():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    n = (request.form.get('name') or '').strip()
    if n:
        try:
            conn = get_db()
            conn.execute("INSERT INTO user_groups (name,description,created_at) VALUES (?,?,?)",
                         (n, request.form.get('description', ''),
                          datetime.now().strftime('%Y-%m-%d %H:%M')))
            conn.commit()
            conn.close()
            flash('✅ گروه ایجاد شد!', 'success')
        except Exception:
            flash('❌ گروه تکراری است', 'error')
    return redirect(url_for('groups_page'))

@app.route('/delete_group/<int:gid>')
def delete_group(gid):
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    conn = get_db()
    conn.execute("DELETE FROM user_groups WHERE id=?", (gid,))
    conn.commit()
    conn.close()
    flash('✅ حذف شد!', 'success')
    return redirect(url_for('groups_page'))

@app.route('/group_members/<int:gid>')
def group_members_page(gid):
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    try:
        conn = get_db()
        row = conn.execute("SELECT * FROM user_groups WHERE id=?", (gid,)).fetchone()
        if not row:
            conn.close()
            return redirect(url_for('groups_page'))
        group = dict(row)
        members = [r['username'] for r in conn.execute(
            "SELECT username FROM group_members WHERE group_id=?", (gid,)).fetchall()]
        available = [r['username'] for r in conn.execute(
            "SELECT username FROM users WHERE username NOT IN "
            "(SELECT username FROM group_members WHERE group_id=?)", (gid,)).fetchall()]
        conn.close()
        return render_template('group_members.html', group=group,
                               members=members, available_users=available)
    except Exception:
        return render_template('error.html', error_message='خطا'), 500

@app.route('/add_group_members/<int:gid>', methods=['POST'])
def add_group_members(gid):
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    conn = get_db()
    for uname in request.form.getlist('usernames'):
        try:
            conn.execute("INSERT INTO group_members (group_id,username) VALUES (?,?)", (gid, uname))
        except Exception:
            pass
    conn.commit()
    conn.close()
    flash('✅ اضافه شدند!', 'success')
    return redirect(url_for('group_members_page', gid=gid))

@app.route('/remove_group_member/<int:gid>/<username>')
def remove_group_member(gid, username):
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    conn = get_db()
    conn.execute("DELETE FROM group_members WHERE group_id=? AND username=?", (gid, username))
    conn.commit()
    conn.close()
    flash('✅ حذف شد!', 'success')
    return redirect(url_for('group_members_page', gid=gid))

@app.route('/sub/<username>')
def sub_page(username):
    try:
        if not _token_ok(username):
            return render_template('sub_error.html', error_message='لینک نامعتبر است (توکن صحیح نیست)'), 403
        conn = get_db()
        row = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
        if not row:
            conn.close()
            return render_template('sub_error.html', error_message='کاربر یافت نشد'), 404
        user = dict(row)
        if user['status'] == 0:
            conn.close()
            return render_template('sub_error.html', error_message='اکانت شما غیرفعال شده است'), 403
        tok = _user_token(username)
        dom = get_setting('domain') or request.host.split(':')[0]
        dpub = get_setting('reality_public_key')
        tg = round(float(user['total_traffic'] or 0) / 1024, 2)
        ug = round(float(user['used_traffic'] or 0) / 1024, 2)
        if tg > 0:
            rg = round(max(0.0, tg - ug), 2)
            prog = min(100, int(ug / tg * 100))
            total_s, used_s, rem_s = f'{tg} GB', f'{ug} GB', f'{rg} GB'
        else:
            prog = 0
            total_s, used_s, rem_s = 'نامحدود', f'{ug} GB', 'نامحدود'
        try:
            dl = max(0, (datetime.strptime(user['expire_date'], '%Y-%m-%d %H:%M') - datetime.now()).days)
        except Exception:
            dl = 0
        ssh_uri = f"ssh://{username}:{user['password']}@{dom}:22#OP-{username}"
        ssh_qr = generate_qr_base64(ssh_uri)
        xl = []
        rows = conn.execute("""SELECT cl.uuid, ib.port, ib.protocol, ib.network, ib.security,
                               ib.server_name, ib.fingerprint, ib.short_id, ib.public_key,
                               ib.path, ib.tag FROM xray_clients cl
                               JOIN xray_inbounds ib ON cl.inbound_id=ib.id
                               WHERE cl.username=? AND cl.enable=1 AND ib.status=1
                               ORDER BY cl.id ASC""", (username,)).fetchall()
        for idx, xc in enumerate(rows):
            xc = dict(xc)
            link = ''
            try:
                link = gen_link(xc['protocol'], xc['uuid'], dom, xc['port'],
                                xc.get('network', 'tcp'), xc.get('security', 'none'),
                                xc.get('server_name', ''), xc.get('fingerprint', ''),
                                xc.get('short_id', ''), xc.get('public_key') or dpub,
                                xc.get('path', '/'), username)
            except Exception as e:
                logger.error("link gen: %s", e)
            xl.append({'protocol': xc['protocol'], 'tag': xc.get('tag', ''),
                       'port': xc['port'], 'net': xc.get('network', 'tcp'),
                       'sec': xc.get('security', 'none'), 'link': link,
                       'qr_code': generate_qr_base64(link) if link else '',
                       'nepster_link': f"/download/nepster/{username}/{idx}?token={tok}",
                       'netmod_link': f"/download/netmod/{username}/{idx}?token={tok}"})
        conn.close()
        return render_template('sub.html', username=username, password=user['password'],
                               expire_date=user['expire_date'], days_left=str(dl),
                               total_traffic=total_s, used_traffic=used_s,
                               remaining_traffic=rem_s, progress_percent=str(prog),
                               status=str(user['status']), max_conn=str(user['max_connections']),
                               ssh_uri=ssh_uri, ssh_qr=ssh_qr, xray_configs=xl)
    except Exception as e:
        logger.error("sub: %s\n%s", e, traceback.format_exc())
        return render_template('sub_error.html', error_message=f'خطا: {e}'), 500

def _get_sub_config(username, idx):
    conn = get_db()
    dom = get_setting('domain') or request.host.split(':')[0]
    dpub = get_setting('reality_public_key')
    xc = conn.execute("""SELECT cl.uuid, ib.port, ib.protocol, ib.network, ib.security,
                         ib.server_name, ib.fingerprint, ib.short_id, ib.public_key, ib.path
                         FROM xray_clients cl JOIN xray_inbounds ib ON cl.inbound_id=ib.id
                         WHERE cl.username=? AND cl.enable=1 AND ib.status=1
                         ORDER BY cl.id ASC LIMIT 1 OFFSET ?""", (username, idx)).fetchone()
    conn.close()
    return (dict(xc) if xc else None), dom, dpub

@app.route('/download/nepster/<username>/<int:config_index>')
def download_nepster(username, config_index):
    if not _token_ok(username):
        return "Not found", 404
    xc, dom, dpub = _get_sub_config(username, config_index)
    if not xc:
        return "Not found", 404
    cfg = generate_nepster_config(xc['protocol'], xc['uuid'], dom, xc['port'],
        xc.get('network', 'tcp'), xc.get('security', 'none'), xc.get('server_name', ''),
        xc.get('fingerprint', ''), xc.get('short_id', ''), xc.get('public_key') or dpub,
        xc.get('path', '/'), username)
    return Response(cfg, mimetype="application/octet-stream",
        headers={"Content-Disposition": f"attachment;filename=OP_{username}_{xc['protocol']}.npvt"})

@app.route('/download/netmod/<username>/<int:config_index>')
def download_netmod(username, config_index):
    if not _token_ok(username):
        return "Not found", 404
    xc, dom, dpub = _get_sub_config(username, config_index)
    if not xc:
        return "Not found", 404
    cfg = generate_netmod_config(xc['protocol'], xc['uuid'], dom, xc['port'],
        xc.get('network', 'tcp'), xc.get('security', 'none'), xc.get('server_name', ''),
        xc.get('fingerprint', ''), xc.get('short_id', ''), xc.get('public_key') or dpub,
        xc.get('path', '/'), username)
    return Response(cfg, mimetype="application/json",
        headers={"Content-Disposition": f"attachment;filename=OP_{username}_{xc['protocol']}.json"})

@app.route('/reports')
def reports():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    try:
        conn = get_db()
        summary = dict(conn.execute(
            "SELECT COUNT(*) as total_users, COALESCE(SUM(total_traffic)/1024,0) as total_traffic_gb,"
            "COALESCE(SUM(used_traffic)/1024,0) as used_traffic_gb FROM users").fetchone())
        ib_count = conn.execute("SELECT COUNT(*) FROM xray_inbounds WHERE status=1").fetchone()[0]
        cl_count = conn.execute("SELECT COUNT(*) FROM xray_clients WHERE enable=1").fetchone()[0]
        conn.close()
        return render_template('reports.html', summary=summary, ib_count=ib_count,
                               cl_count=cl_count, cpu=get_cpu(), ram=get_ram())
    except Exception:
        return render_template('error.html', error_message='خطا'), 500

@app.route('/settings', methods=['GET', 'POST'])
def settings():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    if request.method == 'POST':
        action = request.form.get('action', '')
        if action == 'save_settings':
            if request.form.get('domain'):
                set_setting('domain', request.form['domain'].strip())
            if request.form.get('admin_username'):
                set_setting('admin_username', request.form['admin_username'].strip())
            if request.form.get('ssl_domain'):
                set_setting('ssl_domain', request.form['ssl_domain'].strip())
            pp = (request.form.get('panel_port') or '').strip()
            port_changed = False
            if pp:
                if not pp.isdigit() or not (1024 <= int(pp) <= 65535):
                    flash('❌ پورت باید عددی بین 1024 و 65535 باشد', 'error')
                    return redirect(url_for('settings'))
                if pp != get_setting('panel_port'):
                    set_setting('panel_port', pp)
                    port_changed = True
            if request.form.get('admin_password'):
                set_setting('admin_password', request.form['admin_password'])
            set_setting('block_iran_client', '1' if request.form.get('block_iran') else '0')
            apply_iran_block()
            sync_xray()
            msg = '✅ ذخیره شد!'
            if port_changed:
                msg += ' (برای اعمال پورت جدید: systemctl restart ssh-panel)'
            flash(msg, 'success')
        elif action == 'generate_keys':
            try:
                result = run_command([XRAY_BIN, 'x25519'])
                if result:
                    out = result.stdout.decode() + result.stderr.decode()
                    priv = pub = ''
                    for line in out.split('\n'):
                        line = line.strip()
                        if ':' not in line:
                            continue
                        k, v = line.split(':', 1)
                        k = k.strip().lower()
                        if 'private' in k:
                            priv = v.strip()
                        elif 'public' in k:
                            pub = v.strip()
                    if priv and pub:
                        set_setting('reality_private_key', priv)
                        set_setting('reality_public_key', pub)
                        sync_xray()
                        flash('✅ کلیدهای Reality تولید شدند!', 'success')
                    else:
                        flash('❌ خروجی x25519 قابل پردازش نبود', 'error')
            except Exception:
                flash('❌ خطا در تولید کلیدها', 'error')
        return redirect(url_for('settings'))
    sd = {}
    for k in ['domain', 'admin_username', 'admin_password', 'block_iran_client',
              'panel_port', 'reality_public_key', 'reality_private_key', 'ssl_domain']:
        sd[k] = get_setting(k)
    return render_template('settings.html', **sd, cpu=get_cpu(), ram=get_ram())

@app.route('/backup_download')
def backup_download():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    try:
        src = sqlite3.connect(DB_PATH)
        dst = sqlite3.connect('/tmp/panel_backup.db')
        with dst:
            src.backup(dst)
        dst.close()
        src.close()
        return send_file('/tmp/panel_backup.db', as_attachment=True,
                         download_name='OutlineParsian_Backup.db')
    except Exception as e:
        flash(f'❌ خطا: {e}', 'error')
        return redirect(url_for('settings'))

@app.route('/backup_upload', methods=['POST'])
def backup_upload():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    file = request.files.get('backup_file')
    if not file or file.filename == '':
        flash('❌ فایلی انتخاب نشده است', 'error')
        return redirect(url_for('settings'))
    temp_path = '/tmp/uploaded_restore.db'
    file.save(temp_path)
    try:
        tc = sqlite3.connect(temp_path)
        users_count = tc.execute("SELECT COUNT(*) FROM users;").fetchone()[0]
        tc.close()
    except Exception as e:
        if os.path.exists(temp_path):
            os.remove(temp_path)
        flash(f'❌ فایل نامعتبر: {e}', 'error')
        return redirect(url_for('settings'))
    restore_script = """#!/bin/bash
sleep 2
systemctl mask ssh-panel.service ssh-panel-worker.service 2>/dev/null
systemctl stop ssh-panel.service ssh-panel-worker.service
for i in $(seq 1 20); do
    if ! systemctl is-active --quiet ssh-panel.service && ! systemctl is-active --quiet ssh-panel-worker.service; then
        break
    fi
    sleep 0.5
done
cp /root/ssh-panel/panel.db /root/ssh-panel/panel.db.before_restore_$(date +%s) 2>/dev/null
rm -f /root/ssh-panel/panel.db-wal /root/ssh-panel/panel.db-shm
cp '""" + temp_path + """' /root/ssh-panel/panel.db
sync
systemctl unmask ssh-panel.service ssh-panel-worker.service 2>/dev/null
systemctl start ssh-panel-worker.service
systemctl start ssh-panel.service
rm -f '""" + temp_path + """'
"""
    with open('/tmp/restore_panel.sh', 'w') as f:
        f.write(restore_script)
    os.chmod('/tmp/restore_panel.sh', 0o755)
    subprocess.Popen(['systemd-run', '--description', 'Restore Panel DB', '/bin/bash',
                      '/tmp/restore_panel.sh'],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
    flash(f'✅ بازگردانی آغاز شد ({users_count} کاربر). پنل چند لحظه قطع و خودکار بالا می‌آید.', 'success')
    return redirect(url_for('settings'))

if __name__ == '__main__':
    for lf in ['/tmp/xray_access.log', '/tmp/xray_error.log', '/var/log/panel.log', '/tmp/worker.log']:
        if not os.path.exists(lf):
            open(lf, 'a').close()
        try:
            os.chmod(lf, 0o666)
        except Exception:
            pass
    ensure_schema()
    sync_xray()
    apply_iran_block()
    sync_users_from_db()
    logger.info("Panel starting on port %d", get_panel_port())
    app.run(host='0.0.0.0', port=get_panel_port(), debug=False, threaded=True)
EOFAPP
chmod +x /root/ssh-panel/app.py
verify_py /root/ssh-panel/app.py

# ============================================
# [8/14] Iran block script
# ============================================
echo "[8/14] Creating Iran block script..."
cat << 'EOFIRAN' > /usr/local/bin/iran-block.sh
#!/bin/bash
IPSET_NAME="iran_ips"
enable_block() {
    ipset create $IPSET_NAME hash:net maxelem 200000 2>/dev/null
    curl -s --max-time 60 https://www.ipdeny.com/ipblocks/data/countries/ir.zone -o /tmp/ir.zone
    if [ -s /tmp/ir.zone ]; then
        ipset flush $IPSET_NAME 2>/dev/null
        while read -r line; do
            [ -n "$line" ] && ipset add $IPSET_NAME "$line" 2>/dev/null
        done < /tmp/ir.zone
    fi
    iptables -C OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I OUTPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
    while iptables -C OUTPUT -m set --match-set $IPSET_NAME dst -j DROP 2>/dev/null; do
        iptables -D OUTPUT -m set --match-set $IPSET_NAME dst -j DROP 2>/dev/null
    done
    iptables -A OUTPUT -m set --match-set $IPSET_NAME dst -j DROP
    ipset save > /etc/ipset.conf 2>/dev/null
    echo "iran-block: enabled"
}
disable_block() {
    while iptables -C OUTPUT -m set --match-set $IPSET_NAME dst -j DROP 2>/dev/null; do
        iptables -D OUTPUT -m set --match-set $IPSET_NAME dst -j DROP 2>/dev/null
    done
    echo "iran-block: disabled"
}
case "$1" in
    enable)  enable_block ;;
    disable) disable_block ;;
    *) echo "usage: $0 enable|disable" ;;
esac
EOFIRAN
chmod +x /usr/local/bin/iran-block.sh
echo "✓ Iran block script created"

# ============================================
# [9/14] worker.py
# ============================================
echo "[9/14] Creating online/traffic worker..."
cat << 'EOFWORKER' > /root/ssh-panel/worker.py
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, re, sys, json, time, signal, sqlite3, subprocess, threading, logging
from collections import defaultdict
from datetime import datetime

sys.path.insert(0, '/root/ssh-panel/grpc_proto')
try:
    import grpc
    import stats_pb2, stats_pb2_grpc
    HAS_GRPC = True
except Exception:
    HAS_GRPC = False

DB_PATH     = '/root/ssh-panel/panel.db'
ONLINE_FILE = '/tmp/online_users.json'
XRAY_LOG    = '/tmp/xray_access.log'
API_ADDR    = '127.0.0.1:10085'
MB = 1048576.0

CHECK_INTERVAL   = 5
WINDOW           = 60
XRAY_TTL         = 300
IP_MAP_TTL       = 1800
TRAFFIC_INTERVAL = 10
LIMIT_CHAIN  = 'OP_LIMIT'
SSH_OUT_CHAIN = 'OPWG_OUT'
BLOCK_SECONDS = 600
SEED_BYTES    = 12 * 1024 * 1024
ENFORCE_SSH  = True
ENFORCE_XRAY = True

EMAIL_RE = re.compile(r'email[:=]\s*"?([A-Za-z0-9_.@-]+)')
SRC_RE   = re.compile(r'((?:\d{1,3}\.){3}\d{1,3}|\[[0-9a-fA-F:]+\]):\d+')
TS_RE    = re.compile(r'^(\d{4}[-/]\d{2}[-/]\d{2})[ T](\d{2}:\d{2}:\d{2})')
SSHD_RE  = re.compile(r'(?:sshd-session|sshd):\s*([^\s:@]+)@(\S+)')

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s',
                    handlers=[logging.FileHandler('/tmp/worker.log'), logging.StreamHandler()])
log = logging.getLogger('worker')

activity     = defaultdict(dict)
blocked      = {}
log_pos      = 0
_lastcount   = -1
_uid_cache   = {}
_rules_installed = set()
SSH_ACCOUNTING = True

def strip_port(addr):
    if addr.startswith('[') and ']' in addr:
        return addr[1:addr.index(']')]
    if addr.count(':') == 1:
        return addr.rsplit(':', 1)[0]
    return addr

def line_ts(line, fallback):
    m = TS_RE.match(line)
    if not m:
        return fallback
    try:
        return time.mktime(time.strptime(
            m.group(1).replace('/', '-') + ' ' + m.group(2), '%Y-%m-%d %H:%M:%S'))
    except ValueError:
        return fallback

def load_db():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    try:
        users = {r['username']: dict(r) for r in conn.execute(
            'SELECT username,expire_date,total_traffic,used_traffic,status,max_connections FROM users')}
        email_map = {}
        for r in conn.execute(
            'SELECT cl.email AS email, cl.username AS username FROM xray_clients cl '
            'JOIN users u ON u.username=cl.username WHERE cl.enable=1 AND u.status=1'):
            if r['email']:
                email_map[r['email']] = r['username']
        ports = {str(r['port']) for r in conn.execute('SELECT port FROM xray_inbounds WHERE status=1')}
        return users, email_map, ports
    finally:
        conn.close()

def read_new_lines():
    global log_pos
    try:
        size = os.path.getsize(XRAY_LOG)
    except OSError:
        return []
    if size < log_pos:
        log_pos = 0
    if size == log_pos:
        return []
    try:
        with open(XRAY_LOG, 'rb') as f:
            f.seek(log_pos)
            data = f.read(4 * 1024 * 1024)
        cut = data.rfind(b'\n')
        if cut == -1:
            return []
        consumed = data[:cut + 1]
        log_pos += len(consumed)
        return consumed.decode('utf-8', 'replace').splitlines()
    except Exception as e:
        log('log read error: %s', e)
        return []

def feed(lines, email_map, now):
    n = 0
    for line in lines:
        m = EMAIL_RE.search(line)
        if not m:
            continue
        uname = email_map.get(m.group(1))
        if not uname:
            continue
        s = SRC_RE.search(line)
        if not s:
            continue
        ip = strip_port(s.group(1))
        if not ip:
            continue
        ts = line_ts(line, now)
        d = activity[uname]
        st = d.get(ip)
        if st is None:
            d[ip] = {'first': ts, 'last': ts}
        elif ts > st['last']:
            st['last'] = ts
        n += 1
    return n

def ssh_sessions():
    per = defaultdict(list)
    try:
        out = subprocess.run(['ps', '-eo', 'pid,args'], capture_output=True, timeout=5)
        txt = out.stdout.decode(errors='replace')
    except Exception as e:
        log('ps error: %s', e)
        return per
    for line in txt.splitlines():
        m = SSHD_RE.search(line)
        if not m:
            continue
        try:
            pid = int(line.split()[0])
        except (ValueError, IndexError):
            continue
        per[m.group(1)].append({'pid': pid, 'tty': m.group(2)})
    return per

def established_peer_ips(ports):
    if not ports:
        return None
    try:
        out = subprocess.run(['ss', '-tnH', 'state', 'established'],
                             capture_output=True, timeout=5)
        txt = out.stdout.decode(errors='replace')
    except Exception:
        return None
    peers = set()
    for line in txt.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        local, peer = parts[-2], parts[-1]
        if local.rsplit(':', 1)[-1] in ports:
            pip = peer.rsplit(':', 1)[0].strip('[]')
            if pip:
                peers.add(pip)
    return peers

def ipt(*a):
    try:
        return subprocess.run(['iptables'] + list(a), capture_output=True, timeout=5)
    except Exception:
        return None

def ensure_chain():
    ipt('-N', LIMIT_CHAIN)
    if ipt('-C', 'INPUT', '-j', LIMIT_CHAIN).returncode != 0:
        ipt('-I', 'INPUT', '1', '-j', LIMIT_CHAIN)

def block_ip(ip, ports):
    if ip in blocked:
        return
    ok = False
    for p in ports:
        if ipt('-A', LIMIT_CHAIN, '-s', ip, '-p', 'tcp', '--dport', p, '-j', 'DROP').returncode == 0:
            ok = True
    if ok:
        blocked[ip] = time.time() + BLOCK_SECONDS
        log('BLOCK %s for %ss (over limit)', ip, BLOCK_SECONDS)

def unblock_expired(ports):
    now = time.time()
    for ip in list(blocked):
        if blocked[ip] <= now:
            for p in ports:
                ipt('-D', LIMIT_CHAIN, '-s', ip, '-p', 'tcp', '--dport', p, '-j', 'DROP')
            del blocked[ip]
            log('UNBLOCK %s', ip)

# ---------- SSH traffic accounting (owner match, mangle OUTPUT) ----------
def uid_of(username):
    if username in _uid_cache:
        return _uid_cache[username]
    try:
        r = subprocess.run(['id', '-u', username], capture_output=True, timeout=5)
        uid = int(r.stdout.decode().strip())
        _uid_cache[username] = uid
        return uid
    except Exception:
        return None

def ensure_traffic_hooks():
    global SSH_ACCOUNTING
    ipt('-t', 'mangle', '-N', SSH_OUT_CHAIN)
    if ipt('-t', 'mangle', '-C', 'OUTPUT', '-j', SSH_OUT_CHAIN).returncode != 0:
        ipt('-t', 'mangle', '-I', 'OUTPUT', '1', '-j', SSH_OUT_CHAIN)
    t = ipt('-t', 'mangle', '-A', SSH_OUT_CHAIN, '-m', 'owner', '--uid-owner', '0')
    if t is None or t.returncode != 0:
        SSH_ACCOUNTING = False
        log('SSH traffic accounting disabled (owner match unsupported)')
    else:
        ipt('-t', 'mangle', '-D', SSH_OUT_CHAIN, '-m', 'owner', '--uid-owner', '0')

def read_ssh_counters():
    res = defaultdict(int)
    try:
        out = subprocess.run(['iptables-save', '-c', '-t', 'mangle'],
                             capture_output=True, timeout=5).stdout.decode(errors='replace')
    except Exception:
        return res
    for line in out.splitlines():
        m = re.match(r'\[(\d+):(\d+)\] -A ' + SSH_OUT_CHAIN + r' .*--uid-owner (\d+)', line)
        if m:
            res[int(m.group(3))] += int(m.group(2))
    return res

def _apply_traffic(deltas):
    if not deltas:
        return
    conn = sqlite3.connect(DB_PATH, timeout=30)
    try:
        c = conn.cursor()
        for un, mb in deltas.items():
            c.execute("UPDATE users SET used_traffic = used_traffic + ? WHERE username=?", (mb, un))
        conn.commit()
    finally:
        conn.close()

def collect_ssh_traffic():
    if not SSH_ACCOUNTING:
        return
    ctr = read_ssh_counters()
    ipt('-t', 'mangle', '-Z', SSH_OUT_CHAIN)
    uid_user = {v: k for k, v in _uid_cache.items()}
    deltas = {}
    for uid, b in ctr.items():
        if b and uid in uid_user:
            deltas[uid_user[uid]] = b / MB
    _apply_traffic(deltas)

def sync_uid_rules(users):
    global _rules_installed
    want = set()
    for un, u in users.items():
        if u['status'] != 1:
            continue
        uid = uid_of(un)
        if uid is not None and uid != 0:
            want.add(uid)
    for uid in want - _rules_installed:
        if ipt('-t', 'mangle', '-A', SSH_OUT_CHAIN, '-m', 'owner', '--uid-owner', str(uid)) is not None:
            _rules_installed.add(uid)
    for uid in _rules_installed - want:
        ipt('-t', 'mangle', '-D', SSH_OUT_CHAIN, '-m', 'owner', '--uid-owner', str(uid))
        _rules_installed.discard(uid)

def bootstrap_ssh_traffic(users):
    try:
        collect_ssh_traffic()
        ipt('-t', 'mangle', '-F', SSH_OUT_CHAIN)
        _rules_installed.clear()
    except Exception as e:
        log('bootstrap ssh traffic: %s', e)

def collect_xray_traffic(email_map):
    xbytes = defaultdict(int)
    if HAS_GRPC:
        try:
            with grpc.insecure_channel(API_ADDR) as ch:
                stub = stats_pb2_grpc.StatsServiceStub(ch)
                resp = stub.QueryStats(
                    stats_pb2.QueryStatsRequest(pattern='user>>>', reset=True), timeout=5)
                for s in resp.stat:
                    p = s.name.split('>>>')
                    if len(p) == 4 and p[2] == 'traffic':
                        xbytes[p[1]] += s.value
        except Exception as e:
            log('grpc stats error: %s', e)
    deltas = {}
    for email, b in xbytes.items():
        un = email_map.get(email)
        if un and b:
            deltas[un] = deltas.get(un, 0.0) + b / MB
    _apply_traffic(deltas)

def traffic_loop():
    while True:
        time.sleep(TRAFFIC_INTERVAL)
        try:
            users, email_map, _ = load_db()
            if SSH_ACCOUNTING:
                collect_ssh_traffic()
            collect_xray_traffic(email_map)
        except Exception as e:
            log('traffic error: %s', e)

def enforce_expiration(users):
    changed = []
    now = datetime.now()
    conn = sqlite3.connect(DB_PATH, timeout=30)
    try:
        c = conn.cursor()
        for un, u in users.items():
            if u['status'] != 1:
                continue
            reason = None
            try:
                if u['expire_date'] and datetime.strptime(u['expire_date'], '%Y-%m-%d %H:%M') < now:
                    reason = 'expired'
            except Exception:
                pass
            tot = float(u['total_traffic'] or 0)
            used = float(u['used_traffic'] or 0)
            if tot > 0 and used >= tot:
                reason = reason or 'traffic-full'
            if reason:
                if c.execute("UPDATE users SET status=0 WHERE username=? AND status=1", (un,)).rowcount:
                    changed.append((un, reason))
        if changed:
            conn.commit()
    finally:
        conn.close()
    for un, reason in changed:
        subprocess.run(['usermod', '-L', un], capture_output=True, timeout=5)
        subprocess.run(['pkill', '-KILL', '-u', un], capture_output=True, timeout=5)
        log('AUTO-DISABLED %s (%s)', un, reason)
    if changed:
        subprocess.run(['python3', '/root/ssh-panel/sync_xray.py'], capture_output=True, timeout=40)

def prune(now):
    for un in list(activity):
        for ip, st in list(activity[un].items()):
            if now - st['last'] > IP_MAP_TTL:
                del activity[un][ip]
        if not activity[un]:
            del activity[un]

def write_state(online):
    tmp = ONLINE_FILE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump({'ts': time.time(), 'users': online}, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, ONLINE_FILE)
    try:
        os.chmod(ONLINE_FILE, 0o644)
    except Exception:
        pass

def cycle():
    global _lastcount
    now = time.time()
    users, email_map, ports = load_db()
    feed(read_new_lines(), email_map, now)
    prune(now)
    est = established_peer_ips(ports)
    ssh = ssh_sessions()
    unblock_expired(ports)
    if SSH_ACCOUNTING:
        sync_uid_rules(users)
    enforce_expiration(users)

    online = {}
    for uname, u in users.items():
        if u['status'] != 1:
            continue
        try:
            limit = int(u['max_connections'])
        except (TypeError, ValueError):
            limit = 2
        if limit < 0:
            limit = 0

        act = activity.get(uname, {})
        xset = set()
        for ip, st in act.items():
            recent = (now - st['last']) <= WINDOW
            alive = (est is not None) and (ip in est) and ((now - st['last']) <= XRAY_TTL)
            if recent or alive:
                xset.add(ip)

        ssh_list = ssh.get(uname, [])
        ssh_count = len(ssh_list)
        if ssh_count == 0 and not xset:
            continue

        total = ssh_count + len(xset)
        over = (limit > 0) and (total > limit)
        online[uname] = {
            'ssh': ssh_count, 'xray': bool(xset),
            'ssh_count': ssh_count, 'xray_ips': len(xset),
            'ips': sorted(xset), 'limit': limit,
            'over_limit': over, 'ts': now,
        }

        if over:
            log('OVER-LIMIT %s: ssh=%d xray_devices=%d limit=%d',
                uname, ssh_count, len(xset), limit)
            if ENFORCE_SSH:
                allowed = max(0, limit - len(xset))
                for s in sorted(ssh_list, key=lambda s: -s['pid'])[allowed:]:
                    try:
                        os.kill(s['pid'], signal.SIGTERM)
                        log('  closed extra ssh pid=%d (%s)', s['pid'], uname)
                    except Exception as e:
                        log('  kill fail %s: %s', uname, e)
            if ENFORCE_XRAY and len(xset) > limit:
                keep = set(sorted(xset, key=lambda ip: act[ip]['first'])[:limit])
                for ip in xset - keep:
                    block_ip(ip, ports)

    write_state(online)
    if len(online) != _lastcount:
        log('online users: %d -> %s', len(online), sorted(online))
        _lastcount = len(online)

def seed_from_log():
    global log_pos
    try:
        size = os.path.getsize(XRAY_LOG)
    except OSError:
        log_pos = 0
        return
    start = max(0, size - SEED_BYTES)
    try:
        with open(XRAY_LOG, 'rb') as f:
            f.seek(start)
            data = f.read()
        if start > 0:
            nl = data.find(b'\n')
            data = data[nl + 1:] if nl != -1 else b''
        log_pos = size
        _, email_map, _ = load_db()
        log('seeded %d entries', feed(data.decode('utf-8', 'replace').splitlines(), email_map, time.time()))
    except Exception as e:
        log('seed error: %s', e)

if __name__ == '__main__':
    ensure_chain()
    subprocess.run(['iptables', '-F', LIMIT_CHAIN], capture_output=True)
    ensure_traffic_hooks()
    seed_from_log()
    if SSH_ACCOUNTING:
        users, _, _ = load_db()
        bootstrap_ssh_traffic(users)
    log('worker started (grpc=%s, ssh_acct=%s)', HAS_GRPC, SSH_ACCOUNTING)
    threading.Thread(target=traffic_loop, daemon=True).start()
    while True:
        try:
            cycle()
        except Exception as e:
            log('cycle error: %s', e)
        time.sleep(CHECK_INTERVAL)
EOFWORKER
chmod +x /root/ssh-panel/worker.py
verify_py /root/ssh-panel/worker.py

# ============================================
# [10/14] Stylesheet
# ============================================
echo "[10/14] Creating stylesheet..."
mkdir -p /root/ssh-panel/static
cat << 'EOFCSS' > /root/ssh-panel/static/style.css
:root{--bg:#0b0f17;--card:#141b26;--line:#233043;--txt:#e6edf3;--dim:#8b98a9;--acc:#3b82f6;--ok:#22c55e;--warn:#f59e0b;--err:#ef4444}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--txt);font-family:Vazirmatn,Tahoma,sans-serif;direction:rtl;min-height:100vh}
.wrap{max-width:1200px;margin:0 auto;padding:24px 16px}
h1{font-size:1.35rem;margin-bottom:18px}h2{font-size:1.05rem;margin:18px 0 10px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin-bottom:20px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px;text-align:center}
.card .v{font-size:1.4rem;font-weight:700}.card .l{color:var(--dim);font-size:.78rem;margin-top:4px}
table{width:100%;border-collapse:collapse;background:var(--card);border-radius:12px;overflow:auto;display:block}
th,td{padding:9px 11px;border-bottom:1px solid var(--line);font-size:.83rem;text-align:right;white-space:nowrap}
th{background:#1a2332;color:var(--dim)}
.btn{display:inline-block;background:var(--acc);color:#fff;border:none;border-radius:8px;padding:8px 16px;cursor:pointer;font-size:.85rem;text-decoration:none;font-family:inherit}
.btn.sec{background:#26334a}.btn.danger{background:var(--err)}.btn.ok{background:var(--ok)}.btn.sm{padding:4px 10px;font-size:.74rem}
.badge{display:inline-block;padding:3px 9px;border-radius:999px;font-size:.7rem;margin:1px}
.b-ok{background:rgba(34,197,94,.15);color:var(--ok)}.b-err{background:rgba(239,68,68,.15);color:var(--err)}
.b-warn{background:rgba(245,158,11,.15);color:var(--warn)}.b-dim{background:rgba(139,152,169,.15);color:var(--dim)}
.bar{height:6px;background:#1d2839;border-radius:4px;overflow:hidden;margin-top:4px;min-width:90px}
.bar>i{display:block;height:100%;background:var(--acc)}
form.panel{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:20px;max-width:520px;margin-bottom:16px}
label{display:block;color:var(--dim);font-size:.8rem;margin:12px 0 4px}
input,select{width:100%;background:#0d1420;border:1px solid var(--line);color:var(--txt);border-radius:8px;padding:9px;font-family:inherit;font-size:.9rem}
input[type=checkbox]{width:auto}
.modal-bg{display:none;position:fixed;inset:0;background:rgba(0,0,0,.65);z-index:50;align-items:center;justify-content:center}
.modal-bg.open{display:flex}
.modal{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:20px;width:min(560px,92vw);max-height:90vh;overflow:auto}
.flash{padding:10px 14px;border-radius:8px;margin-bottom:12px;font-size:.85rem}
.f-ok{background:rgba(34,197,94,.15);color:var(--ok)}.f-err{background:rgba(239,68,68,.15);color:var(--err)}
code.mono{background:#0d1420;padding:3px 7px;border-radius:6px;font-size:.76rem;direction:ltr;display:inline-block;max-width:340px;overflow:auto;vertical-align:middle}
.nav{display:flex;gap:16px;margin-bottom:18px;flex-wrap:wrap}
.nav a{color:var(--dim);text-decoration:none;font-size:.9rem;padding:6px 0;border-bottom:2px solid transparent}
.nav a.on,.nav a:hover{color:var(--acc);border-color:var(--acc)}
.qr{text-align:center;margin-top:10px}.qr img{max-width:170px;background:#fff;padding:6px;border-radius:8px}
details{margin-top:4px}
EOFCSS
echo "✓ Stylesheet created"

# ============================================
# [11/14] Templates
# ============================================
echo "[11/14] Creating templates..."

cat << 'EOFLOGIN' > /root/ssh-panel/templates/login.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ورود | OutlineParsian</title><link rel="stylesheet" href="/static/style.css"></head>
<body><div class="wrap" style="display:flex;align-items:center;justify-content:center;min-height:100vh">
<form class="panel" method="post" style="width:100%;max-width:380px">
<h1 style="text-align:center">🔐 OutlineParsian</h1>
{% if error %}<div class="flash f-err">{{ error }}</div>{% endif %}
<label>نام کاربری</label><input name="username" required autofocus>
<label>رمز عبور</label><input name="password" type="password" required>
<div style="margin-top:16px"><button class="btn" style="width:100%">ورود</button></div>
</form></div></body></html>
EOFLOGIN

cat << 'EOFDASH' > /root/ssh-panel/templates/dashboard.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>داشبورد</title><link rel="stylesheet" href="/static/style.css"></head>
<body><div class="wrap">
<div class="nav"><a class="on" href="/dashboard">داشبورد</a><a href="/inbounds">اینباندها</a><a href="/groups">گروه‌ها</a><a href="/reports">گزارش‌ها</a><a href="/settings">تنظیمات</a><a href="/logout">خروج</a></div>
{% with msgs = get_flashed_messages(with_categories=true) %}{% for cat,m in msgs %}<div class="flash {{ 'f-ok' if cat=='success' else 'f-err' }}">{{ m }}</div>{% endfor %}{% endwith %}
<div class="cards">
<div class="card"><div class="v">{{ total_users }}</div><div class="l">کاربران</div></div>
<div class="card"><div class="v">{{ active_users }}</div><div class="l">فعال</div></div>
<div class="card"><div class="v">{{ total_inbounds }}</div><div class="l">اینباند</div></div>
<div class="card"><div class="v">{{ total_clients }}</div><div class="l">کلاینت Xray</div></div>
<div class="card"><div class="v">{{ total_used }}</div><div class="l">مصرف (GB)</div></div>
<div class="card"><div class="v">{{ cpu }}%</div><div class="l">CPU</div></div>
<div class="card"><div class="v">{{ ram }}%</div><div class="l">RAM</div></div>
</div>
<div style="margin-bottom:12px"><a class="btn ok" href="/add_user_page">＋ افزودن کاربر</a></div>
<table>
<tr><th>کاربر</th><th>رمز</th><th>وضعیت</th><th>انقضا</th><th>مصرف</th><th>آنلاین</th><th>ساب</th><th>عملیات</th></tr>
{% for u in users %}
<tr>
<td><b>{{ u.username }}</b></td>
<td><code class="mono">{{ u.password }}</code></td>
<td>{% if u.status==1 %}<span class="badge b-ok">فعال</span>{% else %}<span class="badge b-err">غیرفعال</span>{% endif %}</td>
<td>{{ u.expire_date }}{% if u.days_left is not none %} <span class="badge {{ 'b-err' if u.days_left<3 else 'b-warn' if u.days_left<7 else 'b-dim' }}">{{ u.days_left }} روز</span>{% endif %}</td>
<td>{{ u.used_traffic }} / {{ u.total_traffic if u.total_traffic>0 else '∞' }} GB{% if u.total_traffic>0 %}<div class="bar"><i style="width:{{ u.progress }}%"></i></div>{% endif %}</td>
<td>{% if u.is_online %}<span class="badge b-ok">آنلاین</span><span class="badge b-dim">{{ u.online_count }} دستگاه</span>{% if u.ssh_count %}<span class="badge b-dim">SSH:{{ u.ssh_count }}</span>{% endif %}{% if u.xray_ips %}<span class="badge b-dim">Xray:{{ u.xray_ips }}</span>{% endif %}{% if u.over_limit %}<span class="badge b-err">بیش از حد!</span>{% endif %}{% else %}<span class="badge b-dim">آفلاین</span>{% endif %}</td>
<td><button class="btn sec sm" onclick="copyTxt('{{ u.sub_link }}')">کپی لینک</button></td>
<td><button class="btn sm" onclick="openEdit('{{ loop.index }}')">ویرایش</button> <a class="btn danger sm" href="/delete_user/{{ u.username }}" onclick="return confirm('حذف کامل {{ u.username }}؟')">حذف</a></td>
</tr>
{% endfor %}
</table>
{% for u in users %}
<div class="modal-bg" id="m{{ loop.index }}">
<form class="modal" method="post" action="/edit_user">
<input type="hidden" name="csrf_token" value="{{ csrf_token }}">
<input type="hidden" name="username" value="{{ u.username }}">
<h3>ویرایش {{ u.username }}</h3>
<label>رمز عبور (خالی = بدون تغییر)</label><input name="password" value="{{ u.password }}">
<label>حجم کل (GB — صفر = نامحدود)</label><input name="traffic_gb" type="number" step="0.01" value="{{ u.total_traffic }}">
<label>حداکثر اتصال همزمان (صفر = نامحدود)</label><input name="max_connections" type="number" value="{{ u.max_connections }}" min="0">
<label>تاریخ انقضا</label><input name="expire_date" value="{{ u.expire_date }}">
<label>وضعیت</label><select name="status"><option value="1" {{ 'selected' if u.status==1 }}>فعال</option><option value="0" {{ 'selected' if u.status==0 }}>غیرفعال</option></select>
<label><input type="checkbox" name="reset_traffic"> صفر کردن مصرف</label>
<label><input type="checkbox" name="reset_expire"> ریست تاریخ به</label><input name="reset_days" type="number" value="30" min="1">
<label>تمدید (روز)</label><input name="extend_days" type="number" value="0" min="0">
<div style="margin-top:14px;display:flex;gap:8px"><button class="btn ok">ذخیره</button><button type="button" class="btn sec" onclick="closeEdit('{{ loop.index }}')">انصراف</button></div>
</form>
</div>
{% endfor %}
<script>
function openEdit(i){document.getElementById('m'+i).classList.add('open')}
function closeEdit(i){document.getElementById('m'+i).classList.remove('open')}
function copyTxt(t){navigator.clipboard.writeText(t).then(function(){alert('کپی شد ✅')})}
</script>
</div></body></html>
EOFDASH

cat << 'EOFADDU' > /root/ssh-panel/templates/add_user.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>افزودن کاربر</title><link rel="stylesheet" href="/static/style.css"></head>
<body><div class="wrap">
<div class="nav"><a href="/dashboard">→ داشبورد</a></div>
{% with msgs = get_flashed_messages(with_categories=true) %}{% for cat,m in msgs %}<div class="flash {{ 'f-ok' if cat=='success' else 'f-err' }}">{{ m }}</div>{% endfor %}{% endwith %}
<form class="panel" method="post" action="/add_user">
<input type="hidden" name="csrf_token" value="{{ csrf_token }}">
<h1>＋ افزودن کاربر</h1>
<label>نام کاربری (حروف کوچک انگلیسی — ۳ تا ۳۲ کاراکتر)</label><input name="username" pattern="[a-z][a-z0-9_-]{2,31}" required>
<label>رمز عبور (حداقل ۴ کاراکتر، بدون «:»)</label><input name="password" minlength="4" required>
<label>مدت اعتبار (روز)</label><input name="expire_days" type="number" value="30" min="1">
<label>حجم کل (GB — صفر = نامحدود)</label><input name="traffic_gb" type="number" step="0.01" value="0" min="0">
<label>حداکثر اتصال همزمان (صفر = نامحدود)</label><input name="max_connections" type="number" value="2" min="0">
<div style="margin-top:16px"><button class="btn ok">ایجاد کاربر</button> <a class="btn sec" href="/dashboard">بازگشت</a></div>
</form></div></body></html>
EOFADDU

cat << 'EOFIB' > /root/ssh-panel/templates/inbounds.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>اینباندها</title><link rel="stylesheet" href="/static/style.css"></head>
<body><div class="wrap">
<div class="nav"><a href="/dashboard">داشبورد</a><a class="on" href="/inbounds">اینباندها</a><a href="/groups">گروه‌ها</a><a href="/reports">گزارش‌ها</a><a href="/settings">تنظیمات</a><a href="/logout">خروج</a></div>
{% with msgs = get_flashed_messages(with_categories=true) %}{% for cat,m in msgs %}<div class="flash {{ 'f-ok' if cat=='success' else 'f-err' }}">{{ m }}</div>{% endfor %}{% endwith %}
<h1>اینباندهای Xray</h1>
<div style="margin-bottom:12px"><a class="btn ok" href="/add_inbound_page">＋ اینباند جدید</a></div>
<table>
<tr><th>Tag</th><th>پروتکل</th><th>پورت</th><th>شبکه</th><th>امنیت</th><th>کلاینت‌ها</th><th>وضعیت</th><th>عملیات</th></tr>
{% for ib in inbounds %}
<tr><td><b>{{ ib.tag }}</b></td><td>{{ ib.protocol|upper }}</td><td>{{ ib.port }}</td><td>{{ ib.network }}</td>
<td>{{ ib.security }}</td><td>{{ ib.client_count }}</td>
<td>{% if ib.status==1 %}<span class="badge b-ok">فعال</span>{% else %}<span class="badge b-err">غیرفعال</span>{% endif %}</td>
<td><a class="btn sm" href="/clients/{{ ib.id }}">کلاینت‌ها</a> <a class="btn danger sm" href="/delete_inbound/{{ ib.id }}" onclick="return confirm('حذف اینباند {{ ib.tag }}؟')">حذف</a></td></tr>
{% endfor %}
</table></div></body></html>
EOFIB

cat << 'EOFADDIB' > /root/ssh-panel/templates/add_inbound.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>اینباند جدید</title><link rel="stylesheet" href="/static/style.css"></head>
<body><div class="wrap">
<div class="nav"><a href="/inbounds">→ اینباندها</a></div>
{% with msgs = get_flashed_messages(with_categories=true) %}{% for cat,m in msgs %}<div class="flash {{ 'f-ok' if cat=='success' else 'f-err' }}">{{ m }}</div>{% endfor %}{% endwith %}
<form class="panel" method="post" action="/add_inbound">
<input type="hidden" name="csrf_token" value="{{ csrf_token }}">
<h1>＋ اینباند جدید</h1>
<label>نام (Tag)</label><input name="tag" pattern="[A-Za-z0-9_-]{1,32}" required>
<label>پروتکل</label><select name="protocol"><option value="vless">VLESS</option><option value="vmess">VMess</option><option value="trojan">Trojan</option></select>
<label>پورت</label><input name="port" type="number" value="{{ random_port }}" min="1" max="65535" required>
<label>شبکه</label><select name="network"><option value="tcp">TCP</option><option value="ws">WebSocket</option><option value="grpc">gRPC</option></select>
<label>امنیت</label><select name="security"><option value="reality">Reality</option><option value="none">None</option><option value="tls">TLS</option></select>
<label>Server Name (SNI)</label><input name="server_name" value="www.microsoft.com">
<label>Fingerprint</label><select name="fingerprint"><option>chrome</option><option>firefox</option><option>safari</option><option>ios</option><option>android</option><option>edge</option></select>
<label>Short ID (Reality)</label><input name="short_id" value="">
<label>Path (برای ws/grpc)</label><input name="path" value="/">
<div style="margin-top:16px"><button class="btn ok">ایجاد</button> <a class="btn sec" href="/inbounds">بازگشت</a></div>
</form></div></body></html>
EOFADDIB

cat << 'EOFCL' > /root/ssh-panel/templates/clients.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>کلاینت‌ها</title><link rel="stylesheet" href="/static/style.css"></head>
<body><div class="wrap">
<div class="nav"><a href="/inbounds">→ اینباندها</a></div>
{% with msgs = get_flashed_messages(with_categories=true) %}{% for cat,m in msgs %}<div class="flash {{ 'f-ok' if cat=='success' else 'f-err' }}">{{ m }}</div>{% endfor %}{% endwith %}
<h1>کلاینت‌های «{{ inbound.tag }}»</h1>
<div class="cards">
<div class="card"><div class="v">{{ inbound.protocol|upper }}</div><div class="l">پروتکل</div></div>
<div class="card"><div class="v">{{ inbound.port }}</div><div class="l">پورت</div></div>
<div class="card"><div class="v">{{ inbound.network }}</div><div class="l">شبکه</div></div>
<div class="card"><div class="v">{{ inbound.security }}</div><div class="l">امنیت</div></div>
</div>
<table>
<tr><th>کاربر</th><th>UUID</th><th>لینک</th><th>عملیات</th></tr>
{% for cl in clients %}
<tr><td><b>{{ cl.username }}</b></td><td><code class="mono">{{ cl.uuid[:13] }}…</code></td>
<td><button class="btn sec sm" onclick="copyTxt('{{ cl.link }}')">کپی لینک</button>
<details><summary style="cursor:pointer;font-size:.75rem;color:#8b98a9">نمایش</summary><code class="mono">{{ cl.link }}</code></details></td>
<td><a class="btn danger sm" href="/delete_client/{{ cl.id }}" onclick="return confirm('حذف؟')">حذف</a></td></tr>
{% endfor %}
</table>
<form class="panel" method="post" action="/add_clients/{{ inbound.id }}">
<input type="hidden" name="csrf_token" value="{{ csrf_token }}">
<h2>افزودن کلاینت</h2>
<label>کاربران (Ctrl برای چند انتخاب)</label>
<select name="usernames" multiple size="6" required>
{% for a in available_users %}<option value="{{ a }}">{{ a }}</option>{% endfor %}
</select>
<div style="margin-top:14px"><button class="btn ok">افزودن</button></div>
</form>
<script>function copyTxt(t){navigator.clipboard.writeText(t).then(function(){alert('کپی شد ✅')})}</script>
</div></body></html>
EOFCL

cat << 'EOFGRP' > /root/ssh-panel/templates/groups.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>گروه‌ها</title><link rel="stylesheet" href="/static/style.css"></head>
<body><div class="wrap">
<div class="nav"><a href="/dashboard">داشبورد</a><a href="/inbounds">اینباندها</a><a class="on" href="/groups">گروه‌ها</a><a href="/reports">گزارش‌ها</a><a href="/settings">تنظیمات</a><a href="/logout">خروج</a></div>
{% with msgs = get_flashed_messages(with_categories=true) %}{% for cat,m in msgs %}<div class="flash {{ 'f-ok' if cat=='success' else 'f-err' }}">{{ m }}</div>{% endfor %}{% endwith %}
<h1>گروه‌های کاربری</h1>
<form class="panel" method="post" action="/add_group">
<input type="hidden" name="csrf_token" value="{{ csrf_token }}">
<label>نام گروه</label><input name="name" required>
<label>توضیحات</label><input name="description">
<div style="margin-top:12px"><button class="btn ok">ایجاد گروه</button></div>
</form>
<table>
<tr><th>نام</th><th>توضیحات</th><th>اعضا</th><th>عملیات</th></tr>
{% for g in groups %}
<tr><td><b>{{ g.name }}</b></td><td>{{ g.description }}</td><td>{{ g.member_count }}</td>
<td><a class="btn sm" href="/group_members/{{ g.id }}">اعضا</a> <a class="btn danger sm" href="/delete_group/{{ g.id }}" onclick="return confirm('حذف گروه؟')">حذف</a></td></tr>
{% endfor %}
</table></div></body></html>
EOFGRP

cat << 'EOFGRPM' > /root/ssh-panel/templates/group_members.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>اعضا</title><link rel="stylesheet" href="/static/style.css"></head>
<body><div class="wrap">
<div class="nav"><a href="/groups">→ گروه‌ها</a></div>
{% with msgs = get_flashed_messages(with_categories=true) %}{% for cat,m in msgs %}<div class="flash {{ 'f-ok' if cat=='success' else 'f-err' }}">{{ m }}</div>{% endfor %}{% endwith %}
<h1>اعضای گروه «{{ group.name }}»</h1>
<table>
<tr><th>کاربر</th><th>عملیات</th></tr>
{% for m in members %}<tr><td><b>{{ m }}</b></td>
<td><a class="btn danger sm" href="/remove_group_member/{{ group.id }}/{{ m }}">حذف</a></td></tr>
{% endfor %}
</table>
<form class="panel" method="post" action="/add_group_members/{{ group.id }}">
<input type="hidden" name="csrf_token" value="{{ csrf_token }}">
<h2>افزودن عضو</h2>
<select name="usernames" multiple size="6" required>
{% for a in available_users %}<option value="{{ a }}">{{ a }}</option>{% endfor %}
</select>
<div style="margin-top:12px"><button class="btn ok">افزودن</button></div>
</form></div></body></html>
EOFGRPM

cat << 'EOFRP' > /root/ssh-panel/templates/reports.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>گزارش‌ها</title><link rel="stylesheet" href="/static/style.css"></head>
<body><div class="wrap">
<div class="nav"><a href="/dashboard">داشبورد</a><a href="/inbounds">اینباندها</a><a href="/groups">گروه‌ها</a><a class="on" href="/reports">گزارش‌ها</a><a href="/settings">تنظیمات</a><a href="/logout">خروج</a></div>
<h1>گزارش کلی</h1>
<div class="cards">
<div class="card"><div class="v">{{ summary.total_users }}</div><div class="l">کاربران</div></div>
<div class="card"><div class="v">{{ '%.2f'|format(summary.total_traffic_gb or 0) }}</div><div class="l">حجم کل (GB)</div></div>
<div class="card"><div class="v">{{ '%.2f'|format(summary.used_traffic_gb or 0) }}</div><div class="l">مصرف (GB)</div></div>
<div class="card"><div class="v">{{ ib_count }}</div><div class="l">اینباند فعال</div></div>
<div class="card"><div class="v">{{ cl_count }}</div><div class="l">کلاینت فعال</div></div>
<div class="card"><div class="v">{{ cpu }}%</div><div class="l">CPU</div></div>
<div class="card"><div class="v">{{ ram }}%</div><div class="l">RAM</div></div>
</div></div></body></html>
EOFRP

cat << 'EOFSET' > /root/ssh-panel/templates/settings.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>تنظیمات</title><link rel="stylesheet" href="/static/style.css"></head>
<body><div class="wrap">
<div class="nav"><a href="/dashboard">داشبورد</a><a href="/inbounds">اینباندها</a><a href="/groups">گروه‌ها</a><a href="/reports">گزارش‌ها</a><a class="on" href="/settings">تنظیمات</a><a href="/logout">خروج</a></div>
{% with msgs = get_flashed_messages(with_categories=true) %}{% for cat,m in msgs %}<div class="flash {{ 'f-ok' if cat=='success' else 'f-err' }}">{{ m }}</div>{% endfor %}{% endwith %}
<h1>تنظیمات</h1>
<form class="panel" method="post">
<input type="hidden" name="csrf_token" value="{{ csrf_token }}">
<input type="hidden" name="action" value="save_settings">
<h2>عمومی</h2>
<label>دامنه / IP سرور</label><input name="domain" value="{{ domain }}">
<label>نام کاربری مدیر</label><input name="admin_username" value="{{ admin_username }}">
<label>رمز مدیر (خالی = بدون تغییر)</label><input name="admin_password" type="password">
<label>پورت پنل (برای اعمال: systemctl restart ssh-panel)</label><input name="panel_port" value="{{ panel_port }}">
<label>دامنه SSL (برای اینباندهای TLS — گواهی را با certbot بسازید)</label><input name="ssl_domain" value="{{ ssl_domain }}">
<label><input type="checkbox" name="block_iran" {{ 'checked' if block_iran_client=='1' }}> مسدودسازی اتصالات سرور به مقاصد ایرانی</label>
<div style="margin-top:14px"><button class="btn ok">ذخیره</button></div>
</form>
<form class="panel" method="post">
<input type="hidden" name="csrf_token" value="{{ csrf_token }}">
<input type="hidden" name="action" value="generate_keys">
<h2>کلیدهای Reality</h2>
<label>Public Key فعلی</label><input value="{{ reality_public_key }}" readonly>
<div style="margin-top:12px"><button class="btn">تولید کلیدهای جدید</button></div>
</form>
<div class="panel">
<h2>پشتیبان‌گیری</h2>
<p style="font-size:.8rem;color:#8b98a9;margin:10px 0">دانلود بکاپ کامل دیتابیس یا بازگردانی از فایل قبلی</p>
<a class="btn ok" href="/backup_download">⬇ دانلود بکاپ</a>
<form method="post" action="/backup_upload" enctype="multipart/form-data" style="margin-top:14px">
<input type="hidden" name="csrf_token" value="{{ csrf_token }}">
<input type="file" name="backup_file" accept=".db" required>
<div style="margin-top:10px"><button class="btn danger">بازگردانی از فایل</button></div>
</form>
</div>
</div></body></html>
EOFSET

cat << 'EOFSUB' > /root/ssh-panel/templates/sub.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>اشتراک {{ username }}</title><link rel="stylesheet" href="/static/style.css"></head>
<body><div class="wrap">
<h1>🎁 اشتراک {{ username }}</h1>
<div class="cards">
<div class="card"><div class="v">{% if status=='1' %}<span class="badge b-ok">فعال</span>{% else %}<span class="badge b-err">غیرفعال</span>{% endif %}</div><div class="l">وضعیت</div></div>
<div class="card"><div class="v" style="font-size:1rem">{{ expire_date }}</div><div class="l">{{ days_left }} روز باقیمانده</div></div>
<div class="card"><div class="v" style="font-size:1rem">{{ used_traffic }} / {{ total_traffic }}</div><div class="l">مصرف</div><div class="bar"><i style="width:{{ progress_percent }}%"></i></div></div>
<div class="card"><div class="v" style="font-size:1rem">{{ remaining_traffic }}</div><div class="l">باقیمانده</div></div>
<div class="card"><div class="v" style="font-size:1rem">{{ max_conn }}</div><div class="l">حد اتصال همزمان</div></div>
</div>
<h2>🔐 SSH</h2>
<div class="card" style="text-align:right">
<p style="font-size:.85rem">کاربر: <code class="mono">{{ username }}</code> رمز: <code class="mono">{{ password }}</code></p>
<code class="mono" style="margin:10px 0">{{ ssh_uri }}</code><br>
<button class="btn sec sm" onclick="copyTxt('{{ ssh_uri }}')">کپی لینک SSH</button>
{% if ssh_qr %}<div class="qr"><img src="data:image/png;base64,{{ ssh_qr }}" alt="QR"></div>{% endif %}
</div>
<h2>⚡ کانفیگ‌های Xray</h2>
{% for x in xray_configs %}
<div class="panel" style="max-width:none">
<b>{{ x.tag }}</b> <span class="badge b-dim">{{ x.protocol|upper }} · {{ x.net }} · {{ x.sec }} · پورت {{ x.port }}</span>
<div style="margin:10px 0"><code class="mono" style="max-width:100%">{{ x.link }}</code></div>
<button class="btn sec sm" onclick="copyTxt('{{ x.link }}')">کپی لینک</button>
<a class="btn sec sm" href="{{ x.nepster_link }}">دانلود Nepster</a>
<a class="btn sec sm" href="{{ x.netmod_link }}">دانلود NetMod</a>
{% if x.qr_code %}<div class="qr"><img src="data:image/png;base64,{{ x.qr_code }}" alt="QR"></div>{% endif %}
</div>
{% else %}
<div class="card"><div class="l">کانفیگ Xray برای این کاربر ثبت نشده است</div></div>
{% endfor %}
<script>function copyTxt(t){navigator.clipboard.writeText(t).then(function(){alert('کپی شد ✅')})}</script>
</div></body></html>
EOFSUB

cat << 'EOFSUBE' > /root/ssh-panel/templates/sub_error.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><title>خطا</title><link rel="stylesheet" href="/static/style.css"></head>
<body><div class="wrap" style="display:flex;align-items:center;justify-content:center;min-height:100vh">
<div class="card" style="max-width:420px;padding:30px">
<h1>⚠ {{ error_message }}</h1>
<p style="color:#8b98a9;font-size:.85rem;margin-top:10px">در صورت مشکل با مدیر سرور تماس بگیرید</p>
</div></div></body></html>
EOFSUBE

cat << 'EOFERR' > /root/ssh-panel/templates/error.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><title>خطا</title><link rel="stylesheet" href="/static/style.css"></head>
<body><div class="wrap" style="display:flex;align-items:center;justify-content:center;min-height:100vh">
<div class="card" style="max-width:480px;padding:30px">
<h1>❌ خطا</h1>
<p style="color:#8b98a9;font-size:.85rem;margin-top:10px;direction:ltr;text-align:left">{{ error_message }}</p>
<a class="btn" href="/dashboard">بازگشت</a>
</div></div></body></html>
EOFERR

TPL_FAIL=0
for t in login dashboard add_user inbounds add_inbound clients groups group_members reports settings sub sub_error error; do
  f="/root/ssh-panel/templates/${t}.html"
  if [ ! -f "$f" ] || ! tail -1 "$f" | grep -q '</html>'; then
    echo "  ✗ قالب ${t}.html ناقص است!"
    TPL_FAIL=1
  fi
done
[ $TPL_FAIL -eq 0 ] && echo "✓ All templates complete" || die "قالب(ها) ناقص paste شده‌اند — اسکریپت را از مرحله [11/14] دوباره اجرا کنید"

# ============================================
# [12/14] Systemd services
# ============================================
echo "[12/14] Creating services..."
cat << 'SVCEOF1' > /etc/systemd/system/ssh-panel.service
[Unit]
Description=OutlineParsian Panel
After=network.target xray.service

[Service]
Type=simple
WorkingDirectory=/root/ssh-panel
ExecStart=/usr/bin/python3 /root/ssh-panel/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF1

cat << 'SVCEOF2' > /etc/systemd/system/ssh-panel-worker.service
[Unit]
Description=OutlineParsian Online/Traffic Worker
After=network.target xray.service

[Service]
Type=simple
WorkingDirectory=/root/ssh-panel
ExecStart=/usr/bin/python3 /root/ssh-panel/worker.py
Restart=always
RestartSec=3
ExecStopPost=/bin/sh -c "iptables -F OP_LIMIT 2>/dev/null; true"

[Install]
WantedBy=multi-user.target
SVCEOF2
systemctl daemon-reload
systemctl enable xray ssh ssh-panel ssh-panel-worker 2>/dev/null
echo "✓ Services created"

# ============================================
# [13/14] Firewall + Start
# ============================================
echo "[13/14] Firewall & starting services..."
PANEL_PORT=$(sqlite3 /root/ssh-panel/panel.db "SELECT value FROM settings WHERE key='panel_port';" 2>/dev/null)
[ -z "$PANEL_PORT" ] && PANEL_PORT=5000
iptables -C INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT 2>/dev/null || \
    iptables -A INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT
netfilter-persistent save 2>/dev/null

systemctl stop ssh-panel ssh-panel-worker 2>/dev/null
python3 /root/ssh-panel/sync_xray.py
systemctl restart xray
systemctl restart ssh-panel
systemctl restart ssh-panel-worker
sleep 5
echo "✓ Services started"

# ============================================
# [14/14] Final Report
# ============================================
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$SERVER_IP" ] && SERVER_IP="SERVER_IP"
ADMIN_USER=$(sqlite3 /root/ssh-panel/panel.db "SELECT value FROM settings WHERE key='admin_username';" 2>/dev/null)

echo ""
echo "=========================================================="
echo "  ✅ نصب OutlineParsian v4.1 کامل شد"
echo "=========================================================="
echo ""
for svc in xray ssh-panel ssh-panel-worker; do
  state=$(systemctl is-active $svc 2>/dev/null)
  if [ "$state" = "active" ]; then
    echo "  ✓ $svc : active"
  else
    echo "  ✗ $svc : $state  ←  برای دیدن خطا: journalctl -u $svc -n 20 --no-pager"
  fi
done
echo ""
echo "  پنل:   http://${SERVER_IP}:${PANEL_PORT}"
echo "  کاربر: ${ADMIN_USER}"
echo "  رمز:   admin123   (حتماً از تنظیمات تغییر دهید!)"
echo ""
echo "  تست سریع سلامت ورکر:"
echo "    tail -5 /tmp/worker.log"
echo "    python3 -m json.tool /tmp/online_users.json"
echo ""
