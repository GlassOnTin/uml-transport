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
ENVBAK=/host/endpoint.env
CFG=/root/.config/opencode/opencode.json
VER=v1.18.31
TARBALL=opencode-linux-arm64-musl.tar.gz
# sha256 of $TARBALL at $VER; the fetch fails loudly on a mismatch.
SHA=20f548107dd3307437594ad4344f9dac2e2264c26ea03d946db461f73c2d1bf0

die() { echo "agent-launcher: $*"; exec /bin/ash; }

# Ask once for the endpoint and save it. Values are written single-quoted
# so ids with spaces ("Qwen 3.8 Max") survive sourcing; an embedded '
# becomes '\''.
prompt_endpoint() {
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
		printf 'AGENT_ENDPOINT_BASE='; sq_write "$base"; printf '\n'
		printf 'AGENT_ENDPOINT_KEY=';  sq_write "$key";  printf '\n'
		printf 'AGENT_MODEL=';         sq_write "$model"; printf '\n'
	} > "$ENVF"
	chmod 600 "$ENVF"
	echo "agent-launcher: endpoint saved to $ENVF (chmod 600)"
}

# Emit $1 single-quoted, safe to source.
sq_write() {
	printf "'"
	printf '%s' "$1" | sed "s/'/'\\\\''/g"
	printf "'"
}

# Opt out of the agent TUI: touch /root/no-agent and this boot just gives
# you a login shell. Remove the file to come back.
if [ -e /root/no-agent ]; then
	exec /bin/ash -l
fi

# Escape hatch when the TUI owns the console and you cannot reach a shell:
# create agent-shell in the share (Haven Files -> uml share), then reconnect
# the guest. This boot gives a login shell and removes the flag.
if [ -e /host/agent-shell ]; then
	rm -f /host/agent-shell
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

if [ ! -f "$ENVF" ] && [ -f "$ENVBAK" ]; then
	# The rootfs image was re-staged (a rootfs update wipes guest data);
	# restore the endpoint from the share backup instead of re-prompting.
	cp "$ENVBAK" "$ENVF"
	chmod 600 "$ENVF"
	echo "agent-launcher: endpoint restored from $ENVBAK"
fi

# Older installs kept a goose-format backup instead; derive the endpoint
# from it in-guest (values never cross the console). Falls through to the
# prompt if anything is missing.
if [ ! -f "$ENVF" ] && [ -f /host/nexos.env.bak ]; then
	. /host/nexos.env.bak 2>/dev/null || true
	case "${OPENAI_HOST:-}" in
		*/v1) BASE="$OPENAI_HOST" ;;
		"")   BASE="" ;;
		*)    BASE="$OPENAI_HOST/v1" ;;
	esac
	if [ -n "${BASE:-}" ] && [ -n "${OPENAI_API_KEY:-}" ] \
		&& [ -n "${GOOSE_MODEL:-}" ]; then
		umask 077
		{
			printf 'AGENT_ENDPOINT_BASE='; sq_write "$BASE"; printf '\n'
			printf 'AGENT_ENDPOINT_KEY=';  sq_write "$OPENAI_API_KEY";  printf '\n'
			printf 'AGENT_MODEL=';         sq_write "$GOOSE_MODEL";     printf '\n'
		} > "$ENVF"
		chmod 600 "$ENVF"
		echo "agent-launcher: endpoint.env restored from /host/nexos.env.bak"
	fi
	unset OPENAI_HOST OPENAI_API_KEY GOOSE_MODEL BASE
fi

if [ ! -f "$ENVF" ]; then
	prompt_endpoint
	# Back it up outside the rootfs image so a re-stage keeps the key.
	if [ -d /host ]; then
		cp "$ENVF" "$ENVBAK"
		chmod 600 "$ENVBAK"
	fi
fi

# Source the saved endpoint. Values are written single-quoted (see
# sq_write), but a file edited by hand may not be; if anything is missing
# after sourcing, drop the file and ask again rather than crash-looping
# under init's respawn.
. "$ENVF" 2>/dev/null || true
if [ -z "${AGENT_ENDPOINT_BASE:-}" ] || [ -z "${AGENT_ENDPOINT_KEY:-}" ] \
	|| [ -z "${AGENT_MODEL:-}" ]; then
	echo "agent-launcher: $ENVF is malformed (unquoted values?), re-prompting"
	rm -f "$ENVF"
	unset AGENT_ENDPOINT_BASE AGENT_ENDPOINT_KEY AGENT_MODEL
	prompt_endpoint
	. "$ENVF" 2>/dev/null || true
fi
[ -n "${AGENT_ENDPOINT_KEY:-}" ] || die "no key in $ENVF"

# Haven MCP (optional): the share may carry a pairing token for Haven's
# agent endpoint. When it does, the generated config gains the Haven MCP
# server so the in-guest agent can call Haven verbs over the slirp route —
# reads are free, writes surface the usual consent sheet on the phone
# screen. The token is referenced through an env var, never baked into the
# config file, and is backed up on the share like the endpoint env so a
# re-stage keeps it.
HAVEN_URL_FILE=/root/haven-mcp.env
if [ ! -f "$HAVEN_URL_FILE" ] && [ -f /host/haven-mcp.env ]; then
	cp /host/haven-mcp.env "$HAVEN_URL_FILE"
	chmod 600 "$HAVEN_URL_FILE"
	echo "agent-launcher: haven-mcp.env restored from the share"
fi
if [ -f "$HAVEN_URL_FILE" ]; then
	. "$HAVEN_URL_FILE" 2>/dev/null || true
fi
HAVEN_MCP_URL="${HAVEN_MCP_URL:-http://169.254.2.2:8730/mcp}"

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
	if [ -n "${HAVEN_MCP_TOKEN:-}" ]; then
		printf '    },\n'
		printf '    "mcp": {\n'
		printf '      "haven": {\n'
		printf '        "type": "remote",\n'
		printf '        "url": "%s",\n' "$HAVEN_MCP_URL"
		printf '        "enabled": true,\n'
		printf '        "headers": {\n'
		printf '          "Authorization": "Bearer {env:HAVEN_MCP_TOKEN}"\n'
		printf '        }\n'
		printf '      }\n'
		printf '    }\n'
	else
		printf '    }\n'
	fi
	printf '  }\n'
	printf '%s\n' '}'
} > "$CFG"

export AGENT_ENDPOINT_BASE AGENT_ENDPOINT_KEY AGENT_MODEL
[ -n "${HAVEN_MCP_TOKEN:-}" ] && export HAVEN_MCP_TOKEN HAVEN_MCP_URL
cd /root
echo "agent-launcher: starting opencode — the first frame can take a few minutes on this device."
# Hand the TUI a raw tty: the guest line discipline defaults to ICRNL, which
# turns the terminal's \r into \n and Enter inserts a newline instead of
# submitting. inlcr also maps a \n (in case a cooked path is upstream) back
# to \r. Bracketed-paste keeps multi-line pastes intact.
stty raw -echo inlcr 2>/dev/null
# Re-broadcast SIGWINCH: the UML console forwards host-side resizes
# unreliably (the second of a rapid keyboard show/hide pair is dropped)
# and a resize made inside the guest never signals the foreground group
# at all. Poll the console size and SIGWINCH the TUI on any change; the
# loop dies with opencode so each respawn runs exactly one watcher.
(
	sleep 1
	last=""
	while :; do
		pidof opencode >/dev/null 2>&1 || exit
		size=$(stty -F /dev/console size 2>/dev/null) || { sleep 1; continue; }
		if [ -n "$last" ] && [ "$size" != "$last" ]; then
			for p in $(pidof opencode); do kill -WINCH "$p" 2>/dev/null; done
		fi
		last=$size
		sleep 0.3
	done
) &
"$BIN" || true
stty sane 2>/dev/null
# On exit hand the console to a shell; logging out respawns the launcher,
# so the tab cycles TUI -> shell -> TUI and never locks the user out.
exec /bin/ash
