#!/usr/bin/env bash
# traffic-collector: pull mobile data usage from RUT routers through Orange Pi tunnels.
# Runs on the SSH bastion (Reckon VPS). Hops: bastion → Orange Pi → router.
#
# Usage:
#   ./mdcollect.sh [-m mapping.txt] [-o outfile] [-a] [hostname ...]
set -euo pipefail

# --- config ---------------------------------------------------------------
RECKEY="${RECKEY:-/root/.ssh/reckon}"
RECKEY_PASS="${RECKEY_PASS:?set RECKEY_PASS env var with the reckon key passphrase}"
MAPPING_FILE="${MAPPING_FILE:-}"
OUTFILE="${OUTFILE:-}"
ROUTER_IP="${ROUTER_IP:-172.29.1.1}"
ORANGEPI_USER="${ORANGEPI_USER:-orangepi}"

# --- arg parsing ----------------------------------------------------------
declare -a HOSTS=()
AUTO_DISCOVER=0
while [ $# -gt 0 ]; do
	case "$1" in
	-m)
		MAPPING_FILE="$2"
		shift 2
		;;
	-o)
		OUTFILE="$2"
		shift 2
		;;
	-a | --all)
		AUTO_DISCOVER=1
		shift
		;;
	*)
		HOSTS+=("$1")
		shift
		;;
	esac
done

# --- helpers --------------------------------------------------------------
CYPHER="0b1gsh0wes74n04r"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*" >&2; }

sha384_hex() {
	if command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha384 | awk '{print $NF}'
	elif command -v sha384sum >/dev/null 2>&1; then
		sha384sum | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 384 | awk '{print $1}'
	else
		log "FATAL: need openssl, sha384sum, or shasum" >&2
		exit 1
	fi
}

derive_password() {
	_ssid="$1"
	_cy="$CYPHER"
	_hex="$(
		while [ -n "$_ssid" ] && [ -n "$_cy" ]; do
			_sc="${_ssid%"${_ssid#?}"}"
			_ssid="${_ssid#?}"
			_cc="${_cy%"${_cy#?}"}"
			_cy="${_cy#?}"
			_sv="$(printf '%d' "'$_sc")"
			_cv="$(printf '%d' "'$_cc")"
			_xor=$((_sv ^ _cv))
			printf "\\$(printf '%03o' "$_xor")"
		done | sha384_hex
	)" || return 1
	printf '%s' "$_hex" | cut -c5-13
}

lookup_ssid() {
	local host="$1" base="${1%-bd}"
	[ -n "${MAPPING_FILE:-}" ] || return 1
	[ -f "$MAPPING_FILE" ] || return 1
	for key in "$host" "$base"; do
		local val
		val=$(grep "^${key}=" "$MAPPING_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
		[ -n "$val" ] && {
			echo "$val"
			return 0
		}
	done
	return 1
}

# Single SSH hop: Reckon VPS → Orange Pi → (one sshpass) → Router → JSON line
pull_router() {
	local host="$1" root_pass="$2" ssid="$3"

	sshpass -P 'Enter passphrase for key' -p "$RECKEY_PASS" \
		ssh -i "$RECKEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
		"${ORANGEPI_USER}@${host}" \
		"HOSTNAME=${host} GATEWAY=${ROUTER_IP} ROOT_PASS=${root_pass} SSID=${ssid} sh -s" 2>/dev/null <<'REMOTE'

# One SSH to the router that returns eval-safe key=value lines.
router_data=$(sshpass -p "$ROOT_PASS" ssh \
  -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  -o KexAlgorithms=+diffie-hellman-group14-sha256 \
  -o HostKeyAlgorithms=+ssh-rsa,ssh-ed25519 \
  "root@$GATEWAY" \
  "sh -s" 2>/dev/null <<'ROUTER'
mac=$(cat /sys/class/net/br-lan/address 2>/dev/null || ip link show br-lan 2>/dev/null | grep ether | awk '{print $2}' || echo '')

mdm_json=$(gsmctl -E 2>/dev/null || echo '{}')
usb_id=$(echo "$mdm_json" | sed -n 's/.*"usb_id": *"\([^"]*\)".*/\1/p' || echo '')
hw_type=$(echo "$mdm_json" | sed -n 's/.*"type": *"\([^"]*\)".*/\1/p' || echo '')
case "$hw_type" in
  gobinet) dev=qmimux0 ;;
  rmnet)   dev=rmnet_mhi0 ;;
  *)       dev=qmimux0 ;;
esac
[ -z "$usb_id" ] && usb_id="1-1"
iface=mob1s1a1
sim=1

for p in day week month; do
  r=$(ubus call mdcollect get "{\"period\":\"$p\",\"sim\":$sim,\"modem\":\"$usb_id\",\"device\":\"$dev\",\"iface\":\"$iface\"}" 2>/dev/null || echo '{"rx":0,"tx":0}')
  echo "$p"'_rx='$(echo "$r" | sed -n 's/.*"rx": *\([0-9]*\).*/\1/p')
  echo "$p"'_tx='$(echo "$r" | sed -n 's/.*"tx": *\([0-9]*\).*/\1/p')
done

r=$(ubus call mdcollect get_raw_total "{\"from\":0,\"to\":2000000000,\"sim\":$sim,\"modem\":\"$usb_id\",\"device\":\"$dev\",\"iface\":\"$iface\"}" 2>/dev/null || echo '{"rx":0,"tx":0}')
echo 'total_rx='$(echo "$r" | sed -n 's/.*"rx": *\([0-9]*\).*/\1/p')
echo 'total_tx='$(echo "$r" | sed -n 's/.*"tx": *\([0-9]*\).*/\1/p')
echo 'mac='"$mac"
echo 'usb_id='"$usb_id"
ROUTER
)

eval "$router_data"

printf '{"host":"%s","ssid":"%s","mac":"%s","usage":{"day":{"rx":%s,"tx":%s},"week":{"rx":%s,"tx":%s},"month":{"rx":%s,"tx":%s},"total":{"rx":%s,"tx":%s}},"ts":"%s"}\n' \
  "$HOSTNAME" "$SSID" "$mac" \
  "${day_rx:-0}" "${day_tx:-0}" \
  "${week_rx:-0}" "${week_tx:-0}" \
  "${month_rx:-0}" "${month_tx:-0}" \
  "${total_rx:-0}" "${total_tx:-0}" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REMOTE
}

# --- main -----------------------------------------------------------------

if [ ${#HOSTS[@]} -eq 0 ]; then
	if [ "$AUTO_DISCOVER" -ne 1 ]; then
		log "No hosts given. Use -a/--all to auto-discover from SSH config, or pass hostnames."
		exit 1
	fi
	log "Auto-discovering hosts from /root/.ssh/config..."
	while read -r line; do
		case "$line" in
		Host*) for w in ${line#Host }; do HOSTS+=("$w"); done ;;
		esac
	done </root/.ssh/config
	declare -a filtered
	for h in "${HOSTS[@]}"; do
		[[ "$h" == *-bd || "$h" == *-BD || "$h" == "*" ]] && continue
		[[ "$h" =~ ^[a-z] ]] && filtered+=("$h")
	done
	HOSTS=("${filtered[@]}")
fi

log "START mapping=${MAPPING_FILE:-none} hosts=${#HOSTS[@]}"

online=0
for host in "${HOSTS[@]}"; do
	ssid=$(lookup_ssid "$host") || true
	if [ -z "$ssid" ] || [[ "$ssid" != bb-* ]]; then
		log "SKIP  $host — no bb-* SSID in mapping"
		continue
	fi

	log "PULL  $host ssid=$ssid"

	wifi_pass=$(derive_password "$ssid") || {
		log "WARN  $host — derivation failed"
		continue
	}
	root_pass="BB${wifi_pass}"

	line=$(pull_router "$host" "$root_pass" "$ssid") || {
		log "WARN  $host — pull failed"
		continue
	}

	if [ -n "$line" ]; then
		echo "$line"
		[ -n "${OUTFILE:-}" ] && echo "$line" >>"$OUTFILE"
		online=$((online + 1))
	fi
done

log "DONE online=$online total=${#HOSTS[@]}"
