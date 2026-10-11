#!/usr/bin/env bash
# OutlineParsian Panel v3.8 -- complete, readable, single-file installer.
# Reviewed against the supplied v3.7 script. All payload source follows below.
#
# ریشه‌یابی و اصلاحات:
#  1. CRLF ورودی به LF تبدیل شده است؛ خطای نحوی Python در نسخهٔ ارسالی دیده نشد.
#  2. نصب مجدد دیگر دیتابیس را با دیتابیس خالی جایگزین نمی‌کند؛ migration درجا است.
#  3. نصب از خطا عبور نمی‌کند و apt upgrade یا pip سیستمی اجرا نمی‌کند.
#  4. تنظیمات اصلی SSH و دسترسی مدیر سرور بازنویسی نمی‌شوند.
#  5. فرمان‌های سیستمی بدون shell اجرا می‌شوند؛ chpasswd ورودی را از stdin می‌گیرد.
#  6. نام‌های سیستمی، ورودی‌های ناسالم، NaN، پورت‌های تکراری و ترکیب‌های نامعتبر رد می‌شوند.
#  7. رمز مدیر hash می‌شود؛ رمزهای SSH در دیتابیس رمزگذاری می‌شوند و فایل‌ها خصوصی‌اند.
#  8. کلید نشست پایدار است؛ CSRF و POST برای حذف، خروج و عملیات تغییردهنده فعال‌اند.
#  9. اشتراک و دانلود به توکن تصادفی و اعتبار واقعی حساب وابسته‌اند؛ نام کاربر کافی نیست.
# 10. مصرف و baseline شمارنده در یک تراکنش ثبت می‌شوند؛ شمارندهٔ Xray صفر نمی‌شود.
# 11. تاریخ و سقف مصرف همهٔ حساب‌ها حتی بدون مصرف جدید بررسی می‌شوند.
# 12. آنلاین Xray از API رسمی، و IPهای SSH با parser دارای پشتیبانی IPv6 خوانده می‌شوند.
# 13. محدودیت بر اساس IP یکتا و ترکیب حساب+IP است؛ INPUT DROP سراسری ساخته نمی‌شود.
# 14. حساب‌های SSH غیرفعال هم قفل و هم منقضی می‌شوند؛ فقط نشست تاییدشده قطع می‌شود.
# 15. Trojan از password استفاده می‌کند؛ TLS دارای گواهی است؛ لینک‌ها URL-encode می‌شوند.
# 16. تنظیمات Xray پیش از جایگزینی آزمایش می‌شوند؛ restart ناموفق config قبلی را برمی‌گرداند.
# 17. بکاپ با SQLite backup API و همراه کلید است؛ restore ساختار و روابط را بررسی می‌کند.
# 18. تغییر پورت داخلی، Nginx و Gunicorn را نیز به‌روز می‌کند؛ کلید Reality موجود حفظ می‌شود.
# 19. فایل جعلی .npvt حذف شده است؛ خروجی واقعی JSON استاندارد Xray ارائه می‌شود.
#
# حدود دقت:
# - «IP فعال» تعداد دستگاه نیست؛ NAT می‌تواند چند دستگاه را پشت یک IP نشان دهد.
# - محدودسازی Xray روی درخواست‌های تازه پس از احراز هویت اعمال می‌شود. جریان‌های
#   از قبل routeشده تا بسته‌شدن ادامه دارند؛ مسدودسازی سخت همان جریان به تغییر core نیاز دارد.
# - شمارش SSH با snapshot شمارندهٔ TCP تقریبی و شامل سربار است؛ اتصال‌های بسیار کوتاه
#   یا بایت‌های نهایی بین دو poll ممکن است دیده نشوند. برای صورتحساب دقیق کافی نیست.
# - crash سیستم یا restart بیرونی Xray بین دو poll می‌تواند بخشی از مصرف اخیر را از دست بدهد.
# - این نسخه برای سرور Debian/Ubuntu دارای systemd و Python >=3.10 است.
# - SSH کاربران پنل مخصوص tunnel است (MaxSessions 0)؛ تنظیمات حساب مدیر سرور حفظ می‌شود.
# - لینک‌های قدیمی /sub/username با لینک‌های توکن‌دار در داشبورد جایگزین می‌شوند.
# - بکاپ جدید ZIP است؛ DB قدیمی هم قابل ورود است، مشروط به اعتبار داده/حساب/تنظیمات.
# - رمز/کلید بکاپ را منتشر نکنید. این فایل شامل هیچ رمز یا دیتابیس کاربر واقعی نیست.
#
# Usage:
#   bash outlineparsian_fixed_v3_8.sh --check            # no installation/system mutation
#   bash outlineparsian_fixed_v3_8.sh --extract ./source # export all readable source files
#   sudo bash outlineparsian_fixed_v3_8.sh              # install/upgrade on your VPS
# Optional first-install environment:
#   PANEL_ADMIN_PASSWORD (>=12 chars); PANEL_PUBLIC_PORT (default 80).
#   PANEL_SERVER_ADDRESS (hostname/IP); PANEL_HTTPS_DOMAIN (existing LetsEncrypt certificate).
# For HTTPS, set PANEL_PUBLIC_PORT=443 and PANEL_HTTPS_DOMAIN=your-domain with existing certs.
# Existing public port/address/admin credentials are preserved unless explicitly supplied.
# New installations print a random admin password; default admin123 is replaced.
# Tested configuration target: official Xray v25.8.3. Existing newer compatible cores are reused.
# Reference: https://xtls.github.io/en/config/api.html
#            https://xtls.github.io/en/config/policy.html
#            https://github.com/XTLS/Xray-core/tree/v25.8.3
set -Eeuo pipefail
umask 077
BASE=/root/ssh-panel
XRAY_TESTED_VERSION=25.8.3
STAGE=''
BACKUP_DIR=''
DEPLOYING=0
SUCCESS=0
declare -A ORIGINAL_ACTIVE=()

cleanup() {
    local code=$?
    if [[ -n "$STAGE" && -d "$STAGE" ]]; then rm -rf -- "$STAGE"; fi
    return "$code"
}
trap cleanup EXIT

on_error() {
    local code=$? line=$1
    trap - ERR
    set +e
    printf '\nInstallation stopped at line %s (exit %s).\n' "$line" "$code" >&2
    if (( DEPLOYING && ! SUCCESS )) && [[ -f "$BACKUP_DIR/panel-before.tar.gz" ]]; then
        printf 'Restoring pre-upgrade files and configuration...\n' >&2
        systemctl stop xray ssh-panel ssh-panel-worker ssh-panel-ip-manager 2>/dev/null
        tar -xzf "$BACKUP_DIR/panel-before.tar.gz" -C "$BASE"
        if [[ -f "$BACKUP_DIR/panel-before.db" ]]; then
            python3 - "$BACKUP_DIR/panel-before.db" "$BASE/panel.db" <<'ROLLBACK_DB'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as src, sqlite3.connect(sys.argv[2]) as dst:
    src.backup(dst)
ROLLBACK_DB
        fi
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            if [[ -e "$BACKUP_DIR/system$path" || -L "$BACKUP_DIR/system$path" ]]; then
                rm -f -- "$path"
                mkdir -p -- "$(dirname -- "$path")"
                cp -a -- "$BACKUP_DIR/system$path" "$path"
            else
                rm -f -- "$path"
            fi
        done < "$BACKUP_DIR/system-files.txt"
        systemctl daemon-reload
        /usr/sbin/sshd -t && systemctl reload ssh
        nginx -t && systemctl reload-or-restart nginx
        for svc in xray ssh-panel ssh-panel-worker ssh-panel-ip-manager; do
            if [[ "${ORIGINAL_ACTIVE[$svc]:-0}" == 1 ]]; then systemctl start "$svc"; fi
        done
        printf 'Backup and restore record: %s\n' "$BACKUP_DIR" >&2
    fi
    printf 'Installation did not complete; inspect the error above.\n' >&2
    exit "$code"
}
trap 'on_error "$LINENO"' ERR

# Payload is written using quoted heredocs; no downloaded code is piped into bash.
write_sources() {
    local payload=$1
    mkdir -p -- "$payload/templates" "$payload/static"
    cat > "$payload/app.py" <<'OP_SOURCE_APP_PY_END'
"""OutlineParsian 3.8 web application. Run behind the supplied Nginx proxy."""
import base64
import hashlib
import io
import json
import logging
import secrets
import sqlite3
import time
import uuid
from datetime import datetime, timedelta
from functools import wraps
from pathlib import Path
from urllib.parse import quote

import psutil
import qrcode
from flask import (Flask, abort, flash, jsonify, redirect, render_template, request,
                   send_file, session, url_for, Response)
from werkzeug.middleware.proxy_fix import ProxyFix
from werkzeug.security import check_password_hash, generate_password_hash

from common import (BASE, ONLINE_FILE, STATE, allowed, authority, database, decrypt,
                    encrypt, ensure_system_user, gen_link, get_setting, host, integer,
                    lock_system_user, log, new_keys, now_text, owned_account, parse_expiry,
                    password, run, set_setting, state_lock, traffic_mb, username)
from maintenance import backup_bytes, queue_restore
from sync_xray import apply, client_config, generate, port_free, validate_inbound
from telemetry import capture_xray, ssh_snapshot

app = Flask(__name__, template_folder=str(BASE / 'templates'), static_folder=str(BASE / 'static'))
app.secret_key = (BASE / 'session.key').read_bytes().strip()
app.config.update(MAX_CONTENT_LENGTH=32*1024*1024, SESSION_COOKIE_HTTPONLY=True,
                  SESSION_COOKIE_SECURE=get_setting('ssl_status') == 'active',
                  SESSION_COOKIE_SAMESITE='Lax', PERMANENT_SESSION_LIFETIME=timedelta(hours=8))
# Only trusted loopback Nginx sets these headers. Gunicorn is never exposed publicly.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1)


def admin_signature():
    return hashlib.sha256((get_setting('admin_username') + '\x00' + get_setting('admin_password_hash')).encode()).hexdigest()


def logged_in():
    return bool(session.get('logged_in') and secrets.compare_digest(
        session.get('admin_signature', ''), admin_signature()))


def csrf_token():
    if 'csrf' not in session:
        session['csrf'] = secrets.token_urlsafe(32)
    return session['csrf']


@app.context_processor
def context():
    return {'csrf_token': csrf_token, 'version': '3.8'}


@app.before_request
def guard():
    public = {'login', 'static', 'sub_page', 'download_client', 'download_netmod', 'download_nepster', 'health'}
    if request.endpoint and request.endpoint not in public and not logged_in():
        if request.path.startswith('/api/'):
            return jsonify(error='Unauthorized'), 401
        return redirect(url_for('login'))
    if request.method in {'POST', 'PUT', 'PATCH', 'DELETE'}:
        token = request.form.get('csrf_token') or request.headers.get('X-CSRF-Token', '')
        expected = session.get('csrf', '')
        if not expected or not secrets.compare_digest(expected.encode(), token.encode()):
            abort(400, description='درخواست نامعتبر؛ صفحه را تازه کنید')


@app.after_request
def headers(response):
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Content-Security-Policy'] = (
        "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; "
        "base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
    return response


@app.errorhandler(ValueError)
@app.errorhandler(sqlite3.IntegrityError)
def bad_input(exc):
    flash(str(exc) if isinstance(exc, ValueError) else 'نام، پورت یا عضویت تکراری/نامعتبر است', 'error')
    return redirect(url_for('dashboard'))


@app.errorhandler(500)
def failed(exc):
    log.exception('Web request failed')
    return render_template('error.html', error_message='عملیات ناموفق بود؛ جزئیات در لاگ سرویس ثبت شده است'), 500


def mutate(callback):
    """SQL changes commit only after the complete candidate Xray config works."""
    with state_lock():
        with database() as conn:
            capture_xray(conn)
            conn.commit()
        with database() as conn:
            conn.execute('BEGIN IMMEDIATE')
            result = callback(conn)
            config = generate(conn)
            from common import XRAY_CONFIG, atomic_bytes
            previous = XRAY_CONFIG.read_bytes() if XRAY_CONFIG.exists() else None
            applied = apply(config)
            try:
                conn.commit()
            except Exception:
                if applied and previous is not None:
                    atomic_bytes(XRAY_CONFIG, previous)
                    run(['systemctl', 'restart', 'xray'], check=False)
                raise
            return result


def server_host():
    return host(get_setting('domain') or get_setting('server_address'))


def public_base():
    server = authority(server_host())
    port = int(get_setting('public_port', default='80'))
    tls = get_setting('ssl_status') == 'active'
    scheme = 'https' if tls else 'http'
    return f'{scheme}://{server}' + (f':{port}' if port != (443 if tls else 80) else '')


def online_data():
    try:
        data = json.loads(ONLINE_FILE.read_text())
        if time.time() - data['last_update'] > 20:
            return {'users': {}, 'stale': True}
        return data
    except (OSError, ValueError, KeyError):
        return {'users': {}, 'stale': True}


def random_port():
    with database() as conn:
        taken = {r[0] for r in conn.execute('SELECT port FROM xray_inbounds')}
        taken |= {int(get_setting('panel_port', conn)), 10085, int(get_setting('ssh_port', conn, '22'))}
    for _ in range(100):
        selected = secrets.randbelow(50000) + 10000
        if selected not in taken and port_free(selected):
            return selected
    raise ValueError('پورت آزاد پیدا نشد')


def qr_data(content):
    output = io.BytesIO()
    qrcode.make(content).save(output, format='PNG')
    return base64.b64encode(output.getvalue()).decode()


@app.route('/', methods=['GET', 'POST'])
def login():
    error = None
    if request.method == 'POST':
        address = request.remote_addr or 'unknown'
        now = time.time()
        with state_lock(), database() as conn:
            conn.execute('CREATE TABLE IF NOT EXISTS login_attempts(ip TEXT PRIMARY KEY, count INTEGER, since REAL)')
            row = conn.execute('SELECT * FROM login_attempts WHERE ip=?', (address,)).fetchone()
            count = row['count'] if row and now - row['since'] < 300 else 0
            since = row['since'] if count else now
            if count >= 10:
                return render_template('login.html', error='تلاش‌های زیاد؛ پنج دقیقه بعد دوباره امتحان کنید'), 429
            valid = check_password_hash(get_setting('admin_password_hash', conn), request.form.get('password', ''))
            valid = secrets.compare_digest(request.form.get('username', '').encode(),
                                           get_setting('admin_username', conn).encode()) and valid
            if valid:
                conn.execute('DELETE FROM login_attempts WHERE ip=?', (address,))
            else:
                conn.execute('INSERT INTO login_attempts VALUES(?,?,?) ON CONFLICT(ip) DO UPDATE '
                             'SET count=excluded.count,since=excluded.since', (address, count + 1, since))
            conn.execute('DELETE FROM login_attempts WHERE since<?', (now - 3600,))
            conn.commit()
        if valid:
            session.clear()
            session.update(logged_in=True, admin_signature=admin_signature(), csrf=secrets.token_urlsafe(32))
            session.permanent = True
            return redirect(url_for('dashboard'))
        error = 'اطلاعات ورود نادرست است'
    return render_template('login.html', error=error)


@app.post('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))


@app.get('/health')
def health():
    # Health detail is intentionally available only to loopback monitoring.
    if request.remote_addr not in ('127.0.0.1', '::1'):
        abort(404)
    with database() as conn:
        conn.execute('SELECT 1 FROM settings LIMIT 1')
    return jsonify(ok=True)


@app.get('/dashboard')
def dashboard():
    online = online_data()
    with database() as conn:
        users = []
        for row in conn.execute('SELECT * FROM users ORDER BY created_at DESC,username'):
            item = dict(row)
            item['password'] = decrypt(row['password'])
            item['online'] = online['users'].get(row['username'], {})
            item['active'] = allowed(row)
            item['sub_link'] = public_base() + '/sub/' + (row['sub_token'] or '')
            users.append(item)
        inbounds = conn.execute('SELECT COUNT(*) FROM xray_inbounds WHERE status=1').fetchone()[0]
        clients = conn.execute('SELECT COUNT(*) FROM xray_clients WHERE enable=1').fetchone()[0]
    return render_template('dashboard.html', users=users, online=online, inbounds=inbounds, clients=clients,
                           used=sum(u['used_traffic'] or 0 for u in users) / 1024,
                           active_count=sum(u['active'] for u in users))


@app.get('/api/stats')
def api_stats():
    return jsonify(cpu=psutil.cpu_percent(interval=None), ram=psutil.virtual_memory().percent)


@app.get('/api/online')
def api_online():
    return jsonify(online_data()['users'])


@app.get('/add_user_page')
def add_user_page():
    return render_template('user_form.html', user=None)


@app.get('/edit_user_page/<name>')
def edit_user_page(name):
    with database() as conn:
        row = conn.execute('SELECT * FROM users WHERE username=?', (name,)).fetchone()
    if not row:
        abort(404)
    user = dict(row)
    user['password'] = decrypt(row['password'])
    return render_template('user_form.html', user=user)


@app.post('/add_user')
def add_user():
    name = username(request.form.get('username'))
    plain = password(request.form.get('password'))
    days = integer(request.form.get('expire_days', '30'), 1, 36500, 'مدت اعتبار')
    total = traffic_mb(request.form.get('traffic_gb', '0'))
    limit = integer(request.form.get('max_connections', '2'), 0, 1000, 'حد IP')
    with state_lock():
        with database() as conn:
            if conn.execute('SELECT 1 FROM users WHERE username=?', (name,)).fetchone():
                raise ValueError('نام کاربر تکراری است')
        # Never change a pre-existing account not explicitly owned by this panel.
        if owned_account(name) is not None:
            raise ValueError('یک حساب سیستمی با این نام از قبل وجود دارد')
        created = ensure_system_user(name, plain)
        try:
            def insert(conn):
                conn.execute('INSERT INTO users(username,password,expire_date,total_traffic,used_traffic,status,'
                             'max_connections,created_at,sub_token) VALUES(?,?,?,?,0,1,?,?,?)',
                             (name, encrypt(plain), (datetime.now()+timedelta(days=days)).strftime('%Y-%m-%d %H:%M'),
                              total, limit, now_text(), secrets.token_urlsafe(32)))
                set_setting('pending_iran_apply', '1', conn)
            mutate(insert)
        except Exception:
            if created:
                run(['userdel', '--', name], check=False)  # Preserve its home directory.
            raise
    flash('کاربر ایجاد شد', 'success')
    return redirect(url_for('dashboard'))


@app.post('/edit_user')
def edit_user():
    name = username(request.form.get('username'))
    plain = password(request.form.get('password'))
    total = traffic_mb(request.form.get('traffic_gb', '0'))
    limit = integer(request.form.get('max_connections', '2'), 0, 1000, 'حد IP')
    status = integer(request.form.get('status', '1'), 0, 1, 'وضعیت')
    expiry = parse_expiry(request.form.get('expire_date'))
    reset = request.form.get('reset_traffic') == 'on'
    if request.form.get('reset_expire') == 'on':
        expiry = datetime.now() + timedelta(days=integer(request.form.get('reset_days', '30'), 1, 36500))
    elif request.form.get('extend_days', '0') != '0':
        extra = integer(request.form.get('extend_days'), 0, 36500)
        expiry = max(datetime.now(), expiry) + timedelta(days=extra)
    with state_lock():
        def update(conn):
            old = conn.execute('SELECT * FROM users WHERE username=?', (name,)).fetchone()
            if not old:
                raise ValueError('کاربر یافت نشد')
            used = 0 if reset else old['used_traffic']
            candidate = {'status': status, 'expire_date': expiry.strftime('%Y-%m-%d %H:%M'),
                         'total_traffic': total, 'used_traffic': used}
            if status and not allowed(candidate):
                raise ValueError('برای فعال‌سازی، تاریخ و حجم باقی‌مانده باید معتبر باشند')
            conn.execute("UPDATE users SET password=?,total_traffic=?,used_traffic=?,max_connections=?,status=?,"
                         "expire_date=?,disabled_reason='' WHERE username=?",
                         (encrypt(plain), total, used, limit, status, candidate['expire_date'], name))
            if request.form.get('rotate_token') == 'on':
                conn.execute('UPDATE users SET sub_token=? WHERE username=?', (secrets.token_urlsafe(32), name))
        # mutate captures pending usage BEFORE resetting the visible quota; baselines remain intact.
        mutate(update)
        from traffic_worker import reconcile_ssh
        with database() as conn:
            row = dict(conn.execute('SELECT * FROM users WHERE username=?', (name,)).fetchone())
        failures = reconcile_ssh([row], ssh_snapshot({name}, int(get_setting('ssh_port', default='22'))))
    flash('اطلاعات ذخیره شد؛ اعمال تغییر SSH ناموفق بود و worker دوباره تلاش می‌کند' if failures
          else 'کاربر به‌روز شد', 'error' if failures else 'success')
    return redirect(url_for('dashboard'))


@app.post('/delete_user/<name>')
def delete_user(name):
    managed = None
    try:
        managed = owned_account(name)
    except ValueError:
        # Allow removing unsafe legacy DB entries without touching any system account.
        pass
    with state_lock():
        if managed:
            lock_system_user(name, True)
            from common import kill_ssh_session
            for sock in ssh_snapshot({name}, int(get_setting('ssh_port', default='22'))):
                kill_ssh_session(sock['pid'], name)
        def remove(conn):
            conn.execute('DELETE FROM users WHERE username=?', (name,))
            prefix = 'user>>>' + name + '>>>'
            conn.execute("DELETE FROM counter_state WHERE source='xray' AND substr(name,1,?)=?", (len(prefix), prefix))
            conn.execute('DELETE FROM runtime_state WHERE key=?', ('ssh-' + name,))
            set_setting('pending_iran_apply', '1', conn)
        mutate(remove)
        if managed:
            run(['userdel', '--', name])
    flash('کاربر حذف شد؛ پوشهٔ خانگی حفظ شد', 'success')
    return redirect(url_for('dashboard'))


@app.get('/inbounds')
def inbounds_page():
    with database() as conn:
        rows = [dict(r) for r in conn.execute('SELECT ib.*, (SELECT COUNT(*) FROM xray_clients cl '
                                            'WHERE cl.inbound_id=ib.id) client_count FROM xray_inbounds ib ORDER BY id DESC')]
    return render_template('inbounds.html', inbounds=rows)


@app.get('/add_inbound_page')
def add_inbound_page():
    return render_template('inbound_form.html', random_port=random_port())


@app.post('/add_inbound')
def add_inbound():
    ib = {k: request.form.get(k, default) for k, default in {
        'tag': '', 'protocol': 'vless', 'network': 'tcp', 'security': 'reality', 'server_name': 'www.microsoft.com',
        'fingerprint': 'chrome', 'short_id': '', 'path': '/', 'certificate_file': '', 'key_file': ''}.items()}
    ib['port'] = integer(request.form.get('port'), 1, 65535, 'پورت')
    ib['server_name'] = host(ib['server_name'], allow_empty=ib['security'] == 'none')
    ib['private_key'] = ib['public_key'] = ''
    if ib['security'] == 'reality':
        ib['private_key'], ib['public_key'] = new_keys()
        ib['short_id'] = ib['short_id'] or secrets.token_hex(4)
    validate_inbound(ib)
    reserved = {int(get_setting(k, default=str(d))) for k, d in
                [('panel_port', 5000), ('public_port', 80), ('ssh_port', 22)]} | {10085, 443}
    if ib['port'] in reserved or not port_free(ib['port']):
        raise ValueError('پورت رزرو شده یا در حال استفاده است')
    def insert(conn):
        keys = list(ib) + ['created_at']
        conn.execute('INSERT INTO xray_inbounds(' + ','.join(keys) + ') VALUES(' + ','.join('?' for _ in keys) + ')',
                     [ib[k] for k in ib] + [now_text()])
    mutate(insert)
    flash('اینباند پس از آزمون تنظیمات ایجاد شد', 'success')
    return redirect(url_for('inbounds_page'))


@app.post('/delete_inbound/<int:ib_id>')
def delete_inbound(ib_id):
    mutate(lambda conn: conn.execute('DELETE FROM xray_inbounds WHERE id=?', (ib_id,)))
    flash('اینباند حذف شد', 'success')
    return redirect(url_for('inbounds_page'))


def effective_inbound(ib):
    ib = dict(ib)
    ib['public_key'] = ib['public_key'] or get_setting('reality_public_key')
    return ib


@app.get('/clients/<int:ib_id>')
def clients_page(ib_id):
    with database() as conn:
        row = conn.execute('SELECT * FROM xray_inbounds WHERE id=?', (ib_id,)).fetchone()
        if not row:
            abort(404)
        inbound = effective_inbound(row)
        clients = [dict(r) for r in conn.execute('SELECT * FROM xray_clients WHERE inbound_id=?', (ib_id,))]
        available = [r[0] for r in conn.execute('SELECT username FROM users WHERE status=1 AND username NOT IN '
                                               '(SELECT username FROM xray_clients WHERE inbound_id=?)', (ib_id,))]
    for client in clients:
        client['link'] = gen_link(inbound, client, server_host())
    return render_template('clients.html', inbound=inbound, clients=clients, available_users=available)


@app.post('/add_clients/<int:ib_id>')
def add_clients(ib_id):
    names = list(dict.fromkeys(request.form.getlist('usernames')))
    def insert(conn):
        for name in names:
            username(name)
            conn.execute('INSERT OR IGNORE INTO xray_clients(inbound_id,username,uuid,email,created_at) VALUES(?,?,?,?,?)',
                         (ib_id, name, str(uuid.uuid4()), name, now_text()))
    mutate(insert)
    flash('کلاینت‌ها افزوده شدند', 'success')
    return redirect(url_for('clients_page', ib_id=ib_id))


@app.post('/delete_client/<int:cl_id>')
def delete_client(cl_id):
    def remove(conn):
        row = conn.execute('SELECT inbound_id FROM xray_clients WHERE id=?', (cl_id,)).fetchone()
        if not row:
            raise ValueError('کلاینت یافت نشد')
        conn.execute('DELETE FROM xray_clients WHERE id=?', (cl_id,))
        return row[0]
    ib_id = mutate(remove)
    return redirect(url_for('clients_page', ib_id=ib_id))


@app.get('/groups')
def groups_page():
    with database() as conn:
        groups = [dict(r) for r in conn.execute('SELECT g.*, (SELECT COUNT(*) FROM group_members m '
                                              'WHERE m.group_id=g.id) member_count FROM user_groups g ORDER BY id DESC')]
    return render_template('groups.html', groups=groups)


@app.post('/add_group')
def add_group():
    name = request.form.get('name', '').strip()
    if not 1 <= len(name) <= 100:
        raise ValueError('نام گروه نامعتبر است')
    with state_lock(), database() as conn:
        conn.execute('INSERT INTO user_groups(name,description,created_at) VALUES(?,?,?)',
                     (name, request.form.get('description', '')[:1000], now_text()))
        conn.commit()
    return redirect(url_for('groups_page'))


@app.post('/delete_group/<int:gid>')
def delete_group(gid):
    with state_lock(), database() as conn:
        conn.execute('DELETE FROM user_groups WHERE id=?', (gid,))
        conn.commit()
    return redirect(url_for('groups_page'))


@app.get('/group_members/<int:gid>')
def group_members_page(gid):
    with database() as conn:
        group = conn.execute('SELECT * FROM user_groups WHERE id=?', (gid,)).fetchone()
        if not group:
            abort(404)
        members = [r[0] for r in conn.execute('SELECT username FROM group_members WHERE group_id=?', (gid,))]
        available = [r[0] for r in conn.execute('SELECT username FROM users WHERE username NOT IN '
                                               '(SELECT username FROM group_members WHERE group_id=?)', (gid,))]
    return render_template('group_members.html', group=group, members=members, available_users=available)


@app.post('/add_group_members/<int:gid>')
def add_group_members(gid):
    with state_lock(), database() as conn:
        for name in request.form.getlist('usernames'):
            conn.execute('INSERT OR IGNORE INTO group_members(group_id,username) VALUES(?,?)', (gid, username(name)))
        conn.commit()
    return redirect(url_for('group_members_page', gid=gid))


@app.post('/remove_group_member/<int:gid>/<name>')
def remove_group_member(gid, name):
    with state_lock(), database() as conn:
        conn.execute('DELETE FROM group_members WHERE group_id=? AND username=?', (gid, name))
        conn.commit()
    return redirect(url_for('group_members_page', gid=gid))


def subscription(token):
    with database() as conn:
        row = conn.execute('SELECT * FROM users WHERE sub_token=?', (token,)).fetchone()
        if not row:
            abort(404)
        if not allowed(row):
            abort(403)
        user = dict(row)
        configs = []
        for client in conn.execute('SELECT * FROM xray_clients WHERE username=? AND enable=1 ORDER BY id', (row['username'],)):
            inbound = conn.execute('SELECT * FROM xray_inbounds WHERE id=? AND status=1', (client['inbound_id'],)).fetchone()
            if inbound:
                configs.append((effective_inbound(inbound), dict(client)))
        return user, configs


@app.get('/sub/<token>')
def sub_page(token):
    user, pairs = subscription(token)
    links = [gen_link(ib, client, server_host()) for ib, client in pairs]
    if request.args.get('format') == 'base64':
        body = base64.b64encode('\n'.join(links).encode()).decode()
        return Response(body, mimetype='text/plain')
    plain = decrypt(user['password'])
    uri = ('ssh://' + quote(user['username'], safe='') + ':' + quote(plain, safe='') + '@'
           + authority(server_host()) + ':' + get_setting('ssh_port', default='22') + '#OP-' + user['username'])
    configs = [{'link': link, 'qr': qr_data(link), 'inbound': ib, 'index': i}
               for i, ((ib, _), link) in enumerate(zip(pairs, links))]
    return render_template('sub.html', user=user, password=plain, token=token, ssh_uri=uri,
                           ssh_qr=qr_data(uri), configs=configs,
                           days_left=max(0, (parse_expiry(user['expire_date']) - datetime.now()).days))


@app.get('/download/client/<token>/<int:index>')
def download_client(token, index):
    user, configs = subscription(token)
    if index >= len(configs):
        abort(404)
    ib, client = configs[index]
    body = json.dumps(client_config(ib, client, server_host()), ensure_ascii=False, indent=2)
    return Response(body, mimetype='application/json', headers={
        'Content-Disposition': f'attachment; filename="OP_{user["username"]}_{ib["id"]}.json"'})


@app.get('/download/netmod/<token>/<int:index>')
def download_netmod(token, index):
    return download_client(token, index)


@app.get('/download/nepster/<token>/<int:index>')
def download_nepster(token, index):
    # Never claim a JSON object is a proprietary encrypted .npvt file.
    return download_client(token, index)


@app.get('/reports')
def reports():
    with database() as conn:
        rows = [dict(r) for r in conn.execute('SELECT * FROM users ORDER BY used_traffic DESC')]
    return render_template('reports.html', users=rows, used=sum(r['used_traffic'] or 0 for r in rows) / 1024)


@app.route('/settings', methods=['GET', 'POST'])
def settings():
    if request.method == 'POST':
        action = request.form.get('action')
        if action == 'generate_keys':
            private, public = new_keys()
            # Existing inbounds retain their own pairs; key generation cannot break live links.
            with state_lock(), database() as conn:
                set_setting('reality_private_key', private, conn)
                set_setting('reality_public_key', public, conn)
                conn.commit()
        elif action == 'save_settings':
            domain = host(request.form.get('domain', ''), allow_empty=True)
            admin = request.form.get('admin_username', '').strip()
            if not 1 <= len(admin) <= 64:
                raise ValueError('نام مدیر نامعتبر است')
            port = integer(request.form.get('panel_port', '5000'), 1024, 65535, 'پورت داخلی')
            if port != int(get_setting('panel_port')) and not port_free(port):
                raise ValueError('پورت داخلی آزاد نیست')
            if port in {10085, int(get_setting('public_port', default='80')), int(get_setting('ssh_port', default='22'))}:
                raise ValueError('پورت داخلی رزرو شده است')
            admin_password = request.form.get('admin_password', '')
            if admin_password and not 12 <= len(admin_password) <= 256:
                raise ValueError('رمز مدیر باید بین ۱۲ و ۲۵۶ نویسه باشد')
            def update(conn):
                if conn.execute('SELECT 1 FROM xray_inbounds WHERE port=?', (port,)).fetchone():
                    raise ValueError('پورت داخلی با یک اینباند تداخل دارد')
                for k, v in {'domain': domain, 'admin_username': admin, 'panel_port': port,
                             'block_iran_client': '1' if request.form.get('block_iran') else '0',
                             'pending_panel_restart': '1', 'pending_iran_apply': '1'}.items():
                    set_setting(k, v, conn)
                if admin_password:
                    set_setting('admin_password_hash', generate_password_hash(admin_password), conn)
            mutate(update)
            session['admin_signature'] = admin_signature()
        else:
            raise ValueError('عملیات ناشناخته است')
        flash('تنظیمات ذخیره شد؛ تغییر پورت در چند ثانیه اعمال می‌شود', 'success')
        return redirect(url_for('settings'))
    with database() as conn:
        data = {r['key']: r['value'] for r in conn.execute('SELECT * FROM settings')}
    data.pop('admin_password_hash', None)
    return render_template('settings.html', data=data)


@app.get('/backup_download')
def backup_download():
    return send_file(io.BytesIO(backup_bytes()), as_attachment=True,
                     download_name='OutlineParsian_Backup_v38.zip', mimetype='application/zip')


@app.post('/backup_upload')
def backup_upload():
    file = request.files.get('backup_file')
    if not file or not file.filename:
        raise ValueError('فایل بکاپ انتخاب نشده است')
    queue_restore(file.read(32*1024*1024 + 1))
    flash('بکاپ بررسی شد؛ بازگردانی در چند ثانیه انجام می‌شود', 'success')
    return redirect(url_for('settings'))


if __name__ == '__main__':
    # Development only. The service uses Gunicorn, one process, threaded workers.
    app.run(host='127.0.0.1', port=int(get_setting('panel_port')), debug=False)
OP_SOURCE_APP_PY_END
    cat > "$payload/common.py" <<'OP_SOURCE_COMMON_PY_END'
"""Shared state, validation and non-destructive database migration."""
import base64
import contextlib
import fcntl
import ipaddress
import json
import logging
import math
import os
import pwd
import re
import secrets
import sqlite3
import subprocess
import tempfile
import threading
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import quote, urlencode

from cryptography.fernet import Fernet, InvalidToken
from werkzeug.security import generate_password_hash

BASE = Path(os.environ.get('OP_PANEL_DIR', '/root/ssh-panel')).resolve()
DB_PATH = BASE / 'panel.db'
STATE = BASE / 'state'
ONLINE_FILE = STATE / 'online.json'
XRAY_BIN = os.environ.get('OP_XRAY_BIN', '/usr/local/bin/xray')
XRAY_CONFIG = Path(os.environ.get('OP_XRAY_CONFIG', '/usr/local/etc/xray/config.json'))
XRAY_LOG = Path(os.environ.get('OP_XRAY_LOG', '/var/log/xray/access.log'))
API_ADDR = os.environ.get('OP_XRAY_API', '127.0.0.1:10085')
MARKER = 'OutlineParsian managed account'
MiB = 1024 * 1024
log = logging.getLogger('outlineparsian')
_threads = threading.RLock()
_local = threading.local()


def prepare_dirs():
    for path in (BASE, STATE, BASE / 'backups', BASE / 'templates'):
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.chmod(0o700)


@contextlib.contextmanager
def state_lock():
    """Serialize worker, web requests, configuration swaps and restores."""
    with _threads:
        if getattr(_local, 'depth', 0):
            _local.depth += 1
            try:
                yield
            finally:
                _local.depth -= 1
            return
        with open(STATE / 'panel.lock', 'a', encoding='utf-8') as handle:
            os.chmod(handle.name, 0o600)
            fcntl.flock(handle, fcntl.LOCK_EX)
            _local.depth = 1
            try:
                yield
            finally:
                _local.depth = 0
                fcntl.flock(handle, fcntl.LOCK_UN)


def atomic_bytes(path, content, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'wb') as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def atomic_json(path, obj):
    atomic_bytes(path, json.dumps(obj, ensure_ascii=False).encode())


def secret_file(name, generator):
    path = BASE / name
    # Called during init under state_lock; never replaces an existing key.
    if not path.exists():
        atomic_bytes(path, generator())
    path.chmod(0o600)
    return path.read_bytes().strip()


def cipher(key=None):
    return Fernet(key if key is not None else (BASE / 'credential.key').read_bytes().strip())


def encrypt(value, key=None):
    return 'enc:v1:' + cipher(key).encrypt(value.encode()).decode()


def decrypt(value, key=None):
    if not isinstance(value, str):
        raise ValueError('اطلاعات ورود نامعتبر است')
    if not value.startswith('enc:v1:'):
        return value
    try:
        return cipher(key).decrypt(value[7:].encode()).decode()
    except (InvalidToken, ValueError, UnicodeError) as exc:
        raise ValueError('کلید رمزگشایی با دیتابیس تطابق ندارد') from exc


@contextlib.contextmanager
def database(path=None):
    conn = sqlite3.connect(str(path or DB_PATH), timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA foreign_keys=ON')
    conn.execute('PRAGMA busy_timeout=30000')
    try:
        yield conn
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


def get_setting(key, conn=None, default=''):
    if conn is None:
        with database() as db:
            return get_setting(key, db, default)
    row = conn.execute('SELECT value FROM settings WHERE key=?', (key,)).fetchone()
    return row[0] if row else default


def set_setting(key, value, conn):
    conn.execute('INSERT INTO settings(key,value) VALUES(?,?) '
                 'ON CONFLICT(key) DO UPDATE SET value=excluded.value', (key, str(value)))


def now_text():
    return datetime.now().strftime('%Y-%m-%d %H:%M')


def username(value):
    if not re.fullmatch(r'[a-z][a-z0-9_-]{0,30}', value or ''):
        raise ValueError('نام کاربر باید با حرف کوچک انگلیسی شروع شود و حداکثر ۳۱ حرف باشد')
    if value in {'root', 'admin', 'nobody', 'sshd', 'daemon', 'www-data', 'xray', 'systemd'}:
        raise ValueError('این نام برای حساب سیستمی رزرو شده است')
    return value


def password(value, minimum=8):
    if not isinstance(value, str) or not minimum <= len(value) <= 256:
        raise ValueError('رمز کاربر باید بین ۸ و ۲۵۶ نویسه باشد')
    if any(ch in value for ch in ('\n', '\r', '\x00', ':')):
        raise ValueError('رمز نمی‌تواند شامل خط جدید، نویسهٔ صفر یا دونقطه باشد')
    return value


def integer(value, minimum, maximum, label='عدد'):
    try:
        result = int(value)
    except (ValueError, TypeError):
        raise ValueError(f'{label} نامعتبر است') from None
    if str(value).strip() != str(result) or not minimum <= result <= maximum:
        raise ValueError(f'{label} باید بین {minimum} و {maximum} باشد')
    return result


def traffic_mb(value):
    try:
        result = float(value) * 1024
    except (ValueError, TypeError):
        raise ValueError('حجم نامعتبر است') from None
    if not math.isfinite(result) or not 0 <= result <= 1024 * 1000000:
        raise ValueError('حجم باید عددی متناهی و نامنفی باشد')
    return result


def host(value, allow_empty=False):
    value = (value or '').strip()
    if not value and allow_empty:
        return ''
    try:
        return str(ipaddress.ip_address(value.strip('[]')))
    except ValueError:
        pass
    try:
        value = value.encode('idna').decode('ascii').lower().rstrip('.')
    except UnicodeError:
        raise ValueError('دامنه نامعتبر است') from None
    if len(value) > 253 or not value or any(not re.fullmatch(
            r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', part) for part in value.split('.')):
        raise ValueError('فقط نام دامنه یا IP وارد کنید؛ بدون http، پورت و مسیر')
    return value


def authority(value):
    value = host(value)
    return f'[{value}]' if ':' in value else value


def parse_expiry(value):
    for fmt in ('%Y-%m-%d %H:%M', '%Y-%m-%dT%H:%M', '%Y-%m-%d'):
        try:
            return datetime.strptime(value, fmt)
        except (ValueError, TypeError):
            continue
    raise ValueError('تاریخ انقضا نامعتبر است')


def allowed(user, at=None):
    try:
        return (int(user['status']) == 1 and parse_expiry(user['expire_date']) > (at or datetime.now())
                and (float(user['total_traffic']) <= 0 or float(user['used_traffic']) < float(user['total_traffic'])))
    except (ValueError, TypeError, KeyError):
        return False


def run(args, *, input=None, timeout=20, check=True):
    # No shell invocation, interpolation or unbounded subprocesses.
    result = subprocess.run([str(x) for x in args], input=input, text=True,
                            capture_output=True, timeout=timeout)
    if check and result.returncode:
        # Never log args/input: chpasswd and Xray may contain secrets.
        raise RuntimeError(f'فرمان {Path(str(args[0])).name} ناموفق بود: '
                           + (result.stderr or result.stdout)[-800:])
    return result


def owned_account(name):
    username(name)
    try:
        account = pwd.getpwnam(name)
    except KeyError:
        return None
    if account.pw_uid < 1000 or account.pw_gecos != MARKER or account.pw_dir != f'/home/{name}':
        raise ValueError(f'حساب سیستمی {name} تحت مدیریت این پنل نیست')
    return account


def set_system_password(name, plain):
    if owned_account(name) is None:
        raise ValueError('حساب SSH یافت نشد')
    password(plain, minimum=1)
    run(['chpasswd'], input=f'{name}:{plain}\n')


def ensure_system_user(name, plain):
    username(name)
    password(plain, minimum=1)
    account = owned_account(name)
    if account is None:
        run(['useradd', '--create-home', '--shell', '/bin/bash', '--comment', MARKER,
             '--groups', 'op-panel-users', '--', name])
        # Managed clients are tunnel-only; an SSH Match block disables sessions.
        set_system_password(name, plain)
        return True
    return False


def kill_ssh_session(pid, name):
    """Only terminate a verified child sshd session, never pkill a UID."""
    import psutil
    owned_account(name)
    try:
        proc = psutil.Process(int(pid))
        text = ' '.join(proc.cmdline())
        if re.search(r'\bsshd:\s*' + re.escape(name) + r'(?:\s|@)', text) and proc.pid != os.getpid():
            proc.terminate()
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        pass


def lock_system_user(name, disabled):
    account = owned_account(name)
    if account is None:
        return
    if disabled:
        run(['usermod', '--lock', '--expiredate', '1970-01-02', '--', name])
    else:
        # Clear account expiry as well as the password lock.
        run(['usermod', '--unlock', '--expiredate', '', '--', name])


def init_db(path=None, *, key=None):
    """Migrate v3.7 in place, retain counters/settings/UUIDs; never rename/reset DB."""
    prepare_dirs()
    with state_lock():
        secret_file('credential.key', Fernet.generate_key)
        secret_file('session.key', lambda: secrets.token_hex(32).encode())
        with database(path) as conn:
            conn.execute('PRAGMA journal_mode=WAL')
            conn.executescript('''
                CREATE TABLE IF NOT EXISTS users (
                  username TEXT PRIMARY KEY, password TEXT, expire_date TEXT,
                  total_traffic REAL, used_traffic REAL DEFAULT 0, status INTEGER DEFAULT 1,
                  max_connections INTEGER DEFAULT 2, created_at TEXT);
                CREATE TABLE IF NOT EXISTS xray_inbounds (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, tag TEXT UNIQUE, protocol TEXT, port INTEGER,
                  network TEXT DEFAULT 'tcp', security TEXT DEFAULT 'none', server_name TEXT DEFAULT '',
                  fingerprint TEXT DEFAULT 'chrome', short_id TEXT DEFAULT '', public_key TEXT DEFAULT '',
                  private_key TEXT DEFAULT '', path TEXT DEFAULT '/', status INTEGER DEFAULT 1, created_at TEXT);
                CREATE TABLE IF NOT EXISTS xray_clients (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, inbound_id INTEGER, username TEXT, uuid TEXT, email TEXT,
                  enable INTEGER DEFAULT 1, created_at TEXT,
                  FOREIGN KEY(inbound_id) REFERENCES xray_inbounds(id) ON DELETE CASCADE,
                  FOREIGN KEY(username) REFERENCES users(username) ON DELETE CASCADE);
                CREATE TABLE IF NOT EXISTS user_groups (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, description TEXT, created_at TEXT);
                CREATE TABLE IF NOT EXISTS group_members (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER, username TEXT,
                  FOREIGN KEY(group_id) REFERENCES user_groups(id) ON DELETE CASCADE,
                  FOREIGN KEY(username) REFERENCES users(username) ON DELETE CASCADE);
                CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
                CREATE TABLE IF NOT EXISTS counter_state (
                  source TEXT, name TEXT, generation TEXT, value INTEGER,
                  PRIMARY KEY(source,name));
                CREATE TABLE IF NOT EXISTS runtime_state (key TEXT PRIMARY KEY, value TEXT);
            ''')
            additions = {
                'users': {'sub_token': 'TEXT', 'disabled_reason': "TEXT DEFAULT ''"},
                'xray_inbounds': {'certificate_file': "TEXT DEFAULT ''", 'key_file': "TEXT DEFAULT ''"}
            }
            for table, columns in additions.items():
                present = {r[1] for r in conn.execute(f'PRAGMA table_info({table})')}
                for name, declaration in columns.items():
                    if name not in present:
                        conn.execute(f'ALTER TABLE {table} ADD COLUMN {name} {declaration}')
            # Deduplicate only redundant memberships; retain the first UUID.
            conn.execute('DELETE FROM xray_clients WHERE id NOT IN '
                         '(SELECT MIN(id) FROM xray_clients GROUP BY inbound_id,username)')
            conn.execute('DELETE FROM group_members WHERE id NOT IN '
                         '(SELECT MIN(id) FROM group_members GROUP BY group_id,username)')
            conn.execute('UPDATE xray_clients SET email=username')
            conn.execute('CREATE UNIQUE INDEX IF NOT EXISTS ux_clients ON xray_clients(inbound_id,username)')
            conn.execute('CREATE UNIQUE INDEX IF NOT EXISTS ux_members ON group_members(group_id,username)')
            conn.execute('CREATE UNIQUE INDEX IF NOT EXISTS ux_sub_token ON users(sub_token)')
            conn.execute('CREATE UNIQUE INDEX IF NOT EXISTS ux_inbound_port ON xray_inbounds(port)')
            defaults = {'domain': '', 'admin_username': 'admin', 'block_iran_client': '0',
                        'panel_port': '5000', 'public_port': '80', 'server_address': '127.0.0.1',
                        'reality_private_key': '', 'reality_public_key': '', 'ssl_domain': '', 'ssl_status': 'none'}
            for name, value in defaults.items():
                conn.execute('INSERT OR IGNORE INTO settings(key,value) VALUES(?,?)', (name, value))
            if not get_setting('admin_password_hash', conn):
                plain = get_setting('admin_password', conn)
                if not plain or plain == 'admin123':
                    plain = os.environ.get('OP_ADMIN_PASSWORD') or secrets.token_urlsafe(18)
                    if len(plain) < 12:
                        raise ValueError('رمز مدیر باید دست‌کم ۱۲ نویسه باشد')
                    atomic_bytes(BASE / 'admin-initial.txt',
                                 (get_setting('admin_username', conn) + '\n' + plain + '\n').encode())
                set_setting('admin_password_hash', generate_password_hash(plain), conn)
            conn.execute("DELETE FROM settings WHERE key='admin_password'")
            for row in conn.execute('SELECT * FROM users').fetchall():
                try:
                    username(row['username'])
                except ValueError:
                    conn.execute("UPDATE users SET status=0,disabled_reason='unsafe legacy username' WHERE username=?",
                                 (row['username'],))
                stored = row['password'] or ''
                if stored.startswith('enc:v1:'):
                    decrypt(stored, key)
                else:
                    # Old shorter passwords remain usable; new/edit passwords require >=8.
                    if any(ch in stored for ch in ('\n', '\r', '\x00', ':')):
                        raise ValueError('رمز ناسالم در دیتابیس قدیمی؛ ابتدا آن حساب را اصلاح کنید')
                    conn.execute('UPDATE users SET password=? WHERE username=?', (encrypt(stored, key), row['username']))
                if not row['sub_token']:
                    conn.execute('UPDATE users SET sub_token=? WHERE username=?',
                                 (secrets.token_urlsafe(32), row['username']))
            conn.execute('UPDATE users SET used_traffic=COALESCE(used_traffic,0),total_traffic=COALESCE(total_traffic,0)')
            # Freeze old shared Reality keys into each inbound. Rotating a default
            # must not change existing inbound identities or client links.
            from cryptography.hazmat.primitives import serialization
            from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
            for ib in conn.execute("SELECT id,private_key FROM xray_inbounds WHERE security='reality'").fetchall():
                private = ib['private_key'] or get_setting('reality_private_key', conn)
                if private:
                    try:
                        raw = base64.urlsafe_b64decode(private + '=' * (-len(private) % 4))
                        pub = X25519PrivateKey.from_private_bytes(raw).public_key().public_bytes(
                            serialization.Encoding.Raw, serialization.PublicFormat.Raw)
                    except (ValueError, TypeError):
                        raise ValueError('کلید خصوصی Reality در دیتابیس قدیمی نامعتبر است') from None
                    conn.execute('UPDATE xray_inbounds SET private_key=?,public_key=? WHERE id=?',
                                 (private, base64.urlsafe_b64encode(pub).decode().rstrip('='), ib['id']))
            set_setting('schema_version', '38', conn)
            conn.commit()
        (Path(path) if path else DB_PATH).chmod(0o600)


def save_backup(destination, source=None):
    with database(source) as src, database(destination) as dst:
        src.backup(dst)
    Path(destination).chmod(0o600)


def new_keys():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    private = X25519PrivateKey.generate()
    raw = private.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                serialization.NoEncryption())
    public = private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    encode = lambda b: base64.urlsafe_b64encode(b).decode().rstrip('=')
    return encode(raw), encode(public)


def gen_link(ib, client, server):
    proto, net, sec = ib['protocol'], ib['network'], ib['security']
    ident = client['uuid']
    label = 'OP-' + client['username'] + '-' + ib['tag']
    if proto == 'vmess':
        doc = {'v': '2', 'ps': label, 'add': host(server), 'port': str(ib['port']),
               'id': ident, 'aid': '0', 'net': net, 'type': 'none',
               'host': ib['server_name'] if net == 'ws' else '',
               'path': ib['path'].strip('/') if net == 'grpc' else ib['path'] if net == 'ws' else '',
               'tls': 'tls' if sec == 'tls' else '', 'sni': ib['server_name']}
        return 'vmess://' + base64.b64encode(json.dumps(doc).encode()).decode()
    query = {'type': net, 'security': sec}
    if proto == 'vless':
        query['encryption'] = 'none'
    if sec == 'reality':
        query.update(fp=ib['fingerprint'], sni=ib['server_name'], pbk=ib['public_key'],
                     sid=ib['short_id'], flow='xtls-rprx-vision')
    elif sec == 'tls':
        query['sni'] = ib['server_name']
    if net == 'ws':
        query['path'] = ib['path']
        if ib['server_name']:
            query['host'] = ib['server_name']
    elif net == 'grpc':
        query['serviceName'] = ib['path'].strip('/') or 'grpc'
        query['mode'] = 'gun'
    return f'{proto}://{quote(ident, safe="")}@{authority(server)}:{ib["port"]}?' + urlencode(query) + '#' + quote(label)


if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    init_db()
OP_SOURCE_COMMON_PY_END
    cat > "$payload/gunicorn.conf.py" <<'OP_SOURCE_GUNICORN_CONF_PY_END'
from common import get_setting

bind = '127.0.0.1:' + get_setting('panel_port', default='5000')
workers = 1
threads = 8
worker_class = 'gthread'
timeout = 120
graceful_timeout = 20
accesslog = None  # Subscription bearer tokens must not enter access logs.
errorlog = '-'
capture_output = True
forwarded_allow_ips = '127.0.0.1,::1'
limit_request_line = 4094
limit_request_fields = 50
OP_SOURCE_GUNICORN_CONF_PY_END
    cat > "$payload/maintenance.py" <<'OP_SOURCE_MAINTENANCE_PY_END'
"""Consistent backup and checked restore, including the credential encryption key."""
import io
import json
import os
import pwd
import sqlite3
import tempfile
import zipfile
from datetime import datetime
from pathlib import Path

from cryptography.fernet import Fernet
from common import (BASE, DB_PATH, MARKER, STATE, atomic_bytes, atomic_json, database, decrypt,
                    get_setting, host, init_db, owned_account, password, run, save_backup,
                    state_lock, username)

MAX_DB = 32 * 1024 * 1024
REQUIRED = {'users', 'xray_inbounds', 'xray_clients', 'settings', 'user_groups', 'group_members'}


def backup_bytes():
    with state_lock():
        fd, name = tempfile.mkstemp(prefix='backup-', suffix='.db', dir=BASE / 'backups')
        os.close(fd)
        path = Path(name)
        try:
            save_backup(path)
            output = io.BytesIO()
            with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
                archive.write(path, 'panel.db')
                archive.writestr('credential.key', (BASE / 'credential.key').read_bytes())
                archive.writestr('metadata.json', json.dumps({'format': 'OutlineParsian', 'version': 38}))
            return output.getvalue()
        finally:
            path.unlink(missing_ok=True)


def validate_database(path, key):
    if path.stat().st_size > MAX_DB or not path.read_bytes()[:16] == b'SQLite format 3\x00':
        raise ValueError('بکاپ یک دیتابیس معتبر SQLite نیست')
    Fernet(key.strip())
    with database(path) as conn:
        if conn.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('دیتابیس بکاپ خراب است')
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not REQUIRED <= tables:
            raise ValueError('جدول‌های موردنیاز در بکاپ وجود ندارند')
        if conn.execute('PRAGMA foreign_key_check').fetchone():
            raise ValueError('روابط دیتابیس بکاپ ناسالم است')
        for table in ('users', 'settings', 'xray_clients', 'xray_inbounds'):
            if conn.execute("SELECT 1 FROM sqlite_master WHERE type='trigger' AND tbl_name=?", (table,)).fetchone():
                raise ValueError('بکاپ دارای trigger غیرمجاز است')
        for row in conn.execute('SELECT * FROM users'):
            username(row['username'])
            plain = decrypt(row['password'], key)
            if not plain or any(x in plain for x in ('\r', '\n', '\x00', ':')):
                raise ValueError('رمز ناسالم در بکاپ')
            from common import parse_expiry, traffic_mb, integer
            parse_expiry(row['expire_date'])
            traffic_mb(float(row['total_traffic']) / 1024)
            traffic_mb(float(row['used_traffic']) / 1024)
            integer(str(row['max_connections']), 0, 1000, 'حد IP')
            try:
                existing = pwd.getpwnam(row['username'])
            except KeyError:
                continue
            if existing.pw_uid < 1000 or existing.pw_gecos != MARKER or existing.pw_dir != f'/home/{row["username"]}':
                raise ValueError('نام یک حساب بکاپ با حساب خارج از مدیریت پنل تداخل دارد')
        for name in ('domain', 'ssl_domain', 'server_address'):
            host(get_setting(name, conn), allow_empty=True)
        from common import integer
        internal = integer(get_setting('panel_port', conn), 1024, 65535, 'پورت داخلی')
        public = integer(get_setting('public_port', conn), 1, 65535, 'پورت عمومی')
        ssh_port = integer(get_setting('ssh_port', conn, '22'), 1, 65535, 'پورت SSH')
        occupied = {int(r[0]) for r in conn.execute('SELECT port FROM xray_inbounds')}
        if internal in {public, ssh_port, 10085} | occupied or public in {ssh_port, 10085} | occupied:
            raise ValueError('پورت‌های بکاپ با یک سرویس دیگر تداخل دارند')
        if get_setting('ssl_status', conn) == 'active':
            from system_config import nginx_text
            nginx_text(conn)
        from sync_xray import generate
        generate(conn)  # Schema fields from old v3.7 are added before this call by queue_restore.


def queue_restore(content):
    if len(content) > MAX_DB:
        raise ValueError('فایل بیش از ۳۲ مگابایت است')
    with state_lock():
        if (STATE / 'restore-request.json').exists():
            raise ValueError('یک بازگردانی دیگر در صف است')
        fd, name = tempfile.mkstemp(prefix='restore-', suffix='.db', dir=BASE / 'backups')
        os.close(fd)
        path = Path(name)
        try:
            key = (BASE / 'credential.key').read_bytes().strip()
            if zipfile.is_zipfile(io.BytesIO(content)):
                with zipfile.ZipFile(io.BytesIO(content)) as archive:
                    names = archive.namelist()
                    if set(names) - {'panel.db', 'credential.key', 'metadata.json'} or len(names) != len(set(names)):
                        raise ValueError('ساختار فایل ZIP بکاپ نامعتبر است')
                    if sum(info.file_size for info in archive.infolist()) > MAX_DB + 4096:
                        raise ValueError('حجم محتوای بکاپ بیش از حد مجاز است')
                    atomic_bytes(path, archive.read('panel.db'))
                    key = archive.read('credential.key').strip()
            else:
                atomic_bytes(path, content)
            # Read-only structural checks before migrations; never run arbitrary SQL from an upload.
            if path.read_bytes()[:16] != b'SQLite format 3\x00':
                raise ValueError('فرمت بکاپ نامعتبر است')
            with database(path) as conn:
                triggers = conn.execute("SELECT name FROM sqlite_master WHERE type='trigger'").fetchall()
                tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if triggers or not REQUIRED <= tables or conn.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                    raise ValueError('ساختار بکاپ نامعتبر است')
                # An unsafe default in a legacy backup must not lock its owner
                # out behind a newly generated, undisclosed random password.
                if not get_setting('admin_password_hash', conn) and get_setting('admin_password', conn) == 'admin123':
                    from common import set_setting
                    set_setting('admin_password_hash', get_setting('admin_password_hash'), conn)
                    set_setting('admin_username', get_setting('admin_username'), conn)
                    conn.commit()
            init_db(path, key=key)
            validate_database(path, key)
            from sync_xray import generate, validate_config
            with database(path) as conn:
                validate_config(generate(conn))
            keypath = path.with_suffix('.key')
            atomic_bytes(keypath, key)
            atomic_json(STATE / 'restore-request.json', {'db': path.name, 'key': keypath.name})
        except Exception:
            for candidate in (path, path.with_suffix('.key'), Path(str(path) + '-wal'), Path(str(path) + '-shm')):
                candidate.unlink(missing_ok=True)
            raise


def perform_restore():
    request = STATE / 'restore-request.json'
    if not request.exists():
        return False
    with state_lock():
        payload = json.loads(request.read_text())
        # Queue files are local trusted files; still enforce basename and location.
        if any(Path(payload[k]).name != payload[k] for k in ('db', 'key')):
            raise ValueError('مسیر بازگردانی نامعتبر است')
        candidate, keypath = BASE / 'backups' / payload['db'], BASE / 'backups' / payload['key']
        key = keypath.read_bytes().strip()
        try:
            validate_database(candidate, key)
        except Exception:
            atomic_json(STATE / 'restore-result.json', {'ok': False, 'timestamp': time_text()})
            request.unlink(missing_ok=True)
            raise
        stamp = datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        before = BASE / 'backups' / f'before-restore-{stamp}.db'
        saved_key = (BASE / 'credential.key').read_bytes()
        with database() as conn:
            previous = {r[0] for r in conn.execute('SELECT username FROM users')}
        save_backup(before)
        atomic_bytes(before.with_suffix('.key'), saved_key)
        try:
            run(['systemctl', 'stop', 'ssh-panel'], timeout=30)
            # SQLite's backup API handles the destination WAL, without rm -f of active journals.
            save_backup(DB_PATH, candidate)
            atomic_bytes(BASE / 'credential.key', key)
            from sync_xray import apply, generate
            with database() as conn:
                apply(generate(conn), force=True)
                current = {r[0] for r in conn.execute('SELECT username FROM users')}
                conn.execute('DELETE FROM counter_state')
                conn.execute('DELETE FROM runtime_state')
                set_pending = ('pending_panel_restart', '1')
                from common import set_setting
                set_setting(*set_pending, conn)
                set_setting('pending_iran_apply', '1', conn)
                conn.commit()
            from traffic_worker import reconcile_ssh
            with database() as conn:
                restored_users = [dict(r) for r in conn.execute('SELECT * FROM users')]
            if reconcile_ssh(restored_users, []):
                raise ValueError('بازگردانی حساب‌های SSH ناموفق بود')
            # Orphans stay on disk, but cannot reconnect after restoring a smaller DB.
            from common import lock_system_user
            for name in previous - current:
                try:
                    lock_system_user(name, True)
                    from common import kill_ssh_session
                    from telemetry import ssh_snapshot
                    for session in ssh_snapshot({name}, int(get_setting('ssh_port', default='22'))):
                        kill_ssh_session(session['pid'], name)
                except ValueError:
                    pass
            atomic_json(STATE / 'restore-result.json', {'ok': True, 'timestamp': time_text()})
        except Exception:
            save_backup(DB_PATH, before)
            atomic_bytes(BASE / 'credential.key', saved_key)
            from sync_xray import apply, generate
            with database() as conn:
                apply(generate(conn), force=True)
                previous_users = [dict(r) for r in conn.execute('SELECT * FROM users')]
            from traffic_worker import reconcile_ssh
            reconcile_ssh(previous_users, [])
            atomic_json(STATE / 'restore-result.json', {'ok': False, 'timestamp': time_text()})
            raise
        finally:
            request.unlink(missing_ok=True)
            for p in (candidate, keypath, Path(str(candidate) + '-wal'), Path(str(candidate) + '-shm')):
                p.unlink(missing_ok=True)
            run(['systemctl', 'start', 'ssh-panel'], timeout=30)
        return True


def time_text():
    return datetime.now().isoformat(timespec='seconds')
OP_SOURCE_MAINTENANCE_PY_END
    cat > "$payload/requirements.txt" <<'OP_SOURCE_REQUIREMENTS_TXT_END'
Flask>=3.1,<4
psutil>=6,<8
grpcio>=1.70,<2
grpcio-tools>=1.70,<2
qrcode[pil]>=8,<9
cryptography>=44,<47
gunicorn>=23,<24
OP_SOURCE_REQUIREMENTS_TXT_END
    cat > "$payload/ssh-panel-worker.service" <<'OP_SOURCE_SSH_PANEL_WORKER_SERVICE_END'
[Unit]
Description=OutlineParsian Traffic, Expiry and IP Worker v3.8
After=network-online.target xray.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/ssh-panel
Environment=OP_PANEL_DIR=/root/ssh-panel
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
Environment=PYTHONUNBUFFERED=1
ExecStart=/root/ssh-panel/.venv/bin/python /root/ssh-panel/traffic_worker.py
Restart=on-failure
RestartSec=3
PrivateTmp=true
UMask=0077

[Install]
WantedBy=multi-user.target
OP_SOURCE_SSH_PANEL_WORKER_SERVICE_END
    cat > "$payload/ssh-panel.service" <<'OP_SOURCE_SSH_PANEL_SERVICE_END'
[Unit]
Description=OutlineParsian Panel v3.8
After=network-online.target xray.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/ssh-panel
Environment=OP_PANEL_DIR=/root/ssh-panel
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
Environment=PYTHONUNBUFFERED=1
ExecStart=/root/ssh-panel/.venv/bin/python -m gunicorn -c /root/ssh-panel/gunicorn.conf.py app:app
Restart=on-failure
RestartSec=3
TimeoutStopSec=30
PrivateTmp=true
UMask=0077

[Install]
WantedBy=multi-user.target
OP_SOURCE_SSH_PANEL_SERVICE_END
    cat > "$payload/static/panel.css" <<'OP_SOURCE_STATIC_PANEL_CSS_END'
:root{color-scheme:dark;--bg:#0b090b;--card:#181117;--line:#442333;--red:#ec5a73;--text:#f5eaf0;--muted:#af92a0}*{box-sizing:border-box}body{margin:0;background:radial-gradient(ellipse at top,#2b101e 0,var(--bg) 55%);color:var(--text);font-family:Tahoma,Arial,sans-serif;font-size:14px;line-height:1.85;min-height:100vh}header{display:flex;align-items:center;justify-content:space-between;gap:20px;padding:18px 5%;border-bottom:1px solid var(--line);flex-wrap:wrap;background:#110c10}a{color:var(--text);text-decoration:none}.brand{display:flex;align-items:center;gap:12px;font-size:25px;font-weight:bold;color:var(--red)}.brand span{font-size:18px}.brand small{font-size:12px;font-weight:normal}nav,.actions,.toolbar{display:flex;align-items:center;gap:10px;flex-wrap:wrap}nav a{padding:6px 9px;border-radius:8px}nav a:hover{background:#341622}nav form{margin:0}main{max-width:1320px;margin:auto;padding:32px 24px}h1{font-size:24px;margin:0 0 22px}h2{font-size:18px;margin-top:0}small,.muted{color:var(--muted)}.card{background:var(--card);border:1px solid var(--line);padding:24px;border-radius:17px;margin-bottom:22px;min-width:0}.narrow{max-width:660px;margin:32px auto}.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:14px;margin-bottom:16px}.stats strong{display:block;font-size:28px;color:var(--red);font-variant-numeric:tabular-nums}.stats .card{padding:20px;margin-bottom:0}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:20px}.columns{display:grid;grid-template-columns:1fr 1fr;gap:16px}.toolbar{justify-content:space-between;margin-bottom:20px}.toolbar h1{margin:0}label{display:block;margin-bottom:17px}input,select,textarea{display:block;width:100%;padding:12px 13px;background:#0b090b;border:1px solid var(--line);color:var(--text);border-radius:9px;font:inherit;outline:none;margin-top:5px}input:focus,textarea:focus,select:focus{border-color:var(--red)}textarea{min-height:85px;resize:vertical;direction:ltr;text-align:left;overflow-wrap:anywhere}.mono{font-family:monospace;direction:ltr;unicode-bidi:plaintext;overflow-wrap:anywhere}input[type=checkbox]{width:18px;height:18px;margin:0;accent-color:var(--red)}.check,.checks label{display:flex;gap:10px;align-items:center}.checks{display:flex;gap:12px;flex-wrap:wrap;margin:15px 0}.checks label{padding:10px;background:#29151f;border-radius:9px}button,.button{display:inline-block;cursor:pointer;background:#331b29;border:1px solid #5d3149;padding:9px 15px;border-radius:9px;color:var(--text);font:inherit;line-height:1.6;transition:background .15s}button:hover,.button:hover{background:#53233c}.primary{background:#a32947;border-color:#dd4568}.danger{background:#39141c;color:#ff9db0;border-color:#7d2b3a}.ghost{background:transparent}.inline{display:inline-block;margin:0}.notice{padding:14px 18px;border-radius:10px;margin:0 0 18px;border:1px solid var(--line)}.notice.error{background:#3a1723;color:#ffa5b8}.notice.success{background:#122f24;color:#8de3ae}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;white-space:nowrap;text-align:right}th{color:var(--muted);font-size:12px}td,th{padding:14px 11px;border-bottom:1px solid var(--line)}tr:last-child td{border:0}progress{display:block;width:150px;height:7px;margin-top:8px;accent-color:var(--red)}.badge{padding:4px 10px;border:1px solid #5a2c3e;border-radius:20px;color:#eaaaaf}.badge.active{color:#9ce7b7;border-color:#305944}hr{border:0;border-top:1px solid var(--line);margin:22px 0}.qr{display:block;width:220px;max-width:100%;height:auto;border:10px solid white;border-radius:10px;margin:24px auto}footer{text-align:center;color:var(--muted);padding:30px;font-size:12px}#search{max-width:260px}.hidden{display:none!important}@media(max-width:650px){main{padding:20px 12px}header{padding:14px}nav{gap:3px;font-size:12px}.brand span{font-size:16px}.columns{grid-template-columns:1fr;gap:0}.card{padding:18px}.grid{grid-template-columns:1fr}.stats{grid-template-columns:repeat(2,1fr)}h1{font-size:21px}td,th{padding:12px 8px}.toolbar{align-items:stretch}.toolbar h1{width:100%}#search{max-width:100%;flex:1}button,.button{padding:9px 12px}}
OP_SOURCE_STATIC_PANEL_CSS_END
    cat > "$payload/static/panel.js" <<'OP_SOURCE_STATIC_PANEL_JS_END'
'use strict';
document.querySelectorAll('form[data-confirm]').forEach(form => {
  form.addEventListener('submit', event => {
    if (!window.confirm(form.dataset.confirm)) event.preventDefault();
  });
});
document.querySelectorAll('button.copy').forEach(button => {
  button.addEventListener('click', async () => {
    const area = document.getElementById(button.dataset.target);
    if (!area) return;
    try {
      if (navigator.clipboard && window.isSecureContext) await navigator.clipboard.writeText(area.value);
      else { area.focus(); area.select(); if (!document.execCommand('copy')) throw new Error('copy'); }
      const old = button.textContent; button.textContent = 'کپی شد';
      window.setTimeout(() => { button.textContent = old; }, 1400);
    } catch (_) { area.focus(); area.select(); button.textContent = 'متن را دستی کپی کنید'; }
  });
});
const search = document.getElementById('search');
if (search) {
  search.addEventListener('input', () => {
    const query = search.value.toLowerCase();
    document.querySelectorAll('tr[data-user]').forEach(row => {
      row.classList.toggle('hidden', !row.dataset.user.toLowerCase().includes(query));
    });
  });
  let pending = false;
  const refresh = async () => {
    if (pending || document.hidden) return;
    pending = true;
    try {
      const results = await Promise.all([fetch('/api/stats'), fetch('/api/online')]);
      if (results.some(result => !result.ok)) return;
      const [stats, online] = await Promise.all(results.map(result => result.json()));
      document.getElementById('cpu').textContent = Number(stats.cpu).toFixed(1);
      document.getElementById('ram').textContent = Number(stats.ram).toFixed(1);
      document.querySelectorAll('tr[data-user]').forEach(row => {
        const span = row.querySelector('[data-online]');
        if (span) span.textContent = String(Number(online[row.dataset.user]?.online_count || 0));
      });
    } catch (_) { /* Preserve the last displayed values during a service restart. */ }
    finally { pending = false; }
  };
  refresh(); window.setInterval(refresh, 5000);
}
OP_SOURCE_STATIC_PANEL_JS_END
    cat > "$payload/stats.proto" <<'OP_SOURCE_STATS_PROTO_END'
syntax = "proto3";

package xray.app.stats.command;
option csharp_namespace = "Xray.App.Stats.Command";
option go_package = "github.com/xtls/xray-core/app/stats/command";
option java_package = "com.xray.app.stats.command";
option java_multiple_files = true;

message GetStatsRequest {
  // Name of the stat counter.
  string name = 1;
  // Whether or not to reset the counter to fetching its value.
  bool reset = 2;
}

message Stat {
  string name = 1;
  int64 value = 2;
}

message GetStatsResponse {
  Stat stat = 1;
}

message QueryStatsRequest {
  string pattern = 1;
  bool reset = 2;
}

message QueryStatsResponse {
  repeated Stat stat = 1;
}

message SysStatsRequest {}

message SysStatsResponse {
  uint32 NumGoroutine = 1;
  uint32 NumGC = 2;
  uint64 Alloc = 3;
  uint64 TotalAlloc = 4;
  uint64 Sys = 5;
  uint64 Mallocs = 6;
  uint64 Frees = 7;
  uint64 LiveObjects = 8;
  uint64 PauseTotalNs = 9;
  uint32 Uptime = 10;
}

message GetStatsOnlineIpListResponse {
  string name = 1;
  map<string, int64> ips = 2;
}

service StatsService {
  rpc GetStats(GetStatsRequest) returns (GetStatsResponse) {}
  rpc GetStatsOnline(GetStatsRequest) returns (GetStatsResponse) {}
  rpc QueryStats(QueryStatsRequest) returns (QueryStatsResponse) {}
  rpc GetSysStats(SysStatsRequest) returns (SysStatsResponse) {}
  rpc GetStatsOnlineIpList(GetStatsRequest) returns (GetStatsOnlineIpListResponse) {}
}

message Config {}
OP_SOURCE_STATS_PROTO_END
    cat > "$payload/sync_xray.py" <<'OP_SOURCE_SYNC_XRAY_PY_END'
"""Validate before atomic configuration replacement; roll back failed restarts."""
import json
import os
import re
import socket
import tempfile
from pathlib import Path

from common import (API_ADDR, BASE, XRAY_BIN, XRAY_CONFIG, XRAY_LOG, allowed, atomic_bytes,
                    database, get_setting, host, integer, new_keys, run, state_lock)

RESERVED_TAGS = {'api', 'direct', 'block', 'op-api'}


def validate_inbound(ib, *, check_files=True):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', ib['tag'] or '') or ib['tag'] in RESERVED_TAGS:
        raise ValueError('Tag نامعتبر یا رزرو شده است')
    if ib['protocol'] not in {'vless', 'vmess', 'trojan'}:
        raise ValueError('پروتکل پشتیبانی نمی‌شود')
    integer(str(ib['port']), 1, 65535, 'پورت')
    if ib['network'] not in {'tcp', 'ws', 'grpc'}:
        raise ValueError('Transport پشتیبانی نمی‌شود')
    if ib['security'] not in {'none', 'tls', 'reality'}:
        raise ValueError('Security نامعتبر است')
    if ib['security'] == 'reality':
        # Vision is supported here only for VLESS over raw/TCP.
        if (ib['protocol'], ib['network']) != ('vless', 'tcp'):
            raise ValueError('در این پنل Reality فقط با VLESS + TCP پشتیبانی می‌شود')
        host(ib['server_name'])
        if not re.fullmatch(r'(?:[0-9a-fA-F]{2}){0,8}', ib['short_id'] or ''):
            raise ValueError('Short ID باید زوج، هگزادسیمال و حداکثر ۱۶ نویسه باشد')
        if not ib['private_key'] or not ib['public_key']:
            raise ValueError('کلیدهای Reality وجود ندارند')
    if ib['security'] == 'tls':
        host(ib['server_name'])
        for field in ('certificate_file', 'key_file'):
            path = Path(ib[field] or '')
            if not path.is_absolute() or '\x00' in str(path):
                raise ValueError('مسیر مطلق فایل گواهی و کلید TLS لازم است')
            if check_files and not path.is_file():
                raise ValueError(f'فایل TLS موجود نیست: {field}')
    if ib['protocol'] == 'trojan' and ib['security'] != 'tls':
        raise ValueError('Trojan در این پنل به TLS معتبر نیاز دارد')
    if ib['fingerprint'] not in {'chrome', 'firefox', 'safari', 'ios', 'android', 'edge', 'random', 'randomized'}:
        raise ValueError('Fingerprint نامعتبر است')
    if len(ib['path'] or '') > 256 or any(ch in (ib['path'] or '') for ch in ('\r', '\n', '\x00')):
        raise ValueError('مسیر Transport نامعتبر است')
    if ib['network'] == 'ws' and not (ib['path'] or '').startswith('/'):
        raise ValueError('مسیر WebSocket باید با / شروع شود')


def port_free(port):
    # Binding, rather than substring matching in `ss`, detects real collisions.
    for family, address in ((socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')):
        try:
            with socket.socket(family, socket.SOCK_STREAM) as sock:
                if family == socket.AF_INET6:
                    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                sock.bind((address, port))
        except OSError as exc:
            if family == socket.AF_INET6 and exc.errno in (97, 99):
                continue
            return False
    return True


def base_rules(conn, blocked=None):
    rules = []
    for name, addresses in sorted((blocked or {}).items()):
        if addresses:
            rules.append({'type': 'field', 'ruleTag': 'op-limit-' + name,
                          'user': [name], 'source': sorted(addresses), 'outboundTag': 'block'})
    if get_setting('block_iran_client', conn) == '1':
        rules.append({'type': 'field', 'ruleTag': 'op-iran', 'ip': ['geoip:ir'], 'outboundTag': 'block'})
    # No catch-all inbound rule: default outbound `direct` applies after limit rules.
    return rules


def generate(conn):
    inbounds = []
    for row in conn.execute('SELECT * FROM xray_inbounds WHERE status=1 ORDER BY id').fetchall():
        ib = dict(row)
        ib['private_key'] = ib['private_key'] or get_setting('reality_private_key', conn)
        ib['public_key'] = ib['public_key'] or get_setting('reality_public_key', conn)
        if ib['security'] == 'tls' and not ib['certificate_file']:
            domain = get_setting('ssl_domain', conn) or ib['server_name']
            ib['certificate_file'] = f'/etc/letsencrypt/live/{host(domain)}/fullchain.pem'
            ib['key_file'] = f'/etc/letsencrypt/live/{host(domain)}/privkey.pem'
        validate_inbound(ib)
        # Keep empty inbounds: adding an inbound must open its configured port.
        clients = []
        for cl in conn.execute('SELECT cl.*, u.status, u.expire_date, u.total_traffic, u.used_traffic '
                               'FROM xray_clients cl JOIN users u ON u.username=cl.username '
                               'WHERE cl.inbound_id=? AND cl.enable=1 ORDER BY cl.id', (ib['id'],)):
            if not allowed(cl):
                continue
            obj = {'email': cl['username'], 'level': 0}
            if ib['protocol'] == 'trojan':
                obj['password'] = cl['uuid']
            else:
                obj['id'] = cl['uuid']
            if ib['security'] == 'reality':
                obj['flow'] = 'xtls-rprx-vision'
            clients.append(obj)
        settings = {'clients': clients}
        if ib['protocol'] == 'vless':
            settings['decryption'] = 'none'
        stream = {'network': ib['network'], 'security': ib['security']}
        if ib['security'] == 'reality':
            stream['realitySettings'] = {
                'dest': host(ib['server_name']) + ':443', 'serverNames': [host(ib['server_name'])],
                'privateKey': ib['private_key'], 'shortIds': [ib['short_id'] or '']}
        elif ib['security'] == 'tls':
            stream['tlsSettings'] = {'serverName': ib['server_name'],
                                     'certificates': [{'certificateFile': ib['certificate_file'],
                                                       'keyFile': ib['key_file']}]}
        if ib['network'] == 'ws':
            stream['wsSettings'] = {'path': ib['path'] or '/'}
        elif ib['network'] == 'grpc':
            stream['grpcSettings'] = {'serviceName': ib['path'].strip('/') or 'grpc'}
        inbounds.append({'tag': ib['tag'], 'listen': '0.0.0.0', 'port': ib['port'],
                         'protocol': ib['protocol'], 'settings': settings, 'streamSettings': stream})
    return {
        'log': {'loglevel': 'warning', 'access': str(XRAY_LOG), 'error': str(XRAY_LOG.parent / 'error.log')},
        'api': {'tag': 'op-api', 'listen': API_ADDR, 'services': ['StatsService', 'RoutingService', 'LoggerService']},
        'stats': {}, 'inbounds': inbounds,
        'outbounds': [{'protocol': 'freedom', 'tag': 'direct'}, {'protocol': 'blackhole', 'tag': 'block'}],
        'routing': {'domainStrategy': 'AsIs', 'rules': base_rules(conn)},
        'policy': {'levels': {'0': {'statsUserUplink': True, 'statsUserDownlink': True, 'statsUserOnline': True}},
                   'system': {'statsInboundUplink': True, 'statsInboundDownlink': True}}
    }


def validate_config(config):
    fd, name = tempfile.mkstemp(prefix='xray-candidate-', suffix='.json', dir=STATE_DIR())
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            json.dump(config, handle)
        run([XRAY_BIN, 'run', '-test', '-config', name], timeout=20)
    finally:
        Path(name).unlink(missing_ok=True)


def STATE_DIR():
    return BASE / 'state'


def apply(config, *, force=False):
    validate_config(config)
    encoded = (json.dumps(config, indent=2) + '\n').encode()
    old = XRAY_CONFIG.read_bytes() if XRAY_CONFIG.exists() else None
    if not force and old == encoded and run(['systemctl', 'is-active', '--quiet', 'xray'], check=False).returncode == 0:
        return False
    atomic_bytes(XRAY_CONFIG, encoded)
    try:
        run(['systemctl', 'restart', 'xray'], timeout=30)
        if run(['systemctl', 'is-active', '--quiet', 'xray'], check=False).returncode:
            raise RuntimeError('Xray پس از راه‌اندازی فعال نشد')
    except Exception:
        if old is not None:
            atomic_bytes(XRAY_CONFIG, old)
            run(['systemctl', 'restart', 'xray'], timeout=30, check=False)
        else:
            XRAY_CONFIG.unlink(missing_ok=True)
        raise
    return True


def sync():
    from telemetry import capture_xray
    with state_lock(), database() as conn:
        capture_xray(conn)  # Capture before any graceful restart, without reset=True.
        conn.commit()
        return apply(generate(conn))


def client_config(ib, client, server):
    proto = ib['protocol']
    if proto == 'trojan':
        settings = {'servers': [{'address': host(server), 'port': ib['port'], 'password': client['uuid']}]}
    else:
        obj = {'id': client['uuid'], 'encryption': 'none'} if proto == 'vless' else {'id': client['uuid'], 'alterId': 0}
        if ib['security'] == 'reality':
            obj['flow'] = 'xtls-rprx-vision'
        settings = {'vnext': [{'address': host(server), 'port': ib['port'], 'users': [obj]}]}
    stream = {'network': ib['network'], 'security': ib['security']}
    if ib['security'] == 'reality':
        stream['realitySettings'] = {'serverName': ib['server_name'], 'fingerprint': ib['fingerprint'],
                                     'publicKey': ib['public_key'], 'shortId': ib['short_id']}
    elif ib['security'] == 'tls':
        stream['tlsSettings'] = {'serverName': ib['server_name'], 'allowInsecure': False}
    if ib['network'] == 'ws':
        stream['wsSettings'] = {'path': ib['path'] or '/'}
        if ib['server_name']:
            stream['wsSettings']['headers'] = {'Host': ib['server_name']}
    elif ib['network'] == 'grpc':
        stream['grpcSettings'] = {'serviceName': ib['path'].strip('/') or 'grpc'}
    return {'log': {'loglevel': 'warning'},
            'inbounds': [{'listen': '127.0.0.1', 'port': 10808, 'protocol': 'socks',
                          'settings': {'udp': True}}],
            'outbounds': [{'tag': 'proxy', 'protocol': proto, 'settings': settings, 'streamSettings': stream}]}


if __name__ == '__main__':
    sync()
OP_SOURCE_SYNC_XRAY_PY_END
    cat > "$payload/system_config.py" <<'OP_SOURCE_SYSTEM_CONFIG_PY_END'
"""Update panel services without changing unrelated SSH, Nginx or firewall policy."""
import ipaddress
import os
import pwd
import tempfile
import time
from pathlib import Path
import urllib.request

from common import (BASE, MARKER, atomic_bytes, database, get_setting, host, owned_account,
                    run, set_setting, state_lock)

NGINX_PATH = Path(os.environ.get('OP_NGINX_CONFIG', '/etc/nginx/sites-available/outlineparsian.conf'))


def nginx_text(conn):
    backend = int(get_setting('panel_port', conn))
    public = int(get_setting('public_port', conn, '80'))
    server = host(get_setting('domain', conn) or get_setting('server_address', conn))
    # IPv6 IP literals are accepted as server_name; no user strings reach directives unvalidated.
    tls_domain = get_setting('ssl_domain', conn)
    tls = get_setting('ssl_status', conn) == 'active'
    ssl_lines = ''
    listen = f'listen {public};\n    listen [::]:{public};'
    if tls:
        tls_domain = host(tls_domain)
        cert = Path(f'/etc/letsencrypt/live/{tls_domain}/fullchain.pem')
        key = Path(f'/etc/letsencrypt/live/{tls_domain}/privkey.pem')
        if not cert.is_file() or not key.is_file():
            raise ValueError('گواهی HTTPS پنل موجود نیست')
        listen = f'listen {public} ssl;\n    listen [::]:{public} ssl;'
        ssl_lines = f'\n    ssl_certificate {cert};\n    ssl_certificate_key {key};\n    ssl_protocols TLSv1.2 TLSv1.3;'
    return f'''# OutlineParsian managed v3.8
server {{
    {listen}
    server_name {server};{ssl_lines}
    client_max_body_size 32m;
    location / {{
        proxy_pass http://127.0.0.1:{backend};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
        proxy_redirect off;
    }}
}}
'''


def nginx_apply(conn):
    prior = NGINX_PATH.read_bytes() if NGINX_PATH.exists() else None
    atomic_bytes(NGINX_PATH, nginx_text(conn).encode(), 0o644)
    try:
        run(['nginx', '-t'])
        run(['systemctl', 'reload-or-restart', 'nginx'], timeout=30)
    except Exception:
        if prior is None:
            NGINX_PATH.unlink(missing_ok=True)
        else:
            atomic_bytes(NGINX_PATH, prior, 0o644)
        raise


def iran_apply(conn):
    """Destination blocking only for panel users. No global INPUT/OUTPUT DROP."""
    enabled = get_setting('block_iran_client', conn) == '1'
    accounts = []
    for row in conn.execute('SELECT username FROM users'):
        try:
            account = owned_account(row[0])
            if account:
                accounts.append(account.pw_uid)
        except ValueError:
            pass
    for tool, family, suffix, url in [
        ('iptables', 'inet', '4', 'https://www.ipdeny.com/ipblocks/data/aggregated/ir-aggregated.zone'),
        ('ip6tables', 'inet6', '6', 'https://www.ipdeny.com/ipv6/ipaddresses/aggregated/ir-aggregated.zone')]:
        chain, setname = 'OP_IRAN', 'op_iran_' + suffix
        run([tool, '-w', '5', '-N', chain], check=False)
        if run([tool, '-w', '5', '-C', 'OUTPUT', '-j', chain], check=False).returncode:
            run([tool, '-w', '5', '-I', 'OUTPUT', '1', '-j', chain])
        # Only this application's chain is ever flushed.
        if not enabled:
            run([tool, '-w', '5', '-F', chain])
            continue
        req = urllib.request.Request(url, headers={'User-Agent': 'OutlineParsian/3.8'})
        content = urllib.request.urlopen(req, timeout=15).read(4*1024*1024).decode()
        networks = [str(ipaddress.ip_network(line.strip(), strict=False)) for line in content.splitlines() if line.strip()]
        if not networks or any(ipaddress.ip_network(n).version != int(suffix) for n in networks):
            raise ValueError('فهرست شبکه‌های ایران نامعتبر است')
        temporary = setname + '_new'
        run(['ipset', 'create', setname, 'hash:net', 'family', family, 'maxelem', '200000', '-exist'])
        run(['ipset', 'create', temporary, 'hash:net', 'family', family, 'maxelem', '200000', '-exist'])
        run(['ipset', 'flush', temporary])
        run(['ipset', 'restore'], input=''.join(f'add {temporary} {n}\n' for n in networks))
        run(['ipset', 'swap', temporary, setname])
        run(['ipset', 'destroy', temporary])
        # IPv4/IPv6 destination rules are bound to each owned UID, excluding administrator sessions.
        run([tool, '-w', '5', '-F', chain])
        for uid in accounts:
            run([tool, '-w', '5', '-A', chain, '-m', 'owner', '--uid-owner', uid,
                 '-m', 'set', '--match-set', setname, 'dst', '-j', 'REJECT'])


def apply_pending():
    with state_lock(), database() as conn:
        due = (get_setting('block_iran_client', conn) == '1'
               and time.time() - float(get_setting('iran_updated_at', conn, '0')) > 86400)
        if get_setting('pending_iran_apply', conn) == '1' or due:
            iran_apply(conn)
            set_setting('pending_iran_apply', '0', conn)
            set_setting('iran_updated_at', str(time.time()), conn)
            conn.commit()
        if get_setting('pending_panel_restart', conn) == '1':
            # Validate Nginx before replacing the backend process.
            nginx_apply(conn)
            run(['systemctl', 'restart', 'ssh-panel'], timeout=30)
            set_setting('pending_panel_restart', '0', conn)
            conn.commit()


def initial_apply():
    with state_lock(), database() as conn:
        nginx_apply(conn)
        iran_apply(conn)


if __name__ == '__main__':
    initial_apply()
OP_SOURCE_SYSTEM_CONFIG_PY_END
    cat > "$payload/telemetry.py" <<'OP_SOURCE_TELEMETRY_PY_END'
"""Cumulative traffic counters committed together with their SQLite baselines."""
import importlib
import ipaddress
import re
import time
import logging
from pathlib import Path

import grpc
import psutil

from common import API_ADDR, MiB, XRAY_BIN, log, run


def generation():
    try:
        pid = int(run(['systemctl', 'show', 'xray', '--property=MainPID', '--value'], timeout=5).stdout.strip())
        if pid <= 0:
            return None
        proc = psutil.Process(pid)
        return f'{pid}:{proc.create_time():.6f}'
    except (ValueError, RuntimeError, psutil.Error):
        return None


def account_snapshot(conn, source, epoch, counters):
    """Counter and usage updates share the caller's transaction; retries are idempotent."""
    if not epoch:
        raise ValueError('شناسهٔ نسل شمارنده موجود نیست')
    usage = {}
    for name, (user, value) in counters.items():
        if not isinstance(value, int) or value < 0:
            continue
        if not conn.execute('SELECT 1 FROM users WHERE username=?', (user,)).fetchone():
            continue
        row = conn.execute('SELECT generation,value FROM counter_state WHERE source=? AND name=?',
                           (source, name)).fetchone()
        delta = value if not row or row['generation'] != epoch or value < row['value'] else value - row['value']
        usage[user] = usage.get(user, 0) + delta
        conn.execute('INSERT INTO counter_state(source,name,generation,value) VALUES(?,?,?,?) '
                     'ON CONFLICT(source,name) DO UPDATE SET generation=excluded.generation,value=excluded.value',
                     (source, name, epoch, value))
    for user, count in usage.items():
        conn.execute('UPDATE users SET used_traffic=COALESCE(used_traffic,0)+? WHERE username=?',
                     (count / MiB, user))
    return usage


def capture_xray(conn):
    before = generation()
    if not before:
        return False
    try:
        pb = importlib.import_module('stats_pb2')
        rpc = importlib.import_module('stats_pb2_grpc')
        with grpc.insecure_channel(API_ADDR) as channel:
            response = rpc.StatsServiceStub(channel).QueryStats(pb.QueryStatsRequest(pattern='user>>>', reset=False), timeout=5)
        if generation() != before:
            # Never attribute a snapshot to a different Xray process.
            return False
        counters = {}
        for stat in response.stat:
            parts = stat.name.split('>>>')
            if len(parts) == 4 and parts[0] == 'user' and parts[2] == 'traffic' and parts[3] in ('uplink', 'downlink'):
                counters[stat.name] = (parts[1], stat.value)
        account_snapshot(conn, 'xray', before, counters)
        return True
    except grpc.RpcError as exc:
        log.warning('Xray traffic API unavailable (%s)', exc.code())
        return False


def xray_online(users):
    pb = importlib.import_module('stats_pb2')
    rpc = importlib.import_module('stats_pb2_grpc')
    result, healthy = {}, True
    now = time.time()
    with grpc.insecure_channel(API_ADDR) as channel:
        stub = rpc.StatsServiceStub(channel)
        for user in users:
            try:
                resp = stub.GetStatsOnlineIpList(pb.GetStatsRequest(name=f'user>>>{user}>>>online'), timeout=2)
                addresses = {}
                for address, seen in resp.ips.items():
                    try:
                        address = normalized_ip(address)
                    except ValueError:
                        continue
                    if -5 <= now - seen <= 20:
                        addresses[address] = seen
                result[user] = addresses
            except grpc.RpcError as exc:
                if exc.code() != grpc.StatusCode.NOT_FOUND:
                    healthy = False
                    log.warning('Xray online API unavailable (%s)', exc.code())
                    break
                result[user] = {}
    return result, healthy


def normalized_ip(value):
    parsed = ipaddress.ip_address(value.split('%', 1)[0])
    return str(parsed.ipv4_mapped) if isinstance(parsed, ipaddress.IPv6Address) and parsed.ipv4_mapped else str(parsed)


def endpoint(value):
    # IPv4, bracketed IPv6 and unbracketed IPv6 from iproute2.
    address, port = value.rsplit(':', 1)
    return normalized_ip(address.strip('[]')), int(port)


def ssh_username(pid, permitted):
    try:
        proc = psutil.Process(pid)
        text = ' '.join(proc.cmdline())
        match = re.search(r'\bsshd:\s*([a-z][a-z0-9_-]*)(?:\s|@)', text)
        if match and match[1] in permitted:
            return match[1]
        if proc.username() in permitted and proc.name() in ('sshd', 'sshd-session'):
            return proc.username()
    except psutil.Error:
        pass
    return None


def parse_ss(text, permitted, resolver=ssh_username, ssh_port=22):
    """Split by endpoint patterns, not fixed offsets; multiple PID owners deduplicate by inode."""
    sessions = {}
    current = None
    for line in text.splitlines():
        if line and not line[0].isspace():
            current = None
            fields = line.split()
            endpoints = []
            for item in fields:
                try:
                    endpoints.append(endpoint(item))
                except (ValueError, IndexError):
                    continue
                if len(endpoints) == 2:
                    break
            if len(endpoints) != 2 or endpoints[0][1] != ssh_port:
                continue
            name, pid = None, None
            for ident in re.findall(r'pid=(\d+)', line):
                resolved = resolver(int(ident), permitted)
                if resolved:
                    name, pid = resolved, int(ident)
                    break
            if not name:
                continue
            inode = re.search(r'\bino:(\d+)', line)
            cookie = re.search(r'\bsk:([0-9a-f]+)', line)
            if not inode and not cookie:
                # A persistent socket identity is required for safe counter accounting.
                continue
            ip, peer_port = endpoints[1]
            identity = f'{inode[1] if inode else ""}:{cookie[1] if cookie else ""}:{ip}:{peer_port}'
            current = {'key': identity, 'username': name, 'pid': pid, 'ip': ip,
                       'bytes_acked': 0, 'bytes_received': 0, 'has_counters': False}
            sessions[identity] = current
        if current is not None:
            for name in ('bytes_acked', 'bytes_received'):
                match = re.search(r'\b' + name + r':(\d+)', line)
                if match:
                    current[name] = int(match[1])
                    current['has_counters'] = True
    return list(sessions.values())


def ssh_snapshot(permitted, ssh_port=22):
    result = run(['ss', '-Htnpie', 'state', 'established'], timeout=10)
    return parse_ss(result.stdout, permitted, ssh_port=ssh_port)


def capture_ssh(conn, sessions):
    # TCP byte counters include SSH overhead. Very short/closed-between-polls
    # sessions may be missed; do not market this as an exact billing meter.
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    counters = {s['key']: (s['username'], s['bytes_acked'] + s['bytes_received'])
                for s in sessions if s['has_counters']}
    account_snapshot(conn, 'ssh', boot, counters)
    # Remove only closed SSH identities. Live identities survive worker restarts.
    live = {s['key'] for s in sessions}
    for row in conn.execute("SELECT name FROM counter_state WHERE source='ssh'").fetchall():
        if row[0] not in live:
            conn.execute("DELETE FROM counter_state WHERE source='ssh' AND name=?", (row[0],))


def sweep_expired(conn, at=None):
    from common import allowed
    changed = []
    for row in conn.execute('SELECT * FROM users WHERE status=1').fetchall():
        if not allowed(row, at):
            reason = 'traffic' if row['total_traffic'] and row['used_traffic'] >= row['total_traffic'] else 'expiry'
            conn.execute('UPDATE users SET status=0,disabled_reason=? WHERE username=?', (reason, row['username']))
            changed.append(row['username'])
    return changed
OP_SOURCE_TELEMETRY_PY_END
    cat > "$payload/templates/base.html" <<'OP_SOURCE_TEMPLATES_BASE_HTML_END'
<!doctype html>
<html lang="fa" dir="rtl">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{% block title %}OutlineParsian{% endblock %}</title>
<link rel="stylesheet" href="{{ url_for('static', filename='panel.css') }}">
<script src="{{ url_for('static', filename='panel.js') }}" defer></script></head>
<body><header><a class="brand" href="{{ url_for('dashboard') }}">OP <span>OutlineParsian <small>v{{ version }}</small></span></a>
{% if session.get('logged_in') %}<nav><a href="{{ url_for('dashboard') }}">کاربران</a><a href="{{ url_for('inbounds_page') }}">اینباندها</a>
<a href="{{ url_for('groups_page') }}">گروه‌ها</a><a href="{{ url_for('reports') }}">گزارش</a><a href="{{ url_for('settings') }}">تنظیمات</a>
<form action="{{ url_for('logout') }}" method="post"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><button class="ghost">خروج</button></form></nav>{% endif %}</header>
<main>{% for category,message in get_flashed_messages(with_categories=true) %}<div class="notice {{ category }}">{{ message }}</div>{% endfor %}
{% block content %}{% endblock %}</main><footer>OutlineParsian · SSH + Xray</footer></body></html>
OP_SOURCE_TEMPLATES_BASE_HTML_END
    cat > "$payload/templates/clients.html" <<'OP_SOURCE_TEMPLATES_CLIENTS_HTML_END'
{% extends 'base.html' %}{% from 'macros.html' import csrf, delete, selectable with context %}
{% block content %}<h1>کلاینت‌های {{ inbound.tag }}</h1><section class="card"><h2>افزودن کاربران</h2><form action="{{ url_for('add_clients', ib_id=inbound.id) }}" method="post">{{ csrf() }}{{ selectable(available_users) }}<button class="primary">افزودن</button></form></section>
<div class="grid">{% for cl in clients %}<section class="card"><h2>{{ cl.username }}</h2><textarea readonly id="client-{{ cl.id }}" class="mono">{{ cl.link }}</textarea>
<div class="actions"><button type="button" class="copy" data-target="client-{{ cl.id }}">کپی لینک</button>{{ delete(url_for('delete_client', cl_id=cl.id)) }}</div></section>{% endfor %}</div>{% endblock %}
OP_SOURCE_TEMPLATES_CLIENTS_HTML_END
    cat > "$payload/templates/dashboard.html" <<'OP_SOURCE_TEMPLATES_DASHBOARD_HTML_END'
{% extends 'base.html' %}{% from 'macros.html' import delete with context %}
{% block content %}<div class="stats"><section class="card"><small>کل کاربران</small><strong>{{ users|length }}</strong></section>
<section class="card"><small>فعال</small><strong>{{ active_count }}</strong></section><section class="card"><small>اینباند</small><strong>{{ inbounds }}</strong></section>
<section class="card"><small>کلاینت</small><strong>{{ clients }}</strong></section><section class="card"><small>مصرف GiB</small><strong>{{ '%.3f'|format(used) }}</strong></section></div>
<div class="toolbar"><h1>مدیریت کاربران</h1><input id="search" placeholder="جستجوی نام کاربر" aria-label="جستجو"><a class="button primary" href="{{ url_for('add_user_page') }}">کاربر جدید</a></div>
<p class="muted">CPU <span id="cpu">—</span>% · RAM <span id="ram">—</span>% · تعداد آنلاین بر اساس IP یکتا است؛ چند دستگاه پشت یک مودم ممکن است یک IP داشته باشند.</p>
{% if online.get('stale') or not online.get('xray_traffic_ok', False) %}<p class="notice error">اطلاعات مصرف یا آنلاین Xray تازه نیست؛ وضعیت سرویس worker و API را بررسی کنید.</p>{% endif %}
<div class="card table-wrap"><table><thead><tr><th>کاربر</th><th>رمز SSH</th><th>IP فعال</th><th>مصرف / حجم GiB</th><th>انقضا</th><th>وضعیت</th><th>عملیات</th></tr></thead><tbody>
{% for user in users %}<tr data-user="{{ user.username }}"><td class="mono">{{ user.username }}</td><td class="mono">{{ user.password }}</td>
<td><span data-online>{{ user.online.get('online_count', 0) }}</span> / {{ user.max_connections if user.max_connections else '∞' }}</td>
<td>{{ '%.3f'|format((user.used_traffic or 0)/1024) }} / {{ '%.3f'|format(user.total_traffic/1024) if user.total_traffic else '∞' }}
{% if user.total_traffic %}<progress max="{{ user.total_traffic }}" value="{{ [user.used_traffic or 0,user.total_traffic]|min }}"></progress>{% endif %}</td>
<td class="mono">{{ user.expire_date }}</td><td><span class="badge {{ 'active' if user.active else '' }}">{{ 'فعال' if user.active else 'غیرفعال' }}</span></td>
<td><div class="actions"><a href="{{ url_for('edit_user_page', name=user.username) }}" class="button">ویرایش</a>
{% if user.sub_token %}<a href="{{ user.sub_link }}" class="button" target="_blank" rel="noreferrer">اشتراک</a>{% endif %}
{{ delete(url_for('delete_user', name=user.username)) }}</div></td></tr>{% else %}<tr><td colspan="7">هنوز کاربری ایجاد نشده است.</td></tr>{% endfor %}
</tbody></table></div>{% endblock %}
OP_SOURCE_TEMPLATES_DASHBOARD_HTML_END
    cat > "$payload/templates/error.html" <<'OP_SOURCE_TEMPLATES_ERROR_HTML_END'
{% extends 'base.html' %}{% block content %}<section class="card"><h1>عملیات ناموفق</h1><p>{{ error_message }}</p><a class="button" href="{{ url_for('dashboard') }}">بازگشت</a></section>{% endblock %}
OP_SOURCE_TEMPLATES_ERROR_HTML_END
    cat > "$payload/templates/group_members.html" <<'OP_SOURCE_TEMPLATES_GROUP_MEMBERS_HTML_END'
{% extends 'base.html' %}{% from 'macros.html' import csrf, delete, selectable with context %}
{% block content %}<h1>اعضای {{ group.name }}</h1><section class="card"><form method="post" action="{{ url_for('add_group_members', gid=group.id) }}">{{ csrf() }}{{ selectable(available_users) }}<button class="primary">افزودن اعضا</button></form></section>
<div class="grid">{% for name in members %}<section class="card"><h2>{{ name }}</h2>{{ delete(url_for('remove_group_member', gid=group.id, name=name), 'حذف از گروه') }}</section>{% endfor %}</div>{% endblock %}
OP_SOURCE_TEMPLATES_GROUP_MEMBERS_HTML_END
    cat > "$payload/templates/groups.html" <<'OP_SOURCE_TEMPLATES_GROUPS_HTML_END'
{% extends 'base.html' %}{% from 'macros.html' import csrf, delete with context %}
{% block content %}<h1>گروه‌ها</h1><section class="card"><form method="post" action="{{ url_for('add_group') }}">{{ csrf() }}<div class="columns">
<label>نام گروه<input name="name" required maxlength="100"></label><label>توضیح<input name="description" maxlength="1000"></label></div><button class="primary">ایجاد گروه</button></form></section>
<div class="grid">{% for group in groups %}<section class="card"><h2>{{ group.name }}</h2><p>{{ group.description }}</p><p>{{ group.member_count }} عضو</p>
<div class="actions"><a class="button" href="{{ url_for('group_members_page', gid=group.id) }}">اعضا</a>{{ delete(url_for('delete_group', gid=group.id)) }}</div></section>{% endfor %}</div>{% endblock %}
OP_SOURCE_TEMPLATES_GROUPS_HTML_END
    cat > "$payload/templates/inbound_form.html" <<'OP_SOURCE_TEMPLATES_INBOUND_FORM_HTML_END'
{% extends 'base.html' %}{% from 'macros.html' import csrf with context %}
{% block content %}<section class="card narrow"><h1>اینباند جدید</h1><form method="post" action="{{ url_for('add_inbound') }}">{{ csrf() }}
<label>Tag<input name="tag" pattern="[A-Za-z0-9_-]{1,64}" maxlength="64" required></label>
<label>پورت<input type="number" name="port" value="{{ random_port }}" min="1" max="65535" required></label>
<div class="columns"><label>پروتکل<select name="protocol"><option>vless</option><option>vmess</option><option>trojan</option></select></label>
<label>Transport<select name="network"><option>tcp</option><option>ws</option><option>grpc</option></select></label></div>
<label>Security<select name="security"><option>reality</option><option>tls</option><option>none</option></select></label>
<p class="muted">Reality فقط برای VLESS + TCP؛ Trojan به TLS معتبر نیاز دارد. انتخاب TLS به دو فایل گواهی و کلید نیاز دارد.</p>
<label>SNI / نام سرور<input name="server_name" value="www.microsoft.com" maxlength="253"></label>
<label>Fingerprint<select name="fingerprint"><option>chrome</option><option>firefox</option><option>safari</option><option>ios</option><option>android</option><option>edge</option><option>random</option><option>randomized</option></select></label>
<label>Short ID (خالی = خودکار)<input name="short_id" maxlength="16" pattern="([0-9a-fA-F]{2}){0,8}"></label>
<label>مسیر WebSocket یا serviceName در gRPC<input name="path" value="/" maxlength="256"></label>
<label>مسیر فایل fullchain.pem برای TLS<input name="certificate_file" placeholder="/etc/letsencrypt/live/example.com/fullchain.pem"></label>
<label>مسیر فایل privkey.pem برای TLS<input name="key_file" placeholder="/etc/letsencrypt/live/example.com/privkey.pem"></label>
<button class="primary">بررسی و ایجاد</button></form></section>{% endblock %}
OP_SOURCE_TEMPLATES_INBOUND_FORM_HTML_END
    cat > "$payload/templates/inbounds.html" <<'OP_SOURCE_TEMPLATES_INBOUNDS_HTML_END'
{% extends 'base.html' %}{% from 'macros.html' import delete with context %}
{% block content %}<div class="toolbar"><h1>اینباندهای Xray</h1><a href="{{ url_for('add_inbound_page') }}" class="button primary">اینباند جدید</a></div>
<div class="grid">{% for ib in inbounds %}<section class="card"><h2>{{ ib.tag }}</h2><p class="mono">{{ ib.protocol }} · {{ ib.port }} · {{ ib.network }} · {{ ib.security }}</p>
<p>{{ ib.client_count }} کلاینت · {{ 'فعال' if ib.status else 'غیرفعال' }}</p><div class="actions"><a href="{{ url_for('clients_page', ib_id=ib.id) }}" class="button">مدیریت کلاینت‌ها</a>{{ delete(url_for('delete_inbound', ib_id=ib.id)) }}</div></section>{% else %}<p>هنوز اینباندی وجود ندارد.</p>{% endfor %}</div>{% endblock %}
OP_SOURCE_TEMPLATES_INBOUNDS_HTML_END
    cat > "$payload/templates/login.html" <<'OP_SOURCE_TEMPLATES_LOGIN_HTML_END'
{% extends 'base.html' %}{% from 'macros.html' import csrf with context %}
{% block content %}<section class="card narrow"><h1>ورود به پنل</h1>{% if error %}<p class="notice error">{{ error }}</p>{% endif %}
<form method="post">{{ csrf() }}<label>نام مدیر<input name="username" required autocomplete="username" maxlength="64"></label>
<label>رمز عبور<input name="password" type="password" required autocomplete="current-password" maxlength="256"></label><button class="primary">ورود</button></form></section>{% endblock %}
OP_SOURCE_TEMPLATES_LOGIN_HTML_END
    cat > "$payload/templates/macros.html" <<'OP_SOURCE_TEMPLATES_MACROS_HTML_END'
{% macro csrf() %}<input type="hidden" name="csrf_token" value="{{ csrf_token() }}">{% endmacro %}
{% macro delete(action, text='حذف') %}<form method="post" action="{{ action }}" class="inline" data-confirm="این مورد حذف شود؟">{{ csrf() }}<button class="danger">{{ text }}</button></form>{% endmacro %}
{% macro selectable(names) %}<div class="checks">{% for name in names %}<label><input type="checkbox" name="usernames" value="{{ name }}">{{ name }}</label>{% else %}<p class="muted">کاربری برای انتخاب وجود ندارد.</p>{% endfor %}</div>{% endmacro %}
OP_SOURCE_TEMPLATES_MACROS_HTML_END
    cat > "$payload/templates/reports.html" <<'OP_SOURCE_TEMPLATES_REPORTS_HTML_END'
{% extends 'base.html' %}{% block content %}<h1>گزارش مصرف</h1><section class="card"><h2>{{ '%.3f'|format(used) }} GiB</h2>
<p class="muted">Xray: مجموع دادهٔ uplink و downlink. SSH: تخمین مبتنی بر شمارندهٔ TCP، شامل سربار رمزنگاری؛ اتصال‌های بسیار کوتاه ممکن است ثبت نشوند.</p>
<div class="table-wrap"><table><thead><tr><th>کاربر</th><th>مصرف GiB</th><th>سقف GiB</th><th>انقضا</th></tr></thead><tbody>{% for u in users %}<tr><td>{{ u.username }}</td><td>{{ '%.3f'|format((u.used_traffic or 0)/1024) }}</td><td>{{ '%.3f'|format(u.total_traffic/1024) if u.total_traffic else '∞' }}</td><td>{{ u.expire_date }}</td></tr>{% endfor %}</tbody></table></div></section>{% endblock %}
OP_SOURCE_TEMPLATES_REPORTS_HTML_END
    cat > "$payload/templates/settings.html" <<'OP_SOURCE_TEMPLATES_SETTINGS_HTML_END'
{% extends 'base.html' %}{% from 'macros.html' import csrf with context %}
{% block content %}<h1>تنظیمات</h1><div class="grid"><section class="card"><h2>عمومی</h2><form method="post">{{ csrf() }}<input type="hidden" name="action" value="save_settings">
<label>دامنه یا IP (بدون scheme و پورت)<input name="domain" value="{{ data.domain }}" maxlength="253"></label>
<label>نام مدیر<input name="admin_username" value="{{ data.admin_username }}" required maxlength="64"></label>
<label>رمز جدید مدیر (خالی = حفظ رمز)<input type="password" name="admin_password" minlength="12" maxlength="256" autocomplete="new-password"></label>
<label>پورت داخلی پنل<input type="number" name="panel_port" value="{{ data.panel_port }}" min="1024" max="65535" required></label>
<p class="muted">پورت عمومی {{ data.public_port }} است. تغییر پورت داخلی، Nginx و سرویس پنل را نیز به‌روز می‌کند.</p>
<label class="check"><input type="checkbox" name="block_iran" {% if data.block_iran_client == '1' %}checked{% endif %}>مسدودکردن مقصدهای ایران برای کاربران پنل</label><button class="primary">ذخیره</button></form></section>
<section class="card"><h2>پشتیبان‌گیری</h2><p>بکاپ ZIP شامل دیتابیس و کلید رمزگشایی رمزهای SSH است. آن را خصوصی نگه دارید.</p>
<a class="button" href="{{ url_for('backup_download') }}">دانلود بکاپ کامل</a><hr><form method="post" action="{{ url_for('backup_upload') }}" enctype="multipart/form-data" data-confirm="بکاپ جایگزین اطلاعات فعلی شود؟">{{ csrf() }}
<label>بازگردانی ZIP یا دیتابیس قدیمی<input type="file" name="backup_file" accept=".zip,.db,.sqlite,.sqlite3" required></label><button class="danger">بررسی و بازگردانی</button></form>
<hr><h2>کلید پیش‌فرض Reality</h2><p class="muted">کلیدهای اینباندهای موجود حفظ می‌شوند؛ هر اینباند جدید کلید مستقل دارد.</p><textarea readonly class="mono">{{ data.reality_public_key }}</textarea>
<form method="post">{{ csrf() }}<input type="hidden" name="action" value="generate_keys"><button>ساخت کلید پیش‌فرض جدید</button></form></section></div>{% endblock %}
OP_SOURCE_TEMPLATES_SETTINGS_HTML_END
    cat > "$payload/templates/sub.html" <<'OP_SOURCE_TEMPLATES_SUB_HTML_END'
{% extends 'base.html' %}{% block content %}<h1>اشتراک {{ user.username }}</h1><section class="card"><div class="stats"><div>مصرف<strong>{{ '%.3f'|format((user.used_traffic or 0)/1024) }} GiB</strong></div>
<div>حجم<strong>{{ '%.3f'|format(user.total_traffic/1024) if user.total_traffic else 'نامحدود' }}</strong></div><div>اعتبار<strong>{{ days_left }} روز</strong></div></div>
<p class="mono">{{ user.expire_date }}</p><p class="muted">این لینک دسترسی به اطلاعات اتصال شما می‌دهد؛ آن را خصوصی نگه دارید.</p><a class="button" href="{{ url_for('sub_page', token=token, format='base64') }}">اشتراک Base64 پروتکل‌های Xray</a></section>
<section class="card"><h2>SSH</h2><p>نام کاربر: <b class="mono">{{ user.username }}</b> · رمز: <b class="mono">{{ password }}</b></p><textarea readonly class="mono" id="ssh-link">{{ ssh_uri }}</textarea>
<button type="button" class="copy" data-target="ssh-link">کپی لینک SSH</button><img class="qr" src="data:image/png;base64,{{ ssh_qr }}" alt="QR اتصال SSH"></section>
<div class="grid">{% for cfg in configs %}<section class="card"><h2>{{ cfg.inbound.tag }}</h2><p class="mono">{{ cfg.inbound.protocol }} · {{ cfg.inbound.network }} · {{ cfg.inbound.security }}</p>
<textarea readonly class="mono" id="cfg-{{ cfg.index }}">{{ cfg.link }}</textarea><div class="actions"><button type="button" class="copy" data-target="cfg-{{ cfg.index }}">کپی لینک</button>
<a class="button" href="{{ url_for('download_client', token=token, index=cfg.index) }}">JSON استاندارد Xray</a></div><img class="qr" src="data:image/png;base64,{{ cfg.qr }}" alt="QR اتصال {{ cfg.inbound.tag }}"></section>{% endfor %}</div>{% endblock %}
OP_SOURCE_TEMPLATES_SUB_HTML_END
    cat > "$payload/templates/user_form.html" <<'OP_SOURCE_TEMPLATES_USER_FORM_HTML_END'
{% extends 'base.html' %}{% from 'macros.html' import csrf with context %}
{% block content %}<section class="card narrow"><h1>{{ 'ویرایش کاربر' if user else 'کاربر جدید' }}</h1>
<form method="post" action="{{ url_for('edit_user' if user else 'add_user') }}">{{ csrf() }}
<label>نام کاربر<input name="username" value="{{ user.username if user else '' }}" required maxlength="31" {% if user %}readonly{% endif %} pattern="[a-z][a-z0-9_-]{0,30}"></label>
<label>رمز SSH (حداقل ۸ نویسه)<input name="password" value="{{ user.password if user else '' }}" required minlength="8" maxlength="256" autocomplete="new-password"></label>
<div class="columns"><label>حجم کل (GiB، صفر نامحدود)<input type="number" name="traffic_gb" min="0" max="1000000" step="0.001" value="{{ (user.total_traffic/1024) if user else 0 }}" required></label>
<label>حد IP یکتا (صفر نامحدود)<input type="number" name="max_connections" value="{{ user.max_connections if user else 2 }}" min="0" max="1000" required></label></div>
{% if user %}
<label>تاریخ انقضا (زمان سرور)<input type="datetime-local" name="expire_date" value="{{ user.expire_date.replace(' ', 'T') }}" required></label>
<label>وضعیت<select name="status"><option value="1" {% if user.status %}selected{% endif %}>فعال</option><option value="0" {% if not user.status %}selected{% endif %}>غیرفعال</option></select></label>
<label class="check"><input type="checkbox" name="reset_traffic">صفرکردن مصرف ثبت‌شده</label>
<label class="check"><input type="checkbox" name="reset_expire">محاسبهٔ تاریخ از اکنون</label><label>مدت جدید (روز)<input type="number" name="reset_days" value="30" min="1" max="36500"></label>
<label>تمدید اعتبار باقی‌مانده (روز)<input type="number" name="extend_days" value="0" min="0" max="36500"></label>
<label class="check"><input type="checkbox" name="rotate_token">صدور لینک اشتراک جدید و باطل‌کردن لینک قبلی</label>
{% else %}<label>اعتبار (روز)<input type="number" name="expire_days" value="30" min="1" max="36500" required></label>{% endif %}
<button class="primary">ذخیره</button><a href="{{ url_for('dashboard') }}" class="button">بازگشت</a></form></section>{% endblock %}
OP_SOURCE_TEMPLATES_USER_FORM_HTML_END
    cat > "$payload/traffic_worker.py" <<'OP_SOURCE_TRAFFIC_WORKER_PY_END'
"""One owner for traffic, account expiry, activity and per-account IP routing."""
import hashlib
import hmac
import json
import logging
import time

from common import (BASE, ONLINE_FILE, allowed, atomic_json, database, decrypt, ensure_system_user,
                    get_setting, kill_ssh_session, lock_system_user, log, owned_account, run, state_lock)
from telemetry import capture_ssh, capture_xray, generation, ssh_snapshot, sweep_expired, xray_online
from sync_xray import apply, base_rules, generate

# v3.9 FIX: automatic database migration for older panel.db files
def ensure_runtime_schema():
    with database() as conn:
        conn.execute("CREATE TABLE IF NOT EXISTS counter_state (source TEXT NOT NULL, name TEXT NOT NULL, generation INTEGER NOT NULL DEFAULT 0, value TEXT, PRIMARY KEY(source,name))")
        conn.execute("CREATE TABLE IF NOT EXISTS runtime_state (key TEXT PRIMARY KEY, value TEXT)")


ensure_runtime_schema()

POLL = 15
first_seen = {}
last_applied = None


def limit_plan(users, ssh, xray, now):
    global first_seen
    active = {}
    for row in users:
        name = row['username']
        addresses = set(xray.get(name, {})) | {s['ip'] for s in ssh if s['username'] == name}
        prior = first_seen.get(name, {})
        times = {ip: prior.get(ip, now) for ip in addresses}
        if times:
            active[name] = times
    first_seen = active
    blocked = {}
    for row in users:
        name, limit = row['username'], int(row['max_connections'])
        if not allowed(row):
            continue
        order = sorted(active.get(name, {}), key=lambda ip: (active[name][ip], ip))
        blocked[name] = set(order[limit:]) if limit > 0 else set()
    return blocked


def enforce_ip_rules(conn, blocked):
    global last_applied
    rules = base_rules(conn, blocked)
    digest = (generation(), json.dumps(rules, sort_keys=True))
    if digest[0] and digest != last_applied:
        # Atomic replace of only this panel's router rules. No INPUT IP DROP.
        run([__import__('common').XRAY_BIN, 'api', 'adrules', '--server=' + __import__('common').API_ADDR,
             '--timeout=5'], input=json.dumps({'routing': {'domainStrategy': 'AsIs', 'rules': rules}}), timeout=10)
        last_applied = digest


def reconcile_ssh(users, sessions):
    key = (BASE / 'session.key').read_bytes()
    failures = []
    with database() as conn:
        for row in users:
            name = row['username']
            if row.get('disabled_reason') == 'unsafe legacy username':
                continue
            try:
                plain = decrypt(row['password'])
                # Username validation and ownership prevent modification of root/system users.
                owned_account(name)
                active = allowed(row)
                stamp = hmac.new(key, (plain + ':' + str(active)).encode(), hashlib.sha256).hexdigest()
                old = conn.execute('SELECT value FROM runtime_state WHERE key=?', ('ssh-' + name,)).fetchone()
                created = ensure_system_user(name, plain)
                if created or not old or old[0] != stamp:
                    from common import set_system_password
                    set_system_password(name, plain)
                    lock_system_user(name, not active)
                    conn.execute('INSERT INTO runtime_state(key,value) VALUES(?,?) '
                                 'ON CONFLICT(key) DO UPDATE SET value=excluded.value', ('ssh-' + name, stamp))
                if not active:
                    for s in sessions:
                        if s['username'] == name:
                            kill_ssh_session(s['pid'], name)
            except (ValueError, RuntimeError) as exc:
                log.error('SSH reconciliation failed for %s: %s', name, exc)
                failures.append(name)
        conn.commit()
    return failures


def poll():
    from maintenance import perform_restore
    if perform_restore():
        return
    with state_lock():
        with database() as conn:
            users = [dict(r) for r in conn.execute('SELECT * FROM users')]
            names = {u['username'] for u in users}
            ssh = ssh_snapshot(names, int(get_setting('ssh_port', conn, '22')))
            xray_ok = capture_xray(conn)
            capture_ssh(conn, ssh)
            # Sweep ALL users even when both SSH/Xray traffic snapshots are empty.
            changed = sweep_expired(conn)
            conn.commit()
            users = [dict(r) for r in conn.execute('SELECT * FROM users')]
            xray, online_ok = xray_online([u['username'] for u in users if allowed(u)])
            blocked = limit_plan(users, ssh, xray, time.time())
            if changed or get_setting('pending_xray_sync', conn) == '1':
                apply(generate(conn))
                from common import set_setting
                set_setting('pending_xray_sync', '0', conn)
                conn.commit()
            if online_ok:
                enforce_ip_rules(conn, blocked)
        reconcile_ssh(users, ssh)
        for s in ssh:
            if s['ip'] in blocked.get(s['username'], set()):
                kill_ssh_session(s['pid'], s['username'])
        online = {}
        for row in users:
            name = row['username']
            user_ssh = [s for s in ssh if s['username'] == name]
            user_xray = set(xray.get(name, {}))
            ips = {s['ip'] for s in user_ssh} | user_xray
            online[name] = {'ssh': bool(user_ssh), 'xray': bool(user_xray),
                            'ssh_count': len(user_ssh), 'xray_ips': len(user_xray),
                            'online_count': len(ips), 'is_online': bool(ips), 'ts': time.time()}
        atomic_json(ONLINE_FILE, {'last_update': time.time(), 'users': online,
                                 'xray_traffic_ok': xray_ok, 'xray_online_ok': online_ok,
                                 'ssh_traffic': 'TCP snapshots (approximate)'})
    from system_config import apply_pending
    apply_pending()


def main():
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    log.info('OutlineParsian 3.8 worker started; SSH counts bytes sampled from live TCP sockets')
    while True:
        try:
            poll()
        except Exception:
            log.exception('Worker cycle failed')
        time.sleep(POLL)


if __name__ == '__main__':
    main()
OP_SOURCE_TRAFFIC_WORKER_PY_END
    cat > "$payload/xray.service" <<'OP_SOURCE_XRAY_SERVICE_END'
[Unit]
Description=OutlineParsian managed Xray Core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
UMask=0077

[Install]
WantedBy=multi-user.target
OP_SOURCE_XRAY_SERVICE_END
}

mode=${1:-install}
case "$mode" in
    --help|-h)
        sed -n '1,/^set -Eeuo pipefail/p' "$0"
        exit 0 ;;
    --extract)
        [[ $# == 2 ]] || { printf 'Usage: %s --extract DIRECTORY\n' "$0" >&2; exit 2; }
        write_sources "$2"
        printf 'All source files exported to %s\n' "$2"
        exit 0 ;;
    --check)
        bash -n "$0"
        STAGE=$(mktemp -d)
        write_sources "$STAGE"
        "${OP_CHECK_PYTHON:-python3}" - "$STAGE" <<'CHECK_PAYLOAD'
import ast,sys
from pathlib import Path
p=Path(sys.argv[1])
for f in p.glob('*.py'):
    ast.parse(f.read_text(encoding='utf-8'),filename=str(f))
print('Bash syntax and all embedded Python sources: OK')
try:
    from jinja2 import Environment,FileSystemLoader
except ImportError:
    print('Jinja2 is not installed here; template check requires the install dependencies.')
else:
    env=Environment(loader=FileSystemLoader(str(p/'templates')))
    for name in env.list_templates(): env.get_template(name)
    print('All Jinja templates: OK')
CHECK_PAYLOAD
        exit 0 ;;
    install)
        [[ $# -le 1 ]] || { printf 'Unexpected arguments. Use --help.\n' >&2; exit 2; } ;;
    *) printf 'Unknown option: %s\n' "$mode" >&2; exit 2 ;;
esac

[[ $EUID == 0 ]] || { printf 'Run installation with sudo/root.\n' >&2; exit 1; }
command -v apt-get >/dev/null || { printf 'Debian/Ubuntu with apt-get is required.\n' >&2; exit 1; }
[[ -d /run/systemd/system ]] || { printf 'A running systemd host is required.\n' >&2; exit 1; }
python3 - <<'CHECK_PYTHON'
import sys
if sys.version_info < (3,10):
    raise SystemExit('Python 3.10 or later is required.')
CHECK_PYTHON
export DEBIAN_FRONTEND=noninteractive
export OP_PANEL_DIR="$BASE"
export XRAY_LOCATION_ASSET=/usr/local/share/xray
if [[ -n "${PANEL_ADMIN_PASSWORD:-}" ]]; then export OP_ADMIN_PASSWORD="$PANEL_ADMIN_PASSWORD"; fi
STAGE=$(mktemp -d)
write_sources "$STAGE"
python3 -m compileall -q "$STAGE"
printf '[1/9] Installing prerequisites in a private Python environment...\n'
apt-get update
apt-get install -y python3 python3-venv python3-pip nginx curl ca-certificates unzip openssh-server \
    iproute2 iptables ipset sqlite3 util-linux
install -d -m 700 "$BASE" "$BASE/state" "$BASE/backups"
python3 -m venv "$BASE/.venv"
PY="$BASE/.venv/bin/python"
"$PY" -m pip install --disable-pip-version-check -r "$STAGE/requirements.txt"
"$PY" -m grpc_tools.protoc -I"$STAGE" --python_out="$STAGE" --grpc_python_out="$STAGE" "$STAGE/stats.proto"
"$PY" -m compileall -q "$STAGE"
"$PY" - "$STAGE" <<'VERIFY_TEMPLATES'
import sys
from jinja2 import Environment,FileSystemLoader
env=Environment(loader=FileSystemLoader(sys.argv[1]+'/templates'))
for name in env.list_templates(): env.get_template(name)
sys.path.insert(0,sys.argv[1])
import stats_pb2, stats_pb2_grpc
print('Python, templates and gRPC bindings verified.')
VERIFY_TEMPLATES

printf '[2/9] Recording service state and taking a consistent backup...\n'
STAMP=$(date -u +%Y%m%d-%H%M%S)-$$
BACKUP_DIR="$BASE/backups/upgrade-$STAMP"
install -d -m 700 "$BACKUP_DIR/system"
for svc in xray ssh-panel ssh-panel-worker ssh-panel-ip-manager; do
    if systemctl is-active --quiet "$svc"; then ORIGINAL_ACTIVE[$svc]=1; else ORIGINAL_ACTIVE[$svc]=0; fi
done
cat > "$BACKUP_DIR/system-files.txt" <<'SYSTEM_FILES'
/etc/ssh/sshd_config
/etc/systemd/system/xray.service
/etc/systemd/system/ssh-panel.service
/etc/systemd/system/ssh-panel-worker.service
/etc/systemd/system/ssh-panel-ip-manager.service
/etc/systemd/system/iran-block.service
/etc/nginx/sites-available/outlineparsian.conf
/etc/nginx/sites-enabled/outlineparsian.conf
/etc/nginx/sites-enabled/panel
/usr/local/etc/xray/config.json
/usr/local/bin/xray
SYSTEM_FILES
while IFS= read -r path; do
    if [[ -e "$path" || -L "$path" ]]; then
        mkdir -p "$BACKUP_DIR/system$(dirname "$path")"
        cp -a -- "$path" "$BACKUP_DIR/system$path"
    fi
done < "$BACKUP_DIR/system-files.txt"
# Stop old database writers before archiving; leave existing SSH sessions intact.
for svc in ssh-panel ssh-panel-worker ssh-panel-ip-manager; do
    if [[ "${ORIGINAL_ACTIVE[$svc]}" == 1 ]]; then
        systemctl stop "$svc"
        if systemctl is-active --quiet "$svc"; then
            printf 'Could not stop database writer: %s\n' "$svc" >&2
            false
        fi
    fi
done
if [[ -f "$BASE/panel.db" ]]; then
    "$PY" - "$BASE/panel.db" "$BACKUP_DIR/panel-before.db" <<'BACKUP_DB'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as src, sqlite3.connect(sys.argv[2]) as dst:
    src.backup(dst)
BACKUP_DB
fi
tar --exclude='./backups' --exclude='./.venv' --exclude='./panel.db-wal' \
    --exclude='./panel.db-shm' --exclude='./__pycache__' -czf "$BACKUP_DIR/panel-before.tar.gz" -C "$BASE" .
DEPLOYING=1

printf '[3/9] Checking/installing Xray Core (tested version %s)...\n' "$XRAY_TESTED_VERSION"
NEED_CORE=1
if [[ -x /usr/local/bin/xray ]]; then
    CORE_VERSION=$(/usr/local/bin/xray version | awk '/^Xray /{print $2;exit}')
    if [[ "$CORE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
        dpkg --compare-versions "$CORE_VERSION" ge "$XRAY_TESTED_VERSION"; then
        NEED_CORE=0
    fi
fi
if (( NEED_CORE )); then
    case "$(uname -m)" in x86_64) CORE_ARCH=64 ;; aarch64|arm64) CORE_ARCH=arm64-v8a ;; *) printf 'Unsupported CPU architecture.\n' >&2; false ;; esac
    CORE_URL="https://github.com/XTLS/Xray-core/releases/download/v$XRAY_TESTED_VERSION/Xray-linux-$CORE_ARCH.zip"
    curl --fail --show-error --location --retry 3 --connect-timeout 15 --max-time 180 "$CORE_URL" -o "$STAGE/xray.zip"
    curl --fail --show-error --location --retry 3 --connect-timeout 15 --max-time 60 "$CORE_URL.dgst" -o "$STAGE/xray.dgst"
    "$PY" - "$STAGE/xray.zip" "$STAGE/xray.dgst" <<'VERIFY_XRAY'
import hashlib,re,sys
from pathlib import Path
m=re.search(r'SHA2-256\s*=\s*([0-9a-fA-F]{64})',Path(sys.argv[2]).read_text())
if not m or hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()!=m[1].lower():
    raise SystemExit('Xray SHA256 verification failed.')
VERIFY_XRAY
    mkdir "$STAGE/core"
    unzip -q "$STAGE/xray.zip" xray geoip.dat geosite.dat -d "$STAGE/core"
    install -d /usr/local/bin /usr/local/share/xray /usr/local/etc/xray
    install -m 755 "$STAGE/core/xray" /usr/local/bin/xray
    install -m 644 "$STAGE/core/geoip.dat" "$STAGE/core/geosite.dat" /usr/local/share/xray/
elif [[ ! -f /usr/local/share/xray/geoip.dat ]]; then
    printf 'Existing Xray has no geoip.dat; install its matching geodata before continuing.\n' >&2
    false
fi
/usr/local/bin/xray version
install -d -m 700 /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log
chmod 600 /var/log/xray/access.log /var/log/xray/error.log

printf '[4/9] Deploying source and migrating the existing database in place...\n'
# Remove obsolete generated protobuf files before installing matching bindings.
find "$BASE" -maxdepth 1 -type f -name 'stats_pb2*.py' -delete
install -d -m 700 "$BASE/templates" "$BASE/static"
for file in "$STAGE"/*.py "$STAGE"/stats.proto "$STAGE"/requirements.txt; do install -m 600 "$file" "$BASE/"; done
for file in "$STAGE/templates/"*; do install -m 600 "$file" "$BASE/templates/"; done
for file in "$STAGE/static/"*; do install -m 600 "$file" "$BASE/static/"; done
"$PY" - "$BASE" <<'MIGRATE'
import ipaddress,json,os,pwd,re,subprocess,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from common import (BASE,MARKER,STATE,atomic_json,database,get_setting,host,init_db,
                    run,set_setting,username)
legacy=False
if (BASE/'panel.db').exists():
    with database() as conn:
        try: legacy=not get_setting('schema_version',conn)
        except Exception: legacy=True
init_db()
run(['groupadd','--force','op-panel-users'])
with database() as conn:
    # Adopt only explicitly recorded v3.7 users with safe UID/home/shell; never root or service accounts.
    if legacy:
        for row in conn.execute('SELECT username FROM users').fetchall():
            try:
                name=username(row[0]); account=pwd.getpwnam(name)
            except (KeyError,ValueError): continue
            if account.pw_uid>=1000 and account.pw_dir==f'/home/{name}' and account.pw_shell=='/bin/bash':
                run(['usermod','--comment',MARKER,'--append','--groups','op-panel-users','--',name])
            else:
                raise ValueError('Unsafe legacy system account; cannot adopt '+name)
    for key,env in [('public_port','PANEL_PUBLIC_PORT'),('server_address','PANEL_SERVER_ADDRESS')]:
        if os.environ.get(env): set_setting(key,os.environ[env],conn)
    public=int(get_setting('public_port',conn,'80'))
    if not 1<=public<=65535: raise ValueError('Invalid public port')
    if get_setting('server_address',conn)=='127.0.0.1' and not os.environ.get('PANEL_SERVER_ADDRESS'):
        result=run(['curl','-4','--fail','--silent','--show-error','--connect-timeout','5',
                    '--max-time','10','https://api.ipify.org'],check=False,timeout=12)
        try: address=str(ipaddress.ip_address(result.stdout.strip()))
        except ValueError:
            result=run(['hostname','-I'])
            candidates=result.stdout.split()
            if not candidates: raise ValueError('Set PANEL_SERVER_ADDRESS to your public IP/hostname')
            address=str(ipaddress.ip_address(candidates[0]))
        set_setting('server_address',address,conn)
    host(get_setting('server_address',conn))
    host(get_setting('domain',conn),allow_empty=True)
    if os.environ.get('PANEL_HTTPS_DOMAIN'):
        domain=host(os.environ['PANEL_HTTPS_DOMAIN'])
        if not (Path('/etc/letsencrypt/live')/domain/'fullchain.pem').is_file():
            raise ValueError('A pre-existing HTTPS certificate is required')
        set_setting('domain',domain,conn);set_setting('ssl_domain',domain,conn);set_setting('ssl_status','active',conn)
    ssh=run(['/usr/sbin/sshd','-T']).stdout
    ports=re.findall(r'^port (\d+)$',ssh,re.M)
    if not ports: raise ValueError('Cannot determine SSH port')
    set_setting('ssh_port',ports[0],conn)
    internal=int(get_setting('panel_port',conn,'5000'))
    taken={int(r[0]) for r in conn.execute('SELECT port FROM xray_inbounds')}
    if internal in {public,10085,*map(int,ports)} or internal in taken:
        raise ValueError('Internal panel port conflicts with a managed service')
    if public in {10085,*map(int,ports)} or public in taken:
        raise ValueError('Public panel port conflicts with SSH/Xray')
    set_setting('pending_panel_restart','0',conn)
    set_setting('pending_iran_apply','1',conn)
    set_setting('pending_xray_sync','0',conn)
    conn.commit()
atomic_json(STATE/'installation.json',{'legacy':legacy,'version':38})
print('Database migration complete; users, usage and UUIDs retained.')
MIGRATE

printf '[5/9] Adding scoped SSH tunnel settings and service units...\n'
"$PY" - "$BASE" <<'SSH_PATCH'
import re,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from common import atomic_bytes,run
path=Path('/etc/ssh/sshd_config')
text=path.read_text()
text=re.sub(r'(?ms)^# BEGIN OutlineParsian managed\n.*?^# END OutlineParsian managed\n?','',text)
text += '''\n# BEGIN OutlineParsian managed
Match Group op-panel-users
    PasswordAuthentication yes
    PubkeyAuthentication no
    AuthenticationMethods password
    AllowTcpForwarding yes
    AllowStreamLocalForwarding no
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
    GatewayPorts no
    MaxSessions 0
Match all
# END OutlineParsian managed
'''
before=path.read_bytes()
atomic_bytes(path,text.encode(),0o600)
try: run(['/usr/sbin/sshd','-t'])
except Exception:
    atomic_bytes(path,before,0o600)
    raise
run(['systemctl','reload','ssh'])
SSH_PATCH
for unit in xray ssh-panel ssh-panel-worker; do
    systemctl unmask "$unit.service" 2>/dev/null || true
    cp --remove-destination "$STAGE/$unit.service" "/etc/systemd/system/$unit.service"
    chmod 644 "/etc/systemd/system/$unit.service"
done
# The old separate IP manager and global country firewall must no longer run.
systemctl disable --now ssh-panel-ip-manager iran-block.service 2>/dev/null || true
install -d /etc/nginx/sites-available /etc/nginx/sites-enabled
ln -sfn /etc/nginx/sites-available/outlineparsian.conf /etc/nginx/sites-enabled/outlineparsian.conf
# Only the v3.7 panel site's own symlink is retired. Other Nginx sites/defaults are preserved.
if [[ -L /etc/nginx/sites-enabled/panel && -f "$BACKUP_DIR/panel-before.tar.gz" ]]; then
    if [[ "$(readlink /etc/nginx/sites-enabled/panel)" == /etc/nginx/sites-available/panel ]]; then
        if [[ -f "$BACKUP_DIR/system/etc/systemd/system/ssh-panel.service" ]]; then
            rm -f /etc/nginx/sites-enabled/panel
        fi
    fi
fi

printf '[6/9] Retiring tracked v3.7 firewall rules (never flushing INPUT)...\n'
"$PY" - "$BASE" <<'CLEAN_OLD_RULES'
import ipaddress,json,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from common import BASE,atomic_bytes,run
tracked=Path('/tmp/ip_manager_state.json')
addresses=set()
if tracked.is_file():
    try:
        data=json.loads(tracked.read_text())
        values=data.get('blocked_ips',[]) if isinstance(data,dict) else data if isinstance(data,list) else []
        for value in values:
            try: addresses.add(str(ipaddress.ip_address(value)))
            except ValueError: pass
    except (ValueError,OSError): pass
for ip in addresses:
    tool='ip6tables' if ':' in ip else 'iptables'
    if run([tool,'-w','5','-C','INPUT','-s',ip,'-j','DROP'],check=False).returncode==0:
        run([tool,'-w','5','-D','INPUT','-s',ip,'-j','DROP'])
    persisted=Path('/etc/iptables/rules.v6' if ':' in ip else '/etc/iptables/rules.v4')
    if persisted.is_file():
        lines=persisted.read_text().splitlines(keepends=True)
        exact={f'-A INPUT -s {ip} -j DROP',f'-A INPUT -s {ip}/{128 if ":" in ip else 32} -j DROP'}
        atomic_bytes(persisted,''.join(line for line in lines if line.strip() not in exact).encode(),0o600)
for tool in ['iptables','ip6tables']:
    rule=[tool,'-w','5','-m','set','--match-set','iran_ips','dst','-j','DROP']
    while run(rule[:3]+['-C','OUTPUT']+rule[3:],check=False).returncode==0:
        run(rule[:3]+['-D','OUTPUT']+rule[3:])
    persisted=Path('/etc/iptables/rules.v6' if tool=='ip6tables' else '/etc/iptables/rules.v4')
    if persisted.is_file():
        lines=persisted.read_text().splitlines(keepends=True)
        exact='-A OUTPUT -m set --match-set iran_ips dst -j DROP'
        atomic_bytes(persisted,''.join(line for line in lines if line.strip()!=exact).encode(),0o600)
CLEAN_OLD_RULES

printf '[7/9] Validating and starting Xray and the managed services...\n'
systemctl daemon-reload
"$PY" "$BASE/sync_xray.py"
"$PY" - "$BASE" <<'RECONCILE_ACCOUNTS'
import sys
sys.path.insert(0,sys.argv[1])
from common import database
from traffic_worker import reconcile_ssh
with database() as conn: users=[dict(r) for r in conn.execute('SELECT * FROM users') if r['disabled_reason']!='unsafe legacy username']
failures=reconcile_ssh(users,[])
if failures: raise SystemExit('SSH user reconciliation failed for: '+', '.join(failures))
RECONCILE_ACCOUNTS
"$PY" "$BASE/system_config.py"
systemctl enable xray ssh-panel ssh-panel-worker nginx ssh
systemctl restart ssh-panel ssh-panel-worker

printf '[8/9] Checking service health and the real Xray stats API...\n'
for svc in xray ssh-panel ssh-panel-worker nginx ssh; do
    if ! systemctl is-active --quiet "$svc"; then
        journalctl -u "$svc" -n 20 --no-pager
        false
    fi
done
"$PY" - "$BASE" <<'HEALTH_CHECK'
import json,sys,time,urllib.request
sys.path.insert(0,sys.argv[1])
from common import get_setting,database
from telemetry import capture_xray
port=get_setting('panel_port')
for attempt in range(15):
    try:
        with urllib.request.urlopen('http://127.0.0.1:'+port+'/health',timeout=3) as response:
            if json.load(response).get('ok'): break
    except Exception:
        time.sleep(1)
else: raise SystemExit('Panel HTTP health check failed.')
with database() as conn:
    if not capture_xray(conn): raise SystemExit('Xray StatsService API health check failed.')
    conn.commit()
print('Panel HTTP, database and Xray gRPC health checks: OK')
HEALTH_CHECK

SUCCESS=1
printf '[9/9] Installation complete.\n'
"$PY" - "$BASE" <<'INSTALL_RESULT'
import sys
sys.path.insert(0,sys.argv[1])
from common import BASE,get_setting
from app import public_base
print('Panel URL:',public_base())
print('Admin username:',get_setting('admin_username'))
credentials=BASE/'admin-initial.txt'
if credentials.exists():
    lines=credentials.read_text().splitlines()
    from werkzeug.security import check_password_hash
    if len(lines)>1 and check_password_hash(get_setting('admin_password_hash'),lines[1]):
        print('Admin password:',lines[1])
    else: print('Admin password: preserved (use your existing password).')
else: print('Admin password: preserved (use your existing password).')
print('SSH clients use token subscription links from the dashboard.')
print('Diagnostics: journalctl -u ssh-panel -u ssh-panel-worker -u xray -n 100 --no-pager')
INSTALL_RESULT
printf 'Pre-upgrade backup: %s\n' "$BACKUP_DIR"
