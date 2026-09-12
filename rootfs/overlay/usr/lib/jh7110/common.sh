#!/usr/bin/env bash
# Shared first-boot helpers.
#
# The prepare service, the recovery setup and the build-time rootfs writer all
# source this file, so the hostname, the hosts file and the state directory have
# exactly one implementation.  Nothing here hardcodes /etc: every path is
# derived from JH7110_ETC and JH7110_STATE_DIR, which is what lets the host-side
# tests run the real functions against a sandbox instead of a copy of the logic.

: "${JH7110_ETC:=/etc}"
: "${JH7110_STATE_DIR:=/var/lib/jh7110}"

# Everything the library reports goes to stderr with one prefix, so a caller
# under `set -e` can capture stdout without mixing in diagnostics.
jh7110_log() {
    printf 'jh7110: %s\n' "$*" >&2
}

# Load /etc/jh7110/board.conf.  The file is written by the build from the board
# profile and only ever holds KEY=value lines; sourcing it is how the shipped
# shell tools read the board identity, and BOARD_ID is the only value that may
# not be empty.
jh7110_board_conf_load() {
    local board_conf="$JH7110_ETC/jh7110/board.conf"
    if [[ ! -r "$board_conf" ]]; then
        jh7110_log "missing board configuration: $board_conf"
        return 1
    fi
    # shellcheck source=/dev/null
    source "$board_conf"
    if [[ -z "${BOARD_ID:-}" || "${BOARD_ID}" == unconfigured ]]; then
        jh7110_log "invalid BOARD_ID in $board_conf"
        return 1
    fi
    return 0
}

# The default hostname for this board.  board.conf carries the value the build
# wrote, so a new board only has to declare DEFAULT_HOSTNAME in its profile;
# the fallback keeps older images working after an upgrade.
jh7110_default_hostname() {
    if [[ -n "${DEFAULT_HOSTNAME:-}" ]]; then
        printf '%s' "$DEFAULT_HOSTNAME"
    else
        printf 'jh7110-%s' "$BOARD_ID"
    fi
}

# RFC 1123 label: letters, digits and inner hyphens, at most 63 characters.
# A name made only of digits is rejected - hostname(7) keeps that reserved for
# addresses, and `hostname -f` on such a name is a debugging trap.
jh7110_hostname_validate() {
    local name=${1:-} length
    if [[ -z "$name" ]]; then
        jh7110_log 'hostname is empty'
        return 1
    fi
    length=${#name}
    if (( length > 63 )); then
        jh7110_log "hostname is longer than 63 characters: $name"
        return 1
    fi
    if [[ ! "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
        jh7110_log "hostname must start and end with a letter or digit and use only letters, digits and hyphens: $name"
        return 1
    fi
    if [[ "$name" =~ ^[0-9]+$ ]]; then
        jh7110_log "hostname must not be all digits: $name"
        return 1
    fi
    return 0
}

# Write stdin to $1 through a temporary file in the same directory, so a reader
# either sees the old file or the new one and never a half-written hosts file.
jh7110_write_atomic() {
    local target=$1 dir tmp
    dir=$(dirname -- "$target")
    tmp=$(mktemp "$dir/.jh7110.XXXXXX") || return 1
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! chmod 0644 "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp"
        return 1
    fi
    return 0
}

# Render a hosts file: stdin is the current content, $1 the hostname to map on
# 127.0.1.1, $2 the hostname being replaced (may be empty), $3 the kernel
# hostname (may be empty).  The 127.0.1.1 line is the one this project owns, so
# it is rewritten where it already is (aliases a user put on it survive) and
# added after the loopback line when the file has none.  Every other line,
# comment and blank line is passed through untouched.
#
# The whole file is read before anything is printed: the alias list is only
# complete once every 127.0.1.1 line has been seen, and writing a line out
# before then is how the aliases got lost.
jh7110_hosts_render() {
    local name=$1 previous=${2:-} kernel=${3:-}
    awk -v name="$name" -v previous="$previous" -v kernel="$kernel" '
        {
            lines[NR] = $0
            trimmed = $0
            sub(/^[ \t]+/, "", trimmed)
            if (trimmed == "" || substr(trimmed, 1, 1) == "#") { next }
            addr = $1
            if (addr == "127.0.0.1") {
                seen_v4_loopback = 1
                if (!v4_loopback_ln) { v4_loopback_ln = NR }
            }
            if (addr == "::1") { seen_v6_loopback = 1 }
            if (addr == "ff02::1") { seen_v6_allnodes = 1 }
            if (addr == "ff02::2") { seen_v6_allrouters = 1 }
            if (addr == "127.0.1.1") {
                if (hostname_ln) {
                    # A file with two managed lines is left with one.
                    drop[NR] = 1
                } else {
                    hostname_ln = NR
                }
                for (field = 2; field <= NF; field++) {
                    if ($field == name || $field == previous || $field == kernel) { continue }
                    if (index(" " extra " ", " " $field " ") > 0) { continue }
                    extra = extra " " $field
                }
            }
        }
        END {
            managed = "127.0.1.1\t" name extra
            if (!hostname_ln && !v4_loopback_ln) {
                # Nothing in the file is a base entry, so this is the image
                # build writing a fresh hosts file: keep the order Debian
                # ships, with the machine name under the loopback line.
                print "127.0.0.1\tlocalhost"
                print managed
                seen_v4_loopback = 1
            }
            for (i = 1; i <= NR; i++) {
                if (drop[i]) { continue }
                if (i == hostname_ln) { print managed }
                else { print lines[i] }
                if (!hostname_ln && i == v4_loopback_ln) { print managed }
            }
            if (!seen_v4_loopback) { print "127.0.0.1\tlocalhost" }
            if (!seen_v6_loopback || !seen_v6_allnodes || !seen_v6_allrouters) {
                print ""
                print "# The following lines are desirable for IPv6 capable hosts"
            }
            if (!seen_v6_loopback) { print "::1\tlocalhost ip6-localhost ip6-loopback" }
            if (!seen_v6_allnodes) { print "ff02::1\tip6-allnodes" }
            if (!seen_v6_allrouters) { print "ff02::2\tip6-allrouters" }
        }
    '
}

# Write /etc/hostname and /etc/hosts without touching the running kernel.  This
# is what the image build calls: it must produce the same files a board would
# produce, but it must never rename the machine doing the build.
jh7110_write_hostname_files() {
    local name=$1
    local hostname_file="$JH7110_ETC/hostname"
    local hosts_file="$JH7110_ETC/hosts"
    local previous='' kernel='' tmp

    jh7110_hostname_validate "$name" || return 1

    # The name being replaced is what makes a rename drop the stale 127.0.1.1
    # entry instead of keeping both names on the line.
    if [[ -r "$hostname_file" ]]; then
        previous=$(head -n 1 "$hostname_file" 2>/dev/null) || previous=''
        previous=${previous%%[[:space:]]*}
    fi
    kernel=$(cat /proc/sys/kernel/hostname 2>/dev/null) || kernel=''

    if ! printf '%s\n' "$name" | jh7110_write_atomic "$hostname_file"; then
        jh7110_log "could not write $hostname_file"
        return 1
    fi

    tmp=$(mktemp "$JH7110_ETC/.jh7110-hosts.XXXXXX") || return 1
    if [[ -r "$hosts_file" ]]; then
        jh7110_hosts_render "$name" "$previous" "$kernel" < "$hosts_file" > "$tmp" \
            || { rm -f "$tmp"; jh7110_log "could not render $hosts_file"; return 1; }
    else
        jh7110_hosts_render "$name" "$previous" "$kernel" < /dev/null > "$tmp" \
            || { rm -f "$tmp"; jh7110_log "could not render $hosts_file"; return 1; }
    fi
    if ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$hosts_file"; then
        rm -f "$tmp"
        jh7110_log "could not write $hosts_file"
        return 1
    fi
    return 0
}

# Point the running kernel at the new name.  hostnamectl is the systemd way and
# also rewrites /etc/hostname, but the running name must not depend on it: the
# sysctl node is what the kernel actually reads, so it is the fallback.
jh7110_set_kernel_hostname() {
    local name=$1
    if command -v hostnamectl >/dev/null 2>&1; then
        if hostnamectl set-hostname "$name"; then
            return 0
        fi
        jh7110_log "hostnamectl set-hostname failed; falling back to /proc/sys/kernel/hostname"
    fi
    if ! printf '%s\n' "$name" > /proc/sys/kernel/hostname 2>/dev/null; then
        jh7110_log "could not set the running hostname to $name"
        return 1
    fi
    return 0
}

# Ask the resolver whether the name now resolves.  RFC 6761 says a single-label
# name must be resolved locally, and a hosts entry is what makes `sudo` stop
# complaining, so this is the check that actually proves the fix.  A missing
# resolver tool is reported but not treated as a broken hosts file.
jh7110_verify_hostname() {
    local name=$1 answer
    if ! command -v getent >/dev/null 2>&1; then
        jh7110_log 'getent is not installed; skipping the hostname resolution check'
        return 0
    fi
    answer=$(getent hosts "$name" 2>/dev/null) || answer=''
    if [[ -z "$answer" ]]; then
        jh7110_log "hostname $name does not resolve; check $JH7110_ETC/hosts"
        return 1
    fi
    return 0
}

# The one entry point the first-boot path uses: files, running kernel, and the
# resolution check.  Exit statuses let a caller distinguish a name it must
# reject (1) from a write that failed (2) from a resolver that still disagrees
# (3); nothing here exits the process, because a caller may be mid-way through
# other first-boot work.
jh7110_set_system_hostname() {
    local name=$1
    if ! jh7110_write_hostname_files "$name"; then
        return 2
    fi
    if ! jh7110_set_kernel_hostname "$name"; then
        return 2
    fi
    if ! jh7110_verify_hostname "$name"; then
        return 3
    fi
    return 0
}
