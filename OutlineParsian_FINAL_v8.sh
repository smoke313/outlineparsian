#!/bin/bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
trap 'echo "❌ Installer failed at line $LINENO" >&2' ERR
if [ "$(id -u)" -ne 0 ]; then echo "❌ Run this installer as root"; exit 1; fi
if ! command -v apt-get >/dev/null 2>&1; then echo "❌ Debian/Ubuntu (apt) is required"; exit 1; fi
# ============================================
# OutlineParsian Ultimate Panel - Production Final v8
# All Features | All Bugs Fixed | Production Ready
# SSH Traffic Counting + Xray Traffic
# Iran Block: Only outbound traffic to Iran blocked (inbound allowed)
# Backup Restore: Stable (mask/unmask method)
# ============================================

clear
cat << "BANNER"
   ____  _    _ _   _     _     ___  ____   ____   _    ____ ____  _    ____ _   _ 
  / __ \|  | | \ | |   | |   / _ \|  _ \ / ___| | |  / ___| _ \/ \  / ___| \ | |
 | |  | | |  | |  \| |   | | | | | | |_) | |     | | | |   | |_) / _ \ \___ \  \| |
 | |  | | |  | | . ` |   | |  | | | |  __/| |___  | | | |___|  _ < ___ \ ___) | |\  |
 | |__| | |__| | |\  |   | |__| |_| | |    \____| | |  \____|_| \_\   \_\____/|_| \_|
  \____/ \____/|_| \_| |_____\___/|_|          |_|
  
  OutlineParsian Ultimate Panel
BANNER

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     OutlineParsian Ultimate Panel                    ║"
echo "║     Complete Installation | Production Ready         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ============================================
# STEP 1: System Update & Prerequisites
# ============================================
echo "[1/16] Updating system and installing prerequisites..."
apt update -y
apt install -y python3 python3-pip python3-venv nginx ipset iptables curl netfilter-persistent iptables-persistent unzip wget sqlite3 net-tools jq certbot python3-certbot-nginx qrencode openssh-server chrony cron
true # Python dependencies are installed in the panel virtualenv below
systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || true
systemctl enable --now cron 2>/dev/null || true
echo "✓ Prerequisites installed"

# ============================================
# STEP 2: SSH Configuration
# ============================================
echo "[2/16] Configuring SSH safely..."
mkdir -p /etc/ssh/sshd_config.d
if [ -f /etc/ssh/sshd_config ] && [ ! -f /etc/ssh/sshd_config.outlineparsian.bak ]; then
    cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.outlineparsian.bak
fi
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
    sed -i '1iInclude /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi
cat << 'EOF' > /etc/ssh/sshd_config.d/99-outlineparsian.conf
Port 22
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
AllowTcpForwarding yes
GatewayPorts yes
MaxStartups 50:30:200
MaxSessions 50
EOF
if ! /usr/sbin/sshd -t; then
    echo "❌ SSH config validation failed; restoring previous config"
    rm -f /etc/ssh/sshd_config.d/99-outlineparsian.conf
    [ -f /etc/ssh/sshd_config.outlineparsian.bak ] && cp -a /etc/ssh/sshd_config.outlineparsian.bak /etc/ssh/sshd_config
    exit 1
fi
systemctl enable ssh
systemctl restart ssh
for p in 22 80 443; do
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
done
netfilter-persistent save >/dev/null 2>&1 || true
echo "✓ SSH and panel web ports configured safely"

# ============================================
# STEP 3: Directory Structure
# ============================================
echo "[3/16] Creating directory structure..."
mkdir -p /root/ssh-panel/templates /root/ssh-panel/static /root/ssh-panel/downloads /root/ssh-panel/backups /root/ssh-panel/xray_proto /usr/local/etc/xray /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log /var/log/panel.log
chmod 640 /var/log/xray/access.log /var/log/xray/error.log /var/log/panel.log
echo "✓ Directories created"
echo "[*] Creating isolated Python environment..."
python3 -m venv /root/ssh-panel/venv
/root/ssh-panel/venv/bin/pip install --upgrade pip wheel >/dev/null
/root/ssh-panel/venv/bin/pip install Flask psutil requests grpcio grpcio-tools protobuf qrcode pillow waitress >/dev/null
echo "✓ Python environment ready"

# ============================================
# STEP 4: Install Xray Core + gRPC
# ============================================
echo "[4/16] Installing Xray Core..."
if ! bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then echo "❌ Xray installation failed"; exit 1; fi

cat << 'PROTOEOF' > /root/ssh-panel/xray_proto/stats.proto
syntax = "proto3";
package xray.app.stats.command;
message QueryStatsRequest { string pattern = 1; bool reset = 2; }
message Stat { string name = 1; int64 value = 2; }
message QueryStatsResponse { repeated Stat stat = 1; }
service StatsService { rpc QueryStats(QueryStatsRequest) returns (QueryStatsResponse); }
PROTOEOF

cd /root/ssh-panel/xray_proto && /root/ssh-panel/venv/bin/python -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. stats.proto && cd /root
echo "✓ Xray Core + gRPC installed"

# ============================================
# STEP 5: Initialize Database
# ============================================
echo "[5/16] Initializing database..."
rm -f /tmp/outlineparsian_new_admin
if [ -f /root/ssh-panel/panel.db ]; then
    mkdir -p /root/ssh-panel/backups
    sqlite3 /root/ssh-panel/panel.db ".backup '/root/ssh-panel/backups/panel_pre_update_$(date +%Y%m%d_%H%M%S).db'" 2>/dev/null || true
    echo "✓ Existing database backed up before migration"
fi
/root/ssh-panel/venv/bin/python << 'PYEOF'
import sqlite3, os, secrets
from werkzeug.security import generate_password_hash
DB_PATH = "/root/ssh-panel/panel.db"
new_db = not os.path.exists(DB_PATH)
conn = sqlite3.connect(DB_PATH, timeout=30)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("PRAGMA synchronous=NORMAL")
conn.execute("PRAGMA foreign_keys=ON")
c = conn.cursor()
c.execute('''CREATE TABLE IF NOT EXISTS users (
    username TEXT PRIMARY KEY,
    password TEXT NOT NULL,
    expire_date TEXT,
    total_traffic REAL NOT NULL DEFAULT 0.0,
    used_traffic REAL NOT NULL DEFAULT 0.0,
    status INTEGER NOT NULL DEFAULT 1,
    max_connections INTEGER NOT NULL DEFAULT 2,
    created_at TEXT,
    last_xray_seen INTEGER NOT NULL DEFAULT 0,
    last_ssh_seen INTEGER NOT NULL DEFAULT 0,
    sub_token TEXT
)''')
c.execute('''CREATE TABLE IF NOT EXISTS xray_inbounds (id INTEGER PRIMARY KEY AUTOINCREMENT, tag TEXT UNIQUE, protocol TEXT, port INTEGER, network TEXT DEFAULT 'tcp', security TEXT DEFAULT 'none', server_name TEXT DEFAULT '', fingerprint TEXT DEFAULT 'chrome', short_id TEXT DEFAULT '', public_key TEXT DEFAULT '', private_key TEXT DEFAULT '', path TEXT DEFAULT '/', ss_method TEXT DEFAULT '', ss_password TEXT DEFAULT '', socks_auth TEXT DEFAULT 'noauth', status INTEGER DEFAULT 1, created_at TEXT)''')
c.execute('''CREATE TABLE IF NOT EXISTS xray_clients (id INTEGER PRIMARY KEY AUTOINCREMENT, inbound_id INTEGER, username TEXT, uuid TEXT, email TEXT, enable INTEGER DEFAULT 1, created_at TEXT, FOREIGN KEY (inbound_id) REFERENCES xray_inbounds(id) ON DELETE CASCADE, FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE)''')
c.execute('''CREATE TABLE IF NOT EXISTS user_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, description TEXT, created_at TEXT)''')
c.execute('''CREATE TABLE IF NOT EXISTS group_members (id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER, username TEXT, FOREIGN KEY (group_id) REFERENCES user_groups(id) ON DELETE CASCADE, FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE)''')
c.execute('''CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)''')
c.execute('''CREATE TABLE IF NOT EXISTS ssh_counters (session_key TEXT PRIMARY KEY, username TEXT NOT NULL, tx_bytes INTEGER NOT NULL DEFAULT 0, rx_bytes INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0)''')
c.execute('''CREATE TABLE IF NOT EXISTS xray_counters (stat_name TEXT PRIMARY KEY, username TEXT NOT NULL, byte_value INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0)''')
cols={row[1] for row in c.execute("PRAGMA table_info(users)")}
for name,ddl in [
 ('last_xray_seen','ALTER TABLE users ADD COLUMN last_xray_seen INTEGER NOT NULL DEFAULT 0'),
 ('last_ssh_seen','ALTER TABLE users ADD COLUMN last_ssh_seen INTEGER NOT NULL DEFAULT 0'),
 ('sub_token','ALTER TABLE users ADD COLUMN sub_token TEXT')]:
    if name not in cols:c.execute(ddl)
initial_password=None
existing_admin=c.execute("SELECT value FROM settings WHERE key='admin_password'").fetchone()
if existing_admin is None or existing_admin[0]=='admin123':
    initial_password=secrets.token_urlsafe(14)
    admin_hash=generate_password_hash(initial_password)
else:
    admin_hash=existing_admin[0]
defaults=[('domain',''),('admin_username','admin'),('admin_password',admin_hash),('block_iran_client','0'),('panel_port','5000'),('reality_public_key',''),('reality_private_key',''),('ssl_domain',''),('ssl_status','none'),('tls_cert_file',''),('tls_key_file','')]
for k,v in defaults:c.execute("INSERT OR IGNORE INTO settings(key,value) VALUES(?,?)",(k,v))
if existing_admin is not None and existing_admin[0]=='admin123':
    c.execute("UPDATE settings SET value=? WHERE key='admin_password'",(admin_hash,))
rows=c.execute("SELECT username,sub_token FROM users ORDER BY username").fetchall(); used=set()
for username,token in rows:
    if not token or token in used:
        token=secrets.token_urlsafe(32)
        while token in used:token=secrets.token_urlsafe(32)
        c.execute("UPDATE users SET sub_token=? WHERE username=?",(token,username))
    used.add(token)
# Repair duplicate rows left by older versions before adding uniqueness constraints.
c.execute("DELETE FROM xray_clients WHERE id NOT IN (SELECT MIN(id) FROM xray_clients GROUP BY inbound_id,username)")
c.execute("DELETE FROM group_members WHERE id NOT IN (SELECT MIN(id) FROM group_members GROUP BY group_id,username)")
for sql in [
 "CREATE INDEX IF NOT EXISTS idx_users_status ON users(status)",
 "CREATE INDEX IF NOT EXISTS idx_users_created ON users(created_at)",
 "CREATE INDEX IF NOT EXISTS idx_users_xray_seen ON users(last_xray_seen)",
 "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_sub_token ON users(sub_token)",
 "CREATE INDEX IF NOT EXISTS idx_clients_inbound ON xray_clients(inbound_id)",
 "CREATE INDEX IF NOT EXISTS idx_clients_username ON xray_clients(username)",
 "CREATE UNIQUE INDEX IF NOT EXISTS idx_clients_inbound_user ON xray_clients(inbound_id,username)",
 "CREATE UNIQUE INDEX IF NOT EXISTS idx_group_member_unique ON group_members(group_id,username)",
 "CREATE INDEX IF NOT EXISTS idx_ssh_counter_updated ON ssh_counters(updated_at)",
 "CREATE INDEX IF NOT EXISTS idx_xray_counter_updated ON xray_counters(updated_at)"]:
    c.execute(sql)
conn.commit(); conn.close()
if initial_password:
    path='/root/ssh-panel/initial_admin_credentials.txt'
    admin_user=candidate_admin='admin'
    try:
        tmp=sqlite3.connect(DB_PATH); row=tmp.execute("SELECT value FROM settings WHERE key='admin_username'").fetchone(); tmp.close(); admin_user=row[0] if row and row[0] else 'admin'
    except Exception: admin_user='admin'
    with open(path,'w') as f:f.write('username='+admin_user+'\npassword='+initial_password+'\n')
    os.chmod(path,0o600)
    with open('/tmp/outlineparsian_new_admin','w') as f:f.write(initial_password)
    os.chmod('/tmp/outlineparsian_new_admin',0o600)
    print('✓ Fresh admin credentials written to '+path)
print("✓ Database initialized/migrated without deleting existing users")
PYEOF

# ============================================
# STEP 6: Main Panel Application (app.py) - کامل با SSH counters
# ============================================
echo "[6/16] Creating panel application..."

cat << 'APPEOF' > /root/ssh-panel/app.py
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys, sqlite3, subprocess, time, json, uuid, base64, io, traceback, random, shutil, threading, re, secrets, pwd
from urllib.parse import quote
from datetime import datetime, timedelta
try:
    import psutil
    HAS_PSUTIL = True
except:
    HAS_PSUTIL = False
from flask import Flask, render_template_string, request, redirect, url_for, session, send_file, flash, Response, jsonify, abort
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.middleware.proxy_fix import ProxyFix
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s',
                   handlers=[logging.FileHandler('/var/log/panel.log'), logging.StreamHandler()])
logger = logging.getLogger('OP')

app = Flask(__name__)
# Waitress only listens on loopback, so trusting one local Nginx proxy hop is safe.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)
SECRET_FILE = '/root/ssh-panel/.secret_key'
if not os.path.exists(SECRET_FILE):
    with open(SECRET_FILE, 'w') as f:
        f.write(secrets.token_hex(32))
    os.chmod(SECRET_FILE, 0o600)
with open(SECRET_FILE, 'r') as f:
    app.secret_key = f.read().strip()
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE='Lax', PERMANENT_SESSION_LIFETIME=timedelta(hours=12), MAX_CONTENT_LENGTH=25*1024*1024)

def csrf_token():
    token=session.get('_csrf_token')
    if not token:
        token=secrets.token_urlsafe(32)
        session['_csrf_token']=token
    return token

app.jinja_env.globals['csrf_token']=csrf_token

@app.before_request
def protect_state_changes():
    if request.method in ('POST','PUT','PATCH','DELETE') and request.endpoint not in ('login',):
        if not session.get('logged_in'):
            return redirect(url_for('login'))
        supplied=request.form.get('csrf_token') or request.headers.get('X-CSRF-Token','')
        if not supplied or not secrets.compare_digest(supplied, csrf_token()):
            abort(400, description='CSRF token invalid')

@app.errorhandler(ValueError)
def handle_value_error(err):
    logger.warning(f'Validation error: {err}')
    if request.path.startswith('/settings'):
        flash(f'❌ {err}','error'); return redirect(url_for('settings'))
    return render_template('error.html', error_message=str(err)), 400

@app.after_request
def security_headers(response):
    response.headers.setdefault('X-Content-Type-Options','nosniff')
    response.headers.setdefault('X-Frame-Options','DENY')
    response.headers.setdefault('Referrer-Policy','same-origin')
    response.headers.setdefault('Permissions-Policy','camera=(), microphone=(), geolocation=()')
    return response

DB_PATH = '/root/ssh-panel/panel.db'
XRAY_CONFIG = '/usr/local/etc/xray/config.json'
XRAY_BIN = '/usr/local/bin/xray'
DOWNLOADS_DIR = '/root/ssh-panel/downloads'

if not os.path.exists(DOWNLOADS_DIR):
    os.makedirs(DOWNLOADS_DIR)

# ============================================
# LIVE SYSTEM STATS CACHE
# ============================================
system_stats = {'cpu': 0, 'ram': 0, 'last_update': 0}
login_failures = {}
login_lock = threading.Lock()

def login_client_ip():
    return (request.headers.get('X-Real-IP') or request.remote_addr or 'unknown').split(',')[0].strip()[:64]

def login_is_allowed(ip):
    now=time.time()
    with login_lock:
        recent=[t for t in login_failures.get(ip,[]) if now-t < 300]
        login_failures[ip]=recent
        return len(recent) < 8

def record_login_failure(ip):
    with login_lock:
        login_failures.setdefault(ip,[]).append(time.time())

def clear_login_failures(ip):
    with login_lock:
        login_failures.pop(ip,None)

def update_system_stats():
    global system_stats
    while True:
        try:
            if HAS_PSUTIL:
                cpu = psutil.cpu_percent(interval=1)
                ram = psutil.virtual_memory().percent
            else:
                try:
                    out = subprocess.check_output("top -bn1 | grep 'Cpu(s)'", shell=True, timeout=3).decode()
                    cpu = float(out.split(':')[1].split('%')[0].split(',')[3].strip()) if out else 0
                except:
                    cpu = 0
                try:
                    out = subprocess.check_output("free | grep Mem", shell=True, timeout=3).decode()
                    parts = out.split()
                    ram = round(int(parts[2])/int(parts[1])*100, 1) if len(parts) >= 3 else 0
                except:
                    ram = 0
            system_stats = {'cpu': cpu, 'ram': ram, 'last_update': time.time()}
        except:
            pass
        time.sleep(2)

stats_thread = threading.Thread(target=update_system_stats, daemon=True)
stats_thread.start()

def get_cpu():
    return system_stats.get('cpu', 0)

def get_ram():
    return system_stats.get('ram', 0)

def run_command(cmd, shell=False, timeout=15):
    try:
        return subprocess.run(cmd, shell=shell, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, text=False)
    except Exception as e:
        logger.warning(f"Command failed: {cmd}: {e}")
        return None

def get_random_port():
    while True:
        port = random.randint(10000, 65000)
        try:
            result = subprocess.run(['ss', '-tlnp'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            if f':{port}' not in result.stdout.decode():
                conn = get_db()
                c = conn.cursor()
                c.execute("SELECT COUNT(*) FROM xray_inbounds WHERE port=?", (port,))
                if c.fetchone()[0] == 0:
                    conn.close()
                    return port
                conn.close()
        except:
            return random.randint(10000, 65000)

def port_available(port):
    try:
        if int(port) in (22,80,get_panel_port()): return False
        conn=get_db(); exists=conn.execute('SELECT 1 FROM xray_inbounds WHERE port=?',(int(port),)).fetchone(); conn.close()
        if exists:return False
        r=subprocess.run(['ss','-ltnH'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=4)
        return not any(re.search(rf':{int(port)}(?:\s|$)',line) for line in r.stdout.splitlines())
    except Exception:return False

# ============================================
# SSH COUNTERS (CLEAN – No iptables rules)
# ============================================
def setup_ssh_counters(username):
    """No iptables rules needed. Traffic tracked natively via Kernel Socket Statistics"""
    return True

def remove_ssh_counters(username):
    """Clean implementation without firewall bloating"""
    pass

def valid_username(username):
    return bool(re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', username or '')) and username not in {'root','daemon','bin','sys','sync','games','man','lp','mail','news','uucp','proxy','www-data','backup','list','irc','gnats','nobody','systemd-network','systemd-timesync','messagebus','syslog','_apt','tss','uuidd','tcpdump','sshd','ubuntu','debian','centos','fedora','rocky','almalinux','ec2-user','operator'}

def set_system_password(username, password):
    if not valid_username(username) or not password or '\n' in password or ':' in password:
        return False
    try:
        subprocess.run(['chpasswd'], input=f'{username}:{password}\n', text=True, check=True, timeout=5)
        return True
    except Exception as e:
        logger.error(f"set_system_password({username}) failed: {e}")
        return False

def create_system_user(username, password):
    if not valid_username(username): return False
    try:
        result = subprocess.run(['id', username], capture_output=True, timeout=5)
        if result.returncode != 0:
            subprocess.run(['useradd', '-m', '-s', '/bin/bash', username], check=True, timeout=10)
        if not set_system_password(username,password): return False
        setup_ssh_counters(username)
        return True
    except Exception as e:
        logger.error(f"create_system_user({username}) failed: {e}")
        return False

def get_ssh_online_users():
    """Return per-user SSH session counts with one ss call + one ps call."""
    try:
        result=subprocess.run(['ss','-tnp','state','established','sport','=',':22'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=4,text=True)
        pids=sorted(set(re.findall(r'pid=(\d+)',result.stdout)))
        if not pids:return {}
        ps=subprocess.run(['ps','-o','pid=,user=,args=','-p',','.join(pids)],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=4,text=True)
        counts={}
        for line in ps.stdout.splitlines():
            parts=line.strip().split(None,2)
            if len(parts)<2:continue
            user=parts[1]; args=parts[2] if len(parts)>2 else ''; actual=user
            if user in ('root','sshd'):
                m=re.search(r'sshd:\s+([a-zA-Z0-9_-]+)',args)
                actual=m.group(1) if m and m.group(1) not in ('root','sshd','priv') else None
            if actual:counts[actual]=counts.get(actual,0)+1
        return counts
    except Exception as e:
        logger.debug(f"SSH online detection failed: {e}"); return {}

def get_xray_online_users():
    """Traffic worker updates last_xray_seen; dashboard never resets Xray counters."""
    cutoff = int(time.time()) - 30
    conn = get_db()
    try:
        rows = conn.execute("SELECT username FROM users WHERE last_xray_seen >= ?", (cutoff,)).fetchall()
        return {r['username'] for r in rows}
    finally:
        conn.close()

@app.route('/api/stats')
def api_stats():
    if not session.get('logged_in'):
        return jsonify({'error': 'Unauthorized'}), 401
    return jsonify({'cpu': get_cpu(), 'ram': get_ram()})

def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.row_factory = sqlite3.Row
    return conn

def ensure_schema():
    conn = get_db()
    try:
        c = conn.cursor()
        cols = {r['name'] for r in c.execute('PRAGMA table_info(users)').fetchall()}
        migrations = [
            ('last_xray_seen', 'ALTER TABLE users ADD COLUMN last_xray_seen INTEGER NOT NULL DEFAULT 0'),
            ('last_ssh_seen', 'ALTER TABLE users ADD COLUMN last_ssh_seen INTEGER NOT NULL DEFAULT 0'),
            ('sub_token', 'ALTER TABLE users ADD COLUMN sub_token TEXT')
        ]
        for name, ddl in migrations:
            if name not in cols:
                c.execute(ddl)
        c.execute("CREATE TABLE IF NOT EXISTS ssh_counters (session_key TEXT PRIMARY KEY, username TEXT NOT NULL, tx_bytes INTEGER NOT NULL DEFAULT 0, rx_bytes INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0)")
        c.execute("CREATE TABLE IF NOT EXISTS xray_counters (stat_name TEXT PRIMARY KEY, username TEXT NOT NULL, byte_value INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0)")
        runtime_defaults=[('domain',''),('admin_username','admin'),('block_iran_client','0'),('panel_port','5000'),('reality_public_key',''),('reality_private_key',''),('ssl_domain',''),('ssl_status','none'),('tls_cert_file',''),('tls_key_file','')]
        for k,v in runtime_defaults: c.execute("INSERT OR IGNORE INTO settings(key,value) VALUES(?,?)",(k,v))
        admin_pw=c.execute("SELECT value FROM settings WHERE key='admin_password'").fetchone()
        if admin_pw is None or admin_pw['value']=='admin123':
            new_pw=secrets.token_urlsafe(14)
            c.execute("INSERT OR REPLACE INTO settings(key,value) VALUES('admin_password',?)",(generate_password_hash(new_pw),))
            admin_row=c.execute("SELECT value FROM settings WHERE key='admin_username'").fetchone(); admin_user=admin_row['value'] if admin_row and admin_row['value'] else 'admin'
            cred='/root/ssh-panel/initial_admin_credentials.txt'
            with open(cred,'w') as f: f.write(f'username={admin_user}\npassword={new_pw}\n')
            os.chmod(cred,0o600)
            logger.warning('Legacy/default admin password was rotated; see initial_admin_credentials.txt')
        rows=c.execute("SELECT username,sub_token FROM users ORDER BY username").fetchall()
        used=set()
        for r in rows:
            token=r['sub_token']
            if not token or token in used:
                token=secrets.token_urlsafe(32)
                while token in used: token=secrets.token_urlsafe(32)
                c.execute("UPDATE users SET sub_token=? WHERE username=?",(token,r['username']))
            used.add(token)
        c.execute("DELETE FROM xray_clients WHERE id NOT IN (SELECT MIN(id) FROM xray_clients GROUP BY inbound_id,username)")
        c.execute("DELETE FROM group_members WHERE id NOT IN (SELECT MIN(id) FROM group_members GROUP BY group_id,username)")
        c.execute('CREATE INDEX IF NOT EXISTS idx_users_status ON users(status)')
        c.execute('CREATE INDEX IF NOT EXISTS idx_users_xray_seen ON users(last_xray_seen)')
        c.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_users_sub_token ON users(sub_token)')
        c.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_clients_inbound_user ON xray_clients(inbound_id,username)')
        c.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_group_member_unique ON group_members(group_id,username)')
        c.execute('CREATE INDEX IF NOT EXISTS idx_ssh_counter_updated ON ssh_counters(updated_at)')
        c.execute('CREATE INDEX IF NOT EXISTS idx_xray_counter_updated ON xray_counters(updated_at)')
        conn.commit()
    finally:
        conn.close()

def get_setting(key):
    conn = get_db()
    try:
        c = conn.cursor()
        c.execute("SELECT value FROM settings WHERE key=?", (key,))
        row = c.fetchone()
        return row['value'] if row else ""
    finally: conn.close()

def set_setting(key, value):
    conn = get_db()
    try:
        c = conn.cursor()
        c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?,?)", (key, value))
        conn.commit()
    finally: conn.close()

def write_nginx_proxy(port):
    port = int(port)
    content = f"""server {{
    listen 80;
    server_name _;
    client_max_body_size 100M;
    location / {{
        proxy_pass http://127.0.0.1:{port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }}
}}
"""
    path='/etc/nginx/sites-available/panel'
    try:
        with open(path+'.tmp','w') as f: f.write(content)
        os.replace(path+'.tmp',path)
        test=run_command(['nginx','-t'])
        return bool(test and test.returncode==0)
    except Exception as e:
        logger.error(f'Nginx update failed: {e}')
        return False

def get_panel_port():
    port = get_setting('panel_port')
    return int(port) if port and port.isdigit() else 5000

def public_base_url():
    configured=get_setting('domain').strip().rstrip('/')
    if configured:
        if configured.startswith(('http://','https://')):
            return configured
        scheme='https' if get_setting('ssl_status')=='active' else request.scheme
        return f"{scheme}://{configured}"
    return request.host_url.rstrip('/')

def verify_admin_password(candidate):
    stored=get_setting('admin_password')
    if not stored: return False
    if stored.startswith(('scrypt:','pbkdf2:')):
        try: return check_password_hash(stored,candidate)
        except Exception: return False
    # Legacy plaintext migration on successful login
    if secrets.compare_digest(stored,candidate):
        set_setting('admin_password',generate_password_hash(candidate))
        return True
    return False

def ensure_reality_keys():
    priv=get_setting('reality_private_key'); pub=get_setting('reality_public_key')
    if priv and pub: return priv,pub
    result=run_command([XRAY_BIN,'x25519'])
    if not result or result.returncode!=0:
        raise ValueError('تولید کلید Reality ناموفق بود')
    output=(result.stdout+result.stderr).decode(errors='ignore')
    priv=pub=None
    for line in output.splitlines():
        if ':' not in line: continue
        k,v=line.split(':',1); k=k.strip().lower(); v=v.strip()
        if 'private' in k: priv=v
        elif ('public' in k or 'password' in k) and 'hash32' not in k: pub=v
    if not priv or not pub: raise ValueError('خروجی کلید Reality قابل تشخیص نبود')
    set_setting('reality_private_key',priv); set_setting('reality_public_key',pub)
    return priv,pub

def tls_certificate_paths(server_name):
    domain=(get_setting('ssl_domain') or server_name or '').strip()
    candidates=[]
    if domain:
        candidates.append((f'/etc/letsencrypt/live/{domain}/fullchain.pem', f'/etc/letsencrypt/live/{domain}/privkey.pem'))
    cert=get_setting('tls_cert_file').strip(); key=get_setting('tls_key_file').strip()
    if cert and key: candidates.insert(0,(cert,key))
    for cert,key in candidates:
        if os.path.isfile(cert) and os.path.isfile(key): return cert,key
    raise ValueError('برای TLS گواهی معتبر پیدا نشد؛ ssl_domain یا مسیر certificate/key را تنظیم کنید')

def xray_service_identity():
    """Return uid/gid of the account systemd uses for Xray."""
    user='nobody'
    r=run_command(['systemctl','show','-p','User','--value','xray'],timeout=5)
    if r and r.returncode==0:
        candidate=r.stdout.decode(errors='ignore').strip()
        if candidate: user=candidate
    try:
        pw=pwd.getpwnam(user); return pw.pw_uid,pw.pw_gid,user
    except KeyError:
        return 0,0,'root'

def prepare_xray_tls_certificate(server_name):
    """Copy TLS material to an Xray-owned path so a non-root Xray service can read it."""
    src_cert,src_key=tls_certificate_paths(server_name)
    label=re.sub(r'[^A-Za-z0-9._-]+','_', (get_setting('ssl_domain') or server_name or 'default'))[:100] or 'default'
    dest_dir='/usr/local/etc/xray/certs'; os.makedirs(dest_dir,mode=0o755,exist_ok=True)
    dst_cert=os.path.join(dest_dir,label+'.crt'); dst_key=os.path.join(dest_dir,label+'.key')
    shutil.copy2(src_cert,dst_cert); shutil.copy2(src_key,dst_key)
    uid,gid,_=xray_service_identity()
    os.chown(dst_cert,uid,gid); os.chown(dst_key,uid,gid)
    os.chmod(dst_cert,0o644); os.chmod(dst_key,0o600)
    return dst_cert,dst_key

def validate_inbound(proto,net,sec):
    if proto not in ('vless','vmess','trojan'): raise ValueError('پروتکل نامعتبر است')
    if net not in ('tcp','ws','grpc'): raise ValueError('نوع انتقال نامعتبر است')
    if sec not in ('none','tls','reality'): raise ValueError('نوع امنیت نامعتبر است')
    if sec=='reality' and net=='ws': raise ValueError('Reality روی WebSocket توسط Xray پشتیبانی نمی‌شود')

def generate_qr_base64(data):
    try:
        import qrcode
        from io import BytesIO
        qr = qrcode.QRCode(version=1, box_size=12, border=2)
        qr.add_data(data)
        qr.make(fit=True)
        img = qr.make_image(fill_color="black", back_color="white")
        buffered = BytesIO()
        img.save(buffered, format="PNG")
        return base64.b64encode(buffered.getvalue()).decode()
    except:
        try:
            result = subprocess.run(['qrencode', '-o', '-', data], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            return base64.b64encode(result.stdout).decode()
        except: return ""

def build_xray_config():
    conn=get_db()
    try:
        c=conn.cursor(); c.execute("SELECT * FROM xray_inbounds WHERE status=1")
        inbounds=[]; all_tags=[]
        default_priv=get_setting('reality_private_key')
        for row in c.fetchall():
            ib=dict(row); proto=ib['protocol']; net=ib.get('network','tcp'); sec=ib.get('security','none')
            validate_inbound(proto,net,sec)
            clients=[dict(x) for x in c.execute("SELECT cl.username,cl.uuid,cl.email FROM xray_clients cl JOIN users u ON u.username=cl.username WHERE cl.inbound_id=? AND cl.enable=1 AND u.status=1",(ib['id'],)).fetchall()]
            if not clients: continue
            users=[]
            for cl in clients:
                email=cl.get('email') or cl['username']
                if proto in ('vless','vmess'):
                    u={'id':cl['uuid'],'email':email,'level':0}
                    # Vision is valid only with VLESS over raw TCP + TLS/Reality.
                    if proto=='vless' and net=='tcp' and sec in ('tls','reality'):
                        u['flow']='xtls-rprx-vision'
                else: # trojan
                    u={'password':cl['uuid'],'email':email,'level':0}
                users.append(u)
            settings={'users':users}
            if proto=='vless': settings['decryption']='none'
            method={'tcp':'raw','ws':'websocket','grpc':'grpc'}[net]
            stream={'method':method,'security':sec}
            if net=='ws': stream['wsSettings']={'path':ib.get('path') or '/'}
            elif net=='grpc': stream['grpcSettings']={'serviceName':(ib.get('path') or '/').strip('/') or 'grpc'}
            if sec=='reality':
                priv=ib.get('private_key') or default_priv
                if not priv: raise ValueError(f"Reality private key برای {ib['tag']} موجود نیست")
                sn=ib.get('server_name') or 'www.microsoft.com'; sid=ib.get('short_id') or ''
                stream['realitySettings']={'target':f'{sn}:443','serverNames':[sn],'privateKey':priv,'shortIds':[sid] if sid else ['']}
            elif sec=='tls':
                cert,key=prepare_xray_tls_certificate(ib.get('server_name',''))
                stream['tlsSettings']={'serverName':ib.get('server_name',''),'minVersion':'1.2','certificates':[{'certificateFile':cert,'keyFile':key}]}
            inbounds.append({'tag':ib['tag'],'port':ib['port'],'protocol':proto,'settings':settings,'streamSettings':stream})
            all_tags.append(ib['tag'])
        cfg={
            'log':{'loglevel':'warning','access':'/var/log/xray/access.log','error':'/var/log/xray/error.log'},
            'inbounds':inbounds,
            'outbounds':[{'protocol':'freedom','tag':'direct'}],
            'routing':{'rules':[]},
            'stats':{},
            'api':{'tag':'api','listen':'127.0.0.1:10085','services':['StatsService']},
            'policy':{'levels':{'0':{'statsUserUplink':True,'statsUserDownlink':True}},'system':{'statsInboundUplink':True,'statsInboundDownlink':True,'statsOutboundUplink':True,'statsOutboundDownlink':True}}
        }
        if all_tags: cfg['routing']['rules'].append({'type':'field','inboundTag':all_tags,'outboundTag':'direct'})
        return cfg
    finally: conn.close()

def generate_xray_config():
    config=build_xray_config(); new=json.dumps(config,indent=2,sort_keys=True)
    old=''
    try: old=open(XRAY_CONFIG,'r').read()
    except Exception: pass
    if old==new: return False
    tmp=XRAY_CONFIG+'.candidate'
    backup=XRAY_CONFIG+'.lastgood'
    with open(tmp,'w') as f: f.write(new)
    test=run_command([XRAY_BIN,'run','-test','-c',tmp],timeout=20)
    if not test or test.returncode!=0:
        err=((test.stderr if test else b'') or (test.stdout if test else b'')).decode(errors='ignore')[-2000:]
        try: os.remove(tmp)
        except: pass
        raise ValueError('Xray config validation failed: '+err)
    if os.path.exists(XRAY_CONFIG): shutil.copy2(XRAY_CONFIG,backup)
    os.replace(tmp,XRAY_CONFIG)
    return True

def sync_xray_firewall():
    """Maintain one dedicated INPUT chain containing only active Xray TCP ports."""
    chain='OP_XRAY_IN'
    conn=get_db()
    try:
        ports=[int(r['port']) for r in conn.execute("SELECT DISTINCT port FROM xray_inbounds WHERE status=1 ORDER BY port").fetchall()]
    finally:
        conn.close()
    try:
        run_command(['iptables','-N',chain],timeout=5)
        r=run_command(['iptables','-F',chain],timeout=5)
        if not r or r.returncode!=0: raise RuntimeError('cannot flush Xray firewall chain')
        for port in ports:
            r=run_command(['iptables','-A',chain,'-p','tcp','--dport',str(port),'-j','ACCEPT'],timeout=5)
            if not r or r.returncode!=0: raise RuntimeError(f'cannot allow Xray port {port}')
        while True:
            check=run_command(['iptables','-C','INPUT','-j',chain],timeout=5)
            if not check or check.returncode!=0: break
            run_command(['iptables','-D','INPUT','-j',chain],timeout=5)
        jump=run_command(['iptables','-I','INPUT','1','-j',chain],timeout=5)
        if not jump or jump.returncode!=0: raise RuntimeError('cannot attach Xray firewall chain')
        run_command(['netfilter-persistent','save'],timeout=15)
    except Exception as e:
        logger.warning(f'Xray firewall sync failed: {e}')

def reload_xray_config(force=False):
    changed=generate_xray_config()
    if changed or force:
        result=run_command(['systemctl','restart','xray'],timeout=25)
        ok=bool(result and result.returncode==0)
        if ok:
            time.sleep(.5)
            active=run_command(['systemctl','is-active','--quiet','xray'],timeout=5)
            ok=bool(active and active.returncode==0)
        if not ok:
            backup=XRAY_CONFIG+'.lastgood'
            if os.path.exists(backup):
                shutil.copy2(backup,XRAY_CONFIG); run_command(['systemctl','restart','xray'],timeout=25)
            raise RuntimeError('Xray restart failed; last known-good config restored')
    sync_xray_firewall()
    return changed

def set_user_runtime_status(username, enabled):
    """Keep Linux SSH account and Xray config in sync with DB status."""
    if enabled:
        run_command(['usermod','-U',username])
    else:
        run_command(['usermod','-L',username])
        run_command(['pkill','-u',username])

def gen_link(proto,uid,dom,port,net,sec,sni,fp,sid,pub,path,user):
    validate_inbound(proto,net,sec)
    q=[]
    if proto=='vless':
        q=[f'type={quote(net)}',f'security={quote(sec)}','encryption=none']
        if net=='tcp' and sec in ('tls','reality'): q.append('flow=xtls-rprx-vision')
        if net=='ws': q.append('path='+quote(path or '/',safe=''))
        elif net=='grpc': q.append('serviceName='+quote((path or '/').strip('/') or 'grpc',safe=''))
        if sec in ('tls','reality') and sni: q.append('sni='+quote(sni,safe=''))
        if sec=='reality':
            q += ['fp='+quote(fp or 'chrome',safe=''),'pbk='+quote(pub or '',safe=''),'sid='+quote(sid or '',safe='')]
        return f"vless://{uid}@{dom}:{port}?{'&'.join(q)}#OP-{quote(user,safe='')}"
    if proto=='vmess':
        cnf={'v':'2','ps':f'OP-{user}','add':dom,'port':str(port),'id':uid,'aid':'0','scy':'auto','net':net,'type':'none','host':'','path':path if net=='ws' else '','tls':'tls' if sec=='tls' else ('reality' if sec=='reality' else 'none')}
        if net=='grpc': cnf['path']=(path or '/').strip('/') or 'grpc'
        if sec in ('tls','reality'): cnf['sni']=sni
        if sec=='reality': cnf.update({'fp':fp or 'chrome','pbk':pub or '','sid':sid or ''})
        return 'vmess://'+base64.b64encode(json.dumps(cnf,separators=(',',':')).encode()).decode()
    if proto=='trojan':
        q=[f'security={quote(sec)}',f'type={quote(net)}']
        if net=='ws': q.append('path='+quote(path or '/',safe=''))
        elif net=='grpc': q.append('serviceName='+quote((path or '/').strip('/') or 'grpc',safe=''))
        if sec in ('tls','reality') and sni: q.append('sni='+quote(sni,safe=''))
        if sec=='reality': q += ['fp='+quote(fp or 'chrome',safe=''),'pbk='+quote(pub or '',safe=''),'sid='+quote(sid or '',safe='')]
        return f"trojan://{quote(uid,safe='')}@{dom}:{port}?{'&'.join(q)}#OP-{quote(user,safe='')}"
    raise ValueError('Unsupported protocol')

def generate_nepster_config(protocol, uuid, domain, port, network, security, sni, fp, sid, pub_key, path, username):
    config = {"config_version":"1.0","name":f"OP-{username}","type":protocol,"server":domain,"port":port,"uuid":uuid,"network":network,"security":security,"sni":sni,"fp":fp,"sid":sid,"pbk":pub_key,"path":path,"flow":"xtls-rprx-vision" if protocol=="vless" and network=="tcp" and security in ("tls","reality") else ""}
    return json.dumps(config, indent=2)

def generate_netmod_config(protocol, uuid, domain, port, network, security, sni, fp, sid, pub_key, path, username):
    config = {"name":f"OP-{username}","type":protocol,"server":domain,"port":port,"uuid":uuid,"network":network,"tls":security if security!="none" else "none","sni":sni,"fingerprint":fp,"shortId":sid,"publicKey":pub_key,"path":path,"flow":"xtls-rprx-vision" if protocol=="vless" and network=="tcp" and security in ("tls","reality") else "none"}
    return json.dumps(config, indent=2)

def sync_users_from_db(force_password=False):
    """Fast startup sync. Existing passwords are rewritten only during an explicit restore."""
    conn = get_db(); ok=True
    try:
        users = conn.execute("SELECT username,password,status FROM users WHERE username != 'root'").fetchall()
        for user in users:
            username=user['username']
            if not valid_username(username):
                logger.warning(f'Skipping unsafe/reserved DB username during OS sync: {username}'); ok=False
                continue
            exists=(subprocess.run(['id',username],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=5).returncode==0)
            if not exists:
                if not create_system_user(username,user['password']):
                    logger.error(f'Could not create missing OS account for {username}'); ok=False; continue
            elif force_password:
                if not set_system_password(username,user['password']):
                    logger.error(f'Could not restore OS password for {username}'); ok=False; continue
            set_user_runtime_status(username,bool(user['status']))
    except Exception as e:
        logger.error(f"Sync users error: {e}"); ok=False
    finally:
        conn.close()
    return ok

# ============================================
# IRAN BLOCK – only outbound (OUTPUT chain)
# ============================================
def apply_iran_block():
    try:
        if get_setting('block_iran_client') == '1':
            subprocess.run(['/usr/local/bin/iran-block.sh', 'enable'], timeout=30)
        else:
            subprocess.run(['/usr/local/bin/iran-block.sh', 'disable'], timeout=30)
    except Exception as e:
        logger.error(f"apply_iran_block failed: {e}")

# ============================================
# TEMPLATE LOADER
# ============================================
def render_template(template_name, **kwargs):
    template_path = os.path.join('/root/ssh-panel/templates', template_name)
    if os.path.exists(template_path):
        with open(template_path, 'r', encoding='utf-8') as f:
            template_content = f.read()
        return render_template_string(template_content, **kwargs)
    else:
        return render_template_string("""
        <!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><title>خطا</title>
        <style>body{background:#0a0a0a;color:#fff;font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0}
        .error{background:rgba(255,0,0,0.1);border:1px solid rgba(255,0,0,0.3);padding:2rem;border-radius:1rem;text-align:center}
        a{color:#f87171;text-decoration:none}</style></head><body><div class="error">
        <h1>قالب یافت نشد</h1><p>{{ template_name }}</p><a href="/dashboard">بازگشت</a></div></body></html>
        """, template_name=template_name)

# ============================================
# ALL ROUTES
# ============================================
@app.route('/', methods=['GET','POST'])
def login():
    if request.method=='POST':
        ip=login_client_ip()
        if not login_is_allowed(ip):
            return render_template('login.html', error='تلاش‌های ورود بیش از حد است؛ چند دقیقه بعد دوباره امتحان کنید'), 429
        username=request.form.get('username',''); password=request.form.get('password','')
        if secrets.compare_digest(username,get_setting('admin_username')) and verify_admin_password(password):
            clear_login_failures(ip)
            session.clear(); session['logged_in']=True; session.permanent=True; csrf_token()
            return redirect(url_for('dashboard'))
        record_login_failure(ip)
        time.sleep(0.35)
        return render_template('login.html', error='اطلاعات نادرست')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/dashboard')
def dashboard():
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn=get_db(); c=conn.cursor()
        summary=c.execute("""SELECT COUNT(*) total, SUM(CASE WHEN status=1 THEN 1 ELSE 0 END) active, COALESCE(SUM(used_traffic),0)/1024.0 used_gb FROM users""").fetchone()
        total_users=summary['total']; active_users=summary['active']; total_used=round(summary['used_gb'],2)
        total_inbounds=c.execute("SELECT COUNT(*) FROM xray_inbounds WHERE status=1").fetchone()[0]
        total_clients=c.execute("SELECT COUNT(*) FROM xray_clients WHERE enable=1").fetchone()[0]
        q=request.args.get('q','').strip()[:64]
        status_filter=request.args.get('status','all')
        try: page=max(1,int(request.args.get('page','1')))
        except: page=1
        per_page=50
        wh=[]; params=[]
        if q:
            wh.append("username LIKE ?"); params.append(f"%{q}%")
        if status_filter in ('0','1'):
            wh.append("status=?"); params.append(int(status_filter))
        where=(' WHERE '+ ' AND '.join(wh)) if wh else ''
        filtered=c.execute('SELECT COUNT(*) FROM users'+where, params).fetchone()[0]
        pages=max(1,(filtered+per_page-1)//per_page)
        page=min(page,pages)
        rows=c.execute('SELECT * FROM users'+where+' ORDER BY created_at DESC LIMIT ? OFFSET ?', params+[per_page,(page-1)*per_page]).fetchall()
        dom=get_setting('domain') or request.host.split(':')[0]
        base=public_base_url()
        ssh_connections=get_ssh_online_users()
        xray_online=get_xray_online_users()
        users=[]
        for row in rows:
            u=dict(row); username=u['username']
            used_gb=round((u.get('used_traffic') or 0)/1024,2); total_gb=round((u.get('total_traffic') or 0)/1024,2)
            is_ssh=username in ssh_connections; ssh_count=ssh_connections.get(username,0); is_xray=username in xray_online
            users.append({**u,'total_traffic':total_gb,'used_traffic':used_gb,'remaining_traffic':round(max(0,total_gb-used_gb),2),
                          'usage_percent':min(100,round((used_gb/total_gb)*100,1)) if total_gb>0 else 0,
                          'is_online':is_ssh or is_xray,'is_ssh_online':is_ssh,'is_xray_online':is_xray,'online_count':ssh_count,
                          'sub_link':f"{base}/sub/{u.get('sub_token')}"})
        conn.close()
        return render_template('dashboard.html', cpu=get_cpu(), ram=get_ram(), total_users=total_users, active_users=active_users,
                               total_inbounds=total_inbounds,total_clients=total_clients,total_used=total_used,users=users,
                               q=q,status_filter=status_filter,page=page,pages=pages,filtered=filtered)
    except Exception as e:
        logger.error(f"Dashboard error: {e}\n{traceback.format_exc()}")
        return render_template('error.html', error_message=f'خطا: {str(e)}'), 500

@app.route('/add_user_page')
def add_user_page():
    if not session.get('logged_in'): return redirect(url_for('login'))
    return render_template('add_user.html')

@app.route('/add_user', methods=['POST'])
def add_user():
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        u=request.form.get('username','').strip(); p=request.form.get('password','')
        if not valid_username(u): raise ValueError('نام کاربری نامعتبر است')
        ed=max(1,min(3650,int(request.form.get('expire_days','30'))))
        tg=max(0,float(request.form.get('traffic_gb','0')))*1024
        mc=max(1,min(50,int(request.form.get('max_connections','2'))))
        exp=(datetime.now()+timedelta(days=ed)).strftime('%Y-%m-%d %H:%M')
        conn=get_db()
        if conn.execute("SELECT 1 FROM users WHERE username=?",(u,)).fetchone():
            conn.close(); raise ValueError('این نام کاربری قبلاً وجود دارد')
        if subprocess.run(['id',u],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:
            conn.close(); raise ValueError('این نام کاربری از قبل در سیستم لینوکس وجود دارد')
        if not create_system_user(u,p):
            conn.close(); raise ValueError('ساخت کاربر لینوکس ناموفق بود')
        try:
            conn.execute("INSERT INTO users (username,password,expire_date,total_traffic,used_traffic,status,max_connections,created_at,sub_token) VALUES (?,?,?,?,0.0,1,?,?,?)",
                         (u,p,exp,tg,mc,datetime.now().strftime('%Y-%m-%d %H:%M'),secrets.token_urlsafe(32)))
            conn.commit(); conn.close()
        except Exception:
            conn.close()
            run_command(['userdel','-r',u])
            raise
        flash(f'✅ کاربر {u} ایجاد شد!', 'success')
    except Exception as e:
        flash(f'❌ خطا: {e}', 'error')
    return redirect(url_for('dashboard'))

@app.route('/edit_user', methods=['POST'])
def edit_user():
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        u=request.form.get('username','').strip(); p=request.form.get('password','')
        if not valid_username(u): raise ValueError('کاربر نامعتبر')
        tg=max(0,float(request.form.get('traffic_gb','0')))*1024
        mc=max(1,min(50,int(request.form.get('max_connections','2'))))
        s=1 if request.form.get('status')=='1' else 0; exp=request.form.get('expire_date','').strip()
        datetime.strptime(exp,'%Y-%m-%d %H:%M')
        conn=get_db()
        exists=conn.execute("SELECT 1 FROM users WHERE username=?",(u,)).fetchone()
        conn.close()
        if not exists: raise ValueError('کاربر در دیتابیس پنل وجود ندارد')
        if not create_system_user(u,p): raise ValueError('به‌روزرسانی حساب سیستم ناموفق بود')
        conn=get_db(); conn.execute("UPDATE users SET password=?,total_traffic=?,max_connections=?,status=?,expire_date=? WHERE username=?",(p,tg,mc,s,exp,u)); conn.commit(); conn.close()
        set_user_runtime_status(u, bool(s)); reload_xray_config(force=True)
        flash(f'✅ کاربر {u} بروزرسانی شد!', 'success')
    except Exception as e:
        flash(f'❌ خطا: {e}', 'error')
    return redirect(url_for('dashboard'))

@app.route('/user_action/<username>', methods=['POST'])
def user_action(username):
    if not session.get('logged_in'): return redirect(url_for('login'))
    action=request.form.get('action','')
    conn=get_db()
    try:
        row=conn.execute("SELECT status,total_traffic FROM users WHERE username=?",(username,)).fetchone()
        if not row: raise ValueError('کاربر یافت نشد')
        if action=='toggle':
            new_status=0 if row['status'] else 1
            conn.execute("UPDATE users SET status=? WHERE username=?",(new_status,username)); conn.commit()
            set_user_runtime_status(username, bool(new_status)); reload_xray_config(force=True)
        elif action=='reset_traffic':
            conn.execute("UPDATE users SET used_traffic=0 WHERE username=?",(username,)); conn.commit()
        elif action=='extend_30':
            cur=conn.execute("SELECT expire_date FROM users WHERE username=?",(username,)).fetchone()['expire_date']
            try: base=max(datetime.now(), datetime.strptime(cur,'%Y-%m-%d %H:%M'))
            except: base=datetime.now()
            conn.execute("UPDATE users SET expire_date=? WHERE username=?",((base+timedelta(days=30)).strftime('%Y-%m-%d %H:%M'),username)); conn.commit()
        elif action=='add_10gb':
            conn.execute("UPDATE users SET total_traffic=total_traffic+10240 WHERE username=?",(username,)); conn.commit()
        else: raise ValueError('عملیات نامعتبر')
        flash('✅ عملیات انجام شد', 'success')
    except Exception as e:
        flash(f'❌ {e}', 'error')
    finally: conn.close()
    return redirect(request.referrer or url_for('dashboard'))

@app.route('/bulk_users', methods=['POST'])
def bulk_users():
    if not session.get('logged_in'): return redirect(url_for('login'))
    usernames=[u for u in request.form.getlist('usernames') if valid_username(u)]
    action=request.form.get('action','')
    if not usernames:
        flash('❌ کاربری انتخاب نشده', 'error'); return redirect(url_for('dashboard'))
    conn=get_db()
    placeholders=','.join('?' for _ in usernames)
    existing={r['username'] for r in conn.execute(f"SELECT username FROM users WHERE username IN ({placeholders})",usernames).fetchall()}
    usernames=[u for u in usernames if u in existing]
    if not usernames:
        conn.close(); flash('❌ هیچ‌کدام از کاربران انتخاب‌شده در پنل وجود ندارند', 'error'); return redirect(url_for('dashboard'))
    placeholders=','.join('?' for _ in usernames)
    need_xray=False
    try:
        if action in ('activate','deactivate'):
            enabled=1 if action=='activate' else 0
            conn.execute(f"UPDATE users SET status=? WHERE username IN ({placeholders})", [enabled]+usernames); conn.commit()
            for u in usernames: set_user_runtime_status(u,bool(enabled))
            need_xray=True
        elif action=='reset_traffic':
            conn.execute(f"UPDATE users SET used_traffic=0 WHERE username IN ({placeholders})", usernames); conn.commit()
        elif action=='add_10gb':
            conn.execute(f"UPDATE users SET total_traffic=total_traffic+10240 WHERE username IN ({placeholders})", usernames); conn.commit()
        elif action=='extend_30':
            for u in usernames:
                row=conn.execute("SELECT expire_date FROM users WHERE username=?",(u,)).fetchone()
                try: base=max(datetime.now(),datetime.strptime(row['expire_date'],'%Y-%m-%d %H:%M'))
                except: base=datetime.now()
                conn.execute("UPDATE users SET expire_date=? WHERE username=?",((base+timedelta(days=30)).strftime('%Y-%m-%d %H:%M'),u))
            conn.commit()
        elif action=='delete':
            for u in usernames: run_command(['userdel','-r',u])
            conn.execute(f"DELETE FROM users WHERE username IN ({placeholders})",usernames); conn.commit(); need_xray=True
        else: raise ValueError('عملیات نامعتبر')
        if need_xray: reload_xray_config(force=True)
        flash(f'✅ عملیات روی {len(usernames)} کاربر انجام شد', 'success')
    except Exception as e:
        flash(f'❌ {e}', 'error')
    finally: conn.close()
    return redirect(url_for('dashboard'))

@app.route('/delete_user/<username>', methods=['POST'])
def delete_user(username):
    if not session.get('logged_in'): return redirect(url_for('login'))
    conn=get_db()
    try:
        if not conn.execute("SELECT 1 FROM users WHERE username=?",(username,)).fetchone():
            flash('❌ کاربر در پنل وجود ندارد', 'error'); return redirect(url_for('dashboard'))
        run_command(["userdel","-r",username])
        remove_ssh_counters(username)
        conn.execute("DELETE FROM users WHERE username=?",(username,)); conn.commit()
    finally:
        conn.close()
    reload_xray_config(force=True)
    flash(f'✅ {username} حذف شد!', 'success')
    return redirect(url_for('dashboard'))

@app.route('/inbounds')
def inbounds_page():
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn=get_db(); c=conn.cursor()
        c.execute("""SELECT ib.*, COUNT(cl.id) AS client_count FROM xray_inbounds ib LEFT JOIN xray_clients cl ON cl.inbound_id=ib.id GROUP BY ib.id ORDER BY ib.id DESC""")
        inbounds=[dict(r) for r in c.fetchall()]
        conn.close()
        return render_template('inbounds.html', inbounds=inbounds, cpu=get_cpu(), ram=get_ram())
    except: return render_template('error.html', error_message='خطا'), 500

@app.route('/add_inbound_page')
def add_inbound_page():
    if not session.get('logged_in'): return redirect(url_for('login'))
    return render_template('add_inbound.html', random_port=get_random_port())

@app.route('/add_inbound', methods=['POST'])
def add_inbound():
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        tag=request.form.get('tag','').strip(); proto=request.form.get('protocol','vless')
        if not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}',tag): raise ValueError('Tag فقط می‌تواند شامل حروف، عدد، نقطه، خط تیره و زیرخط باشد')
        port=int(request.form.get('port', get_random_port()))
        net=request.form.get('network','tcp'); sec=request.form.get('security','none')
        validate_inbound(proto,net,sec)
        if port < 1 or port > 65535: raise ValueError('پورت نامعتبر است')
        if not port_available(port): raise ValueError('این پورت قبلاً در حال استفاده است')
        sni=request.form.get('server_name','www.microsoft.com').strip()
        fp=request.form.get('fingerprint','chrome').strip() or 'chrome'
        sid=request.form.get('short_id','').strip(); path=request.form.get('path','/') or '/'
        if sec=='reality':
            priv,pub=ensure_reality_keys()
            if not sid: sid=secrets.token_hex(8)
        else: pub=priv=''
        if sec=='tls': tls_certificate_paths(sni)
        conn=get_db()
        conn.cursor().execute("INSERT INTO xray_inbounds (tag,protocol,port,network,security,server_name,fingerprint,short_id,public_key,private_key,path,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                             (tag,proto,port,net,sec,sni,fp,sid,pub,priv,path,datetime.now().strftime('%Y-%m-%d %H:%M')))
        conn.commit(); conn.close()
        reload_xray_config(force=True)
        flash(f'✅ اینباند {tag}:{port} ایجاد شد!', 'success')
    except Exception as e: flash(f'❌ خطا: {e}', 'error')
    return redirect(url_for('inbounds_page'))

@app.route('/delete_inbound/<int:ib_id>', methods=['POST'])
def delete_inbound(ib_id):
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn=get_db()
        conn.cursor().execute("DELETE FROM xray_inbounds WHERE id=?",(ib_id,))
        conn.commit(); conn.close()
        reload_xray_config(force=True)
        flash('✅ حذف شد!', 'success')
    except: flash('❌ خطا', 'error')
    return redirect(url_for('inbounds_page'))

@app.route('/clients/<int:ib_id>')
def clients_page(ib_id):
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn=get_db(); c=conn.cursor()
        c.execute("SELECT * FROM xray_inbounds WHERE id=?",(ib_id,))
        row=c.fetchone()
        if not row: conn.close(); return redirect(url_for('inbounds_page'))
        inbound=dict(row)
        c.execute("SELECT * FROM xray_clients WHERE inbound_id=?",(ib_id,))
        clients_raw=[dict(cl) for cl in c.fetchall()]
        c.execute("SELECT username FROM users WHERE username NOT IN (SELECT username FROM xray_clients WHERE inbound_id=?)",(ib_id,))
        available=[r['username'] for r in c.fetchall()]
        dom=get_setting('domain') or request.host.split(':')[0]
        dpub=get_setting('reality_public_key')
        clients=[]
        for cl in clients_raw:
            cl['link']=gen_link(inbound['protocol'],cl['uuid'],dom,inbound['port'],
                               inbound.get('network','tcp'),inbound.get('security','none'),
                               inbound.get('server_name',''),inbound.get('fingerprint',''),
                               inbound.get('short_id',''),inbound.get('public_key') or dpub,
                               inbound.get('path','/'),cl['username'])
            clients.append(cl)
        conn.close()
        return render_template('clients.html', inbound=inbound, clients=clients, available_users=available)
    except: return render_template('error.html', error_message='خطا'), 500

@app.route('/add_clients/<int:ib_id>', methods=['POST'])
def add_clients(ib_id):
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn=get_db()
        for uname in request.form.getlist('usernames'):
            uid=str(uuid.uuid4())
            conn.cursor().execute("INSERT OR IGNORE INTO xray_clients (inbound_id,username,uuid,email,created_at) VALUES (?,?,?,?,?)",
                                 (ib_id,uname,uid,uname,datetime.now().strftime('%Y-%m-%d %H:%M')))
        conn.commit(); conn.close()
        reload_xray_config(force=True)
        flash('✅ اضافه شدند!', 'success')
    except: flash('❌ خطا', 'error')
    return redirect(url_for('clients_page', ib_id=ib_id))

@app.route('/delete_client/<int:cl_id>', methods=['POST'])
def delete_client(cl_id):
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn=get_db()
        conn.cursor().execute("DELETE FROM xray_clients WHERE id=?",(cl_id,))
        conn.commit(); conn.close()
        reload_xray_config(force=True)
        flash('✅ حذف شد!', 'success')
    except: flash('❌ خطا', 'error')
    return redirect(url_for('inbounds_page'))

@app.route('/groups')
def groups_page():
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn=get_db(); c=conn.cursor()
        c.execute("""SELECT g.*, COUNT(gm.id) AS member_count FROM user_groups g LEFT JOIN group_members gm ON gm.group_id=g.id GROUP BY g.id ORDER BY g.id DESC""")
        groups=[dict(r) for r in c.fetchall()]
        conn.close()
        return render_template('groups.html', groups=groups, cpu=get_cpu(), ram=get_ram())
    except: return render_template('error.html', error_message='خطا'), 500

@app.route('/add_group', methods=['POST'])
def add_group():
    if not session.get('logged_in'): return redirect(url_for('login'))
    n=request.form.get('name','')
    if n:
        conn=get_db()
        conn.cursor().execute("INSERT INTO user_groups (name,description,created_at) VALUES (?,?,?)",
                             (n,request.form.get('description',''),datetime.now().strftime('%Y-%m-%d %H:%M')))
        conn.commit(); conn.close()
        flash('✅ گروه ایجاد شد!', 'success')
    return redirect(url_for('groups_page'))

@app.route('/delete_group/<int:gid>', methods=['POST'])
def delete_group(gid):
    if not session.get('logged_in'): return redirect(url_for('login'))
    conn=get_db()
    conn.cursor().execute("DELETE FROM user_groups WHERE id=?",(gid,))
    conn.commit(); conn.close()
    flash('✅ حذف شد!', 'success')
    return redirect(url_for('groups_page'))

@app.route('/group_members/<int:gid>')
def group_members_page(gid):
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn=get_db(); c=conn.cursor()
        c.execute("SELECT * FROM user_groups WHERE id=?",(gid,))
        row=c.fetchone()
        if not row: conn.close(); return redirect(url_for('groups_page'))
        group=dict(row)
        c.execute("SELECT username FROM group_members WHERE group_id=?",(gid,))
        members=[r['username'] for r in c.fetchall()]
        c.execute("SELECT username FROM users WHERE username NOT IN (SELECT username FROM group_members WHERE group_id=?)",(gid,))
        available=[r['username'] for r in c.fetchall()]
        conn.close()
        return render_template('group_members.html', group=group, members=members, available_users=available)
    except: return render_template('error.html', error_message='خطا'), 500

@app.route('/add_group_members/<int:gid>', methods=['POST'])
def add_group_members(gid):
    if not session.get('logged_in'): return redirect(url_for('login'))
    conn=get_db()
    for uname in request.form.getlist('usernames'):
        try: conn.cursor().execute("INSERT INTO group_members (group_id,username) VALUES (?,?)",(gid,uname))
        except: pass
    conn.commit(); conn.close()
    flash('✅ اضافه شدند!', 'success')
    return redirect(url_for('group_members_page', gid=gid))

@app.route('/remove_group_member/<int:gid>/<username>', methods=['POST'])
def remove_group_member(gid, username):
    if not session.get('logged_in'): return redirect(url_for('login'))
    conn=get_db()
    conn.cursor().execute("DELETE FROM group_members WHERE group_id=? AND username=?",(gid,username))
    conn.commit(); conn.close()
    flash('✅ حذف شد!', 'success')
    return redirect(url_for('group_members_page', gid=gid))

@app.route('/sub/<token>')
def sub_page(token):
    try:
        conn=get_db(); c=conn.cursor()
        c.execute("SELECT * FROM users WHERE sub_token=?",(token,)); user_data=c.fetchone()
        if not user_data: conn.close(); return render_template('sub_error.html', error_message='لینک اشتراک نامعتبر است'),404
        user=dict(user_data); username=user['username']; dom=(get_setting('domain') or request.host.split(':')[0]).replace('http://','').replace('https://','').split('/')[0]
        dpub=get_setting('reality_public_key'); tg=round(float(user['total_traffic'] or 0)/1024,2); ug=round(float(user['used_traffic'] or 0)/1024,2); rg=round(max(0.0,tg-ug),2); prog=min(100,int((ug/tg)*100)) if tg>0 else 0
        try: dl=max(0,(datetime.strptime(user['expire_date'],'%Y-%m-%d %H:%M')-datetime.now()).days)
        except: dl=0
        ssh=f"ssh://{quote(username,safe='')}:{quote(user['password'],safe='')}@{dom}:22#OP-{quote(username,safe='')}"; ssh_qr=generate_qr_base64(ssh); xl=[]
        c.execute("""SELECT cl.uuid,ib.port,ib.protocol,ib.network,ib.security,ib.server_name,ib.fingerprint,ib.short_id,ib.public_key,ib.path,ib.tag FROM xray_clients cl JOIN xray_inbounds ib ON cl.inbound_id=ib.id WHERE cl.username=? AND cl.enable=1 AND ib.status=1""",(username,))
        for xc in c.fetchall():
            xc=dict(xc)
            try:
                link=gen_link(xc['protocol'],xc['uuid'],dom,xc['port'],xc.get('network','tcp'),xc.get('security','none'),xc.get('server_name',''),xc.get('fingerprint',''),xc.get('short_id',''),xc.get('public_key') or dpub,xc.get('path','/'),username)
                xl.append({'protocol':xc['protocol'],'link':link,'qr_code':generate_qr_base64(link),'tag':xc.get('tag',''),'port':xc['port'],'nepster_link':f"/download/nepster/{token}/{len(xl)}",'netmod_link':f"/download/netmod/{token}/{len(xl)}"})
            except Exception as e: logger.warning(f'link generation skipped: {e}')
        conn.close()
        return render_template('sub.html',username=username,password=user['password'],expire_date=user['expire_date'],total_traffic=str(tg),used_traffic=str(ug),remaining_traffic=str(rg),progress_percent=str(prog),days_left=str(dl),status=str(user['status']),ssh_uri=ssh,ssh_qr=ssh_qr,xray_configs=xl)
    except Exception as e:
        logger.error(f"Sub error: {e}"); return render_template('sub_error.html',error_message='خطا در ساخت اشتراک'),500

def _config_for_token(token,index):
    conn=get_db(); c=conn.cursor(); row=c.execute('SELECT username FROM users WHERE sub_token=?',(token,)).fetchone()
    if not row: conn.close(); return None,None,None
    username=row['username']; dom=(get_setting('domain') or request.host.split(':')[0]).replace('http://','').replace('https://','').split('/')[0]; dpub=get_setting('reality_public_key')
    xc=c.execute("SELECT cl.uuid,ib.port,ib.protocol,ib.network,ib.security,ib.server_name,ib.fingerprint,ib.short_id,ib.public_key,ib.path FROM xray_clients cl JOIN xray_inbounds ib ON cl.inbound_id=ib.id WHERE cl.username=? AND cl.enable=1 AND ib.status=1 ORDER BY cl.id LIMIT 1 OFFSET ?",(username,index)).fetchone(); conn.close()
    return username,dom,(dict(xc) if xc else None)

@app.route('/download/nepster/<token>/<int:config_index>')
def download_nepster(token,config_index):
    try:
        username,dom,xc=_config_for_token(token,config_index)
        if not xc:return 'Not found',404
        cfg=generate_nepster_config(xc['protocol'],xc['uuid'],dom,xc['port'],xc.get('network','tcp'),xc.get('security','none'),xc.get('server_name',''),xc.get('fingerprint',''),xc.get('short_id',''),xc.get('public_key') or get_setting('reality_public_key'),xc.get('path','/'),username)
        return Response(cfg,mimetype='application/octet-stream',headers={'Content-Disposition':f"attachment;filename=OP_{username}_{xc['protocol']}.npvt"})
    except Exception as e: logger.error(f'Nepster download: {e}'); return 'Error',500

@app.route('/download/netmod/<token>/<int:config_index>')
def download_netmod(token,config_index):
    try:
        username,dom,xc=_config_for_token(token,config_index)
        if not xc:return 'Not found',404
        cfg=generate_netmod_config(xc['protocol'],xc['uuid'],dom,xc['port'],xc.get('network','tcp'),xc.get('security','none'),xc.get('server_name',''),xc.get('fingerprint',''),xc.get('short_id',''),xc.get('public_key') or get_setting('reality_public_key'),xc.get('path','/'),username)
        return Response(cfg,mimetype='application/json',headers={'Content-Disposition':f"attachment;filename=OP_{username}_{xc['protocol']}.json"})
    except Exception as e: logger.error(f'Netmod download: {e}'); return 'Error',500

@app.route('/reports')
def reports():
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn=get_db(); c=conn.cursor()
        c.execute("SELECT COUNT(*) as total_users, COALESCE(SUM(total_traffic)/1024,0) as total_traffic_gb, COALESCE(SUM(used_traffic)/1024,0) as used_traffic_gb FROM users")
        summary=dict(c.fetchone())
        c.execute("SELECT COUNT(*) as cnt FROM xray_inbounds WHERE status=1"); ib_count=c.fetchone()['cnt']
        c.execute("SELECT COUNT(*) as cnt FROM xray_clients WHERE enable=1"); cl_count=c.fetchone()['cnt']
        conn.close()
        return render_template('reports.html', summary=summary, ib_count=ib_count, cl_count=cl_count, cpu=get_cpu(), ram=get_ram())
    except: return render_template('error.html', error_message='خطا'), 500

@app.route('/settings', methods=['GET','POST'])
def settings():
    if not session.get('logged_in'): return redirect(url_for('login'))
    if request.method=='POST':
        action=request.form.get('action','')
        if action=='save_settings':
            for k in ['domain','admin_username']:
                if request.form.get(k): set_setting(k,request.form[k].strip())
            for k in ['ssl_domain','tls_cert_file','tls_key_file']:
                set_setting(k,request.form.get(k,'').strip())
            restart_for_port=False
            requested_port=request.form.get('panel_port','').strip()
            if requested_port:
                port=int(requested_port)
                if port < 1024 or port > 65535: raise ValueError('پورت باید بین 1024 تا 65535 باشد')
                if port != get_panel_port():
                    old_port=get_panel_port(); set_setting('panel_port',str(port))
                    if not write_nginx_proxy(port):
                        set_setting('panel_port',str(old_port)); write_nginx_proxy(old_port)
                        raise ValueError('تنظیم Nginx برای پورت جدید ناموفق بود')
                    restart_for_port=True
            if request.form.get('admin_password'):
                set_setting('admin_password',generate_password_hash(request.form['admin_password']))
                try: os.remove('/root/ssh-panel/initial_admin_credentials.txt')
                except FileNotFoundError: pass
            set_setting('block_iran_client','1' if request.form.get('block_iran') else '0')
            apply_iran_block()
            flash('✅ ذخیره شد!', 'success')
            if restart_for_port:
                unit=f'outlineparsian-port-{int(time.time())}'
                subprocess.Popen(['systemd-run','--on-active=2s',f'--unit={unit}','/bin/bash','-lc','systemctl restart ssh-panel.service && systemctl reload nginx'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
        elif action=='generate_keys':
            try:
                result=run_command([XRAY_BIN,'x25519'])
                if result:
                    output=result.stdout.decode()+'\n'+result.stderr.decode()
                    priv=pub=None
                    for line in output.split('\n'):
                        line=line.strip()
                        if 'private' in line.lower() and ':' in line: priv=line.split(':',1)[1].strip()
                        if ('public' in line.lower() or 'password' in line.lower()) and ':' in line and 'hash32' not in line.lower():
                            pk=line.split(':',1)[1].strip()
                            if priv and pk!=priv: pub=pk
                    if priv and pub:
                        set_setting('reality_private_key',priv)
                        set_setting('reality_public_key',pub)
                        reload_xray_config(force=True)
                        flash('✅ کلیدها تولید شدند!', 'success')
            except: flash('❌ خطا', 'error')
        return redirect(url_for('settings'))
    sd={}
    for k in ['domain','admin_username','block_iran_client','panel_port','reality_public_key','reality_private_key','ssl_domain','tls_cert_file','tls_key_file']:
        sd[k]=get_setting(k)
    return render_template('settings.html', **sd, cpu=get_cpu(), ram=get_ram())

@app.route('/backup_download')
def backup_download():
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn = sqlite3.connect('/root/ssh-panel/panel.db')
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        conn.close()
        backup_path = '/tmp/panel_backup.db'
        shutil.copy2('/root/ssh-panel/panel.db', backup_path)
        return send_file(backup_path, as_attachment=True, download_name='OutlineParsian_Backup.db')
    except Exception as e:
        flash(f'❌ خطا در دانلود بکاپ: {e}', 'error')
        return redirect(url_for('settings'))

# ============================================
# ULTRA STABLE BACKUP UPLOAD (mask/unmask + WAL removal)
# ============================================
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
        test_conn = sqlite3.connect(temp_path)
        integrity=test_conn.execute('PRAGMA integrity_check').fetchone()[0]
        if integrity!='ok': raise ValueError('SQLite integrity_check failed')
        required={'users','settings','xray_inbounds','xray_clients'}
        tables={r[0] for r in test_conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not required.issubset(tables): raise ValueError('Backup schema is incomplete')
        users_count = test_conn.execute("SELECT COUNT(*) FROM users;").fetchone()[0]
        test_conn.close()
    except Exception as e:
        if os.path.exists(temp_path):
            os.remove(temp_path)
        flash(f'❌ فایل بکاپ نامعتبر: {str(e)}', 'error')
        return redirect(url_for('settings'))

    restore_script = f"""#!/bin/bash
set -Eeuo pipefail
sleep 2
STAMP=$(date +%Y%m%d_%H%M%S)
BEFORE=/root/ssh-panel/backups/panel_before_restore_$STAMP.db
mkdir -p /root/ssh-panel/backups
systemctl mask ssh-panel.service ssh-panel-worker.service ssh-connection-limiter.service 2>/dev/null || true
systemctl stop ssh-panel.service ssh-panel-worker.service ssh-connection-limiter.service || true
for i in {{1..20}}; do
    if ! systemctl is-active --quiet ssh-panel.service && ! systemctl is-active --quiet ssh-panel-worker.service && ! systemctl is-active --quiet ssh-connection-limiter.service; then break; fi
    sleep 0.5
done
if [ -f /root/ssh-panel/panel.db ]; then cp /root/ssh-panel/panel.db "$BEFORE"; fi
rm -f /root/ssh-panel/panel.db-wal /root/ssh-panel/panel.db-shm
cp "{temp_path}" /root/ssh-panel/panel.db
sync
if ! /root/ssh-panel/venv/bin/python -c "import sys;sys.path.insert(0,'/root/ssh-panel');import app;app.ensure_schema();app.reload_xray_config(force=True);app.sync_users_from_db(force_password=True)"; then
    echo "Restore migration failed; rolling back" >&2
    if [ -f "$BEFORE" ]; then
        rm -f /root/ssh-panel/panel.db-wal /root/ssh-panel/panel.db-shm
        cp "$BEFORE" /root/ssh-panel/panel.db
    fi
fi
systemctl unmask ssh-panel.service ssh-panel-worker.service ssh-connection-limiter.service 2>/dev/null || true
systemctl start ssh-panel.service
sleep 2
systemctl start ssh-panel-worker.service ssh-connection-limiter.service
rm -f "{temp_path}"
"""
    script_path = '/tmp/restore_panel.sh'
    with open(script_path, 'w') as f:
        f.write(restore_script)
    os.chmod(script_path, 0o755)

    subprocess.Popen(
        ['systemd-run', '--description', 'Restore OutlineParsian DB', '/bin/bash', script_path],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True
    )

    flash(f'✅ بازگردانی آغاز شد. پنل چند لحظه قطع و خودکار راه‌اندازی می‌شود. ({users_count} کاربر)', 'success')
    return redirect(url_for('settings'))

if __name__=='__main__':
    for lf in ['/var/log/xray/access.log','/var/log/xray/error.log','/var/log/panel.log']:
        if not os.path.exists(lf): open(lf,'a').close()
        os.chmod(lf,0o640)
    ensure_schema()
    reload_xray_config(force=False)
    apply_iran_block()
    sync_users_from_db()
    logger.info(f"Panel starting on port {get_panel_port()}")
    from waitress import serve
    serve(app, host='127.0.0.1', port=get_panel_port(), threads=12, channel_timeout=60)
APPEOF

echo "✓ Panel application created"

# ============================================
# CREATE FIXED IRAN BLOCK SCRIPT (OUTPUT chain)
# ============================================
cat << 'EOF' > /usr/local/bin/iran-block.sh
#!/bin/bash
set -o pipefail
IPSET_NAME="iran_ips"
CHAIN="OP_IRAN"
DB_PATH="/root/ssh-panel/panel.db"

cleanup_legacy() {
    while iptables -C OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null; do
        iptables -D OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null || break
    done
}

case "$1" in
    auto)
        VALUE=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='block_iran_client';" 2>/dev/null || echo 0)
        if [ "$VALUE" = "1" ]; then exec "$0" enable; else exec "$0" disable; fi
        ;;
    enable)
        ipset create "$IPSET_NAME" hash:net maxelem 200000 2>/dev/null || true
        if curl -fsS --connect-timeout 8 --max-time 30 https://www.ipdeny.com/ipblocks/data/countries/ir.zone -o /tmp/ir.zone && [ -s /tmp/ir.zone ]; then
            ipset flush "$IPSET_NAME" 2>/dev/null || true
            while read -r line; do [ -n "$line" ] && ipset add "$IPSET_NAME" "$line" 2>/dev/null || true; done < /tmp/ir.zone
        fi
        cleanup_legacy
        iptables -N "$CHAIN" 2>/dev/null || true
        iptables -F "$CHAIN"
        iptables -A "$CHAIN" -m set --match-set "$IPSET_NAME" dst -j DROP
        while iptables -C OUTPUT -j "$CHAIN" 2>/dev/null; do iptables -D OUTPUT -j "$CHAIN" 2>/dev/null || break; done
        iptables -I OUTPUT 1 -j "$CHAIN"
        netfilter-persistent save >/dev/null 2>&1 || true
        ;;
    disable)
        cleanup_legacy
        while iptables -C OUTPUT -j "$CHAIN" 2>/dev/null; do iptables -D OUTPUT -j "$CHAIN" 2>/dev/null || break; done
        iptables -F "$CHAIN" 2>/dev/null || true
        netfilter-persistent save >/dev/null 2>&1 || true
        ;;
    *)
        echo "Usage: $0 auto|enable|disable"
        exit 1
        ;;
esac
EOF
chmod +x /usr/local/bin/iran-block.sh

cat << 'EOF' > /etc/cron.weekly/update-iran-ips
#!/bin/bash
/usr/local/bin/iran-block.sh auto
EOF
chmod +x /etc/cron.weekly/update-iran-ips

cat << 'EOF' > /etc/cron.weekly/outlineparsian-tls-sync
#!/bin/bash
set -e
DB=/root/ssh-panel/panel.db
PY=/root/ssh-panel/venv/bin/python
[ -x "$PY" ] || exit 0
[ -f "$DB" ] || exit 0
COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM xray_inbounds WHERE status=1 AND security='tls';" 2>/dev/null || echo 0)
if [ "${COUNT:-0}" -gt 0 ]; then
  cd /root/ssh-panel
  "$PY" -c "import app; app.reload_xray_config(force=True)" >/var/log/outlineparsian-tls-sync.log 2>&1 || exit 1
fi
EOF
chmod +x /etc/cron.weekly/outlineparsian-tls-sync

cat << 'EOF' > /etc/systemd/system/iran-block.service
[Unit]
Description=Apply OutlineParsian Iran outbound blocking setting
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/iran-block.sh auto
RemainAfterExit=no
[Install]
WantedBy=multi-user.target
EOF

echo "✓ Iran block is setting-aware and uses a dedicated firewall chain"

# ============================================
# STEP 7: Traffic Worker (updated with SSH)
# ============================================
echo "[7/16] Creating traffic worker..."
cat << 'WORKEREOF' > /root/ssh-panel/traffic_worker.py
#!/usr/bin/env python3
import sys,time,sqlite3,subprocess,re,os
from datetime import datetime
sys.path.insert(0,'/root/ssh-panel/xray_proto')
try:
    import grpc,stats_pb2,stats_pb2_grpc
except Exception:
    grpc=None
DB_PATH='/root/ssh-panel/panel.db'

def db():
    c=sqlite3.connect(DB_PATH,timeout=30)
    c.execute('PRAGMA journal_mode=WAL'); c.execute('PRAGMA synchronous=NORMAL'); c.execute('PRAGMA busy_timeout=5000')
    return c

def read_xray_counters():
    """Return cumulative per-user Xray byte counters without resetting them."""
    if not grpc:return {}
    channel=None; out={}
    try:
        channel=grpc.insecure_channel('127.0.0.1:10085')
        stub=stats_pb2_grpc.StatsServiceStub(channel)
        response=stub.QueryStats(stats_pb2.QueryStatsRequest(pattern='user>>>',reset=False),timeout=4)
        for stat in response.stat:
            parts=stat.name.split('>>>')
            if len(parts)>=4 and parts[0]=='user' and parts[2]=='traffic' and parts[3] in ('uplink','downlink') and stat.value>=0:
                out[stat.name]=(parts[1],int(stat.value))
    except Exception as e:
        print(f'Xray traffic error: {e}',flush=True)
    finally:
        if channel:
            try:channel.close()
            except:pass
    return out

def ssh_snapshot():
    sessions={}
    try:
        out=subprocess.check_output(['ss','-tpino','state','established','sport','=',':22'],text=True,stderr=subprocess.DEVNULL,timeout=4)
        lines=out.splitlines(); i=0
        while i<len(lines):
            raw=lines[i]; line=raw.strip()
            if not line or line.startswith(('State','Recv-Q')) or raw[:1].isspace(): i+=1; continue
            info=''
            if i+1<len(lines) and lines[i+1][:1].isspace(): info=lines[i+1].strip()
            parts=line.split(); pidm=re.search(r'pid=(\d+)',line)
            if len(parts)<4 or not pidm: i+=1; continue
            pid=pidm.group(1); local=parts[-2]; peer=parts[-1]
            ino=re.search(r'ino:(\d+)',line+' '+info); key=f"{local}|{peer}|{pid}|{ino.group(1) if ino else '-'}"
            ack=re.search(r'bytes_acked:(\d+)',info); rcv=re.search(r'bytes_received:(\d+)',info)
            tx=int(ack.group(1)) if ack else 0; rx=int(rcv.group(1)) if rcv else 0
            username=None
            try:
                ps=subprocess.check_output(['ps','-p',pid,'-o','user=,command='],text=True,stderr=subprocess.DEVNULL,timeout=2).strip()
                if ps:
                    first=ps.split(None,1)[0]
                    if first not in ('root','sshd'):username=first
                    else:
                        m=re.search(r'sshd:\s+([a-zA-Z0-9_-]+)',ps)
                        if m and m.group(1) not in ('root','sshd','priv'):username=m.group(1)
            except Exception:pass
            if username:sessions[key]=(username,tx,rx)
            i+=2 if info else 1
    except subprocess.CalledProcessError:pass
    except Exception as e:print(f'SSH snapshot error: {e}',flush=True)
    return sessions

def apply_usage(xray_now,ssh_now):
    """Atomically persist baselines and usage so worker crashes cannot double count traffic."""
    now=int(time.time()); conn=db(); c=conn.cursor(); deltas={}; xseen=set(); sseen=set(); disabled=[]
    try:
        c.execute('BEGIN IMMEDIATE')
        for stat_name,(username,current) in xray_now.items():
            row=c.execute('SELECT byte_value,username FROM xray_counters WHERE stat_name=?',(stat_name,)).fetchone()
            # First observation is baseline only. If Xray restarted (counter dropped), count from zero.
            delta=0 if row is None else (current-row[0] if current>=row[0] else current)
            if delta>0:
                deltas[username]=deltas.get(username,0)+delta; xseen.add(username)
            c.execute('INSERT INTO xray_counters(stat_name,username,byte_value,updated_at) VALUES(?,?,?,?) ON CONFLICT(stat_name) DO UPDATE SET username=excluded.username,byte_value=excluded.byte_value,updated_at=excluded.updated_at',(stat_name,username,current,now))
        for key,(username,tx,rx) in ssh_now.items():
            row=c.execute('SELECT tx_bytes,rx_bytes,username FROM ssh_counters WHERE session_key=?',(key,)).fetchone()
            delta=0
            if row and row[2]==username:
                delta=(tx-row[0] if tx>=row[0] else tx)+(rx-row[1] if rx>=row[1] else rx)
            if delta>0:
                deltas[username]=deltas.get(username,0)+delta; sseen.add(username)
            c.execute('INSERT INTO ssh_counters(session_key,username,tx_bytes,rx_bytes,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(session_key) DO UPDATE SET username=excluded.username,tx_bytes=excluded.tx_bytes,rx_bytes=excluded.rx_bytes,updated_at=excluded.updated_at',(key,username,tx,rx,now))
        for username,byte_delta in deltas.items():
            c.execute('UPDATE users SET used_traffic=used_traffic+? WHERE username=?',(byte_delta/(1024*1024),username))
        for u in xseen:c.execute('UPDATE users SET last_xray_seen=? WHERE username=?',(now,u))
        for u in sseen:c.execute('UPDATE users SET last_ssh_seen=? WHERE username=?',(now,u))
        c.execute('DELETE FROM ssh_counters WHERE updated_at < ?',(now-600,))
        c.execute('DELETE FROM xray_counters WHERE updated_at < ?',(now-86400,))
        rows=c.execute('SELECT username,total_traffic,used_traffic,expire_date FROM users WHERE status=1').fetchall()
        for username,total,used,expire in rows:
            expired=bool(total and total>0 and used>=total)
            try:
                if expire and datetime.now()>datetime.strptime(expire,'%Y-%m-%d %H:%M'):expired=True
            except Exception:pass
            if expired:
                c.execute('UPDATE users SET status=0 WHERE username=?',(username,)); disabled.append(username)
        conn.commit()
    except Exception:
        conn.rollback(); raise
    finally:conn.close()
    for username in disabled:
        subprocess.run(['usermod','-L',username],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        subprocess.run(['pkill','-u',username],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if disabled:
        # Rebuild Xray config without restarting the web panel.
        code="import sys;sys.path.insert(0,'/root/ssh-panel');import app;app.reload_xray_config(force=True)"
        subprocess.run(['/root/ssh-panel/venv/bin/python','-c',code],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)

def main():
    print('Worker started - persistent non-reset Xray/SSH counters',flush=True)
    while True:
        started=time.time()
        try:apply_usage(read_xray_counters(),ssh_snapshot())
        except Exception as e:print(f'Worker loop error: {e}',flush=True)
        time.sleep(max(1,5-(time.time()-started)))
if __name__=='__main__':main()
WORKEREOF
echo "✓ Worker created (SSH traffic counting active)"
echo "[*] Validating generated Python files..."
/root/ssh-panel/venv/bin/python -m py_compile /root/ssh-panel/app.py /root/ssh-panel/traffic_worker.py || { echo "❌ Python validation failed (app/worker)"; exit 1; }
echo "✓ Python syntax validated"

# ============================================
# STEP 8: Connection Limiter
# ============================================
echo "[8/16] Creating connection limiter..."
cat << 'EOF' > /root/ssh-panel/connection_limiter.py
#!/usr/bin/env python3
import sqlite3, subprocess, time, re
DB_PATH='/root/ssh-panel/panel.db'
def limits():
    c=sqlite3.connect(DB_PATH,timeout=10); rows=c.execute("SELECT username,max_connections FROM users WHERE status=1 AND max_connections>0").fetchall(); c.close(); return dict(rows)
def sessions():
    out=subprocess.run(['ss','-tnp','state','established','sport','=',':22'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=4).stdout
    pids=sorted(set(re.findall(r'pid=(\d+)',out)))
    if not pids:return {}
    ps=subprocess.run(['ps','-o','pid=,user=,args=','-p',','.join(pids)],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=4).stdout
    by={}
    for line in ps.splitlines():
        p=line.strip().split(None,2)
        if len(p)<2: continue
        pid,user=int(p[0]),p[1]; args=p[2] if len(p)>2 else ''
        actual=user
        if user in ('root','sshd'):
            m=re.search(r'sshd:\s+([a-zA-Z0-9_-]+)',args)
            actual=m.group(1) if m and m.group(1) not in ('root','sshd','priv') else None
        if actual:
            by.setdefault(actual,[]).append(pid)
    return by
def main():
    print('[*] SSH connection limiter started (process based, no iptables rebuild)',flush=True)
    while True:
        try:
            lim=limits(); ses=sessions()
            for u,pids in ses.items():
                maxc=lim.get(u)
                if maxc and len(pids)>maxc:
                    # Keep oldest PID/session, terminate newest extras only.
                    for pid in sorted(pids, reverse=True)[:len(pids)-maxc]:
                        subprocess.run(['kill','-TERM',str(pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        except Exception as e: print(f'Limiter error: {e}',flush=True)
        time.sleep(5)
if __name__=='__main__': main()
EOF
chmod +x /root/ssh-panel/connection_limiter.py
/root/ssh-panel/venv/bin/python -m py_compile /root/ssh-panel/connection_limiter.py || { echo "❌ Python validation failed (limiter)"; exit 1; }

cat << 'EOF' > /etc/systemd/system/ssh-connection-limiter.service
[Unit]
Description=SSH Connection Limiter
After=network.target ssh.service
[Service]
Type=simple
User=root
ExecStart=/root/ssh-panel/venv/bin/python /root/ssh-panel/connection_limiter.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

echo "✓ Connection limiter created"

# ============================================
# STEP 9-14: ALL HTML TEMPLATES (کامل)
# ============================================
echo "[9/16] Creating HTML templates..."

cat << 'EOF' > /root/ssh-panel/templates/error.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>خطا | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#0a0a0a}.glass{background:rgba(20,0,0,0.9);border:1px solid rgba(255,0,0,0.2);border-radius:24px;padding:2rem;text-align:center;max-width:400px;margin:auto}</style></head><body class="min-h-screen flex items-center justify-center p-4"><div class="glass shadow-2xl shadow-red-900/20"><div class="w-20 h-20 mx-auto bg-red-900/30 rounded-2xl flex items-center justify-center mb-4 border border-red-500/30"><i class="fa-solid fa-triangle-exclamation text-4xl text-red-500"></i></div><h1 class="text-xl font-bold text-red-400 mb-2">خطا</h1><p class="text-gray-400 text-sm mb-6">{{ error_message }}</p><a href="/dashboard" class="inline-flex items-center gap-2 px-6 py-2.5 bg-gradient-to-r from-red-700 to-red-900 text-red-100 text-sm font-bold rounded-xl border border-red-500/30">بازگشت</a></div></body></html>
EOF

cat << 'EOF' > /root/ssh-panel/templates/login.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>ورود | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;min-height:100vh}@keyframes pulseRed{0%,100%{box-shadow:0 0 30px rgba(220,38,38,0.3)}50%{box-shadow:0 0 60px rgba(220,38,38,0.6)}}.pulse-red{animation:pulseRed 3s ease-in-out infinite}.slide-up{animation:slideUp 0.8s ease-out}@keyframes slideUp{from{opacity:0;transform:translateY(30px)}to{opacity:1;transform:translateY(0)}}</style></head><body class="flex items-center justify-center p-4"><div class="w-full max-w-md slide-up"><div class="bg-gradient-to-b from-[#1a0000] to-[#0a0000] border border-red-900/50 rounded-3xl p-8 shadow-2xl pulse-red"><div class="text-center mb-8"><div class="w-24 h-24 mx-auto bg-gradient-to-br from-red-700 to-red-900 rounded-2xl flex items-center justify-center shadow-lg mb-4 border border-red-500/30"><span class="text-5xl font-black text-red-100">OP</span></div><h1 class="text-2xl font-bold text-red-400">OutlineParsian</h1><p class="text-sm text-red-700/70 mt-1">Ultimate Panel</p></div>{% if error %}<div class="bg-red-900/30 border border-red-700/50 text-red-400 p-4 rounded-2xl mb-6 text-sm"><i class="fa-solid fa-triangle-exclamation ml-2"></i>{{ error }}</div>{% endif %}<form action="/" method="POST" class="space-y-5"><div><label class="block text-xs font-bold text-red-400/70 mb-2">نام کاربری</label><input type="text" name="username" required class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 text-left font-mono outline-none focus:border-red-500 transition-all" dir="ltr" placeholder="admin"></div><div><label class="block text-xs font-bold text-red-400/70 mb-2">کلمه عبور</label><input type="password" name="password" required class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 text-left font-mono outline-none focus:border-red-500 transition-all" dir="ltr" placeholder="••••••••"></div><button type="submit" class="w-full bg-gradient-to-r from-red-700 to-red-900 hover:from-red-600 hover:to-red-800 py-4 rounded-2xl font-bold text-red-100 shadow-lg transition-all border border-red-500/30">ورود به پنل</button></form></div></div></body></html>
EOF

cat << 'EOF' > /root/ssh-panel/templates/dashboard.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>مدیریت کاربران | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:Vazirmatn,sans-serif}body{background:#050505;color:#eee}.glass{background:rgba(20,0,0,.82);border:1px solid rgba(239,68,68,.18)}.btn{transition:.15s}.btn:hover{transform:translateY(-1px)}tr:hover{background:rgba(127,29,29,.1)}</style></head><body>
<nav class="glass sticky top-0 z-40 px-4 py-3"><div class="max-w-7xl mx-auto flex gap-3 items-center justify-between flex-wrap"><div class="font-black text-red-400 text-lg">OutlineParsian</div><div class="flex gap-2 text-xs"><span class="px-3 py-1 rounded-full bg-black/60">CPU <b id="cpu_value">{{ cpu }}</b>%</span><span class="px-3 py-1 rounded-full bg-black/60">RAM <b id="ram_value">{{ ram }}</b>%</span></div><div class="flex gap-2 text-xs"><a class="px-3 py-2 rounded-xl bg-red-800" href="/add_user_page">+ کاربر جدید</a><a class="px-3 py-2 rounded-xl bg-black/60" href="/inbounds">اینباند</a><a class="px-3 py-2 rounded-xl bg-black/60" href="/groups">گروه‌ها</a><a class="px-3 py-2 rounded-xl bg-black/60" href="/settings">تنظیمات</a><a class="px-3 py-2 rounded-xl bg-black/60" href="/reports">گزارش</a><a class="px-3 py-2 rounded-xl bg-red-950" href="/logout">خروج</a></div></div></nav>
<main class="max-w-7xl mx-auto p-4">{% with messages=get_flashed_messages(with_categories=true) %}{% for category,message in messages %}<div class="mb-3 p-3 rounded-xl border {% if category=='success' %}border-emerald-800 bg-emerald-950/40 text-emerald-300{% else %}border-red-800 bg-red-950/40 text-red-300{% endif %}">{{ message }}</div>{% endfor %}{% endwith %}
<div class="grid grid-cols-2 md:grid-cols-5 gap-3 mb-4">{% for label,val,icon in [('کل کاربران',total_users,'users'),('فعال',active_users,'user-check'),('اینباند',total_inbounds,'server'),('کلاینت',total_clients,'plug'),('مصرف GB',total_used,'database')] %}<div class="glass rounded-2xl p-4"><div class="text-xs text-red-300/60">{{ label }}</div><div class="text-2xl font-black mt-1">{{ val }}</div></div>{% endfor %}</div>
<div class="glass rounded-2xl p-3 mb-4"><form method="get" class="flex flex-wrap gap-2"><input name="q" value="{{ q }}" placeholder="جستجوی نام کاربری..." class="flex-1 min-w-52 bg-black border border-red-900 rounded-xl px-4 py-2 text-sm"><select name="status" class="bg-black border border-red-900 rounded-xl px-3 py-2 text-sm"><option value="all" {% if status_filter=='all' %}selected{% endif %}>همه</option><option value="1" {% if status_filter=='1' %}selected{% endif %}>فعال</option><option value="0" {% if status_filter=='0' %}selected{% endif %}>غیرفعال</option></select><button class="px-5 py-2 bg-red-800 rounded-xl text-sm">فیلتر</button><a href="/dashboard" class="px-4 py-2 bg-black/60 rounded-xl text-sm">پاک کردن</a></form></div>
<form action="/bulk_users" method="post" id="bulkForm"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><div class="glass rounded-2xl p-3 mb-3 flex flex-wrap items-center gap-2"><span class="text-xs text-red-300/60 ml-2">عملیات گروهی:</span><select name="action" required class="bg-black border border-red-900 rounded-xl px-3 py-2 text-xs"><option value="">انتخاب...</option><option value="activate">فعال‌سازی</option><option value="deactivate">غیرفعال‌سازی</option><option value="extend_30">+۳۰ روز</option><option value="add_10gb">+۱۰ گیگ</option><option value="reset_traffic">صفر کردن مصرف</option><option value="delete">حذف</option></select><button onclick="return confirmBulk()" class="px-4 py-2 bg-red-800 rounded-xl text-xs">اجرا</button><span class="mr-auto text-xs text-gray-500">{{ filtered }} نتیجه</span></div>
<div class="glass rounded-2xl overflow-x-auto"><table class="w-full text-sm min-w-[1050px]"><thead class="bg-black/70 text-red-300/70 text-xs"><tr><th class="p-3"><input type="checkbox" id="all" onclick="toggleAll(this)"></th><th class="p-3 text-right">کاربر</th><th class="p-3 text-right">ترافیک</th><th class="p-3">اتصال SSH</th><th class="p-3">انقضا</th><th class="p-3">وضعیت</th><th class="p-3">عملیات سریع</th></tr></thead><tbody>{% for user in users %}<tr class="border-t border-red-950/60"><td class="p-3 text-center"><input class="uc" type="checkbox" name="usernames" value="{{ user.username }}"></td><td class="p-3"><div class="font-bold text-red-300">{{ user.username }} {% if user.is_online %}<span class="text-emerald-400 text-[10px]">● آنلاین</span>{% endif %}</div><div class="text-[10px] text-gray-600 font-mono">{{ user.password }}</div></td><td class="p-3"><div class="flex justify-between text-[10px]"><span>{{ user.used_traffic }} GB</span><span>{{ user.total_traffic }} GB</span></div><div class="h-1.5 bg-red-950 rounded mt-1 overflow-hidden"><div class="h-full bg-red-500" style="width:{{ user.usage_percent }}%"></div></div><div class="text-[10px] text-gray-600 mt-1">باقی: {{ user.remaining_traffic }} GB</div></td><td class="p-3 text-center">{{ user.online_count }}/{{ user.max_connections }}</td><td class="p-3 text-center text-xs font-mono">{{ user.expire_date }}</td><td class="p-3 text-center">{% if user.status==1 %}<span class="text-emerald-400">فعال</span>{% else %}<span class="text-red-400">غیرفعال</span>{% endif %}</td><td class="p-3"><div class="flex gap-1 justify-center"><a title="اشتراک" target="_blank" href="/sub/{{ user.username }}" class="btn px-2 py-1.5 bg-blue-950 text-blue-300 rounded-lg"><i class="fa-solid fa-link"></i></a><button type="button" title="ویرایش" onclick='openEdit({{ user|tojson }})' class="btn px-2 py-1.5 bg-amber-950 text-amber-300 rounded-lg"><i class="fa-solid fa-pen"></i></button><button type="submit" formaction="/user_action/{{ user.username }}" name="action" value="toggle" class="btn px-2 py-1.5 bg-purple-950 text-purple-300 rounded-lg">{% if user.status==1 %}خاموش{% else %}روشن{% endif %}</button><button type="submit" formaction="/user_action/{{ user.username }}" name="action" value="extend_30" class="btn px-2 py-1.5 bg-emerald-950 text-emerald-300 rounded-lg">+30d</button><button type="submit" formaction="/user_action/{{ user.username }}" name="action" value="add_10gb" class="btn px-2 py-1.5 bg-sky-950 text-sky-300 rounded-lg">+10G</button><button type="submit" formaction="/user_action/{{ user.username }}" name="action" value="reset_traffic" onclick="return confirm('مصرف صفر شود؟')" class="btn px-2 py-1.5 bg-orange-950 text-orange-300 rounded-lg">0G</button><button type="submit" formaction="/delete_user/{{ user.username }}" onclick="return confirm('کاربر حذف شود؟')" class="btn px-2 py-1.5 bg-red-950 text-red-300 rounded-lg"><i class="fa-solid fa-trash"></i></button></div></td></tr>{% endfor %}</tbody></table></div></form>
<div class="flex items-center justify-center gap-2 mt-4 text-xs">{% if page>1 %}<a class="px-3 py-2 glass rounded-lg" href="?q={{ q }}&status={{ status_filter }}&page={{ page-1 }}">قبلی</a>{% endif %}<span>صفحه {{ page }} از {{ pages }}</span>{% if page<pages %}<a class="px-3 py-2 glass rounded-lg" href="?q={{ q }}&status={{ status_filter }}&page={{ page+1 }}">بعدی</a>{% endif %}</div></main>
<div id="editModal" class="fixed inset-0 bg-black/90 z-50 items-center justify-center p-4" style="display:none"><div class="glass rounded-3xl p-6 w-full max-w-md"><div class="flex justify-between mb-4"><b>ویرایش کاربر</b><button onclick="closeEdit()">✕</button></div><form action="/edit_user" method="post" class="space-y-3"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><input type="hidden" name="username" id="e_u"><input name="password" id="e_p" required class="w-full bg-black border border-red-900 rounded-xl p-3" placeholder="رمز"><div class="grid grid-cols-2 gap-2"><input type="number" step="0.1" name="traffic_gb" id="e_t" required class="bg-black border border-red-900 rounded-xl p-3" placeholder="GB"><input type="number" name="max_connections" id="e_c" required class="bg-black border border-red-900 rounded-xl p-3" placeholder="اتصال SSH"></div><input name="expire_date" id="e_e" required class="w-full bg-black border border-red-900 rounded-xl p-3" placeholder="YYYY-MM-DD HH:MM"><select name="status" id="e_s" class="w-full bg-black border border-red-900 rounded-xl p-3"><option value="1">فعال</option><option value="0">غیرفعال</option></select><button class="w-full bg-red-800 rounded-xl p-3 font-bold">ذخیره</button></form></div></div>
<script>function toggleAll(x){document.querySelectorAll('.uc').forEach(e=>e.checked=x.checked)}function confirmBulk(){const a=document.querySelector('#bulkForm select[name=action]').value;if(!a)return false;const n=document.querySelectorAll('.uc:checked').length;if(!n){alert('کاربری انتخاب نشده');return false}return a==='delete'?confirm('حذف '+n+' کاربر؟'):true}function openEdit(u){e_u.value=u.username;e_p.value=u.password;e_t.value=u.total_traffic;e_c.value=u.max_connections;e_e.value=u.expire_date;e_s.value=u.status;editModal.style.display='flex'}function closeEdit(){editModal.style.display='none'}setInterval(()=>fetch('/api/stats').then(r=>r.json()).then(d=>{cpu_value.textContent=d.cpu;ram_value.textContent=d.ram}).catch(()=>{}),5000)</script></body></html>
EOF

cat << 'EOF' > /root/ssh-panel/templates/add_user.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>کاربر جدید | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.9);border:1px solid rgba(255,0,0,0.15)}</style></head><body class="min-h-screen"><nav class="glass px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex justify-between items-center"><h1 class="text-lg font-bold text-red-400">ایجاد اکانت SSH</h1><a href="/dashboard" class="px-4 py-2 glass rounded-xl text-red-300 text-sm">بازگشت</a></div></nav><main class="p-6 max-w-xl mx-auto"><div class="glass rounded-3xl p-8"><form action="/add_user" method="POST" class="space-y-5"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><div><label class="block text-sm text-red-400/70 mb-2">نام کاربری</label><input type="text" name="username" required class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 font-mono outline-none focus:border-red-500/50" dir="ltr"></div><div><label class="block text-sm text-red-400/70 mb-2">کلمه عبور</label><input type="text" name="password" required class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 font-mono outline-none focus:border-red-500/50" dir="ltr"></div><div class="grid grid-cols-3 gap-4"><div><label class="block text-sm text-red-400/70 mb-2">مدت (روز)</label><input type="number" name="expire_days" value="30" class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 text-center outline-none focus:border-red-500/50"></div><div><label class="block text-sm text-red-400/70 mb-2">حجم (GB)</label><input type="number" step="0.1" name="traffic_gb" value="50" class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 text-center outline-none focus:border-red-500/50"></div><div><label class="block text-sm text-red-400/70 mb-2">اتصال SSH</label><input type="number" name="max_connections" value="2" class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 text-center outline-none focus:border-red-500/50"></div></div><button type="submit" class="w-full bg-gradient-to-r from-red-700 to-red-900 py-4 rounded-2xl font-bold text-red-100 shadow-lg transition-all border border-red-500/30">ساخت اکانت</button></form></div></main></body></html>
EOF

cat << 'EOF' > /root/ssh-panel/templates/inbounds.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>اینباندها | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);backdrop-filter:blur(20px);border:1px solid rgba(255,0,0,0.15)}.nav-link{transition:all 0.2s}.nav-link:hover{background:rgba(220,38,38,0.15);color:#f87171}.nav-link.active{background:rgba(220,38,38,0.25);color:#f87171;border:1px solid rgba(220,38,38,0.4)}.badge{font-size:10px;padding:3px 10px;border-radius:20px;font-weight:bold}</style></head><body class="min-h-screen"><nav class="glass sticky top-0 z-50 px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex items-center justify-between flex-wrap gap-3"><div class="flex items-center gap-3"><div class="w-10 h-10 bg-gradient-to-br from-red-700 to-red-900 rounded-xl flex items-center justify-center shadow-lg border border-red-500/30"><span class="text-lg font-black text-red-100">OP</span></div><div><h1 class="text-lg font-bold text-red-400">اینباندها</h1></div></div><div class="flex items-center gap-4 text-xs"><span class="bg-red-900/20 px-3 py-1 rounded-full border border-red-800/30"><i class="fa-solid fa-microchip text-red-500"></i> {{ cpu }}%</span><span class="bg-red-900/20 px-3 py-1 rounded-full border border-red-800/30"><i class="fa-solid fa-memory text-red-400"></i> {{ ram }}%</span></div><div class="flex items-center gap-2 flex-wrap"><a href="/dashboard" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs">داشبورد</a><a href="/inbounds" class="nav-link active px-3 py-1.5 rounded-lg text-xs font-bold">اینباند</a><a href="/groups" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs">گروه‌ها</a><a href="/add_inbound_page" class="px-3 py-1.5 bg-gradient-to-r from-red-700 to-red-900 rounded-lg text-red-100 text-xs font-bold border border-red-500/30">+ اینباند</a><a href="/settings" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs"><i class="fa-solid fa-gear"></i></a><a href="/logout" class="px-3 py-1.5 bg-red-900/30 text-red-400 rounded-lg border border-red-800/50 text-xs">خروج</a></div></div></nav><main class="p-4 max-w-7xl mx-auto">{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, message in messages %}<div class="{% if category == 'success' %}bg-emerald-900/30 border border-emerald-700/50 text-emerald-400{% else %}bg-red-900/30 border border-red-700/50 text-red-400{% endif %} p-4 rounded-2xl text-sm mb-4">{{ message }}</div>{% endfor %}{% endif %}{% endwith %}<div class="glass rounded-2xl p-4 overflow-hidden"><table class="w-full text-right text-sm"><thead><tr class="bg-black/50 text-red-400/70 text-xs"><th class="p-4">Tag</th><th class="p-4">پروتکل</th><th class="p-4">پورت</th><th class="p-4">شبکه</th><th class="p-4">امنیت</th><th class="p-4">SNI/FP</th><th class="p-4 text-center">کلاینت</th><th class="p-4 text-center">عملیات</th></tr></thead><tbody class="divide-y divide-red-900/20">{% for ib in inbounds %}<tr class="hover:bg-red-900/10"><td class="p-4 font-bold text-red-400">{{ ib.tag }}</td><td class="p-4"><span class="badge {% if ib.protocol=='vless' %}bg-blue-900/30 text-blue-400{% elif ib.protocol=='vmess' %}bg-purple-900/30 text-purple-400{% elif ib.protocol=='trojan' %}bg-amber-900/30 text-amber-400{% else %}bg-gray-900/30 text-gray-400{% endif %}">{{ ib.protocol|upper }}</span></td><td class="p-4 text-red-300 font-mono">{{ ib.port }}</td><td class="p-4 text-red-400/70 text-xs">{{ ib.network|upper }}</td><td class="p-4">{% if ib.security=='reality' %}<span class="text-emerald-400 text-xs">🔒 Reality</span>{% elif ib.security=='tls' %}<span class="text-blue-400 text-xs">🔐 TLS</span>{% else %}<span class="text-gray-500 text-xs">None</span>{% endif %}</td><td class="p-4 text-[10px] text-red-400/50">{% if ib.security!='none' %}{{ ib.server_name }}/{{ ib.fingerprint }}{% else %}-{% endif %}</td><td class="p-4 text-center"><a href="/clients/{{ ib.id }}" class="px-3 py-1 bg-red-900/20 text-red-400 rounded-lg text-xs font-bold border border-red-800/30">{{ ib.client_count }}</a></td><td class="p-4 text-center"><div class="inline-flex gap-1.5"><a href="/clients/{{ ib.id }}" class="p-2 bg-blue-900/20 text-blue-400 border border-blue-800/30 rounded-xl text-xs"><i class="fa-solid fa-users"></i></a><form action="/delete_inbound/{{ ib.id }}" method="POST" class="inline"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><button type="submit" onclick="return confirm('حذف؟')" class="p-2 bg-red-900/30 text-red-400 border border-red-700/50 rounded-xl text-xs"><i class="fa-solid fa-trash"></i></button></form></div></td></tr>{% endfor %}</tbody></table></div></main></body></html>
EOF

cat << 'EOF' > /root/ssh-panel/templates/add_inbound.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>اینباند جدید | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;500;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);backdrop-filter:blur(20px);border:1px solid rgba(255,0,0,0.15)}.fp-btn{transition:all 0.2s}.fp-btn:hover{background:rgba(220,38,38,0.2);border-color:rgba(220,38,38,0.4)}.fp-btn.active{background:rgba(220,38,38,0.3);border-color:#dc2626;color:#f87171}</style></head><body class="min-h-screen pb-20"><nav class="glass sticky top-0 z-50 px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex justify-between items-center"><div class="flex items-center gap-3"><div class="w-10 h-10 bg-gradient-to-br from-red-700 to-red-900 rounded-xl flex items-center justify-center shadow-lg border border-red-500/30"><span class="text-lg font-black text-red-100">OP</span></div><div><h1 class="text-lg font-bold text-red-400">ساخت اینباند جدید</h1></div></div><a href="/inbounds" class="px-4 py-2 glass rounded-xl text-red-300 text-sm"><i class="fa-solid fa-arrow-right ml-1"></i>بازگشت</a></div></nav><main class="p-4 md:p-6 max-w-5xl mx-auto"><form action="/add_inbound" method="POST"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><div class="space-y-6"><div class="glass rounded-3xl p-6"><h3 class="text-lg font-bold text-red-400 mb-4">اطلاعات پایه</h3><div class="grid grid-cols-1 md:grid-cols-3 gap-4"><div><label class="block text-xs font-bold text-red-400/70 mb-2">نام (Tag)</label><input type="text" name="tag" required class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 font-mono text-sm outline-none focus:border-red-500" dir="ltr"></div><div><label class="block text-xs font-bold text-red-400/70 mb-2">پروتکل</label><select name="protocol" class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 text-sm outline-none focus:border-red-500"><option value="vless">VLESS</option><option value="vmess">VMess</option><option value="trojan">Trojan</option></select></div><div><label class="block text-xs font-bold text-red-400/70 mb-2">پورت <span class="text-emerald-400 text-[10px]">(رندوم)</span></label><div class="flex gap-2"><input type="number" name="port" id="port_input" value="{{ random_port }}" class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 text-center text-sm outline-none focus:border-red-500"><button type="button" onclick="randomPort()" class="px-4 py-3 bg-emerald-900/30 text-emerald-400 rounded-2xl border border-emerald-700/50"><i class="fa-solid fa-shuffle"></i></button></div></div></div></div><div class="glass rounded-3xl p-6"><h3 class="text-lg font-bold text-red-400 mb-4">انتقال</h3><div class="grid grid-cols-2 gap-4"><div><label class="block text-xs font-bold text-red-400/70 mb-2">نوع</label><select name="network" class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 text-sm"><option value="tcp">TCP</option><option value="ws">WebSocket</option><option value="grpc">gRPC</option></select></div><div><label class="block text-xs font-bold text-red-400/70 mb-2">Path</label><input type="text" name="path" value="/" class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 font-mono text-sm" dir="ltr"></div></div></div><div class="glass rounded-3xl p-6"><h3 class="text-lg font-bold text-red-400 mb-4">امنیت</h3><div class="grid grid-cols-3 gap-3 mb-6"><label class="cursor-pointer"><input type="radio" name="security" value="none" class="hidden peer" checked><div class="glass rounded-2xl p-4 border-2 border-transparent peer-checked:border-red-500 text-center"><span class="text-sm font-bold text-gray-400">None</span></div></label><label class="cursor-pointer"><input type="radio" name="security" value="tls" class="hidden peer"><div class="glass rounded-2xl p-4 border-2 border-transparent peer-checked:border-blue-500 text-center"><span class="text-sm font-bold text-blue-400">TLS</span></div></label><label class="cursor-pointer"><input type="radio" name="security" value="reality" class="hidden peer"><div class="glass rounded-2xl p-4 border-2 border-transparent peer-checked:border-emerald-500 text-center"><span class="text-sm font-bold text-emerald-400">Reality</span></div></label></div><div id="security_settings" style="display:none"><div class="bg-black border border-red-900/50 rounded-2xl p-5 mb-4"><h4 class="text-sm font-bold text-red-400 mb-3">Server Name (SNI)</h4><div class="grid grid-cols-4 gap-2 mb-3"><button type="button" onclick="setSNI('www.microsoft.com')" class="px-3 py-2 bg-gray-900/50 hover:bg-blue-900/30 border border-gray-700/30 rounded-xl text-xs text-gray-300">Microsoft</button><button type="button" onclick="setSNI('www.google.com')" class="px-3 py-2 bg-gray-900/50 hover:bg-blue-900/30 border border-gray-700/30 rounded-xl text-xs text-gray-300">Google</button><button type="button" onclick="setSNI('www.cloudflare.com')" class="px-3 py-2 bg-gray-900/50 hover:bg-blue-900/30 border border-gray-700/30 rounded-xl text-xs text-gray-300">Cloudflare</button><button type="button" onclick="setSNI('www.amazon.com')" class="px-3 py-2 bg-gray-900/50 hover:bg-blue-900/30 border border-gray-700/30 rounded-xl text-xs text-gray-300">Amazon</button></div><input type="text" id="sni_input" name="server_name" value="www.microsoft.com" class="w-full bg-black border border-red-900/50 rounded-2xl p-3 text-red-300 font-mono text-sm" dir="ltr"></div><div class="bg-black border border-red-900/50 rounded-2xl p-5"><h4 class="text-sm font-bold text-red-400 mb-3">Fingerprint</h4><div class="grid grid-cols-5 gap-2 mb-3"><button type="button" onclick="setFP('chrome')" class="fp-btn active px-3 py-2 bg-blue-900/20 text-blue-400 border border-blue-700/50 rounded-xl text-xs" id="fp_chrome">Chrome</button><button type="button" onclick="setFP('firefox')" class="fp-btn px-3 py-2 bg-orange-900/20 text-orange-400 border border-orange-700/30 rounded-xl text-xs" id="fp_firefox">Firefox</button><button type="button" onclick="setFP('safari')" class="fp-btn px-3 py-2 bg-gray-800/50 text-gray-400 border border-gray-700/30 rounded-xl text-xs" id="fp_safari">Safari</button><button type="button" onclick="setFP('edge')" class="fp-btn px-3 py-2 bg-gray-800/50 text-gray-400 border border-gray-700/30 rounded-xl text-xs" id="fp_edge">Edge</button><button type="button" onclick="setFP('random')" class="fp-btn px-3 py-2 bg-amber-900/20 text-amber-400 border border-amber-700/30 rounded-xl text-xs" id="fp_random">Random</button></div><input type="hidden" name="fingerprint" id="fp_input" value="chrome"><div class="text-xs text-red-400/50">انتخاب: <span id="fp_display" class="text-red-400 font-mono">chrome</span></div></div></div></div><button type="submit" class="w-full bg-gradient-to-r from-red-700 via-red-800 to-red-950 py-4 rounded-2xl font-bold text-red-100 text-lg shadow-2xl border border-red-500/30">ساخت اینباند</button></div></form></main><script>function randomPort(){document.getElementById('port_input').value=Math.floor(Math.random()*55000+10000)}function setSNI(s){document.getElementById('sni_input').value=s}function setFP(f){document.getElementById('fp_input').value=f;document.getElementById('fp_display').textContent=f;document.querySelectorAll('.fp-btn').forEach(b=>b.classList.remove('active'));const btn=document.getElementById('fp_'+f);if(btn)btn.classList.add('active')}document.querySelectorAll('input[name=security]').forEach(r=>r.addEventListener('change',()=>{document.getElementById('security_settings').style.display=r.value==='none'?'none':'block';if(r.checked&&r.value==='reality'){const n=document.querySelector('select[name=network]');if(n.value==='ws'){n.value='tcp';alert('Reality روی WebSocket پشتیبانی نمی‌شود؛ انتقال به TCP تغییر کرد.')}}}))</script></body></html>
EOF

cat << 'EOF' > /root/ssh-panel/templates/clients.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>کلاینت‌ها | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);backdrop-filter:blur(20px);border:1px solid rgba(255,0,0,0.15)}.link-box{transition:all 0.3s;cursor:pointer}.link-box:hover{transform:translateY(-2px);box-shadow:0 10px 30px rgba(220,38,38,0.2)}.copied{position:absolute;top:8px;right:8px;background:#10b981;color:#fff;padding:4px 10px;border-radius:20px;font-size:10px;z-index:10}</style></head><body class="min-h-screen"><nav class="glass sticky top-0 z-50 px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex items-center justify-between"><div class="flex items-center gap-3"><div class="w-10 h-10 bg-gradient-to-br from-red-700 to-red-900 rounded-xl flex items-center justify-center border border-red-500/30"><span class="text-lg font-black text-red-100">OP</span></div><div><h1 class="text-lg font-bold text-red-400">کلاینت‌های {{ inbound.tag }}</h1></div></div><a href="/inbounds" class="px-3 py-1.5 bg-red-900/20 text-red-400 rounded-lg text-xs border border-red-800/30">بازگشت</a></div></nav><main class="p-4 max-w-5xl mx-auto">{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, message in messages %}<div class="{% if category == 'success' %}bg-emerald-900/30 border border-emerald-700/50 text-emerald-400{% else %}bg-red-900/30 border border-red-700/50 text-red-400{% endif %} p-4 rounded-2xl text-sm mb-4">{{ message }}</div>{% endfor %}{% endif %}{% endwith %}{% if available_users %}<div class="glass rounded-2xl p-4 mb-4"><form action="/add_clients/{{ inbound.id }}" method="POST"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><div class="grid grid-cols-2 md:grid-cols-4 gap-2 mb-3 max-h-40 overflow-y-auto">{% for uname in available_users %}<label class="flex items-center gap-2 bg-black border border-red-900/30 p-2 rounded-xl cursor-pointer"><input type="checkbox" name="usernames" value="{{ uname }}" class="text-red-600 rounded"><span class="text-xs text-red-300">{{ uname }}</span></label>{% endfor %}</div><button type="submit" class="px-4 py-2 bg-gradient-to-r from-red-700 to-red-900 text-red-100 text-xs font-bold rounded-xl">افزودن</button></form></div>{% endif %}<div class="space-y-3">{% for cl in clients %}<div class="glass rounded-2xl p-4"><div class="flex items-center justify-between mb-3"><span class="font-bold text-red-400">{{ cl.username }}</span><form action="/delete_client/{{ cl.id }}" method="POST" class="inline"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><button type="submit" onclick="return confirm('حذف؟')" class="p-2 bg-red-900/30 text-red-400 border border-red-700/50 rounded-xl text-xs"><i class="fa-solid fa-trash"></i></button></form></div><div class="link-box bg-black border border-red-900/30 rounded-xl p-3 relative" onclick="copyLink('{{ cl.link }}', this)"><code class="text-xs text-red-300 break-all block" dir="ltr">{{ cl.link }}</code><div class="mt-1 text-[10px] text-red-600">کلیک برای کپی</div></div></div>{% endfor %}</div></main><script>function copyLink(t,e){navigator.clipboard.writeText(t).then(()=>{const n=document.createElement('div');n.className='copied';n.innerHTML='✓ کپی شد';e.appendChild(n);setTimeout(()=>n.remove(),2000)})}</script></body></html>
EOF

cat << 'EOF' > /root/ssh-panel/templates/groups.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>گروه‌ها | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);backdrop-filter:blur(20px);border:1px solid rgba(255,0,0,0.15)}.nav-link{transition:all 0.2s}.nav-link:hover{background:rgba(220,38,38,0.15);color:#f87171}.nav-link.active{background:rgba(220,38,38,0.25);color:#f87171;border:1px solid rgba(220,38,38,0.4)}</style></head><body class="min-h-screen"><nav class="glass sticky top-0 z-50 px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex items-center justify-between flex-wrap gap-3"><div class="flex items-center gap-3"><div class="w-10 h-10 bg-gradient-to-br from-red-700 to-red-900 rounded-xl flex items-center justify-center border border-red-500/30"><span class="text-lg font-black text-red-100">OP</span></div><h1 class="text-lg font-bold text-red-400">مدیریت گروه‌ها</h1></div><div class="flex items-center gap-4 text-xs"><span class="bg-red-900/20 px-3 py-1 rounded-full"><i class="fa-solid fa-microchip text-red-500"></i> {{ cpu }}%</span><span class="bg-red-900/20 px-3 py-1 rounded-full"><i class="fa-solid fa-memory text-red-400"></i> {{ ram }}%</span></div><div class="flex items-center gap-2"><a href="/dashboard" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs">داشبورد</a><a href="/inbounds" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs">اینباند</a><a href="/groups" class="nav-link active px-3 py-1.5 rounded-lg text-xs font-bold">گروه‌ها</a><a href="/logout" class="px-3 py-1.5 bg-red-900/30 text-red-400 rounded-lg border border-red-800/50 text-xs">خروج</a></div></div></nav><main class="p-4 max-w-4xl mx-auto">{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, message in messages %}<div class="{% if category == 'success' %}bg-emerald-900/30 border border-emerald-700/50 text-emerald-400{% else %}bg-red-900/30 border border-red-700/50 text-red-400{% endif %} p-4 rounded-2xl text-sm mb-4">{{ message }}</div>{% endfor %}{% endif %}{% endwith %}<div class="glass rounded-2xl p-4 mb-4"><form action="/add_group" method="POST" class="flex gap-3 items-end"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><div class="flex-1"><label class="block text-xs text-red-400/70 mb-1.5">نام گروه</label><input type="text" name="name" required class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 text-sm" placeholder="VIP"></div><div class="flex-1"><label class="block text-xs text-red-400/70 mb-1.5">توضیحات</label><input type="text" name="description" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 text-sm" placeholder="اختیاری"></div><button type="submit" class="px-6 py-3 bg-gradient-to-r from-red-700 to-red-900 text-red-100 text-sm font-bold rounded-xl">ایجاد</button></form></div><div class="glass rounded-2xl p-4"><table class="w-full text-right text-sm"><thead><tr class="bg-black/50 text-red-400/70 text-xs"><th class="p-4">نام</th><th class="p-4">اعضا</th><th class="p-4 text-center">عملیات</th></tr></thead><tbody>{% for g in groups %}<tr class="hover:bg-red-900/10"><td class="p-4 font-bold text-red-400">{{ g.name }}</td><td class="p-4"><span class="px-3 py-1 bg-red-900/20 text-red-400 rounded-lg text-xs">{{ g.member_count }}</span></td><td class="p-4 text-center"><div class="inline-flex gap-1.5"><a href="/group_members/{{ g.id }}" class="p-2 bg-blue-900/20 text-blue-400 rounded-xl text-xs"><i class="fa-solid fa-users"></i></a><form action="/delete_group/{{ g.id }}" method="POST" class="inline"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><button type="submit" onclick="return confirm('حذف؟')" class="p-2 bg-red-900/30 text-red-400 rounded-xl text-xs"><i class="fa-solid fa-trash"></i></button></form></div></td></tr>{% endfor %}</tbody></table></div></main></body></html>
EOF

cat << 'EOF' > /root/ssh-panel/templates/group_members.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>اعضای {{ group.name }} | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);backdrop-filter:blur(20px);border:1px solid rgba(255,0,0,0.15)}</style></head><body class="min-h-screen"><nav class="glass sticky top-0 z-50 px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex items-center justify-between"><div class="flex items-center gap-3"><div class="w-10 h-10 bg-gradient-to-br from-red-700 to-red-900 rounded-xl flex items-center justify-center border border-red-500/30"><span class="text-lg font-black text-red-100">OP</span></div><h1 class="text-lg font-bold text-red-400">اعضای {{ group.name }}</h1></div><a href="/groups" class="px-3 py-1.5 bg-red-900/20 text-red-400 rounded-lg text-xs border border-red-800/30">بازگشت</a></div></nav><main class="p-4 max-w-4xl mx-auto">{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, message in messages %}<div class="{% if category == 'success' %}bg-emerald-900/30 border border-emerald-700/50 text-emerald-400{% else %}bg-red-900/30 border border-red-700/50 text-red-400{% endif %} p-4 rounded-2xl text-sm mb-4">{{ message }}</div>{% endfor %}{% endif %}{% endwith %}{% if available_users %}<div class="glass rounded-2xl p-4 mb-4"><form action="/add_group_members/{{ group.id }}" method="POST"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><div class="grid grid-cols-2 md:grid-cols-4 gap-2 mb-3 max-h-40 overflow-y-auto">{% for uname in available_users %}<label class="flex items-center gap-2 bg-black border border-red-900/30 p-2 rounded-xl cursor-pointer"><input type="checkbox" name="usernames" value="{{ uname }}" class="text-red-600 rounded"><span class="text-xs text-red-300">{{ uname }}</span></label>{% endfor %}</div><button type="submit" class="px-4 py-2 bg-gradient-to-r from-red-700 to-red-900 text-red-100 text-xs font-bold rounded-xl">افزودن</button></form></div>{% endif %}<div class="glass rounded-2xl p-4"><div class="grid grid-cols-2 md:grid-cols-4 gap-2">{% for uname in members %}<div class="flex items-center justify-between bg-black border border-red-900/30 p-3 rounded-xl"><span class="text-sm text-red-300">{{ uname }}</span><form action="/remove_group_member/{{ group.id }}/{{ uname }}" method="POST" class="inline"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><button type="submit" class="p-1.5 bg-red-900/30 text-red-400 rounded-lg text-xs"><i class="fa-solid fa-xmark"></i></button></form></div>{% endfor %}</div></div></main></body></html>
EOF

cat << 'EOF' > /root/ssh-panel/templates/reports.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>گزارشات | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);backdrop-filter:blur(20px);border:1px solid rgba(255,0,0,0.15)}.stat-card{transition:all 0.3s}.stat-card:hover{transform:translateY(-3px);box-shadow:0 10px 40px rgba(220,38,38,0.2)}</style></head><body class="min-h-screen"><nav class="glass sticky top-0 z-50 px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex justify-between items-center"><div class="flex items-center gap-3"><div class="w-10 h-10 bg-gradient-to-br from-red-700 to-red-900 rounded-xl flex items-center justify-center border border-red-500/30"><span class="text-lg font-black text-red-100">OP</span></div><h1 class="text-lg font-bold text-red-400">گزارشات</h1></div><a href="/dashboard" class="px-4 py-2 bg-red-900/20 text-red-400 rounded-xl text-sm border border-red-800/30">داشبورد</a></div></nav><main class="p-4 max-w-5xl mx-auto"><div class="grid grid-cols-2 md:grid-cols-4 gap-3"><div class="glass stat-card rounded-2xl p-4 text-center"><i class="fa-solid fa-users text-2xl text-red-500 mb-2"></i><span class="block text-[10px] text-red-400/50">کل کاربران</span><span class="text-xl font-black text-red-400">{{ summary.total_users }}</span></div><div class="glass stat-card rounded-2xl p-4 text-center"><i class="fa-solid fa-hard-drive text-2xl text-blue-400 mb-2"></i><span class="block text-[10px] text-red-400/50">حجم کل (GB)</span><span class="text-xl font-black text-blue-400">{{ summary.total_traffic_gb }}</span></div><div class="glass stat-card rounded-2xl p-4 text-center"><i class="fa-solid fa-chart-line text-2xl text-purple-400 mb-2"></i><span class="block text-[10px] text-red-400/50">مصرف کل (GB)</span><span class="text-xl font-black text-purple-400">{{ summary.used_traffic_gb }}</span></div><div class="glass stat-card rounded-2xl p-4 text-center"><i class="fa-solid fa-server text-2xl text-emerald-400 mb-2"></i><span class="block text-[10px] text-red-400/50">اینباند/کلاینت</span><span class="text-xl font-black text-emerald-400">{{ ib_count }}/{{ cl_count }}</span></div></div></main></body></html>
EOF

cat << 'EOF' > /root/ssh-panel/templates/sub.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>اشتراک {{ username }}</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif;margin:0;padding:0;box-sizing:border-box}body{background:#0a0a0a;color:#fff;min-height:100vh}.card{background:rgba(20,0,0,0.6);border:1px solid rgba(220,38,38,0.15);border-radius:16px}.qr-img{border-radius:12px;cursor:pointer;background:#fff;padding:8px}.btn{transition:all 0.2s;cursor:pointer}.btn:hover{transform:translateY(-1px)}.copied-toast{position:fixed;top:20px;left:50%;transform:translateX(-50%);background:#10b981;color:#fff;padding:10px 24px;border-radius:50px;font-size:13px;z-index:999;animation:fadeInOut 2s ease}@keyframes fadeInOut{0%{opacity:0;top:0}20%{opacity:1;top:20px}80%{opacity:1;top:20px}100%{opacity:0;top:0}}</style></head><body class="p-4 md:p-8"><div class="max-w-3xl mx-auto"><div class="text-center mb-8"><div class="w-16 h-16 mx-auto bg-gradient-to-br from-red-700 to-red-900 rounded-2xl flex items-center justify-center mb-3"><span class="text-2xl font-black text-red-100">OP</span></div><h1 class="text-xl font-bold text-red-400">{{ username }}</h1><div class="flex justify-center gap-3 mt-2 text-xs"><span class="text-red-400/60">{{ expire_date }}</span><span>•</span><span class="{% if status == '1' %}text-emerald-400{% else %}text-red-400{% endif %}">{% if status == '1' %}فعال{% else %}غیرفعال{% endif %}</span><span>•</span><span>{{ days_left }} روز</span></div><div class="mt-4 p-4 bg-black/50 rounded-2xl"><div class="grid grid-cols-3 gap-4 text-center"><div><p class="text-[10px] text-red-400/50 mb-1">حجم کل</p><p class="text-lg font-bold text-blue-400">{{ total_traffic }} GB</p></div><div><p class="text-[10px] text-red-400/50 mb-1">مصرف شده</p><p class="text-lg font-bold text-amber-400">{{ used_traffic }} GB</p></div><div><p class="text-[10px] text-red-400/50 mb-1">باقیمانده</p><p class="text-lg font-bold {% if remaining_traffic|float > 5 %}text-emerald-400{% else %}text-red-400{% endif %}">{{ remaining_traffic }} GB</p></div></div><div class="w-full bg-red-900/20 h-2 rounded-full mt-3 overflow-hidden"><div class="h-full bg-gradient-to-r from-red-600 to-red-400 rounded-full" style="width:{{ progress_percent }}%"></div></div><p class="text-[10px] text-red-400/40 mt-1">{{ progress_percent }}% مصرف شده</p></div></div><div class="card p-4 mb-3"><div class="flex items-center gap-2 mb-3"><i class="fa-solid fa-terminal text-emerald-400 text-sm"></i><span class="text-xs font-bold text-emerald-400">SSH</span></div><div class="flex items-center gap-4"><div class="flex-1 bg-black/50 rounded-xl p-3 font-mono text-xs text-emerald-300 break-all cursor-pointer hover:bg-black/80 transition" dir="ltr" onclick="copyText('{{ ssh_uri }}')">{{ ssh_uri }}</div>{% if ssh_qr %}<img src="data:image/png;base64,{{ ssh_qr }}" class="qr-img w-16 h-16" onclick="openQR('{{ ssh_qr }}')">{% endif %}</div></div>{% for config in xray_configs %}<div class="card p-4 mb-3"><div class="flex items-center gap-2 mb-3"><span class="text-xs font-bold px-2 py-0.5 rounded-full {% if config.protocol=='vless' %}bg-blue-900/30 text-blue-400{% elif config.protocol=='vmess' %}bg-purple-900/30 text-purple-400{% else %}bg-amber-900/30 text-amber-400{% endif %}">{{ config.protocol|upper }}</span><span class="text-[10px] text-gray-500">{{ config.tag }}:{{ config.port }}</span></div><div class="flex items-start gap-4"><div class="flex-1 min-w-0"><div class="bg-black/50 rounded-xl p-3 font-mono text-xs text-gray-300 break-all cursor-pointer hover:bg-black/80 transition" dir="ltr" onclick="copyText('{{ config.link }}')">{{ config.link }}</div><div class="flex gap-2 mt-2"><a href="{{ config.nepster_link }}" class="btn inline-flex items-center gap-1 px-3 py-1.5 bg-red-900/20 text-red-400 text-[10px] rounded-lg"><i class="fa-solid fa-download"></i> Nepster</a><a href="{{ config.netmod_link }}" class="btn inline-flex items-center gap-1 px-3 py-1.5 bg-red-900/20 text-red-400 text-[10px] rounded-lg"><i class="fa-solid fa-download"></i> NetMod</a></div></div>{% if config.qr_code %}<img src="data:image/png;base64,{{ config.qr_code }}" class="qr-img w-20 h-20" onclick="openQR('{{ config.qr_code }}')">{% endif %}</div></div>{% endfor %}</div><div id="qrModal" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,0.9);z-index:100;align-items:center;justify-content:center" onclick="this.style.display='none'"><div onclick="event.stopPropagation()" style="background:#fff;border-radius:20px;padding:20px;max-width:320px"><img id="qrModalImg" src="" style="width:100%;border-radius:12px"></div></div><script>function copyText(text){try{navigator.clipboard.writeText(text).then(()=>{showToast()})}catch(e){var tmp=document.createElement('textarea');tmp.value=text;tmp.style.position='fixed';tmp.style.opacity='0';document.body.appendChild(tmp);tmp.select();document.execCommand('copy');document.body.removeChild(tmp);showToast()}}function showToast(){var t=document.createElement('div');t.className='copied-toast';t.innerHTML='✓ کپی شد!';document.body.appendChild(t);setTimeout(()=>t.remove(),2000)}function openQR(e){document.getElementById('qrModalImg').src='data:image/png;base64,'+e;document.getElementById('qrModal').style.display='flex'}</script></body></html>
EOF

cat << 'EOF' > /root/ssh-panel/templates/sub_error.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>خطا</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#0a0a0a}.card{background:rgba(20,0,0,0.8);border:1px solid rgba(255,0,0,0.15);border-radius:20px}</style></head><body class="min-h-screen flex items-center justify-center p-4"><div class="card p-8 max-w-md w-full text-center"><div class="w-16 h-16 mx-auto bg-red-900/30 rounded-2xl flex items-center justify-center mb-4"><i class="fa-solid fa-triangle-exclamation text-3xl text-red-500"></i></div><h1 class="text-lg font-bold text-red-400 mb-2">خطا</h1><p class="text-gray-400 text-sm mb-6">{{ error_message }}</p><a href="/" class="inline-flex items-center gap-2 px-5 py-2 bg-gradient-to-r from-red-700 to-red-900 text-red-100 text-sm rounded-xl">بازگشت</a></div></body></html>
EOF

cat << 'EOF' > /root/ssh-panel/templates/settings.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>تنظیمات | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);border:1px solid rgba(255,0,0,0.15)}.btn{transition:all 0.2s;cursor:pointer}.btn:hover{transform:translateY(-1px)}</style></head><body class="min-h-screen"><nav class="glass sticky top-0 z-50 px-6 py-3 border-b border-red-900/30"><div class="max-w-4xl mx-auto flex justify-between items-center"><h1 class="text-lg font-bold text-red-400 flex items-center gap-2">⚙️ تنظیمات و پشتیبان‌گیری</h1><a href="/dashboard" class="px-4 py-2 bg-red-900/20 text-red-400 rounded-xl text-sm border border-red-800/30">🔙 بازگشت</a></div></nav><main class="max-w-4xl mx-auto p-6 space-y-6">{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, msg in messages %}<div class="p-4 rounded-xl text-center font-bold border text-sm {% if category == 'success' %}bg-emerald-900/40 text-emerald-400 border-emerald-800 {% elif category == 'info' %}bg-blue-900/40 text-blue-400 border-blue-800{% else %}bg-red-900/40 text-red-400 border-red-900{% endif %}">{{ msg }}</div>{% endfor %}{% endif %}{% endwith %}<div class="glass rounded-2xl p-6"><h2 class="text-lg font-bold text-red-400 mb-4">💾 پشتیبان‌گیری و بازیابی</h2><div class="grid grid-cols-1 md:grid-cols-2 gap-6"><div class="bg-black/50 border border-red-900/30 p-5 rounded-xl flex flex-col justify-between"><div><h3 class="text-sm font-bold text-red-500 mb-2">دانلود بکاپ</h3><p class="text-xs text-gray-500">دانلود فایل کامل دیتابیس</p></div><a href="/backup_download" class="btn w-full bg-red-700 hover:bg-red-600 text-white font-bold py-2.5 rounded-xl text-center mt-4 block">📥 دانلود فایل بکاپ</a></div><div class="bg-black/50 border border-red-900/30 p-5 rounded-xl flex flex-col justify-between"><div><h3 class="text-sm font-bold text-amber-500 mb-2">بازیابی بکاپ</h3><p class="text-xs text-gray-500">آپلود فایل بکاپ و جایگزینی</p></div><form action="/backup_upload" method="POST" enctype="multipart/form-data" class="mt-4 space-y-3"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><input type="file" name="backup_file" accept=".db" required class="w-full text-xs text-gray-400 bg-black p-2 rounded-lg border border-red-900/30"><button type="submit" class="btn w-full bg-amber-600 hover:bg-amber-500 text-black font-bold py-2.5 rounded-xl text-center">📤 آپلود و بازیابی</button></form></div></div></div><div class="glass rounded-2xl p-6"><h2 class="text-lg font-bold text-red-400 mb-4">⚙️ تنظیمات پنل</h2><form action="/settings" method="POST" class="space-y-4"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><input type="hidden" name="action" value="save_settings"><div class="grid grid-cols-2 gap-4"><div><label class="block text-xs text-red-400/70 mb-1.5">دامنه</label><input type="text" name="domain" value="{{ domain }}" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 font-mono text-sm" dir="ltr"></div><div><label class="block text-xs text-red-400/70 mb-1.5">پورت پنل</label><input type="number" name="panel_port" value="{{ panel_port }}" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 text-sm"></div></div><div class="grid grid-cols-2 gap-4"><div><label class="block text-xs text-red-400/70 mb-1.5">نام کاربری ادمین</label><input type="text" name="admin_username" value="{{ admin_username }}" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 font-mono text-sm" dir="ltr"></div><div><label class="block text-xs text-red-400/70 mb-1.5">رمز جدید</label><input type="password" name="admin_password" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 text-sm" placeholder="خالی = بدون تغییر"></div></div><div class="grid grid-cols-1 md:grid-cols-3 gap-4"><div><label class="block text-xs text-red-400/70 mb-1.5">دامنه TLS</label><input type="text" name="ssl_domain" value="{{ ssl_domain }}" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 font-mono text-sm" dir="ltr" placeholder="example.com"></div><div><label class="block text-xs text-red-400/70 mb-1.5">Certificate path</label><input type="text" name="tls_cert_file" value="{{ tls_cert_file }}" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 font-mono text-xs" dir="ltr" placeholder="/etc/letsencrypt/live/example.com/fullchain.pem"></div><div><label class="block text-xs text-red-400/70 mb-1.5">Private key path</label><input type="text" name="tls_key_file" value="{{ tls_key_file }}" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 font-mono text-xs" dir="ltr" placeholder="/etc/letsencrypt/live/example.com/privkey.pem"></div></div><div class="flex items-center gap-3 mt-2"><input type="checkbox" name="block_iran" id="block_iran" class="text-red-600 rounded" {% if block_iran_client == '1' %}checked{% endif %}><label for="block_iran" class="text-xs text-red-300">بلاک ترافیک خروجی سرور به IPهای ایران</label></div><button type="submit" class="btn w-full bg-red-700 hover:bg-red-600 text-white font-bold py-3 rounded-xl">💾 ذخیره تنظیمات</button></form></div><div class="glass rounded-2xl p-6"><h2 class="text-lg font-bold text-red-400 mb-4">🔐 کلیدهای Reality</h2><form action="/settings" method="POST" class="mb-4"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><input type="hidden" name="action" value="generate_keys"><button type="submit" class="btn px-4 py-2 bg-red-900/30 text-red-400 border border-red-800/50 rounded-xl text-sm font-bold">🎲 تولید کلید جدید</button></form><div class="space-y-2"><input type="text" value="{{ reality_public_key }}" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-500 font-mono text-xs" dir="ltr" readonly><input type="text" value="{{ reality_private_key }}" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-500 font-mono text-xs" dir="ltr" readonly></div></div></main></body></html>
EOF

echo "✓ All HTML templates created"

# ============================================
# STEP 15-16: Services & Start
# ============================================
echo "[15/16] Creating services..."

cat << 'EOF' > /etc/systemd/system/ssh-panel.service
[Unit]
Description=OutlineParsian Panel
After=network.target xray.service
[Service]
Type=simple
User=root
WorkingDirectory=/root/ssh-panel
ExecStart=/root/ssh-panel/venv/bin/python /root/ssh-panel/app.py
Restart=always
RestartSec=3
TimeoutStartSec=30
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > /etc/systemd/system/ssh-panel-worker.service
[Unit]
Description=OutlineParsian Worker
After=network.target xray.service ssh-panel.service
[Service]
Type=simple
User=root
WorkingDirectory=/root/ssh-panel
ExecStart=/root/ssh-panel/venv/bin/python /root/ssh-panel/traffic_worker.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

PANEL_PORT=$(sqlite3 /root/ssh-panel/panel.db "SELECT value FROM settings WHERE key='panel_port';" 2>/dev/null)
[ -z "$PANEL_PORT" ] && PANEL_PORT=5000
cat << 'EOF' > /etc/nginx/sites-available/panel
server {listen 80;server_name _;client_max_body_size 100M;location / {proxy_pass http://127.0.0.1:__PANEL_PORT__;proxy_http_version 1.1;proxy_set_header Upgrade $http_upgrade;proxy_set_header Connection 'upgrade';proxy_set_header Host $host;proxy_set_header X-Real-IP $remote_addr;proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;proxy_set_header X-Forwarded-Proto $scheme;proxy_cache_bypass $http_upgrade;}}
EOF
sed -i "s/__PANEL_PORT__/${PANEL_PORT}/g" /etc/nginx/sites-available/panel
ln -sf /etc/nginx/sites-available/panel /etc/nginx/sites-enabled/ 2>/dev/null
rm -f /etc/nginx/sites-enabled/default 2>/dev/null

echo "[16/16] Preflight validation and service startup..."
systemctl daemon-reload
systemctl enable xray ssh-panel ssh-panel-worker ssh-connection-limiter nginx iran-block.service 2>/dev/null
nginx -t || { echo "❌ Nginx validation failed"; exit 1; }
/root/ssh-panel/venv/bin/python -c "import sys;sys.path.insert(0,'/root/ssh-panel');import app;app.ensure_schema();app.generate_xray_config()" || { echo "❌ Xray config preflight failed"; exit 1; }

for svc in xray ssh-panel ssh-panel-worker ssh-connection-limiter nginx iran-block.service; do
    systemctl restart "$svc" || { echo "❌ Failed to start $svc"; journalctl -u "$svc" -n 30 --no-pager 2>/dev/null || true; exit 1; }
done
sleep 2
FAILED=0
for svc in xray ssh-panel ssh-panel-worker ssh-connection-limiter nginx ssh cron; do
    if ! systemctl is-active --quiet "$svc"; then
        echo "❌ Health check failed: $svc"
        journalctl -u "$svc" -n 30 --no-pager 2>/dev/null || true
        FAILED=1
    fi
done
[ "$FAILED" -eq 0 ] || exit 1

echo "✓ All core services are active"
IP=$(curl -fsS --connect-timeout 3 --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║                                                      ║"
echo "║   ✅ OutlineParsian Ultimate Panel                   ║"
echo "║   Installation Complete!                             ║"
echo "║                                                      ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  🌐 Panel:  http://${IP}/                 ║"
if [ -f /tmp/outlineparsian_new_admin ]; then
  ADMIN_INIT_PASS=$(cat /tmp/outlineparsian_new_admin)
  echo "║  👤 User: admin | Initial password generated         ║"
else
  ADMIN_INIT_PASS=""
  echo "║  👤 Existing admin credentials preserved             ║"
fi
echo "╠══════════════════════════════════════════════════════╣"
echo "║  ✅ LIVE System Stats (CPU/RAM every 2s)             ║"
echo "║  ✅ Connection Limiter (lightweight SSH session control)              ║"
echo "║  ✅ Backup/Restore (Mask/Unmask – Reliable)           ║"
echo "║  ✅ Accurate SSH Traffic Counting (persistent socket deltas)          ║"
echo "║  ✅ Xray VLESS / VMess / Trojan config validation     ║"
echo "║  ✅ Iran Outbound Block (inbound NOT affected)        ║"
echo "║  ✅ Auto User Sync + SSH Config                       ║"
echo "║  ✅ Sub Page + Copy + QR + Downloads                  ║"
echo "║  ✅ Auto-Restart on Crash (3s recovery)               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  🚀 Panel is ready!"
if [ -n "${ADMIN_INIT_PASS}" ]; then
  echo "  🔑 Initial admin password: ${ADMIN_INIT_PASS}"
  echo "  📁 Saved securely at: /root/ssh-panel/initial_admin_credentials.txt"
  rm -f /tmp/outlineparsian_new_admin
fi
echo ""