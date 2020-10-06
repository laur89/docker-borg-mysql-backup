#!/bin/sh
# alpine-linux entry

/setup.sh || exit 1


if [ $# -ne 0 ]; then
    [ "$1" = '--' ] && shift
    [ $# -eq 0 ] && exit 1
    exec "$@"
else
    # start cron
    /usr/sbin/crond -f -l 8 -L /dev/stdout -c /var/spool/cron/crontabs
fi
