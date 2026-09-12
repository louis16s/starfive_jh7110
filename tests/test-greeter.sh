#!/usr/bin/env bash
# The greeter wrapper's decision table.
#
# On a board that has not been set up, lightdm starts this wrapper instead of
# the login screen.  Every branch below ends in either the setup or the real
# greeter, and the one outcome that is not allowed is a board with no account
# and nothing offering to create one - so the cases that matter are the ones
# where the wizard cannot run, does not finish, or never stops being offered.
#
# The wrapper execs what it decides on, so each case runs it in a subshell with
# stubs standing in for the wizard, the greeter and systemctl.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly WRAPPER="$repo/rootfs/overlay/usr/libexec/jh7110-greeter"
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

readonly STATE_DIR="$sandbox/state"
readonly CALLS="$sandbox/calls"
mkdir -p "$STATE_DIR" "$sandbox/bin"

# Every stub records that it ran, so a case can say which of them ran and in
# what order rather than only what the wrapper printed.
cat > "$sandbox/bin/greeter" <<'EOF'
#!/usr/bin/env bash
printf 'greeter\n' >> "$JH7110_TEST_CALLS"
exit 0
EOF

# The wizard stands in for the real one: JH7110_WIZARD_FINISHES decides whether
# it writes the done file, and it records the --check it was asked for as a
# call of its own so a case can tell a check from a run.
cat > "$sandbox/bin/wizard" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [[ ${1:-} == --check ]]; then
    printf 'wizard --check\n' >> "$JH7110_TEST_CALLS"
    [[ ${JH7110_CHECK_FAILS:-0} != 1 ]]
    exit $?
fi
printf 'wizard run\n' >> "$JH7110_TEST_CALLS"
if [[ ${JH7110_WIZARD_FINISHES:-0} == 1 ]]; then
    : > "$JH7110_TEST_STATE/oobe.done"
fi
exit 0
EOF

cat > "$sandbox/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$JH7110_TEST_CALLS"
[[ ${JH7110_SYSTEMCTL_FAILS:-0} != 1 ]]
EOF
chmod 0755 "$sandbox/bin/greeter" "$sandbox/bin/wizard" "$sandbox/bin/systemctl"

# One run of the wrapper.  It execs, so it has to have a shell of its own; the
# stubs are reached through the environment rather than through PATH because
# the wrapper names the real greeter by its full path.
run_greeter() {
    : > "$CALLS"
    set +e
    (
        cd "$sandbox" || exit 1
        JH7110_STATE_DIR="$STATE_DIR" \
        JH7110_TEST_STATE="$STATE_DIR" \
        JH7110_TEST_CALLS="$CALLS" \
        JH7110_WIZARD="${JH7110_WIZARD:-$sandbox/bin/wizard}" \
        JH7110_REAL_GREETER="${JH7110_REAL_GREETER:-$sandbox/bin/greeter}" \
        JH7110_ATTEMPTS_FILE="$sandbox/attempts" \
        HOME="$sandbox" \
        PATH="$sandbox/bin:$PATH" \
        "$WRAPPER" "$@"
    ) > "$sandbox/stdout" 2> "$sandbox/stderr"
    status=$?
    set -e
    return "$status"
}

calls() {
    cat "$CALLS"
}

reset_case() {
    rm -f "$STATE_DIR/oobe.done" "$sandbox/attempts"
    unset JH7110_WIZARD_FINISHES JH7110_CHECK_FAILS JH7110_SYSTEMCTL_FAILS \
        JH7110_WIZARD JH7110_REAL_GREETER
}

# A board that has been set up must not see any of this: the wizard is not
# started, not even checked, and the session goes straight to the login screen.
reset_case
: > "$STATE_DIR/oobe.done"
run_greeter || fail 'the wrapper failed on a board that is already set up'
[[ $(calls) == greeter ]] || fail "a set-up board ran more than the greeter: $(calls)"

# First boot: the wizard runs, finishes, and the greeter follows it in the same
# session.  The tally is cleared, because it counts unfinished setups.
reset_case
JH7110_WIZARD_FINISHES=1 run_greeter || fail 'the wrapper failed after a finished setup'
[[ $(calls) == $'wizard --check\nwizard run\ngreeter' ]] \
    || fail "unexpected sequence on a finished first run: $(calls)"
[[ -e "$sandbox/attempts" ]] && fail 'the attempt tally survived a finished setup'

# The user closes the window.  The wizard exits 0 either way, so what says it
# did not finish is the file it never wrote - and the recovery console is
# offered then and there rather than after another reboot.
reset_case
run_greeter || fail 'the wrapper failed after an unfinished setup'
[[ $(calls) == $'wizard --check\nwizard run\nsystemctl start --no-block jh7110-console-setup.service\ngreeter' ]] \
    || fail "an unfinished setup did not fall back to the console: $(calls)"
[[ $(cat "$sandbox/attempts") == 1 ]] || fail 'the unfinished run was not counted'
grep -q 'did not finish' "$sandbox/stderr" || fail 'the unfinished run was not reported'

# Three unfinished runs is where trying again stops being the answer.
reset_case
printf '3\n' > "$sandbox/attempts"
run_greeter || fail 'the wrapper failed at the attempt limit'
[[ $(calls) == $'wizard --check\nsystemctl start --no-block jh7110-console-setup.service\ngreeter' ]] \
    || fail "the wizard was started past the limit: $(calls)"
[[ $(cat "$sandbox/attempts") == 3 ]] || fail 'the tally grew past the limit'
grep -q 'without finishing' "$sandbox/stderr" || fail 'the attempt limit was not reported'

# A tally a half-written file left behind must not lock the board out of its
# own setup, so anything that is not a number reads as "no attempts yet".
reset_case
printf 'not a number\n' > "$sandbox/attempts"
run_greeter || fail 'a corrupt tally failed the wrapper'
[[ $(cat "$sandbox/attempts") == 1 ]] || fail 'a corrupt tally was not replaced with a count'
grep -q 'wizard run' "$CALLS" || fail 'a corrupt tally skipped the wizard'

# No GTK on the board: the wizard cannot open at all, so the recovery console
# is offered immediately instead of after the retries have been spent.
reset_case
JH7110_CHECK_FAILS=1 run_greeter || fail 'the wrapper failed without a graphical stack'
[[ $(calls) == $'wizard --check\nsystemctl start --no-block jh7110-console-setup.service\ngreeter' ]] \
    || fail "a board without GTK did not go to the console: $(calls)"
[[ -e "$sandbox/attempts" ]] && fail 'a board without GTK spent an attempt'
grep -q 'cannot run' "$sandbox/stderr" || fail 'the missing stack was not reported'

# The wizard is not installed at all - an image assembled without it, or a file
# something removed.  The board still has to have a way in.
reset_case
JH7110_WIZARD="$sandbox/bin/absent" run_greeter || fail 'the wrapper failed without a wizard'
[[ $(calls) == $'systemctl start --no-block jh7110-console-setup.service\ngreeter' ]] \
    || fail "a missing wizard did not go to the console: $(calls)"
grep -q 'not installed' "$sandbox/stderr" || fail 'the missing wizard was not reported'

# If even that is refused - polkit missing, the unit gone - the wrapper must
# still say what a person can run, because the board has no account yet.
reset_case
JH7110_CHECK_FAILS=1 JH7110_SYSTEMCTL_FAILS=1 run_greeter \
    || fail 'the wrapper failed when the recovery unit could not be started'
grep -q 'jh7110-console-setup' "$sandbox/stderr" \
    || fail 'a refused recovery request did not say what to run instead'

# A board whose login screen is missing is the one case that cannot be fixed
# here, and it is also the one that would otherwise leave no trace: the wrapper
# must say what is missing rather than exec into nothing.
reset_case
JH7110_REAL_GREETER="$sandbox/bin/absent" run_greeter >/dev/null 2>&1 || true
grep -q 'login screen is missing' "$sandbox/stderr" \
    || fail 'a missing login screen was not reported'

# The greeter is started exactly once in every branch above, and never before
# the wizard: two greeters or a greeter before the setup is a session that
# shows a login screen with nothing to log into.  This is also the check that
# the wrapper execs rather than falling through to whatever follows it.
reset_case
run_greeter || fail 'the wrapper failed'
[[ $(grep -c '^greeter$' "$CALLS") == 1 ]] || fail 'the greeter ran more than once'
[[ $(tail -n 1 "$CALLS") == greeter ]] || fail 'the greeter was not the last thing started'

echo 'PASS: the greeter wrapper runs the setup, then the greeter, and never leaves a board without a way in'
