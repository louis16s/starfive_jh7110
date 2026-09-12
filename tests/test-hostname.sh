#!/usr/bin/env bash
# Hostname and /etc/hosts regression tests.
#
# These run the real functions from the shipped library against a sandbox: a
# board that boots with a hostname no hosts file knows about is what makes every
# `sudo` print "unable to resolve host", so the cases below are the ones that
# have to hold after a rename, a repeated run and a file a user has edited.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

export JH7110_ETC="$sandbox/etc"
export JH7110_STATE_DIR="$sandbox/state"
export HOSTNAMECTL_LOG="$sandbox/hostnamectl.log"
mkdir -p "$JH7110_ETC" "$sandbox/bin"

# The board image is built with the host's own identity copied in by mmdebstrap,
# so the stale name below stands in for the CI runner's hostname.
write_initial_state() {
    cat > "$JH7110_ETC/hostname" <<'EOF'
runnervmlun5p
EOF
    cat > "$JH7110_ETC/hosts" <<'EOF'
127.0.0.1	localhost
127.0.1.1	runnervmlun5p

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

# a line the user added, which must survive
192.168.1.50 nas.local nas
EOF
}

cat > "$sandbox/bin/hostnamectl" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${1:-}" "${2:-}" >> "${HOSTNAMECTL_LOG:?}"
[[ "${HOSTNAMECTL_FAIL:-0}" != 1 ]]
EOF
# `getent hosts NAME` answered from the sandbox hosts file, so the resolution
# check exercises the file this library writes rather than the test host's.
cat > "$sandbox/bin/getent" <<'EOF'
#!/usr/bin/env bash
awk -v name="${2:-}" '
    $1 !~ /^#/ && NF > 1 {
        for (field = 2; field <= NF; field++) {
            if ($field == name) { print; exit }
        }
    }
' "$JH7110_ETC/hosts"
EOF
chmod 0755 "$sandbox/bin/hostnamectl" "$sandbox/bin/getent"
export PATH="$sandbox/bin:$PATH"

# shellcheck source=rootfs/overlay/usr/lib/jh7110/common.sh
source "$repo/rootfs/overlay/usr/lib/jh7110/common.sh"

assert_hostname_line() { # $1 hosts file, $2 expected name
    local count
    count=$(awk '$1 == "127.0.1.1"' "$1" | grep -c . || true)
    [[ "$count" == 1 ]] || fail "expected exactly one 127.0.1.1 line in $1, found $count"
    awk '$1 == "127.0.1.1" { print $2 }' "$1" | grep -Fxq "$2" \
        || fail "127.0.1.1 does not map to $2 in $1"
}

# Compare an entry by fields rather than by bytes: hosts files mix tabs and
# spaces, and the file a user edits is not the file this project wrote.
assert_hosts_entry() { # $1 hosts file, $2 address, $3 names, in order
    awk -v addr="$2" -v want="$3" '
        $1 == addr {
            sub(/[ \t]*#.*/, "")
            $1 = ""
            gsub(/^[ \t]+|[ \t]+$/, "")
            gsub(/[ \t]+/, " ")
            if ($0 == want) { found = 1 }
        }
        END { exit !found }
    ' "$1" || fail "$1 has no '$2 $3' line"
}

write_initial_state
jh7110_write_hostname_files jh7110-mars || fail 'write_hostname_files rejected a valid name'
[[ $(<"$JH7110_ETC/hostname") == jh7110-mars ]] || fail '/etc/hostname was not updated'
assert_hostname_line "$JH7110_ETC/hosts" jh7110-mars
grep -q 'runnervmlun5p' "$JH7110_ETC/hosts" && fail 'the previous hostname survived in /etc/hosts'
grep -Fxq '192.168.1.50 nas.local nas' "$JH7110_ETC/hosts" || fail 'a user line was modified'
grep -q '^# a line the user added' "$JH7110_ETC/hosts" || fail 'a comment was dropped'
assert_hosts_entry "$JH7110_ETC/hosts" 127.0.0.1 'localhost'
assert_hosts_entry "$JH7110_ETC/hosts" ::1 'localhost ip6-localhost ip6-loopback'
assert_hosts_entry "$JH7110_ETC/hosts" ff02::1 'ip6-allnodes'
assert_hosts_entry "$JH7110_ETC/hosts" ff02::2 'ip6-allrouters'

# A repeated run must be a no-op, not a second 127.0.1.1 line.
cp "$JH7110_ETC/hosts" "$sandbox/hosts.once"
cp "$JH7110_ETC/hostname" "$sandbox/hostname.once"
jh7110_write_hostname_files jh7110-mars || fail 'the second run failed'
cmp -s "$sandbox/hosts.once" "$JH7110_ETC/hosts" || fail '/etc/hosts changed on a repeated run'
cmp -s "$sandbox/hostname.once" "$JH7110_ETC/hostname" \
    || fail '/etc/hostname changed on a repeated run'

# Renaming must replace the entry, not add a second one.
jh7110_write_hostname_files jh7110-vf2 || fail 'rename failed'
assert_hostname_line "$JH7110_ETC/hosts" jh7110-vf2
grep -q 'jh7110-mars' "$JH7110_ETC/hosts" && fail 'the old board hostname survived a rename'

# Aliases a user added to the managed line are kept; the stale names are not.
cat > "$JH7110_ETC/hosts" <<'EOF'
127.0.0.1	localhost
127.0.1.1	old-name jh7110-extra
EOF
printf 'old-name\n' > "$JH7110_ETC/hostname"
jh7110_write_hostname_files jh7110-mars || fail 'alias rewrite failed'
alias_line=$(awk '$1 == "127.0.1.1" { print $0 }' "$JH7110_ETC/hosts")
[[ "$alias_line" == *jh7110-mars* ]] || fail "new name missing from: $alias_line"
[[ "$alias_line" == *jh7110-extra* ]] || fail "user alias dropped from: $alias_line"
[[ "$alias_line" != *old-name* ]] || fail "stale name kept in: $alias_line"

# A missing hosts file is created with the base entries a resolver needs.
rm -f "$JH7110_ETC/hosts"
jh7110_write_hostname_files jh7110-mars || fail 'a missing hosts file was not created'
assert_hostname_line "$JH7110_ETC/hosts" jh7110-mars
assert_hosts_entry "$JH7110_ETC/hosts" 127.0.0.1 'localhost'
assert_hosts_entry "$JH7110_ETC/hosts" ::1 'localhost ip6-localhost ip6-loopback'

# A file with no IPv6 lines gets them appended once, not on every run.
cat > "$JH7110_ETC/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 old
EOF
jh7110_write_hostname_files jh7110-mars || fail 'ipv6 rewrite failed'
cp "$JH7110_ETC/hosts" "$sandbox/hosts.ipv6"
jh7110_write_hostname_files jh7110-mars || fail 'the second ipv6 run failed'
cmp -s "$sandbox/hosts.ipv6" "$JH7110_ETC/hosts" || fail '/etc/hosts is not idempotent'
[[ $(grep -c '^::1' "$JH7110_ETC/hosts") == 1 ]] || fail 'duplicate ::1 lines'

# The full entry point: kernel hostname, then the resolution check.
write_initial_state
: > "$HOSTNAMECTL_LOG"
jh7110_set_system_hostname jh7110-mars || fail 'set_system_hostname failed'
grep -Fxq 'set-hostname jh7110-mars' "$HOSTNAMECTL_LOG" \
    || fail 'hostnamectl was not called with the new name'
[[ $(<"$JH7110_ETC/hostname") == jh7110-mars ]] || fail '/etc/hostname was not updated'
assert_hostname_line "$JH7110_ETC/hosts" jh7110-mars

# The resolution check is what proves `sudo` stops warning, so a name that does
# not resolve has to be reported rather than passed over.
if jh7110_verify_hostname jh7110-absent >/dev/null 2>&1; then
    fail 'an unresolvable hostname was accepted'
fi
if jh7110_set_system_hostname '' >/dev/null 2>&1; then
    fail 'an empty hostname was accepted'
fi

# Without getent the check is skipped with a message instead of failing the boot.
set +e
# The command string is deliberately single-quoted: it must run in a shell that
# has no getent on PATH, so nothing may be expanded before it starts.
mkdir -p "$sandbox/empty-path"
# shellcheck disable=SC2016
missing_tools=$(env -i PATH="$sandbox/empty-path" HOME="$HOME" "$BASH" -c '
    JH7110_ETC="$1" JH7110_STATE_DIR="$2"
    export JH7110_ETC JH7110_STATE_DIR
    source "$3"
    jh7110_verify_hostname jh7110-mars
' _ "$JH7110_ETC" "$JH7110_STATE_DIR" "$repo/rootfs/overlay/usr/lib/jh7110/common.sh" 2>&1)
missing_status=$?
set -e
[[ "$missing_status" == 0 ]] || fail "a missing getent failed the check: $missing_tools"
[[ "$missing_tools" == *'skipping the hostname resolution check'* ]] \
    || fail "a missing getent was not reported: $missing_tools"

invalid_names=('' '-bad' 'bad-' '12345' 'bad name' 'bad_name' 'a.-b')
invalid_names+=("$(printf 'x%.0s' $(seq 1 64))")
for name in "${invalid_names[@]}"; do
    if jh7110_hostname_validate "$name" >/dev/null 2>&1; then
        fail "invalid hostname accepted: '$name'"
    fi
done
for name in 'a' 'jh7110-mars' 'Mars-01' 'x1'; do
    jh7110_hostname_validate "$name" || fail "valid hostname rejected: '$name'"
done

echo 'PASS: hostname and /etc/hosts stay in sync through rename, repeat and edit'
