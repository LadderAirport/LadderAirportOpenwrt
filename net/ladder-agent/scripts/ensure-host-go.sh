#!/bin/sh
# ensure-host-go.sh <go.mod> <cache-dir>
#
# Prints one line on stdout: "<go-binary> <GOROOT>".
# The OpenWrt SDK's host Go is too old for agent/go.mod (24.10 ships 1.23;
# 19.07-era SDKs ship a Go that predates GOTOOLCHAIN). When the host toolchain
# is older than the go line, this downloads that exact official Linux toolchain
# into the cache, checks the published SHA-256, and prints its binary.
# A host toolchain that is already new enough is used as-is.
set -eu

gomod=${1:-}
cache=${2:-}

if [ -z "$gomod" ] || [ ! -f "$gomod" ] || [ -z "$cache" ]; then
	echo "usage: ensure-host-go.sh <go.mod> <cache-dir>" >&2
	exit 1
fi

# Lowest version is printed first. Equal versions count as "a >= b".
version_ge() {
	lowest=$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)
	[ "$lowest" = "$2" ]
}

go_line=$(awk '/^go [0-9]/ { print $2; exit }' "$gomod")
toolchain_line=$(awk '/^toolchain go/ { sub(/^go/, "", $2); print $2; exit }' "$gomod")
required=$go_line
if [ -n "$toolchain_line" ] && ! version_ge "$go_line" "$toolchain_line"; then
	required=$toolchain_line
fi
if [ -z "$required" ]; then
	echo "ensure-host-go: no go version in $gomod" >&2
	exit 1
fi

host_bin=$(command -v go 2>/dev/null || true)
host_ver=
if [ -n "$host_bin" ]; then
	host_ver=$(GOTOOLCHAIN=local "$host_bin" version 2>/dev/null | awk '{ print $3; exit }' | sed 's/^go//')
fi

if [ -n "$host_ver" ] && version_ge "$host_ver" "$required"; then
	goroot=$(GOTOOLCHAIN=local "$host_bin" env GOROOT)
	printf '%s %s\n' "$host_bin" "$goroot"
	exit 0
fi

machine=$(uname -m)
case "$machine" in
x86_64) goarch=amd64 ;;
aarch64 | arm64) goarch=arm64 ;;
*)
	echo "ensure-host-go: unsupported build host $machine" >&2
	exit 1
	;;
esac

name="go${required}.linux-${goarch}"
mkdir -p "$cache"
dest="$cache/$name"
go_bin="$dest/go/bin/go"

fetch() {
	url=$1
	out=$2
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 300 -o "$out" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$out" "$url"
	else
		echo "ensure-host-go: curl or wget is required to fetch $name" >&2
		exit 1
	fi
}

file_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$1" | awk '{ print $NF }'
	else
		echo "ensure-host-go: sha256sum or openssl is required" >&2
		exit 1
	fi
}

if [ ! -x "$go_bin" ]; then
	tarball="$cache/${name}.tar.gz"
	sumfile="$cache/${name}.tar.gz.sha256"
	partial="$tarball.partial"
	echo "ensure-host-go: host go ${host_ver:-missing} < ${required}; fetching ${name}" >&2
	# go.dev/dl/*.sha256 is an HTML documentation redirect. The published
	# checksum is the 64-char file on the Google mirror.
	fetch "https://dl.google.com/go/${name}.tar.gz.sha256" "$sumfile"
	expected=$(awk 'NF { print $1; exit }' "$sumfile" | tr 'A-F' 'a-f')
	case "$expected" in
	*[!0-9a-f]* | "")
		echo "ensure-host-go: checksum file has no SHA-256" >&2
		exit 1
		;;
	esac
	if [ ! -f "$tarball" ] || [ "$(file_sha256 "$tarball")" != "$expected" ]; then
		fetch "https://dl.google.com/go/${name}.tar.gz" "$partial" \
			|| fetch "https://go.dev/dl/${name}.tar.gz" "$partial"
		mv "$partial" "$tarball"
	fi
	actual=$(file_sha256 "$tarball")
	if [ "$actual" != "$expected" ]; then
		echo "ensure-host-go: SHA-256 mismatch for ${name}" >&2
		echo "  expected $expected" >&2
		echo "  actual   $actual" >&2
		exit 1
	fi
	rm -rf "$dest"
	mkdir -p "$dest"
	tar -C "$dest" -xzf "$tarball"
fi

if [ ! -x "$go_bin" ]; then
	echo "ensure-host-go: $go_bin missing after extract" >&2
	exit 1
fi

got=$(GOTOOLCHAIN=local "$go_bin" version 2>/dev/null | awk '{ print $3; exit }' | sed 's/^go//')
if [ "$got" != "$required" ]; then
	echo "ensure-host-go: $go_bin reports go${got}, want go${required}" >&2
	exit 1
fi

printf '%s %s\n' "$go_bin" "$dest/go"
