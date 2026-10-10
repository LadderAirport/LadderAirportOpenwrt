#!/bin/sh
# Emit JSON snapshot of ladder-agent local status for LuCI.
# Does not print raw control tokens.
#
# Do not enable nounset (-u). OpenWrt /lib/functions.sh references unset
# IPKG_INSTROOT both while it is sourced and inside config_load. BusyBox ash
# then exits immediately (rc=2) and `|| true` never runs, so LuCI shows
# "Failed to read status" with empty output.
set -e

. /lib/functions.sh 2>/dev/null || true

json_escape() {
	# Escape for JSON string values (ash-safe-ish).
	printf '%s' "$1" | sed \
		-e 's/\\/\\\\/g' \
		-e 's/"/\\"/g' \
		-e 's/	/\\t/g' \
		-e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g'
}

mask_secret() {
	local v="$1"
	local n
	if [ -z "$v" ]; then
		echo ""
		return
	fi
	n=$(printf '%s' "$v" | wc -c)
	if [ "$n" -le 8 ]; then
		echo "***"
		return
	fi
	printf '%s***%s\n' "$(printf '%s' "$v" | cut -c1-4)" "$(printf '%s' "$v" | sed 's/.*\(....\)$/\1/')"
}

enabled="0"
panel_url=""
node_id=""
token=""
enroll_token=""
listen=""
data_dir="/var/lib/ladder-agent"
uplink="1"
uplink_serve_grpc="0"
uplink_ws="1"
report_address=""
log_stderr="1"

if [ -f /etc/config/ladder-agent ]; then
	config_load ladder-agent
	config_get_bool enabled main enabled 0
	config_get panel_url main panel_url ""
	config_get node_id main node_id ""
	config_get token main token ""
	config_get enroll_token main enroll_token ""
	config_get listen main listen "0.0.0.0:50051"
	config_get data_dir main data_dir "/var/lib/ladder-agent"
	config_get_bool uplink main uplink 1
	config_get_bool uplink_serve_grpc main uplink_serve_grpc 0
	config_get_bool uplink_ws main uplink_ws 1
	config_get report_address main report_address ""
	config_get_bool log_stderr main log_stderr 1
fi

running="0"
pid=""
if command -v pidof >/dev/null 2>&1; then
	pid="$(pidof ladder-agent 2>/dev/null || true)"
fi
if [ -n "$pid" ]; then
	running="1"
	# pidof may return multiple; keep first
	pid="$(printf '%s' "$pid" | awk '{print $1}')"
fi

version=""
if [ -x /usr/bin/ladder-agent ]; then
	version="$(/usr/bin/ladder-agent -version 2>/dev/null | head -n 1 || true)"
fi

init_enabled="0"
if [ -x /etc/init.d/ladder-agent ] && /etc/init.d/ladder-agent enabled 2>/dev/null; then
	init_enabled="1"
fi

has_config="0"
config_bytes="0"
inbound_count="0"
inbound_types=""
if [ -f "${data_dir}/current.json" ]; then
	has_config="1"
	config_bytes="$(wc -c < "${data_dir}/current.json" 2>/dev/null | tr -d ' ' || echo 0)"
	if command -v jsonfilter >/dev/null 2>&1; then
		inbound_types="$(jsonfilter -i "${data_dir}/current.json" -e '$.inbounds[*].type' 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
		if [ -n "$inbound_types" ]; then
			inbound_count="$(printf '%s' "$inbound_types" | awk -F',' '{print NF}')"
		fi
	fi
fi

has_frps="0"
[ -f "${data_dir}/frps-current.json" ] && has_frps="1"

uplink_bytes="0"
downlink_bytes="0"
if [ -f "${data_dir}/traffic.json" ] && command -v jsonfilter >/dev/null 2>&1; then
	uplink_bytes="$(jsonfilter -i "${data_dir}/traffic.json" -e '@.uplink' 2>/dev/null || echo 0)"
	downlink_bytes="$(jsonfilter -i "${data_dir}/traffic.json" -e '@.downlink' 2>/dev/null || echo 0)"
fi
[ -n "$uplink_bytes" ] || uplink_bytes="0"
[ -n "$downlink_bytes" ] || downlink_bytes="0"

token_set="0"
[ -n "$token" ] && token_set="1"
enroll_set="0"
[ -n "$enroll_token" ] && enroll_set="1"

# Host stats the Panel system/ops cards show, collected without blocking.
# awk does the *1024 so 32-bit ash arithmetic cannot overflow on large disks.
hostname="$(uname -n 2>/dev/null || true)"
load1=""
if [ -r /proc/loadavg ]; then
	read -r load1 _ < /proc/loadavg || true
fi
congestion=""
if [ -r /proc/sys/net/ipv4/tcp_congestion_control ]; then
	congestion="$(tr -d ' \t\n' < /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)"
fi
uptime_seconds="0"
mem_total_bytes="0"
mem_available_bytes="0"
mem_used_bytes="0"
disk_total_bytes="0"
disk_used_bytes="0"
if command -v awk >/dev/null 2>&1; then
	if [ -r /proc/uptime ]; then
		uptime_seconds="$(awk '{ printf "%.0f", $1 }' /proc/uptime 2>/dev/null || echo 0)"
	fi
	if [ -r /proc/meminfo ]; then
		mem_total_bytes="$(awk '/^MemTotal:/ { printf "%.0f", $2 * 1024 }' /proc/meminfo 2>/dev/null || echo 0)"
		mem_available_bytes="$(awk '/^MemAvailable:/ { printf "%.0f", $2 * 1024 }' /proc/meminfo 2>/dev/null || echo 0)"
		mem_used_bytes="$(awk -v t="${mem_total_bytes:-0}" -v a="${mem_available_bytes:-0}" 'BEGIN { u=t-a; if (u<0) u=0; printf "%.0f", u }')"
	fi
	if command -v df >/dev/null 2>&1; then
		df_out="$(df -Pk / 2>/dev/null | awk 'NR==2 { printf "%.0f %.0f", $2 * 1024, $3 * 1024 }' || true)"
		if [ -n "$df_out" ]; then
			disk_total_bytes="${df_out%% *}"
			disk_used_bytes="${df_out#* }"
		fi
	fi
fi
[ -n "$uptime_seconds" ] || uptime_seconds="0"
[ -n "$mem_total_bytes" ] || mem_total_bytes="0"
[ -n "$mem_available_bytes" ] || mem_available_bytes="0"
[ -n "$mem_used_bytes" ] || mem_used_bytes="0"
[ -n "$disk_total_bytes" ] || disk_total_bytes="0"
[ -n "$disk_used_bytes" ] || disk_used_bytes="0"

now="$(date +%s 2>/dev/null || echo 0)"

printf '{'
printf '"collected_at_unix":%s,' "$now"
printf '"enabled":%s,' "$enabled"
printf '"init_enabled":%s,' "$init_enabled"
printf '"running":%s,' "$running"
printf '"pid":"%s",' "$(json_escape "$pid")"
printf '"version":"%s",' "$(json_escape "$version")"
printf '"panel_url":"%s",' "$(json_escape "$panel_url")"
printf '"node_id":"%s",' "$(json_escape "$node_id")"
printf '"token_set":%s,' "$token_set"
printf '"token_masked":"%s",' "$(json_escape "$(mask_secret "$token")")"
printf '"enroll_token_set":%s,' "$enroll_set"
printf '"listen":"%s",' "$(json_escape "$listen")"
printf '"data_dir":"%s",' "$(json_escape "$data_dir")"
printf '"uplink":%s,' "$uplink"
printf '"uplink_serve_grpc":%s,' "$uplink_serve_grpc"
printf '"uplink_ws":%s,' "$uplink_ws"
printf '"report_address":"%s",' "$(json_escape "$report_address")"
printf '"has_config":%s,' "$has_config"
printf '"config_bytes":%s,' "${config_bytes:-0}"
printf '"inbound_count":%s,' "${inbound_count:-0}"
printf '"inbound_types":"%s",' "$(json_escape "$inbound_types")"
printf '"has_frps":%s,' "$has_frps"
printf '"uplink_bytes":%s,' "${uplink_bytes:-0}"
printf '"downlink_bytes":%s,' "${downlink_bytes:-0}"
printf '"hostname":"%s",' "$(json_escape "$hostname")"
printf '"load1":"%s",' "$(json_escape "$load1")"
printf '"congestion":"%s",' "$(json_escape "$congestion")"
printf '"uptime_seconds":%s,' "${uptime_seconds:-0}"
printf '"mem_total_bytes":%s,' "${mem_total_bytes:-0}"
printf '"mem_used_bytes":%s,' "${mem_used_bytes:-0}"
printf '"disk_total_bytes":%s,' "${disk_total_bytes:-0}"
printf '"disk_used_bytes":%s' "${disk_used_bytes:-0}"
printf '}\n'
