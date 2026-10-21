#!/bin/sh
# Exercises ladder-update.sh with mocked opkg/curl. POSIX sh.
# shellcheck shell=sh
set -eu

rootdir=$(cd -- "$(dirname -- "$0")/.." && pwd)
script=$rootdir/scripts/ladder-update.sh
fail=0

ok() { printf 'ok  %s\n' "$1"; }
bad() {
	printf 'FAIL %s\n' "$1" >&2
	fail=1
}

assert_eq() {
	if [ "$1" = "$2" ]; then
		ok "$3"
	else
		printf '  got [%s] want [%s]\n' "$1" "$2" >&2
		bad "$3"
	fi
}

unit() {
	(
		export LADDER_UPDATE_SOURCE_ONLY=1
		# shellcheck disable=SC1090
		. "$script"
		"$@"
	)
}

setup() {
	base=$(mktemp -d /tmp/ladder-update-test.XXXXXX)
	BIN=$base/bin
	ROOT=$base/root
	STATE=$base/state
	mkdir -p "$BIN" "$ROOT/etc/config" "$ROOT/etc/init.d" "$STATE/status"
	: >"$STATE/install.log"
	: >"$STATE/curl.log"
	: >"$STATE/init.log"

	feed=$base/feed/ladderairport
	mkdir -p "$feed"
	printf 'agent-bytes\n' >"$feed/ladder-agent_0.16.0-2_aarch64_cortex-a53.ipk"
	printf 'luci-bytes\n' >"$feed/luci-app-ladder-agent_0.16.0-2_all.ipk"
	agent_sum=$(sha256sum "$feed/ladder-agent_0.16.0-2_aarch64_cortex-a53.ipk" | awk '{ print $1 }')
	luci_sum=$(sha256sum "$feed/luci-app-ladder-agent_0.16.0-2_all.ipk" | awk '{ print $1 }')
	# Upper case plus a trailing space/CR. A correct checker folds this back.
	# `tr -d '[:space:]'` on a class-incapable tr would also delete a, c, and e.
	agent_sum_raw=$(printf '%s' "$agent_sum" | awk '{ print toupper($0) }')
	luci_sum_raw=$(printf '%s' "$luci_sum" | awk '{ print toupper($0) }')
	{
		printf '%s\n' "Package: ladder-agent"
		printf '%s\n' "Version: 0.16.0-2"
		printf '%s\n' "Filename: ladder-agent_0.16.0-2_aarch64_cortex-a53.ipk"
		printf 'SHA256sum: %s \r\n' "$agent_sum_raw"
		printf '\n'
		printf '%s\n' "Package: luci-app-ladder-agent"
		printf '%s\n' "Version: 0.16.0-2"
		printf '%s\n' "Filename: luci-app-ladder-agent_0.16.0-2_all.ipk"
		printf 'SHA256sum: %s \r\n' "$luci_sum_raw"
	} >"$feed/Packages"
	tar -czf "$base/good.tar.gz" -C "$base/feed" .
	cp "$base/good.tar.gz" "$base/bad.tar.gz"
	# Rebuild a tarball whose index hash does not match the ipk bytes.
	badfeed=$base/badfeed/ladderairport
	mkdir -p "$badfeed"
	cp "$feed"/* "$badfeed/"
	printf 'tampered\n' >>"$badfeed/ladder-agent_0.16.0-2_aarch64_cortex-a53.ipk"
	tar -czf "$base/bad.tar.gz" -C "$base/badfeed" .

	cat >"$base/release.json" <<EOF
{
  "tag_name": "v0.16.0-2",
  "name": "v0.16.0-2",
  "assets": [
    {
      "name": "aarch64_cortex-a53.tar.gz",
      "browser_download_url": "https://github.com/LadderAirport/LadderAirportOpenwrt/releases/download/v0.16.0-2/aarch64_cortex-a53.tar.gz"
    },
    {
      "name": "x86_64.tar.gz",
      "browser_download_url": "https://github.com/LadderAirport/LadderAirportOpenwrt/releases/download/v0.16.0-2/x86_64.tar.gz"
    },
    {
      "name": "SHA256SUMS.txt",
      "browser_download_url": "https://github.com/LadderAirport/LadderAirportOpenwrt/releases/download/v0.16.0-2/SHA256SUMS.txt"
    }
  ]
}
EOF

	cat >"$ROOT/etc/config/ladder-agent" <<'EOF'
config ladder-agent 'main'
	option enabled '1'
	option panel_url 'https://panel.example.com'
	option token 'secret-token'
	list tls_sans 'a.example'
EOF
	cat >"$base/opkg-config" <<'EOF'
config ladder-agent 'main'
	option enabled '1'
	option panel_url 'https://panel.example.com'
	option token 'replaced-token'
	option egress_interface 'wan'
	list tls_sans 'a.example'
	list log_target 'syslog'
EOF
	cp "$ROOT/etc/config/ladder-agent" "$base/user-config.before"

	cat >"$ROOT/etc/init.d/ladder-agent" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >>"$STATE/init.log"
case \$1 in
restart) exit 0 ;;
status)
	if [ "\${MOCK_STATUS_MISSING:-}" = 1 ]; then
		echo "status: not found" >&2
		exit 127
	fi
	echo running
	exit 0
	;;
esac
exit 0
EOF
	chmod +x "$ROOT/etc/init.d/ladder-agent"

	cat >"$BIN/curl" <<EOF
#!/bin/sh
dest=
prev=
url=
for arg in "\$@"; do
	if [ "\$prev" = "-o" ]; then
		dest=\$arg
		prev=
		continue
	fi
	case \$arg in
	-o) prev=-o ;;
	http://* | https://*) url=\$arg ;;
	esac
done
printf '%s\n' "\$url" >>"$STATE/curl.log"
case \$url in
*api.github.com/repos/LadderAirport/LadderAirportOpenwrt/releases/latest | *api.github.com/repos/LadderAirport/LadderAirportOpenwrt/releases/tags/*)
	cp "$base/release.json" "\$dest"
	;;
*releases/download/*aarch64_cortex-a53.tar.gz | *releases/download/*x86_64.tar.gz)
	if [ "\${MOCK_BAD_TAR:-}" = 1 ]; then
		cp "$base/bad.tar.gz" "\$dest"
	else
		cp "$base/good.tar.gz" "\$dest"
	fi
	;;
*)
	echo "unexpected url \$url" >&2
	exit 1
	;;
esac
EOF
	chmod +x "$BIN/curl"

	cat >"$BIN/opkg" <<EOF
#!/bin/sh
cmd=\$1
shift
case \$cmd in
print-architecture)
	cat "$STATE/arch"
	;;
status)
	if [ -f "$STATE/status/\$1" ]; then
		cat "$STATE/status/\$1"
	fi
	;;
install)
	printf '%s\n' "\$*" >>"$STATE/install.log"
	ipk=\$1
	case \$1 in
	--force-reinstall)
		ipk=\$2
		;;
	esac
	base=\$(basename "\$ipk")
	case \$base in
	luci-app-ladder-agent_*) pkg=luci-app-ladder-agent ;;
	ladder-agent_*) pkg=ladder-agent ;;
	*) echo "unknown ipk \$base" >&2; exit 1 ;;
	esac
	cat >"$STATE/status/\$pkg" <<STATUS
Package: \$pkg
Version: 0.16.0-2
Status: install user installed
STATUS
	if [ "\$pkg" = ladder-agent ] && [ "\${MOCK_WRITE_OPKG:-}" = 1 ]; then
		cp "$base/opkg-config" "$ROOT/etc/config/ladder-agent-opkg"
	fi
	;;
*)
	echo "bad opkg \$cmd" >&2
	exit 1
	;;
esac
EOF
	chmod +x "$BIN/opkg"

	cat >"$BIN/pidof" <<'EOF'
#!/bin/sh
echo 4242
exit 0
EOF
	chmod +x "$BIN/pidof"

	cat >"$BIN/jsonfilter" <<'EOF'
#!/bin/sh
expr=
while [ $# -gt 0 ]; do
	case $1 in
	-e)
		shift
		expr=$1
		;;
	esac
	[ $# -gt 0 ] || break
	shift
done
python3 -c '
import json, sys
expr = sys.argv[1]
data = json.load(sys.stdin)
if expr == "@.tag_name":
    print(data["tag_name"])
elif expr == "@.assets[*].name":
    for asset in data["assets"]:
        print(asset["name"])
elif expr == "@.assets[*].browser_download_url":
    for asset in data["assets"]:
        print(asset["browser_download_url"])
else:
    sys.stderr.write("bad expr %s\n" % expr)
    sys.exit(1)
' "$expr"
EOF
	chmod +x "$BIN/jsonfilter"

	# BusyBox tr without FEATURE_TR_CLASSES: [:space:] is the literal set
	# "[ :space:]", so -d removes a, c, and e. Ranges such as A-F still expand.
	cat >"$BIN/tr" <<'EOF'
#!/usr/bin/env python3
import sys

def expand(s):
    out = []
    i = 0
    while i < len(s):
        if i + 2 < len(s) and s[i + 1] == "-":
            a, b = s[i], s[i + 2]
            if a <= b:
                for code in range(ord(a), ord(b) + 1):
                    out.append(chr(code))
            else:
                out.extend((a, "-", b))
            i += 3
        else:
            out.append(s[i])
            i += 1
    return out

delete = False
sets = []
for arg in sys.argv[1:]:
    if arg == "-d":
        delete = True
    elif arg.startswith("-"):
        sys.stderr.write("tr shim: unsupported %s\n" % arg)
        sys.exit(1)
    else:
        sets.append(arg)

text = sys.stdin.read()
if delete:
    if not sets:
        sys.stderr.write("tr shim: missing set\n")
        sys.exit(1)
    drop = set(expand(sets[0]))
    text = "".join(ch for ch in text if ch not in drop)
else:
    if len(sets) < 2:
        sys.stderr.write("tr shim: missing set\n")
        sys.exit(1)
    src = expand(sets[0])
    dst = expand(sets[1])
    if not dst:
        sys.stderr.write("tr shim: empty set2\n")
        sys.exit(1)
    if len(dst) < len(src):
        dst = dst + [dst[-1]] * (len(src) - len(dst))
    table = {}
    for idx, ch in enumerate(src):
        table[ch] = dst[idx]
    text = "".join(table.get(ch, ch) for ch in text)
sys.stdout.write(text)
EOF
	chmod +x "$BIN/tr"
}

write_status() {
	pkg=$1
	ver=$2
	cat >"$STATE/status/$pkg" <<EOF
Package: $pkg
Version: $ver
Status: install user installed
EOF
}

run_update() {
	# Extra env assignments are prefix words in $1 when needed; callers export.
	PATH="$RUN_PATH" LADDER_UPDATE_ROOT="$ROOT" "$RUN_SH" "$script" "$@"
}

# --- unit: arch map and release parse ---

select_from() {
	text=$1
	dir=$2
	printf '%s\n' "$text" >"$dir/arch"
	select_arch "$dir/arch" "$dir/sorted"
}

unit_arch_body() {
	d=$(mktemp -d)
	got=$(select_from "arch all 1
arch noarch 1
arch aarch64_cortex-a55_neon-vfpv4 10" "$d")
	[ "$got" = aarch64_cortex-a53 ]
	got=$(select_from "arch all 1
arch aarch64_cortex-a72 10" "$d")
	[ "$got" = aarch64_cortex-a53 ]
	got=$(select_from "arch all 1
arch aarch64_generic 20
arch aarch64_cortex-a53 10" "$d")
	[ "$got" = aarch64_generic ]
	got=$(select_from "arch all 1
arch aarch64_generic 10
arch aarch64_cortex-a53 30" "$d")
	[ "$got" = aarch64_cortex-a53 ]
	got=$(select_from "arch all 1
arch x86_64 10" "$d")
	[ "$got" = x86_64 ]
	got=$(select_from "arch all 1
arch mipsel_24kc 10" "$d")
	[ "$got" = mipsel_24kc ]
	got=$(select_from "arch all 1
arch arm_cortex-a7_neon 10" "$d")
	[ "$got" = arm_cortex-a7 ]
	if select_from "arch all 1
arch arc 10" "$d" >/dev/null 2>&1; then
		exit 1
	fi
	LADDER_GH_PREFIX=
	export LADDER_GH_PREFIX
	[ "$(prefix_url https://github.com/a)" = "https://github.com/a" ]
	LADDER_GH_PREFIX=https://ghfast.top/
	export LADDER_GH_PREFIX
	[ "$(prefix_url https://github.com/a)" = "https://ghfast.top/https://github.com/a" ]
	LADDER_GH_PREFIX=https://ghfast.top
	export LADDER_GH_PREFIX
	[ "$(prefix_url https://github.com/a)" = "https://ghfast.top/https://github.com/a" ]
	[ "$(normalize_tag 0.16.0-2)" = "v0.16.0-2" ]
	[ "$(normalize_tag v0.16.0-2)" = "v0.16.0-2" ]
	rm -rf "$d"
}

unit_parse_body() {
	tag=$(parse_release_awk "$base/release.json" "$base/assets")
	[ "$tag" = "v0.16.0-2" ]
	url=$(asset_url "aarch64_cortex-a53.tar.gz" "$base/assets")
	[ "$url" = "https://github.com/LadderAirport/LadderAirportOpenwrt/releases/download/v0.16.0-2/aarch64_cortex-a53.tar.gz" ]
	ver=$(index_field ladder-agent Version "$feed/Packages")
	[ "$ver" = "0.16.0-2" ]
	fn=$(index_field luci-app-ladder-agent Filename "$feed/Packages")
	[ "$fn" = "luci-app-ladder-agent_0.16.0-2_all.ipk" ]
	keys=$(uci_keys "$base/opkg-config")
	printf '%s\n' "$keys" | grep -qx egress_interface
	printf '%s\n' "$keys" | grep -qx log_target
	printf '%s\n' "$keys" | grep -qx token
}

unit_hex_body() {
	sample=ba536bba798b3acb44c178cb0712cb40cf7fc466444e836d42df9b7cdb02434a
	upper=$(printf '%s' "$sample" | awk '{ print toupper($0) }')
	got=$(printf ' \t%s \r' "$upper" | normalize_hex)
	[ "$got" = "$sample" ]
}

# --- integration ---

check() {
	desc=$1
	shift
	if "$@"; then
		ok "$desc"
	else
		bad "$desc"
	fi
}

check_absent() {
	desc=$1
	shift
	if "$@"; then
		bad "$desc"
	else
		ok "$desc"
	fi
}

launch() {
	if [ "$RUN_SH" = "busybox" ]; then
		PATH="$RUN_PATH" LADDER_UPDATE_ROOT="$ROOT" busybox ash "$script" "$@"
	else
		PATH="$RUN_PATH" LADDER_UPDATE_ROOT="$ROOT" "$RUN_SH" "$script" "$@"
	fi
}

assert_classless_tr() {
	shell_bin=$1
	sample=ba536bba798b3acb44c178cb0712cb40cf7fc466444e836d42df9b7cdb02434a
	got=$(printf '%s' "$sample" | "$BIN/tr" -d '[:space:]')
	want=b536bb798b3b44178b0712b40f7f466444836d42df9b7db02434
	if [ "$got" = "$want" ]; then
		ok "classless tr deletes a/c/e ($shell_bin)"
	else
		printf '  got [%s]\n' "$got" >&2
		bad "classless tr deletes a/c/e ($shell_bin)"
	fi
	folded=$(printf '%s' 'ABCDEF' | "$BIN/tr" 'A-F' 'a-f')
	if [ "$folded" = "abcdef" ]; then
		ok "classless tr still folds A-F ($shell_bin)"
	else
		bad "classless tr still folds A-F ($shell_bin)"
	fi
}

integration_cases() {
	shell_bin=$1
	setup
	assert_classless_tr "$shell_bin"
	printf '%s\n' "arch all 1" "arch noarch 1" "arch aarch64_cortex-a55_neon-vfpv4 10" >"$STATE/arch"
	write_status ladder-agent 0.15.12-2
	RUN_PATH="$BIN:/usr/bin:/bin"
	rm -f "$BIN/jsonfilter"
	RUN_SH=$shell_bin
	out=$base/out

	if MOCK_WRITE_OPKG=1 launch >"$out"; then
		ok "upgrade a55 under classless tr ($shell_bin)"
	else
		bad "upgrade a55 under classless tr ($shell_bin)"
		cat "$out" >&2 || true
		return
	fi
	check "a55 downloads a53 tarball" grep -q 'aarch64_cortex-a53.tar.gz' "$STATE/curl.log"
	check "latest release api" grep -q 'releases/latest' "$STATE/curl.log"
	check "install order agent then luci" awk '
		NR == 1 && /ladder-agent_/ && !/luci/ { ok = 1 }
		NR == 2 && /luci-app-ladder-agent_/ { ok = ok + 1 }
		END { exit ok != 2 }
	' "$STATE/install.log"
	check "reports new egress_interface" grep -q 'egress_interface' "$out"
	check "reports new list key" grep -q 'log_target' "$out"
	check_absent "does not print token values" grep -q 'replaced-token' "$out"
	check "user config unchanged" cmp -s "$base/user-config.before" "$ROOT/etc/config/ladder-agent"
	check "keeps -opkg by default" test -f "$ROOT/etc/config/ladder-agent-opkg"
	check "prints agent version arrow" grep -q '0.15.12-2 -> 0.16.0-2' "$out"
	check "prints luci installed from none" grep -q '未安装 -> 0.16.0-2' "$out"
	check "restarts service" grep -q '^restart$' "$STATE/init.log"
	check "prints service status" grep -q 'running' "$out"

	: >"$STATE/install.log"
	: >"$STATE/init.log"
	if launch >"$out"; then
		ok "second run skips"
	else
		bad "second run skips"
	fi
	check "skip does not reinstall" test ! -s "$STATE/install.log"
	check "skip does not restart" test ! -s "$STATE/init.log"
	check "skip message" grep -q '跳过安装' "$out"

	if launch --drop-opkg >"$out"; then
		ok "drop-opkg run"
	else
		bad "drop-opkg run"
	fi
	check "drop-opkg removes file" test ! -f "$ROOT/etc/config/ladder-agent-opkg"
	check "drop-opkg keeps user config" cmp -s "$base/user-config.before" "$ROOT/etc/config/ladder-agent"

	: >"$STATE/install.log"
	if launch --force >"$out"; then
		ok "force reinstall"
	else
		bad "force reinstall"
	fi
	check "force uses --force-reinstall" grep -q -- '--force-reinstall' "$STATE/install.log"
	check "force installs both packages" awk 'END { exit NR != 2 }' "$STATE/install.log"

	: >"$STATE/curl.log"
	: >"$STATE/install.log"
	if MOCK_BAD_TAR=1 launch --force >"$out" 2>"$base/err"; then
		bad "bad sha256 must fail"
	else
		ok "bad sha256 must fail"
	fi
	check "bad sha256 message" grep -q 'SHA256' "$base/err"
	check "bad sha256 installs nothing" test ! -s "$STATE/install.log"

	: >"$STATE/curl.log"
	if launch --arch x86_64 v0.16.0-2 >"$out"; then
		ok "explicit version and arch"
	else
		bad "explicit version and arch"
	fi
	check "tag api" grep -q 'releases/tags/v0.16.0-2' "$STATE/curl.log"
	check "x86_64 asset" grep -q '/x86_64.tar.gz' "$STATE/curl.log"

	: >"$STATE/curl.log"
	if LADDER_GH_PREFIX=https://ghfast.top/ launch --arch armv7 >/dev/null 2>"$base/err"; then
		bad "unsupported arch must fail before download"
	else
		ok "unsupported arch must fail"
	fi
	check "bad arch does not download" test ! -s "$STATE/curl.log"

	: >"$STATE/curl.log"
	if LADDER_GH_PREFIX=https://ghfast.top launch --arch aarch64_cortex-a53 >"$out"; then
		ok "mirror prefix"
	else
		bad "mirror prefix"
	fi
	check "prefix on api" grep -q '^https://ghfast.top/https://api.github.com/' "$STATE/curl.log"
	check "prefix on tarball" grep -q '^https://ghfast.top/https://github.com/.*/aarch64_cortex-a53.tar.gz$' "$STATE/curl.log"

	: >"$STATE/init.log"
	if MOCK_STATUS_MISSING=1 launch --force >"$out"; then
		ok "19.07 status fallback"
	else
		bad "19.07 status fallback"
	fi
	check "pidof fallback" grep -q '4242' "$out"

	rm -rf "$base"
}

jsonfilter_smoke() {
	setup
	printf '%s\n' "arch all 1" "arch aarch64_cortex-a53 10" >"$STATE/arch"
	RUN_PATH="$BIN:/usr/bin:/bin"
	if PATH="$RUN_PATH" LADDER_UPDATE_ROOT="$ROOT" /bin/sh "$script" --arch aarch64_cortex-a53 >"$base/out"; then
		ok "jsonfilter parser smoke"
	else
		bad "jsonfilter parser smoke"
		cat "$base/out" >&2 || true
	fi
	check "jsonfilter saw tag" grep -q 'v0.16.0-2' "$base/out"
	rm -rf "$base"
}

no_downloader() {
	setup
	rm -f "$BIN/curl" "$BIN/wget" "$BIN/uclient-fetch" "$BIN/jsonfilter" "$BIN/opkg"
	ln -s "$(command -v mkdir)" "$BIN/mkdir"
	ln -s "$(command -v mktemp)" "$BIN/mktemp"
	if PATH="$BIN" LADDER_UPDATE_ROOT="$ROOT" /bin/sh "$script" --arch x86_64 v0.16.0-2 >"$base/out" 2>"$base/err"; then
		bad "missing downloader must fail"
	else
		ok "missing downloader must fail"
	fi
	check "missing downloader message" grep -q 'curl' "$base/err"
	rm -rf "$base"
}

if unit unit_arch_body; then
	ok "arch priority and url prefix"
else
	bad "arch priority and url prefix"
fi
setup
if unit unit_parse_body; then
	ok "awk release parse, index, uci keys"
else
	bad "awk release parse, index, uci keys"
fi
if unit unit_hex_body; then
	ok "normalize hex without tr classes"
else
	bad "normalize hex without tr classes"
fi
rm -rf "$base"

integration_cases /bin/sh
if command -v dash >/dev/null 2>&1; then
	integration_cases dash
fi
if command -v busybox >/dev/null 2>&1; then
	integration_cases busybox
fi
jsonfilter_smoke
no_downloader

if [ "$fail" -eq 0 ]; then
	printf '%s\n' "all ladder-update checks passed"
else
	printf '%s\n' "ladder-update checks failed" >&2
	exit 1
fi
