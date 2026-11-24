# 5. Geräte einrichten

| Zugang | Wert |
|---|---|
| DoT-Hostname | `dns.example.com` |
| DoH-URL | `https://dns.example.com/dns-query` |
| Server-IP (nur wo verlangt) | `203.0.113.10` / `2001:db8::10` |

> **Firmengeräte:** DNS-Einstellungen nur mit Freigabe der IT ändern. Ein eigener verschlüsselter Resolver umgeht Firmen-DNS und -Filter.

---

## Android (ab Version 9)

Einstellungen → Netzwerk & Internet → **Privates DNS** → „Hostname des Anbieters für privates DNS“ → `dns.example.com`

- Samsung: Einstellungen → Verbindungen → Weitere Verbindungseinstellungen → Privates DNS
- Nur den Hostnamen eintragen, **ohne** `https://` und ohne Port.
- Das gilt systemweit für WLAN und Mobilfunk.

## iPhone, iPad, Mac

Apple-Geräte brauchen ein **Konfigurationsprofil**. Vorlagen:

- [`clients/apple-doh.mobileconfig`](../clients/apple-doh.mobileconfig): DNS-over-HTTPS (empfohlen)
- [`clients/apple-dot.mobileconfig`](../clients/apple-dot.mobileconfig): DNS-over-TLS

Vorbereitung:
1. `dns.example.com` (und bei DoT die IP) durch deine Werte ersetzen.
2. Die beiden `PayloadUUID`-Werte durch neue UUIDs ersetzen (Windows: `New-Guid` in PowerShell, macOS/Linux: `uuidgen`).
3. Die Datei per AirDrop, Mail oder Download aufs Gerät bringen.

Installieren:
- **iOS/iPadOS:** Einstellungen → „Profil geladen“ → Installieren. Danach unter Einstellungen → Allgemein → **VPN, DNS & Geräteverwaltung → DNS** das Profil auswählen.
- **macOS:** Doppelklick auf die Datei, dann Systemeinstellungen → Datenschutz & Sicherheit → **Profile** → Installieren.

Die Menünamen weichen je nach Version leicht ab.

## Windows 11

Einstellungen → Netzwerk und Internet → Ethernet bzw. WLAN → **DNS-Serverzuweisung → Bearbeiten** → Manuell

| Feld | Wert |
|---|---|
| IPv4 | Ein |
| Bevorzugter DNS | `203.0.113.10` |
| DNS über HTTPS | **Ein (manuelle Vorlage)** |
| DoH-Vorlage | `https://dns.example.com/dns-query` |
| Fallback auf Klartext | **Aus** |

**Warum „Fallback aus“:** Mit Fallback würde Windows bei Problemen Port 53 versuchen. Der ist absichtlich geschlossen, und Klartext wäre ohnehin unverschlüsselt.

Für IPv6 dasselbe mit `2001:db8::10`, falls ein AAAA-Record existiert.

## Firefox

Einstellungen → Datenschutz & Sicherheit → **DNS über HTTPS** → „Maximaler Schutz“ → Anbieter wählen: **Benutzerdefiniert** → `https://dns.example.com/dns-query`

„Maximaler Schutz“ heißt: kein stiller Rückfall auf den System-DNS.

## Chrome

Einstellungen → Datenschutz und Sicherheit → Sicherheit → **Sicheres DNS verwenden** → „Benutzerdefinierten DNS-Anbieter auswählen“ → `https://dns.example.com/dns-query`

## Edge

Einstellungen → Datenschutz, Suche und Dienste → Sicherheit → **Sicheres DNS verwenden** → „Dienstanbieter auswählen“ → `https://dns.example.com/dns-query`

## Brave

Einstellungen → Datenschutz und Sicherheit → Sicherheit → **Sicheres DNS verwenden** → „Mit“ → Benutzerdefiniert → `https://dns.example.com/dns-query`

## Linux (systemd-resolved)

```ini
# /etc/systemd/resolved.conf.d/dot.conf
[Resolve]
DNS=203.0.113.10#dns.example.com
DNS=2001:db8::10#dns.example.com
DNSOverTLS=yes
DNSSEC=no
Domains=~.
```

```bash
systemctl restart systemd-resolved
resolvectl status | grep -A2 'Global'
resolvectl query example.com
```

- **`#dns.example.com`** sagt resolved, auf welchen Namen das Zertifikat geprüft wird.
- **`DNSSEC=no`:** Der Server validiert bereits, eine doppelte Validierung in resolved verursacht eher Probleme.
- **`Domains=~.`** schickt alle Anfragen über diesen Server.

## Prüfen, ob das Gerät den Resolver nutzt

- Eine Seite wie **dnsleaktest.com** („Standard test“) öffnen. Angezeigt werden sollte nur die IP **deines Servers**.
- Android: Unter „Privates DNS“ erscheint bei Problemen „Kein Zugriff auf privaten DNS-Server“.
- Firefox: `about:networking#dns` zeigt in der Spalte „TRR“ `true` für über DoH aufgelöste Namen.
