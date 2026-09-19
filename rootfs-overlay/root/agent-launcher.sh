#!/bin/ash
# Boot the opencode agent TUI on the guest console.
#
# First run on a fresh rootfs: fetch the pinned opencode binary through vec0,
# then ask once for the AI endpoint base URL, API key and model. The key is
# read with echo off and lands only in /root/endpoint.env (chmod 600); it is
# never printed and is handed to opencode through an env-var indirection, so
# the generated config file holds a reference, not the secret.
#
# Steady state: exec opencode straight away. If anything fails (no network,
# fetch error, config), drop to a shell so the console still works.
#
# The guest runs as root on a private kernel; /root here is guest-local
# storage, not the phone's.

set -u
# The kernel hands the console a vt102 default; the TUI needs the full
# xterm set (256col, alt screen).
export TERM=xterm-256color
BIN=/root/bin/opencode
ENVF=/root/endpoint.env
CFG=/root/.config/opencode/opencode.json
VER=v1.18.31
TARBALL=opencode-linux-arm64-musl.tar.gz
# sha256 of $TARBALL at $VER; the fetch fails loudly on a mismatch.
SHA=20f548107dd3307437594ad4344f9dac2e2264c26ea03d946db461f73c2d1bf0

die() { echo "agent-launcher: $*"; exec /bin/ash; }

# Opt out of the agent TUI: touch /root/no-agent and this boot just gives
# you a login shell. Remove the file to come back.
if [ -e /root/no-agent ]; then
	exec /bin/ash -l
fi

# The -musl build still links against libstdc++/libgcc for its C++ deps.
if [ ! -e /usr/lib/libstdc++.so.6 ]; then
	echo "agent-launcher: installing libstdc++/libgcc..."
	apk add --no-cache libstdc++ libgcc 2>&1 | tail -1 \
		|| die "apk add failed (no network?)"
fi

if [ ! -x "$BIN" ]; then
	echo "agent-launcher: fetching opencode $VER through vec0 (~62 MB)..."
	mkdir -p /root/bin /tmp/oc
	# haven-net runs concurrently in init; give vec0 a moment to get its
	# lease before the first fetch.
	i=0
	while [ $i -lt 15 ] && ! ip route | grep -q default; do
		sleep 1; i=$((i+1))
	done
	wget -q -O /tmp/oc.tar.gz \
		"https://github.com/anomalyco/opencode/releases/download/$VER/$TARBALL" \
		|| die "fetch failed"
	if [ -n "$SHA" ]; then
		echo "$SHA  /tmp/oc.tar.gz" | sha256sum -c - >/dev/null \
			|| die "sha256 mismatch for $TARBALL"
	fi
	tar -xzf /tmp/oc.tar.gz -C /tmp/oc || die "untar failed"
	mv /tmp/oc/opencode "$BIN" 2>/dev/null || mv /tmp/oc/opencode-* "$BIN" \
		|| die "binary not found in tarball"
	rm -rf /tmp/oc /tmp/oc.tar.gz
fi

if [ ! -f "$ENVF" ]; then
	echo "AI endpoint base URL (incl. /v1, e.g. https://api.nexos.ai/v1):"
	IFS= read -r base
	[ -n "$base" ] || die "empty base URL"
	echo "API key (input hidden):"
	stty -echo 2>/dev/null
	IFS= read -r key
	stty echo 2>/dev/null
	echo
	[ -n "$key" ] || die "empty key"
	echo "Model id (e.g. Qwen 3.8 Max):"
	IFS= read -r model
	[ -n "$model" ] || die "empty model"
	umask 077
	{
		printf 'AGENT_ENDPOINT_BASE=%s\n' "$base"
		printf 'AGENT_ENDPOINT_KEY=%s\n' "$key"
		printf 'AGENT_MODEL=%s\n' "$model"
	} > "$ENVF"
	chmod 600 "$ENVF"
	echo "agent-launcher: endpoint saved to $ENVF (chmod 600)"
fi

. "$ENVF"
[ -n "${AGENT_ENDPOINT_KEY:-}" ] || die "no key in $ENVF"

mkdir -p /root/.config/opencode
{
	printf '%s\n' '{'
	printf '  "$schema": "https://opencode.ai/config.json",\n'
	printf '  "model": "endpoint/%s",\n' "$AGENT_MODEL"
	printf '  "provider": {\n'
	printf '    "endpoint": {\n'
	printf '      "npm": "@ai-sdk/openai-compatible",\n'
	printf '      "name": "Endpoint",\n'
	printf '      "options": {\n'
	printf '        "baseURL": "%s",\n' "$AGENT_ENDPOINT_BASE"
	printf '        "apiKey": "{env:AGENT_ENDPOINT_KEY}"\n'
	printf '      },\n'
	printf '      "models": {\n'
	printf '        "%s": { "name": "%s" }\n' "$AGENT_MODEL" "$AGENT_MODEL"
	printf '      }\n'
	printf '    }\n'
	printf '  }\n'
	printf '%s\n' '}'
} > "$CFG"

export AGENT_ENDPOINT_BASE AGENT_ENDPOINT_KEY AGENT_MODEL
cd /root
# On exit hand the console to a shell; logging out respawns the launcher,
# so the tab cycles TUI -> shell -> TUI and never locks the user out.
"$BIN" || true
exec /bin/ash
