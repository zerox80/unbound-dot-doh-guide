# 8. Fehlersuche

Erster Schritt immer: `bash scripts/dns-selftest.sh dns.example.com`. Die fehlgeschlagenen Prüfungen zeigen meist schon die Ursache.

| Symptom | Ursache / Prüfung | Lösung |
|---|---|---|
| **Unbound startet nicht** | `unbound-checkconf`, `journalctl -u unbound -n 50` | Häufig fehlt das Zertifikat unter `/etc/unbound/tls/`. Ausführen: `RENEWED_LINEAGE=/etc/letsencrypt/live/dns.example.com /usr/local/sbin/unbound-tls-deploy` |
| **`error: can't bind socket: Address already in use`** | `ss -tulpn \| grep -E ':(53\|853\|8053)\b'` | Ein anderer Dienst belegt den Port. Unbound nicht auf `0.0.0.0:53` binden (Konflikt mit `systemd-resolved`). |
| **Android: „Kein Zugriff auf privaten DNS-Server“** | Hostname korrekt (ohne `https://`)? `ss -tlnp \| grep 853`, `ufw status \| grep 853`, Zertifikat gültig? | Manche Firmen-, Hotel- und Gast-WLANs blockieren Port 853. Im Mobilfunk testen. |
| **DoH: HTTP 502** | Läuft Unbound? `ss -tlnp \| grep 8053` | `systemctl restart unbound`. Zum Debuggen das nginx-Error-Log kurz einschalten ([Datenschutz](04-datenschutz-und-logging.md#logs-vorübergehend-zum-debuggen-einschalten)). |
| **DoH: HTTP 429** | Rate-Limit greift | `rate`/`burst` in `dns-doh.conf` erhöhen, falls viele Nutzer hinter einer IP sitzen |
| **DoH: HTTP 404** | Falscher Pfad | Die URL muss genau `/dns-query` enden |
| **DoH: HTTP 400/415** | Client schickt falschen Content-Type | POST braucht `content-type: application/dns-message`, GET braucht den Parameter `?dns=` (Base64url) |
| **Zertifikatsfehler bei DoT** | `openssl x509 -in /etc/unbound/tls/fullchain.pem -noout -subject -enddate` | Ist die Kopie veraltet, den Deploy-Hook manuell ausführen (siehe erste Zeile) |
| **Einzelne Domain: SERVFAIL** | `dig @127.0.0.1 domain` | Steht dort `EDE: 6 (DNSSEC Bogus)`, ist das DNSSEC der Domain kaputt. Das ist gewollt, der Fehler liegt beim Domain-Betreiber. Notfalls `domain-insecure: "domain"` setzen (schaltet DNSSEC für diese Domain ab). |
| **Interne Domain liefert keine IP** | Zeigt sie auf eine private IP? | Rebinding-Schutz greift. Lösung: `private-domain` ([Betrieb](07-betrieb-und-wartung.md#interne-records-mit-privaten-ips)) |
| **Langsame erste Antworten** | Normal bei leerem Cache, z. B. nach einem Neustart | Prefetch und Cache füllen sich mit der Nutzung |
| **Windows nutzt DoH nicht** | `netsh dns show encryption` | Die Server-IP muss als DNS-Server eingetragen sein **und** die Vorlage dazu passen |
| **Zertifikat erneuert sich nicht** | `certbot renew --cert-name dns.example.com --dry-run` | Port 80 erreichbar? Zeigt der A-Record noch auf den Server? Liegt der Port-80-Block im nginx-vHost noch? |

## Nützliche Befehle

```bash
journalctl -u unbound -f                         # Live-Log (ohne Anfragen)
unbound-control status                           # Version, Uptime, Threads
unbound-control list_forwards                    # muss leer sein (kein Forwarder)
unbound-control lookup example.com               # welche Nameserver Unbound für eine Zone nutzt
nginx -T | grep -A40 'server_name dns.example.com'
openssl s_client -connect dns.example.com:853 -servername dns.example.com </dev/null 2>/dev/null | openssl x509 -noout -subject -enddate
```
