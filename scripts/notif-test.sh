#!/usr/bin/env bash
#
# tests configured notification system(s)

readonly SELF="${0##*/}"
readonly LOG=/dev/null

# ================
# Entry
# ================
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh"; exit 1; }
validate_config_common
[[ -z "$ERR_NOTIF" ]] && fail -N "[ERR_NOTIF] is undefined - nothing to test here"
log "ERR_NOTIF: [$ERR_NOTIF]"

while getopts "p:H:s:T:F:A:m:" opt; do
    case "$opt" in
        p) ARCHIVE_PREFIX="$OPTARG"
           JOB_ID="${OPTARG}-$$"
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
        *) fail -N "$SELF called with unsupported flag(s)"
            ;;
    esac
done

[[ -z "$MSG" ]] && MSG="Test error message
host: {h}
archive prefix: {p}
job id: {i}
fatal?: {f}"

fail "$MSG"

exit 0
