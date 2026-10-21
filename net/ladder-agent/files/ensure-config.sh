#!/bin/sh
# Create /etc/config/ladder-agent, or add options from the defaults file
# that are not set yet. An existing value is never replaced.
#
# Upgrading from 0.16.0-r3 deletes /etc/config/ladder-agent: that release
# shipped it, and opkg unlinks files the previous package owned when the
# new package does not. preinst copies the live file to
# /tmp/ladder-agent.config.preserve first. This script puts it back.
# shellcheck shell=sh
set -eu

DEFAULTS=${LADDER_DEFAULTS:-/usr/share/ladder-agent/ladder-agent.defaults}
CFG=${LADDER_UCI_CONFIG:-/etc/config/ladder-agent}
PRESERVE=${LADDER_CONFIG_PRESERVE:-/tmp/ladder-agent.config.preserve}
PKG=ladder-agent

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

command -v uci >/dev/null 2>&1 || die "需要 uci 才能写入 ${CFG}"
[ -f "$DEFAULTS" ] || die "找不到默认配置 ${DEFAULTS}"

if [ ! -f "$CFG" ] && [ -f "$PRESERVE" ]; then
	mkdir -p "$(dirname "$CFG")"
	cp -f "$PRESERVE" "$CFG"
fi
rm -f "$PRESERVE"

dir=$(dirname "$CFG")
sq=$(printf "'")
parsed=${TMPDIR:-/tmp}/ladder-ensure.$$
trap 'rm -f "$parsed"' EXIT INT HUP TERM

awk -v sq="$sq" '
function unquote(s,    q, n) {
	gsub(/^[ \t]+/, "", s)
	gsub(/[ \t]+$/, "", s)
	n = length(s)
	q = substr(s, 1, 1)
	if (n >= 2 && (q == sq || q == "\"") && substr(s, n, 1) == q)
		return substr(s, 2, n - 2)
	return s
}
function emit(    unused) {
	if (emitted)
		return
	emitted = 1
	printf "section\t%s\t\n", sec
}
BEGIN { sec = "main"; emitted = 0 }
/^[\t ]*($|#)/ { next }
/^[\t ]*config[\t ]/ {
	if ($3 != "")
		sec = unquote($3)
	next
}
/^[\t ]*(option|list)[\t ]/ {
	emit()
	kind = $1
	key = $2
	rest = $0
	sub(/^[\t ]*(option|list)[\t ]+[^ \t]+[\t ]*/, "", rest)
	printf "%s\t%s\t%s\n", kind, key, unquote(rest)
}
END { emit() }
' "$DEFAULTS" >"$parsed"

secname=main
tab=$(printf '\t')
while IFS="$tab" read -r kind key val; do
	[ -n "${kind}" ] || continue
	case $kind in
	section)
		secname=$key
		if ! uci -c "$dir" -q get "${PKG}.${secname}" >/dev/null 2>&1; then
			uci -c "$dir" set "${PKG}.${secname}=${PKG}"
		fi
		;;
	option)
		if ! uci -c "$dir" -q get "${PKG}.${secname}.${key}" >/dev/null 2>&1; then
			uci -c "$dir" set "${PKG}.${secname}.${key}=${val}"
		fi
		;;
	list)
		if ! uci -c "$dir" -q get "${PKG}.${secname}.${key}" >/dev/null 2>&1; then
			uci -c "$dir" add_list "${PKG}.${secname}.${key}=${val}"
		fi
		;;
	*)
		die "默认配置里有无法识别的行: ${kind}"
		;;
	esac
done <"$parsed"

uci -c "$dir" commit "$PKG"
rm -f "$parsed"
trap - EXIT INT HUP TERM
