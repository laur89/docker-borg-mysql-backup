#!/usr/bin/env bash
#
# tests configured notification system(s)

readonly SELF="${0##*/}"
readonly LOG=/dev/null
JOB_ID="notif-test-$$"  # just for logging; will be overwritten before notification(s) are triggered

readonly usage="
    usage: $SELF [-hpHsTFAmef]

    Test configured notifications. Running it will fire notification via each of
    the configured channels.

    arguments:
      -p ARCHIVE_PREFIX
      -H HOST_ID
      -s NOTIF_SUBJECT
      -T MAIL_TO
      -F MAIL_FROM
      -A SMTP_ACCOUNT
      -m MSG
      -e ERR_NOTIF
      -f                      marks the error as fatal (ie halting the script)
"

# ================
# Entry
# ================
NO_NOTIF=true
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh"; exit 1; }

while getopts "p:H:s:T:F:A:m:e:fh" opt; do
    case "$opt" in
        p) ARCHIVE_PREFIX="$OPTARG"
            ;;
        H) HOST_ID="$OPTARG"  # overrides env var of same name
            ;;
        s) NOTIF_SUBJECT="$OPTARG"  # overrides env var of same name
            ;;
        T) MAIL_TO="$OPTARG"  # overrides env var of same name
            ;;
        F) MAIL_FROM="$OPTARG"  # overrides env var of same name
            ;;
        A) SMTP_ACCOUNT="$OPTARG"  # overrides env var of same name
            ;;
        m) MSG="$OPTARG"
            ;;
        e) ERR_NOTIF="$OPTARG"  # overrides env var of same name
            ;;
        f) FATAL=1
            ;;
        h) echo -e "$usage"
           exit 0
            ;;
        *) fail "$SELF called with unsupported flag(s)"
            ;;
    esac
done

[[ -z "$ERR_NOTIF" ]] && fail "[ERR_NOTIF] is undefined - nothing to test here"
validate_config_common
log "ERR_NOTIF: [$ERR_NOTIF]"

[[ -z "$ARCHIVE_PREFIX" ]] && ARCHIVE_PREFIX='dummy-prefix'
JOB_ID="${ARCHIVE_PREFIX}-$$"
[[ -z "$HOST_ID" ]] && HOST_ID='dummy-host'

[[ -z "$MSG" ]] && MSG='Test error message'

unset NO_NOTIF
[[ "$FATAL" -eq 1 ]] && fail "$MSG" || err "$MSG"

exit 0
