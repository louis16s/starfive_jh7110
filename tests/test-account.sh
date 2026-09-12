#!/usr/bin/env bash
# Desktop account regression tests.
#
# The account the first-run setup creates is the only way into the board: root
# ships locked, and this account owns the desktop, the files on it and the sudo
# rights over the system.  The tool is exercised against a sandbox user
# database, so the rules can be checked without a board - the names that are
# refused, the groups that are added only when they exist, the fate of a home
# directory on a repeated run, and above all that the password only ever
# travels on standard input.
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly account_tool="$repo/rootfs/overlay/usr/libexec/jh7110-account"
# The tool ships as `#!/usr/bin/env bash`; running it through this shell keeps
# the checks on the oldest bash around (macOS still ships 3.2) while CI runs
# the same file under bash 5.
readonly account_shell=${ACCOUNT_SHELL:-/bin/bash}
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

export JH7110_SANDBOX="$sandbox"
export PATH="$sandbox/bin:$PATH"
mkdir -p "$sandbox/bin" "$sandbox/etc" "$sandbox/home"

run_account() {
    "$account_shell" "$account_tool" "$@"
}

# ---------------------------------------------------------------------------
# The sandbox user database and the tools that maintain it
# ---------------------------------------------------------------------------

# A miniature version of what a Debian image has: the superuser, one system
# account (uid 1, which a person must not be able to take over), the groups the
# desktop account needs, one group of the kind a board has for other reasons,
# and two groups the desktop tool asks for that this board does not have.
write_database() {
    cat > "$sandbox/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
EOF
    cat > "$sandbox/etc/group" <<'EOF'
root:x:0:
sudo:x:27:
video:x:44:
render:x:109:
audio:x:29:
netdev:x:110:
dialout:x:20:
cdrom:x:24:
EOF
    rm -rf "${sandbox:?}/home"
    mkdir -p "$sandbox/home"
    : > "$sandbox/calls.log"
    : > "$sandbox/chpasswd.received"
}

# Every stub records what it was called with.  The tests read this back to
# prove a password never became an argument - arguments are visible in `ps` to
# every process on the board.
cat > "$sandbox/bin/log-call" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${1:-}" >> "$JH7110_SANDBOX/calls.log"
shift
for argument in "$@"; do
    printf ' %s' "$argument" >> "$JH7110_SANDBOX/calls.log"
done
printf '\n' >> "$JH7110_SANDBOX/calls.log"
STUB

cat > "$sandbox/bin/sandbox-group-add" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
sb=${JH7110_SANDBOX:?}
member=${1:?}
shift
for group in "$@"; do
    awk -F: -v g="$group" -v m="$member" '
        BEGIN { OFS = ":" }
        $1 == g {
            if ($4 == "") { $4 = m }
            else if (index("," $4 ",", "," m ",") == 0) { $4 = $4 "," m }
        }
        { print }
    ' "$sb/etc/group" > "$sb/etc/group.new"
    mv "$sb/etc/group.new" "$sb/etc/group"
done
STUB

cat > "$sandbox/bin/sandbox-group-remove" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
sb=${JH7110_SANDBOX:?}
member=${1:?}
shift
for group in "$@"; do
    awk -F: -v g="$group" -v m="$member" '
        BEGIN { OFS = ":" }
        $1 == g {
            count = split($4, members, ",")
            kept = ""
            for (i = 1; i <= count; i++) {
                if (members[i] == m || members[i] == "") { continue }
                kept = (kept == "" ? members[i] : kept "," members[i])
            }
            $4 = kept
        }
        { print }
    ' "$sb/etc/group" > "$sb/etc/group.new"
    mv "$sb/etc/group.new" "$sb/etc/group"
done
STUB

cat > "$sandbox/bin/getent" <<'STUB'
#!/usr/bin/env bash
db=${1:?}
shift
name=${1:-}
file="$JH7110_SANDBOX/etc/$db"
[[ -r "$file" ]] || exit 2
if [[ -z "$name" ]]; then
    cat "$file"
    exit 0
fi
awk -F: -v n="$name" '$1 == n { print; found = 1 } END { exit !found }' "$file"
STUB

cat > "$sandbox/bin/id" <<'STUB'
#!/usr/bin/env bash
sb=${JH7110_SANDBOX:?}
case ${1:-} in
    -u)
        if [[ $# -ge 2 ]]; then
            awk -F: -v n="$2" '$1 == n { print $3; found = 1 } END { exit !found }' \
                "$sb/etc/passwd" || exit 1
        else
            # Without an override this answers as root, which is what the
            # account tool requires before it touches the database.
            printf '%s\n' "${JH7110_FAKE_UID:-0}"
        fi
        ;;
    -nG)
        [[ $# -ge 2 ]] || exit 1
        primary=$(awk -F: -v n="$2" '$1 == n { print $4; found = 1 } END { exit !found }' \
            "$sb/etc/passwd") || exit 1
        awk -F: -v n="$2" -v g="$primary" '
            $3 == g { print $1; next }
            {
                count = split($4, members, ",")
                for (i = 1; i <= count; i++) {
                    if (members[i] == n) { print $1 }
                }
            }
        ' "$sb/etc/group" | awk '{ out = (out == "" ? $1 : out " " $1) } END { print out }'
        ;;
    *)
        exit 1
        ;;
esac
STUB

cat > "$sandbox/bin/useradd" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
sb=${JH7110_SANDBOX:?}
log-call useradd "$@"
[[ ${USERADD_FAIL:-0} != 1 ]] || { echo "useradd: refusing on purpose" >&2; exit 1; }
name=
groups=
while [[ $# -gt 0 ]]; do
    case $1 in
        --create-home | --user-group) shift ;;
        --shell) shift 2 ;;
        --groups) groups=$2; shift 2 ;;
        *) name=$1; shift ;;
    esac
done
[[ -n "$name" ]] || exit 1
next_uid=$(awk -F: 'BEGIN { uid = 999 } $3 > uid && $3 < 60000 { uid = $3 } END { print uid + 1 }' \
    "$sb/etc/passwd")
[[ "$next_uid" -ge 1000 ]] || next_uid=1000
# --user-group: the account gets a group of its own, with the same number.
mkdir -p "$sb/home/$name"
printf '%s:x:%s:%s:%s:%s:/bin/bash\n' \
    "$name" "$next_uid" "$next_uid" "$name" "$sb/home/$name" >> "$sb/etc/passwd"
printf '%s:x:%s:\n' "$name" "$next_uid" >> "$sb/etc/group"
if [[ -n "$groups" ]]; then
    sandbox-group-add "$name" $(printf '%s' "$groups" | tr ',' ' ')
fi
STUB

cat > "$sandbox/bin/usermod" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
sb=${JH7110_SANDBOX:?}
log-call usermod "$@"
name=
groups=
while [[ $# -gt 0 ]]; do
    case $1 in
        --append) shift ;;
        --groups) groups=$2; shift 2 ;;
        *) name=$1; shift ;;
    esac
done
[[ -n "$name" && -n "$groups" ]] || exit 1
sandbox-group-add "$name" $(printf '%s' "$groups" | tr ',' ' ')
STUB

# The one tool that ever sees the password.  It records the pipe rather than
# the account, so the test can assert on what the account tool sent without
# asserting on anything the image does.
cat > "$sandbox/bin/chpasswd" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
sb=${JH7110_SANDBOX:?}
log-call chpasswd "$@"
IFS= read -r record || exit 1
printf '%s\n' "$record" >> "$sb/chpasswd.received"
STUB

cat > "$sandbox/bin/stat" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
sb=${JH7110_SANDBOX:?}
log-call stat "$@"
format=
path=
while [[ $# -gt 0 ]]; do
    case $1 in
        -c | --format) format=$2; shift 2 ;;
        *) path=$1; shift ;;
    esac
done
[[ "$format" == *%u* ]] || exit 1
if [[ -n "${STAT_UID_OVERRIDE:-}" ]]; then
    printf '%s\n' "$STAT_UID_OVERRIDE"
    exit 0
fi
# The sandbox filesystem has no real ownership, so the owner of a home
# directory is whoever the database says lives there.
awk -F: -v home="$path" '$6 == home { print $3; found = 1 } END { exit !found }' \
    "$sb/etc/passwd" || printf '0\n'
STUB

chmod 0755 "$sandbox/bin"/*

passwd_line() { # $1 user name
    awk -F: -v n="$1" '$1 == n { print; found = 1 } END { exit !found }' "$sandbox/etc/passwd"
}

# A user is in a group either because it is the primary group of the account or
# because the group lists it as a member, which is exactly what `id -nG` reports.
in_group() { # $1 user name, $2 group
    local gid primary
    gid=$(awk -F: -v g="$2" '$1 == g { print $3; found = 1 } END { exit !found }' \
        "$sandbox/etc/group") || return 1
    primary=$(awk -F: -v n="$1" '$1 == n { print $4 }' "$sandbox/etc/passwd")
    [[ "$gid" == "$primary" ]] && return 0
    awk -F: -v g="$2" '$1 == g { print $4 }' "$sandbox/etc/group" \
        | grep -qE "(^|,)${1}(,|$)"
}

# ---------------------------------------------------------------------------
# The names that are accepted, and the ones that are not
# ---------------------------------------------------------------------------
write_database

for name in jh7110 a _service admin-1 'jh7110-mars'; do
    run_account validate "$name" >/dev/null 2>&1 \
        || fail "a valid user name was refused: '$name'"
done
# `root` is the one name this must never accept: the image ships root locked,
# and a setup that could be talked into creating it would undo that.
for name in '' root Root 1abc 'bad name' -bad 'bad.' 'jh7110:root' 'üser' 'root '; do
    if run_account validate "$name" >/dev/null 2>&1; then
        fail "an invalid user name was accepted: '$name'"
    fi
done
too_long=$(printf 'x%.0s' $(seq 1 33))
if run_account validate "$too_long" >/dev/null 2>&1; then
    fail 'a 33 character user name was accepted'
fi
# A system account is not a person's to take over.
if run_account validate daemon >/dev/null 2>&1; then
    fail 'a system account was accepted as a desktop account'
fi
# A prompt shows the refusal as the reason, so an accepted name says nothing
# and a refused one says why.
[[ -z "$(run_account validate jh7110 2>&1)" ]] || fail 'validate was noisy about a valid name'
[[ -n "$(run_account validate root 2>&1)" ]] || fail 'validate refused root without saying why'

# ---------------------------------------------------------------------------
# Creating the account
# ---------------------------------------------------------------------------
password='correct horse battery'
set +e
create_output=$(printf '%s\n' "$password" | run_account create jh7110 2>&1)
create_status=$?
set -e
[[ "$create_status" -eq 0 ]] || fail "creating the account failed: $create_output"

passwd_line jh7110 >/dev/null || fail 'the account was not created'
uid=$(awk -F: '$1 == "jh7110" { print $3 }' "$sandbox/etc/passwd")
[[ "$uid" -ge 1000 ]] || fail "the account got a system uid: $uid"
[[ "$(awk -F: '$1 == "jh7110" { print $6 }' "$sandbox/etc/passwd")" == "$sandbox/home/jh7110" ]] \
    || fail 'the account has no home directory'
[[ -d "$sandbox/home/jh7110" ]] || fail 'the home directory was not created'
[[ "$(awk -F: '$1 == "jh7110" { print $7 }' "$sandbox/etc/passwd")" == /bin/bash ]] \
    || fail 'the account does not have a login shell'
in_group jh7110 jh7110 || fail 'the account did not get a group of its own'

# sudo is what makes the desktop account an administrator; the rest are what
# the desktop needs for graphics, sound, removable media and the serial port.
for group in sudo video render audio netdev dialout; do
    in_group jh7110 "$group" || fail "the account is not in $group"
done
# The two groups this board does not have are skipped with a message rather
# than added blindly or failed over.
for group in bluetooth plugdev; do
    in_group jh7110 "$group" && fail "$group was created just to be joined"
    [[ "$create_output" == *"skipping group that does not exist: $group"* ]] \
        || fail "a missing group was skipped silently: $create_output"
done
# The group a board happens to have for other reasons is not this tool's business.
in_group jh7110 cdrom && fail 'the account was added to a group it did not ask for'

# The password travels on standard input only.  Standard input is not in `ps`,
# not in the journal and not in a shell history; an argument is all three.
[[ "$(cat "$sandbox/chpasswd.received")" == "jh7110:$password" ]] \
    || fail "unexpected password record: $(cat "$sandbox/chpasswd.received")"
grep -qF "$password" "$sandbox/calls.log" \
    && fail 'the password was passed as a command line argument'
grep -qF "$password" "$sandbox/etc/passwd" && fail 'the password reached the account database'
grep -qF "$password" "$sandbox/etc/group" && fail 'the password reached the group database'
[[ $(awk 'END { print NR }' "$sandbox/chpasswd.received") == 1 ]] \
    || fail 'the password was sent more than once'
run_account check jh7110 || fail 'the account the tool created does not pass its own check'

# Groups asked for on the command line are added as well.
printf 'another\n' | run_account create extra-user cdrom \
    || fail 'creating an account with an extra group failed'
in_group extra-user cdrom || fail 'an explicitly requested group was not added'
in_group extra-user sudo || fail 'the desktop groups were dropped when one was named'

# ---------------------------------------------------------------------------
# Running it again repairs the account instead of creating a second one
# ---------------------------------------------------------------------------
marker="$sandbox/home/jh7110/keep-me"
: > "$marker"
: > "$sandbox/calls.log"
: > "$sandbox/chpasswd.received"
printf 'replacement\n' | run_account create jh7110 || fail 'the second run failed'
[[ $(grep -c '^useradd' "$sandbox/calls.log") == 0 ]] \
    || fail 'a repeated run tried to create the account again'
grep -q '^usermod' "$sandbox/calls.log" || fail 'a repeated run did not bring the groups up to date'
[[ -f "$marker" ]] || fail 'a repeated run replaced the home directory'
[[ "$(cat "$sandbox/chpasswd.received")" == 'jh7110:replacement' ]] \
    || fail 'a repeated run did not set the password again'
run_account validate jh7110 >/dev/null \
    || fail 'an existing human account was refused as a repair target'

# ---------------------------------------------------------------------------
# The ways this must fail
# ---------------------------------------------------------------------------
# An empty password is worse than no account at all.
if printf '\n' | run_account create nobody >/dev/null 2>&1; then
    fail 'an empty password was accepted'
fi
if printf '' | run_account create nobody >/dev/null 2>&1; then
    fail 'a missing password was accepted'
fi
passwd_line nobody >/dev/null 2>&1 && fail 'the account was created despite the password failure'

# The desktop account is not creatable without root.
if env JH7110_FAKE_UID=1000 "$account_shell" "$account_tool" create nobody \
    </dev/null >/dev/null 2>&1; then
    fail 'the account tool ran without root'
fi
# Neither is the account of a daemon.
if printf 'x\n' | run_account create daemon >/dev/null 2>&1; then
    fail 'the account tool took over a system account'
fi

# A useradd that fails must stop the tool rather than report a success.
if printf 'x\n' | env USERADD_FAIL=1 "$account_shell" "$account_tool" create partial \
    >/dev/null 2>&1; then
    fail 'a failed useradd was reported as success'
fi

# The check has to notice each of the ways the account can be unusable.
run_account check jh7110 || fail 'check rejected a healthy account'
if STAT_UID_OVERRIDE=4242 run_account check jh7110 >/dev/null 2>&1; then
    fail 'check accepted a home directory owned by somebody else'
fi
if run_account check phantomb >/dev/null 2>&1; then
    fail 'check accepted an account that does not exist'
fi
"$sandbox/bin/sandbox-group-remove" jh7110 sudo
if run_account check jh7110 >/dev/null 2>&1; then
    fail 'check accepted an account that cannot use sudo'
fi
"$sandbox/bin/sandbox-group-add" jh7110 sudo
rm -rf "$sandbox/home/jh7110"
if run_account check jh7110 >/dev/null 2>&1; then
    fail 'check accepted an account with no home directory'
fi

# Usage errors are errors, not silence.
if run_account >/dev/null 2>&1; then
    fail 'the account tool ran with no arguments'
fi
if printf 'x\n' | run_account create >/dev/null 2>&1; then
    fail 'the account tool created an account with no name'
fi
if run_account nonsense jh7110 >/dev/null 2>&1; then
    fail 'the account tool ran an unknown subcommand'
fi

echo 'PASS: the desktop account is created, repaired and checked on standard-input passwords'
