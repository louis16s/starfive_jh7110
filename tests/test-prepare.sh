#!/usr/bin/env bash
# Machine preparation regression tests.
#
# This is the part of first boot that runs unattended, on every board, before
# anything a person sees.  It is also the part with the most ways to be quietly
# wrong: a machine id that is generated twice makes the board a different
# machine to the network and to its own journal, a step that treats "there was
# nothing to do" as failure bricks an already-grown board, and a completion
# marker written early tells the next boot that work happened that did not.
#
# The script is run twice in a row against a sandbox, so those are checked
# rather than assumed.  Everything it calls out to is a stub on PATH, which is
# what makes a boot-time script runnable from a host with no board attached.
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly prepare="$repo/rootfs/overlay/usr/libexec/jh7110-prepare"
# The script ships as `#!/usr/bin/env bash`; running it through this shell keeps
# the checks on the oldest bash around (macOS still ships 3.2) while CI runs
# the same file under bash 5.
readonly prepare_shell=${PREPARE_SHELL:-/bin/bash}
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

export JH7110_SANDBOX="$sandbox"
# The helpers the script sources, and the /etc it writes, both come from the
# checkout: the sandbox is a host directory, not a board.
export JH7110_LIB="$repo/rootfs/overlay/usr/lib/jh7110"
export JH7110_ETC="$sandbox/etc"
export JH7110_STATE_DIR="$sandbox/state"
export JH7110_ROOT="$sandbox/root"
export PATH="$sandbox/bin:$PATH"
mkdir -p "$sandbox/bin" "$sandbox/etc/jh7110" "$sandbox/state" \
    "$sandbox/root/usr/share/zoneinfo/Asia"

# The sandbox stands in for a board that has a timezone database, an /etc and a
# state directory; nothing else about it is meant to look like a board.
: > "$sandbox/root/usr/share/zoneinfo/Asia/Shanghai"

cat > "$sandbox/etc/jh7110/board.conf" <<'EOF'
BOARD_ID=mars
BOARD_NAME='Milk-V Mars'
DEFAULT_HOSTNAME=jh7110-mars
TIMEZONE=Asia/Shanghai
DEFAULT_LOCALE=zh_CN.UTF-8
DEFAULT_LANGUAGE=zh_CN:zh:en_US:en
SUPPORTED_LOCALES='zh_CN.UTF-8 en_US.UTF-8'
EOF

# The device the sandbox pretends its root filesystem lives on.  The script
# tests it with `-b`, so it has to be a block device that really exists on this
# host; every use of it below is a stub, so which one does not matter.
root_device=
for candidate in /dev/disk0 /dev/sda /dev/vda /dev/nvme0n1 /dev/loop0 /dev/mmcblk0; do
    if [[ -b "$candidate" ]]; then
        root_device=$candidate
        break
    fi
done

# ---------------------------------------------------------------------------
# The board, in miniature
# ---------------------------------------------------------------------------

# Every stub records what it was called with, and notes whether the completion
# marker was already there: the marker has to be written after all of them, or
# a boot that died half way leaves a board that claims it was prepared.
cat > "$sandbox/bin/log-call" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${1:-}" >> "$JH7110_SANDBOX/calls.log"
shift
for argument in "$@"; do
    printf ' [%s]' "$argument" >> "$JH7110_SANDBOX/calls.log"
done
if [[ -e "$JH7110_STATE_DIR/prepare.done" ]]; then
    printf ' done-file-already-written' >> "$JH7110_SANDBOX/calls.log"
fi
printf '\n' >> "$JH7110_SANDBOX/calls.log"
STUB

cat > "$sandbox/bin/id" <<'STUB'
#!/usr/bin/env bash
case ${1:-} in
    -u) printf '%s\n' "${JH7110_FAKE_UID:-0}" ;;
    *) exit 1 ;;
esac
STUB

# The running kernel's name is set through hostnamectl when it is there; the
# preparation script is not allowed to write /proc itself.
cat > "$sandbox/bin/hostnamectl" <<'STUB'
#!/usr/bin/env bash
log-call hostnamectl "$@"
STUB

# Resolution is what proves the hosts file is right, and it is asked of the
# sandbox's own hosts file rather than the host's.
cat > "$sandbox/bin/getent" <<'STUB'
#!/usr/bin/env bash
[[ ${1:-} == hosts ]] || exit 1
name=${2:?}
if awk -v n="$name" '$0 ~ "(^|[ \t])" n "([ \t]|$)" { found = 1 } END { exit !found }' \
    "$JH7110_ETC/hosts"; then
    printf '127.0.1.1 %s\n' "$name"
else
    exit 2
fi
STUB

# The machine id is generated once per installation, so this counts the calls.
cat > "$sandbox/bin/systemd-machine-id-setup" <<'STUB'
#!/usr/bin/env bash
log-call systemd-machine-id-setup "$@"
printf 'sandbox-machine-id\n' > "$JH7110_ETC/machine-id"
STUB

cat > "$sandbox/bin/ssh-keygen" <<'STUB'
#!/usr/bin/env bash
log-call ssh-keygen "$@"
STUB

cat > "$sandbox/bin/locale-gen" <<'STUB'
#!/usr/bin/env bash
log-call locale-gen "$@"
STUB

cat > "$sandbox/bin/update-locale" <<'STUB'
#!/usr/bin/env bash
log-call update-locale "$@"
STUB

# The filesystem: this reports the sandbox's root device as ext4, exactly as a
# board's findmnt would.
cat > "$sandbox/bin/findmnt" <<'STUB'
#!/usr/bin/env bash
log-call findmnt "$@"
while [[ $# -gt 0 ]]; do
    case $1 in
        --output)
            case $2 in
                SOURCE) printf '%s\n' "${JH7110_TEST_ROOT_DEVICE:?}" ;;
                FSTYPE) printf 'ext4\n' ;;
            esac
            exit 0
            ;;
        *) shift ;;
    esac
done
exit 1
STUB

cat > "$sandbox/bin/lsblk" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
    case $1 in
        --output)
            case $2 in
                PKNAME) printf 'sandboxdisk\n' ;;
                PARTN) printf '1\n' ;;
            esac
            exit 0
            ;;
        *) shift ;;
    esac
done
exit 1
STUB

# growpart exits 1 to say the partition already fills the disk, which for a
# board that has been booted once is the normal case and not a failure.
cat > "$sandbox/bin/growpart" <<'STUB'
#!/usr/bin/env bash
log-call growpart "$@"
exit "${GROWPART_STATUS:-0}"
STUB

cat > "$sandbox/bin/resize2fs" <<'STUB'
#!/usr/bin/env bash
log-call resize2fs "$@"
STUB

cat > "$sandbox/bin/jh7110-info" <<'STUB'
#!/usr/bin/env bash
log-call jh7110-info "$@"
[[ ${JH7110_INFO_FAILS:-0} != 1 ]] || exit 1
printf 'board: sandbox\n'
STUB

chmod 0755 "$sandbox/bin"/*

run_prepare() {
    "$prepare_shell" "$prepare"
}

# Reset to the state just after the image is written: no marker, no machine id,
# and an empty record of what was called.
reset() {
    rm -f "$sandbox/state/prepare.done" "$sandbox/etc/machine-id" \
        "$sandbox/state/hardware-report.txt"
    : > "$sandbox/calls.log"
}

calls() {
    cat "$sandbox/calls.log"
}

# ---------------------------------------------------------------------------
# The first boot
# ---------------------------------------------------------------------------
[[ -n "$root_device" ]] || echo "note: no block device found; the growth checks will be skipped"
export JH7110_TEST_ROOT_DEVICE=${root_device:-/dev/null}
reset

run_prepare > "$sandbox/stdout" 2> "$sandbox/stderr" \
    || fail "the first run failed: $(cat "$sandbox/stderr")"

[[ -f "$sandbox/state/prepare.done" ]] || fail 'the completion marker was not written'
[[ -s "$sandbox/state/hardware-report.txt" ]] || fail 'the hardware report was not written'
[[ "$(cat "$sandbox/etc/timezone")" == 'Asia/Shanghai' ]] \
    || fail 'the timezone file does not say what the board profile says'
[[ "$(readlink "$sandbox/etc/localtime")" == '/usr/share/zoneinfo/Asia/Shanghai' ]] \
    || fail 'the timezone link points somewhere else'
[[ "$(cat "$sandbox/etc/machine-id")" == 'sandbox-machine-id' ]] \
    || fail 'the machine id was not generated'
[[ -s "$sandbox/etc/hostname" ]] || fail 'the board was left without a name'
grep -q 'jh7110-mars' "$sandbox/etc/hosts" || fail 'the name does not resolve to itself'

grep -q '^hostnamectl \[set-hostname\] \[jh7110-mars\]' <<< "$(calls)" \
    || fail "the running hostname was not set: $(calls)"
grep -q '^systemd-machine-id-setup$' <<< "$(calls)" \
    || fail 'the machine id was not generated'
grep -q '^ssh-keygen \[-A\]$' <<< "$(calls)" || fail 'no SSH host keys were generated'
grep -q '^locale-gen \[zh_CN.UTF-8\] \[en_US.UTF-8\]$' <<< "$(calls)" \
    || fail "the supported locales were not generated: $(calls)"
grep -q '^update-locale' <<< "$(calls)" || fail 'the default locale was not set'
grep -q '^resize2fs \[' <<< "$(calls)" || fail 'the root filesystem was not grown'

# The marker is what tells the next boot there is nothing to do, so nothing in
# the sequence may run after it is written.
grep -q 'done-file-already-written' <<< "$(calls)" \
    && fail 'the completion marker was written before the work it records'

# ---------------------------------------------------------------------------
# A board that has already booted runs the same sequence again
# ---------------------------------------------------------------------------
# The unit skips this script once the marker exists, but the script is meant to
# be run by hand after removing the marker, so it has to be safe on a machine
# that is already prepared.
rm -f "$sandbox/state/prepare.done"
: > "$sandbox/calls.log"
run_prepare > /dev/null 2>&1 || fail 'the second run failed'
grep -q '^systemd-machine-id-setup$' <<< "$(calls)" \
    && fail 'the machine id was generated a second time'
[[ "$(cat "$sandbox/etc/machine-id")" == 'sandbox-machine-id' ]] \
    || fail 'a repeated run replaced the machine id'
[[ -f "$sandbox/state/prepare.done" ]] || fail 'a repeated run did not mark itself done'

# A partition that already fills its disk makes growpart exit 1, which is the
# ordinary case on the second boot rather than a failure.
rm -f "$sandbox/state/prepare.done"
if ! GROWPART_STATUS=1 run_prepare > /dev/null 2>&1; then
    fail 'an already-grown partition was treated as a failure'
fi

# ---------------------------------------------------------------------------
# The ways this must fail, and the ones that must not
# ---------------------------------------------------------------------------
# A growpart that failed for a real reason is a real failure: the board is left
# without the marker so the next boot tries again.
rm -f "$sandbox/state/prepare.done"
if GROWPART_STATUS=2 run_prepare > /dev/null 2>&1; then
    fail 'a failed growpart was ignored'
fi
[[ -f "$sandbox/state/prepare.done" ]] \
    && fail 'the board was marked prepared after a step failed'

# The hardware report is diagnostic; it runs under `set -e`, and losing it must
# not cost the board the rest of the sequence.
reset
if ! JH7110_INFO_FAILS=1 run_prepare > /dev/null 2>&1; then
    fail 'a failing hardware report stopped the sequence'
fi
[[ -f "$sandbox/state/prepare.done" ]] \
    || fail 'a board whose hardware report failed was left unprepared'

# A timezone the board does not have is a board whose clock is wrong, and a
# name it never resolves is the warning this whole phase exists to remove.
cp "$sandbox/etc/jh7110/board.conf" "$sandbox/etc/jh7110/board.conf.bak"
sed 's|^TIMEZONE=.*|TIMEZONE=Not/AZone|' "$sandbox/etc/jh7110/board.conf.bak" \
    > "$sandbox/etc/jh7110/board.conf"
reset
if run_prepare > /dev/null 2>&1; then
    fail 'an unknown timezone was accepted'
fi
[[ -f "$sandbox/state/prepare.done" ]] && fail 'the board was marked prepared with a bad timezone'
mv "$sandbox/etc/jh7110/board.conf.bak" "$sandbox/etc/jh7110/board.conf"

# The board profile is what says which board this is; without it nothing here
# can be right.
mv "$sandbox/etc/jh7110/board.conf" "$sandbox/etc/jh7110/board.conf.hidden"
reset
if run_prepare > /dev/null 2>&1; then
    fail 'the sequence ran without a board profile'
fi
mv "$sandbox/etc/jh7110/board.conf.hidden" "$sandbox/etc/jh7110/board.conf"

# Only the preparation unit, which runs as root, may do any of this.
reset
if JH7110_FAKE_UID=1000 run_prepare > /dev/null 2>&1; then
    fail 'the sequence ran without root'
fi
[[ -f "$sandbox/state/prepare.done" ]] && fail 'a non-root run marked the board prepared'

# The locale tools are not what makes the board reachable: a board without them
# still has to come up with its own name and its own filesystem grown.  They are
# absent by being absent from PATH, which is how a board that does not have them
# looks to the script - a host that happens to have them installed would
# otherwise be found further along the path and answer for a board that has not.
bare_path() {
    local dir="$sandbox/bare" tool
    rm -rf "$dir"
    mkdir -p "$dir"
    # bash is in the list because the stubs are `#!/usr/bin/env bash` scripts:
    # a path without it is one where nothing the sandbox provides can run.
    for tool in awk bash basename cat chmod cut date dirname grep head install \
        ln mktemp mv rm sed sort tr uname; do
        ln -s "$(command -v "$tool")" "$dir/$tool"
    done
    printf '%s' "$dir"
}

reset
mv "$sandbox/bin/locale-gen" "$sandbox/bin/locale-gen.hidden"
mv "$sandbox/bin/update-locale" "$sandbox/bin/update-locale.hidden"
if ! PATH="$sandbox/bin:$(bare_path)" run_prepare > /dev/null 2> "$sandbox/stderr"; then
    fail "a board without the locale tools was left unprepared: $(cat "$sandbox/stderr")"
fi
mv "$sandbox/bin/locale-gen.hidden" "$sandbox/bin/locale-gen"
mv "$sandbox/bin/update-locale.hidden" "$sandbox/bin/update-locale"

# Nothing here asks a question: it is started with no terminal and the desktop
# queues up behind it, so a run whose standard input is closed has to finish.
reset
if ! run_prepare < /dev/null > /dev/null 2>&1; then
    fail 'the sequence did not survive a closed standard input'
fi

echo 'PASS: machine preparation is idempotent, and fails only where it must'
