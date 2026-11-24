#!/usr/bin/env bash
# dns-selftest.sh - Selbsttest fuer den Unbound-Resolver (DoT + DoH)
#
# Aufruf (als root, auf dem DNS-Server):
#   bash dns-selftest.sh dns.example.com
#
# Exit-Code: 0 = alle Pruefungen ok, 1 = mindestens ein Fehler, 2 = falscher Aufruf
#
# Hinweis: Ob Port 53 von AUSSEN geschlossen ist, kann nur ein Test von einem
# anderen Rechner zeigen (docs/06-tests.md). Verkehr vom Server an sich selbst
# laeuft ueber Loopback und umgeht die Firewall.

set -u

HOST="${1:-}"
if [ -z "$HOST" ]; then
    echo "Aufruf: $0 <dns-hostname>   (z.B. $0 dns.example.com)" >&2
    exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "Bitte als root ausfuehren (ss, ufw und unbound-control brauchen root)." >&2
    exit 2
fi

CA=/etc/ssl/certs/ca-certificates.crt
TLSOPT=(+tls-ca="$CA" +tls-hostname="$HOST")
DIG=(dig +time=5 +tries=1)
TLSDIR=/etc/unbound/tls
LEDIR="/etc/letsencrypt/live/$HOST"
PASS=0
FAIL=0

if [ -t 1 ]; then GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'; else GREEN=""; RED=""; RESET=""; fi
ok()  { printf '  %s[OK]%s     %s\n' "$GREEN" "$RESET" "$1"; PASS=$((PASS + 1)); }
bad() { printf '  %s[FEHLER]%s %s\n' "$RED" "$RESET" "$1"; FAIL=$((FAIL + 1)); }
# t "Beschreibung" befehl ...   -> OK, wenn der Befehl mit 0 endet
t() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

# dig-Ausgabe enthaelt Muster?   has <regex> <dig-Argumente...>
has() { local pat="$1"; shift; "${DIG[@]}" "$@" 2>/dev/null | grep -q -E "$pat"; }

# Unbound-Sockets als "proto adresse:port"
socks() { ss -Htulpn 2>/dev/null | grep '"unbound"' | awk '{print $1, $5}'; }

port53_local_only() {
    local a
    a=$(socks | awk '$2 ~ /:53$/ {print $2}')
    [ -n "$a" ] || return 1
    ! printf '%s\n' "$a" | grep -q -v -E '^(127\.0\.0\.1|\[::1\]):53$'
}
dot_tcp_only() {
    socks | grep -q -E '^tcp .*:853$' && ! socks | grep -q -E '^udp .*:853$'
}
doh_backend_local() {
    local a
    a=$(socks | awk '$2 ~ /:8053$/ {print $1, $2}')
    [ -n "$a" ] || return 1
    ! printf '%s\n' "$a" | grep -q -v -E '^tcp 127\.0\.0\.1:8053$'
}
http_404() {
    [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$HOST/")" = "404" ]
}
cert_valid_14d() {
    openssl x509 -checkend $((14 * 86400)) -noout -in "$TLSDIR/fullchain.pem"
}
cert_copy_current() {
    local a b
    a=$(openssl x509 -noout -fingerprint -sha256 -in "$TLSDIR/fullchain.pem" 2>/dev/null)
    b=$(openssl x509 -noout -fingerprint -sha256 -in "$LEDIR/cert.pem" 2>/dev/null)
    [ -n "$a" ] && [ "$a" = "$b" ]
}
key_perms() {
    [ "$(stat -c '%a %U:%G' "$TLSDIR/privkey.pem")" = "640 root:unbound" ]
}
hook_registered() {
    grep -q -E '^renew_hook *= */usr/local/sbin/unbound-tls-deploy' "/etc/letsencrypt/renewal/$HOST.conf"
}
opt_is() {
    [ "$(unbound-control get_option "$1" 2>/dev/null)" = "$2" ]
}
nginx_vhost_quiet() {
    local block
    block=$(nginx -T 2>/dev/null | awk -v h="server_name $HOST;" 'index($0, h) {f = 1} f {print} f && /^}/ {f = 0}')
    [ "$(printf '%s\n' "$block" | grep -c 'access_log off;')" -ge 2 ] &&
    [ "$(printf '%s\n' "$block" | grep -c 'error_log /dev/null;')" -ge 2 ]
}
ufw_853() {
    ufw status 2>/dev/null | grep -q -E '^853/tcp +ALLOW'
}
ufw_no_53() {
    ufw status 2>/dev/null | grep -q '^Status: active' &&
    ! ufw status 2>/dev/null | grep -q -E '^53(/(tcp|udp))?( \(v6\))? +ALLOW +Anywhere'
}

echo "Selbsttest fuer $HOST"
echo

echo "== Dienste =="
t "Unbound laeuft"                            systemctl is-active --quiet unbound
t "Unbound-Konfiguration fehlerfrei"          unbound-checkconf
t "nginx-Konfiguration fehlerfrei"            nginx -t

echo "== Ports =="
t "Port 53 nur auf 127.0.0.1 / ::1"           port53_local_only
t "DoT (853) nur TCP, kein UDP"               dot_tcp_only
t "DoH-Backend (8053) nur auf 127.0.0.1"      doh_backend_local

echo "== Resolver =="
t "DNSSEC gueltig: isc.org hat ad-Flag"       has 'flags:[^;]* ad[ ;]' @127.0.0.1 +dnssec isc.org A
t "DNSSEC kaputt: dnssec-failed.org abgelehnt" has 'status: SERVFAIL' @127.0.0.1 dnssec-failed.org A
t "QNAME-Minimierung aktiv"                   has 'HOORAY' @127.0.0.1 qnamemintest.internet.nl TXT
t "Version wird nicht verraten"               has 'status: REFUSED' @127.0.0.1 version.bind CH TXT
t "ANY-Anfragen werden nicht beantwortet"     has 'ANSWER: 0,' @127.0.0.1 example.com ANY

echo "== Verschluesselte Zugaenge =="
t "DoT mit gueltigem Zertifikat"              has 'status: NOERROR' +tls "${TLSOPT[@]}" @"$HOST" example.com A
t "DoH per POST mit gueltigem Zertifikat"     has 'status: NOERROR' +https "${TLSOPT[@]}" @"$HOST" example.com A
t "DoH per GET"                               has 'status: NOERROR' +https-get "${TLSOPT[@]}" @"$HOST" example.com AAAA
t "Andere Pfade liefern 404"                  http_404

echo "== Zertifikat =="
t "Noch mindestens 14 Tage gueltig"           cert_valid_14d
t "Unbound-Kopie = aktuelles certbot-Zertifikat" cert_copy_current
t "Schluesselrechte 640 root:unbound"         key_perms
t "Deploy-Hook bei certbot eingetragen"       hook_registered

echo "== Logging und Firewall =="
t "Unbound loggt keine Anfragen"              opt_is log-queries no
t "Unbound loggt keine Antworten"             opt_is log-replies no
t "nginx-vHost ohne Access- und Error-Log"    nginx_vhost_quiet
t "UFW erlaubt 853/tcp"                       ufw_853
t "UFW aktiv und Port 53 NICHT freigegeben"   ufw_no_53

echo
echo "Ergebnis: $PASS ok, $FAIL Fehler"
echo "Nicht vom Server aus pruefbar: Port 53 von aussen -> docs/06-tests.md"
[ "$FAIL" -eq 0 ]
