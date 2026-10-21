#!/bin/sh
# ladder-update.sh — install or upgrade ladder-agent on OpenWrt.
#
# POSIX sh / BusyBox ash (OpenWrt 19.07 and newer). No bash, jq, or GNU tar.
# Downloads one arch tarball from a GitHub Release, checks each ipk against
# the Packages index SHA256, installs ladder-agent before luci-app-ladder-agent,
# and leaves /etc/config/ladder-agent alone. Packages from 0.16.0-r4 on
# do not ship that file as a conffile; an older install may still have
# left /etc/config/ladder-agent-opkg.
#
#   curl -fsSL https://github.com/LadderAirport/LadderAirportOpenwrt/releases/latest/download/ladder-update.sh | sh
#
#   export LADDER_GH_PREFIX=https://ghfast.top/
#   curl -fsSL "${LADDER_GH_PREFIX}https://github.com/LadderAirport/LadderAirportOpenwrt/releases/latest/download/ladder-update.sh" | sh
#
# shellcheck shell=sh

set -eu

REPO="LadderAirport/LadderAirportOpenwrt"
API="https://api.github.com/repos/${REPO}"
DOWNLOAD_BASE="https://github.com/${REPO}/releases/download"

PUBLISHED_ARCHES="x86_64 aarch64_generic aarch64_cortex-a53 arm_cortex-a7 arm_cortex-a9 mipsel_24kc"

usage() {
	cat <<'EOF'
用法: ladder-update.sh [选项] [版本]

从 GitHub Release 安装或升级 ladder-agent 和 luci-app-ladder-agent。
已安装的 /etc/config/ladder-agent 不会被覆盖。0.16.0-r4 起，包本身
只补上缺失的选项，不改已有的值，也不再把这份配置打成 conffile。

  版本              Release 标签，例如 v0.16.0-2 或 0.16.0-2。省略则用最新发布。
  --arch ARCH       使用该架构的包，不再看 opkg print-architecture
  --force           版本相同也重新安装
  --drop-opkg       列出新选项后删除旧包留下的 /etc/config/ladder-agent-opkg
                    0.16.0-r3 及更早才会生成它。默认保留。两种情况下都不改已有的值。
  -h, --help        显示本说明

环境变量:
  LADDER_GH_PREFIX  加在 GitHub URL 前面的镜像前缀，例如 https://ghfast.top/
  LADDER_ARCH       同 --arch
EOF
}

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

is_published() {
	case " $PUBLISHED_ARCHES " in
	*" $1 "*) return 0 ;;
	*) return 1 ;;
	esac
}

# Map an opkg arch name onto a tarball we publish.
map_arch() {
	name=$1
	if is_published "$name"; then
		printf '%s\n' "$name"
		return 0
	fi
	case $name in
	*cortex-a55* | *cortex-a72* | *cortex-a73* | *cortex-a75* | *cortex-a76* | *cortex-a77* | *cortex-a78* | *cortex-a53*)
		printf '%s\n' aarch64_cortex-a53
		;;
	*cortex-a7*)
		printf '%s\n' arm_cortex-a7
		;;
	*cortex-a9* | *cortex-a8* | *cortex-a15* | *cortex-a17*)
		printf '%s\n' arm_cortex-a9
		;;
	*mipsel_24kc* | *mipsel_24k*)
		printf '%s\n' mipsel_24kc
		;;
	x86_64_* | *x86_64)
		printf '%s\n' x86_64
		;;
	aarch64_generic* | aarch64)
		printf '%s\n' aarch64_generic
		;;
	*)
		return 1
		;;
	esac
}

# Higher opkg priority wins, same rule as opkg itself. Unknown names fall
# through the map (cortex-a55 / cortex-a72 -> aarch64_cortex-a53).
select_arch() {
	archfile=$1
	sorted=$2
	awk '
		$1 == "arch" && $2 != "" && $2 != "all" && $2 != "noarch" && $3 ~ /^[0-9]+$/ {
			printf "%08d %s\n", $3, $2
		}
	' "$archfile" | sort -r | awk '{ print $2 }' >"$sorted"
	while read -r name; do
		[ -n "$name" ] || continue
		if mapped=$(map_arch "$name"); then
			printf '%s\n' "$mapped"
			return 0
		fi
	done <"$sorted"
	return 1
}

prefix_url() {
	prefix=${LADDER_GH_PREFIX:-}
	case $prefix in
	"") printf '%s\n' "$1" ;;
	*/) printf '%s%s\n' "$prefix" "$1" ;;
	*) printf '%s/%s\n' "$prefix" "$1" ;;
	esac
}

normalize_tag() {
	case $1 in
	v*) printf '%s\n' "$1" ;;
	*) printf 'v%s\n' "$1" ;;
	esac
}

http_get() {
	url=$1
	dest=$2
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 30 --retry 3 --retry-delay 2 -o "$dest" "$url"
		return
	fi
	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -T 30 -O "$dest" "$url"
		return
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -q -T 30 -O "$dest" "$url"
		return
	fi
	die "需要 curl、uclient-fetch 或 wget 才能下载"
}

file_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
		return
	fi
	if command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$1" | awk '{ print $NF }'
		return
	fi
	die "需要 sha256sum 或 openssl 才能校验 ipk"
}

# OpenWrt BusyBox is often built without FEATURE_TR_CLASSES. In that build,
# `tr -d '[:space:]'` deletes the literal characters in "[ :space:]" — including
# a, c, and e — and corrupts a hex digest. Fold case and drop whitespace here
# instead of calling tr.
normalize_hex() {
	awk '{ gsub(/[ \t\r]/, ""); print tolower($0) }'
}

index_field() {
	pkg=$1
	field=$2
	file=$3
	awk -v pkg="$pkg" -v field="$field" '
		$0 ~ /^Package:[[:space:]]*/ {
			if (cur == pkg && val != "") have = 1
			cur = $2
			if (cur == pkg) val = ""
			next
		}
		have { next }
		cur == pkg && index($0, field ":") == 1 {
			sub(/^[^:]*:[[:space:]]*/, "")
			val = $0
		}
		END { if (val != "") print val }
	' "$file"
}

opkg_version() {
	pkg=$1
	opkg status "$pkg" 2>/dev/null | awk -v pkg="$pkg" '
		$1 == "Package:" { cur = $2 }
		$1 == "Version:" && cur == pkg { print $2; exit }
	' || true
}

uci_keys() {
	file=$1
	[ -f "$file" ] || return 0
	sed -n '
		s/^[[:space:]]*option[[:space:]][[:space:]]*\([A-Za-z0-9_][A-Za-z0-9_]*\).*/\1/p
		s/^[[:space:]]*list[[:space:]][[:space:]]*\([A-Za-z0-9_][A-Za-z0-9_]*\).*/\1/p
	' "$file" | awk '!seen[$0]++'
}

# One line per option/list assignment: "option token secret".
# uci commit rewrites the file, so a byte compare would warn when the
# package only fills in a missing option.
uci_assignments() {
	file=$1
	[ -f "$file" ] || return 0
	awk '
		function unquote(s,    q, n) {
			gsub(/^[ \t]+/, "", s)
			gsub(/[ \t]+$/, "", s)
			n = length(s)
			q = substr(s, 1, 1)
			if (n >= 2 && (q == "\047" || q == "\"") && substr(s, n, 1) == q)
				return substr(s, 2, n - 2)
			return s
		}
		$1 == "option" || $1 == "list" {
			kind = $1
			key = $2
			rest = $0
			sub(/^[ \t]*(option|list)[ \t]+[^ \t]+[ \t]+/, "", rest)
			print kind, key, unquote(rest)
		}
	' "$file"
}

# Exit 0 when an assignment that was already set is missing or different.
config_values_changed() {
	before=$1
	after=$2
	line=
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if ! grep -qxF -e "$line" "$after"; then
			return 0
		fi
	done <"$before"
	return 1
}

# Pretty-printed GitHub release JSON. Ignores the release-level "name"
# and only pairs asset names with browser_download_url inside "assets".
parse_release_awk() {
	file=$1
	names=$2
	awk '
		/"tag_name"[[:space:]]*:/ && tag == "" {
			line = $0
			sub(/.*"tag_name"[[:space:]]*:[[:space:]]*"/, "", line)
			sub(/".*/, "", line)
			tag = line
		}
		/"assets"[[:space:]]*:/ { in_assets = 1 }
		in_assets && /"name"[[:space:]]*:/ {
			line = $0
			sub(/.*"name"[[:space:]]*:[[:space:]]*"/, "", line)
			sub(/".*/, "", line)
			asset_name = line
		}
		in_assets && /"browser_download_url"[[:space:]]*:/ {
			line = $0
			sub(/.*"browser_download_url"[[:space:]]*:[[:space:]]*"/, "", line)
			sub(/".*/, "", line)
			if (asset_name != "") {
				print asset_name " " line
				asset_name = ""
			}
		}
		END {
			if (tag == "") exit 1
			print tag > tagfile
		}
	' tagfile="$2.tag" "$file" >"$names"
	tag=$(cat "$2.tag")
	printf '%s\n' "$tag"
}

parse_release_jsonfilter() {
	file=$1
	names=$2
	tag=$(jsonfilter -e '@.tag_name' <"$file" 2>/dev/null) || tag=
	jsonfilter -e '@.assets[*].name' <"$file" >"$workdir/asset.names" 2>/dev/null || true
	jsonfilter -e '@.assets[*].browser_download_url' <"$file" >"$workdir/asset.urls" 2>/dev/null || true
	awk 'NR == FNR { a[NR] = $0; c = NR; next } FNR <= c { print a[FNR] " " $0 }' \
		"$workdir/asset.names" "$workdir/asset.urls" >"$names"
	printf '%s\n' "$tag"
}

load_release() {
	file=$1
	names=$2
	if command -v jsonfilter >/dev/null 2>&1; then
		parse_release_jsonfilter "$file" "$names"
	else
		parse_release_awk "$file" "$names"
	fi
}

asset_url() {
	want=$1
	names=$2
	awk -v want="$want" '
		$1 == want {
			sub(/^[^ ]+ /, "")
			print
			found = 1
			exit
		}
		END { if (!found) exit 1 }
	' "$names"
}

report_opkg_config() {
	cfg=$1
	cfg_new=$2
	keys_old=$3
	keys_new=$4
	[ -f "$cfg_new" ] || return 0
	printf '%s\n' "发现旧包留下的 ${cfg_new}。0.16.0-r3 及更早把该配置当成 conffile，opkg 才会另存这个文件。当前包只补缺失选项，不改已有的值。"
	if [ ! -f "$cfg" ]; then
		printf '%s\n' "发现 ${cfg_new}，但还没有 ${cfg}。"
	else
		uci_keys "$cfg" | sort >"$keys_old"
		uci_keys "$cfg_new" | sort >"$keys_new"
		printf '%s\n' "已保留 ${cfg}，没有改其中的值。"
		found=0
		while read -r key; do
			[ -n "$key" ] || continue
			if ! grep -qx "$key" "$keys_old"; then
				if [ "$found" -eq 0 ]; then
					printf '%s\n' "以下选项只出现在 ${cfg_new##*/} 中："
					found=1
				fi
				printf '  %s\n' "$key"
			fi
		done <"$keys_new"
		if [ "$found" -eq 0 ]; then
			printf '%s\n' "${cfg_new##*/} 没有新的选项名。已有选项的值未比较，也未写入。"
		fi
	fi
	if [ "$drop_opkg" -eq 1 ]; then
		rm -f "$cfg_new"
		printf '%s\n' "已删除 ${cfg_new}。"
	else
		printf '%s\n' "已保留 ${cfg_new}。不需要它时加 --drop-opkg。"
	fi
}

service_status() {
	init=$1
	if [ ! -x "$init" ]; then
		printf '%s\n' "未找到 ${init}，包已处理但未重启服务。"
		return 0
	fi
	if ! "$init" restart; then
		printf '%s\n' "服务重启失败。" >&2
	fi
	if "$init" status >"$workdir/status.out" 2>"$workdir/status.err"; then
		printf '%s\n' "服务状态:"
		cat "$workdir/status.out"
		return 0
	fi
	if [ -s "$workdir/status.out" ]; then
		printf '%s\n' "服务状态:"
		cat "$workdir/status.out"
		return 0
	fi
	if command -v pidof >/dev/null 2>&1 && pidof ladder-agent >/dev/null 2>&1; then
		printf '%s\n' "服务状态: running ($(pidof ladder-agent))"
	else
		printf '%s\n' "服务状态: stopped"
	fi
}

install_pkg() {
	pkg=$1
	packages_file=$2
	ver=$(index_field "$pkg" Version "$packages_file")
	fn=$(index_field "$pkg" Filename "$packages_file")
	sum=$(index_field "$pkg" SHA256sum "$packages_file")
	[ -n "$ver" ] || die "Packages 索引里没有 ${pkg} 的 Version"
	[ -n "$fn" ] || die "Packages 索引里没有 ${pkg} 的 Filename"
	[ -n "$sum" ] || die "Packages 索引里没有 ${pkg} 的 SHA256sum"
	case $fn in
	*/* | *..*) die "拒绝索引中的路径: ${fn}" ;;
	esac
	ipk=$(dirname "$packages_file")/$fn
	[ -f "$ipk" ] || die "找不到 ${ipk}"
	got=$(file_sha256 "$ipk" | normalize_hex)
	want=$(printf '%s\n' "$sum" | normalize_hex)
	if [ "$got" != "$want" ]; then
		die "${fn} 的 SHA256 与 Packages 索引不符"
	fi
	old=$(opkg_version "$pkg")
	if [ "$force" -eq 0 ] && [ "$old" = "$ver" ]; then
		return 0
	fi
	if [ "$force" -eq 1 ] && [ "$old" = "$ver" ]; then
		opkg install --force-reinstall "$ipk"
	else
		opkg install "$ipk"
	fi
	did_install=1
}

cleanup() {
	if [ -n "${workdir:-}" ] && [ -d "$workdir" ]; then
		rm -rf "$workdir"
	fi
}

main() {
	force=0
	drop_opkg=0
	arch_override=${LADDER_ARCH:-}
	version=

	while [ $# -gt 0 ]; do
		case $1 in
		--force) force=1 ;;
		--drop-opkg) drop_opkg=1 ;;
		--arch)
			shift
			[ $# -gt 0 ] || die "--arch 需要一个架构名"
			arch_override=$1
			;;
		--arch=*)
			arch_override=${1#--arch=}
			;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			die "未知选项: $1"
			;;
		*)
			[ -z "$version" ] || die "只能指定一个版本"
			version=$1
			;;
		esac
		shift
	done
	while [ $# -gt 0 ]; do
		[ -z "$version" ] || die "只能指定一个版本"
		version=$1
		shift
	done

	if [ -n "$arch_override" ] && ! is_published "$arch_override"; then
		die "不支持的架构 ${arch_override}。可选: ${PUBLISHED_ARCHES}"
	fi

	root=${LADDER_UPDATE_ROOT:-}
	cfg="${root}/etc/config/ladder-agent"
	cfg_new="${cfg}-opkg"
	init="${root}/etc/init.d/ladder-agent"

	if command -v mktemp >/dev/null 2>&1; then
		workdir=$(mktemp -d /tmp/ladder-update.XXXXXX)
	else
		workdir=/tmp/ladder-update.$$
		mkdir -p "$workdir"
	fi
	trap cleanup EXIT INT HUP TERM

	if [ -n "$arch_override" ]; then
		arch=$arch_override
	else
		command -v opkg >/dev/null 2>&1 || die "需要 opkg，或用 --arch 指定架构"
		opkg print-architecture >"$workdir/arch.txt"
		arch=$(select_arch "$workdir/arch.txt" "$workdir/arch.sorted") ||
			die "无法从 opkg print-architecture 匹配架构。用 --arch 指定其中一个: ${PUBLISHED_ARCHES}"
	fi
	printf '%s\n' "架构: ${arch}"

	tag=
	asset=
	if [ -n "$version" ]; then
		tag=$(normalize_tag "$version")
		if http_get "$(prefix_url "${API}/releases/tags/${tag}")" "$workdir/release.json"; then
			tag=$(load_release "$workdir/release.json" "$workdir/assets") || tag=$(normalize_tag "$version")
			asset=$(asset_url "${arch}.tar.gz" "$workdir/assets") || asset=
		fi
		if [ -z "$asset" ]; then
			asset=$(prefix_url "${DOWNLOAD_BASE}/${tag}/${arch}.tar.gz")
		else
			asset=$(prefix_url "$asset")
		fi
	else
		http_get "$(prefix_url "${API}/releases/latest")" "$workdir/release.json" ||
			die "无法读取最新 Release。可改为: ladder-update.sh v0.16.0-2"
		tag=$(load_release "$workdir/release.json" "$workdir/assets")
		[ -n "$tag" ] || die "最新 Release 没有 tag_name"
		asset=$(asset_url "${arch}.tar.gz" "$workdir/assets") ||
			die "Release ${tag} 没有 ${arch}.tar.gz"
		asset=$(prefix_url "$asset")
	fi
	printf '%s\n' "版本: ${tag}"

	http_get "$asset" "$workdir/arch.tar.gz" || die "下载失败: ${asset}"
	mkdir -p "$workdir/feed"
	tar -xzf "$workdir/arch.tar.gz" -C "$workdir/feed"

	packages_file=
	for candidate in "$workdir/feed"/*/Packages "$workdir/feed"/Packages "$workdir/feed"/*/*/Packages; do
		[ -f "$candidate" ] || continue
		if grep -q '^Package: ladder-agent$' "$candidate"; then
			packages_file=$candidate
			break
		fi
	done
	[ -n "$packages_file" ] || die "压缩包里没有 ladder-agent 的 Packages 索引"

	old_agent=$(opkg_version ladder-agent)
	old_luci=$(opkg_version luci-app-ladder-agent)
	new_agent=$(index_field ladder-agent Version "$packages_file")
	new_luci=$(index_field luci-app-ladder-agent Version "$packages_file")
	: >"$workdir/cfg.before"
	if [ -f "$cfg" ]; then
		uci_assignments "$cfg" | sort >"$workdir/cfg.before"
	fi

	did_install=0
	install_pkg ladder-agent "$packages_file"
	install_pkg luci-app-ladder-agent "$packages_file"

	if [ -s "$workdir/cfg.before" ]; then
		if [ ! -f "$cfg" ]; then
			printf '%s\n' "警告: ${cfg} 不见了，请核对自己的配置。" >&2
		else
			uci_assignments "$cfg" | sort >"$workdir/cfg.after"
			if config_values_changed "$workdir/cfg.before" "$workdir/cfg.after"; then
				printf '%s\n' "警告: ${cfg} 里已有选项的值变了，请核对自己的配置。" >&2
			fi
		fi
	fi

	report_opkg_config "$cfg" "$cfg_new" "$workdir/keys.old" "$workdir/keys.new"

	if [ "$did_install" -eq 0 ]; then
		printf '%s\n' "已是当前版本，跳过安装和重启。"
	else
		service_status "$init"
	fi

	printf '%s\n' "ladder-agent: ${old_agent:-未安装} -> ${new_agent:-未知}"
	printf '%s\n' "luci-app-ladder-agent: ${old_luci:-未安装} -> ${new_luci:-未知}"
	cleanup
	trap - EXIT INT HUP TERM
}

if [ "${LADDER_UPDATE_SOURCE_ONLY:-}" != 1 ]; then
	main "$@"
fi
