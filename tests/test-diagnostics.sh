#!/usr/bin/env bash
# The diagnostics bundle must not carry a secret off the board.
#
# Whoever sends the bundle is asking for help with a board that is not working,
# and the receiver is somebody they have never met.  The NetworkManager profile
# is where the Wi-Fi password is written down, and a state file is where the
# next thing that should not be sent will turn up.  Every file below is one the
# tool really collects, reached by pointing its root at a sandbox.
#
# The script runs on the board with everything the board has; on this host most
# of the section commands are missing, and that is the first case: a bundle
# assembled from what happened to be installed is still a bundle.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly TOOL="$repo/rootfs/overlay/usr/bin/jh7110-diagnostics"
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The root the tool reads /etc from, the two directories it is told about by
# name, and the place bundles are written.
readonly ROOT="$sandbox/root"
readonly STATE_DIR="$sandbox/state"
readonly ETC_DIR="$sandbox/etc/jh7110"
mkdir -p "$ROOT/etc/NetworkManager/system-connections" \
    "$ROOT/etc/ssh/sshd_config.d" \
    "$ROOT/etc/lightdm/lightdm.conf.d" \
    "$STATE_DIR" "$ETC_DIR"

# Secrets of shapes nothing else here has, so finding one anywhere in a bundle
# is unambiguous.
readonly WIFI_PSK='correct-horse-battery-staple'
readonly SESSION_TOKEN='eyJhbGciOiJIUzI1NiJ9.a-token-that-must-not-travel'

cat > "$ROOT/etc/NetworkManager/system-connections/HomeWifi.nmconnection" <<EOF
[connection]
id=HomeWifi
uuid=11111111-2222-3333-4444-555555555555
type=wifi

[wifi]
ssid=HomeWifi

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PSK

[ipv4]
method=auto
EOF

cat > "$ROOT/etc/ssh/sshd_config.d/90-jh7110.conf" <<'EOF'
PermitRootLogin no
PasswordAuthentication no
EOF

cat > "$ROOT/etc/lightdm/lightdm.conf.d/50-jh7110.conf" <<'EOF'
[Seat:*]
greeter-session=jh7110-greeter
EOF

cat > "$ETC_DIR/board.conf" <<'EOF'
BOARD_ID=mars
BOARD_NAME='Milk-V Mars'
DEFAULT_HOSTNAME=jh7110-mars
EOF

# A file the setup wrote, holding the one thing that must not travel.
cat > "$STATE_DIR/oobe-state.json" <<EOF
{"hostname": "jh7110-mars", "locale": "zh_CN.UTF-8", "session_token": "$SESSION_TOKEN"}
EOF

cat > "$STATE_DIR/hardware.json" <<'EOF'
{"board": "mars", "checks": [{"name": "display", "status": "ok"}]}
EOF

run_tool() {
    JH7110_ROOT="$ROOT" JH7110_STATE_DIR="$STATE_DIR" JH7110_ETC="$ETC_DIR" \
        "$TOOL" "$@"
}

open_bundle() { # $1 bundle, $2 directory to unpack into
    mkdir -p "$2"
    tar -xzf "$1" -C "$2" || fail "$1 is not a readable tar"
}

# ---------------------------------------------------------------------------
# Nothing on this host is the board, and a bundle still has to be produced.
# ---------------------------------------------------------------------------
bundle="$sandbox/first.tar.gz"
run_tool -o "$bundle" || fail 'the tool failed on a host with none of the board tools'
[[ -s "$bundle" ]] || fail 'the bundle is empty'

first="$sandbox/first"
open_bundle "$bundle" "$first"
[[ -s "$first/README" ]] || fail 'the bundle has no manifest'
grep -q 'jh7110 diagnostics' "$first/README" || fail 'the manifest does not say what this is'
grep -q 'REDACTED' "$first/README" || fail 'the manifest does not say what was removed'
# A section says why it is empty.  A missing command and a command that failed
# are different diagnoses, and neither is the same as "nothing was wrong".
grep -q 'not installed\|command:' "$first/kernel-modules" \
    || fail 'a section does not say why it is empty'

# ---------------------------------------------------------------------------
# The secrets.
# ---------------------------------------------------------------------------
secrets="$sandbox/secrets"
open_bundle "$bundle" "$secrets"

for secret in "$WIFI_PSK" "$SESSION_TOKEN"; do
    if grep -rqF "$secret" "$secrets"; then
        fail "a secret is in the bundle: $(grep -rlF "$secret" "$secrets" | tr '\n' ' ')"
    fi
done
if grep -rqF 'BEGIN OPENSSH PRIVATE KEY' "$secrets"; then
    fail 'a private key is in the bundle'
fi

# Redaction that deletes the section instead of the value would pass every
# check above and still leave nothing to diagnose with, so what has to survive
# is asserted too.
grep -q 'psk=REDACTED' "$secrets/nm-connection-HomeWifi.nmconnection" \
    || fail 'the Wi-Fi profile section does not show a redacted psk'
grep -q 'ssid=HomeWifi' "$secrets/nm-connection-HomeWifi.nmconnection" \
    || fail 'redaction ate the network name it was meant to report'
grep -q 'session_token.*REDACTED' "$secrets/state-oobe-state.json" \
    || fail 'the token in the state file was not redacted in place'
grep -q 'jh7110-mars' "$secrets/etc-jh7110-board.conf" \
    || fail 'redaction ate the board configuration it was meant to report'
grep -q 'PermitRootLogin no' "$secrets/etc-sshd.conf" \
    || fail 'redaction ate the sshd configuration it was meant to report'
grep -q 'greeter-session=jh7110-greeter' "$secrets/etc-lightdm.conf" \
    || fail 'the lightdm section is empty'
grep -q '"status": "ok"' "$secrets/state-hardware.json" \
    || fail 'the hardware report is not in the bundle'

# A file that turns out to hold key material is dropped whole - there is no
# useful redacted form for a private key - and it is named in the manifest, so
# whoever sends the bundle knows what is missing and can decide about it.
cat > "$STATE_DIR/hardware.json" <<'EOF'
{"board": "mars", "recovery": "-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-real-key\n-----END OPENSSH PRIVATE KEY-----"}
EOF
cat > "$STATE_DIR/oobe-state.json" <<'EOF'
{"authorized": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB1yZXBvcnRlZC1rZXk comment"}
EOF

bundle="$sandbox/keys.tar.gz"
run_tool -o "$bundle" || fail 'the tool failed with key material in a state file'
keys="$sandbox/keys"
open_bundle "$bundle" "$keys"

if grep -rqF 'BEGIN OPENSSH PRIVATE KEY' "$keys"; then
    fail 'a private key reached the bundle'
fi
if grep -rqF 'ssh-ed25519 AAAAC3' "$keys"; then
    fail 'an authorized key reached the bundle'
fi
grep -q 'NOT INCLUDED' "$keys/state-hardware.json" \
    || fail 'a dropped key file is not explained in its own section'
grep -q 'NOT INCLUDED' "$keys/state-oobe-state.json" \
    || fail 'an authorized_keys line did not drop its file'
for name in state-hardware.json state-oobe-state.json; do
    grep -q "$name" "$keys/README" || fail "$name is not named in the manifest"
done
grep -q 'Left out because they hold key material' "$keys/README" \
    || fail 'the manifest does not say why the files were left out'

# ---------------------------------------------------------------------------
# Behaviour that has to hold whatever the board looks like.
# ---------------------------------------------------------------------------
# A directory that does not exist is a section that says so, not an exit: the
# board being diagnosed is a board where things are missing.
JH7110_ROOT="$ROOT" JH7110_STATE_DIR="$STATE_DIR/absent" JH7110_ETC="$ETC_DIR" \
    "$TOOL" -o "$sandbox/absent.tar.gz" \
    || fail 'the tool failed when its state directory did not exist'
open_bundle "$sandbox/absent.tar.gz" "$sandbox/absent"

# The default output name carries the board's name and a timestamp, and a colon
# in it would make the file awkward to move between filesystems.
( cd "$sandbox" && run_tool >/dev/null )
default_bundle=$(find "$sandbox" -maxdepth 1 -name 'jh7110-diagnostics-*.tar.gz' | head -n 1)
[[ -n "$default_bundle" ]] || fail 'the tool did not write a default-named bundle'
[[ "${default_bundle##*/}" != *:* ]] || fail 'the default name contains a colon'

# What the tool says about itself is what a person reads before sending a log
# to somebody, and an argument it does not understand must not be ignored.
help_text=$(run_tool --help) || fail '--help failed'
[[ "$help_text" == *'jh7110-diagnostics'* ]] || fail '--help does not describe the tool'
[[ "$help_text" == *'redact'* || "$help_text" == *'filtered'* ]] \
    || fail '--help does not say what happens to secrets'
if run_tool --nonsense >/dev/null 2>&1; then
    fail 'an unknown argument was accepted'
fi

echo 'PASS: the diagnostics bundle reports the board without carrying its secrets off it'
