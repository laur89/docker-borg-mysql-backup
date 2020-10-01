#!/usr/bin/env bash
#
# tests configured notification system(s)

readonly SELF="${0##*/}"
readonly LOG=/dev/null
JOB_ID="notif-test-$$"  # just for logging; will be overwritten before notification(s) are triggered

readonly usage="
    usage: $SELF [-hpHsTFAmef]

    Test configured notifications

    arguments:
      -p ARCHIVE_PREFIX
      -H HOST_NAME
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
        H) HOST_NAME="$OPTARG"
            ;;
        s) NOTIF_SUBJECT="$OPTARG"
            ;;
        T) MAIL_TO="$OPTARG"
            ;;
        F) MAIL_FROM="$OPTARG"
            ;;
        A) SMTP_ACCOUNT="$OPTARG"
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
[[ -z "$HOST_NAME" ]] && HOST_NAME='dummy-host'

[[ -z "$MSG" ]] && MSG="Test error message
host: {h}
archive prefix: {p}
job id: {i}
fatal?: {f}"

unset NO_NOTIF
[[ "$FATAL" -eq 1 ]] && fail "$MSG" || err "$MSG"

exit 0
