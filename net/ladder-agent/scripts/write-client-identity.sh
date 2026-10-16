#!/bin/sh
# write-client-identity.sh <version-package-dir>
#
# The main repo's agent/internal/version package is the source of truth for
# these names:
#   ClientType, ClientVersion, LuciVersion
# Until that package declares each one, write the missing string vars so
# the OpenWrt ldflags (-X version.ClientType / version.ClientVersion) and
# the startup LuCI read (version.LuciVersion) compile. When upstream adds
# the same declarations, this file is not emitted.
set -eu

dir=${1:-}
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
	echo "usage: write-client-identity.sh <version-package-dir>" >&2
	exit 1
fi

out=$dir/openwrt_client_identity.go

has_var() {
	name=$1
	for f in "$dir"/*.go; do
		[ -f "$f" ] || return 1
		base=${f##*/}
		case "$base" in
		openwrt_client_identity.go | openwrt_luci.go | zzz_openwrt_luci.go) continue ;;
		esac
		# A declaration, including one field inside a var ( ) group.
		# Assignments in functions are indented too, but those files are
		# upstream; if the name is assigned there the var already exists
		# in that package or the build is already broken.
		if grep -E -q "^var ${name}([[:space:]]|=)|^[[:space:]]+${name}[[:space:]]*(\"|string|=)" "$f"; then
			return 0
		fi
	done
	return 1
}

missing=""
for name in ClientType ClientVersion LuciVersion; do
	if ! has_var "$name"; then
		missing="$missing $name"
	fi
done

if [ -z "$missing" ]; then
	rm -f "$out"
	exit 0
fi

{
	printf '%s\n' 'package version'
	printf '\n'
	printf '%s\n' '// OpenWrt feed fill-in for version symbols the linked LadderAirport'
	printf '%s\n' '// tree does not declare yet. Names match that package, so the ldflags'
	printf '%s\n' '// stay valid after upstream adds them; this file is then omitted.'
	for name in $missing; do
		printf '\n'
		case "$name" in
		ClientType)
			printf '%s\n' '// ClientType is the closed client enum. OpenWrt builds set "openwrt".'
			printf '%s\n' 'var ClientType = ""'
			;;
		ClientVersion)
			printf '%s\n' '// ClientVersion is the feed package, PKG_VERSION-rPKG_RELEASE.'
			printf '%s\n' 'var ClientVersion = ""'
			;;
		LuciVersion)
			printf '%s\n' '// LuciVersion is filled at process start from the LuCI opkg control.'
			printf '%s\n' '// Empty means luci-app-ladder-agent is not installed; reporters omit it.'
			printf '%s\n' 'var LuciVersion = ""'
			;;
		esac
	done
} >"$out"

if command -v gofmt >/dev/null 2>&1; then
	gofmt -w "$out"
fi
