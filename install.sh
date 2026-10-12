#!/bin/bash
set -euo pipefail
if [ "${1:-}" = --check ]; then
    bash -n "$0"
    python3 - "$0" <<'OP_CHECK_PY'
import ast, pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
count = 0
for match in re.finditer(r"^cat << '([^']+)' > (\S+)\n(.*?)^\1$", source, re.M | re.S):
    if match.group(2).strip('"').endswith('.py'):
        ast.parse(match.group(3), filename=match.group(2))
        count += 1
print('Shell syntax and %d embedded Python modules OK' % count)
OP_CHECK_PY
    exit 0
fi
if [ "$EUID" -ne 0 ]; then echo "Run with sudo bash $0"; exit 1; fi
if [ -f /root/ssh-panel/panel.db ]; then
    echo "Existing panel detected. Run update-v3.7.sh; users and UI will be preserved."
    exit 2
fi
# ============================================
# OutlineParsian Ultimate Panel v3.7
# v3.7 Backend Repair | CPU + Online status | Original templates preserved
# SSH + Xray Traffic | Accurate Online | IP-Based Limiter
# ============================================

clear 2>/dev/null || true
cat << "BANNER"
   ____  _    _ _   _     _     ___  ____   ____   _    ____ ____  _    ____ _   _ 
  / __ \|  |  | \ | |   | |   / _ \|  _ \ / ___| | |  / ___| _ \/ \  / ___| \ | |
 | |  | | |  | |  \| |   | | | | | | |_) | |     | | | |   | |_) / _ \ \___ \  \| |
 | |  | | |  | | . ` |   | |  | | | |  __/| |___  | | | |___|  _ < ___ \ ___) | |\  |
 | |__| | |__| | |\  |   | |__| |_| | |    \____| | |  \____|_| \_\   \_\____/|_| \_|
  \____/ \____/|_| \_| |_____\___/|_|          |_|
  
  OutlineParsian Ultimate Panel v3.7
BANNER

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   OutlineParsian Ultimate Panel v3.7                 ║"
echo "║   Backend: CPU and Online Status Repair              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ============================================
# STEP 1: System Update & Prerequisites
# ============================================
echo "[1/16] Updating system and installing prerequisites..."
apt update -y
apt install -y iproute2 logrotate python3 python3-pip python3-venv nginx ipset iptables curl netfilter-persistent iptables-persistent unzip wget sqlite3 net-tools jq certbot python3-certbot-nginx python3-psutil python3-flask python3-requests qrencode openssh-server 2>/dev/null
pip3 install flask psutil requests grpcio grpcio-tools protobuf qrcode[pil] --break-system-packages 2>/dev/null || pip3 install flask psutil requests grpcio grpcio-tools protobuf qrcode[pil] 2>/dev/null
echo "✓ Prerequisites installed"

# ============================================
# STEP 2: SSH Configuration
# ============================================
echo "[2/16] Configuring SSH..."
cat << 'EOF' > /etc/ssh/sshd_config
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
EOF
systemctl enable ssh
systemctl restart ssh
iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null
echo "✓ SSH configured"

# ============================================
# STEP 3: Directory Structure
# ============================================
echo "[3/16] Creating directory structure..."
mkdir -p /root/ssh-panel/templates /root/ssh-panel/static /root/ssh-panel/downloads /root/ssh-panel/backups /root/ssh-panel/grpc_proto /usr/local/etc/xray /var/log/xray
touch /tmp/xray_access.log /tmp/xray_error.log /var/log/panel.log
chmod 666 /tmp/xray_access.log /tmp/xray_error.log /var/log/panel.log
echo "✓ Directories created"

# ============================================
# STEP 4: Install Xray Core + gRPC
# ============================================
echo "[4/16] Installing Xray Core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
pip3 install grpcio grpcio-tools protobuf --break-system-packages 2>/dev/null || pip3 install grpcio grpcio-tools protobuf 2>/dev/null

cat << 'PROTOEOF' > /root/ssh-panel/grpc_proto/stats.proto
syntax = "proto3";
package xray.app.stats.command;
message QueryStatsRequest { string pattern = 1; bool reset = 2; }
message Stat { string name = 1; int64 value = 2; }
message QueryStatsResponse { repeated Stat stat = 1; }
message GetStatsRequest { string name = 1; bool reset = 2; }
message GetStatsOnlineIpListResponse { string name = 1; map<string, int64> ips = 2; }
message GetAllOnlineUsersRequest {}
message GetAllOnlineUsersResponse { repeated string users = 1; }
message OnlineIPEntry { string ip = 1; int64 last_seen = 2; }
message TrafficUserStat { int64 uplink = 1; int64 downlink = 2; }
message UserStat { string email = 1; repeated OnlineIPEntry ips = 2; TrafficUserStat traffic = 3; }
message GetUsersStatsRequest { bool include_traffic = 1; bool reset = 2; }
message GetUsersStatsResponse { repeated UserStat users = 1; }
service StatsService {
  rpc QueryStats(QueryStatsRequest) returns (QueryStatsResponse);
  rpc GetUsersStats(GetUsersStatsRequest) returns (GetUsersStatsResponse);
  rpc GetAllOnlineUsers(GetAllOnlineUsersRequest) returns (GetAllOnlineUsersResponse);
  rpc GetStatsOnlineIpList(GetStatsRequest) returns (GetStatsOnlineIpListResponse);
}
PROTOEOF

python3 -m grpc_tools.protoc -I/root/ssh-panel/grpc_proto --python_out=/root/ssh-panel/grpc_proto --grpc_python_out=/root/ssh-panel/grpc_proto /root/ssh-panel/grpc_proto/stats.proto
echo "✓ Xray Core + gRPC installed"

# ============================================
# STEP 5: Initialize Database
# ============================================
echo "[5/16] Initializing database..."
python3 << 'PYEOF'
import sqlite3, os
DB_PATH = "/root/ssh-panel/panel.db"
if os.path.exists(DB_PATH): raise SystemExit('Existing database: use update-v3.7.sh')
conn = sqlite3.connect(DB_PATH)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("PRAGMA foreign_keys=ON")
c = conn.cursor()
c.execute('''CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, password TEXT, expire_date TEXT, total_traffic REAL, used_traffic REAL DEFAULT 0.0, status INTEGER DEFAULT 1, max_connections INTEGER DEFAULT 2, created_at TEXT)''')
c.execute('''CREATE TABLE IF NOT EXISTS xray_inbounds (id INTEGER PRIMARY KEY AUTOINCREMENT, tag TEXT UNIQUE, protocol TEXT, port INTEGER, network TEXT DEFAULT 'tcp', security TEXT DEFAULT 'none', server_name TEXT DEFAULT '', fingerprint TEXT DEFAULT 'chrome', short_id TEXT DEFAULT '', public_key TEXT DEFAULT '', private_key TEXT DEFAULT '', path TEXT DEFAULT '/', status INTEGER DEFAULT 1, created_at TEXT)''')
c.execute('''CREATE TABLE IF NOT EXISTS xray_clients (id INTEGER PRIMARY KEY AUTOINCREMENT, inbound_id INTEGER, username TEXT, uuid TEXT, email TEXT, enable INTEGER DEFAULT 1, created_at TEXT, FOREIGN KEY (inbound_id) REFERENCES xray_inbounds(id) ON DELETE CASCADE, FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE)''')
c.execute('''CREATE TABLE IF NOT EXISTS user_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, description TEXT, created_at TEXT)''')
c.execute('''CREATE TABLE IF NOT EXISTS group_members (id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER, username TEXT, FOREIGN KEY (group_id) REFERENCES user_groups(id) ON DELETE CASCADE, FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE)''')
c.execute('''CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)''')
defaults = [('domain',''),('admin_username','admin'),('admin_password','admin123'),('block_iran_client','0'),('panel_port','5000'),('reality_public_key',''),('reality_private_key',''),('ssl_domain',''),('ssl_status','none')]
for k,v in defaults: c.execute("INSERT OR IGNORE INTO settings (key,value) VALUES (?,?)",(k,v))
c.execute("CREATE INDEX IF NOT EXISTS idx_clients_inbound ON xray_clients(inbound_id)")
c.execute("CREATE INDEX IF NOT EXISTS idx_clients_username ON xray_clients(username)")
conn.commit()
conn.close()
print("✓ Database initialized")
PYEOF

# ============================================
# STEP 6: Xray Config Sync Script
# ============================================
echo "[6/16] Creating Xray Sync Script..."
cat << 'EOF' > /root/ssh-panel/sync_xray.py
#!/usr/bin/env python3
import sqlite3, json, os, subprocess, fcntl, tempfile

DB_PATH = '/root/ssh-panel/panel.db'
XRAY_CONFIG = '/usr/local/etc/xray/config.json'
XRAY_BIN = '/usr/local/bin/xray'

def generate():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    c.execute("SELECT * FROM xray_inbounds WHERE status=1")
    inbounds_db = c.fetchall()
    
    inbounds_config = [{
        "tag": "api", "listen": "127.0.0.1", "port": 10085,
        "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}
    }]
    
    all_tags = []
    
    def get_setting(key):
        c.execute("SELECT value FROM settings WHERE key=?", (key,))
        row = c.fetchone()
        return row['value'] if row else ""
        
    default_pub = get_setting('reality_public_key')
    default_priv = get_setting('reality_private_key')
    
    for ib in inbounds_db:
        ib = dict(ib)
        c.execute("""SELECT cl.username, cl.uuid, cl.email 
                     FROM xray_clients cl 
                     JOIN users u ON cl.username = u.username 
                     WHERE cl.inbound_id=? AND cl.enable=1 AND u.status=1""", (ib['id'],))
        clients_data = c.fetchall()
        if not clients_data: continue
        
        inbound_entry = {"tag": ib['tag'], "port": ib['port'], "protocol": ib['protocol'], "settings": {"clients": []}, "streamSettings": {"network": ib.get('network','tcp')}}
        if ib['protocol'] == 'vless': inbound_entry["settings"]["decryption"] = "none"
        sec = ib.get('security','none')
        if sec != 'none': inbound_entry["streamSettings"]["security"] = sec
        
        for cl in clients_data:
            cl = dict(cl)
            obj = {"id": cl['uuid'], "email": cl.get('email') or cl.get('username','')}
            if sec == "reality" and ib['protocol'] == 'vless': obj["flow"] = "xtls-rprx-vision"
            inbound_entry["settings"]["clients"].append(obj)
            
        if sec == "reality":
            pk = ib.get('private_key') or default_priv
            sn = ib.get('server_name','www.microsoft.com')
            sid = ib.get('short_id','')
            fp = ib.get('fingerprint','chrome')
            inbound_entry["streamSettings"]["realitySettings"] = {"dest": f"{sn}:443", "serverNames": [sn], "privateKey": pk, "shortIds": [sid] if sid else [""], "fingerprint": fp}
        elif sec == "tls":
            sd = get_setting('ssl_domain') or ib.get('server_name','')
            inbound_entry["streamSettings"]["tlsSettings"] = {"serverName": sd}
            
        path = ib.get('path','/')
        if ib.get('network') == "ws": inbound_entry["streamSettings"]["wsSettings"] = {"path": path}
        elif ib.get('network') == "grpc": inbound_entry["streamSettings"]["grpcSettings"] = {"serviceName": path.strip('/') or "grpc"}
        
        inbounds_config.append(inbound_entry)
        all_tags.append(ib['tag'])
        
    config = {
        "log": {"loglevel":"warning", "access":"/tmp/xray_access.log", "error":"/tmp/xray_error.log"},
        "inbounds": inbounds_config,
        "outbounds": [{"protocol":"freedom","tag":"direct"}, {"protocol":"blackhole","tag":"block"}, {"protocol":"blackhole","tag":"api"}],
        "routing": {"rules": [{"type":"field", "inboundTag":["api"], "outboundTag":"api"}] + ([{"type":"field", "inboundTag":all_tags, "outboundTag":"direct"}] if all_tags else [])},
        "stats": {},
        "api": {"tag":"api","services":["StatsService"]},
        "policy": {
            "system": {
                "statsInboundUplink": False,
                "statsInboundDownlink": False,
                "statsOutboundUplink": False,
                "statsOutboundDownlink": False
            },
            "levels": {
                "0": {
                    "statsUserUplink": True,
                    "statsUserDownlink": True,
                    "statsUserOnline": True
                }
            }
        }
    }
    conn.close()
    try:
        with open(XRAY_CONFIG) as f:
            if json.load(f) == config:
                return False
    except (OSError, ValueError):
        pass
    fd, temporary = tempfile.mkstemp(prefix='.config-', suffix='.json', dir=os.path.dirname(XRAY_CONFIG))
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(config, f, indent=2)
        os.chmod(temporary, 0o644)
        subprocess.run([XRAY_BIN, 'run', '-test', '-config', temporary], check=True, timeout=15)
        os.replace(temporary, XRAY_CONFIG)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def synchronize():
    # Concurrent panel requests and quota checks cannot race config/restarts.
    with open('/root/ssh-panel/sync_xray.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        pending = '/root/ssh-panel/.xray_restart_pending'
        changed = generate()
        if changed or os.path.exists(pending):
            open(pending, 'a').close()
            subprocess.run(['systemctl', 'restart', 'xray'], check=True, timeout=15)
            os.unlink(pending)

if __name__ == '__main__':
    synchronize()
EOF
chmod +x /root/ssh-panel/sync_xray.py
echo "✓ Xray Sync Script created"

# ============================================
# STEP 7: Main Panel Application (app.py)
# ============================================
echo "[7/16] Creating panel application..."

cat << 'APPEOF' > /root/ssh-panel/app.py
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys, sqlite3, subprocess, time, json, uuid, base64, io, traceback, random, shutil, threading
from datetime import datetime, timedelta
try:
    import psutil
    HAS_PSUTIL = True
except:
    HAS_PSUTIL = False
from flask import Flask, render_template_string, request, redirect, url_for, session, send_file, flash, Response, jsonify
import logging
import hashlib, pwd
from logging.handlers import RotatingFileHandler
from telemetry import SnapshotReader, online_view, atomic_json

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s',
                   handlers=[RotatingFileHandler('/var/log/panel.log', maxBytes=5*1024*1024, backupCount=3), logging.StreamHandler()])
logger = logging.getLogger('OP')

app = Flask(__name__)
app.secret_key = os.urandom(24).hex()

DB_PATH = '/root/ssh-panel/panel.db'
XRAY_CONFIG = '/usr/local/etc/xray/config.json'
XRAY_BIN = '/usr/local/bin/xray'
DOWNLOADS_DIR = '/root/ssh-panel/downloads'
ONLINE_FILE = '/tmp/online_users.json'
online_reader = SnapshotReader(ONLINE_FILE)
online_reader_lock = threading.Lock()
PASSWORD_SYNC_FILE = '/root/ssh-panel/.password_sync.json'
password_sync_lock = threading.Lock()

def password_fingerprint(password):
    return hashlib.sha256(password.encode('utf-8')).hexdigest()

def password_sync_state():
    try:
        with open(PASSWORD_SYNC_FILE) as stream:
            value = json.load(stream)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}

if not os.path.exists(DOWNLOADS_DIR):
    os.makedirs(DOWNLOADS_DIR)

system_stats = {'cpu': 0, 'ram': 0, 'last_update': 0}

def update_system_stats():
    global system_stats
    while True:
        try:
            if HAS_PSUTIL:
                cpu = psutil.cpu_percent(interval=1)
                ram = psutil.virtual_memory().percent
            else:
                cpu = 0; ram = 0
            system_stats = {'cpu': cpu, 'ram': ram, 'last_update': time.time()}
        except:
            pass
        time.sleep(2)

def get_cpu(): return system_stats.get('cpu', 0)
def get_ram(): return system_stats.get('ram', 0)

def safe_float(val, default=0):
    try: return float(val)
    except: return default

def safe_int(val, default=0):
    try: return int(val)
    except: return default

def run_command(cmd, shell=False):
    try:
        if shell: return subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        else: return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    except:
        return None

def get_random_port():
    for _ in range(50):
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
    return random.randint(10000, 65000)

def get_online_users():
    with online_reader_lock:
        return online_view(online_reader.read())

def create_system_user(username, password):
    try:
        try:
            pwd.getpwnam(username)
        except KeyError:
            subprocess.run(['useradd', '-m', '-s', '/bin/bash', username], check=True, timeout=10)
        if '\n' in username + password or '\r' in username + password:
            return False
        subprocess.run(['chpasswd'], input=username + ':' + password + '\n', text=True, check=True, timeout=5)
        with password_sync_lock:
            fingerprints = password_sync_state()
            fingerprints[username] = password_fingerprint(password)
            atomic_json(PASSWORD_SYNC_FILE, fingerprints)
        return True
    except:
        return False

def get_db():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.row_factory = sqlite3.Row
    return conn

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

def get_panel_port():
    port = get_setting('panel_port')
    return int(port) if port and port.isdigit() else 5000

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

def sync_xray():
    subprocess.run([sys.executable, "/root/ssh-panel/sync_xray.py"], check=True, timeout=40)

def gen_link(proto,uid,dom,port,net,sec,sni,fp,sid,pub,path,user):
    if proto == 'vless':
        l = f"vless://{uid}@{dom}:{port}?type={net}&security={sec}&encryption=none"
        if sec == 'reality':
            l += f"&fp={fp}&sni={sni}&pbk={pub}&flow=xtls-rprx-vision&sid={sid}"
        if net == 'ws':
            l += f"&path={path}"
        l += f"#OP-{user}"
    elif proto == 'vmess':
        cnf = {
            "v": "2", "ps": f"OP-{user}", "add": dom, "port": str(port),
            "id": uid, "aid": "0", "net": net, "type": "none", "host": "",
            "path": path if net == 'ws' else "",
            "tls": "tls" if sec in ('tls','reality') else "none"
        }
        if sec == "reality":
            cnf["security"] = "reality"; cnf["flow"] = "xtls-rprx-vision"
            cnf["sni"] = sni; cnf["fp"] = fp; cnf["pbk"] = pub; cnf["sid"] = sid
        l = f"vmess://{base64.b64encode(json.dumps(cnf).encode()).decode()}"
    elif proto == 'trojan':
        l = f"trojan://{uid}@{dom}:{port}?security={sec}&type={net}"
        if sec == 'reality':
            l += f"&sni={sni}&flow=xtls-rprx-vision"
        l += f"#OP-{user}"
    else:
        l = f"{proto}://{uid}@{dom}:{port}#OP-{user}"
    return l

def generate_nepster_config(protocol, uuid_, domain, port, network, security, sni, fp, sid, pub_key, path, username):
    config = {"config_version":"1.0","name":f"OP-{username}","type":protocol,"server":domain,"port":port,"uuid":uuid_,"network":network,"security":security,"sni":sni,"fp":fp,"sid":sid,"pbk":pub_key,"path":path,"flow":"xtls-rprx-vision" if security=="reality" else ""}
    return json.dumps(config, indent=2)

def generate_netmod_config(protocol, uuid_, domain, port, network, security, sni, fp, sid, pub_key, path, username):
    config = {"name":f"OP-{username}","type":protocol,"server":domain,"port":port,"uuid":uuid_,"network":network,"tls":security if security!="none" else "none","sni":sni,"fingerprint":fp,"shortId":sid,"publicKey":pub_key,"path":path,"flow":"xtls-rprx-vision" if security=="reality" else "none"}
    return json.dumps(config, indent=2)

def sync_users_from_db():
    conn = get_db()
    try:
        c = conn.cursor()
        c.execute("SELECT username, password FROM users WHERE username != 'root'")
        existing = {entry.pw_name for entry in pwd.getpwall()}
        fingerprints = password_sync_state()
        first_migration = not os.path.exists(PASSWORD_SYNC_FILE)
        for user in c.fetchall():
            username, password = user['username'], user['password']
            fingerprint = password_fingerprint(password)
            if username in existing and (first_migration or fingerprints.get(username) == fingerprint):
                fingerprints[username] = fingerprint
                continue
            if create_system_user(username, password):
                fingerprints[username] = fingerprint
        with password_sync_lock:
            atomic_json(PASSWORD_SYNC_FILE, fingerprints)
    except Exception as e:
        logger.error(f"Sync users error: {e}")
    finally:
        conn.close()

def apply_iran_block():
    try:
        if get_setting('block_iran_client') == '1':
            subprocess.run(['/usr/local/bin/iran-block.sh', 'enable'], timeout=30)
        else:
            subprocess.run(['/usr/local/bin/iran-block.sh', 'disable'], timeout=30)
    except Exception as e:
        logger.error(f"apply_iran_block failed: {e}")

def render_template(template_name, **kwargs):
    template_path = os.path.join('/root/ssh-panel/templates', template_name)
    if os.path.exists(template_path):
        with open(template_path, 'r', encoding='utf-8') as f:
            template_content = f.read()
        rendered = render_template_string(template_content, **kwargs)
        if template_name == 'dashboard.html':
            # Templates/CSS remain byte-for-byte unchanged; update only the
            # existing status indicators and counters in place.
            rendered = rendered.replace('</body>', '<script src="/static/online-status.js"></script></body>', 1)
        return rendered
    return render_template_string("""
    <!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><title>Error</title>
    <style>body{background:#0a0a0a;color:#fff;font-family:sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0}
    .error{background:rgba(255,0,0,0.1);border:1px solid rgba(255,0,0,0.3);padding:2rem;border-radius:1rem;text-align:center}
    a{color:#f87171;text-decoration:none}</style></head><body><div class="error">
    <h1>Template Not Found</h1><p>{{ template_name }}</p><a href="/dashboard">Back</a></div></body></html>
    """, template_name=template_name)

@app.route('/', methods=['GET','POST'])
def login():
    if request.method=='POST':
        if request.form['username']==get_setting('admin_username') and request.form['password']==get_setting('admin_password'):
            session['logged_in']=True
            return redirect(url_for('dashboard'))
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
        c.execute("SELECT COUNT(*) as t FROM users"); total_users=c.fetchone()['t']
        c.execute("SELECT COUNT(*) as t FROM users WHERE status=1"); active_users=c.fetchone()['t']
        c.execute("SELECT COUNT(*) as t FROM xray_inbounds WHERE status=1"); total_inbounds=c.fetchone()['t']
        c.execute("SELECT COUNT(*) as t FROM xray_clients WHERE enable=1"); total_clients=c.fetchone()['t']
        c.execute("SELECT COALESCE(SUM(used_traffic)/1024,0) FROM users"); total_used=round(c.fetchone()[0],2)
        c.execute("SELECT * FROM users ORDER BY created_at DESC")
        users=[]
        dom=get_setting('domain') or request.host.split(':')[0]
        pp=get_panel_port()
        online_map = get_online_users()
        for u in c.fetchall():
            u=dict(u)
            username = u['username']
            online_info = online_map.get(username, {})
            is_ssh = online_info.get('ssh', False)
            is_xray = online_info.get('xray', False)
            ssh_count = online_info.get('ssh_count', 0)
            xray_ips = online_info.get('xray_ips', 0)
            users.append({
                'username': username,'password': u['password'],
                'expire_date': u['expire_date'],
                'total_traffic': round(u['total_traffic']/1024, 2) if u['total_traffic'] else 0,
                'used_traffic': round(u['used_traffic']/1024, 2) if u['used_traffic'] else 0,
                'status': u['status'],'max_connections': u['max_connections'],
                'is_online': is_ssh or is_xray,
                'is_ssh_online': is_ssh,
                'is_xray_online': is_xray,
                'online_count': online_info.get('online_count', 0),
                'sub_link': f"http://{dom}:{pp}/sub/{username}"
            })
        conn.close()
        return render_template('dashboard.html', cpu=get_cpu(), ram=get_ram(),
                             total_users=total_users, active_users=active_users,
                             total_inbounds=total_inbounds, total_clients=total_clients,
                             total_used=total_used, users=users)
    except Exception as e:
        logger.error(f"Dashboard error: {e}\n{traceback.format_exc()}")
        return render_template('error.html', error_message=f'خطا: {str(e)}'), 500

@app.route('/api/stats')
def api_stats():
    if not session.get('logged_in'):
        return jsonify({'error': 'Unauthorized'}), 401
    return jsonify({'cpu': get_cpu(), 'ram': get_ram()})

@app.route('/api/online')
def api_online():
    if not session.get('logged_in'):
        return jsonify({'error': 'Unauthorized'}), 401
    response = jsonify(get_online_users())
    response.headers['Cache-Control'] = 'no-store'
    return response

@app.route('/add_user_page')
def add_user_page():
    if not session.get('logged_in'): return redirect(url_for('login'))
    return render_template('add_user.html')

@app.route('/add_user', methods=['POST'])
def add_user():
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        u=request.form['username']; p=request.form['password']
        ed=safe_int(request.form.get('expire_days', 30))
        tg=safe_float(request.form.get('traffic_gb', 0))*1024
        mc=safe_int(request.form.get('max_connections', 2))
        exp=(datetime.now()+timedelta(days=ed)).strftime('%Y-%m-%d %H:%M')
        create_system_user(u, p)
        conn=get_db()
        conn.cursor().execute("INSERT INTO users (username,password,expire_date,total_traffic,used_traffic,status,max_connections,created_at) VALUES (?,?,?,?,0.0,1,?,?)",
                             (u,p,exp,tg,mc,datetime.now().strftime('%Y-%m-%d %H:%M')))
        conn.commit(); conn.close()
        flash(f'✅ کاربر {u} ایجاد شد!', 'success')
    except Exception as e:
        flash(f'❌ خطا: {e}', 'error')
    return redirect(url_for('dashboard'))

@app.route('/edit_user', methods=['POST'])
def edit_user():
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        u = request.form['username']
        p = request.form['password']
        tg = safe_float(request.form.get('traffic_gb', 0)) * 1024
        mc = safe_int(request.form.get('max_connections', 2))
        s = safe_int(request.form.get('status', 1))
        exp = request.form['expire_date']

        reset_traffic = request.form.get('reset_traffic') == 'on'
        reset_expire = request.form.get('reset_expire') == 'on'
        reset_days = safe_int(request.form.get('reset_days', 30), 30)
        extend_days = safe_int(request.form.get('extend_days', 0), 0)

        final_exp = exp
        if reset_expire:
            final_exp = (datetime.now() + timedelta(days=reset_days)).strftime('%Y-%m-%d %H:%M')
        elif extend_days > 0:
            try:
                base = datetime.strptime(exp, '%Y-%m-%d %H:%M')
                final_exp = (base + timedelta(days=extend_days)).strftime('%Y-%m-%d %H:%M')
            except: pass

        create_system_user(u, p)

        if s == 0:
            subprocess.run(f"usermod -L {u} 2>/dev/null", shell=True)
            subprocess.run(f"pkill -u {u} 2>/dev/null", shell=True)
        else:
            subprocess.run(f"usermod -U {u} 2>/dev/null", shell=True)

        conn = get_db()
        c = conn.cursor()
        c.execute("""UPDATE users
                     SET password=?, total_traffic=?, max_connections=?,
                         status=?, expire_date=?
                     WHERE username=?""",
                  (p, tg, mc, s, final_exp, u))

        if reset_traffic:
            c.execute("UPDATE users SET used_traffic=0 WHERE username=?", (u,))

        conn.commit()
        conn.close()
        sync_xray()

        msgs = [f'✅ کاربر {u} بروز شد!']
        if reset_traffic: msgs.append('♻️ مصرف صفر شد')
        if reset_expire: msgs.append(f'📅 تاریخ به {reset_days} روز آینده ریست شد')
        elif extend_days > 0: msgs.append(f'➕ {extend_days} روز به تاریخ اضافه شد')
        flash(' · '.join(msgs), 'success')
    except Exception as e:
        flash(f'❌ خطا: {e}', 'error')
    return redirect(url_for('dashboard'))

@app.route('/delete_user/<username>')
def delete_user(username):
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        subprocess.run(["userdel","-r",username], timeout=10)
    except: pass
    conn=get_db()
    conn.cursor().execute("DELETE FROM users WHERE username=?",(username,))
    conn.commit(); conn.close()
    sync_xray()
    flash(f'✅ {username} حذف شد!', 'success')
    return redirect(url_for('dashboard'))

@app.route('/inbounds')
def inbounds_page():
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn=get_db(); c=conn.cursor()
        c.execute("SELECT * FROM xray_inbounds ORDER BY id DESC")
        inbounds=[]
        for ib in c.fetchall():
            ib=dict(ib)
            c.execute("SELECT COUNT(*) as cnt FROM xray_clients WHERE inbound_id=?",(ib['id'],))
            ib['client_count']=c.fetchone()['cnt']
            inbounds.append(ib)
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
        tag=request.form['tag']; proto=request.form.get('protocol','vless')
        port=int(request.form.get('port', get_random_port()))
        net=request.form.get('network','tcp'); sec=request.form.get('security','none')
        sni=request.form.get('server_name','www.microsoft.com')
        fp=request.form.get('fingerprint','chrome')
        sid=request.form.get('short_id',''); path=request.form.get('path','/')
        
        conn=get_db()
        c = conn.cursor()
        c.execute("SELECT COUNT(*) FROM xray_inbounds WHERE tag=?", (tag,))
        if c.fetchone()[0] > 0:
            conn.close()
            flash('❌ این نام (Tag) قبلاً استفاده شده است.', 'error')
            return redirect(url_for('add_inbound_page'))
            
        c.execute("SELECT COUNT(*) FROM xray_inbounds WHERE port=?", (port,))
        if c.fetchone()[0] > 0:
            conn.close()
            flash('❌ این پورت قبلاً استفاده شده است.', 'error')
            return redirect(url_for('add_inbound_page'))
            
        pub=get_setting('reality_public_key') if sec=='reality' else ''
        priv=get_setting('reality_private_key') if sec=='reality' else ''
        
        if sec == 'reality' and (not pub or not priv):
            try:
                result=run_command([XRAY_BIN,'x25519'])
                if result:
                    output=result.stdout.decode()+'\n'+result.stderr.decode()
                    for line in output.split('\n'):
                        line=line.strip()
                        if 'private' in line.lower() and ':' in line: priv=line.split(':',1)[1].strip()
                        if 'public' in line.lower() and ':' in line: pub=line.split(':',1)[1].strip()
                    if pub and priv:
                        set_setting('reality_public_key', pub)
                        set_setting('reality_private_key', priv)
                    else:
                        conn.close()
                        flash('❌ ساخت کلیدهای Reality ناموفق بود.', 'error')
                        return redirect(url_for('add_inbound_page'))
            except:
                conn.close()
                flash('❌ خطا در تولید کلیدهای Reality.', 'error')
                return redirect(url_for('add_inbound_page'))

        c.execute("INSERT INTO xray_inbounds (tag,protocol,port,network,security,server_name,fingerprint,short_id,public_key,private_key,path,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                             (tag,proto,port,net,sec,sni,fp,sid,pub,priv,path,datetime.now().strftime('%Y-%m-%d %H:%M')))
        conn.commit(); conn.close()
        sync_xray()
        flash(f'✅ اینباند {tag}:{port} ایجاد شد!', 'success')
    except Exception as e: 
        flash(f'❌ خطا: {e}', 'error')
    return redirect(url_for('inbounds_page'))

@app.route('/delete_inbound/<int:ib_id>')
def delete_inbound(ib_id):
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn=get_db()
        conn.cursor().execute("DELETE FROM xray_inbounds WHERE id=?",(ib_id,))
        conn.commit(); conn.close()
        sync_xray()
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
        sync_xray()
        flash('✅ اضافه شدند!', 'success')
    except Exception as e: flash(f'❌ خطا: {e}', 'error')
    return redirect(url_for('clients_page', ib_id=ib_id))

@app.route('/delete_client/<int:cl_id>')
def delete_client(cl_id):
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn=get_db()
        c = conn.cursor()
        c.execute("SELECT inbound_id FROM xray_clients WHERE id=?", (cl_id,))
        row = c.fetchone()
        ib_id = row[0] if row else None
        c.execute("DELETE FROM xray_clients WHERE id=?",(cl_id,))
        conn.commit(); conn.close()
        sync_xray()
        flash('✅ حذف شد!', 'success')
        if ib_id:
            return redirect(url_for('clients_page', ib_id=ib_id))
    except Exception as e: flash(f'❌ خطا: {e}', 'error')
    return redirect(url_for('inbounds_page'))

@app.route('/groups')
def groups_page():
    if not session.get('logged_in'): return redirect(url_for('login'))
    try:
        conn=get_db(); c=conn.cursor()
        c.execute("SELECT * FROM user_groups ORDER BY id DESC")
        groups=[]
        for g in c.fetchall():
            g=dict(g)
            c.execute("SELECT COUNT(*) as cnt FROM group_members WHERE group_id=?",(g['id'],))
            g['member_count']=c.fetchone()['cnt']
            groups.append(g)
        conn.close()
        return render_template('groups.html', groups=groups, cpu=get_cpu(), ram=get_ram())
    except: return render_template('error.html', error_message='خطا'), 500

@app.route('/add_group', methods=['POST'])
def add_group():
    if not session.get('logged_in'): return redirect(url_for('login'))
    n=request.form.get('name','')
    if n:
        try:
            conn=get_db()
            conn.cursor().execute("INSERT INTO user_groups (name,description,created_at) VALUES (?,?,?)",
                                 (n,request.form.get('description',''),datetime.now().strftime('%Y-%m-%d %H:%M')))
            conn.commit(); conn.close()
            flash('✅ گروه ایجاد شد!', 'success')
        except: flash('❌ گروه تکراری است', 'error')
    return redirect(url_for('groups_page'))

@app.route('/delete_group/<int:gid>')
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

@app.route('/remove_group_member/<int:gid>/<username>')
def remove_group_member(gid, username):
    if not session.get('logged_in'): return redirect(url_for('login'))
    conn=get_db()
    conn.cursor().execute("DELETE FROM group_members WHERE group_id=? AND username=?",(gid,username))
    conn.commit(); conn.close()
    flash('✅ حذف شد!', 'success')
    return redirect(url_for('group_members_page', gid=gid))

@app.route('/sub/<username>')
def sub_page(username):
    try:
        conn=get_db(); c=conn.cursor()
        c.execute("SELECT * FROM users WHERE username=?",(username,))
        user_data=c.fetchone()
        if not user_data:
            conn.close()
            return render_template('sub_error.html', error_message='کاربر یافت نشد'), 404
        user=dict(user_data)
        
        if user['status'] == 0:
            return render_template('sub_error.html', error_message='اکنت شما غیرفعال شده است'), 403
            
        dom=get_setting('domain') or request.host.split(':')[0]
        dpub=get_setting('reality_public_key')
        tg=round(float(user['total_traffic'])/1024,2) if user['total_traffic'] else 0
        ug=round(float(user['used_traffic'])/1024,2) if user['used_traffic'] else 0
        rg=round(max(0.0,tg-ug),2)
        prog=min(100,int((ug/tg)*100)) if tg>0 else 0
        try: dl=max(0,(datetime.strptime(user['expire_date'],'%Y-%m-%d %H:%M')-datetime.now()).days)
        except: dl=0
        ssh_uri=f"ssh://{username}:{user['password']}@{dom}:22#OP-{username}"
        ssh_qr=generate_qr_base64(ssh_uri)

        xl=[]
        c.execute("""SELECT cl.uuid, ib.port, ib.protocol, ib.network, ib.security,
                            ib.server_name, ib.fingerprint, ib.short_id, ib.public_key,
                            ib.path, ib.tag
                     FROM xray_clients cl
                     JOIN xray_inbounds ib ON cl.inbound_id=ib.id
                     WHERE cl.username=? AND cl.enable=1 AND ib.status=1
                     ORDER BY cl.id ASC""",(username,))
        rows = c.fetchall()
        for idx, xc in enumerate(rows):
            xc=dict(xc)
            link=""
            qr=""
            try:
                link=gen_link(xc['protocol'],xc['uuid'],dom,xc['port'],
                              xc.get('network','tcp'),xc.get('security','none'),
                              xc.get('server_name',''),xc.get('fingerprint',''),
                              xc.get('short_id',''),xc.get('public_key') or dpub,
                              xc.get('path','/'),username)
                qr=generate_qr_base64(link)
            except Exception as e:
                logger.error(f"Link gen error: {e}")
            xl.append({
                'protocol':xc['protocol'],'link':link,'qr_code':qr,
                'tag':xc.get('tag',''),'port':xc['port'],
                'net':xc.get('network','tcp'),'sec':xc.get('security','none'),
                'nepster_link':f"/download/nepster/{username}/{idx}",
                'netmod_link':f"/download/netmod/{username}/{idx}"
            })
        conn.close()
        return render_template('sub.html',
            username=username, password=user['password'],
            expire_date=user['expire_date'],
            total_traffic=str(tg), used_traffic=str(ug),
            remaining_traffic=str(rg), progress_percent=str(prog),
            days_left=str(dl), status=str(user['status']),
            ssh_uri=ssh_uri, ssh_qr=ssh_qr, xray_configs=xl)
    except Exception as e:
        logger.error(f"Sub error: {e}\n{traceback.format_exc()}")
        return render_template('sub_error.html', error_message=f'خطا: {str(e)}'), 500

def _get_sub_config(username, config_index):
    conn=get_db(); c=conn.cursor()
    dom=get_setting('domain') or request.host.split(':')[0]
    dpub=get_setting('reality_public_key')
    c.execute("""SELECT cl.uuid, ib.port, ib.protocol, ib.network, ib.security,
                        ib.server_name, ib.fingerprint, ib.short_id, ib.public_key, ib.path
                 FROM xray_clients cl
                 JOIN xray_inbounds ib ON cl.inbound_id=ib.id
                 WHERE cl.username=? AND cl.enable=1 AND ib.status=1
                 ORDER BY cl.id ASC
                 LIMIT 1 OFFSET ?""",(username,config_index))
    xc=c.fetchone()
    conn.close()
    if not xc: return None, dom, dpub
    return dict(xc), dom, dpub

@app.route('/download/nepster/<username>/<int:config_index>')
def download_nepster(username, config_index):
    xc, dom, dpub = _get_sub_config(username, config_index)
    if not xc: return "Not found", 404
    cfg=generate_nepster_config(xc['protocol'],xc['uuid'],dom,xc['port'],
        xc.get('network','tcp'),xc.get('security','none'),xc.get('server_name',''),
        xc.get('fingerprint',''),xc.get('short_id',''),xc.get('public_key') or dpub,
        xc.get('path','/'),username)
    return Response(cfg, mimetype="application/octet-stream",
        headers={"Content-Disposition":f"attachment;filename=OP_{username}_{xc['protocol']}.npvt"})

@app.route('/download/netmod/<username>/<int:config_index>')
def download_netmod(username, config_index):
    xc, dom, dpub = _get_sub_config(username, config_index)
    if not xc: return "Not found", 404
    cfg=generate_netmod_config(xc['protocol'],xc['uuid'],dom,xc['port'],
        xc.get('network','tcp'),xc.get('security','none'),xc.get('server_name',''),
        xc.get('fingerprint',''),xc.get('short_id',''),xc.get('public_key') or dpub,
        xc.get('path','/'),username)
    return Response(cfg, mimetype="application/json",
        headers={"Content-Disposition":f"attachment;filename=OP_{username}_{xc['protocol']}.json"})

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
            for k in ['domain','admin_username','panel_port']:
                if request.form.get(k): set_setting(k,request.form[k])
            if request.form.get('admin_password'): set_setting('admin_password',request.form['admin_password'])
            set_setting('block_iran_client','1' if request.form.get('block_iran') else '0')
            apply_iran_block()
            flash('✅ ذخیره شد!', 'success')
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
                        sync_xray()
                        flash('✅ کلیدها تولید شدند!', 'success')
            except: flash('❌ خطا', 'error')
        return redirect(url_for('settings'))
    sd={}
    for k in ['domain','admin_username','admin_password','block_iran_client','panel_port','reality_public_key','reality_private_key']:
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
        flash(f'❌ خطا: {e}', 'error')
        return redirect(url_for('settings'))

@app.route('/backup_upload', methods=['POST'])
def backup_upload():
    if not session.get('logged_in'): return redirect(url_for('login'))
    file = request.files.get('backup_file')
    if not file or file.filename == '':
        flash('❌ فایلی انتخاب نشده است', 'error')
        return redirect(url_for('settings'))
    temp_path = '/tmp/uploaded_restore.db'
    file.save(temp_path)
    try:
        test_conn = sqlite3.connect(temp_path)
        users_count = test_conn.execute("SELECT COUNT(*) FROM users;").fetchone()[0]
        test_conn.close()
    except Exception as e:
        if os.path.exists(temp_path): os.remove(temp_path)
        flash(f'❌ فایل نامعتبر: {str(e)}', 'error')
        return redirect(url_for('settings'))

    restore_script = f"""#!/bin/bash
sleep 2
systemctl mask ssh-panel.service ssh-panel-worker.service 2>/dev/null
systemctl stop ssh-panel.service ssh-panel-worker.service
for i in {{1..20}}; do
    if ! systemctl is-active --quiet ssh-panel.service && ! systemctl is-active --quiet ssh-panel-worker.service; then
        break
    fi
    sleep 0.5
done
if [ -f /root/ssh-panel/panel.db ]; then
    cp /root/ssh-panel/panel.db /root/ssh-panel/panel.db.before_restore_$(date +%s)
fi
rm -f /root/ssh-panel/panel.db-wal /root/ssh-panel/panel.db-shm
cp "{temp_path}" /root/ssh-panel/panel.db
sync
systemctl unmask ssh-panel.service ssh-panel-worker.service 2>/dev/null
systemctl start ssh-panel-worker.service
systemctl start ssh-panel.service
rm -f "{temp_path}"
"""
    script_path = '/tmp/restore_panel.sh'
    with open(script_path, 'w') as f:
        f.write(restore_script)
    os.chmod(script_path, 0o755)
    subprocess.Popen(['systemd-run', '--description', 'Restore Panel DB', '/bin/bash', script_path],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)
    flash(f'✅ بازگردانی آغاز شد ({users_count} کاربر). پنل چند لحظه قطع و خودکار راه‌اندازی می‌شود.', 'success')
    return redirect(url_for('settings'))

if __name__=='__main__':
    threading.Thread(target=update_system_stats, daemon=True).start()
    for lf in ['/tmp/xray_access.log','/tmp/xray_error.log','/var/log/panel.log']:
        if not os.path.exists(lf): open(lf,'a').close()
        try: os.chmod(lf,0o666)
        except: pass
    sync_xray()
    apply_iran_block()
    sync_users_from_db()
    logger.info(f"Panel starting on port {get_panel_port()}")
    app.run(host='0.0.0.0', port=get_panel_port(), debug=False, threaded=True)
APPEOF

echo "✓ Panel application created"

# ============================================
# STEP 8: Iran Block Script
# ============================================
echo "[8/16] Creating Iran block script..."
cat << 'EOF' > /usr/local/bin/iran-block.sh
#!/bin/bash
set -euo pipefail
IPSET_NAME="iran_ips"
CACHE_DIR="/var/cache/ssh-panel"
ZONE_FILE="$CACHE_DIR/ir.zone"
mkdir -p "$CACHE_DIR"
exec 9>/run/ssh-panel-iran.lock
flock -w 30 9
ACTION="${1:-apply}"
if [ "$ACTION" = apply ]; then
    ACTION=$(python3 - <<'PY'
import sqlite3
with sqlite3.connect('file:/root/ssh-panel/panel.db?mode=ro', uri=True) as connection:
    row = connection.execute("SELECT value FROM settings WHERE key='block_iran_client'").fetchone()
print('enable' if row and row[0] == '1' else 'disable')
PY
)
fi
changed=0
case "$ACTION" in
    enable)
        ipset create "$IPSET_NAME" hash:net maxelem 200000 -exist
        ready=0
        if [ -s "$ZONE_FILE" ] && [ "$(($(date +%s) - $(stat -c %Y "$ZONE_FILE")))" -lt 86400 ]; then
            if ipset list "$IPSET_NAME" -t | awk '/Number of entries:/{if ($4 > 0) good=1} END{exit !good}'; then
                ready=1
            fi
        fi
        if [ "$ready" -eq 0 ]; then
            if curl -fsSL --connect-timeout 5 --max-time 15 https://www.ipdeny.com/ipblocks/data/countries/ir.zone -o "$ZONE_FILE.new"; then
                python3 - "$ZONE_FILE.new" <<'PY'
import ipaddress, sys
with open(sys.argv[1]) as stream:
    values = [line.strip() for line in stream if line.strip()]
if not values:
    raise SystemExit('Empty Iran IP list')
for value in values:
    if ipaddress.ip_network(value, strict=False).version != 4:
        raise SystemExit('Invalid IPv4 block')
PY
                mv "$ZONE_FILE.new" "$ZONE_FILE"
            else
                rm -f "$ZONE_FILE.new"
                [ -s "$ZONE_FILE" ] || exit 1
            fi
            # One restore transaction, instead of thousands of ipset processes.
            python3 - "$ZONE_FILE" <<'PY' | ipset restore -exist
import ipaddress, sys
with open(sys.argv[1]) as stream:
    networks = [str(ipaddress.ip_network(line.strip(), strict=False)) for line in stream if line.strip()]
print('create iran_ips_next hash:net maxelem 200000')
print('flush iran_ips_next')
for network in networks:
    print('add iran_ips_next ' + network)
print('swap iran_ips_next iran_ips')
print('flush iran_ips_next')
PY
        fi
        if ! iptables -w 2 -C OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
            iptables -w 2 -I OUTPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT
            changed=1
        fi
        if ! iptables -w 2 -C OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null; then
            iptables -w 2 -A OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP
            changed=1
        fi
        ;;
    disable)
        if iptables -w 2 -C OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null; then
            iptables -w 2 -D OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP
            changed=1
        fi
        ;;
    *) echo "Usage: $0 enable|disable|apply"; exit 1 ;;
esac
if [ "$changed" -eq 1 ]; then
    netfilter-persistent save 2>/dev/null || true
fi
EOF
chmod +x /usr/local/bin/iran-block.sh

cat << 'EOF' > /etc/systemd/system/iran-block.service
[Unit]
Description=Apply Iran outbound IP blocking
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/iran-block.sh apply
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

# ============================================
# STEP 9: Traffic Worker v3.7
# ============================================
echo "[9/16] Creating traffic worker v3.7..."
cat << 'WORKEREOF' > /root/ssh-panel/traffic_worker.py
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v3.7 repair: one bounded collector for traffic, online and IP limits."""
import fcntl
import json
import logging
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time
from collections import defaultdict
from contextlib import closing
from datetime import datetime
from telemetry import BoundedLogReader, ONLINE_TTL, atomic_json, canonical_ip, endpoint, log_activity

sys.path.insert(0, '/root/ssh-panel/grpc_proto')
try:
    import grpc
    import stats_pb2
    import stats_pb2_grpc
except ImportError:
    grpc = None

DB_PATH = '/root/ssh-panel/panel.db'
ONLINE_FILE = '/tmp/online_users.json'
SSH_SESSIONS_FILE = '/tmp/ssh_sessions.json'
POLL_INTERVAL = 5
logger = logging.getLogger('OP.worker')
SOCKET_RE = re.compile(r'^(?:ESTAB\s+)?\d+\s+\d+\s+(\S+)\s+(\S+)')
PID_RE = re.compile(r'pid=(\d+)')
INODE_RE = re.compile(r'\bino:(\d+)')
TITLE_RE = re.compile(r'\bsshd(?:-session|-auth)?:\s+([^\s@]+)(?:@(\S+)|\s+\[priv\])')


def run_output(command):
    return subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL, timeout=3)


class SSHCollector:
    def __init__(self, state_path=SSH_SESSIONS_FILE):
        self.state_path, self.sessions = state_path, {}
        self.initialized = False
        try:
            with open('/proc/sys/kernel/random/boot_id') as stream:
                self.boot_id = stream.read().strip()
        except OSError:
            self.boot_id = ''
        try:
            with open(state_path) as stream:
                state = json.load(stream)
            if state.get('version') == 2 and state.get('boot_id') == self.boot_id:
                self.sessions = state.get('sessions', {})
        except (OSError, ValueError, AttributeError):
            pass

    @staticmethod
    def process_users(output, known):
        processes, authenticated = {}, {}
        for line in output.splitlines():
            fields = line.strip().split(None, 2)
            if len(fields) != 3:
                continue
            try:
                pid, parent = int(fields[0]), int(fields[1])
            except ValueError:
                continue
            title = TITLE_RE.search(fields[2])
            username = title.group(1) if title else None
            processes[pid] = (parent, username)
            if title and title.group(2) and username in known and '[preauth]' not in fields[2]:
                authenticated[pid] = username
        # Privileged parents also own sockets. Resolve them via an authenticated
        # child rather than treating a pre-authentication title as online.
        for pid, username in list(authenticated.items()):
            for _ in range(8):
                parent = processes.get(pid, (0, None))[0]
                record = processes.get(parent)
                if not record or record[1] != username:
                    break
                authenticated[parent] = username
                pid = parent
        return authenticated

    def collect(self, known, now):
        known = {username for username in known if username != 'root'}
        traffic = defaultdict(float)
        try:
            output = run_output(['ss', '-Htnpie', 'state', 'established', '( sport = :22 )'])
            records, current = [], {}
            for line in output.splitlines():
                match = SOCKET_RE.match(line)
                if match:
                    records.append([match, line])
                elif records:
                    records[-1][1] += ' ' + line
            users = self.process_users(run_output(['ps', '-eo', 'pid=,ppid=,args=']), known) if records else {}
            for match, record in records:
                local, peer = endpoint(match.group(1)), endpoint(match.group(2))
                if not local or not peer or local[1] != 22:
                    continue
                username = next((users[int(pid)] for pid in PID_RE.findall(record) if int(pid) in users), None)
                if not username:
                    continue
                inode = INODE_RE.search(record)
                key = '|'.join((username, match.group(1), match.group(2), inode.group(1) if inode else ''))
                tx = re.search(r'\bbytes_acked:(\d+)', record)
                rx = re.search(r'\bbytes_received:(\d+)', record)
                tx, rx = int(tx.group(1)) if tx else 0, int(rx.group(1)) if rx else 0
                current[key] = {'username': username, 'ip': peer[0], 'tx': tx, 'rx': rx, 'ts': now}
                previous = self.sessions.get(key)
                if previous:
                    delta = max(0, tx - int(previous.get('tx', 0))) + max(0, rx - int(previous.get('rx', 0)))
                else:
                    # Migration must not bill existing sessions a second time.
                    delta = tx + rx if self.initialized else 0
                traffic[username] += delta / (1024.0 * 1024.0)
            self.sessions, self.initialized = current, True
            atomic_json(self.state_path, {'version': 2, 'boot_id': self.boot_id, 'sessions': current})
        except (OSError, subprocess.SubprocessError) as error:
            logger.warning('SSH sampling failed: %s', error)
        ips, counts = defaultdict(set), defaultdict(int)
        for item in self.sessions.values():
            if item['username'] in known and now - item['ts'] <= 15:
                ips[item['username']].add(item['ip'])
                counts[item['username']] += 1
        return dict(traffic), dict(ips), dict(counts)


class XrayCollector:
    def __init__(self):
        self.channel, self.stub = None, None
        self.batch_supported, self.legacy_supported = True, True
        if grpc:
            self.channel = grpc.insecure_channel('127.0.0.1:10085')
            self.stub = stats_pb2_grpc.StatsServiceStub(self.channel)

    def close(self):
        if self.channel:
            self.channel.close()

    def traffic(self, aliases):
        result = defaultdict(float)
        if not self.stub:
            return {}
        try:
            response = self.stub.QueryStats(stats_pb2.QueryStatsRequest(pattern='user>>>', reset=True), timeout=2)
            for item in response.stat:
                fields = item.name.split('>>>')
                if len(fields) == 4 and fields[0] == 'user' and fields[2] == 'traffic' and fields[1] in aliases and item.value > 0:
                    result[aliases[fields[1]]] += item.value / (1024.0 * 1024.0)
        except grpc.RpcError:
            pass
        # No startup prime/reset: a worker restart must not discard traffic.
        return dict(result)

    @staticmethod
    def email(value):
        return value[7:-9] if value.startswith('user>>>') and value.endswith('>>>online') else value

    def online(self, aliases):
        if not self.stub:
            return {}, set()
        if self.batch_supported:
            try:
                response = self.stub.GetUsersStats(stats_pb2.GetUsersStatsRequest(include_traffic=False, reset=False), timeout=2)
                addresses = defaultdict(set)
                for user in response.users:
                    if user.email in aliases:
                        for item in user.ips:
                            ip = canonical_ip(item.ip)
                            if ip:
                                addresses[aliases[user.email]].add(ip)
                return dict(addresses), set(aliases.values())
            except grpc.RpcError as error:
                if error.code() == grpc.StatusCode.UNIMPLEMENTED:
                    self.batch_supported = False
                else:
                    return {}, set()
        if self.legacy_supported:
            try:
                response = self.stub.GetAllOnlineUsers(stats_pb2.GetAllOnlineUsersRequest(), timeout=1)
                emails = {self.email(value) for value in response.users} & set(aliases)
                addresses, queried_emails = defaultdict(set), set(aliases) - emails
                deadline = time.monotonic() + 2
                for email in sorted(emails):
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    try:
                        item = self.stub.GetStatsOnlineIpList(stats_pb2.GetStatsRequest(name='user>>>' + email + '>>>online'), timeout=min(0.5, remaining))
                        queried_emails.add(email)
                        for value in item.ips:
                            ip = canonical_ip(value)
                            if ip:
                                addresses[aliases[email]].add(ip)
                    except grpc.RpcError:
                        continue
                authoritative = {username for username in aliases.values()
                                 if all(email in queried_emails for email, owner in aliases.items() if owner == username)}
                return dict(addresses), authoritative
            except grpc.RpcError as error:
                if error.code() == grpc.StatusCode.UNIMPLEMENTED:
                    self.legacy_supported = False
        return {}, set()


def read_accounts():
    with closing(sqlite3.connect(DB_PATH, timeout=5)) as connection:
        connection.row_factory = sqlite3.Row
        users = {row['username']: dict(row) for row in connection.execute('SELECT username,max_connections FROM users WHERE status=1')}
        aliases = dict((username, username) for username in users)
        for email, username in connection.execute('''SELECT cl.email, cl.username FROM xray_clients cl
                JOIN xray_inbounds ib ON ib.id=cl.inbound_id JOIN users u ON u.username=cl.username
                WHERE cl.enable=1 AND ib.status=1 AND u.status=1'''):
            if email:
                aliases[email] = username
        ports = [22] + [row[0] for row in connection.execute('SELECT port FROM xray_inbounds WHERE status=1')]
    return users, aliases, sorted({int(port) for port in ports if 0 < int(port) < 65536})


def update_usage(traffic):
    deactivated = []
    with closing(sqlite3.connect(DB_PATH, timeout=5)) as connection:
        with connection:
            connection.executemany('UPDATE users SET used_traffic=used_traffic+? WHERE username=?',
                                   [(mb, username) for username, mb in traffic.items() if mb > 0])
            now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            deactivated = [row[0] for row in connection.execute('''SELECT username FROM users WHERE status=1
                AND ((total_traffic>0 AND used_traffic>=total_traffic) OR datetime(expire_date)<=?)''', (now,))]
            connection.executemany('UPDATE users SET status=0 WHERE username=?', [(username,) for username in deactivated])
    for username in deactivated:
        if username == 'root':
            continue
        for command in (['usermod', '-L', username], ['pkill', '-u', username]):
            try:
                subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
            except (OSError, subprocess.SubprocessError):
                logger.warning('Could not terminate expired SSH account %s', username)
    return deactivated


class Worker:
    def __init__(self):
        self.ssh, self.xray = SSHCollector(), XrayCollector()
        self.log = BoundedLogReader('/tmp/xray_access.log', '/tmp/xray_log_cursor_v2.json')
        self.activity, self.log_ips, self.native_cache = {}, {}, {}
        self.native_seen, self.first_seen = set(), {}
        self.pending, self.sync_pending = defaultdict(float), False

    def tick(self, now=None):
        now = time.time() if now is None else now
        users, aliases, ports = read_accounts()
        traffic = self.xray.traffic(aliases)
        for username, mb in traffic.items():
            self.pending[username] += mb
            self.activity[username] = now
        for username, ips in log_activity(self.log.read(), aliases, now).items():
            self.log_ips.setdefault(username, {}).update(ips)
        ssh_traffic, ssh_ips, ssh_sessions = self.ssh.collect(users, now)
        for username, mb in ssh_traffic.items():
            self.pending[username] += mb
        native_ips, authoritative = self.xray.online(aliases)
        for username in authoritative:
            self.native_cache[username] = (set(native_ips.get(username, ())), now)
        for username, ips in native_ips.items():
            if ips:
                self.native_seen.add(username)
        try:
            disabled = update_usage(self.pending)
            self.pending.clear()
            self.sync_pending = self.sync_pending or bool(disabled)
            for username in disabled:
                users.pop(username, None)
        except sqlite3.Error as error:
            logger.warning('Usage transaction failed; retaining deltas for retry: %s', error)
        online, live_first_seen = {}, {}
        for username, account in users.items():
            recent_ips = {ip: ts for ip, ts in self.log_ips.get(username, {}).items() if now - ts <= ONLINE_TTL}
            if recent_ips:
                self.log_ips[username] = recent_ips
            else:
                self.log_ips.pop(username, None)
            cached_ips, cached_at = self.native_cache.get(username, (set(), 0))
            native_known = username in authoritative or now - cached_at <= 15
            xray_ips = set(native_ips.get(username, cached_ips if native_known else ()))
            # Older cores and local proxies need a short activity window.
            fallback = not native_known or username not in self.native_seen
            active = now - self.activity.get(username, 0) <= ONLINE_TTL
            if fallback:
                xray_ips.update(recent_ips)
            is_xray = bool(xray_ips) or (fallback and active)
            ssh_addresses = set(ssh_ips.get(username, ()))
            combined, first = ssh_addresses | xray_ips, {}
            for ip in combined:
                key = (username, ip)
                first[ip] = self.first_seen.get(key, now)
                live_first_seen[key] = first[ip]
            if ssh_addresses or is_xray:
                online[username] = {
                    'ssh': len(ssh_addresses), 'ssh_sessions': ssh_sessions.get(username, 0),
                    'xray': is_xray, 'xray_ips': len(xray_ips),
                    'ssh_ips': sorted(ssh_addresses), 'xray_addresses': sorted(xray_ips),
                    'ips': sorted(combined), 'ip_first_seen': first,
                    'online_count': max(1, len(combined)), 'ts': now,
                    'max_connections': account['max_connections'],
                }
        self.first_seen = live_first_seen
        for mapping in (self.activity, self.native_cache, self.log_ips):
            for username in list(mapping):
                if username not in users:
                    del mapping[username]
        self.native_seen.intersection_update(users)
        atomic_json(ONLINE_FILE, {'version': 2, 'last_update': now, 'users': online, 'ports': ports})
        if self.sync_pending:
            try:
                subprocess.run([sys.executable, '/root/ssh-panel/sync_xray.py'], check=True, timeout=30)
                self.sync_pending = False
            except (OSError, subprocess.SubprocessError) as error:
                logger.warning('Xray synchronization will be retried: %s', error)


def main():
    logging.basicConfig(level=logging.WARNING, format='%(asctime)s %(levelname)s %(message)s')
    lock = open('/root/ssh-panel/traffic_worker.lock', 'a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    stopping = False
    def stop(signum, frame):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    worker = Worker()
    try:
        while not stopping:
            started = time.monotonic()
            try:
                worker.tick()
            except Exception:
                logger.exception('Worker sample failed')
            remaining = max(1, POLL_INTERVAL - (time.monotonic() - started))
            until = time.monotonic() + remaining
            while not stopping and time.monotonic() < until:
                time.sleep(min(0.25, max(0, until - time.monotonic())))
    finally:
        worker.xray.close()
        lock.close()


if __name__ == '__main__':
    main()
WORKEREOF
chmod +x /root/ssh-panel/traffic_worker.py
echo "✓ Worker created"

# ============================================
# STEP 10: Smart IP Manager v3.7
# ============================================
echo "[10/16] Creating Smart IP Manager (Multi-device limiter)..."
cat << 'EOF' > /root/ssh-panel/ip_manager.py
#!/usr/bin/env python3
"""IP limiter consuming the worker snapshot, never rescanning SSH or logs."""
import fcntl
import ipaddress
import json
import logging
import os
import signal
import subprocess
import time
from telemetry import SnapshotReader, atomic_json, canonical_ip

ONLINE_FILE = '/tmp/online_users.json'
STATE_FILE = '/tmp/ip_manager_state.json'
CHAIN = 'OP_PANEL_LIMIT'
SETS = {4: 'op_limit_v4', 6: 'op_limit_v6'}
logger = logging.getLogger('OP.limiter')


def command(args, **kwargs):
    return subprocess.run(args, text=True, stdout=subprocess.DEVNULL,
                          stderr=subprocess.PIPE, timeout=5, **kwargs)


def desired_blocks(snapshot):
    blocked = set()
    for info in snapshot.get('users', {}).values():
        try:
            limit = int(info.get('max_connections', 0))
            if limit <= 0:
                continue
            addresses = {canonical_ip(value) for value in info.get('ips', ())}
            addresses.discard(None)
            first = info.get('ip_first_seen', {})
            ordered = sorted(addresses, key=lambda ip: (float(first.get(ip, 0)), ip))
            blocked.update(ordered[limit:])
        except (ValueError, TypeError, AttributeError):
            continue
    return blocked


class Firewall:
    def __init__(self):
        self.initialized = False
        self.ports, self.blocked, self.refreshed = None, None, 0

    def initialize(self):
        for family, name in SETS.items():
            for set_name in (name, name + '_next'):
                result = command(['ipset', 'create', set_name, 'hash:ip', 'family',
                                  'inet' if family == 4 else 'inet6', 'timeout', '60', 'maxelem', '200000', '-exist'])
                if result.returncode:
                    raise RuntimeError(result.stderr.strip())
            tool = 'iptables' if family == 4 else 'ip6tables'
            if command([tool, '-w', '2', '-S', CHAIN]).returncode:
                result = command([tool, '-w', '2', '-N', CHAIN])
                if result.returncode:
                    raise RuntimeError(result.stderr.strip())
            if command([tool, '-w', '2', '-C', 'INPUT', '-j', CHAIN]).returncode:
                result = command([tool, '-w', '2', '-I', 'INPUT', '1', '-j', CHAIN])
                if result.returncode:
                    raise RuntimeError(result.stderr.strip())
        self.initialized = True

    def set_ports(self, ports):
        ports = tuple(sorted({int(port) for port in ports if 0 < int(port) < 65536}))
        if ports == self.ports:
            return
        for family, name in SETS.items():
            # Rewrite only our own chain. Existing INPUT rules stay in place.
            rules = ['*filter', ':' + CHAIN + ' - [0:0]', '-F ' + CHAIN]
            for offset in range(0, len(ports), 15):
                chunk = ','.join(map(str, ports[offset:offset + 15]))
                rules.append('-A ' + CHAIN + ' -p tcp -m multiport --dports ' + chunk +
                             ' -m set --match-set ' + name + ' src -j DROP')
            rules.append('COMMIT')
            result = command(['iptables-restore' if family == 4 else 'ip6tables-restore', '-w', '2', '--noflush'],
                             input='\n'.join(rules) + '\n')
            if result.returncode:
                raise RuntimeError(result.stderr.strip())
        self.ports = ports

    def apply(self, blocked, ports, now=None):
        now = time.time() if now is None else now
        if not self.initialized:
            self.initialize()
        self.set_ports(ports)
        # A stable idle snapshot runs no firewall commands. Refresh active
        # sets in one batch; timeout also releases rules if the limiter dies.
        if blocked == self.blocked and (not blocked or now - self.refreshed < 20):
            return False
        lines = []
        for family, name in SETS.items():
            stage = name + '_next'
            lines.append('flush ' + stage)
            for address in sorted(blocked):
                if ipaddress.ip_address(address).version == family:
                    lines.append('add ' + stage + ' ' + address + ' timeout 60')
            lines.extend(('swap ' + stage + ' ' + name, 'flush ' + stage))
        result = command(['ipset', 'restore', '-exist'], input='\n'.join(lines) + '\n')
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        self.blocked, self.refreshed = set(blocked), now
        return True

    def clear(self):
        if self.initialized:
            command(['ipset', 'restore', '-exist'], input='\n'.join('flush ' + name for name in SETS.values()) + '\n')


def clean_legacy_rules(state_path=STATE_FILE):
    try:
        with open(state_path) as stream:
            state = json.load(stream)
        if isinstance(state, dict) and state.get('version') == 2:
            return
        values = state if isinstance(state, list) else state.get('blocked_ips', [])
        for value in values:
            address = canonical_ip(value)
            if address:
                command(['iptables' if ipaddress.ip_address(address).version == 4 else 'ip6tables',
                         '-w', '2', '-D', 'INPUT', '-s', address, '-j', 'DROP'])
        atomic_json(state_path, {'version': 2, 'blocked_ips': []})
    except (OSError, ValueError, AttributeError):
        pass


def main():
    logging.basicConfig(level=logging.WARNING, format='%(asctime)s %(levelname)s %(message)s')
    lock = open('/root/ssh-panel/ip_manager.lock', 'a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    clean_legacy_rules()
    reader, firewall = SnapshotReader(ONLINE_FILE), Firewall()
    stopping = False
    def stop(signum, frame):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while not stopping:
            try:
                snapshot = reader.read()
                desired = desired_blocks(snapshot)
                ports = snapshot.get('ports', firewall.ports or [22])
                if firewall.apply(desired, ports):
                    atomic_json(STATE_FILE, {'version': 2, 'blocked_ips': sorted(desired)})
            except Exception as error:
                logger.warning('Limiter sample failed: %s', error)
            until = time.monotonic() + 5
            while not stopping and time.monotonic() < until:
                time.sleep(min(0.25, max(0, until - time.monotonic())))
    finally:
        firewall.clear()
        lock.close()


if __name__ == '__main__':
    main()
EOF
chmod +x /root/ssh-panel/ip_manager.py

cat << 'EOF' > /etc/systemd/system/ssh-panel-ip-manager.service
[Unit]
Description=OutlineParsian Smart IP Manager
After=network.target ssh.service xray.service
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /root/ssh-panel/ip_manager.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
echo "✓ Smart IP Manager created"

# ============================================
# STEP 11: HTML TEMPLATES
# ============================================
echo "[11/16] Creating modern HTML templates..."

# ---------- login.html ----------
cat << 'EOF' > /root/ssh-panel/templates/login.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>ورود | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;500;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:radial-gradient(circle at top,#1a0000 0%,#000 60%);min-height:100vh}@keyframes pulseRed{0%,100%{box-shadow:0 0 30px rgba(220,38,38,0.3)}50%{box-shadow:0 0 60px rgba(220,38,38,0.6)}}.pulse-red{animation:pulseRed 3s ease-in-out infinite}.slide-up{animation:slideUp 0.8s ease-out}@keyframes slideUp{from{opacity:0;transform:translateY(30px)}to{opacity:1;transform:translateY(0)}}.glow-input:focus{box-shadow:0 0 0 3px rgba(220,38,38,0.2)}</style></head><body class="flex items-center justify-center p-4"><div class="w-full max-w-md slide-up"><div class="bg-gradient-to-b from-[#1a0000] to-[#0a0000] border border-red-900/50 rounded-3xl p-8 shadow-2xl pulse-red"><div class="text-center mb-8"><div class="w-24 h-24 mx-auto bg-gradient-to-br from-red-700 to-red-900 rounded-2xl flex items-center justify-center shadow-lg mb-4 border border-red-500/30"><span class="text-5xl font-black text-red-100">OP</span></div><h1 class="text-2xl font-bold text-red-400">OutlineParsian</h1><p class="text-xs text-red-700/70 mt-1">Ultimate Panel v3.7</p></div>{% if error %}<div class="bg-red-900/30 border border-red-700/50 text-red-400 p-4 rounded-2xl mb-6 text-sm"><i class="fa-solid fa-triangle-exclamation ml-2"></i>{{ error }}</div>{% endif %}<form action="/" method="POST" class="space-y-5"><div><label class="block text-xs font-bold text-red-400/70 mb-2"><i class="fa-solid fa-user ml-1"></i> نام کاربری</label><input type="text" name="username" required class="glow-input w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 text-left font-mono outline-none focus:border-red-500 transition-all" dir="ltr" placeholder="admin" autocomplete="username"></div><div><label class="block text-xs font-bold text-red-400/70 mb-2"><i class="fa-solid fa-lock ml-1"></i> کلمه عبور</label><input type="password" name="password" required class="glow-input w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 text-left font-mono outline-none focus:border-red-500 transition-all" dir="ltr" placeholder="••••••••" autocomplete="current-password"></div><button type="submit" class="w-full bg-gradient-to-r from-red-700 to-red-900 hover:from-red-600 hover:to-red-800 py-4 rounded-2xl font-bold text-red-100 shadow-lg transition-all border border-red-500/30"><i class="fa-solid fa-right-to-bracket ml-2"></i>ورود به پنل</button></form><p class="text-center text-[10px] text-red-900 mt-6">🔒 Secure Panel · Protected Session</p></div></div></body></html>
EOF

# ---------- error.html ----------
cat << 'EOF' > /root/ssh-panel/templates/error.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>خطا | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:radial-gradient(circle at top,#1a0000 0%,#000 60%);min-height:100vh}.glass{background:rgba(20,0,0,0.9);border:1px solid rgba(255,0,0,0.2);border-radius:24px;padding:2rem;text-align:center;max-width:440px;margin:auto}</style></head><body class="min-h-screen flex items-center justify-center p-4"><div class="glass shadow-2xl shadow-red-900/20"><div class="w-20 h-20 mx-auto bg-red-900/30 rounded-2xl flex items-center justify-center mb-4 border border-red-500/30"><i class="fa-solid fa-triangle-exclamation text-4xl text-red-500"></i></div><h1 class="text-xl font-bold text-red-400 mb-2">خطا</h1><p class="text-gray-400 text-sm mb-6 break-all">{{ error_message }}</p><a href="/dashboard" class="inline-flex items-center gap-2 px-6 py-2.5 bg-gradient-to-r from-red-700 to-red-900 text-red-100 text-sm font-bold rounded-xl border border-red-500/30"><i class="fa-solid fa-house"></i>بازگشت به داشبورد</a></div></body></html>
EOF

# ---------- dashboard.html ----------
cat << 'EOF' > /root/ssh-panel/templates/dashboard.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>داشبورد | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;500;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.75);backdrop-filter:blur(20px);border:1px solid rgba(255,0,0,0.15)}.stat-card{transition:all 0.3s ease;position:relative;overflow:hidden}.stat-card:hover{transform:translateY(-3px);box-shadow:0 10px 40px rgba(220,38,38,0.25)}.stat-card::before{content:'';position:absolute;top:0;right:0;width:100px;height:100px;background:radial-gradient(circle,rgba(220,38,38,0.15),transparent 70%);border-radius:50%}.nav-link{transition:all 0.2s;border:1px solid transparent}.nav-link:hover{background:rgba(220,38,38,0.15);color:#f87171;border-color:rgba(220,38,38,0.2)}.nav-link.active{background:rgba(220,38,38,0.25);color:#f87171;border-color:rgba(220,38,38,0.4)}.user-row{transition:all 0.2s}.user-row:hover{background:rgba(220,38,38,0.08)}.progress-bar{background:linear-gradient(90deg,#dc2626,#f87171)}.pulse-dot{animation:pulse 1.5s ease-in-out infinite}@keyframes pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:0.7;transform:scale(1.2)}}.mobile-card{display:none}.fade-in{animation:fadeIn 0.3s ease}@keyframes fadeIn{from{opacity:0}to{opacity:1}}@media(max-width:768px){.desktop-table{display:none}.mobile-card{display:block!important}}</style></head><body class="min-h-screen pb-8"><nav class="glass sticky top-0 z-50 px-4 md:px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex items-center justify-between flex-wrap gap-3"><div class="flex items-center gap-3"><div class="w-10 h-10 bg-gradient-to-br from-red-700 to-red-900 rounded-xl flex items-center justify-center shadow-lg border border-red-500/30"><span class="text-lg font-black text-red-100">OP</span></div><div><h1 class="text-base md:text-lg font-bold text-red-400">OutlineParsian</h1><p class="text-[10px] text-red-700/70 hidden md:block">Ultimate Panel v3.7</p></div></div><div class="flex items-center gap-2 text-xs order-3 md:order-2"><span class="flex items-center gap-1.5 bg-red-900/20 px-3 py-1.5 rounded-full border border-red-800/30"><i class="fa-solid fa-microchip text-red-500"></i><span id="cpu_value">{{ cpu }}</span>%</span><span class="flex items-center gap-1.5 bg-red-900/20 px-3 py-1.5 rounded-full border border-red-800/30"><i class="fa-solid fa-memory text-red-400"></i><span id="ram_value">{{ ram }}</span>%</span></div><div class="flex items-center gap-1.5 flex-wrap order-2 md:order-3"><a href="/dashboard" class="nav-link active px-3 py-1.5 rounded-lg text-xs font-bold"><i class="fa-solid fa-gauge-high"></i><span class="hidden md:inline mr-1">داشبورد</span></a><a href="/inbounds" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs"><i class="fa-solid fa-server"></i><span class="hidden md:inline mr-1">اینباند</span></a><a href="/groups" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs"><i class="fa-solid fa-layer-group"></i><span class="hidden md:inline mr-1">گروه‌ها</span></a><a href="/reports" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs"><i class="fa-solid fa-chart-bar"></i><span class="hidden md:inline mr-1">گزارش</span></a><a href="/settings" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs"><i class="fa-solid fa-gear"></i></a><a href="/logout" class="px-3 py-1.5 bg-red-900/30 text-red-400 rounded-lg border border-red-800/50 text-xs"><i class="fa-solid fa-right-from-bracket"></i></a></div></div></nav><main class="p-3 md:p-6 max-w-7xl mx-auto">{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, message in messages %}<div class="fade-in {% if category == 'success' %}bg-emerald-900/30 border border-emerald-700/50 text-emerald-400{% else %}bg-red-900/30 border border-red-700/50 text-red-400{% endif %} p-4 rounded-2xl text-sm mb-4 flex items-center gap-2"><i class="fa-solid {% if category=='success' %}fa-circle-check{% else %}fa-circle-exclamation{% endif %}"></i>{{ message }}</div>{% endfor %}{% endif %}{% endwith %}<div class="grid grid-cols-2 md:grid-cols-5 gap-3 mb-6"><div class="glass stat-card rounded-2xl p-4 relative z-10"><div class="flex items-center justify-between mb-2"><i class="fa-solid fa-users text-xl text-red-500"></i><span class="text-[10px] text-red-400/50 uppercase">Users</span></div><div class="text-2xl font-black text-red-400">{{ total_users }}</div><p class="text-[10px] text-red-400/40 mt-1">کل کاربران</p></div><div class="glass stat-card rounded-2xl p-4 relative z-10"><div class="flex items-center justify-between mb-2"><i class="fa-solid fa-user-check text-xl text-emerald-400"></i><span class="text-[10px] text-emerald-400/50 uppercase">Active</span></div><div class="text-2xl font-black text-emerald-400">{{ active_users }}</div><p class="text-[10px] text-emerald-400/40 mt-1">کاربران فعال</p></div><div class="glass stat-card rounded-2xl p-4 relative z-10"><div class="flex items-center justify-between mb-2"><i class="fa-solid fa-server text-xl text-purple-400"></i><span class="text-[10px] text-purple-400/50 uppercase">Inbounds</span></div><div class="text-2xl font-black text-purple-400">{{ total_inbounds }}</div><p class="text-[10px] text-purple-400/40 mt-1">اینباندها</p></div><div class="glass stat-card rounded-2xl p-4 relative z-10"><div class="flex items-center justify-between mb-2"><i class="fa-solid fa-plug text-xl text-blue-400"></i><span class="text-[10px] text-blue-400/50 uppercase">Clients</span></div><div class="text-2xl font-black text-blue-400">{{ total_clients }}</div><p class="text-[10px] text-blue-400/40 mt-1">کلاینت‌ها</p></div><div class="glass stat-card rounded-2xl p-4 relative z-10"><div class="flex items-center justify-between mb-2"><i class="fa-solid fa-database text-xl text-amber-400"></i><span class="text-[10px] text-amber-400/50 uppercase">Traffic</span></div><div class="text-2xl font-black text-amber-400">{{ total_used }}</div><p class="text-[10px] text-amber-400/40 mt-1">GB مصرف شده</p></div></div><div class="flex flex-wrap items-center justify-between gap-3 mb-4"><h2 class="text-base md:text-lg font-bold text-red-400"><i class="fa-solid fa-list ml-1"></i>مدیریت کاربران</h2><div class="flex items-center gap-2 flex-wrap"><input id="searchBox" type="text" placeholder="جستجو..." class="bg-black border border-red-900/50 rounded-xl px-3 py-2 text-red-300 text-xs focus:border-red-500 outline-none w-40 md:w-56"><select id="statusFilter" class="bg-black border border-red-900/50 rounded-xl px-3 py-2 text-red-300 text-xs outline-none"><option value="all">همه</option><option value="online">آنلاین</option><option value="offline">آفلاین</option><option value="active">فعال</option><option value="inactive">غیرفعال</option></select><a href="/add_user_page" class="px-4 py-2 bg-gradient-to-r from-red-700 to-red-900 rounded-xl text-red-100 text-xs font-bold border border-red-500/30"><i class="fa-solid fa-plus ml-1"></i>کاربر جدید</a></div></div><div class="glass rounded-2xl p-2 md:p-4 overflow-hidden"><div class="desktop-table overflow-x-auto"><table class="w-full text-right text-sm"><thead><tr class="bg-black/50 text-red-400/70 text-xs"><th class="p-3">کاربر</th><th class="p-3">پسورد</th><th class="p-3">دستگاه‌ها</th><th class="p-3">ترافیک</th><th class="p-3">انقضا</th><th class="p-3 text-center">وضعیت</th><th class="p-3 text-center">عملیات</th></tr></thead><tbody class="divide-y divide-red-900/20" id="usersTableBody">{% for user in users %}<tr class="user-row" data-username="{{ user.username|lower }}" data-online="{% if user.is_online %}1{% else %}0{% endif %}" data-status="{{ user.status }}"><td class="p-3"><div class="flex items-center gap-2"><span class="w-2.5 h-2.5 rounded-full {% if user.is_online %}bg-emerald-500 pulse-dot shadow-lg shadow-emerald-500/50{% else %}bg-gray-700{% endif %}"></span><span class="font-bold text-red-400">{{ user.username }}</span>{% if user.is_ssh_online %}<span class="text-[9px] bg-emerald-900/40 text-emerald-400 px-1.5 py-0.5 rounded border border-emerald-700/30">SSH</span>{% endif %}{% if user.is_xray_online %}<span class="text-[9px] bg-purple-900/40 text-purple-400 px-1.5 py-0.5 rounded border border-purple-700/30">V2Ray</span>{% endif %}</div></td><td class="p-3 text-red-300/70 font-mono text-xs">{{ user.password }}</td><td class="p-3"><span class="px-2.5 py-1 rounded-lg bg-black/50 text-xs font-mono {% if user.online_count > 0 %}text-emerald-400 border-emerald-800/30{% else %}text-red-400 border-red-900/30{% endif %} border">{{ user.online_count }}/{{ user.max_connections }}</span></td><td class="p-3"><div class="w-28"><div class="flex justify-between text-[10px] text-red-400/50 font-mono mb-1"><span>{{ user.used_traffic }}</span><span>{{ user.total_traffic }} GB</span></div><div class="w-full bg-red-900/30 h-1.5 rounded-full overflow-hidden"><div class="progress-bar h-1.5 rounded-full" style="width:{{ (user.used_traffic/user.total_traffic*100)|int if user.total_traffic>0 else 0 }}%"></div></div></div></td><td class="p-3 text-red-400/50 text-xs font-mono}}{{ user.expire_date }}</td><td class="p-3 text-center">{% if user.status==1 %}<span class="px-2.5 py-1 rounded-full bg-emerald-900/30 text-emerald-400 text-xs border border-emerald-700/50">فعال</span>{% else %}<span class="px-2.5 py-1 rounded-full bg-red-900/50 text-red-400 text-xs border border-red-700/50">غیرفعال</span>{% endif %}</td><td class="p-3"><div class="inline-flex items-center gap-1.5"><a href="/sub/{{ user.username }}" target="_blank" class="p-2 bg-blue-900/20 hover:bg-blue-800/40 text-blue-400 border border-blue-800/30 rounded-xl text-xs" title="صفحه اشتراک"><i class="fa-solid fa-link"></i></a><button onclick="openEdit('{{ user.username }}','{{ user.password }}','{{ user.total_traffic }}','{{ user.max_connections }}','{{ user.status }}','{{ user.expire_date }}')" class="p-2 bg-amber-900/20 hover:bg-amber-800/40 text-amber-400 border border-amber-800/30 rounded-xl text-xs" title="ویرایش"><i class="fa-solid fa-pen-to-square"></i></button><a href="/delete_user/{{ user.username }}" onclick="return confirm('حذف {{ user.username }}؟')" class="p-2 bg-red-900/30 hover:bg-red-800/50 text-red-400 border border-red-700/50 rounded-xl text-xs" title="حذف"><i class="fa-solid fa-trash"></i></a></div></td></tr>{% endfor %}</tbody></table></div><div class="mobile-card space-y-2">{% for user in users %}<div class="bg-black/40 border border-red-900/30 rounded-xl p-3" data-username="{{ user.username|lower }}" data-online="{% if user.is_online %}1{% else %}0{% endif %}" data-status="{{ user.status }}"><div class="flex items-center justify-between mb-2"><div class="flex items-center gap-2"><span class="w-2.5 h-2.5 rounded-full {% if user.is_online %}bg-emerald-500 pulse-dot{% else %}bg-gray-700{% endif %}"></span><span class="font-bold text-red-400 text-sm">{{ user.username }}</span>{% if user.is_ssh_online %}<span class="text-[9px] bg-emerald-900/40 text-emerald-400 px-1.5 py-0.5 rounded">SSH</span>{% endif %}{% if user.is_xray_online %}<span class="text-[9px] bg-purple-900/40 text-purple-400 px-1.5 py-0.5 rounded">V2R</span>{% endif %}</div>{% if user.status==1 %}<span class="text-[10px] text-emerald-400">فعال</span>{% else %}<span class="text-[10px] text-red-400">غیرفعال</span>{% endif %}</div><div class="grid grid-cols-2 gap-2 text-[10px] mb-2"><div><span class="text-red-400/50">پسورد:</span><span class="text-red-300 font-mono mr-1">{{ user.password }}</span></div><div><span class="text-red-400/50">دستگاه:</span><span class="text-emerald-400 font-mono mr-1">{{ user.online_count }}/{{ user.max_connections }}</span></div><div><span class="text-red-400/50">مصرف:</span><span class="text-amber-400 mr-1">{{ user.used_traffic }}/{{ user.total_traffic }}GB</span></div><div><span class="text-red-400/50">انقضا:</span><span class="text-red-300/70 mr-1">{{ user.expire_date }}</span></div></div><div class="w-full bg-red-900/30 h-1 rounded-full overflow-hidden mb-3"><div class="progress-bar h-1 rounded-full" style="width:{{ (user.used_traffic/user.total_traffic*100)|int if user.total_traffic>0 else 0 }}%"></div></div><div class="flex gap-2"><a href="/sub/{{ user.username }}" target="_blank" class="flex-1 text-center py-2 bg-blue-900/20 text-blue-400 rounded-lg text-xs"><i class="fa-solid fa-link"></i> اشتراک</a><button onclick="openEdit('{{ user.username }}','{{ user.password }}','{{ user.total_traffic }}','{{ user.max_connections }}','{{ user.status }}','{{ user.expire_date }}')" class="flex-1 py-2 bg-amber-900/20 text-amber-400 rounded-lg text-xs"><i class="fa-solid fa-pen"></i> ویرایش</button><a href="/delete_user/{{ user.username }}" onclick="return confirm('حذف؟')" class="flex-1 text-center py-2 bg-red-900/30 text-red-400 rounded-lg text-xs"><i class="fa-solid fa-trash"></i></a></div></div>{% endfor %}</div></div></main>

<!-- EDIT MODAL -->
<div id="editModal" class="fixed inset-0 bg-black/90 backdrop-blur-sm items-center justify-center z-50 p-4" style="display:none">
  <div class="glass rounded-3xl w-full max-w-lg p-6 shadow-2xl border border-red-900/50 max-h-[90vh] overflow-y-auto">
    <div class="flex items-center justify-between mb-6">
      <h3 class="text-lg font-bold text-red-400"><i class="fa-solid fa-user-pen ml-1"></i>ویرایش کاربر <span id="edit_username_label" class="text-emerald-400"></span></h3>
      <button onclick="closeEdit()" class="text-red-400/70 hover:text-red-400"><i class="fa-solid fa-xmark text-xl"></i></button>
    </div>
    <form action="/edit_user" method="POST" class="space-y-4">
      <input type="hidden" name="username" id="edit_username">
      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="block text-xs text-red-400/70 mb-1.5">کلمه عبور</label>
          <input type="text" name="password" id="edit_password" required class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 font-mono text-sm outline-none focus:border-red-500">
        </div>
        <div>
          <label class="block text-xs text-red-400/70 mb-1.5">وضعیت</label>
          <select name="status" id="edit_status" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 text-sm outline-none focus:border-red-500">
            <option value="1">فعال</option>
            <option value="0">غیرفعال</option>
          </select>
        </div>
      </div>
      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="block text-xs text-red-400/70 mb-1.5">حجم کل (GB)</label>
          <input type="number" step="0.1" name="traffic_gb" id="edit_traffic" required class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 font-mono text-sm outline-none focus:border-red-500">
        </div>
        <div>
          <label class="block text-xs text-red-400/70 mb-1.5">حداکثر دستگاه (IP)</label>
          <input type="number" name="max_connections" id="edit_connections" required class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 font-mono text-sm outline-none focus:border-red-500">
        </div>
      </div>
      <div>
        <label class="block text-xs text-red-400/70 mb-1.5">تاریخ انقضا (فعلی)</label>
        <input type="text" name="expire_date" id="edit_expire" required class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 font-mono text-sm outline-none focus:border-red-500" placeholder="YYYY-MM-DD HH:MM">
      </div>
      <div class="border-t border-red-900/30 pt-4">
        <h4 class="text-sm font-bold text-amber-400 mb-3"><i class="fa-solid fa-rotate ml-1"></i>عملیات ریست (اختیاری)</h4>
        <div class="space-y-3">
          <label class="flex items-center gap-3 bg-black/50 border border-red-900/30 p-3 rounded-xl cursor-pointer hover:bg-red-900/10 transition">
            <input type="checkbox" name="reset_traffic" id="reset_traffic" class="w-4 h-4 text-red-600 rounded">
            <div class="flex-1">
              <span class="text-sm text-red-300 font-bold block">♻️ صفر کردن مصرف ترافیک</span>
              <span class="text-[10px] text-red-400/50">مصرف کاربر به 0 برمی‌گردد (برای شارژ مجدد)</span>
            </div>
          </label>
          <div class="bg-black/50 border border-red-900/30 p-3 rounded-xl">
            <label class="flex items-center gap-3 cursor-pointer">
              <input type="checkbox" name="reset_expire" id="reset_expire" class="w-4 h-4 text-red-600 rounded" onchange="toggleResetDays()">
              <div class="flex-1">
                <span class="text-sm text-red-300 font-bold block">📅 ریست تاریخ انقضا</span>
                <span class="text-[10px] text-red-400/50">تاریخ انقضا از همین الان محاسبه می‌شود</span>
              </div>
            </label>
            <div id="reset_days_box" class="mt-3 mr-7" style="display:none">
              <label class="block text-xs text-amber-400/70 mb-1.5">تعداد روز از الان:</label>
              <input type="number" name="reset_days" id="reset_days" value="30" min="1" class="w-32 bg-black border border-amber-900/50 rounded-lg p-2 text-amber-300 text-center text-sm outline-none focus:border-amber-500">
            </div>
          </div>
          <div class="bg-black/50 border border-red-900/30 p-3 rounded-xl">
            <label class="block text-sm text-red-300 font-bold mb-2">➕ تمدید تاریخ فعلی</label>
            <div class="flex items-center gap-2">
              <input type="number" name="extend_days" id="extend_days" value="0" min="0" class="w-24 bg-black border border-emerald-900/50 rounded-lg p-2 text-emerald-300 text-center text-sm outline-none focus:border-emerald-500">
              <span class="text-xs text-emerald-400/70">روز به تاریخ فعلی اضافه شود</span>
            </div>
          </div>
        </div>
      </div>
      <div class="flex justify-end gap-3 pt-4 border-t border-red-900/30">
        <button type="button" onclick="closeEdit()" class="px-5 py-2.5 bg-red-900/30 text-red-400 rounded-xl text-sm">انصراف</button>
        <button type="submit" class="px-5 py-2.5 bg-gradient-to-r from-red-700 to-red-900 text-red-100 rounded-xl text-sm font-bold border border-red-500/30"><i class="fa-solid fa-save ml-1"></i>ذخیره</button>
      </div>
    </form>
  </div>
</div>

<script>
function openEdit(u,p,t,c,s,e){
  document.getElementById('edit_username').value=u;
  document.getElementById('edit_username_label').textContent=u;
  document.getElementById('edit_password').value=p;
  document.getElementById('edit_traffic').value=t;
  document.getElementById('edit_connections').value=c;
  document.getElementById('edit_expire').value=e;
  document.getElementById('edit_status').value=s;
  document.getElementById('reset_traffic').checked=false;
  document.getElementById('reset_expire').checked=false;
  document.getElementById('extend_days').value=0;
  document.getElementById('reset_days_box').style.display='none';
  document.getElementById('editModal').style.display='flex';
}
function closeEdit(){document.getElementById('editModal').style.display='none'}
function toggleResetDays(){var c=document.getElementById('reset_expire').checked;document.getElementById('reset_days_box').style.display=c?'block':'none'}
setInterval(function(){fetch('/api/stats').then(r=>r.json()).then(d=>{document.getElementById('cpu_value').textContent=d.cpu;document.getElementById('ram_value').textContent=d.ram}).catch(()=>{});},3000);
function filterUsers(){var q=document.getElementById('searchBox').value.toLowerCase();var sf=document.getElementById('statusFilter').value;var rows=document.querySelectorAll('tbody tr[data-username], .mobile-card [data-username]');rows.forEach(function(r){var u=r.getAttribute('data-username')||'';var on=r.getAttribute('data-online')==='1';var st=r.getAttribute('data-status');var show=true;if(q&&!u.includes(q))show=false;if(sf==='online'&&!on)show=false;if(sf==='offline'&&on)show=false;if(sf==='active'&&st!=='1')show=false;if(sf==='inactive'&&st!=='0')show=false;r.style.display=show?'':'none';});}
document.getElementById('searchBox').addEventListener('input',filterUsers);
document.getElementById('statusFilter').addEventListener('change',filterUsers);
</script></body></html>
EOF

# ---------- add_user.html ----------
cat << 'EOF' > /root/ssh-panel/templates/add_user.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>کاربر جدید | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:radial-gradient(circle at top,#1a0000 0%,#000 60%);color:#f3f4f6;min-height:100vh}.glass{background:rgba(20,0,0,0.85);border:1px solid rgba(255,0,0,0.15)}</style></head><body class="min-h-screen"><nav class="glass px-4 md:px-6 py-3 border-b border-red-900/30 sticky top-0 z-10"><div class="max-w-7xl mx-auto flex justify-between items-center"><h1 class="text-base md:text-lg font-bold text-red-400"><i class="fa-solid fa-user-plus ml-1"></i>ایجاد اکانت SSH</h1><a href="/dashboard" class="px-4 py-2 glass rounded-xl text-red-300 text-sm hover:bg-red-900/20"><i class="fa-solid fa-arrow-right ml-1"></i>بازگشت</a></div></nav><main class="p-4 md:p-6 max-w-xl mx-auto mt-6"><div class="glass rounded-3xl p-6 md:p-8 shadow-2xl"><div class="text-center mb-6"><div class="w-16 h-16 mx-auto bg-gradient-to-br from-red-700 to-red-900 rounded-2xl flex items-center justify-center border border-red-500/30 mb-3"><i class="fa-solid fa-user-plus text-2xl text-red-100"></i></div><p class="text-xs text-red-400/60">اطلاعات کاربر جدید را وارد کنید</p></div><form action="/add_user" method="POST" class="space-y-5"><div><label class="block text-sm text-red-400/70 mb-2"><i class="fa-solid fa-user ml-1"></i>نام کاربری</label><input type="text" name="username" required pattern="[a-zA-Z0-9_\-]+" class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 font-mono outline-none focus:border-red-500 transition" dir="ltr" placeholder="username" autocomplete="off"></div><div><label class="block text-sm text-red-400/70 mb-2"><i class="fa-solid fa-lock ml-1"></i>کلمه عبور</label><input type="text" name="password" required class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 font-mono outline-none focus:border-red-500 transition" dir="ltr" placeholder="password" autocomplete="off"></div><div class="grid grid-cols-3 gap-3"><div><label class="block text-xs text-red-400/70 mb-2">مدت (روز)</label><input type="number" name="expire_days" value="30" min="1" class="w-full bg-black border border-red-900/50 rounded-2xl p-3 text-red-300 text-center outline-none focus:border-red-500"></div><div><label class="block text-xs text-red-400/70 mb-2">حجم (GB)</label><input type="number" step="0.1" name="traffic_gb" value="50" min="0.1" class="w-full bg-black border border-red-900/50 rounded-2xl p-3 text-red-300 text-center outline-none focus:border-red-500"></div><div><label class="block text-xs text-red-400/70 mb-2">حداکثر دستگاه</label><input type="number" name="max_connections" value="3" min="1" class="w-full bg-black border border-red-900/50 rounded-2xl p-3 text-red-300 text-center outline-none focus:border-red-500"></div></div><button type="submit" class="w-full bg-gradient-to-r from-red-700 to-red-900 hover:from-red-600 hover:to-red-800 py-4 rounded-2xl font-bold text-red-100 shadow-lg border border-red-500/30 transition"><i class="fa-solid fa-circle-plus ml-2"></i>ساخت اکانت</button></form></div></main></body></html>
EOF

# ---------- inbounds.html ----------
cat << 'EOF' > /root/ssh-panel/templates/inbounds.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>اینباندها | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);backdrop-filter:blur(20px);border:1px solid rgba(255,0,0,0.15)}.nav-link{transition:all 0.2s}.nav-link:hover{background:rgba(220,38,38,0.15);color:#f87171}.nav-link.active{background:rgba(220,38,38,0.25);color:#f87171;border:1px solid rgba(220,38,38,0.4)}.badge{font-size:10px;padding:3px 10px;border-radius:20px;font-weight:bold}</style></head><body class="min-h-screen"><nav class="glass sticky top-0 z-50 px-4 md:px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex items-center justify-between flex-wrap gap-3"><div class="flex items-center gap-3"><div class="w-10 h-10 bg-gradient-to-br from-red-700 to-red-900 rounded-xl flex items-center justify-center shadow-lg border border-red-500/30"><span class="text-lg font-black text-red-100">OP</span></div><h1 class="text-base md:text-lg font-bold text-red-400">اینباندها</h1></div><div class="flex items-center gap-2 text-xs"><span class="bg-red-900/20 px-3 py-1 rounded-full border border-red-800/30"><i class="fa-solid fa-microchip text-red-500"></i> <span id="cpu_value">{{ cpu }}</span>%</span><span class="bg-red-900/20 px-3 py-1 rounded-full border border-red-800/30"><i class="fa-solid fa-memory text-red-400"></i> <span id="ram_value">{{ ram }}</span>%</span></div><div class="flex items-center gap-1.5 flex-wrap"><a href="/dashboard" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs">داشبورد</a><a href="/inbounds" class="nav-link active px-3 py-1.5 rounded-lg text-xs font-bold">اینباند</a><a href="/groups" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs">گروه‌ها</a><a href="/add_inbound_page" class="px-3 py-1.5 bg-gradient-to-r from-red-700 to-red-900 rounded-lg text-red-100 text-xs font-bold border border-red-500/30"><i class="fa-solid fa-plus ml-1"></i>اینباند</a><a href="/settings" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs"><i class="fa-solid fa-gear"></i></a><a href="/logout" class="px-3 py-1.5 bg-red-900/30 text-red-400 rounded-lg border border-red-800/50 text-xs"><i class="fa-solid fa-right-from-bracket"></i></a></div></div></nav><main class="p-3 md:p-6 max-w-7xl mx-auto">{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, message in messages %}<div class="{% if category == 'success' %}bg-emerald-900/30 border border-emerald-700/50 text-emerald-400{% else %}bg-red-900/30 border border-red-700/50 text-red-400{% endif %} p-4 rounded-2xl text-sm mb-4">{{ message }}</div>{% endfor %}{% endif %}{% endwith %}<div class="glass rounded-2xl p-3 md:p-4 overflow-hidden"><div class="overflow-x-auto"><table class="w-full text-right text-sm"><thead><tr class="bg-black/50 text-red-400/70 text-xs"><th class="p-4">Tag</th><th class="p-4">پروتکل</th><th class="p-4">پورت</th><th class="p-4">شبکه</th><th class="p-4">امنیت</th><th class="p-4">SNI/FP</th><th class="p-4 text-center">کلاینت</th><th class="p-4 text-center">عملیات</th></tr></thead><tbody class="divide-y divide-red-900/20">{% for ib in inbounds %}<tr class="hover:bg-red-900/10 transition"><td class="p-4 font-bold text-red-400">{{ ib.tag }}</td><td class="p-4"><span class="badge {% if ib.protocol=='vless' %}bg-blue-900/30 text-blue-400{% elif ib.protocol=='vmess' %}bg-purple-900/30 text-purple-400{% elif ib.protocol=='trojan' %}bg-amber-900/30 text-amber-400{% else %}bg-gray-900/30 text-gray-400{% endif %}">{{ ib.protocol|upper }}</span></td><td class="p-4 text-red-300 font-mono">{{ ib.port }}</td><td class="p-4 text-red-400/70 text-xs">{{ ib.network|upper }}</td><td class="p-4">{% if ib.security=='reality' %}<span class="text-emerald-400 text-xs">🔒 Reality</span>{% elif ib.security=='tls' %}<span class="text-blue-400 text-xs">🔐 TLS</span>{% else %}<span class="text-gray-500 text-xs">—</span>{% endif %}</td><td class="p-4 text-[10px] text-red-400/50">{% if ib.security!='none' %}{{ ib.server_name }}/{{ ib.fingerprint }}{% else %}—{% endif %}</td><td class="p-4 text-center"><a href="/clients/{{ ib.id }}" class="px-3 py-1 bg-red-900/20 text-red-400 rounded-lg text-xs font-bold border border-red-800/30">{{ ib.client_count }}</a></td><td class="p-4 text-center"><div class="inline-flex gap-1.5"><a href="/clients/{{ ib.id }}" class="p-2 bg-blue-900/20 text-blue-400 border border-blue-800/30 rounded-xl text-xs" title="کلاینت‌ها"><i class="fa-solid fa-users"></i></a><a href="/delete_inbound/{{ ib.id }}" onclick="return confirm('حذف {{ ib.tag }}?')" class="p-2 bg-red-900/30 text-red-400 border border-red-700/50 rounded-xl text-xs" title="حذف"><i class="fa-solid fa-trash"></i></a></div></td></tr>{% endfor %}</tbody></table></div></div></main><script>setInterval(function(){fetch('/api/stats').then(r=>r.json()).then(d=>{document.getElementById('cpu_value').textContent=d.cpu;document.getElementById('ram_value').textContent=d.ram}).catch(()=>{});},3000);</script></body></html>
EOF

# ---------- add_inbound.html ----------
cat << 'EOF' > /root/ssh-panel/templates/add_inbound.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>اینباند جدید | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;500;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);backdrop-filter:blur(20px);border:1px solid rgba(255,0,0,0.15)}.fp-btn{transition:all 0.2s}.fp-btn:hover{background:rgba(220,38,38,0.2);border-color:rgba(220,38,38,0.4)}.fp-btn.active{background:rgba(220,38,38,0.3);border-color:#dc2626;color:#f87171}</style></head><body class="min-h-screen pb-20"><nav class="glass sticky top-0 z-50 px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex justify-between items-center"><div class="flex items-center gap-3"><div class="w-10 h-10 bg-gradient-to-br from-red-700 to-red-900 rounded-xl flex items-center justify-center shadow-lg border border-red-500/30"><span class="text-lg font-black text-red-100">OP</span></div><h1 class="text-base md:text-lg font-bold text-red-400">ساخت اینباند جدید</h1></div><a href="/inbounds" class="px-4 py-2 glass rounded-xl text-red-300 text-sm"><i class="fa-solid fa-arrow-right ml-1"></i>بازگشت</a></div></nav><main class="p-4 md:p-6 max-w-5xl mx-auto"><form action="/add_inbound" method="POST"><div class="space-y-6"><div class="glass rounded-3xl p-6"><h3 class="text-lg font-bold text-red-400 mb-4"><i class="fa-solid fa-info-circle ml-1"></i>اطلاعات پایه</h3><div class="grid grid-cols-1 md:grid-cols-3 gap-4"><div><label class="block text-xs font-bold text-red-400/70 mb-2">نام (Tag)</label><input type="text" name="tag" required class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 font-mono text-sm outline-none focus:border-red-500" dir="ltr" placeholder="inbound-1"></div><div><label class="block text-xs font-bold text-red-400/70 mb-2">پروتکل</label><select name="protocol" class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 text-sm outline-none focus:border-red-500"><option value="vless">VLESS</option><option value="vmess">VMess</option><option value="trojan">Trojan</option></select></div><div><label class="block text-xs font-bold text-red-400/70 mb-2">پورت <span class="text-emerald-400 text-[10px]">(رندوم)</span></label><div class="flex gap-2"><input type="number" name="port" id="port_input" value="{{ random_port }}" class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 text-center text-sm outline-none focus:border-red-500"><button type="button" onclick="randomPort()" class="px-4 py-3 bg-emerald-900/30 text-emerald-400 rounded-2xl border border-emerald-700/50 hover:bg-emerald-800/40" title="پورت جدید"><i class="fa-solid fa-shuffle"></i></button></div></div></div></div><div class="glass rounded-3xl p-6"><h3 class="text-lg font-bold text-red-400 mb-4"><i class="fa-solid fa-network-wired ml-1"></i>انتقال</h3><div class="grid grid-cols-2 gap-4"><div><label class="block text-xs font-bold text-red-400/70 mb-2">نوع</label><select name="network" class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 text-sm"><option value="tcp">TCP</option><option value="ws">WebSocket</option><option value="grpc">gRPC</option></select></div><div><label class="block text-xs font-bold text-red-400/70 mb-2">Path</label><input type="text" name="path" value="/" class="w-full bg-black border border-red-900/50 rounded-2xl p-3.5 text-red-300 font-mono text-sm" dir="ltr"></div></div></div><div class="glass rounded-3xl p-6"><h3 class="text-lg font-bold text-red-400 mb-4"><i class="fa-solid fa-shield-halved ml-1"></i>امنیت</h3><div class="grid grid-cols-3 gap-3 mb-6"><label class="cursor-pointer"><input type="radio" name="security" value="none" class="hidden peer" checked><div class="glass rounded-2xl p-4 border-2 border-transparent peer-checked:border-red-500 text-center transition"><span class="text-sm font-bold text-gray-400">بدون</span></div></label><label class="cursor-pointer"><input type="radio" name="security" value="tls" class="hidden peer"><div class="glass rounded-2xl p-4 border-2 border-transparent peer-checked:border-blue-500 text-center transition"><span class="text-sm font-bold text-blue-400">TLS</span></div></label><label class="cursor-pointer"><input type="radio" name="security" value="reality" class="hidden peer"><div class="glass rounded-2xl p-4 border-2 border-transparent peer-checked:border-emerald-500 text-center transition"><span class="text-sm font-bold text-emerald-400">Reality</span></div></label></div><div id="security_settings" style="display:none"><div class="bg-black border border-red-900/50 rounded-2xl p-5 mb-4"><h4 class="text-sm font-bold text-red-400 mb-3">Server Name (SNI)</h4><div class="grid grid-cols-2 md:grid-cols-4 gap-2 mb-3"><button type="button" onclick="setSNI('www.microsoft.com')" class="px-3 py-2 bg-gray-900/50 hover:bg-blue-900/30 border border-gray-700/30 rounded-xl text-xs text-gray-300">Microsoft</button><button type="button" onclick="setSNI('www.google.com')" class="px-3 py-2 bg-gray-900/50 hover:bg-blue-900/30 border border-gray-700/30 rounded-xl text-xs text-gray-300">Google</button><button type="button" onclick="setSNI('www.cloudflare.com')" class="px-3 py-2 bg-gray-900/50 hover:bg-blue-900/30 border border-gray-700/30 rounded-xl text-xs text-gray-300">Cloudflare</button><button type="button" onclick="setSNI('www.amazon.com')" class="px-3 py-2 bg-gray-900/50 hover:bg-blue-900/30 border border-gray-700/30 rounded-xl text-xs text-gray-300">Amazon</button></div><input type="text" id="sni_input" name="server_name" value="www.microsoft.com" class="w-full bg-black border border-red-900/50 rounded-2xl p-3 text-red-300 font-mono text-sm" dir="ltr"></div><div class="bg-black border border-red-900/50 rounded-2xl p-5 mb-4"><h4 class="text-sm font-bold text-red-400 mb-3">Short ID (اختیاری)</h4><input type="text" name="short_id" class="w-full bg-black border border-red-900/50 rounded-2xl p-3 text-red-300 font-mono text-sm" dir="ltr" placeholder="hex string" maxlength="16"></div><div class="bg-black border border-red-900/50 rounded-2xl p-5"><h4 class="text-sm font-bold text-red-400 mb-3">Fingerprint</h4><div class="grid grid-cols-3 md:grid-cols-5 gap-2 mb-3"><button type="button" onclick="setFP('chrome')" class="fp-btn active px-3 py-2 bg-blue-900/20 text-blue-400 border border-blue-700/50 rounded-xl text-xs" id="fp_chrome">Chrome</button><button type="button" onclick="setFP('firefox')" class="fp-btn px-3 py-2 bg-orange-900/20 text-orange-400 border border-orange-700/30 rounded-xl text-xs" id="fp_firefox">Firefox</button><button type="button" onclick="setFP('safari')" class="fp-btn px-3 py-2 bg-gray-800/50 text-gray-400 border border-gray-700/30 rounded-xl text-xs" id="fp_safari">Safari</button><button type="button" onclick="setFP('edge')" class="fp-btn px-3 py-2 bg-gray-800/50 text-gray-400 border border-gray-700/30 rounded-xl text-xs" id="fp_edge">Edge</button><button type="button" onclick="setFP('random')" class="fp-btn px-3 py-2 bg-amber-900/20 text-amber-400 border border-amber-700/30 rounded-xl text-xs" id="fp_random">Random</button></div><input type="hidden" name="fingerprint" id="fp_input" value="chrome"><div class="text-xs text-red-400/50">انتخاب: <span id="fp_display" class="text-red-400 font-mono">chrome</span></div></div></div></div><button type="submit" class="w-full bg-gradient-to-r from-red-700 via-red-800 to-red-950 py-4 rounded-2xl font-bold text-red-100 text-lg shadow-2xl border border-red-500/30 hover:from-red-600 transition"><i class="fa-solid fa-circle-plus ml-2"></i>ساخت اینباند</button></div></form></main><script>
function randomPort(){document.getElementById('port_input').value=Math.floor(Math.random()*55000+10000)}
function setSNI(s){document.getElementById('sni_input').value=s}
function setFP(f){document.getElementById('fp_input').value=f;document.getElementById('fp_display').textContent=f;document.querySelectorAll('.fp-btn').forEach(b=>b.classList.remove('active'));const btn=document.getElementById('fp_'+f);if(btn)btn.classList.add('active')}
document.querySelectorAll('input[name=security]').forEach(r=>r.addEventListener('change',()=>{document.getElementById('security_settings').style.display=r.value==='none'?'none':'block'}));
</script></body></html>
EOF

# ---------- clients.html ----------
cat << 'EOF' > /root/ssh-panel/templates/clients.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>کلاینت‌ها | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);backdrop-filter:blur(20px);border:1px solid rgba(255,0,0,0.15)}.link-box{transition:all 0.3s;cursor:pointer}.link-box:hover{transform:translateY(-2px);box-shadow:0 10px 30px rgba(220,38,38,0.2)}.copied{position:fixed;top:20px;left:50%;transform:translateX(-50%);background:#10b981;color:#fff;padding:10px 24px;border-radius:20px;font-size:13px;z-index:999}</style></head><body class="min-h-screen"><nav class="glass sticky top-0 z-50 px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex items-center justify-between"><div class="flex items-center gap-3"><div class="w-10 h-10 bg-gradient-to-br from-red-700 to-red-900 rounded-xl flex items-center justify-center border border-red-500/30"><span class="text-lg font-black text-red-100">OP</span></div><h1 class="text-base md:text-lg font-bold text-red-400">کلاینت‌های {{ inbound.tag }}</h1></div><a href="/inbounds" class="px-4 py-2 bg-red-900/20 text-red-400 rounded-xl text-xs border border-red-800/30"><i class="fa-solid fa-arrow-right ml-1"></i>بازگشت</a></div></nav><main class="p-4 md:p-6 max-w-5xl mx-auto">{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, message in messages %}<div class="{% if category == 'success' %}bg-emerald-900/30 border border-emerald-700/50 text-emerald-400{% else %}bg-red-900/30 border border-red-700/50 text-red-400{% endif %} p-4 rounded-2xl text-sm mb-4">{{ message }}</div>{% endfor %}{% endif %}{% endwith %}{% if available_users %}<div class="glass rounded-2xl p-4 mb-4"><h3 class="text-sm font-bold text-red-400 mb-3"><i class="fa-solid fa-user-plus ml-1"></i>افزودن کاربر</h3><form action="/add_clients/{{ inbound.id }}" method="POST"><div class="grid grid-cols-2 md:grid-cols-4 gap-2 mb-3 max-h-40 overflow-y-auto">{% for uname in available_users %}<label class="flex items-center gap-2 bg-black border border-red-900/30 p-2 rounded-xl cursor-pointer hover:bg-red-900/10"><input type="checkbox" name="usernames" value="{{ uname }}" class="text-red-600 rounded"><span class="text-xs text-red-300">{{ uname }}</span></label>{% endfor %}</div><button type="submit" class="px-5 py-2 bg-gradient-to-r from-red-700 to-red-900 text-red-100 text-xs font-bold rounded-xl border border-red-500/30">افزودن انتخاب‌شده‌ها</button></form></div>{% endif %}<div class="space-y-3">{% for cl in clients %}<div class="glass rounded-2xl p-4"><div class="flex items-center justify-between mb-3"><div class="flex items-center gap-2"><span class="font-bold text-red-400">{{ cl.username }}</span><span class="text-[10px] text-red-400/50 font-mono">{{ cl.uuid[:16] }}…</span></div><a href="/delete_client/{{ cl.id }}" onclick="return confirm('حذف {{ cl.username }} از این اینباند؟')" class="p-2 bg-red-900/30 text-red-400 border border-red-700/50 rounded-xl text-xs"><i class="fa-solid fa-trash"></i></a></div><div class="link-box bg-black border border-red-900/30 rounded-xl p-3 relative" onclick="copyLink(this, '{{ cl.link }}')"><code class="text-xs text-red-300 break-all block" dir="ltr">{{ cl.link }}</code><div class="mt-1 text-[10px] text-red-600"><i class="fa-solid fa-copy ml-1"></i>کلیک برای کپی</div></div></div>{% endfor %}{% if not clients %}<div class="glass rounded-2xl p-8 text-center"><i class="fa-solid fa-inbox text-4xl text-red-900/50 mb-3"></i><p class="text-red-400/70 text-sm">هیچ کلاینتی برای این اینباند وجود ندارد</p></div>{% endif %}</div></main><script>
function copyLink(el, text){navigator.clipboard.writeText(text).then(()=>{var t=document.createElement('div');t.className='copied';t.innerHTML='✓ کپی شد!';document.body.appendChild(t);setTimeout(()=>t.remove(),2000)})}
</script></body></html>
EOF

# ---------- groups.html ----------
cat << 'EOF' > /root/ssh-panel/templates/groups.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>گروه‌ها | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);backdrop-filter:blur(20px);border:1px solid rgba(255,0,0,0.15)}.nav-link{transition:all 0.2s}.nav-link:hover{background:rgba(220,38,38,0.15);color:#f87171}.nav-link.active{background:rgba(220,38,38,0.25);color:#f87171;border:1px solid rgba(220,38,38,0.4)}</style></head><body class="min-h-screen"><nav class="glass sticky top-0 z-50 px-4 md:px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex items-center justify-between flex-wrap gap-3"><div class="flex items-center gap-3"><div class="w-10 h-10 bg-gradient-to-br from-red-700 to-red-900 rounded-xl flex items-center justify-center border border-red-500/30"><span class="text-lg font-black text-red-100">OP</span></div><h1 class="text-base md:text-lg font-bold text-red-400">مدیریت گروه‌ها</h1></div><div class="flex items-center gap-2 text-xs"><span class="bg-red-900/20 px-3 py-1 rounded-full"><i class="fa-solid fa-microchip text-red-500"></i> <span id="cpu_value">{{ cpu }}</span>%</span><span class="bg-red-900/20 px-3 py-1 rounded-full"><i class="fa-solid fa-memory text-red-400"></i> <span id="ram_value">{{ ram }}</span>%</span></div><div class="flex items-center gap-1.5"><a href="/dashboard" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs">داشبورد</a><a href="/inbounds" class="nav-link px-3 py-1.5 rounded-lg text-red-300/70 text-xs">اینباند</a><a href="/groups" class="nav-link active px-3 py-1.5 rounded-lg text-xs font-bold">گروه‌ها</a><a href="/logout" class="px-3 py-1.5 bg-red-900/30 text-red-400 rounded-lg border border-red-800/50 text-xs"><i class="fa-solid fa-right-from-bracket"></i></a></div></div></nav><main class="p-4 max-w-4xl mx-auto">{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, message in messages %}<div class="{% if category == 'success' %}bg-emerald-900/30 border border-emerald-700/50 text-emerald-400{% else %}bg-red-900/30 border border-red-700/50 text-red-400{% endif %} p-4 rounded-2xl text-sm mb-4">{{ message }}</div>{% endfor %}{% endif %}{% endwith %}<div class="glass rounded-2xl p-4 mb-4"><h3 class="text-sm font-bold text-red-400 mb-3"><i class="fa-solid fa-plus ml-1"></i>گروه جدید</h3><form action="/add_group" method="POST" class="flex flex-col md:flex-row gap-3 items-end"><div class="flex-1 w-full"><label class="block text-xs text-red-400/70 mb-1.5">نام گروه</label><input type="text" name="name" required class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 text-sm outline-none focus:border-red-500" placeholder="VIP"></div><div class="flex-1 w-full"><label class="block text-xs text-red-400/70 mb-1.5">توضیحات</label><input type="text" name="description" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 text-sm outline-none focus:border-red-500" placeholder="اختیاری"></div><button type="submit" class="px-6 py-3 bg-gradient-to-r from-red-700 to-red-900 text-red-100 text-sm font-bold rounded-xl border border-red-500/30">ایجاد</button></form></div><div class="glass rounded-2xl p-4"><table class="w-full text-right text-sm"><thead><tr class="bg-black/50 text-red-400/70 text-xs"><th class="p-4">نام</th><th class="p-4">توضیحات</th><th class="p-4">اعضا</th><th class="p-4 text-center">عملیات</th></tr></thead><tbody class="divide-y divide-red-900/20">{% for g in groups %}<tr class="hover:bg-red-900/10"><td class="p-4 font-bold text-red-400">{{ g.name }}</td><td class="p-4 text-red-300/70 text-xs">{{ g.description or '—' }}</td><td class="p-4"><span class="px-3 py-1 bg-red-900/20 text-red-400 rounded-lg text-xs">{{ g.member_count }}</span></td><td class="p-4 text-center"><div class="inline-flex gap-1.5"><a href="/group_members/{{ g.id }}" class="p-2 bg-blue-900/20 text-blue-400 rounded-xl text-xs"><i class="fa-solid fa-users"></i></a><a href="/delete_group/{{ g.id }}" onclick="return confirm('حذف گروه {{ g.name }}؟')" class="p-2 bg-red-900/30 text-red-400 rounded-xl text-xs"><i class="fa-solid fa-trash"></i></a></div></td></tr>{% endfor %}{% if not groups %}<tr><td colspan="4" class="p-8 text-center text-red-400/60 text-sm">گروهی وجود ندارد</td></tr>{% endif %}</tbody></table></div></main><script>setInterval(function(){fetch('/api/stats').then(r=>r.json()).then(d=>{document.getElementById('cpu_value').textContent=d.cpu;document.getElementById('ram_value').textContent=d.ram}).catch(()=>{});},3000);</script></body></html>
EOF

# ---------- group_members.html ----------
cat << 'EOF' > /root/ssh-panel/templates/group_members.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>اعضای {{ group.name }}</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);border:1px solid rgba(255,0,0,0.15)}</style></head><body class="min-h-screen"><nav class="glass sticky top-0 z-50 px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex items-center justify-between"><div class="flex items-center gap-3"><div class="w-10 h-10 bg-gradient-to-br from-red-700 to-red-900 rounded-xl flex items-center justify-center border border-red-500/30"><span class="text-lg font-black text-red-100">OP</span></div><h1 class="text-base md:text-lg font-bold text-red-400">اعضای {{ group.name }}</h1></div><a href="/groups" class="px-4 py-2 bg-red-900/20 text-red-400 rounded-xl text-xs border border-red-800/30"><i class="fa-solid fa-arrow-right ml-1"></i>بازگشت</a></div></nav><main class="p-4 max-w-4xl mx-auto">{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, message in messages %}<div class="{% if category == 'success' %}bg-emerald-900/30 border border-emerald-700/50 text-emerald-400{% else %}bg-red-900/30 border border-red-700/50 text-red-400{% endif %} p-4 rounded-2xl text-sm mb-4">{{ message }}</div>{% endfor %}{% endif %}{% endwith %}{% if available_users %}<div class="glass rounded-2xl p-4 mb-4"><h3 class="text-sm font-bold text-red-400 mb-3"><i class="fa-solid fa-user-plus ml-1"></i>افزودن عضو</h3><form action="/add_group_members/{{ group.id }}" method="POST"><div class="grid grid-cols-2 md:grid-cols-4 gap-2 mb-3 max-h-40 overflow-y-auto">{% for uname in available_users %}<label class="flex items-center gap-2 bg-black border border-red-900/30 p-2 rounded-xl cursor-pointer"><input type="checkbox" name="usernames" value="{{ uname }}" class="text-red-600 rounded"><span class="text-xs text-red-300">{{ uname }}</span></label>{% endfor %}</div><button type="submit" class="px-5 py-2 bg-gradient-to-r from-red-700 to-red-900 text-red-100 text-xs font-bold rounded-xl border border-red-500/30">افزودن انتخاب‌شده‌ها</button></form></div>{% endif %}<div class="glass rounded-2xl p-4"><div class="grid grid-cols-2 md:grid-cols-4 gap-2">{% for uname in members %}<div class="flex items-center justify-between bg-black border border-red-900/30 p-3 rounded-xl"><span class="text-sm text-red-300">{{ uname }}</span><a href="/remove_group_member/{{ group.id }}/{{ uname }}" class="p-1.5 bg-red-900/30 text-red-400 rounded-lg text-xs hover:bg-red-900/50"><i class="fa-solid fa-xmark"></i></a></div>{% endfor %}{% if not members %}<p class="text-center text-red-400/60 text-sm col-span-4 py-4">گروه خالی است</p>{% endif %}</div></div></main></body></html>
EOF

# ---------- reports.html ----------
cat << 'EOF' > /root/ssh-panel/templates/reports.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>گزارشات | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);border:1px solid rgba(255,0,0,0.15)}.stat-card{transition:all 0.3s}.stat-card:hover{transform:translateY(-3px);box-shadow:0 10px 40px rgba(220,38,38,0.2)}</style></head><body class="min-h-screen"><nav class="glass sticky top-0 z-50 px-6 py-3 border-b border-red-900/30"><div class="max-w-7xl mx-auto flex justify-between items-center"><div class="flex items-center gap-3"><div class="w-10 h-10 bg-gradient-to-br from-red-700 to-red-900 rounded-xl flex items-center justify-center border border-red-500/30"><span class="text-lg font-black text-red-100">OP</span></div><h1 class="text-base md:text-lg font-bold text-red-400">گزارشات</h1></div><a href="/dashboard" class="px-4 py-2 bg-red-900/20 text-red-400 rounded-xl text-sm border border-red-800/30"><i class="fa-solid fa-arrow-right ml-1"></i>داشبورد</a></div></nav><main class="p-4 max-w-5xl mx-auto mt-6"><div class="grid grid-cols-2 md:grid-cols-4 gap-3"><div class="glass stat-card rounded-2xl p-5 text-center"><i class="fa-solid fa-users text-3xl text-red-500 mb-3"></i><span class="block text-[10px] text-red-400/50 uppercase mb-1">Total Users</span><span class="text-2xl font-black text-red-400">{{ summary.total_users }}</span></div><div class="glass stat-card rounded-2xl p-5 text-center"><i class="fa-solid fa-hard-drive text-3xl text-blue-400 mb-3"></i><span class="block text-[10px] text-blue-400/50 uppercase mb-1">Total GB</span><span class="text-2xl font-black text-blue-400">{{ summary.total_traffic_gb|round(2) }}</span></div><div class="glass stat-card rounded-2xl p-5 text-center"><i class="fa-solid fa-chart-line text-3xl text-purple-400 mb-3"></i><span class="block text-[10px] text-purple-400/50 uppercase mb-1">Used GB</span><span class="text-2xl font-black text-purple-400">{{ summary.used_traffic_gb|round(2) }}</span></div><div class="glass stat-card rounded-2xl p-5 text-center"><i class="fa-solid fa-server text-3xl text-emerald-400 mb-3"></i><span class="block text-[10px] text-emerald-400/50 uppercase mb-1">Inb/Cli</span><span class="text-2xl font-black text-emerald-400">{{ ib_count }}/{{ cl_count }}</span></div></div></main></body></html>
EOF

# ---------- sub_error.html ----------
cat << 'EOF' > /root/ssh-panel/templates/sub_error.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>خطا | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:radial-gradient(circle at top,#1a0000 0%,#000 60%);min-height:100vh}.glass{background:rgba(20,0,0,0.85);border:1px solid rgba(255,0,0,0.2);border-radius:24px}</style></head><body class="min-h-screen flex items-center justify-center p-4"><div class="glass p-8 max-w-md w-full text-center shadow-2xl"><div class="w-20 h-20 mx-auto bg-red-900/30 rounded-2xl flex items-center justify-center mb-4 border border-red-500/30"><i class="fa-solid fa-triangle-exclamation text-4xl text-red-500"></i></div><h1 class="text-xl font-bold text-red-400 mb-2">خطا</h1><p class="text-gray-400 text-sm mb-6 break-all">{{ error_message }}</p></div></body></html>
EOF

# ---------- settings.html ----------
cat << 'EOF' > /root/ssh-panel/templates/settings.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>تنظیمات | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;700&display=swap');*{font-family:'Vazirmatn',sans-serif}body{background:#000;color:#f3f4f6}.glass{background:rgba(20,0,0,0.8);border:1px solid rgba(255,0,0,0.15)}.btn{transition:all 0.2s;cursor:pointer}.btn:hover{transform:translateY(-1px)}</style></head><body class="min-h-screen"><nav class="glass sticky top-0 z-50 px-6 py-3 border-b border-red-900/30"><div class="max-w-4xl mx-auto flex justify-between items-center"><h1 class="text-base md:text-lg font-bold text-red-400"><i class="fa-solid fa-gear ml-1"></i>تنظیمات و پشتیبان‌گیری</h1><a href="/dashboard" class="px-4 py-2 bg-red-900/20 text-red-400 rounded-xl text-sm border border-red-800/30"><i class="fa-solid fa-arrow-right ml-1"></i>بازگشت</a></div></nav><main class="max-w-4xl mx-auto p-4 md:p-6 space-y-6">{% with messages = get_flashed_messages(with_categories=true) %}{% if messages %}{% for category, msg in messages %}<div class="p-4 rounded-xl text-center font-bold border text-sm {% if category == 'success' %}bg-emerald-900/40 text-emerald-400 border-emerald-800{% elif category == 'info' %}bg-blue-900/40 text-blue-400 border-blue-800{% else %}bg-red-900/40 text-red-400 border-red-900{% endif %}">{{ msg }}</div>{% endfor %}{% endif %}{% endwith %}<div class="glass rounded-2xl p-6"><h2 class="text-lg font-bold text-red-400 mb-4"><i class="fa-solid fa-database ml-1"></i>پشتیبان‌گیری و بازیابی</h2><div class="grid grid-cols-1 md:grid-cols-2 gap-4"><div class="bg-black/50 border border-red-900/30 p-5 rounded-xl flex flex-col justify-between"><div><h3 class="text-sm font-bold text-red-500 mb-2"><i class="fa-solid fa-download ml-1"></i>دانلود بکاپ</h3><p class="text-xs text-gray-500">دانلود فایل کامل دیتابیس</p></div><a href="/backup_download" class="btn w-full bg-red-700 hover:bg-red-600 text-white font-bold py-2.5 rounded-xl text-center mt-4 block"><i class="fa-solid fa-file-arrow-down ml-1"></i>دانلود</a></div><div class="bg-black/50 border border-red-900/30 p-5 rounded-xl flex flex-col justify-between"><div><h3 class="text-sm font-bold text-amber-500 mb-2"><i class="fa-solid fa-upload ml-1"></i>بازیابی بکاپ</h3><p class="text-xs text-gray-500">آپلود فایل بکاپ و جایگزینی</p></div><form action="/backup_upload" method="POST" enctype="multipart/form-data" class="mt-4 space-y-3"><input type="file" name="backup_file" accept=".db" required class="w-full text-xs text-gray-400 bg-black p-2 rounded-lg border border-red-900/30"><button type="submit" class="btn w-full bg-amber-600 hover:bg-amber-500 text-black font-bold py-2.5 rounded-xl text-center"><i class="fa-solid fa-cloud-arrow-up ml-1"></i>آپلود و بازیابی</button></form></div></div></div><div class="glass rounded-2xl p-6"><h2 class="text-lg font-bold text-red-400 mb-4"><i class="fa-solid fa-sliders ml-1"></i>تنظیمات پنل</h2><form action="/settings" method="POST" class="space-y-4"><input type="hidden" name="action" value="save_settings"><div class="grid grid-cols-1 md:grid-cols-2 gap-4"><div><label class="block text-xs text-red-400/70 mb-1.5">دامنه</label><input type="text" name="domain" value="{{ domain }}" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 font-mono text-sm outline-none focus:border-red-500" dir="ltr" placeholder="example.com"></div><div><label class="block text-xs text-red-400/70 mb-1.5">پورت پنل</label><input type="number" name="panel_port" value="{{ panel_port }}" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 text-sm outline-none focus:border-red-500"></div></div><div class="grid grid-cols-1 md:grid-cols-2 gap-4"><div><label class="block text-xs text-red-400/70 mb-1.5">نام کاربری ادمین</label><input type="text" name="admin_username" value="{{ admin_username }}" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 font-mono text-sm outline-none focus:border-red-500" dir="ltr"></div><div><label class="block text-xs text-red-400/70 mb-1.5">رمز جدید</label><input type="password" name="admin_password" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-300 text-sm outline-none focus:border-red-500" placeholder="خالی = بدون تغییر"></div></div><div class="flex items-center gap-3 mt-2"><input type="checkbox" name="block_iran" id="block_iran" class="text-red-600 rounded w-4 h-4" {% if block_iran_client == '1' %}checked{% endif %}><label for="block_iran" class="text-xs text-red-300">بلاک ترافیک خروجی به IPهای ایران (ورودی دست‌نخورده)</label></div><button type="submit" class="btn w-full bg-red-700 hover:bg-red-600 text-white font-bold py-3 rounded-xl"><i class="fa-solid fa-floppy-disk ml-1"></i>ذخیره تنظیمات</button></form></div><div class="glass rounded-2xl p-6"><h2 class="text-lg font-bold text-red-400 mb-4"><i class="fa-solid fa-key ml-1"></i>کلیدهای Reality</h2><form action="/settings" method="POST" class="mb-4"><input type="hidden" name="action" value="generate_keys"><button type="submit" class="btn px-4 py-2 bg-red-900/30 text-red-400 border border-red-800/50 rounded-xl text-sm font-bold"><i class="fa-solid fa-dice ml-1"></i>تولید کلید جدید</button></form><div class="space-y-2"><div><label class="block text-[10px] text-red-400/50 mb-1">Public Key</label><input type="text" value="{{ reality_public_key }}" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-500 font-mono text-xs outline-none" dir="ltr" readonly></div><div><label class="block text-[10px] text-red-400/50 mb-1">Private Key</label><input type="text" value="{{ reality_private_key }}" class="w-full bg-black border border-red-900/50 rounded-xl p-3 text-red-500 font-mono text-xs outline-none" dir="ltr" readonly></div></div></div></main></body></html>
EOF

# ---------- sub.html ----------
cat << 'EOF' > /root/ssh-panel/templates/sub.html
<!DOCTYPE html><html lang="fa" dir="rtl"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>اشتراک {{ username }} | OutlineParsian</title><script src="https://cdn.tailwindcss.com"></script><link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"><style>@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;500;700;900&display=swap');*{font-family:'Vazirmatn',sans-serif;margin:0;padding:0;box-sizing:border-box}body{background:radial-gradient(circle at top,#1a0000 0%,#0a0a0a 60%);color:#fff;min-height:100vh}.card{background:rgba(20,0,0,0.7);backdrop-filter:blur(20px);border:1px solid rgba(220,38,38,0.15);border-radius:20px;transition:all 0.3s}.card:hover{border-color:rgba(220,38,38,0.3)}.qr-img{border-radius:12px;cursor:pointer;background:#fff;padding:6px;transition:all 0.2s}.qr-img:hover{transform:scale(1.05)}.btn{transition:all 0.2s;cursor:pointer;border:none}.btn:hover{transform:translateY(-1px)}.copied-toast{position:fixed;top:20px;left:50%;transform:translateX(-50%);background:linear-gradient(90deg,#10b981,#059669);color:#fff;padding:12px 28px;border-radius:50px;font-size:13px;font-weight:bold;z-index:999;animation:fadeInOut 2s ease;box-shadow:0 10px 30px rgba(16,185,129,0.3)}@keyframes fadeInOut{0%{opacity:0;transform:translateX(-50%) translateY(-20px)}20%,80%{opacity:1;transform:translateX(-50%) translateY(0)}100%{opacity:0;transform:translateX(-50%) translateY(-20px)}}.tab-btn{transition:all 0.2s;border:1px solid transparent}.tab-btn.active{background:rgba(220,38,38,0.25);color:#f87171;border-color:rgba(220,38,38,0.4)}.progress-anim{animation:progressFill 1.5s ease}@keyframes progressFill{from{width:0%}}.badge{font-size:10px;padding:4px 10px;border-radius:20px;font-weight:bold;letter-spacing:0.3px}.config-item{transition:all 0.2s;border:1px solid rgba(220,38,38,0.15)}.config-item:hover{border-color:rgba(220,38,38,0.4);background:rgba(220,38,38,0.05)}</style></head><body class="p-4 md:p-8"><div class="max-w-3xl mx-auto">
<div class="text-center mb-6"><div class="w-20 h-20 mx-auto bg-gradient-to-br from-red-700 via-red-800 to-red-950 rounded-3xl flex items-center justify-center mb-3 shadow-2xl shadow-red-900/50 border border-red-500/30"><span class="text-3xl font-black text-red-100">OP</span></div><h1 class="text-2xl font-bold text-red-400 mb-1">{{ username }}</h1><div class="flex justify-center gap-3 mt-2 text-xs text-red-400/60 flex-wrap<span class="flex items-center gap-1"><i class="fa-solid fa-calendar"></i> {{ expire_date }}</span><span>•</span><span class="flex items-center gap-1 {% if status == '1' %}text-emerald-400{% else %}text-red-400{% endif %}"><i class="fa-solid fa-circle text-[6px]"></i> {% if status == '1' %}فعال{% else %}غیرفعال{% endif %}</span><span>•</span><span class="flex items-center gap-1"><i class="fa-solid fa-hourglass-half"></i> {{ days_left }} روز مانده</span></div></div>
<div class="card p-5 mb-4"><div class="grid grid-cols-3 gap-3 text-center mb-4"><div class="bg-black/40 rounded-xl p-3"><i class="fa-solid fa-hard-drive text-blue-400 text-sm mb-1"></i><p class="text-[10px] text-blue-400/60 mb-1">حجم کل</p><p class="text-lg font-black text-blue-400">{{ total_traffic }}<span class="text-xs"> GB</span></p></div><div class="bg-black/40 rounded-xl p-3"><i class="fa-solid fa-chart-line text-amber-400 text-sm mb-1"></i><p class="text-[10px] text-amber-400/60 mb-1">مصرف شده</p><p class="text-lg font-black text-amber-400">{{ used_traffic }}<span class="text-xs"> GB</span></p></div><div class="bg-black/40 rounded-xl p-3"><i class="fa-solid fa-gauge-high {% if remaining_traffic|float > 5 %}text-emerald-400{% else %}text-red-400{% endif %} text-sm mb-1"></i><p class="text-[10px] {% if remaining_traffic|float > 5 %}text-emerald-400/60{% else %}text-red-400/60{% endif %} mb-1">باقی‌مانده</p><p class="text-lg font-black {% if remaining_traffic|float > 5 %}text-emerald-400{% else %}text-red-400{% endif %}">{{ remaining_traffic }}<span class="text-xs"> GB</span></p></div></div><div class="relative"><div class="w-full bg-red-900/20 h-2.5 rounded-full overflow-hidden"><div class="progress-anim h-full bg-gradient-to-r from-red-600 via-red-500 to-red-400 rounded-full shadow-lg shadow-red-900/50" style="width:{{ progress_percent }}%"></div></div><div class="flex justify-between text-[10px] text-red-400/50 mt-1.5"><span>{{ progress_percent }}%</span><span>100%</span></div></div></div>
<div class="flex gap-2 mb-4"><button onclick="showTab('ssh')" class="tab-btn active flex-1 py-3 rounded-xl text-xs font-bold flex items-center justify-center gap-2" id="tab-ssh"><i class="fa-solid fa-terminal text-emerald-400"></i> SSH</button><button onclick="showTab('xray')" class="tab-btn flex-1 py-3 rounded-xl text-xs font-bold flex items-center justify-center gap-2 text-red-300/70" id="tab-xray"><i class="fa-solid fa-bolt text-purple-400"></i> V2Ray ({{ xray_configs|length }})</button></div>
<div id="content-ssh" class="tab-content">
<div class="card p-5"><div class="flex items-center gap-2 mb-4"><div class="w-8 h-8 bg-emerald-900/30 rounded-lg flex items-center justify-center border border-emerald-700/30"><i class="fa-solid fa-terminal text-emerald-400 text-sm"></i></div><div><h3 class="text-sm font-bold text-emerald-400">اتصال SSH</h3><p class="text-[10px] text-emerald-400/60">OpenSSH / Termux / PuTTY</p></div></div><div class="flex flex-col md:flex-row items-center gap-4"><div class="flex-1 w-full"><div class="bg-black/50 rounded-xl p-4 font-mono text-xs text-emerald-300 break-all cursor-pointer hover:bg-black/80 transition border border-emerald-900/30" dir="ltr" onclick="copyText('{{ ssh_uri }}')"><i class="fa-solid fa-copy text-emerald-500 ml-2"></i>{{ ssh_uri }}</div><div class="grid grid-cols-3 gap-2 mt-3 text-center text-[10px]"><div class="bg-black/30 rounded-lg p-2"><p class="text-emerald-400/60">Host</p><p class="text-emerald-400 font-mono mt-0.5">{{ ssh_uri.split('@')[1].split(':')[0] if '@' in ssh_uri else '' }}</p></div><div class="bg-black/30 rounded-lg p-2"><p class="text-emerald-400/60">Port</p><p class="text-emerald-400 font-mono mt-0.5">22</p></div><div class="bg-black/30 rounded-lg p-2"><p class="text-emerald-400/60">User</p><p class="text-emerald-400 font-mono mt-0.5">{{ username }}</p></div></div></div>{% if ssh_qr %}<div class="flex flex-col items-center gap-2"><img src="data:image/png;base64,{{ ssh_qr }}" class="qr-img w-32 h-32" onclick="openQR('{{ ssh_qr }}', 'SSH')"><span class="text-[10px] text-red-400/50"><i class="fa-solid fa-qrcode ml-1"></i>کلیک برای بزرگنمایی</span></div>{% endif %}</div></div>
</div>
<div id="content-xray" class="tab-content" style="display:none">
{% if xray_configs %}{% for config in xray_configs %}<div class="card config-item p-5 mb-3"><div class="flex items-center justify-between mb-4 flex-wrap gap-2"><div class="flex items-center gap-2"><span class="badge {% if config.protocol=='vless' %}bg-blue-900/30 text-blue-400 border border-blue-800/30{% elif config.protocol=='vmess' %}bg-purple-900/30 text-purple-400 border border-purple-800/30{% elif config.protocol=='trojan' %}bg-amber-900/30 text-amber-400 border border-amber-800/30{% else %}bg-gray-900/30 text-gray-400 border border-gray-800/30{% endif %}">{{ config.protocol|upper }}</span><span class="text-[10px] text-gray-500 font-mono">{{ config.tag }}:{{ config.port }}</span>{% if config.sec != 'none' %}<span class="text-[9px] badge {% if config.sec=='reality' %}bg-emerald-900/30 text-emerald-400{% else %}bg-cyan-900/30 text-cyan-400{% endif %}">{{ config.sec|upper }}</span>{% endif %}{% if config.net != 'tcp' %}<span class="text-[9px] badge bg-gray-900/30 text-gray-400">{{ config.net|upper }}</span>{% endif %}</div><div class="flex gap-2"><button onclick="copyText('{{ config.link }}')" class="btn px-3 py-1.5 bg-red-900/20 text-red-400 text-[10px] rounded-lg border border-red-800/30"><i class="fa-solid fa-copy"></i> کپی</button></div></div><div class="flex items-start gap-4 flex-col md:flex-row"><div class="flex-1 min-w-0 w-full"><div class="bg-black/50 rounded-xl p-3 font-mono text-[10px] text-gray-300 break-all border border-red-900/30" dir="ltr">{{ config.link }}</div>{% if config.link %}<div class="flex gap-2 mt-3"><a href="{{ config.nepster_link }}" class="btn inline-flex items-center gap-1.5 px-3 py-1.5 bg-red-900/20 text-red-400 text-[10px] rounded-lg border border-red-800/30"><i class="fa-solid fa-file-arrow-down"></i> Nepster</a><a href="{{ config.netmod_link }}" class="btn inline-flex items-center gap-1.5 px-3 py-1.5 bg-red-900/20 text-red-400 text-[10px] rounded-lg border border-red-800/30"><i class="fa-solid fa-file-code"></i> NetMod</a></div>{% endif %}</div>{% if config.qr_code %}<div class="flex flex-col items-center gap-2 mx-auto md:mx-0"><img src="data:image/png;base64,{{ config.qr_code }}" class="qr-img w-24 h-24" onclick="openQR('{{ config.qr_code }}', '{{ config.protocol|upper }}')"><span class="text-[9px] text-red-400/50">QR</span></div>{% endif %}</div></div>{% endfor %}{% else %}<div class="card p-8 text-center"><i class="fa-solid fa-inbox text-4xl text-red-900/50 mb-3"></i><p class="text-red-400/60 text-sm">هیچ کانفیگ V2Ray برای شما تنظیم نشده است</p><p class="text-red-400/40 text-xs mt-1">با پشتیبانی تماس بگیرید</p></div>{% endif %}
</div>
<div class="text-center mt-8 text-[10px] text-red-900/70"><i class="fa-solid fa-shield-halved ml-1"></i> Powered by OutlineParsian v3.7</div>
</div>
<div id="qrModal" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,0.95);z-index:100;align-items:center;justify-content:center;padding:20px" onclick="this.style.display='none'"><div onclick="event.stopPropagation()" style="background:linear-gradient(135deg,#fff,#f5f5f5);border-radius:24px;padding:24px;max-width:340px;width:100%;text-align:center"><p id="qrModalTitle" style="color:#7f1d1d;font-weight:bold;margin-bottom:12px;font-size:14px"></p><img id="qrModalImg" src="" style="width:100%;border-radius:16px"><p style="color:#991b1b;font-size:11px;margin-top:12px"><i class="fa-solid fa-hand-pointer"></i> برای بستن کلیک کنید</p></div></div>
<script>
function copyText(text){if(!text)return;try{navigator.clipboard.writeText(text).then(()=>{showToast()})}catch(e){var tmp=document.createElement('textarea');tmp.value=text;tmp.style.position='fixed';tmp.style.opacity='0';document.body.appendChild(tmp);tmp.select();document.execCommand('copy');document.body.removeChild(tmp);showToast()}}
function showToast(){var t=document.createElement('div');t.className='copied-toast';t.innerHTML='<i class="fa-solid fa-circle-check"></i> کپی شد!';document.body.appendChild(t);setTimeout(()=>t.remove(),2000)}
function openQR(b64, label){document.getElementById('qrModalImg').src='data:image/png;base64,'+b64;document.getElementById('qrModalTitle').textContent=label+' - اسکن کنید';document.getElementById('qrModal').style.display='flex'}
function showTab(tab){document.querySelectorAll('.tab-content').forEach(el=>el.style.display='none');document.querySelectorAll('.tab-btn').forEach(el=>{el.classList.remove('active');el.classList.add('text-red-300/70')});document.getElementById('content-'+tab).style.display='block';var active=document.getElementById('tab-'+tab);active.classList.add('active');active.classList.remove('text-red-300/70')}
</script></body></html>
EOF

echo "✓ All HTML templates created"

# ============================================
# STEP 12: Systemd Services
# ============================================
echo "[12/16] Creating systemd services..."

cat << 'EOF' > /etc/systemd/system/ssh-panel.service
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
TimeoutStartSec=30
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > /etc/systemd/system/ssh-panel-worker.service
[Unit]
Description=OutlineParsian Worker (Traffic + Online)
After=network.target xray.service
[Service]
Type=simple
User=root
WorkingDirectory=/root/ssh-panel
ExecStart=/usr/bin/python3 /root/ssh-panel/traffic_worker.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > /etc/nginx/sites-available/panel
server {listen 80;server_name _;client_max_body_size 100M;location / {proxy_pass http://127.0.0.1:5000;proxy_http_version 1.1;proxy_set_header Upgrade $http_upgrade;proxy_set_header Connection 'upgrade';proxy_set_header Host $host;proxy_set_header X-Real-IP $remote_addr;proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;proxy_cache_bypass $http_upgrade;proxy_read_timeout 300s;}}
EOF
ln -sf /etc/nginx/sites-available/panel /etc/nginx/sites-enabled/ 2>/dev/null
rm -f /etc/nginx/sites-enabled/default 2>/dev/null

# ============================================
# STEP 13: Start Services
# ============================================
mkdir -p "/root/ssh-panel"
cat << 'OP_FIX_1' > "/root/ssh-panel/telemetry.py"
#!/usr/bin/env python3
"""Shared, bounded telemetry; no process scans in HTTP/limiter paths."""
import ipaddress
import json
import os
import re
import tempfile
import time
from datetime import datetime

ONLINE_TTL = 30
SNAPSHOT_TTL = 20
EMAIL_RE = re.compile(r'\bemail:\s*(\S+)')
SOURCE_RE = re.compile(r'(?:\bfrom\s+)?((?:tcp:|udp:)?(?:\[[^\]]+\]|[0-9a-fA-F.:]+):\d+)\s+accepted\b')
TIMESTAMP_RE = re.compile(r'^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)')


def canonical_ip(value):
    try:
        address = ipaddress.ip_address(str(value).strip('[]').split('%', 1)[0])
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
            address = address.ipv4_mapped
        return str(address)
    except ValueError:
        return None


def endpoint(value):
    value = re.sub(r'^(?:tcp|udp):', '', value)
    try:
        host, port = value.rsplit(':', 1)
        address = canonical_ip(host)
        port = int(port)
        return (address, port) if address and 0 <= port <= 65535 else None
    except (ValueError, AttributeError):
        return None


def atomic_json(path, data):
    directory = os.path.dirname(path) or '.'
    fd, temporary = tempfile.mkstemp(prefix='.' + os.path.basename(path), dir=directory)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(data, stream, separators=(',', ':'))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class SnapshotReader:
    def __init__(self, path, ttl=SNAPSHOT_TTL):
        self.path, self.ttl = path, ttl
        self.signature, self.data = None, {}

    def read(self, now=None):
        now = time.time() if now is None else now
        try:
            stat = os.stat(self.path)
            signature = (stat.st_dev, stat.st_ino, stat.st_mtime_ns, stat.st_size)
            if signature != self.signature:
                with open(self.path, encoding='utf-8') as stream:
                    data = json.load(stream)
                if not isinstance(data, dict) or not isinstance(data.get('users'), dict):
                    return {}
                self.data, self.signature = data, signature
            if not 0 <= now - float(self.data.get('last_update', 0)) <= self.ttl:
                return {}
            return self.data
        except (OSError, ValueError, TypeError):
            return {}


def online_view(snapshot, now=None):
    now = time.time() if now is None else now
    result = {}
    for username, info in snapshot.get('users', {}).items():
        try:
            if not 0 <= now - float(info.get('ts', 0)) <= SNAPSHOT_TTL:
                continue
            ssh_count = max(0, int(info.get('ssh', 0)))
            is_xray = bool(info.get('xray', False))
            xray_count = max(0, int(info.get('xray_ips', 0)))
            if not ssh_count and not is_xray:
                continue
            count = info.get('online_count')
            if count is None:
                count = ssh_count + xray_count
            result[username] = {
                'ssh': bool(ssh_count), 'xray': is_xray,
                'ssh_count': ssh_count, 'xray_ips': xray_count,
                'is_online': True, 'online_count': max(1, int(count)),
            }
        except (ValueError, TypeError, AttributeError):
            continue
    return result


class BoundedLogReader:
    def __init__(self, path, cursor_path, max_bytes=1024 * 1024):
        self.path, self.cursor_path, self.max_bytes = path, cursor_path, max_bytes
        self.cursor = None
        try:
            with open(cursor_path) as stream:
                value = json.load(stream)
            if isinstance(value, dict):
                self.cursor = value
        except (OSError, ValueError):
            pass

    def read(self):
        try:
            with open(self.path, 'rb') as stream:
                stat = os.fstat(stream.fileno())
                identity = [stat.st_dev, stat.st_ino]
                if self.cursor is None:
                    # Historical records must not become current online users.
                    self.cursor = {'identity': identity, 'pos': stat.st_size}
                    atomic_json(self.cursor_path, self.cursor)
                    return []
                position = int(self.cursor.get('pos', 0))
                if self.cursor.get('identity') != identity or position > stat.st_size:
                    position = 0
                skip_partial = stat.st_size - position > self.max_bytes
                if skip_partial:
                    position = stat.st_size - self.max_bytes
                if position >= stat.st_size:
                    return []
                stream.seek(position)
                data = stream.read(self.max_bytes)
                end = data.rfind(b'\n') + 1
                if not end:
                    if len(data) == self.max_bytes:
                        end = len(data)
                    else:
                        return []
                self.cursor = {'identity': identity, 'pos': position + end}
                atomic_json(self.cursor_path, self.cursor)
                lines = data[:end].decode('utf-8', errors='replace').splitlines()
                return lines[1:] if skip_partial else lines
        except (OSError, ValueError, TypeError):
            return []


def log_activity(lines, aliases, now=None):
    now = time.time() if now is None else now
    result = {}
    for line in lines:
        email, source = EMAIL_RE.search(line), SOURCE_RE.search(line)
        if not email or not source or email.group(1) not in aliases:
            continue
        parsed = endpoint(source.group(1))
        if not parsed:
            continue
        timestamp = now
        match = TIMESTAMP_RE.match(line)
        if match:
            try:
                value = match.group(1)
                fmt = '%Y/%m/%d %H:%M:%S.%f' if '.' in value else '%Y/%m/%d %H:%M:%S'
                timestamp = datetime.strptime(value, fmt).timestamp()
            except ValueError:
                continue
        if 0 <= now - timestamp <= ONLINE_TTL:
            result.setdefault(aliases[email.group(1)], {})[parsed[0]] = timestamp
    return result
OP_FIX_1
mkdir -p "/root/ssh-panel/static"
cat << 'OP_FIX_6' > "/root/ssh-panel/static/online-status.js"
/* Refresh the existing v3.7 indicators. No template, style or layout changes. */
(function () {
  'use strict';
  var timer = null;
  var last = '';
  var inFlight = false;

  function render(data) {
    var signature = JSON.stringify(data);
    if (signature === last) return;
    last = signature;
    var lookup = Object.create(null);
    Object.keys(data).forEach(function (username) { lookup[username.toLowerCase()] = data[username]; });
    document.querySelectorAll('tbody tr[data-username], .mobile-card [data-username]').forEach(function (row) {
      var info = lookup[row.getAttribute('data-username')] || {};
      var online = !!info.is_online;
      row.setAttribute('data-online', online ? '1' : '0');
      var dot = row.querySelector('span.w-2\\.5');
      if (dot) {
        dot.classList.toggle('bg-emerald-500', online);
        dot.classList.toggle('pulse-dot', online);
        dot.classList.toggle('bg-gray-700', !online);
        if (row.tagName === 'TR') {
          dot.classList.toggle('shadow-lg', online);
          dot.classList.toggle('shadow-emerald-500/50', online);
        }
        var group = dot.parentElement;
        Array.from(group.querySelectorAll('span')).forEach(function (badge) {
          if (badge.classList.contains('text-[9px]') && /^(SSH|V2Ray|V2R)$/.test(badge.textContent.trim())) badge.remove();
        });
        var desktop = row.tagName === 'TR';
        [['ssh', 'SSH', 'emerald'], ['xray', desktop ? 'V2Ray' : 'V2R', 'purple']].forEach(function (spec) {
          if (!info[spec[0]]) return;
          var badge = document.createElement('span');
          badge.textContent = spec[1];
          badge.className = 'text-[9px] bg-' + spec[2] + '-900/40 text-' + spec[2] + '-400 px-1.5 py-0.5 rounded' +
            (desktop ? ' border border-' + spec[2] + '-700/30' : '');
          group.appendChild(badge);
        });
      }
      var counter = row.tagName === 'TR' ? row.querySelector('td:nth-child(3) span') :
        row.querySelector('.grid > div:nth-child(2) span.font-mono');
      if (counter) {
        var maximum = counter.textContent.split('/').pop().trim();
        counter.textContent = (online ? (Number(info.online_count) || 1) : 0) + '/' + maximum;
        if (row.tagName === 'TR') {
          counter.classList.toggle('text-emerald-400', online);
          counter.classList.toggle('border-emerald-800/30', online);
          counter.classList.toggle('text-red-400', !online);
          counter.classList.toggle('border-red-900/30', !online);
        }
      }
    });
    if (typeof window.filterUsers === 'function') window.filterUsers();
  }

  async function poll() {
    if (document.hidden || inFlight) return;
    inFlight = true;
    var controller = new AbortController();
    var timeout = setTimeout(function () { controller.abort(); }, 4000);
    try {
      var response = await fetch('/api/online', {cache: 'no-store', signal: controller.signal});
      if (response.status === 401) return;
      if (response.ok) render(await response.json());
    } catch (error) {
      /* Keep the last result on a transient network failure. */
    } finally {
      inFlight = false;
      clearTimeout(timeout);
      if (!document.hidden) timer = setTimeout(poll, 5000);
    }
  }
  document.addEventListener('visibilitychange', function () {
    clearTimeout(timer);
    if (!document.hidden) poll();
  });
  poll();
}());
OP_FIX_6
mkdir -p "/etc/logrotate.d"
cat << 'OP_FIX_9' > "/etc/logrotate.d/ssh-panel-xray"
/tmp/xray_access.log /tmp/xray_error.log {
    daily
    maxsize 32M
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su root root
}
OP_FIX_9
mkdir -p "/etc/systemd/system"
cat << 'OP_FIX_10' > "/etc/systemd/system/ssh-panel-logrotate.service"
[Unit]
Description=Rotate OutlineParsian Xray logs

[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate --state /var/lib/logrotate/ssh-panel-xray.status /etc/logrotate.d/ssh-panel-xray
OP_FIX_10
mkdir -p "/etc/systemd/system"
cat << 'OP_FIX_11' > "/etc/systemd/system/ssh-panel-logrotate.timer"
[Unit]
Description=Check OutlineParsian log size every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
OP_FIX_11

echo "[13/16] Starting all services..."
python3 /root/ssh-panel/sync_xray.py
systemctl daemon-reload
systemctl enable xray ssh-panel ssh-panel-worker ssh-panel-ip-manager nginx iran-block.service 2>/dev/null
systemctl restart xray ssh-panel-worker ssh-panel-ip-manager ssh-panel nginx
systemctl start iran-block.service 2>/dev/null
systemctl enable --now ssh-panel-logrotate.timer

sleep 4

# ============================================
# Health check
# ============================================
echo "[14/16] Health check..."
for svc in xray ssh-panel ssh-panel-worker ssh-panel-ip-manager nginx; do
    if systemctl is-active --quiet "$svc"; then
        echo "  ✓ $svc"
    else
        echo "  ✗ $svc (FAILED)"
        journalctl -u "$svc" -n 5 --no-pager 2>/dev/null | tail -5
    fi
done

IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║                                                      ║"
echo "║   ✅ OutlineParsian Ultimate Panel v3.7              ║"
echo "║   Installation Complete!                             ║"
echo "║                                                      ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  🌐 Panel:  http://${IP}:5000"
echo "║  👤 User:   admin      🔑 Pass: admin123"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  🚀 NEW IN v3.7:                                     ║"
echo "║  ✅ CPU and Online Status Backend Repair             ║"
echo "║                                                      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  🚀 Panel is ready! Open in browser."
echo ""
