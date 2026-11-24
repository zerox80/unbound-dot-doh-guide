# 1. Architektur und Designentscheidungen

## Komponenten

| Komponente | Aufgabe | Lauscht auf |
|---|---|---|
| **Unbound** | Rekursiver, DNSSEC-validierender Resolver mit Cache | `127.0.0.1:53`, `[::1]:53` (Klartext, lokal) · `0.0.0.0:853`, `[::]:853` (DoT) · `127.0.0.1:8053` (DoH-Backend) |
| **nginx** | TLS-Terminierung und HTTP/2 für DoH, Rate-Limit pro Client, Let's-Encrypt-Prüfung | `:80`, `:443` (gemeinsam mit anderen vHosts) |
| **certbot** | Zertifikat ausstellen und erneuern | – |
| **Deploy-Hook** | Zertifikat nach `/etc/unbound/tls/` kopieren, Dienste neu laden | – |
| **UFW** | Nur `853/tcp` zusätzlich freigeben | – |

## Datenfluss

**DoT:** Das Gerät baut eine TLS-Verbindung zu `dns.example.com:853` auf. Unbound terminiert TLS selbst, löst rekursiv auf und antwortet über dieselbe Verbindung.

**DoH:** Das Gerät schickt `POST` oder `GET https://dns.example.com/dns-query`. nginx terminiert TLS, prüft das Rate-Limit und reicht die Anfrage per HTTP/2 ohne TLS an `127.0.0.1:8053` weiter. Unbound beantwortet sie dort.

**Rekursion:** Unbound fragt nacheinander Root-, TLD- und autoritative Nameserver. Er prüft dabei die DNSSEC-Signaturen und legt das Ergebnis in den Cache.

---

## Entscheidungen und Begründungen

### Warum ein rekursiver Resolver und kein Forwarder?
Ein Forwarder schickt alle Anfragen an einen großen Anbieter (Google, Cloudflare, Quad9). Der sieht dann jede Domain, die deine Geräte auflösen.
Ein rekursiver Resolver fragt die zuständigen Nameserver selbst. Kein einzelner Dritter sieht alle Anfragen, und dank QNAME-Minimierung erfährt jeder Server nur den Teil des Namens, für den er zuständig ist.

### Warum DoT **und** DoH?
- **Android** kann systemweit („Privates DNS“) nur **DoT** mit eigenem Hostnamen.
- **Browser** (Firefox, Chrome, Edge) und **Windows 11** können nur **DoH** mit eigener URL.
- **iOS/macOS** können beides über ein Konfigurationsprofil.

Nur eins von beiden würde also immer eine Gerätegruppe ausschließen.

### Warum ist Port 53 nicht öffentlich?
Ein öffentlicher Resolver auf UDP 53 ist ein **offener Resolver**. Angreifer schicken kleine Anfragen mit gefälschter Absender-IP, und der Resolver schickt große Antworten an das Opfer (DNS-Amplification, oft 50-fache Verstärkung).
Solche Server werden innerhalb von Stunden gefunden und missbraucht. Die Folge sind Abuse-Meldungen und die Sperrung durch den Hoster.

DoT und DoH laufen über **TCP**. Ohne erfolgreichen TCP-Handshake gibt es keine Antwort, eine gefälschte Absender-IP bringt also nichts.

Klartext-DNS ist außerdem unverschlüsselt und manipulierbar. Für Geräte im Internet ist es ohnehin keine gute Wahl.

### Warum DoH über nginx statt direkt aus Unbound?
- Port 443 ist auf den meisten Servern schon von nginx belegt, der auch andere Websites ausliefert.
- nginx übernimmt TLS, HTTP/2 und Zertifikate genau wie bei den anderen vHosts.
- Unbound sieht bei DoH nur nginx als Absender. Ein Rate-Limit pro echter Client-IP geht deshalb nur in nginx.

### Warum `grpc_pass` und nicht `proxy_pass`?
Unbound spricht DoH ausschließlich über **HTTP/2**. nginx' `proxy_pass` spricht zu Backends aber nur HTTP/1.x.
`grpc_pass` ist in nginx der Weg, HTTP/2 im Klartext (h2c) an ein Backend zu senden. Das funktioniert nicht nur für gRPC, sondern für jede HTTP/2-Anfrage. Beide Methoden (`GET ?dns=…` und `POST`) sind getestet.

Unbound läuft dafür auf `127.0.0.1:8053` mit `http-notls-downstream: yes`, also ohne TLS. Das ist sicher, weil der Port nur auf Loopback lauscht.

### Warum das Unbound-Paket der Distribution und kein Docker-Container?
- Sicherheitsupdates kommen automatisch über `apt` und `unattended-upgrades`.
- Ubuntu liefert ein **AppArmor-Profil** mit. Selbst bei einer Lücke darf Unbound nur `/etc/unbound/**` lesen.
- Kein Docker-NAT: Unbound sieht die echten Client-IPs (wichtig für DoT-Limits), und Docker kann keine Firewall-Regeln am Host vorbei öffnen.
- systemd startet den Dienst früh und übernimmt die Überwachung.

### Warum wird das Zertifikat kopiert und nicht direkt aus `/etc/letsencrypt` gelesen?
- Das AppArmor-Profil erlaubt Unbound nur `/etc/unbound/**`.
- Die Schlüssel in `/etc/letsencrypt/archive/` sind nur für root lesbar. Unbound läuft aber als Benutzer `unbound`.

Der Deploy-Hook kopiert deshalb nach jeder Erneuerung `fullchain.pem` und `privkey.pem` nach `/etc/unbound/tls/`. Der Schlüssel bekommt Modus `0640` und Gruppe `unbound`.

### Warum `webroot` statt `certbot --nginx`?
Das nginx-Plugin von certbot verändert nginx-Konfigurationsdateien selbstständig. Mit `--webroot` legt certbot nur eine Datei in `/var/www/letsencrypt/` ab, und die nginx-Konfiguration bleibt vollständig unter eigener Kontrolle.

### Warum wird `unbound-resolvconf` deaktiviert?
Das Ubuntu-Paket bringt einen Helfer mit, der den systemweiten DNS des Servers auf Unbound umstellen kann. Das soll eine bewusste Entscheidung bleiben (siehe [Betrieb](07-betrieb-und-wartung.md#server-selbst-über-unbound-auflösen-lassen)) und nicht nebenbei nach einem Neustart passieren.

### Warum zwei Unbound-Konfigurationsdateien?
- `10-public-resolver.conf` enthält alles, was ohne Zertifikat funktioniert, und lässt sich sofort testen.
- `20-dot.conf` braucht das Zertifikat und kommt erst danach dazu. So startet Unbound in jeder Phase der Installation.

Die Paketdateien unter `/etc/unbound/` bleiben unverändert. Bei Paket-Updates gibt es deshalb keine Konflikte.
