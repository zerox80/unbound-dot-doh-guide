# 7. Betrieb und Wartung

## Alltag

```bash
systemctl status unbound                 # läuft er?
unbound-checkconf                        # Konfiguration prüfen (immer vor einem Neustart)
systemctl restart unbound                # Neustart (leert den Cache)
unbound-control reload                   # Konfiguration neu laden
unbound-control stats_noreset | grep -E 'total.num.(queries|cachehits|cachemiss)|total.requestlist.exceeded'
unbound-control flush example.com        # einen Namen aus dem Cache werfen
unbound-control flush_zone example.com   # eine ganze Zone aus dem Cache werfen
```

Die Statistiken sind anonyme Zähler ohne IPs und ohne Domains.

## Zertifikat

certbot erneuert automatisch, sein Timer läuft zweimal täglich. Danach läuft der Deploy-Hook: Er kopiert das Zertifikat für Unbound, startet Unbound neu und lädt nginx neu.

```bash
certbot certificates --cert-name dns.example.com
openssl x509 -in /etc/unbound/tls/fullchain.pem -noout -enddate      # muss zum certbot-Datum passen
certbot renew --cert-name dns.example.com --dry-run --run-deploy-hooks
```

`--run-deploy-hooks` lässt den Hook auch beim Probelauf laufen, sonst testet `--dry-run` ihn nicht mit.

Der Unbound-Neustart bei der Erneuerung unterbricht DoT für etwa eine Sekunde, alle 60 bis 90 Tage.

## Updates

Unbound kommt aus dem Distributionspaket. Sicherheitsupdates spielt `unattended-upgrades` automatisch ein.

```bash
systemctl is-active unattended-upgrades
cat /etc/apt/apt.conf.d/20auto-upgrades     # beide Werte "1"
apt list --upgradable 2>/dev/null | grep -i -E 'unbound|nginx|openssl'
```

Nach einem Unbound-Update startet das Paket den Dienst selbst neu. Danach kurz den Selbsttest laufen lassen.

## Regelmäßiger Selbsttest

Zum Beispiel täglich per Cron. Bei einem Fehler schreibt das Skript eine Meldung ins Journal:

```bash
install -m 0750 scripts/dns-selftest.sh /usr/local/sbin/dns-selftest
cat > /etc/cron.d/dns-selftest <<'CRON'
30 6 * * * root /usr/local/sbin/dns-selftest dns.example.com >/dev/null 2>&1 || logger -t dns-selftest "Selbsttest fehlgeschlagen"
CRON
```

Auswerten mit `journalctl -t dns-selftest`.

## Tuning

| Einstellung | Standard hier | Wann ändern |
|---|---|---|
| `num-threads` | 2 | Bei vielen Nutzern auf die Kernzahl erhöhen. Die `*-slabs` auf die nächste Zweierpotenz ≥ Threads setzen. |
| `msg-cache-size` / `rrset-cache-size` | 64 MB / 128 MB | Mehr RAM bringt eine höhere Trefferquote. `rrset` sollte etwa das Doppelte von `msg` sein. |
| `incoming-num-tcp` | 200 pro Thread | Erhöhen, wenn `total.tcpusage` dauerhaft hoch ist |
| nginx `rate` / `burst` | 50/s, 100 | Erhöhen, wenn viele Nutzer hinter einer IP sitzen (z. B. Firmen-NAT) |
| `serve-expired-client-timeout` | 1800 ms | Kleiner bedeutet schneller veraltete Antworten bei Ausfällen fremder Nameserver |

Nach jeder Änderung: `unbound-checkconf && systemctl restart unbound`.

## Erweiterungen

### IPv6 (AAAA-Record) nachrüsten
Am Server ist nichts zu tun, denn Unbound (`::0@853`) und nginx (`[::]:443`) lauschen bereits auf IPv6.
Nur beim DNS-Anbieter den AAAA-Record setzen. Testen:
```bash
dig -6 +tls +tls-hostname=dns.example.com @dns.example.com example.com
```

### Interne Records mit privaten IPs
Der Rebinding-Schutz entfernt Antworten, die auf private Adressen zeigen. Wenn eine eigene öffentliche Domain absichtlich interne IPs hat (z. B. für VPN-Dienste), nimm sie aus:
```
server:
    private-domain: "deine-domain.tld"
```

### Port 53 für VPN-Clients (z. B. WireGuard)
Im verschlüsselten VPN-Tunnel ist Klartext-DNS in Ordnung. Beispiel mit dem Tunnel-Netz `10.8.0.0/24`:
```
server:
    interface: 10.8.0.1@53
    ip-freebind: yes          # Unbound startet auch, wenn das VPN-Interface noch nicht da ist
    access-control: 10.8.0.0/24 allow
```
**Keine** UFW-Freigabe für Port 53 aus dem Internet anlegen, nur aus dem VPN-Interface:
```bash
ufw allow in on wg0 to any port 53 proto udp
ufw allow in on wg0 to any port 53 proto tcp
```

### Server selbst über Unbound auflösen lassen
Dann prüft auch der Server selbst DNSSEC. **Risiko:** Fällt Unbound aus, hat der Server kein DNS mehr (apt, certbot …).
```ini
# /etc/systemd/resolved.conf.d/unbound.conf
[Resolve]
DNS=127.0.0.1
Domains=~.
```
```bash
systemctl restart systemd-resolved && resolvectl query example.com
```

### Werbe- und Tracker-Blocking
Unbound kann Domains per `local-zone: "domain" always_nxdomain` blockieren. Gängige Listen (z. B. Hagezi, StevenBlack) gibt es im Unbound-Format. Sie werden per Cron/Timer geladen, nach `/etc/unbound/unbound.conf.d/blocklist.conf` geschrieben und mit `unbound-control reload` übernommen.
Bei einem öffentlich genutzten Resolver ist das eine **Inhaltsentscheidung für alle Nutzer**, also bewusst treffen.
