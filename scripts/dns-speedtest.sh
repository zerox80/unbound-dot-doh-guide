#!/usr/bin/env bash
# dns-speedtest.sh - Zeigt, an welcher Stelle der Resolver Zeit verliert
#
# Aufruf (als root, auf dem DNS-Server):
#   bash dns-speedtest.sh dns.example.com [domain ...]
#
# Ohne eigene Domains (ohne "www.", z.B. example.org) misst das Skript eine feste
# Liste bekannter Websites.
#
# Das Skript aendert keine Einstellung und schreibt nichts mit. Fuer die Kalt-Messung
# wirft es nur die Testdomains aus dem Cache; die Messung fuellt sie sofort wieder.
#
# Exit-Code: 0 = gemessen, 2 = falscher Aufruf. Die Grenzwerte in den Hinweisen
# sind Richtwerte, keine harten Pruefungen (dafuer gibt es dns-selftest.sh).
#
# Nicht messbar vom Server aus: der Weg Geraet <-> Server. Dafuer gibt das Skript
# am Ende einen Befehl aus, der auf dem Geraet laeuft (docs/08-fehlersuche.md).

set -u

HOST="${1:-}"
if [ -z "$HOST" ]; then
    echo "Aufruf: $0 <dns-hostname> [domain ...]   (z.B. $0 dns.example.com)" >&2
    exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "Bitte als root ausfuehren (unbound-control braucht root)." >&2
    exit 2
fi
shift
if [ "$#" -gt 0 ]; then
    DOMAINS=("$@")
else
    DOMAINS=(wikipedia.org github.com heise.de debian.org mozilla.org
             cloudflare.com microsoft.com apple.com amazon.de isc.org)
fi

CA=/etc/ssl/certs/ca-certificates.crt
TLSOPT=(+tls-ca="$CA" +tls-hostname="$HOST")
DIG=(dig +time=5 +tries=1)
# Beispielanfrage aus RFC 8484 (www.example.com A, Base64url)
DOH_URL="https://$HOST/dns-query?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB"
HINTS=()

hint() { HINTS+=("$1"); }
row()  { printf '  %-44s %s\n' "$1" "$2"; }
opt()  { unbound-control get_option "$1" 2>/dev/null; }

# Antwortzeit einer dig-Anfrage in ms, "-" bei Fehler/Timeout/SERVFAIL
ms_dig() {
    local out
    out=$("${DIG[@]}" "$@" 2>/dev/null) || { echo -; return; }
    grep -q -E 'status: (NOERROR|NXDOMAIN)' <<<"$out" || { echo -; return; }
    awk '/Query time:/ {print $4; f = 1} END {if (!f) print "-"}' <<<"$out"
}
# Median einer Zahlenliste von stdin ("-" wird ignoriert, leere Liste -> "-")
median() {
    grep -v '^-$' | sort -n | awk '{a[NR] = $1} END {if (NR) print a[int((NR + 1) / 2)]; else print "-"}'
}
maximum() {
    grep -v '^-$' | sort -n | awk 'END {if (NR) print $1; else print "-"}'
}
# Ist $1 eine Zahl groesser als $2?
gt() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a ~ /^[0-9.e+-]+$/ && a + 0 > b + 0)}'; }

echo "Geschwindigkeitstest fuer $HOST"
echo

# ---------------------------------------------------------------- Einstellungen
echo "== Einstellungen, die das Tempo bestimmen =="
SECT=$(opt serve-expired-client-timeout); PREF4=$(opt prefer-ip4)
row "serve-expired / -client-timeout" "$(opt serve-expired) / ${SECT:-?} ms   (schnell: yes / 0)"
row "prefetch"                        "$(opt prefetch)   (schnell: yes)"
row "prefer-ip4"                      "${PREF4:-?}"
row "edns-tcp-keepalive / -timeout"   "$(opt edns-tcp-keepalive) / $(opt edns-tcp-keepalive-timeout) ms   (Leerlauf, bis Unbound trennt)"
row "num-threads"                     "$(opt num-threads)"
if [ "$(opt serve-expired)" != "yes" ] || [ "${SECT:-1}" != "0" ]; then
    hint "Abgelaufene Cache-Eintraege werden nicht sofort beantwortet. Bei wenigen Nutzern ist das die groesste Bremse: serve-expired: yes und serve-expired-client-timeout: 0 setzen."
fi
echo

# ---------------------------------------------------------------- 1. Resolver
echo "== 1. Resolver selbst (127.0.0.1:53, ohne Verschluesselung) =="
echo "  kalt  = Domain war nicht im Cache: volle Rekursion ab der TLD"
echo "  Cache = dieselbe Anfrage direkt danach"
printf '  %-30s %10s %10s\n' "Name" "kalt" "Cache"
# flush_zone markiert alles unterhalb der Domain nur als abgelaufen (inkl. DNSSEC-Schluessel).
# Mit serve-expired kaeme die Antwort dann trotzdem sofort aus dem Cache, deshalb werden
# die beiden abgefragten Namen zusaetzlich mit "flush" wirklich entfernt.
cold_flush() {
    unbound-control flush_zone "$1" >/dev/null 2>&1
    unbound-control flush "$1" >/dev/null 2>&1
    unbound-control flush "www.$1" >/dev/null 2>&1
}
COLD=(); WARM=(); NFAIL=0
for d in "${DOMAINS[@]}"; do
    cold_flush "$d"
    c=$(ms_dig @127.0.0.1 "www.$d" A)
    w=$(ms_dig @127.0.0.1 "www.$d" A)
    COLD+=("$c"); WARM+=("$w")
    if [ "$c" = "-" ]; then NFAIL=$((NFAIL + 1)); c="FEHLER"; else c="$c ms"; fi
    [ "$w" = "-" ] || w="$w ms"
    printf '  %-30s %10s %10s\n' "www.$d" "$c" "$w"
done
COLD_MED=$(printf '%s\n' "${COLD[@]}" | median)
COLD_MAX=$(printf '%s\n' "${COLD[@]}" | maximum)
WARM_MAX=$(printf '%s\n' "${WARM[@]}" | maximum)
row "kalt:  Median / Maximum" "$COLD_MED / $COLD_MAX ms   (ueblich: Median unter 150 ms)"
row "Cache: Maximum"          "$WARM_MAX ms   (ueblich: 0-1 ms)"
if [ "$NFAIL" -gt 0 ]; then
    hint "$NFAIL von ${#DOMAINS[@]} Testdomains liessen sich gar nicht aufloesen (Timeout oder SERVFAIL). Abschnitt 2 pruefen."
fi
if gt "$COLD_MED" 300; then
    hint "Kalte Anfragen sind langsam (Median $COLD_MED ms). Die Zeit geht auf dem Weg zu den fremden Nameservern verloren: Abschnitt 2 pruefen, sonst Paketverlust zum Hoster-Uplink (mtr -u -P 53 193.0.14.129)."
fi
if gt "$WARM_MAX" 20; then
    hint "Selbst Antworten aus dem Cache brauchen bis zu $WARM_MAX ms. Der Server ist ausgelastet (top, CPU-Steal) oder Unbound haengt."
fi
echo

# ---------------------------------------------------------------- 2. Weg nach aussen
echo "== 2. Weg zu fremden Nameservern (Root-Server k und f) =="
# Erste Antwortzeit aus einer Liste von Servern, "-" wenn keiner antwortet
root_ms() {
    local flags=("$1") s t; shift
    for s in "$@"; do
        t=$(ms_dig +time=2 +norec "${flags[@]}" @"$s" . SOA)
        [ "$t" = "-" ] || { echo "$t"; return; }
    done
    echo -
}
U4=$(root_ms -4 193.0.14.129 192.5.5.241)
T4=$(root_ms +tcp 193.0.14.129 192.5.5.241)
U6=$(root_ms -6 2001:7fd::1 2001:500:2f::f)
if [ "$U4" = "-" ]; then
    row "IPv4 / UDP" "KEINE ANTWORT"
    hint "Der Server erreicht die Root-Server nicht ueber IPv4/UDP 53. Ausgehende Firewall-Regeln und den Hoster pruefen, ohne das kann Unbound nicht rekursiv aufloesen."
else
    row "IPv4 / UDP" "$U4 ms"
fi
if [ "$T4" = "-" ]; then
    row "IPv4 / TCP" "KEINE ANTWORT"
    hint "Ausgehendes TCP 53 ist gesperrt. Grosse (DNSSEC-)Antworten kommen dann nie an: erst Timeout, dann SERVFAIL. Ausgehende Firewall-Regeln pruefen."
else
    row "IPv4 / TCP" "$T4 ms   (enthaelt den TCP-Handshake)"
fi
if [ "$U6" != "-" ]; then
    row "IPv6 / UDP" "$U6 ms"
elif [ "$PREF4" = "yes" ] || [ "$(opt do-ip6)" = "no" ]; then
    row "IPv6 / UDP" "keine Antwort - egal, Unbound fragt ueber IPv4"
else
    row "IPv6 / UDP" "KEINE ANTWORT"
    hint "IPv6 nach aussen funktioniert nicht, Unbound versucht es aber trotzdem und wartet bei jedem IPv6-Nameserver auf einen Timeout. prefer-ip4: yes setzen."
fi
echo

# ---------------------------------------------------------------- 3. DoT / DoH
echo "== 3. Verschluesselte Zugaenge, gemessen auf dem Server (ohne Netzwerkweg) =="
"${DIG[@]}" @127.0.0.1 www.example.com A >/dev/null 2>&1     # Testnamen in den Cache holen
DOT=$(for _ in 1 2 3 4 5; do ms_dig +tls "${TLSOPT[@]}" @"$HOST" www.example.com A; done | median)
# curl: je Anfrage "HTTP-Code Sekunden"; mehrere URLs in einem Aufruf teilen sich eine Verbindung
doh() { curl -s -m 20 -H 'accept: application/dns-message' -w '%{http_code} %{time_total}\n' "$@" 2>/dev/null; }
to_ms() { awk '$1 == 200 {printf "%.0f\n", $2 * 1000}'; }
DOH_NEW=$(for _ in 1 2 3 4 5; do doh -o /dev/null "$DOH_URL"; done | to_ms | median)
REUSE=(); for _ in 1 2 3 4 5 6 7 8 9 10 11; do REUSE+=(-o /dev/null "$DOH_URL"); done
DOH_KEEP=$(doh "${REUSE[@]}" | tail -n +2 | to_ms | median)
row "DoT, neue Verbindung (TCP + TLS + Anfrage)" "$DOT ms"
row "DoH, neue Verbindung (TCP + TLS + Anfrage)" "$DOH_NEW ms"
row "DoH, bestehende Verbindung"                 "$DOH_KEEP ms"
if [ "$DOT" = "-" ] || [ "$DOH_NEW" = "-" ]; then
    hint "DoT oder DoH antwortet vom Server aus nicht. Erst den Selbsttest laufen lassen: bash scripts/dns-selftest.sh $HOST"
elif gt "$DOT" 100 || gt "$DOH_NEW" 100; then
    hint "Schon ohne Netzwerkweg dauert ein verschluesselter Verbindungsaufbau ueber 100 ms. Der Server ist ausgelastet (top, CPU-Steal beim Hoster)."
fi
echo "  Liegen diese Werte im niedrigen zweistelligen Bereich, bremst nicht der Server,"
echo "  sondern der Weg Geraet <-> Server (siehe Befehl am Ende) oder ein kalter Cache."
echo

# ---------------------------------------------------------------- 4. Statistik
echo "== 4. Statistik seit dem letzten Unbound-Start (anonyme Zaehler) =="
STATS=$(unbound-control stats_noreset 2>/dev/null)
st() { awk -F= -v k="$1" '$1 == k {print $2; f = 1} END {if (!f) print 0}' <<<"$STATS"; }
QUERIES=$(st total.num.queries); HITS=$(st total.num.cachehits)
HITPCT=$(awk -v h="$HITS" -v q="$QUERIES" 'BEGIN {if (q > 0) printf "%.0f", 100 * h / q; else print "-"}')
# Anteil der Rekursionen, die 0,5 s oder laenger gedauert haben
SLOWPCT=$(awk -F'[.=]' '/^histogram\./ {n += $NF; if ($2 + 0 > 0 || $3 + 0 >= 524288) s += $NF}
                        END {if (n > 0) printf "%.0f", 100 * s / n; else print "-"}' <<<"$STATS")
SERVFAILPCT=$(awk -F= '/^num\.answer\.rcode\./ {n += $2; if ($1 ~ /SERVFAIL$/) s = $2}
                       END {if (n > 0) printf "%.0f", 100 * s / n; else print "-"}' <<<"$STATS")
REC_MED=$(awk -v v="$(st total.recursion.time.median)" 'BEGIN {printf "%.0f", v * 1000}')
REC_AVG=$(awk -v v="$(st total.recursion.time.avg)" 'BEGIN {printf "%.0f", v * 1000}')
row "Laufzeit"                           "$(awk -v v="$(st time.up)" 'BEGIN {printf "%.1f h", v / 3600}')"
row "Anfragen / davon aus dem Cache"     "$QUERIES / $HITS ($HITPCT %)"
row "  davon abgelaufen, sofort bedient" "$(st total.num.expired)"
row "  im Voraus erneuert (prefetch)"    "$(st total.num.prefetch)"
row "Rekursion: Median / Mittel"         "$REC_MED / $REC_AVG ms"
row "Rekursionen ab 0,5 s"               "$SLOWPCT %"
row "Warteschlange uebergelaufen"        "$(st total.requestlist.exceeded)   (soll 0 sein)"
row "TCP-Plaetze belegt (jetzt)"         "$(st total.tcpusage)"
if grep -q '^num\.query\.tls=' <<<"$STATS"; then
    TLSQ=$(st num.query.tls)
    row "Anfragen ueber DoT"                 "$TLSQ, davon mit TLS-Wiederaufnahme: $(st num.query.tls.resume)"
    row "Anfragen ueber DoH + lokales TCP"   "$(( $(st num.query.tcp) - TLSQ ))"
    row "SERVFAIL-Anteil"                    "$SERVFAILPCT %   (ueblich: unter 2 %)"
    if gt "$SERVFAILPCT" 5; then
        hint "Auffaellig viele SERVFAIL-Antworten ($SERVFAILPCT %). Fremde Nameserver sind schlecht erreichbar (Abschnitt 2) oder DNSSEC schlaegt fehl (Uhrzeit des Servers pruefen: timedatectl)."
    fi
else
    row "Aufteilung DoT/DoH, SERVFAIL" "nur mit extended-statistics: yes"
fi
if gt "$QUERIES" 500; then
    if gt "$SLOWPCT" 15; then
        hint "$SLOWPCT % der Rekursionen dauern 0,5 s oder laenger. Das deutet auf Timeouts auf dem Weg zu fremden Nameservern hin (Abschnitt 2)."
    fi
    if [ "$HITPCT" != "-" ] && [ "$HITPCT" -lt 50 ]; then
        hint "Nur $HITPCT % der Anfragen kommen aus dem Cache. Kurz nach einem Neustart ist das normal; sonst ist der Nutzerkreis zu klein, um den Cache warm zu halten (serve-expired hilft, siehe oben)."
    fi
fi
if gt "$(st total.requestlist.exceeded)" 0; then
    hint "Die Warteschlange ist uebergelaufen: num-queries-per-thread und outgoing-range erhoehen (docs/07-betrieb-und-wartung.md)."
fi
echo

# ---------------------------------------------------------------- Ergebnis
echo "== Hinweise =="
if [ "${#HINTS[@]}" -eq 0 ]; then
    echo "  Auf dem Server ist nichts Auffaelliges zu sehen."
else
    for h in "${HINTS[@]}"; do printf '  - %s\n' "$h"; done
fi
echo
echo "Noch offen: der Weg Geraet <-> Server. Auf dem Geraet ausfuehren"
echo "(eine Zeile; Windows: in der PowerShell mit curl.exe und -o NUL):"
printf '%s\n' "  curl -s -o /dev/null -H 'accept: application/dns-message' -w 'TCP %{time_connect}s  TLS %{time_appconnect}s  gesamt %{time_total}s\n' '$DOH_URL'"
echo "TCP = eine Laufzeit Geraet -> Server -> Geraet. Ist schon dieser Wert hoch,"
echo "hilft keine Einstellung am Resolver (docs/08-fehlersuche.md)."
