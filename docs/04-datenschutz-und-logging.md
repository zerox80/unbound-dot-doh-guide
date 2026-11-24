# 4. Datenschutz und Logging

**Ziel: Weder Client-IPs noch angefragte Domains werden dauerhaft gespeichert.**

## Was wo gespeichert wird

| Stelle | Gespeichert? | Einstellung |
|---|---|---|
| **Unbound: Anfragen und Antworten** | Nein | `log-queries: no`, `log-replies: no`, `log-local-actions: no`, `log-servfail: no` |
| **Unbound: DNSSEC-Fehler** | Nein | `val-log-level: 0` |
| **Unbound: Journal** | Nur Start und Stop, Trust-Anchor-Signal (RFC 8145) und beim Beenden anonyme Summenstatistiken. Keine IPs, keine Domains. | `verbosity: 1` |
| **nginx: DNS-vHost** | Nein, auch keine Rate-Limit-Treffer | `access_log off;` + `error_log /dev/null;` |
| **nginx: global** | Fehler *vor* der vHost-Zuordnung (z. B. kaputte TLS-Handshakes) laufen auf Level `info`. Bei üblichem globalem Level `notice`/`error` werden sie nicht geschrieben. | `/etc/nginx/nginx.conf` |
| **Firewall (UFW)** | Je nach Logging-Stufe nur **blockierte** Pakete (z. B. Port-53-Scans). Erlaubte DoT/DoH-Verbindungen werden bei `low` nicht protokolliert. | `ufw logging low` |

## Was nur im Arbeitsspeicher liegt

- **Unbound-Cache:** Welche Domains kürzlich gefragt wurden, **aber nicht von wem**. Ein Neustart leert ihn. Einsehbar nur für root mit `unbound-control dump_cache`.
- **nginx-Rate-Limit-Tabelle:** Zähler pro Client-IP, laufend überschrieben.
- **Conntrack-Tabelle des Kernels:** aktive Verbindungen, laufen nach Sekunden bis Minuten aus.

## Was nach außen geht

| Empfänger | Sieht | Gegenmaßnahme |
|---|---|---|
| Autoritative Nameserver | Die IP des **Servers**, nie die IP des Geräts | Kein `subnetcache`-Modul, also kein EDNS Client Subnet |
| Root- und TLD-Server | Nur den Teil des Namens, für den sie zuständig sind (z. B. nur `.de`) | `qname-minimisation: yes` |
| Mitlesende auf dem Weg Gerät → Server | Nur verschlüsselte Daten. Die Länge der Antworten ist auf Blockgröße gepolstert. | TLS, `pad-responses: yes` |

## Logs vorübergehend zum Debuggen einschalten

Nur kurz und danach unbedingt zurückstellen:

```bash
# Unbound (gilt bis zum nächsten Neustart)
unbound-control verbosity 2
unbound-control set_option log-queries: yes
# ... testen ...
unbound-control set_option log-queries: no
unbound-control verbosity 1
```

nginx: in `/etc/nginx/sites-available/dns-doh.conf` `error_log /dev/null;` vorübergehend durch `error_log /var/log/nginx/dns-doh.error.log;` ersetzen, dann `nginx -t && systemctl reload nginx`. Danach zurückstellen und die Logdatei löschen.

## Prüfen, dass nichts geloggt wird

```bash
unbound-control get_option log-queries      # no
unbound-control get_option log-replies      # no
journalctl -u unbound --since today | grep -v -E 'notice|info: (start|server stats|generate keytag)|systemd'
nginx -T 2>/dev/null | grep -A3 'server_name dns.example.com' | grep -E 'access_log|error_log'
```

Der [Selbsttest](06-tests.md) prüft die wichtigsten Punkte automatisch.

## Hinweis, wenn Dritte den Resolver nutzen

Wenn andere Personen deinen Resolver nutzen, verarbeitest du technisch deren IP-Adressen, wenn auch nur flüchtig im Arbeitsspeicher. Je nach Rechtsraum und Nutzerkreis können daraus Pflichten entstehen (z. B. Datenschutzhinweis).
Dieses Setup hält die Verarbeitung so gering wie technisch möglich. Eine Rechtsberatung ersetzt es nicht.
