#!/bin/sh
# Exercises core-version formatting, the version-package fill-in, and ldflags.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
core=$root/scripts/core-identity.sh
write=$root/scripts/write-client-identity.sh
fail=0

ok() { printf 'ok  %s\n' "$1"; }
bad() {
	printf 'FAIL %s\n' "$1" >&2
	fail=1
}

# describe invocations must not request --abbrev=0. Mentions in comments are fine
# when they are not the flag attached to describe.
if grep -E 'describe --(tags --)?abbrev=0' "$core" "$root/Makefile" >/dev/null; then
	bad "describe --abbrev=0 is present"
else
	ok "describe does not use --abbrev=0"
fi

if ! grep -q 'version.Version=$(LADDER_CORE_VERSION)' "$root/Makefile"; then
	bad "Version ldflag is not the core version"
else
	ok "Version ldflag uses core version"
fi
if grep -q "version.Version=\$(PKG_VERSION)" "$root/Makefile"; then
	bad "Version ldflag still uses PKG_VERSION"
else
	ok "Version ldflag is not PKG_VERSION"
fi
if ! grep -q 'version.ClientType=$(LADDER_CLIENT_TYPE)' "$root/Makefile"; then
	bad "ClientType ldflag missing"
else
	ok "ClientType ldflag present"
fi
if ! grep -q 'version.ClientVersion=$(LADDER_CLIENT_VERSION)' "$root/Makefile"; then
	bad "ClientVersion ldflag missing"
else
	ok "ClientVersion ldflag present"
fi
if ! grep -q 'LADDER_CLIENT_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)' "$root/Makefile"; then
	bad "client version is not PKG_VERSION-rPKG_RELEASE"
else
	ok "client version formula"
fi
if ! grep -q '\$\$\$\$VERSION_LDFLAGS' "$root/Makefile" || ! grep -q '\$\$\$\$SINGBOX_VER' "$root/Makefile"; then
	bad "shell dollars in Build/Compile are not escaped"
else
	ok "Build/Compile dollar escaping"
fi

repo=$(mktemp -d)
git -C "$repo" init -q
git -C "$repo" config user.email "identity-test@example.com"
git -C "$repo" config user.name "identity-test"
echo a >"$repo/f"
git -C "$repo" add f
git -C "$repo" commit -q -m a
git -C "$repo" tag v0.15.12

got=$("$core" version "$repo")
abbrev0=$(git -C "$repo" describe --tags --abbrev=0)
if [ "$got" = "v0.15.12" ] && [ "$got" = "$abbrev0" ]; then
	ok "on tag, core version is v0.15.12"
else
	bad "on tag: got=$got abbrev0=$abbrev0"
fi
short=$(git -C "$repo" rev-parse --short HEAD)
if [ "$("$core" commit "$repo")" = "$short" ]; then
	ok "core commit matches rev-parse --short"
else
	bad "commit mismatch"
fi

echo b >"$repo/f"
git -C "$repo" add f
git -C "$repo" commit -q -m b
got=$("$core" version "$repo")
plain=$(git -C "$repo" describe --tags --always)
abbrev0=$(git -C "$repo" describe --tags --abbrev=0)
# The embedded SHA is this commit, not the tagged one.
short=$(git -C "$repo" rev-parse --short HEAD)
if [ "$got" = "$plain" ] && [ "$got" != "$abbrev0" ] && [ "$got" = "v0.15.12-1-g${short}" ]; then
	ok "ahead of tag keeps distance: $got"
else
	bad "ahead of tag: got=$got plain=$plain abbrev0=$abbrev0 short=$short"
fi
if [ "$("$core" commit "$repo")" = "$short" ]; then
	ok "commit follows HEAD after the extra commit"
else
	bad "commit did not follow HEAD"
fi

bare=$(mktemp -d)
git -C "$bare" init -q
git -C "$bare" config user.email "identity-test@example.com"
git -C "$bare" config user.name "identity-test"
echo a >"$bare/f"
git -C "$bare" add f
git -C "$bare" commit -q -m a
git -C "$bare" tag 0.15.9
if [ "$("$core" version "$bare")" = "v0.15.9" ]; then
	ok "untagged-v describe gains a leading v"
else
	bad "leading v: $("$core" version "$bare")"
fi

if [ "$("$core" version /nonexistent)" = "v0.0.0" ] && [ "$("$core" commit /nonexistent)" = "unknown" ]; then
	ok "missing checkout falls back"
else
	bad "missing checkout fallback"
fi

# Fill-in declarations.
verdir=$(mktemp -d)
cat >"$verdir/version.go" <<'EOF'
package version

var Version = "0.1.0-dev"
var Commit = "unknown"
var BuiltAt = "unknown"
EOF
sh "$write" "$verdir"
fill_ok=1
for name in ClientType ClientVersion LuciVersion; do
	if ! grep -q "var ${name} = \"\"" "$verdir/openwrt_client_identity.go"; then
		bad "missing fill-in for $name"
		fill_ok=0
	fi
done
if [ "$fill_ok" -eq 1 ]; then
	ok "fill-in declares ClientType ClientVersion LuciVersion"
fi

# Names that merely share a prefix are not the symbols.
prefix=$(mktemp -d)
cat >"$prefix/version.go" <<'EOF'
package version

var ClientTypeExtra = ""
var ClientVersionExtra = ""
EOF
sh "$write" "$prefix"
if grep -q 'var ClientType = ""' "$prefix/openwrt_client_identity.go" \
	&& grep -q 'var ClientVersion = ""' "$prefix/openwrt_client_identity.go"; then
	ok "prefix names do not satisfy the symbols"
else
	bad "prefix names were treated as the real symbols"
fi

# The startup hook assigns LuciVersion. That assignment is not a declaration.
hookdir=$(mktemp -d)
cp "$verdir/version.go" "$hookdir/version.go"
cp "$root/files/version/openwrt_luci.go" "$hookdir/zzz_openwrt_luci.go"
sh "$write" "$hookdir"
if [ -f "$hookdir/openwrt_client_identity.go" ] \
	&& grep -q 'var ClientType = ""' "$hookdir/openwrt_client_identity.go" \
	&& grep -q 'var LuciVersion = ""' "$hookdir/openwrt_client_identity.go"; then
	ok "LuCI hook assignment does not count as a declaration"
else
	bad "LuCI hook hid a version declaration"
	cat "$hookdir/openwrt_client_identity.go" >&2 || true
fi

# Partial upstream: only LuciVersion still missing.
partial=$(mktemp -d)
cat >"$partial/version.go" <<'EOF'
package version

var ClientType = "linux"
var ClientVersion = ""
EOF
sh "$write" "$partial"
if grep -q 'var LuciVersion = ""' "$partial/openwrt_client_identity.go" \
	&& ! grep -q 'var ClientType ' "$partial/openwrt_client_identity.go" \
	&& ! grep -q 'var ClientVersion ' "$partial/openwrt_client_identity.go"; then
	ok "partial upstream only fills LuciVersion"
else
	bad "partial upstream fill-in was wrong"
	cat "$partial/openwrt_client_identity.go" >&2 || true
fi

# Full upstream: do not emit a second declaration.
full=$(mktemp -d)
cat >"$full/version.go" <<'EOF'
package version

var (
	ClientType    = "linux"
	ClientVersion = ""
	LuciVersion   = ""
)
EOF
echo 'package version' >"$full/openwrt_client_identity.go"
sh "$write" "$full"
if [ ! -f "$full/openwrt_client_identity.go" ]; then
	ok "full upstream omits the fill-in"
else
	bad "fill-in was written even though upstream declares the vars"
fi

# ldflags against a stub of the agent version package.
if ! command -v go >/dev/null 2>&1; then
	bad "go is not installed"
else
	mod=$(mktemp -d)
	mkdir -p "$mod/internal/version" "$mod/internal/openwrtversion" "$mod/cmd/printver"
	cp "$root/openwrtversion/luci.go" "$mod/internal/openwrtversion/luci.go"
	cp "$root/files/version/openwrt_luci.go" "$mod/internal/version/openwrt_luci.go"
	cp "$verdir/version.go" "$mod/internal/version/version.go"
	cp "$verdir/openwrt_client_identity.go" "$mod/internal/version/openwrt_client_identity.go"
	cat >"$mod/go.mod" <<'EOF'
module github.com/ladderairport/agent

go 1.22
EOF
	cat >"$mod/cmd/printver/main.go" <<'EOF'
package main

import (
	"fmt"

	"github.com/ladderairport/agent/internal/version"
)

func main() {
	fmt.Printf("version=%s\n", version.Version)
	fmt.Printf("commit=%s\n", version.Commit)
	fmt.Printf("client_type=%s\n", version.ClientType)
	fmt.Printf("client_version=%s\n", version.ClientVersion)
	fmt.Printf("luci_version=%s\n", version.LuciVersion)
}
EOF
	ldflags="-X github.com/ladderairport/agent/internal/version.Version=v0.15.12"
	ldflags="$ldflags -X github.com/ladderairport/agent/internal/version.Commit=2372916"
	ldflags="$ldflags -X github.com/ladderairport/agent/internal/version.ClientType=openwrt"
	ldflags="$ldflags -X github.com/ladderairport/agent/internal/version.ClientVersion=0.15.12-r2"
	if ! (cd "$mod" && GOPROXY=off go build -o "$mod/printver" -ldflags "$ldflags" ./cmd/printver); then
		bad "stub agent failed to link client ldflags"
	else
		got=$("$mod/printver")
		want="version=v0.15.12
commit=2372916
client_type=openwrt
client_version=0.15.12-r2
luci_version="
		if [ "$got" = "$want" ]; then
			ok "ldflags set core, client_type, client_version; absent LuCI stays empty"
		else
			bad "printver output:
$got"
		fi
	fi

	# Upstream already declared the symbols: fill-in stays out, ldflags still win.
	up=$(mktemp -d)
	mkdir -p "$up/internal/version" "$up/internal/openwrtversion" "$up/cmd/printver"
	cp "$root/openwrtversion/luci.go" "$up/internal/openwrtversion/luci.go"
	cp "$root/files/version/openwrt_luci.go" "$up/internal/version/openwrt_luci.go"
	cp "$full/version.go" "$up/internal/version/version.go"
	# version.go above is only the three client vars. Add Version and Commit.
	cat >"$up/internal/version/version.go" <<'EOF'
package version

var Version = "0.1.0-dev"
var Commit = "unknown"
var BuiltAt = "unknown"
var ClientType = "linux"
var ClientVersion = ""
var LuciVersion = ""
EOF
	sh "$write" "$up/internal/version"
	if [ -f "$up/internal/version/openwrt_client_identity.go" ]; then
		bad "fill-in emitted beside an upstream declaration"
	fi
	cp "$mod/go.mod" "$up/go.mod"
	cp "$mod/cmd/printver/main.go" "$up/cmd/printver/main.go"
	if ! (cd "$up" && GOPROXY=off go build -o "$up/printver" -ldflags "$ldflags" ./cmd/printver); then
		bad "upstream-shaped version package failed to link"
	else
		got=$("$up/printver")
		if [ "$got" = "$want" ]; then
			ok "ldflags override upstream defaults"
		else
			bad "upstream-shaped output:
$got"
		fi
	fi

	tdir=$(mktemp -d)
	mkdir -p "$tdir/openwrtversion" "$tdir/openwrtbind"
	cp "$root/openwrtversion/"*.go "$tdir/openwrtversion/"
	cp "$root/openwrtbind/"*.go "$tdir/openwrtbind/"
	printf 'module test.local/feed\n\ngo 1.22\n' >"$tdir/go.mod"
	if ! (cd "$tdir" && GOPROXY=off go test ./openwrtversion/ ./openwrtbind/); then
		bad "package tests"
	else
		ok "openwrtversion and openwrtbind tests"
	fi
fi

rm -rf "$repo" "$bare"
if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "all identity checks passed"
