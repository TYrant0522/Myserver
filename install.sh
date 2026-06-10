#!/usr/bin/env bash
#
# singbox-vpn one-stop installer (v2 -- Cloudflare-CDN edition)
# -----------------------------------------------------------------------------
# Designed for a FRESH Ubuntu reinstall + a Cloudflare-managed domain.
#
# Deploys a headless sing-box (systemd, NO panel) with up to FOUR inbounds:
#   1. VLESS + WS + TLS   -> sits behind Cloudflare proxy (orange cloud).  *PRIMARY*
#                            Works even when your origin IP is GFW-blocked,
#                            because clients hit Cloudflare's IPs, not yours.
#   2. VLESS + Reality (TCP)   -> direct backup (useful from non-CN / new IP)
#   3. Hysteria2 (UDP)         -> direct backup
#   4. TUIC v5 (UDP)           -> direct backup
#
# With DOMAIN + CF_API_TOKEN it AUTOMATICALLY:
#   - issues a real Let's Encrypt cert via Cloudflare DNS-01 (acme.sh)
#   - creates/updates the orange-cloud A record via the Cloudflare API
#   - tries to set SSL mode = Full(strict)
#   - shares one real cert across WS / HY2 / TUIC (no insecure flag)
#
# Logging is hardened (warn level + logrotate copytruncate + journald cap) so it
# can never fill the disk again.
#
# Generates client configs: CF node link, direct node links, base64 subscription,
# a Clash/Mihomo config with smart routing (blackmatrix7 + SukkaW), and a
# sing-box client config.
#
# Run as root on fresh Ubuntu:
#   DOMAIN=vpn.example.com CF_API_TOKEN=xxxx ACME_EMAIL=you@example.com sudo -E bash install.sh
# -----------------------------------------------------------------------------

set -euo pipefail

# ============================ TUNABLES =======================================
SERVER_IP="${SERVER_IP:-}"                 # auto-detected if empty

# --- Cloudflare / domain (REQUIRED for the primary CF-fronted node) ----------
DOMAIN="${DOMAIN:-}"                        # e.g. vpn.example.com (single-level sub)
CF_API_TOKEN="${CF_API_TOKEN:-}"           # token: Zone.DNS=Edit + Zone.Zone=Read
ACME_EMAIL="${ACME_EMAIL:-}"               # defaults to admin@DOMAIN
CF_AUTO_DNS="${CF_AUTO_DNS:-1}"            # 1 = auto-create orange A record via API

# --- ports -------------------------------------------------------------------
# CF-fronted WS port MUST be a Cloudflare-supported HTTPS port:
#   443, 2053, 2083, 2087, 2096, 8443   (default 443 -- free on a fresh OS)
CF_WS_PORT="${CF_WS_PORT:-443}"
WS_PATH="${WS_PATH:-/cfvpn}"               # must start with /
VLESS_REALITY_PORT="${VLESS_REALITY_PORT:-8443}"   # TCP, direct backup
HY2_PORT="${HY2_PORT:-8444}"               # UDP, direct backup
TUIC_PORT="${TUIC_PORT:-8445}"             # UDP, direct backup
REALITY_DEST="${REALITY_DEST:-www.microsoft.com}"
REALITY_DEST_PORT="${REALITY_DEST_PORT:-443}"

# --- feature switches --------------------------------------------------------
ENABLE_CF="${ENABLE_CF:-auto}"             # auto = on iff DOMAIN+token present
ENABLE_DIRECT="${ENABLE_DIRECT:-1}"        # 1 = also deploy Reality/HY2/TUIC

TAG="${TAG:-MyVPN}"
SB_VERSION="${SB_VERSION:-}"               # empty = latest

# --- layout ------------------------------------------------------------------
SB_DIR="/etc/singbox-vpn"
SB_BIN="/usr/local/bin/sing-box"
SB_SVC="singbox-vpn"
OUT_DIR="${OUT_DIR:-/root/singbox-vpn-clients}"
LOG="/var/log/${SB_SVC}.log"
# =============================================================================

c_red(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_cyn(){ printf '\033[36m%s\033[0m\n' "$*"; }
die(){ c_red "ERROR: $*" >&2; exit 1; }
warn(){ c_ylw "WARN: $*"; }
step(){ printf '\n'; c_cyn "==> $*"; }

[ "$(id -u)" = "0" ] || die "Run as root:  sudo bash $0"

# ---------------------------------------------------------------------------
# 1. Dependencies (Ubuntu/Debian primary; dnf/yum tolerated)
# ---------------------------------------------------------------------------
step "Installing dependencies"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl jq openssl tar ca-certificates qrencode iproute2
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl jq openssl tar ca-certificates qrencode iproute || true
else
  die "Unsupported distro (expected Ubuntu/Debian)."
fi
command -v jq >/dev/null || die "jq failed to install."

# ---------------------------------------------------------------------------
# 2. Public IP + mode resolution
# ---------------------------------------------------------------------------
step "Resolving public IP and mode"
if [ -z "$SERVER_IP" ]; then
  for u in https://api.ipify.org https://ifconfig.me https://ipinfo.io/ip; do
    SERVER_IP="$(curl -4 -fsS --max-time 8 "$u" 2>/dev/null || true)"; [ -n "$SERVER_IP" ] && break
  done
fi
[ -n "$SERVER_IP" ] || die "Could not auto-detect public IP. Re-run with SERVER_IP=<ip>."
c_grn "Public IP: $SERVER_IP"

if [ "$ENABLE_CF" = "auto" ]; then
  if [ -n "$DOMAIN" ] && [ -n "$CF_API_TOKEN" ]; then ENABLE_CF=1; else ENABLE_CF=0; fi
fi
[ -z "$ACME_EMAIL" ] && ACME_EMAIL="admin@${DOMAIN:-example.com}"

if [ "$ENABLE_CF" = 1 ]; then
  c_grn "CF-fronted VLESS+WS: ON  (domain ${DOMAIN}, port ${CF_WS_PORT}, path ${WS_PATH})"
else
  warn "CF-fronted node OFF (no DOMAIN+CF_API_TOKEN)."
  warn "Your IP may be GFW-blocked; without the CF node you may not be able to connect from CN."
fi
[ "$ENABLE_DIRECT" = 1 ] && c_grn "Direct backups (Reality/HY2/TUIC): ON" || c_grn "Direct backups: OFF"
[ "$ENABLE_CF" = 1 ] || [ "$ENABLE_DIRECT" = 1 ] || die "Nothing to deploy: enable CF and/or DIRECT."

# ---------------------------------------------------------------------------
# 3. Install sing-box
# ---------------------------------------------------------------------------
step "Installing sing-box"
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l|armv7)  ARCH=armv7 ;;
  *) die "Unsupported CPU arch: $(uname -m)" ;;
esac
if [ -z "$SB_VERSION" ]; then
  SB_VERSION="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
fi
[ -n "$SB_VERSION" ] && [ "$SB_VERSION" != "null" ] || SB_VERSION="1.11.4"
c_grn "sing-box $SB_VERSION ($ARCH)"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
TB="sing-box-${SB_VERSION}-linux-${ARCH}.tar.gz"
curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${TB}" -o "$TMPD/$TB" \
  || die "sing-box download failed."
tar -xzf "$TMPD/$TB" -C "$TMPD"
install -m0755 "$TMPD/sing-box-${SB_VERSION}-linux-${ARCH}/sing-box" "$SB_BIN"
"$SB_BIN" version >/dev/null || die "sing-box binary not runnable."

# ---------------------------------------------------------------------------
# 4. Secrets
# ---------------------------------------------------------------------------
step "Generating keys / UUIDs / passwords"
mkdir -p "$SB_DIR" "$OUT_DIR"; chmod 700 "$OUT_DIR"
WS_UUID="$("$SB_BIN" generate uuid)"
VL_UUID="$("$SB_BIN" generate uuid)"
TUIC_UUID="$("$SB_BIN" generate uuid)"
SID="$("$SB_BIN" generate rand --hex 8)"
HY2_PW="$("$SB_BIN" generate rand --hex 16)"
TUIC_PW="$("$SB_BIN" generate rand --hex 16)"
RK="$("$SB_BIN" generate reality-keypair)"
PRIV="$(echo "$RK" | awk -F': *' '/PrivateKey/{print $2}')"
PBK="$(echo  "$RK" | awk -F': *' '/PublicKey/{print $2}')"
[ -n "$PRIV" ] && [ -n "$PBK" ] || die "reality-keypair parse failed."

# ---------------------------------------------------------------------------
# 5. Certificate
#    CF mode -> real Let's Encrypt cert via Cloudflare DNS-01 (acme.sh).
#    else    -> self-signed (HY2/TUIC clients use insecure).
# ---------------------------------------------------------------------------
step "Preparing TLS certificate"
HAVE_REAL_CERT=0
if [ "$ENABLE_CF" = 1 ] || { [ -n "$DOMAIN" ] && [ -n "$CF_API_TOKEN" ]; }; then
  c_grn "Issuing Let's Encrypt cert for ${DOMAIN} (Cloudflare DNS-01)"
  curl -fsSL https://get.acme.sh | sh -s email="${ACME_EMAIL}" >/dev/null 2>&1 || die "acme.sh install failed."
  ACMESH="/root/.acme.sh/acme.sh"; [ -x "$ACMESH" ] || die "acme.sh missing."
  export CF_Token="${CF_API_TOKEN}"
  "$ACMESH" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  # issue: exit 0 = issued, exit 2 = already valid / not due (both are fine on re-run)
  set +e; "$ACMESH" --issue --dns dns_cf -d "${DOMAIN}" --keylength ec-256; rc=$?; set -e
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] \
    || die "ACME issue failed (check CF token scope: Zone.DNS=Edit + Zone.Zone=Read, and DOMAIN)."
  # install-cert: the reloadcmd restarts ${SB_SVC}, which doesn't exist yet on the
  # first run (it's created later) -- that reload error is harmless, so tolerate it.
  # acme.sh records the reloadcmd for future renewals (when the unit exists).
  "$ACMESH" --install-cert -d "${DOMAIN}" --ecc \
    --key-file "${SB_DIR}/key.pem" --fullchain-file "${SB_DIR}/cert.pem" \
    --reloadcmd "systemctl restart ${SB_SVC}" || true
  [ -s "${SB_DIR}/cert.pem" ] && [ -s "${SB_DIR}/key.pem" ] \
    || die "cert files missing after install-cert."
  chmod 600 "${SB_DIR}/key.pem"; HAVE_REAL_CERT=1
  c_grn "Real cert installed; auto-renew via acme.sh cron."
else
  openssl ecparam -genkey -name prime256v1 -out "$SB_DIR/key.pem" >/dev/null 2>&1
  openssl req -new -x509 -days 3650 -key "$SB_DIR/key.pem" -out "$SB_DIR/cert.pem" \
    -subj "/CN=bing.com" >/dev/null 2>&1
  chmod 600 "$SB_DIR/key.pem"
  c_ylw "Using self-signed cert (HY2/TUIC clients must enable insecure)."
fi

# ---------------------------------------------------------------------------
# 6. Cloudflare API: orange-cloud A record + SSL strict (best-effort)
# ---------------------------------------------------------------------------
if [ "$ENABLE_CF" = 1 ] && [ "$CF_AUTO_DNS" = 1 ]; then
  step "Cloudflare DNS: ensuring orange-cloud A record for ${DOMAIN}"
  cf_api(){ curl -fsS -X "$1" "https://api.cloudflare.com/client/v4$2" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
            ${3:+--data "$3"}; }
  ZJSON="$(cf_api GET "/zones?per_page=50" || true)"
  ZONE_NAME=""
  if [ -n "$ZJSON" ] && [ "$(echo "$ZJSON" | jq -r '.success')" = "true" ]; then
    for z in $(echo "$ZJSON" | jq -r '.result[].name'); do
      case "$DOMAIN" in *."$z"|"$z") [ ${#z} -gt ${#ZONE_NAME} ] && ZONE_NAME="$z" ;; esac
    done
  fi
  if [ -n "$ZONE_NAME" ]; then
    ZID="$(echo "$ZJSON" | jq -r --arg n "$ZONE_NAME" '.result[]|select(.name==$n)|.id')"
    DATA="$(jq -n --arg ip "$SERVER_IP" --arg name "$DOMAIN" '{type:"A",name:$name,content:$ip,proxied:true,ttl:1}')"
    RID="$(cf_api GET "/zones/${ZID}/dns_records?type=A&name=${DOMAIN}" | jq -r '.result[0].id // empty')"
    if [ -n "$RID" ]; then
      cf_api PUT "/zones/${ZID}/dns_records/${RID}" "$DATA" >/dev/null && c_grn "A record updated (proxied)."
    else
      cf_api POST "/zones/${ZID}/dns_records" "$DATA" >/dev/null && c_grn "A record created (proxied)."
    fi
    if cf_api PATCH "/zones/${ZID}/settings/ssl" '{"value":"strict"}' >/dev/null 2>&1; then
      c_grn "SSL mode set to Full(strict)."
    else
      warn "Could not set SSL mode via API (token lacks Zone.Settings=Edit)."
      warn "  -> Set it manually: Cloudflare ${ZONE_NAME} -> SSL/TLS -> Full (strict)."
    fi
  else
    warn "Could not find the Cloudflare zone for ${DOMAIN} via API."
    warn "  -> Create an A record '${DOMAIN}' -> ${SERVER_IP} with ORANGE cloud, and set SSL Full(strict)."
  fi
fi

# ---------------------------------------------------------------------------
# 7. Build sing-box server config (inbounds assembled conditionally)
# ---------------------------------------------------------------------------
step "Writing $SB_DIR/config.json"
INBOUNDS=()

if [ "$ENABLE_CF" = 1 ]; then
read -r -d '' IB_WS <<EOF || true
{
  "type": "vless", "tag": "vless-ws-in", "listen": "::", "listen_port": ${CF_WS_PORT},
  "users": [ { "uuid": "${WS_UUID}", "name": "cf" } ],
  "tls": { "enabled": true, "server_name": "${DOMAIN}",
           "certificate_path": "${SB_DIR}/cert.pem", "key_path": "${SB_DIR}/key.pem" },
  "transport": { "type": "ws", "path": "${WS_PATH}" }
}
EOF
INBOUNDS+=("$IB_WS")
fi

if [ "$ENABLE_DIRECT" = 1 ]; then
read -r -d '' IB_RE <<EOF || true
{
  "type": "vless", "tag": "vless-reality-in", "listen": "::", "listen_port": ${VLESS_REALITY_PORT},
  "users": [ { "uuid": "${VL_UUID}", "flow": "xtls-rprx-vision" } ],
  "tls": { "enabled": true, "server_name": "${REALITY_DEST}",
    "reality": { "enabled": true,
      "handshake": { "server": "${REALITY_DEST}", "server_port": ${REALITY_DEST_PORT} },
      "private_key": "${PRIV}", "short_id": [ "${SID}" ] } }
}
EOF
read -r -d '' IB_HY2 <<EOF || true
{
  "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": ${HY2_PORT},
  "users": [ { "password": "${HY2_PW}" } ],
  "tls": { "enabled": true, "alpn": [ "h3" ],
           "certificate_path": "${SB_DIR}/cert.pem", "key_path": "${SB_DIR}/key.pem" }
}
EOF
read -r -d '' IB_TUIC <<EOF || true
{
  "type": "tuic", "tag": "tuic-in", "listen": "::", "listen_port": ${TUIC_PORT},
  "users": [ { "uuid": "${TUIC_UUID}", "password": "${TUIC_PW}" } ],
  "congestion_control": "bbr",
  "tls": { "enabled": true, "alpn": [ "h3" ],
           "certificate_path": "${SB_DIR}/cert.pem", "key_path": "${SB_DIR}/key.pem" }
}
EOF
INBOUNDS+=("$IB_RE" "$IB_HY2" "$IB_TUIC")
fi

# join inbound snippets with commas
IB_JOINED="$(printf '%s,\n' "${INBOUNDS[@]}")"; IB_JOINED="${IB_JOINED%,*}"
cat > "$SB_DIR/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true, "output": "${LOG}" },
  "inbounds": [
${IB_JOINED}
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
"$SB_BIN" check -c "$SB_DIR/config.json" || die "sing-box config check failed."
c_grn "Config OK."

# ---------------------------------------------------------------------------
# 8. systemd + logging hardening (never fill the disk again)
# ---------------------------------------------------------------------------
step "Service + log hardening"
cat > "/etc/systemd/system/${SB_SVC}.service" <<EOF
[Unit]
Description=singbox-vpn (CF VLESS+WS + Reality/HY2/TUIC)
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${SB_BIN} run -c ${SB_DIR}/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
User=root

[Install]
WantedBy=multi-user.target
EOF

# logrotate for our log file (copytruncate => no need to signal sing-box)
cat > "/etc/logrotate.d/${SB_SVC}" <<EOF
${LOG} {
  weekly
  rotate 4
  maxsize 50M
  missingok
  notifempty
  compress
  copytruncate
}
EOF
# cap systemd journal so a flood can never eat the disk
sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=300M/' /etc/systemd/journald.conf 2>/dev/null || true
grep -q '^SystemMaxUse=' /etc/systemd/journald.conf 2>/dev/null || echo 'SystemMaxUse=300M' >> /etc/systemd/journald.conf
systemctl restart systemd-journald 2>/dev/null || true

systemctl daemon-reload
systemctl enable "${SB_SVC}" >/dev/null 2>&1 || true
systemctl restart "${SB_SVC}"; sleep 1
systemctl is-active --quiet "${SB_SVC}" || { journalctl -u "${SB_SVC}" -n 30 --no-pager; die "Service failed."; }
c_grn "Service ${SB_SVC} active; logging capped."

# ---------------------------------------------------------------------------
# 9. Time sync + BBR
# ---------------------------------------------------------------------------
step "Time sync + BBR"
timedatectl set-ntp true >/dev/null 2>&1 || true
if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-singbox-bbr.conf
  sysctl --system >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 10. Firewall
# ---------------------------------------------------------------------------
step "Firewall"
open_port(){ # $1=port $2=proto
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$1/$2" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="$1/$2" >/dev/null 2>&1 || true
  fi
}
[ "$ENABLE_CF" = 1 ]     && open_port "$CF_WS_PORT" tcp
if [ "$ENABLE_DIRECT" = 1 ]; then
  open_port "$VLESS_REALITY_PORT" tcp; open_port "$HY2_PORT" udp; open_port "$TUIC_PORT" udp
fi
command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 || true
c_ylw "If a CLOUD firewall is enabled at your provider, open the same ports there."

# ---------------------------------------------------------------------------
# 11. Client configs
# ---------------------------------------------------------------------------
step "Generating client configs into ${OUT_DIR}"

# direct HY2/TUIC: real cert -> connect by IP but SNI=DOMAIN (valid, no insecure);
#                  self-signed -> IP + insecure.
if [ "$HAVE_REAL_CERT" = 1 ]; then
  D_SNI="$DOMAIN"; D_SKIP="false"; D_INSEC="false"; D_HY2Q=""; D_TUICQ=""
else
  D_SNI="bing.com"; D_SKIP="true"; D_INSEC="true"; D_HY2Q="&insecure=1"; D_TUICQ="&allow_insecure=1"
fi

LINKS=(); CLASH_PROXIES=""; SB_OUT=""; NAMES=()
add_clash(){ CLASH_PROXIES+="$1"$'\n'; }
add_sbout(){ SB_OUT+="${SB_OUT:+,}"$'\n'"$1"; }

# ---- CF VLESS+WS node (primary) ----
if [ "$ENABLE_CF" = 1 ]; then
  N="${TAG}-CF"; NAMES+=("$N")
  WSP_ENC="$(printf '%s' "$WS_PATH" | sed 's,/,%2F,g')"
  LINKS+=("vless://${WS_UUID}@${DOMAIN}:${CF_WS_PORT}?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WSP_ENC}#${N}")
  add_clash "  - name: \"${N}\"
    type: vless
    server: ${DOMAIN}
    port: ${CF_WS_PORT}
    uuid: ${WS_UUID}
    udp: true
    tls: true
    servername: ${DOMAIN}
    network: ws
    ws-opts:
      path: ${WS_PATH}
      headers:
        Host: ${DOMAIN}"
  add_sbout "    { \"type\": \"vless\", \"tag\": \"${N}\", \"server\": \"${DOMAIN}\", \"server_port\": ${CF_WS_PORT}, \"uuid\": \"${WS_UUID}\", \"tls\": { \"enabled\": true, \"server_name\": \"${DOMAIN}\", \"utls\": { \"enabled\": true, \"fingerprint\": \"chrome\" } }, \"transport\": { \"type\": \"ws\", \"path\": \"${WS_PATH}\", \"headers\": { \"Host\": \"${DOMAIN}\" } } }"
fi

# ---- direct nodes ----
if [ "$ENABLE_DIRECT" = 1 ]; then
  # Reality
  N="${TAG}-Reality"; NAMES+=("$N")
  LINKS+=("vless://${VL_UUID}@${SERVER_IP}:${VLESS_REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DEST}&fp=chrome&pbk=${PBK}&sid=${SID}&type=tcp#${N}")
  add_clash "  - name: \"${N}\"
    type: vless
    server: ${SERVER_IP}
    port: ${VLESS_REALITY_PORT}
    uuid: ${VL_UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${REALITY_DEST}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PBK}
      short-id: ${SID}"
  add_sbout "    { \"type\": \"vless\", \"tag\": \"${N}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${VLESS_REALITY_PORT}, \"uuid\": \"${VL_UUID}\", \"flow\": \"xtls-rprx-vision\", \"tls\": { \"enabled\": true, \"server_name\": \"${REALITY_DEST}\", \"utls\": { \"enabled\": true, \"fingerprint\": \"chrome\" }, \"reality\": { \"enabled\": true, \"public_key\": \"${PBK}\", \"short_id\": \"${SID}\" } } }"

  # Hysteria2
  N="${TAG}-HY2"; NAMES+=("$N")
  LINKS+=("hysteria2://${HY2_PW}@${SERVER_IP}:${HY2_PORT}?sni=${D_SNI}${D_HY2Q}#${N}")
  add_clash "  - name: \"${N}\"
    type: hysteria2
    server: ${SERVER_IP}
    port: ${HY2_PORT}
    password: ${HY2_PW}
    sni: ${D_SNI}
    skip-cert-verify: ${D_SKIP}
    alpn:
      - h3"
  add_sbout "    { \"type\": \"hysteria2\", \"tag\": \"${N}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${HY2_PORT}, \"password\": \"${HY2_PW}\", \"tls\": { \"enabled\": true, \"server_name\": \"${D_SNI}\", \"insecure\": ${D_INSEC}, \"alpn\": [ \"h3\" ] } }"

  # TUIC
  N="${TAG}-TUIC"; NAMES+=("$N")
  LINKS+=("tuic://${TUIC_UUID}:${TUIC_PW}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&sni=${D_SNI}${D_TUICQ}#${N}")
  add_clash "  - name: \"${N}\"
    type: tuic
    server: ${SERVER_IP}
    port: ${TUIC_PORT}
    uuid: ${TUIC_UUID}
    password: ${TUIC_PW}
    sni: ${D_SNI}
    alpn:
      - h3
    skip-cert-verify: ${D_SKIP}
    congestion-controller: bbr
    udp-relay-mode: native"
  add_sbout "    { \"type\": \"tuic\", \"tag\": \"${N}\", \"server\": \"${SERVER_IP}\", \"server_port\": ${TUIC_PORT}, \"uuid\": \"${TUIC_UUID}\", \"password\": \"${TUIC_PW}\", \"congestion_control\": \"bbr\", \"tls\": { \"enabled\": true, \"server_name\": \"${D_SNI}\", \"insecure\": ${D_INSEC}, \"alpn\": [ \"h3\" ] } }"
fi

# links.txt + base64 subscription
printf '%s\n' "${LINKS[@]}" > "$OUT_DIR/links.txt"
printf '%s\n' "${LINKS[@]}" | base64 -w0 > "$OUT_DIR/subscription.txt"

# proxy-group member list (CF node is first => preferred default)
GROUP_MEMBERS=""; for n in "${NAMES[@]}"; do GROUP_MEMBERS+="      - \"${n}\""$'\n'; done

# ---- Clash / Mihomo (smart routing: blackmatrix7 + SukkaW) ----
cat > "$OUT_DIR/clash.yaml" <<EOF
# Mihomo / Clash.Meta -- generated by singbox-vpn. Primary node: ${TAG}-CF (via Cloudflare).
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false
external-controller: 127.0.0.1:9090
geodata-mode: true

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver: [ https://doh.pub/dns-query, https://dns.alidns.com/dns-query ]
  fallback: [ https://1.1.1.1/dns-query, https://dns.google/dns-query ]
  fallback-filter: { geoip: true, geoip-code: CN }

proxies:
${CLASH_PROXIES}
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Auto
${GROUP_MEMBERS}  - name: Auto
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
${GROUP_MEMBERS}
rule-providers:
  sukka-reject:
    type: http
    behavior: domain
    format: text
    url: "https://ruleset.skk.moe/Clash/domainset/reject.txt"
    path: ./rules/sukka-reject.txt
    interval: 43200
  bm7-ads:
    type: http
    behavior: classical
    format: yaml
    url: "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Advertising/Advertising.yaml"
    path: ./rules/bm7-ads.yaml
    interval: 86400
  bm7-global:
    type: http
    behavior: classical
    format: yaml
    url: "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Global/Global.yaml"
    path: ./rules/bm7-global.yaml
    interval: 86400
  bm7-chinamax:
    type: http
    behavior: classical
    format: yaml
    url: "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMax/ChinaMax.yaml"
    path: ./rules/bm7-chinamax.yaml
    interval: 86400

rules:
  - DOMAIN-SUFFIX,lan,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - RULE-SET,sukka-reject,REJECT
  - RULE-SET,bm7-ads,REJECT
  - RULE-SET,bm7-global,Proxy
  - RULE-SET,bm7-chinamax,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
EOF

# ---- sing-box client ----
DEFAULT_NODE="${NAMES[0]}"
cat > "$OUT_DIR/sing-box-client.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "remote", "address": "tls://8.8.8.8", "detour": "Proxy" },
      { "tag": "local",  "address": "223.5.5.5", "detour": "direct" }
    ],
    "rules": [ { "rule_set": "geosite-cn", "server": "local" } ],
    "final": "remote", "strategy": "ipv4_only"
  },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "address": [ "172.18.0.1/30" ],
      "auto_route": true, "strict_route": true, "stack": "mixed" }
  ],
  "outbounds": [
${SB_OUT},
    { "type": "selector", "tag": "Proxy", "outbounds": [ "Auto"$(printf ', "%s"' "${NAMES[@]}") ], "default": "Auto" },
    { "type": "urltest", "tag": "Auto", "outbounds": [ $(printf '"%s",' "${NAMES[@]}" | sed 's/,$//') ],
      "url": "http://www.gstatic.com/generate_204", "interval": "5m" },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "Proxy",
    "rule_set": [
      { "type": "remote", "tag": "geosite-ads", "format": "binary", "download_detour": "Proxy",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/category-ads-all.srs" },
      { "type": "remote", "tag": "geosite-cn", "format": "binary", "download_detour": "Proxy",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/cn.srs" },
      { "type": "remote", "tag": "geoip-cn", "format": "binary", "download_detour": "Proxy",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/cn.srs" }
    ],
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" },
      { "rule_set": "geosite-ads", "action": "reject" },
      { "rule_set": [ "geoip-cn", "geosite-cn" ], "outbound": "direct" }
    ]
  }
}
EOF

# ---- credentials ----
cat > "$OUT_DIR/credentials.env" <<EOF
SERVER_IP=${SERVER_IP}
TAG=${TAG}
DOMAIN=${DOMAIN}
ENABLE_CF=${ENABLE_CF}
ENABLE_DIRECT=${ENABLE_DIRECT}
HAVE_REAL_CERT=${HAVE_REAL_CERT}
CF_WS_PORT=${CF_WS_PORT}
WS_PATH=${WS_PATH}
WS_UUID=${WS_UUID}
VLESS_REALITY_PORT=${VLESS_REALITY_PORT}
VLESS_UUID=${VL_UUID}
REALITY_PUBLIC_KEY=${PBK}
REALITY_PRIVATE_KEY=${PRIV}
REALITY_SHORT_ID=${SID}
REALITY_DEST=${REALITY_DEST}
HY2_PORT=${HY2_PORT}
HY2_PASSWORD=${HY2_PW}
TUIC_PORT=${TUIC_PORT}
TUIC_UUID=${TUIC_UUID}
TUIC_PASSWORD=${TUIC_PW}
EOF
chmod 600 "$OUT_DIR/credentials.env"

# validate generated sing-box client config too
"$SB_BIN" check -c "$OUT_DIR/sing-box-client.json" >/dev/null 2>&1 \
  && c_grn "sing-box client config validated." \
  || warn "sing-box client config didn't validate (client version differences possible)."

# ---------------------------------------------------------------------------
# 12. Summary
# ---------------------------------------------------------------------------
step "DONE"
c_grn "Client files: ${OUT_DIR}"
echo "    clash.yaml / subscription.txt / sing-box-client.json / links.txt / credentials.env"
echo
c_ylw "Share links:"; printf '  %s\n' "${LINKS[@]}"
echo
if command -v qrencode >/dev/null 2>&1; then
  for L in "${LINKS[@]}"; do echo; c_cyn "QR: ${L##*#}"; qrencode -t ANSIUTF8 "$L"; done
fi
echo
if [ "$ENABLE_CF" = 1 ]; then
  c_cyn "Cloudflare checklist (must be true for the CF node to work):"
  echo "  [*] A record ${DOMAIN} -> ${SERVER_IP}, ORANGE cloud (proxied)"
  echo "  [*] SSL/TLS mode = Full (strict)"
  echo "  [*] client connects to ${DOMAIN}:${CF_WS_PORT}  (resolves to a Cloudflare IP)"
fi
echo
c_cyn "Pull configs locally:  scp root@${SERVER_IP}:${OUT_DIR}/clash.yaml ."
c_cyn "Manage:  systemctl status ${SB_SVC} | journalctl -u ${SB_SVC} -f | tail -f ${LOG}"
