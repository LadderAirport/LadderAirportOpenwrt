#!/bin/sh
# core-identity.sh version|commit <ladder-src>
#
# version: core version from `git describe --tags --always`.
#   On a tag this is vX.Y.Z. Otherwise it is vX.Y.Z-N-gSHA.
#   Never pass --abbrev=0; that drops the commit distance and pretends a
#   non-tag checkout is the tag.
# commit: short SHA of that same checkout (`git rev-parse --short`).
#   This is core_commit. It is not parsed back out of the describe string.
set -eu

mode=${1:-}
src=${2:-}

fallback() {
	if [ "$mode" = "commit" ]; then
		printf '%s\n' unknown
	else
		printf '%s\n' v0.0.0
	fi
}

if [ "$mode" != "version" ] && [ "$mode" != "commit" ]; then
	echo "usage: core-identity.sh version|commit <ladder-src>" >&2
	exit 1
fi

if [ -z "$src" ] || [ ! -e "$src/.git" ] || ! command -v git >/dev/null 2>&1; then
	fallback
	exit 0
fi

case "$mode" in
commit)
	sha=$(git -C "$src" rev-parse --short HEAD 2>/dev/null || true)
	if [ -z "$sha" ]; then
		printf '%s\n' unknown
	else
		printf '%s\n' "$sha"
	fi
	;;
version)
	# --tags --always, default abbrev. Do not add --abbrev=0 or --long.
	desc=$(git -C "$src" describe --tags --always 2>/dev/null || true)
	case "$desc" in
	v*)
		printf '%s\n' "$desc"
		;;
	"")
		printf '%s\n' v0.0.0
		;;
	*)
		printf 'v%s\n' "$desc"
		;;
	esac
	;;
esac
