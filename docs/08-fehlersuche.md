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
| **Alles fühlt sich langsam an** | `bash scripts/dns-speedtest.sh dns.example.com` | Siehe [unten](#der-resolver-fühlt-sich-langsam-an) |
| **Windows nutzt DoH nicht** | `netsh dns show encryption` | Die Server-IP muss als DNS-Server eingetragen sein **und** die Vorlage dazu passen |
| **Zertifikat erneuert sich nicht** | `certbot renew --cert-name dns.example.com --dry-run` | Port 80 erreichbar? Zeigt der A-Record noch auf den Server? Liegt der Port-80-Block im nginx-vHost noch? |

## Der Resolver fühlt sich langsam an

Eine Namensauflösung über diesen Resolver besteht aus drei Strecken. Erst messen, welche davon bremst:

```
Gerät ──(1) Weg zum Server, TLS-Handshake──► Server ──(2) Cache?──► sofort
                                                └─────(3) Rekursion──► fremde Nameserver
```

**Auf dem Server:**
```bash
bash scripts/dns-speedtest.sh dns.example.com
```

**Auf dem Gerät** (misst Strecke 1; unter Windows in der PowerShell mit `curl.exe` und `-o NUL`):
```bash
curl -s -o /dev/null -H 'accept: application/dns-message' -w 'TCP %{time_connect}s  TLS %{time_appconnect}s  gesamt %{time_total}s\n' 'https://dns.example.com/dns-query?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB'
```
`TCP` ist eine Laufzeit Gerät → Server → Gerät. Eine neue Verbindung kostet etwa das Dreifache davon, bevor die erste Antwort da ist. Danach bleibt die Verbindung offen und jede weitere Anfrage kostet nur noch eine Laufzeit.

| Messwert | Bedeutet | Lösung |
|---|---|---|
| `serve-expired-client-timeout` ist nicht `0` | Abgelaufene Einträge warten auf eine volle Rekursion. Bei wenigen Nutzern betrifft das fast jede Anfrage. | `serve-expired-client-timeout: 0` ([Architektur](01-architektur.md#warum-beantwortet-unbound-abgelaufene-einträge-sofort)) |
| Abschnitt 1: „Cache“ über wenige ms | Der Server selbst ist überlastet | `top` prüfen, auf einem VPS auch den Wert `st` (CPU-Steal durch Nachbarn) |
| Abschnitt 1: „kalt“ im Median über 300 ms | Der Weg zu fremden Nameservern ist langsam | Abschnitt 2 ansehen |
| Abschnitt 2: IPv6 ohne Antwort und `prefer-ip4: no` | Unbound wartet bei jedem IPv6-Nameserver auf einen Timeout | `prefer-ip4: yes` |
| Abschnitt 2: IPv4/TCP ohne Antwort | Ausgehendes TCP 53 ist gesperrt, große DNSSEC-Antworten kommen nie an | Ausgehende Firewall-Regeln prüfen |
| Abschnitt 2: IPv4/UDP deutlich über 50 ms | Der Server ist schlecht angebunden oder steht weit weg | Paketverlust prüfen: `mtr -u -P 53 193.0.14.129`. Das kann nur der Hoster beheben. |
| Abschnitt 3 im niedrigen zweistelligen Bereich, auf dem Gerät trotzdem langsam | Der Server ist nicht die Bremse | `TCP`-Wert vom Gerät ansehen. Über etwa 80 ms macht sich der Standort des Servers bemerkbar. |
| Abschnitt 4: Cache-Trefferquote dauerhaft unter 50 % | Der Nutzerkreis ist zu klein, um den Cache warm zu halten | `serve-expired` wie oben, eventuell `serve-expired-ttl` erhöhen ([Tuning](07-betrieb-und-wartung.md#tuning)) |
| Abschnitt 4: SERVFAIL-Anteil über 5 % | Fremde Nameserver sind schlecht erreichbar, oder DNSSEC schlägt fehl | Abschnitt 2 ansehen, Uhrzeit des Servers prüfen (`timedatectl`) |
| Browser mit DoH: Seiten mit vielen Elementen laden zäh | Das Rate-Limit lehnt Anfragen mit 429 ab | `rate`/`burst` in `dns-doh.conf` erhöhen |

**Was normal ist:** Die allererste Anfrage nach einem Namen, den seit 24 Stunden niemand gefragt hat, braucht eine volle Rekursion (typisch 50 bis 300 ms). Nach einem Neustart von Unbound ist der Cache leer, dann gilt das für jeden Namen einmal.

## Nützliche Befehle

```bash
journalctl -u unbound -f                         # Live-Log (ohne Anfragen)
unbound-control status                           # Version, Uptime, Threads
unbound-control list_forwards                    # muss leer sein (kein Forwarder)
unbound-control lookup example.com               # welche Nameserver Unbound für eine Zone nutzt
nginx -T | grep -A40 'server_name dns.example.com'
openssl s_client -connect dns.example.com:853 -servername dns.example.com </dev/null 2>/dev/null | openssl x509 -noout -subject -enddate
```
