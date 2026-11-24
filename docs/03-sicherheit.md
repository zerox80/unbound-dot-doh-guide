# 3. Sicherheit

## Bedrohungen und Gegenmaßnahmen

| Bedrohung | Gegenmaßnahme | Wo |
|---|---|---|
| **Missbrauch als DDoS-Verstärker** (offener Resolver) | Port 53 nur an `127.0.0.1`/`::1`. Öffentlich nur TCP (853, 443), dort sind gefälschte Absender-IPs wirkungslos. Unbound öffnet auf 853 kein UDP. | `10-public-resolver.conf`, `20-dot.conf`, UFW |
| **ANY-Verstärkung** | `deny-any: yes` beantwortet ANY nicht | `10-public-resolver.conf` |
| **Angriff auf fremde Nameserver über deinen Resolver** (z. B. Random-Subdomain-Flut) | `ratelimit: 1000` begrenzt die Anfragen pro Zone an die autoritativen Server | `10-public-resolver.conf` |
| **Cache-Poisoning / gefälschte Antworten** | DNSSEC-Validierung (`validator`), `harden-glue`, `harden-dnssec-stripped`, `harden-below-nxdomain`, `unwanted-reply-threshold` (leert den Cache bei auffällig vielen unerwarteten Antworten) | `10-public-resolver.conf` |
| **Fälschung über fragmentierte UDP-Antworten** | `edns-buffer-size: 1232`: Antworten passen ohne Fragmentierung in ein Paket, größere laufen über TCP | `10-public-resolver.conf` |
| **DNS-Rebinding** (fremde Domain zeigt auf `192.168.x.x`, Website greift über den Browser den Router an) | `private-address` für RFC1918, CGNAT, Link-Local, ULA, IPv4-mapped | `10-public-resolver.conf` |
| **Downgrade auf unsignierte Antworten** | `harden-dnssec-stripped: yes`: Fehlen bei einer signierten Zone die Signaturen, ist die Antwort ungültig | `10-public-resolver.conf` |
| **Ausspähen der Software-Version** | `hide-identity`, `hide-version`, `hide-trustanchor` | `10-public-resolver.conf` |
| **Überlastung durch einzelne Clients** | nginx `limit_req` 50/s pro IP, Burst 100, Antwort 429 | `dns-doh.conf` |
| **Verbindungsflut auf DoT** | `incoming-num-tcp: 200` pro Thread begrenzt die gleichzeitigen TCP-Verbindungen. Leerlauf-Verbindungen werden nach Timeout geschlossen. | `10-public-resolver.conf` |
| **Diebstahl des TLS-Schlüssels** | Schlüssel `0640 root:unbound`, Verzeichnis `0750`. AppArmor sperrt Unbound auf `/etc/unbound/**` ein. | Deploy-Hook, AppArmor |
| **Abgelaufenes Zertifikat** | Automatische Erneuerung durch certbot, Deploy-Hook übergibt an Unbound und nginx | certbot, `unbound-tls-deploy` |
| **Bekannte Sicherheitslücken** | Distributionspaket + `unattended-upgrades` | apt |
| **Zugriff auf das DoH-Backend an nginx vorbei** | `127.0.0.1:8053` lauscht nur auf Loopback | `10-public-resolver.conf` |
| **Andere Pfade auf dem DoH-Host** | `location / { return 404; }`, nur `/dns-query` wird weitergereicht | `dns-doh.conf` |
| **TLS-Downgrade** | Die TLS-Standards von nginx und OpenSSL 3 (TLS ≥ 1.2), HSTS auf dem DoH-Host | nginx |

## Was dieses Setup bewusst nicht tut

- **Kein Zugriffsschutz für DoT/DoH:** Jeder, der den Hostnamen kennt, kann den Resolver verschlüsselt nutzen. Eine IP-Sperre wäre mit wechselnden Mobilfunk-IPs nicht praktikabel, und Android-DoT kennt keine Tokens.
  Ein Verstärkungsrisiko entsteht dadurch nicht, nur Last. Die Rate-Limits begrenzen sie.
- **Kein Schutz gegen große Botnetz-DDoS-Angriffe.** Dafür braucht es einen DDoS-Schutz beim Hoster.
- **Keine Filter- oder Blocklisten** (Werbung, Malware). Ergänzen geht, siehe [Betrieb](07-betrieb-und-wartung.md#erweiterungen).
- **`use-caps-for-id` (0x20-Bit-Kodierung) ist aus.** Das bringt etwas zusätzliche Spoofing-Resistenz, führt aber bei manchen fehlerhaften Nameservern zu Ausfällen. DNSSEC schützt signierte Zonen ohnehin stärker.
- **`harden-large-queries` ist aus.** DoT- und DoH-Clients polstern Anfragen (Padding), daher wären Fehlalarme möglich.

## Grenzen

- **Der Zugangsanbieter** des Geräts sieht weiterhin, *dass* es mit deinem Server spricht (IP, Zeitpunkt, Datenmenge), aber nicht *was*.
- **Der Hoster des Servers** sieht den ausgehenden Verkehr zu den Nameservern. Der ist bei DNS grundsätzlich unverschlüsselt (Rekursion). QNAME-Minimierung reduziert, was dabei sichtbar wird.
- **Die TLS-Verbindung zur Website** verrät den Hostnamen weiterhin per SNI, solange die Website kein ECH nutzt. Das liegt außerhalb von DNS.

## Empfohlene Kontrollen

- Regelmäßig `bash scripts/dns-selftest.sh dns.example.com` ausführen (z. B. per Cron, siehe [Betrieb](07-betrieb-und-wartung.md#regelmäßiger-selbsttest)).
- Nach Firewall-Änderungen von außen prüfen, dass Port 53 geschlossen bleibt ([Tests](06-tests.md#tests-von-außen)).
