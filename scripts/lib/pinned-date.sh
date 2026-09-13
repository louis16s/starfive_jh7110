#!/bin/sh
# A `date` that answers one question from the pinned clock.
#
# It is not sourced by anything: scripts/build-kernel.sh copies it into a
# directory of its own and puts that directory first on PATH for the packaging
# step, so that it is found under the name `date` and nothing else is shadowed.
# The one call it changes is mkdebian's:
#
#     -- $maintainer  $(date -R)
#
# which becomes the last line of debian/changelog - and therefore of the
# compressed copy of it that ships in the image as
# /usr/share/doc/linux-image-*/changelog.Debian.gz.  `date -R` ignores
# SOURCE_DATE_EPOCH, so without this the same kernel packaged twice carries two
# different changelogs and the image differs by the bytes they differ by.
#
# Every other call, and every other form, is the system clock: a build that
# asked `date` what time it is gets the time it is.
case "$*" in
    -R|--rfc-2822|--rfc-email)
        [ -n "${SOURCE_DATE_EPOCH:-}" ] || exec /bin/date "$@"
        # The epoch in UTC, spelled the way this host's date spells it: GNU
        # coreutils takes --date=@N, and the BSD date a development host has is
        # what the test suite runs this file against (-r N).  The image build
        # is Linux and takes the first branch.
        if /bin/date --version >/dev/null 2>&1; then
            LC_ALL=C exec /bin/date --utc --date="@$SOURCE_DATE_EPOCH" --rfc-2822
        fi
        LC_ALL=C exec /bin/date -u -r "$SOURCE_DATE_EPOCH" \
            '+%a, %d %b %Y %H:%M:%S +0000' ;;
esac
exec /bin/date "$@"
