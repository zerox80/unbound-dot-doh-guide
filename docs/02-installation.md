# 2. Installation Schritt für Schritt

Alle Befehle laufen als root auf dem Server. Bei jedem Schritt steht, **warum** er nötig ist.
Ersetze überall `dns.example.com` durch deinen Hostnamen.

Das Repo auf den Server holen (z. B. nach `/root/unbound-dot-doh`) oder die Dateien einzeln kopieren:

```bash
cd /root/unbound-dot-doh
```

---

## Schritt 0: Ausgangslage prüfen

```bash
ss -tulpn | grep -E ':(53|853|8053)\b'   # wer belegt die Ports?
ufw status verbose                       # läuft eine Firewall?
nginx -v                                 # >= 1.25?
```

**Warum:**
- **Port 853 und 8053 müssen frei sein.** Auf Port 53 läuft bei Ubuntu meist `systemd-resolved` auf `127.0.0.53` und `127.0.0.54`. Das stört nicht, weil Unbound auf `127.0.0.1` lauscht, also auf einer anderen Adresse.
- **Ohne aktive Firewall wäre alles erreichbar, was lauscht.**

> **UFW noch nicht aktiv?** Zuerst SSH erlauben, dann aktivieren, sonst sperrst du dich aus:
> ```bash
> ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw enable
> ```

---

## Schritt 1: DNS-Record anlegen

Beim DNS-Anbieter deiner Domain:

| Typ | Name | Wert |
|---|---|---|
| A | `dns` | `203.0.113.10` |
| AAAA | `dns` | `2001:db8::10` (optional) |

Prüfen:
```bash
dig +short dns.example.com A @1.1.1.1
```

**Warum direkt und ohne CDN/Proxy:**
- **DoT braucht eine direkte Verbindung:** DoT läuft auf Port 853, und ein CDN leitet nur HTTP(S) weiter.
- **Privatsphäre:** Ein CDN würde jede DoH-Anfrage im Klartext sehen.

---

## Schritt 2: Unbound installieren

```bash
apt-get update && apt-get install -y unbound
unbound -V | grep -o libnghttp2          # muss "libnghttp2" ausgeben
systemctl disable unbound-resolvconf     # Server-DNS nicht automatisch umbiegen
systemctl is-active unbound              # "active"
```

**Warum:**
- **libnghttp2** ist die HTTP/2-Bibliothek. Ohne sie kann Unbound kein DoH.
- **`unbound-resolvconf`** würde den systemweiten DNS des Servers still auf Unbound umstellen. Das soll eine bewusste Entscheidung sein, siehe [Architektur](01-architektur.md#warum-wird-unbound-resolvconf-deaktiviert).

Nach der Installation lauscht Unbound mit Standardkonfiguration nur auf `127.0.0.1:53` und `[::1]:53`.

---

## Schritt 3: Grundkonfiguration (ohne Zertifikat)

```bash
install -m 0644 config/unbound/10-public-resolver.conf /etc/unbound/unbound.conf.d/
unbound-checkconf
systemctl restart unbound
ss -tulpn | grep unbound
```

Erwartet:
```
udp ... 127.0.0.1:53     tcp ... 127.0.0.1:53
udp ... [::1]:53         tcp ... [::1]:53
                         tcp ... 127.0.0.1:8053
```

**Warum diese Datei:** Was jede Einstellung bewirkt, steht als Kommentar in [`config/unbound/10-public-resolver.conf`](../config/unbound/10-public-resolver.conf) und ausführlich in [Sicherheit](03-sicherheit.md) und [Datenschutz](04-datenschutz-und-logging.md). Die Kurzfassung:
- **Port 53 nur lokal.**
- **DoH-Backend nur auf Loopback.**
- **Kein Logging.**
- **DNSSEC und Härtung, Rebinding-Schutz, Rate-Limits.**
- **Cache und Prefetch.**

Sofort testen:
```bash
dig @127.0.0.1 dnssec-failed.org | grep -E 'status|EDE'     # SERVFAIL + EDE 6 (DNSSEC Bogus)
dig @127.0.0.1 +dnssec isc.org | grep flags                  # enthält "ad"
dig @127.0.0.1 +short qnamemintest.internet.nl TXT | tail -1 # "HOORAY ..."
dig +http-plain=/dns-query @127.0.0.1 -p 8053 example.com    # DoH-Backend antwortet
```

---

## Schritt 4: nginx für die Let's-Encrypt-Prüfung

Das Zertifikat gibt es noch nicht, also zunächst **nur den Port-80-Teil** aktivieren:

```bash
install -d -m 0755 /var/www/letsencrypt
cat > /etc/nginx/sites-available/dns-doh.conf <<'NGX'
server {
    listen 80;
    listen [::]:80;
    server_name dns.example.com;
    access_log off;
    error_log /dev/null;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type text/plain;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}
NGX
ln -sf /etc/nginx/sites-available/dns-doh.conf /etc/nginx/sites-enabled/dns-doh.conf
nginx -t && systemctl reload nginx
```

**Warum:**
- **Port 80:** Let's Encrypt prüft per HTTP auf Port 80, ob dir die Domain gehört.
- **Nur Phase 1:** Der vollständige vHost (Schritt 7) verweist auf Zertifikatsdateien, die es noch nicht gibt. Mit ihm würde `nginx -t` fehlschlagen.

---

## Schritt 5: Deploy-Hook installieren

```bash
install -m 0750 scripts/unbound-tls-deploy /usr/local/sbin/unbound-tls-deploy
sed -i 's/dns\.example\.com/dns.deine-domain.tld/' /usr/local/sbin/unbound-tls-deploy
```

**Warum:** Der Hook läuft nach jeder Ausstellung und Erneuerung. Er kopiert Zertifikat und Schlüssel nach `/etc/unbound/tls/` (Schlüssel `0640 root:unbound`), startet Unbound neu und lädt nginx neu. Ohne ihn würde DoT nach etwa 60 bis 90 Tagen mit einem abgelaufenen Zertifikat ausfallen. Details: [Architektur](01-architektur.md#warum-wird-das-zertifikat-kopiert-und-nicht-direkt-aus-etcletsencrypt-gelesen).

---

## Schritt 6: Zertifikat holen

```bash
certbot certonly --webroot -w /var/www/letsencrypt -d dns.example.com \
  --deploy-hook /usr/local/sbin/unbound-tls-deploy
ls -l /etc/unbound/tls/        # fullchain.pem (644) und privkey.pem (640), Gruppe unbound
grep renew_hook /etc/letsencrypt/renewal/dns.example.com.conf
```

**Warum `--deploy-hook` hier:**
- **certbot merkt sich den Hook in der Erneuerungskonfiguration genau dieses Zertifikats.** Andere Zertifikate auf dem Server bleiben unberührt.
- **Der Hook läuft schon bei der Erstausstellung**, deshalb liegt das Zertifikat danach sofort für Unbound bereit.

---

## Schritt 7: DoT und DoH aktivieren

```bash
# DoT in Unbound
install -m 0644 config/unbound/20-dot.conf /etc/unbound/unbound.conf.d/
unbound-checkconf && systemctl restart unbound
ss -tulpn | grep ':853'        # nur tcp, KEIN udp

# Vollständiger DoH-vHost (ersetzt die Phase-1-Datei)
install -m 0644 config/nginx/dns-doh.conf /etc/nginx/sites-available/dns-doh.conf
sed -i 's/dns\.example\.com/dns.deine-domain.tld/g' /etc/nginx/sites-available/dns-doh.conf
nginx -t && systemctl reload nginx
```

**Warum:**
- **`access-control` in `20-dot.conf` erlaubt alle IPs:** DoT-Geräte kommen aus beliebigen Netzen (Mobilfunk, fremde WLANs). Port 53 bleibt trotzdem lokal, weil Unbound dort nur an Loopback gebunden ist.
- **Unbound öffnet auf dem DoT-Port nur TCP.** Das prüft `ss`.
- **Rate-Limit im nginx-vHost (50 Anfragen/s pro IP, Burst 100):** Unbound sieht bei DoH nur nginx als Absender und kann nicht pro Client bremsen.
- **Kein Access- und kein Error-Log im nginx-vHost.** Das Error-Log würde sonst bei Rate-Limit-Treffern Client-IP und URL schreiben, und bei DoH-GET steckt die angefragte Domain Base64-kodiert in der URL.

---

## Schritt 8: Firewall

```bash
ufw allow 853/tcp comment 'DNS-over-TLS (Unbound)'
ufw status | grep -E '^(53|853)\b'   # nur 853/tcp, KEIN 53
```

**Warum nur TCP:** Unbound öffnet auf 853 zwar kein UDP. Die Firewall ist aber die zweite Sicherung, falls sich daran je etwas ändert.
Port 443 ist für nginx normalerweise schon offen.

---

## Schritt 9: Selbsttest

```bash
bash scripts/dns-selftest.sh dns.example.com
```

Muss mit `… ok, 0 Fehler` enden. Danach unbedingt **von außen** testen, ob Port 53 wirklich geschlossen ist: [Tests](06-tests.md#tests-von-außen).

Dann die Geräte umstellen: [Geräte einrichten](05-geraete-einrichten.md).
