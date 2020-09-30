#!/usr/bin/env bash
#
# tests configured notification system(s)

readonly SELF="${0##*/}"
readonly LOG=/dev/null

# ================
# Entry
# ================
NO_NOTIF=true
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh"; exit 1; }

while getopts "p:H:s:T:F:A:m:e:f" opt; do
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
        f) FAIL=1
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
[[ "$FAIL" -eq 1 ]] && fail "$MSG" || err "$MSG"

exit 0
