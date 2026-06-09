#!/bin/bash
set -e

SHOW_LOGS="$(echo "${SHOW_LOGS:-false}" | tr '[:upper:]' '[:lower:]')"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

func_net_admin() {
    if ! iptables -L >/dev/null 2>&1; then
        log "[ERROR] Cannot use iptables — missing required permissions."
        log "[INFO] Fix: add --cap-add=NET_ADMIN --cap-add=NET_RAW --sysctl net.ipv4.ip_forward=1 to your docker run command"
        exit 1
    fi
}

func_start_client() {
    log "[INFO] Starting Psiphon tunnel core client..."
    pkill -f psiphon-tunnel-core-x86_64 || true

    PSIPHON_DATA="${PSIPHON_DATA:-/tmp/psiphon}"
    mkdir -p "$PSIPHON_DATA"
    chown -R psiphon:psiphon "$PSIPHON_DATA" 2>/dev/null || true

    if [ "$SHOW_LOGS" = "true" ]; then
        su -s /bin/bash psiphon -c \
            "/app/_psiphon/psiphon-tunnel-core-x86_64 -config /app/_psiphon/client.config" &
    else
        su -s /bin/bash psiphon -c \
            "/app/_psiphon/psiphon-tunnel-core-x86_64 -config /app/_psiphon/client.config >/dev/null 2>&1" &
    fi
    client_pid=$!
}

func_check_socks() {
    log "[INFO] Waiting for SOCKS5 proxy on 127.0.0.1:1080..."
    for i in $(seq 1 30); do
        if timeout 1 bash -c 'echo >/dev/tcp/127.0.0.1/1080' 2>/dev/null; then
            log "[OK] SOCKS5 proxy is ready"
            sleep 2
            return 0
        fi
        sleep 2
    done
    log "[FAIL] SOCKS5 proxy did not become ready in time"
    return 1
}

func_expose_psiphon() {
    log "[EXPOSE] Opening Psiphon SOCKS5 on 0.0.0.0:40001 for external access..."
    socat TCP-LISTEN:40001,fork,reuseaddr TCP:127.0.0.1:1080 &
    log "[OK] Psiphon SOCKS5 now available at 0.0.0.0:40001"
}

setup_redsocks() {
    cat > /etc/redsocks.conf <<EOF
base {
    log_debug = off;
    log_info = on;
    log = "stderr";
    daemon = off;
    redirector = iptables;
}
redsocks {
    local_ip = 127.0.0.1;
    local_port = 50000;
    ip = 127.0.0.1;
    port = 1080;
    type = socks5;
}
EOF
    log "[OK] Redsocks configuration saved to /etc/redsocks.conf"
}

setup_iptables() {
    iptables -t nat -F
    iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 -j RETURN
    iptables -t nat -A OUTPUT -p tcp --dport 53 -j RETURN
    iptables -t nat -A OUTPUT -p tcp --dport 50000 -j RETURN
    iptables -t nat -A OUTPUT -p tcp --dport 1080 -j RETURN
    iptables -t nat -A OUTPUT -p tcp --dport 8080 -j RETURN
    iptables -t nat -A OUTPUT -p udp -d 127.0.0.1 -j RETURN
    iptables -t nat -A OUTPUT -p udp --dport 53 -j RETURN
    iptables -t nat -A OUTPUT -p udp --dport 50000 -j RETURN
    # The tunnel-core client's own outbound connections to Psiphon servers
    # must NOT be redirected back to redsocks or we create a circular
    # dependency: client→server → iptables→redsocks→client→…
    # Using --uid-owner (dedicated 'psiphon' user) to bypass.
    iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner psiphon -j RETURN 2>/dev/null || \
    log "[WARN] Could not add --uid-owner bypass for user 'psiphon' (iptables owner module may be missing)"
    iptables -t nat -A OUTPUT -p tcp -j REDIRECT --to-ports 50000
    log "[OK] iptables rules applied — all outbound traffic will go through Psiphon"
}

func_set_proxy() {
    log "[START] Setting up full proxy stack (tunnel-core + Redsocks + iptables)..."
    func_start_client
    func_check_socks
    func_expose_psiphon
    setup_redsocks
    setup_iptables
    if [ "$SHOW_LOGS" = "true" ]; then
        redsocks -c /etc/redsocks.conf &
    else
        redsocks -c /etc/redsocks.conf >/dev/null 2>&1 &
    fi
    redsocks_pid=$!
    sleep 5
    checker=$(printf "%s\n" $CHECKERS | shuf -n1)
    resp=$(curl -L --max-redirs 10 -s --max-time 30 "https://$checker" || true)
    if [ -n "$resp" ]; then
        log "[OK] Global proxy is working! Your IP: $resp (checked via $checker)"
        touch /tmp/redsocks.ready
        return 0
    else
        log "[FAIL] Global proxy test failed — no internet through the proxy"
        return 1
    fi
}

func_global_monitor() {
    while true; do
        log "[RESTART] Shutting down old processes..."
        iptables -t nat -F 2>/dev/null || true
        pkill -f psiphon-tunnel-core-x86_64 || true
        pkill -f redsocks || true
        pkill -f socat || true
        rm -f /tmp/redsocks.ready || true
        func_set_proxy || { sleep 60; continue; }
        proxy_fail_count=0
        while true; do
            sleep 180
            checker=$(printf "%s\n" $CHECKERS | shuf -n1)
            resp=$(curl -L --max-redirs 10 -s --max-time 30 "https://$checker" 2>/dev/null | tr -d '\n\r' || true)
            if [ -n "$resp" ]; then
                log "[OK] Internet check passed — your IP: $resp (via $checker)"
                proxy_fail_count=0
            else
                proxy_fail_count=$((proxy_fail_count+1))
                log "[WARN] Internet check failed (${proxy_fail_count}/3 failures)"
            fi
            if [ $proxy_fail_count -ge 3 ]; then
                log "[RESTART] 3 internet checks failed — restarting the whole proxy stack..."
                break
            fi
        done
    done
}

CHECKERS="4.ipwho.de/ip
4.myip.is
6.ident.me
6.myip.is
a.ident.me
api.getpublicip.com/ip
api.ipify.org
api.iplocation.net/?cmd=get-ip
api.seeip.org
api64.ipify.org
checkip.amazonaws.com
checkip.ca
checkip.synology.com
dafuqismyip.com
ds-whoami.kag2d.com
eth0.me
httpbin.org/ip
icanhazip.com
ident.me
ifconfig.icu/ip
ifconfig.info
ifconfig.io
ifconfig.me/ip
inet-ip.info
ip-addr.es
ip-echo.ripe.net
ip.csis.dk
ip.guide
ip.im
ip.liquidweb.com
ip.me
ip.tyk.nu
ip6.me/api
ipaddress.ai
ipapi.co/ip
ipconfig.io
ipecho.net/ip
iphorse.com/json
ipinfo.io/ip
ipleak.net
ipquail.com
ipunicorn.com
ipv4.getpublicip.com/ip
ipv6.icanhazip.com
ipv6.ip.sb
ipseeker.io
json.myip.wtf
jsonip.com
l2.io/ip
moanmyip.com/simple
my.ip.fi
myexternalip.com/raw
myip.dk
myip.dnsomatic.com
myip.wtf/text
pub-ip.com
simplesniff.com/ip
sshmyip.com
telnetmyip.com
v4.ident.me
v6.ident.me
wgetip.com
whatismyip.akamai.com
whatismyip.help
wtfismyip.com/text
yourip.app/raw"

func_net_admin
func_global_monitor