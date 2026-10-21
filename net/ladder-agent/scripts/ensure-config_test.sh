#!/bin/sh
# Upgrade and fresh-install coverage for ensure-config.sh.
# The upgrade case copies the live file aside, deletes it the way opkg
# deletes an obsolete conffile, then restores it and fills missing options.
# shellcheck shell=sh
set -eu

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
ensure=$root/files/ensure-config.sh
defaults=$root/files/ladder-agent.defaults
mf=$root/Makefile
fail=0

ok() { printf 'ok  %s\n' "$1"; }
bad() {
	printf 'FAIL %s\n' "$1" >&2
	fail=1
}

if grep -q '^PKG_RELEASE:=4$' "$mf"; then
	ok "PKG_RELEASE is 4"
else
	bad "PKG_RELEASE is 4"
fi
if grep -q 'Package/ladder-agent/conffiles' "$mf"; then
	bad "conffiles section is gone"
else
	ok "conffiles section is gone"
fi
if grep -q 'INSTALL_CONF' "$mf"; then
	bad "config is not installed with INSTALL_CONF"
else
	ok "config is not installed with INSTALL_CONF"
fi
if grep -q '/etc/config/ladder-agent' "$mf" && grep -q 'cp -f /etc/config/ladder-agent /tmp/ladder-agent.config.preserve' "$mf"; then
	ok "preinst preserves the live config"
else
	bad "preinst preserves the live config"
fi
if grep -q 'Package/ladder-agent/postrm' "$mf"; then
	bad "postrm must not be defined"
else
	ok "postrm must not be defined"
fi
if grep -q 'ladder-agent.defaults' "$mf" && grep -q 'uci-defaults/50-ladder-agent' "$mf"; then
	ok "defaults and uci-defaults are installed"
else
	bad "defaults and uci-defaults are installed"
fi
if grep -q '^exit' "$root/files/50-ladder-agent"; then
	bad "uci-defaults must not exit when sourced"
else
	ok "uci-defaults must not exit when sourced"
fi
if ! grep -q '/tmp/ladder-agent.config.preserve' "$ensure"; then
	bad "ensure-config restore path"
else
	ok "ensure-config restore path"
fi

base=$(mktemp -d /tmp/ensure-config-test.XXXXXX)
BIN=$base/bin
mkdir -p "$BIN"

cat >"$BIN/uci" <<'EOF'
#!/usr/bin/env python3
import os
import re
import sys

args = sys.argv[1:]
directory = None
positional = []
i = 0
while i < len(args):
    a = args[i]
    if a == "-c":
        i += 1
        directory = args[i]
    elif a == "-q":
        pass
    elif a.startswith("-"):
        sys.stderr.write("uci mock: bad flag %s\n" % a)
        sys.exit(2)
    else:
        positional.append(a)
    i += 1

if not directory or not positional:
    sys.stderr.write("uci mock: usage\n")
    sys.exit(2)

cmd = positional[0]
rest = positional[1:]
path = os.path.join(directory, "ladder-agent")

def unquote(raw):
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "'\"":
        return raw[1:-1]
    return raw

def load(path):
    exists = False
    options = []
    lists = []
    if not os.path.isfile(path):
        return exists, options, lists
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("config "):
                exists = True
                continue
            match = re.match(r"(option|list)\s+(\S+)\s*(.*)$", line)
            if not match:
                continue
            kind, key, raw = match.group(1), match.group(2), unquote(match.group(3).strip())
            if kind == "option":
                options.append((key, raw))
            else:
                lists.append((key, raw))
    return exists, options, lists

def save(path, options, lists):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write("config ladder-agent 'main'\n")
        for key, val in options:
            fh.write("\toption %s '%s'\n" % (key, val))
        for key, val in lists:
            fh.write("\tlist %s '%s'\n" % (key, val))

def has_key(rows, key):
    for name, _val in rows:
        if name == key:
            return True
    return False

exists, options, lists = load(path)

if cmd == "get":
    parts = rest[0].split(".")
    if len(parts) == 2:
        if not exists:
            sys.exit(1)
        sys.stdout.write("ladder-agent\n")
        sys.exit(0)
    if len(parts) != 3:
        sys.exit(1)
    name = parts[2]
    for key, val in options:
        if key == name:
            sys.stdout.write(val + "\n")
            sys.exit(0)
    found = [val for key, val in lists if key == name]
    if found:
        sys.stdout.write("\n".join(found) + "\n")
        sys.exit(0)
    sys.exit(1)

if cmd == "set":
    key, val = rest[0].split("=", 1)
    parts = key.split(".")
    if len(parts) == 2:
        if exists:
            sys.stderr.write("refusing to replace section\n")
            sys.exit(2)
        save(path, options, lists)
        sys.exit(0)
    if len(parts) != 3:
        sys.exit(2)
    name = parts[2]
    if has_key(options, name) or has_key(lists, name):
        sys.stderr.write("refusing to replace %s\n" % name)
        sys.exit(2)
    options.append((name, val))
    save(path, options, lists)
    sys.exit(0)

if cmd == "add_list":
    key, val = rest[0].split("=", 1)
    parts = key.split(".")
    if len(parts) != 3:
        sys.exit(2)
    name = parts[2]
    if has_key(lists, name) or has_key(options, name):
        sys.stderr.write("refusing to replace list %s\n" % name)
        sys.exit(2)
    lists.append((name, val))
    save(path, options, lists)
    sys.exit(0)

if cmd == "commit":
    if os.path.isfile(path) or options or lists:
        save(path, options, lists)
    sys.exit(0)

sys.stderr.write("uci mock: bad cmd %s\n" % cmd)
sys.exit(2)
EOF
chmod +x "$BIN/uci"

apply() {
	shell_bin=$1
	cfg=$2
	preserve=$3
	if [ "$shell_bin" = "busybox" ]; then
		PATH="$BIN:/usr/bin:/bin" \
			LADDER_DEFAULTS="$defaults" \
			LADDER_UCI_CONFIG="$cfg" \
			LADDER_CONFIG_PRESERVE="$preserve" \
			busybox ash "$ensure"
	else
		PATH="$BIN:/usr/bin:/bin" \
			LADDER_DEFAULTS="$defaults" \
			LADDER_UCI_CONFIG="$cfg" \
			LADDER_CONFIG_PRESERVE="$preserve" \
			"$shell_bin" "$ensure"
	fi
}

uci_get() {
	PATH="$BIN:/usr/bin:/bin" uci -c "$(dirname "$1")" -q get "ladder-agent.main.$2"
}

run_shell() {
	shell_bin=$1
	work=$base/$shell_bin
	rm -rf "$work"
	mkdir -p "$work/etc/config" "$work/usr/share/ladder-agent" \
		"$work/usr/libexec/ladder-agent" "$work/etc/uci-defaults" \
		"$work/etc/init.d" "$work/lib/upgrade/keep.d"
	cfg=$work/etc/config/ladder-agent
	preserve=$work/preserve

	cat >"$cfg" <<'EOF'
config ladder-agent 'main'
	option enabled '1'
	option panel_url 'https://panel.example.com'
	option node_id 'node-1'
	option token 'secret-token'
	option listen '127.0.0.1:50051'
EOF
	# preinst, then opkg removes the obsolete conffile.
	cp -f "$cfg" "$preserve"
	rm -f "$cfg"
	if apply "$shell_bin" "$cfg" "$preserve"; then
		ok "upgrade apply ($shell_bin)"
	else
		bad "upgrade apply ($shell_bin)"
		return
	fi
	if [ "$(uci_get "$cfg" enabled)" = "1" ]; then
		ok "upgrade keeps enabled ($shell_bin)"
	else
		bad "upgrade keeps enabled ($shell_bin)"
	fi
	if [ "$(uci_get "$cfg" token)" = "secret-token" ]; then
		ok "upgrade keeps token ($shell_bin)"
	else
		bad "upgrade keeps token ($shell_bin)"
	fi
	if [ "$(uci_get "$cfg" listen)" = "127.0.0.1:50051" ]; then
		ok "upgrade keeps listen ($shell_bin)"
	else
		bad "upgrade keeps listen ($shell_bin)"
	fi
	if [ "$(uci_get "$cfg" panel_url)" = "https://panel.example.com" ]; then
		ok "upgrade keeps panel_url ($shell_bin)"
	else
		bad "upgrade keeps panel_url ($shell_bin)"
	fi
	if [ "$(uci_get "$cfg" uplink)" = "1" ]; then
		ok "upgrade adds uplink ($shell_bin)"
	else
		bad "upgrade adds uplink ($shell_bin)"
	fi
	if uci_get "$cfg" egress_interface >/dev/null; then
		ok "upgrade adds egress_interface ($shell_bin)"
	else
		bad "upgrade adds egress_interface ($shell_bin)"
	fi
	if [ -z "$(uci_get "$cfg" egress_interface)" ]; then
		ok "egress_interface default is empty ($shell_bin)"
	else
		bad "egress_interface default is empty ($shell_bin)"
	fi
	if [ ! -f "$preserve" ]; then
		ok "preserve file removed ($shell_bin)"
	else
		bad "preserve file removed ($shell_bin)"
	fi

	# opkg remove deletes packaged paths only. The UCI file is not one of them.
	rm -f "$work/usr/libexec/ladder-agent/ensure-config" \
		"$work/etc/uci-defaults/50-ladder-agent" \
		"$work/usr/share/ladder-agent/ladder-agent.defaults" \
		"$work/etc/init.d/ladder-agent" \
		"$work/lib/upgrade/keep.d/ladder-agent"
	if [ -f "$cfg" ] && [ "$(uci_get "$cfg" token)" = "secret-token" ]; then
		ok "package removal keeps config ($shell_bin)"
	else
		bad "package removal keeps config ($shell_bin)"
	fi

	rm -rf "$work/etc/config"
	mkdir -p "$work/etc/config"
	preserve=$work/preserve-fresh
	rm -f "$preserve"
	if apply "$shell_bin" "$cfg" "$preserve"; then
		ok "fresh install ($shell_bin)"
	else
		bad "fresh install ($shell_bin)"
		return
	fi
	if [ "$(uci_get "$cfg" enabled)" = "0" ] && [ "$(uci_get "$cfg" listen)" = "0.0.0.0:50051" ]; then
		ok "fresh install defaults ($shell_bin)"
	else
		bad "fresh install defaults ($shell_bin)"
	fi
	if [ "$(uci_get "$cfg" uplink_ws)" = "1" ] && [ "$(uci_get "$cfg" log_stderr)" = "1" ]; then
		ok "fresh install remaining defaults ($shell_bin)"
	else
		bad "fresh install remaining defaults ($shell_bin)"
	fi

	# Live file wins when opkg left it in place and preinst also saved a copy.
	printf '%s\n' "config ladder-agent 'main'" "	option token 'kept-token'" "	option enabled '1'" >"$cfg"
	cp -f "$cfg" "$preserve"
	if apply "$shell_bin" "$cfg" "$preserve"; then
		ok "existing file apply ($shell_bin)"
	else
		bad "existing file apply ($shell_bin)"
		return
	fi
	if [ "$(uci_get "$cfg" token)" = "kept-token" ] && [ "$(uci_get "$cfg" enabled)" = "1" ] && [ "$(uci_get "$cfg" uplink)" = "1" ]; then
		ok "existing file keeps values and adds missing ($shell_bin)"
	else
		bad "existing file keeps values and adds missing ($shell_bin)"
	fi
}

run_shell sh
if command -v dash >/dev/null 2>&1; then
	run_shell dash
fi
if command -v busybox >/dev/null 2>&1; then
	run_shell busybox
fi

rm -rf "$base"

if [ "$fail" -eq 0 ]; then
	printf '%s\n' "all ensure-config checks passed"
else
	printf '%s\n' "ensure-config checks failed" >&2
	exit 1
fi
