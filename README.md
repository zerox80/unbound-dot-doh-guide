# Unbound mit DNS-over-TLS und DNS-over-HTTPS

Eigener verschlüsselter DNS-Resolver auf einem Linux-Server. Er löst rekursiv auf, prüft DNSSEC und schreibt keine Logs.
Öffentlich erreichbar ist er nur über **DoT (TCP 853)** und **DoH (HTTPS 443 über nginx)**. Klartext-DNS auf Port 53 bleibt auf dem Server.

Getestet mit Ubuntu 26.04 LTS, Unbound 1.24.2, nginx 1.28 und certbot 5.

---

## Was das Setup kann

- **Rekursiv statt weiterleitend:** Unbound fragt Root-, TLD- und autoritative Nameserver selbst. Google, Cloudflare & Co. sind nicht beteiligt.
- **DNSSEC-Validierung:** Manipulierte Antworten werden verworfen und der Client bekommt eine erklärende Fehlermeldung (Extended DNS Error).
- **Verschlüsselt für alle Geräte:** DoT für Android „Privates DNS“, DoH für Browser und Windows 11, beides für iOS/macOS.
- **Kein offener Resolver:** Öffentlich gibt es nur TCP-Dienste. Der Server lässt sich nicht für DNS-Amplification-Angriffe missbrauchen.
- **Keine Logs:** Weder Client-IPs noch angefragte Domains landen auf der Festplatte.
- **Datensparsam nach außen:** QNAME-Minimierung, kein EDNS Client Subnet, Padding verschlüsselter Antworten.
- **Missbrauchsschutz:** Rate-Limit pro Client-IP (DoH), Rate-Limit pro Zone (Unbound), ANY-Anfragen gesperrt, begrenzte TCP-Slots.
- **Zertifikate erneuern sich selbst:** Let's Encrypt über certbot, ein Deploy-Hook übergibt das Zertifikat an Unbound.

## Aufbau

```
                  ┌───────────────────────── Server ─────────────────────────┐
Gerät ── DoT ───► │ TCP 853 ──────────────────────────► Unbound              │
  (TLS)           │                                       │                  │
Gerät ── DoH ───► │ TCP 443 ► nginx (TLS, HTTP/2,         │  rekursiv,       │ ──► Root-, TLD- und
  (HTTPS)         │           Rate-Limit pro IP)          │  DNSSEC,         │     autoritative
                  │             └─ HTTP/2 ohne TLS ─► 127.0.0.1:8053         │     Nameserver
                  │                                       │                  │
                  │ Server selbst ──────────────────► 127.0.0.1:53           │
                  └──────────────────────────────────────────────────────────┘
                     Port 53 von außen: geschlossen
```

## Inhalt des Repos

| Pfad | Inhalt |
|---|---|
| [`docs/01-architektur.md`](docs/01-architektur.md) | Aufbau und alle Designentscheidungen mit Begründung |
| [`docs/02-installation.md`](docs/02-installation.md) | Schritt-für-Schritt-Installation, jeder Schritt mit „warum“ |
| [`docs/03-sicherheit.md`](docs/03-sicherheit.md) | Bedrohungen, Gegenmaßnahmen und Grenzen des Setups |
| [`docs/04-datenschutz-und-logging.md`](docs/04-datenschutz-und-logging.md) | Was wo gespeichert wird (und was nicht) |
| [`docs/05-geraete-einrichten.md`](docs/05-geraete-einrichten.md) | Android, iOS/macOS, Windows, Linux, Browser |
| [`docs/06-tests.md`](docs/06-tests.md) | Selbsttest, manuelle Tests, Tests von außen |
| [`docs/07-betrieb-und-wartung.md`](docs/07-betrieb-und-wartung.md) | Alltag, Zertifikate, Updates, Tuning, Erweiterungen |
| [`docs/08-fehlersuche.md`](docs/08-fehlersuche.md) | Typische Probleme und Lösungen |
| [`docs/09-rueckbau.md`](docs/09-rueckbau.md) | Alles wieder entfernen |
| [`config/unbound/`](config/unbound/) | Unbound-Konfiguration (`10-public-resolver.conf`, `20-dot.conf`) |
| [`config/nginx/dns-doh.conf`](config/nginx/dns-doh.conf) | nginx-vHost für DoH und Let's-Encrypt-Prüfung |
| [`scripts/unbound-tls-deploy`](scripts/unbound-tls-deploy) | certbot-Deploy-Hook: Zertifikat an Unbound übergeben |
| [`scripts/dns-selftest.sh`](scripts/dns-selftest.sh) | Automatischer Selbsttest mit 24 Prüfungen |
| [`clients/`](clients/) | Konfigurationsprofile für iPhone, iPad und Mac (DoH und DoT) |

## Schnellstart

1. **DNS-Record anlegen:** `dns.example.com` → A (und optional AAAA) **direkt** auf den Server, ohne CDN-Proxy.
2. **Installation:** [`docs/02-installation.md`](docs/02-installation.md) Schritt für Schritt durchgehen.
3. **Prüfen:** `sudo bash scripts/dns-selftest.sh dns.example.com` muss mit `0 Fehler` enden.
4. **Geräte umstellen:** [`docs/05-geraete-einrichten.md`](docs/05-geraete-einrichten.md).

## Platzhalter

Alle Dateien nutzen Beispielwerte aus den reservierten Dokumentationsbereichen (RFC 2606, RFC 5737, RFC 3849):

| Platzhalter | Ersetzen durch |
|---|---|
| `dns.example.com` | deinen DNS-Hostnamen |
| `203.0.113.10` | die öffentliche IPv4 deines Servers |
| `2001:db8::10` | die öffentliche IPv6 deines Servers (optional) |

Ersetzen auf dem Server, z. B.:

```bash
sed -i 's/dns\.example\.com/dns.deine-domain.tld/g' /etc/nginx/sites-available/dns-doh.conf /usr/local/sbin/unbound-tls-deploy
```

## Voraussetzungen

- Linux-Server mit öffentlicher IPv4 (IPv6 optional) und Root-Zugriff
- Ubuntu oder Debian mit **Unbound ≥ 1.17, gebaut mit libnghttp2** (prüfen: `unbound -V | grep -o libnghttp2`)
- **nginx ≥ 1.25** (für `http2 on;`) mit `http_v2`- und `grpc`-Modul (bei Ubuntu/Debian Standard)
- **certbot**
- Eine (Sub-)Domain, deren A-/AAAA-Record direkt auf den Server zeigt
- Eine Firewall. Die Beispiele nutzen UFW.

## Lizenz und Haftung

Die Anleitung ist ohne Gewähr. Prüfe jeden Schritt, bevor du ihn auf einem Produktivsystem ausführst.
