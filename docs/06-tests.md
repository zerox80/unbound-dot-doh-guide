# 6. Tests

## Automatischer Selbsttest (auf dem Server)

```bash
bash scripts/dns-selftest.sh dns.example.com
```

Das Skript prüft 24 Punkte in sechs Gruppen:

| Gruppe | Prüfungen |
|---|---|
| Dienste | Unbound läuft, Unbound- und nginx-Konfiguration fehlerfrei |
| Ports | Port 53 nur auf Loopback, DoT nur TCP, DoH-Backend nur auf `127.0.0.1` |
| Resolver | DNSSEC gültig (`ad`), DNSSEC kaputt (SERVFAIL), QNAME-Minimierung, Version versteckt, ANY gesperrt |
| Verschlüsselt | DoT, DoH-POST, DoH-GET (jeweils mit echter Zertifikatsprüfung), falscher Pfad gibt 404 |
| Zertifikat | Mindestens 14 Tage gültig, Unbound-Kopie gleich dem certbot-Zertifikat, Schlüsselrechte `640 root:unbound`, Deploy-Hook eingetragen |
| Logging & Firewall | Unbound loggt keine Anfragen/Antworten, nginx-vHost ohne Logs, UFW erlaubt 853/tcp, UFW erlaubt **kein** 53 |

Exit-Code `0` = alles ok, `1` = mindestens ein Fehler. Damit eignet sich das Skript auch für Cron oder Monitoring.

> **Was der Server nicht selbst testen kann:** Ob Port 53 **von außen** geschlossen ist. Verkehr vom Server an seine eigene IP läuft über das Loopback-Interface und umgeht die Firewall. Dafür gibt es die Tests von außen unten.

---

## Geschwindigkeit messen (auf dem Server)

```bash
bash scripts/dns-speedtest.sh dns.example.com
```

Der Selbsttest prüft, **ob** alles funktioniert. Dieses Skript misst, **wie schnell**, und zwar jede Schicht einzeln:

| Abschnitt | Misst |
|---|---|
| Einstellungen | Ob die tempo-relevanten Optionen aktiv sind |
| 1. Resolver selbst | Zehn bekannte Websites, einmal kalt (vorher aus dem Cache geworfen) und einmal aus dem Cache |
| 2. Weg zu fremden Nameservern | Root-Server über IPv4/UDP, IPv4/TCP und IPv6 |
| 3. Verschlüsselte Zugänge | DoT und DoH vom Server aus, mit neuer und mit bestehender Verbindung |
| 4. Statistik | Cache-Trefferquote, Dauer der Rekursionen, SERVFAIL-Anteil seit dem letzten Start |

Am Ende stehen Hinweise zu allem, was auffällt. Was die Werte bedeuten: [Fehlersuche](08-fehlersuche.md#der-resolver-fühlt-sich-langsam-an).

Eigene Domains als weitere Argumente anhängen (ohne `www.`): `bash scripts/dns-speedtest.sh dns.example.com example.org example.net`

---

## Manuelle Tests auf dem Server

```bash
H=dns.example.com
CA="+tls-ca=/etc/ssl/certs/ca-certificates.crt +tls-hostname=$H"

# DoT mit Zertifikatsprüfung
dig +tls $CA @$H example.com A
# DoH per POST / GET
dig +https     $CA @$H example.com A
dig +https-get $CA @$H example.com AAAA
# DoH-Backend direkt (ohne nginx)
dig +http-plain=/dns-query @127.0.0.1 -p 8053 example.com

# DNSSEC
dig @127.0.0.1 dnssec-failed.org          # status: SERVFAIL, EDE: 6 (DNSSEC Bogus)
dig @127.0.0.1 +dnssec isc.org            # flags: ... ad
# Privatsphäre / Härtung
dig @127.0.0.1 +short qnamemintest.internet.nl TXT | tail -1   # "HOORAY - QNAME minimisation is enabled ..."
dig @127.0.0.1 version.bind CH TXT        # status: REFUSED
dig @127.0.0.1 example.com ANY            # ANSWER: 0

# Wer lauscht wo?
ss -tulpn | grep unbound
```

### Rate-Limit testen

```bash
Q="https://dns.example.com/dns-query?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB"
seq 1 1500 | xargs -P 100 -I{} curl -s -o /dev/null -w '%{http_code}\n' -H 'accept: application/dns-message' "$Q" | sort | uniq -c
```
Erwartet ist eine Mischung aus `200` und `429`. Wie viele `429` kommen, hängt vom Tempo ab: Die ersten 400 Anfragen gehen immer durch (Burst), danach 100 pro Sekunde.
Danach prüfen, dass **keine** neuen Zeilen in `/var/log/nginx/error.log` stehen.

Die Zeichenkette hinter `dns=` ist die Beispielanfrage aus RFC 8484 (`www.example.com A`, Base64url).

---

## Tests von außen

Von einem **anderen Rechner** aus, nicht vom Server selbst.

### Windows (PowerShell)

```powershell
# DoH: muss 200 ausgeben
curl.exe -s -o NUL -w "%{http_code}`n" --doh-url https://dns.example.com/dns-query https://example.com

# DoT-Port erreichbar?
Test-NetConnection dns.example.com -Port 853

# Port 53 MUSS geschlossen sein: Zeitüberschreitung = gut
Resolve-DnsName example.com -Server 203.0.113.10 -DnsOnly -QuickTimeout
```

### Linux / macOS

```bash
# DoT mit kdig (Paket knot-dnsutils)
kdig +tls-ca +tls-host=dns.example.com @203.0.113.10 example.com
# DoT mit dig (BIND >= 9.18)
dig +tls +tls-hostname=dns.example.com @dns.example.com example.com
# DoH
curl -s -o /dev/null -w '%{http_code}\n' --doh-url https://dns.example.com/dns-query https://example.com
# Port 53 MUSS geschlossen sein
dig +time=3 +tries=1 @203.0.113.10 example.com      # "connection timed out" = gut
```

### DoT ohne dig/kdig (nur openssl)

Schickt eine echte DNS-Anfrage (`example.com A`) über TLS:

```bash
( printf '\x00\x1d\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01'; sleep 3 ) \
 | openssl s_client -quiet -connect dns.example.com:853 -servername dns.example.com \
     -verify_hostname dns.example.com -verify_return_error 2>/dev/null | od -An -tx1 | head -2
```

Erwartet: Die Ausgabe beginnt mit zwei Längen-Bytes, danach `12 34 81 80`. Das heißt: gleiche ID, Antwort, kein Fehler.

### Online

- **dnsleaktest.com** (vom eingerichteten Gerät aus): Es darf nur die IP deines Servers erscheinen.
- **internet.nl → „Test your connection“**: prüft u. a., ob der genutzte Resolver DNSSEC validiert.
