# 🚀 OutlineParsian Ultimate Panel

<div align="center">

**A Complete SSH + Xray Management Panel for Linux Servers**

مدیریت حرفه‌ای کاربران SSH و Xray با رابط کاربری مدرن، مدیریت ترافیک، بکاپ، Reality، TLS و کنترل کامل سرور.

</div>

---

## ✨ معرفی پروژه

**OutlineParsian Ultimate Panel** یک پنل مدیریتی کامل برای سرورهای لینوکسی است که برای مدیریت سرویس‌های:

- SSH Users
- Xray VLESS / VMess / Trojan
- Traffic Management
- User Subscription
- Server Monitoring

طراحی شده است.

هدف پروژه ایجاد یک پنل سبک، سریع و قابل توسعه برای مدیریت کاربران و سرویس‌های شبکه با کمترین پیچیدگی است.

---

# ⚡ نصب سریع

## نصب با یک دستور

روی سرور Ubuntu/Debian وارد شوید:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/OutlineParsian/main/install.sh)
```

نصب‌کننده به صورت خودکار:

✅ پیش‌نیازها را نصب می‌کند  
✅ محیط Python را آماده می‌کند  
✅ Xray Core را نصب می‌کند  
✅ دیتابیس را ایجاد می‌کند  
✅ سرویس‌های Systemd را فعال می‌کند  
✅ پنل را راه‌اندازی می‌کند  

---

# 🖥 سیستم مورد نیاز

## سیستم عامل

پشتیبانی شده:

- Ubuntu 20.04
- Ubuntu 22.04
- Ubuntu 24.04
- Debian 11+
  
## حداقل منابع پیشنهادی

| مورد | مقدار |
|-|-|
| CPU | 1 Core |
| RAM | 1GB |
| Storage | 10GB |
| Architecture | x86_64 |

---

# 🎯 امکانات اصلی

## 👥 مدیریت کاربران

- ساخت کاربر SSH
- تغییر رمز عبور
- فعال / غیرفعال کردن کاربر
- محدودیت تعداد اتصال
- تاریخ انقضا
- مدیریت گروه کاربران

---

## 📊 مدیریت ترافیک

- شمارش مصرف SSH
- شمارش مصرف Xray
- نمایش مصرف لحظه‌ای
- ریست ترافیک
- محدودیت حجم کاربران

---

## 🌐 Xray Management

پشتیبانی از:

- VLESS
- VMess
- Trojan

قابلیت‌ها:

- TCP
- WebSocket
- gRPC
- TLS
- Reality
- تولید لینک اتصال
- تولید QR Code

---

## 🔐 امنیت

امکانات امنیتی:

- محافظت CSRF
- مدیریت Session
- هدرهای امنیتی HTTP
- محدودیت تلاش ورود
- Backup قبل از تغییرات حساس
- اعتبارسنجی تنظیمات Xray

---

## 💾 Backup & Restore

امکانات:

- ایجاد بکاپ دیتابیس
- بازگردانی کاربران
- Migration خودکار دیتابیس
- Rollback در صورت خطا

---

## 📈 مانیتورینگ سرور

نمایش:

- CPU Usage
- RAM Usage
- وضعیت سرویس‌ها
- کاربران آنلاین

---

# 🏗 ساختار پروژه

```
OutlineParsian/

├── install.sh
│
├── app.py
├── traffic_worker.py
│
├── templates/
│
├── scripts/
│
├── services/
│
└── README.md
```

---

# ⚙ سرویس‌های اصلی

بعد از نصب سرویس‌های زیر فعال می‌شوند:

```
ssh-panel.service
ssh-panel-worker.service
xray.service
nginx.service
```

مشاهده وضعیت:

```bash
systemctl status ssh-panel
```

مشاهده لاگ:

```bash
journalctl -u ssh-panel -f
```

---

# 🔑 ورود به پنل

بعد از نصب:

```
http://SERVER_IP
```

اطلاعات ورود اولیه در مسیر زیر ذخیره می‌شود:

```
/root/ssh-panel/initial_admin_credentials.txt
```

---

# 🔄 بروزرسانی

برای دریافت نسخه جدید:

```bash
git pull
```

یا اجرای دوباره Installer:

```bash
bash install.sh
```

---

# 🛠 توسعه‌دهندگان

این پروژه با هدف ساخت یک پنل مدیریتی ساده، سریع و قابل توسعه ایجاد شده است.

پیشنهادها و Pull Request ها استقبال می‌شوند.

---

# ⚠️ Disclaimer

این پروژه برای مدیریت سرورهایی که مالک آن هستید یا اجازه مدیریت آن‌ها را دارید ساخته شده است.

استفاده مسئولانه از این نرم‌افزار بر عهده کاربر است.

---

# 📜 License

MIT License

---

<div align="center">

⭐ اگر پروژه برای شما مفید بود، Star کردن پروژه باعث حمایت از توسعه آن می‌شود.

</div>
