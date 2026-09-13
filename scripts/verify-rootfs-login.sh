#!/usr/bin/env bash
# Check that a built rootfs can be logged into.
#
# This is the check that runs before the expensive half of a build: a rootfs
# takes minutes, the kernel, U-Boot and the image together take the better part
# of an hour, and the ways a board ends up with no way in at all - a missing
# /bin/login, no sshd, a service that was never enabled - are all properties of
# the rootfs alone.  It reads the tree the build produced rather than running
# anything from it, so it needs no root, no QEMU and no booted system, and it is
# the same check on a runner and on a workstation.
#
# The rootfs build asserts the same things from inside the chroot, where the
# target's own systemd can be asked (is-enabled, cat, sshd -t).  Those are the
# authoritative ones; this is the one that can be run against a tree afterwards,
# and the one the CI smoke job runs before anything is compiled.
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT

die() {
    echo "verify-rootfs-login: $*" >&2
    exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 BOARD"
board=$1

# shellcheck source=/dev/null
source "$REPO_ROOT/board/$board/profile.conf"

rootfs="$REPO_ROOT/$OUTPUT_ROOT/$board/rootfs/rootfs"
[[ -d "$rootfs" ]] || die "missing rootfs: $rootfs (run: make BOARD=$board rootfs)"

failures=0

# Report a path the image has to have.  Every check collects its failure and
# the run ends with the count, so one missing file does not hide the next.
require() {
    if [[ ! -e "$rootfs/$1" ]]; then
        echo "verify-rootfs-login: missing: /$1" >&2
        failures=$((failures + 1))
    elif [[ $# -gt 1 && ! -x "$rootfs/$1" ]]; then
        echo "verify-rootfs-login: not executable: /$1" >&2
        failures=$((failures + 1))
    fi
}

# The serial console: agetty draws the prompt, /bin/login is what the prompt
# hands the terminal to, and the PAM stack behind login decides whether the
# password is accepted.  Debian keeps login in a package of its own, apart from
# the base system, so all three are properties of the package manifest rather
# than of "installing Debian" - and a rootfs with agetty and no login is a board
# that prints its boot log to the serial port and never offers a prompt.
require bin/login executable
require etc/pam.d/login
agetty_path=
for candidate in sbin/agetty usr/sbin/agetty; do
    if [[ -x "$rootfs/$candidate" ]]; then
        agetty_path=$candidate
    fi
done
if [[ -z "$agetty_path" ]]; then
    echo "verify-rootfs-login: missing: agetty" >&2
    failures=$((failures + 1))
fi
# The unit that starts it for the console the kernel names.
require usr/lib/systemd/system/serial-getty@.service

# ssh: the server, the unit that starts it, the drop-in that states its
# configuration, the unit drop-in that gives it /run/sshd and orders it after
# the first boot, and the enablement that makes it come up at boot.  The enable
# symlink is what a board with no serial cable depends on, and without it the
# board is silent until someone finds a cable.
require usr/sbin/sshd executable
require usr/lib/systemd/system/ssh.service
require etc/systemd/system/ssh.service.d/10-jh7110.conf
require etc/systemd/system/multi-user.target.wants/ssh.service
# The image ships no host keys and sshd will not start without them, so the
# daemon has to be ordered after the first-boot unit that makes them: both are
# wanted by multi-user.target, and started together the daemon can reach its own
# start-up check first and exit, after which nothing restarts it.
unit_drop_in="$rootfs/etc/systemd/system/ssh.service.d/10-jh7110.conf"
if [[ -e "$unit_drop_in" ]] && ! grep -qx 'After=jh7110-prepare.service' "$unit_drop_in"; then
    echo "verify-rootfs-login: ssh.service is not ordered after jh7110-prepare.service" >&2
    failures=$((failures + 1))
fi
drop_in="$rootfs/etc/ssh/sshd_config.d/90-jh7110.conf"
require etc/ssh/sshd_config.d/90-jh7110.conf
if [[ -e "$drop_in" ]]; then
    if ! grep -qx 'PermitRootLogin no' "$drop_in"; then
        echo "verify-rootfs-login: the ssh drop-in does not refuse root login" >&2
        failures=$((failures + 1))
    fi
    if ! grep -qx 'PasswordAuthentication yes' "$drop_in"; then
        echo "verify-rootfs-login: the ssh drop-in does not allow password logins" >&2
        failures=$((failures + 1))
    fi
    # The account the first-run setup creates is an ordinary one; with root
    # refused above, a directive that restricts logins further would be the
    # thing that keeps it out.
    if grep -qE '^[[:space:]]*(AllowUsers|AllowGroups|DenyUsers)[[:space:]]' "$drop_in"; then
        echo "verify-rootfs-login: the ssh drop-in restricts which accounts may log in" >&2
        failures=$((failures + 1))
    fi
fi

# The identities belong to the board: a machine id or a host key in the image
# would be one identity shared by every board the image is written to.
if [[ -e "$rootfs/etc/machine-id" ]]; then
    echo "verify-rootfs-login: the image ships a machine id" >&2
    failures=$((failures + 1))
fi
for host_key in "$rootfs"/etc/ssh/ssh_host_*; do
    if [[ -e "$host_key" ]]; then
        echo "verify-rootfs-login: the image ships an SSH host key: ${host_key#"$rootfs"}" >&2
        failures=$((failures + 1))
    fi
done

# The board's own name, and only its own: the two boards share this tree, and
# the profile is the only thing that decides which one an image is.
if [[ "$(head -n 1 "$rootfs/etc/hostname" 2>/dev/null || true)" != "$DEFAULT_HOSTNAME" ]]; then
    echo "verify-rootfs-login: /etc/hostname is not $DEFAULT_HOSTNAME" >&2
    failures=$((failures + 1))
fi
if ! awk -v name="$DEFAULT_HOSTNAME" \
    '$1 == "127.0.1.1" && $2 == name { found = 1 } END { exit !found }' \
    "$rootfs/etc/hosts" 2>/dev/null; then
    echo "verify-rootfs-login: /etc/hosts does not resolve $DEFAULT_HOSTNAME" >&2
    failures=$((failures + 1))
fi
if [[ "$DEFAULT_HOSTNAME" == jh7110-mars ]]; then
    other_hostname=jh7110-vf2
else
    other_hostname=jh7110-mars
fi
if grep -q "$other_hostname" "$rootfs/etc/hostname" "$rootfs/etc/hosts" 2>/dev/null; then
    echo "verify-rootfs-login: this rootfs carries the other board's name: $other_hostname" >&2
    failures=$((failures + 1))
fi

if (( failures > 0 )); then
    die "$failures check(s) failed for board $board"
fi
printf 'verify-rootfs-login: %s can be logged into (serial and ssh)\n' "$board"
