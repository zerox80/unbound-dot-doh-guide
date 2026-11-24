# 9. Rückbau

Entfernt alles, was diese Anleitung angelegt hat. Andere Dienste auf dem Server bleiben unberührt.

```bash
# 1. DoH-vHost entfernen
rm -f /etc/nginx/sites-enabled/dns-doh.conf /etc/nginx/sites-available/dns-doh.conf
nginx -t && systemctl reload nginx

# 2. Firewall-Freigabe entfernen
ufw delete allow 853/tcp

# 3. Zertifikat widerrufen ist optional; löschen:
certbot delete --cert-name dns.example.com

# 4. Unbound entfernen
apt-get purge -y unbound
rm -rf /etc/unbound /var/lib/unbound

# 5. Hilfsdateien
rm -f /usr/local/sbin/unbound-tls-deploy /usr/local/sbin/dns-selftest /etc/cron.d/dns-selftest
rm -rf /var/www/letsencrypt
```

Danach:
- **Beim DNS-Anbieter** den A- und AAAA-Record für `dns` löschen.
- **Auf allen Geräten** die DNS-Einstellung zurücksetzen (Android „Privates DNS“ auf „Automatisch“, Profile auf Apple-Geräten löschen, Browser und Windows auf Standard). Sonst haben sie kein DNS mehr.
- Falls der Server selbst Unbound genutzt hat: `/etc/systemd/resolved.conf.d/unbound.conf` löschen und `systemctl restart systemd-resolved`.
