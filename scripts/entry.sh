#!/bin/sh
# alpine-linux entry
/setup.sh || exit 1

# TODO: remove these 3 lines:
echo "    number of args: [$#]"
echo "    args: [$*]"
#exit 0

if [ $# -ne 0 ]; then
    [ "$1" = '--' ] && shift
    "$@"
else
    # start cron
    /usr/sbin/crond -f -l 8 -L /dev/stdout -c /var/spool/cron/crontabs
fi
