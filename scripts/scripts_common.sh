#!/usr/bin/env bash
#
# common vars & functions

readonly BACKUP_ROOT='/backup'
readonly CONF_ROOT='/config'
readonly SCRIPTS_ROOT="$CONF_ROOT/scripts"

readonly CRON_FILE="$CONF_ROOT/crontab"
readonly MSMTPRC="$CONF_ROOT/msmtprc"
readonly PUSHOVER_CONF="$CONF_ROOT/pushover.conf"
readonly SSH_KEY="$CONF_ROOT/id_rsa"
readonly LOG_TIMESTAMP_FORMAT='+%F %T'

readonly DEFAULT_LOCAL_REPO_NAME=repo
readonly DEFAULT_MAIL_FROM='{h} backup reporter'
readonly DEFAULT_NOTIF_SUBJECT='[{p}] backup error on {h}'


start_or_stop_containers() {
    local start_or_stop c idx

    readonly start_or_stop="$1"

    [[ "${#CONTAINERS[@]}" -eq 0 ]] && return 0  # no containers defined, return
    #docker "$start_or_stop" "${CONTAINERS[@]}" || fail "${start_or_stop}ing container(s) [${CONTAINERS[*]}] failed w/ [$?]"


    if [[ "$start_or_stop" == stop ]]; then
        for c in "${CONTAINERS[@]}"; do
            docker stop "$c" || fail "stopping container [$c] failed w/ [$?]"
        done
    else
        for (( idx=${#CONTAINERS[@]}-1 ; idx>=0 ; idx-- )); do
            c="${CONTAINERS[idx]}"
            docker start "$c" || fail "starting container [$c] failed w/ [$?]"
        done
    fi

    return 0
}


is_dir_empty() {
    local dir

    readonly dir="$1"

    [[ -d "$dir" ]] || fail "[$dir] is not a valid dir."
    find "$dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .
    [[ $? -eq 0 ]] && return 1 || return 0
}


confirm() {
    local msg yno

    readonly msg="$1"

    while : ; do
        [[ -n "$msg" ]] && echo -e "$msg"
        read -r yno
        case "${yno^^}" in
            Y | YES )
                echo "Ok, continuing...";
                return 0
                ;;
            N | NO )
                echo "Abort.";
                return 1
                ;;
            *)
                echo "incorrect answer; try again. (y/n accepted)"
                ;;
        esac
    done
}


fail() {
    err -F "$@"
    exit 1
}


# info lvl logging
log() {
    local msg
    readonly msg="$1"
    echo -e "[$(date "$LOG_TIMESTAMP_FORMAT")] [$JOB_ID]\tINFO  $msg" | tee -a "$LOG"
    return 0
}


err() {
    local opt msg f no_notif OPTIND no_mail_orig

    no_mail_orig="$NO_SEND_MAIL"

    while getopts "FNM" opt; do
        case "$opt" in
            F) f='-F'
                ;;
            N) no_notif=1
                ;;
            M) NO_SEND_MAIL=true
                ;;
            *) fail -N "$FUNCNAME called with unsupported flag(s)"
                ;;
        esac
    done
    shift "$((OPTIND-1))"

    readonly msg="$1"
    echo -e "[$(date "$LOG_TIMESTAMP_FORMAT")] [$JOB_ID]\t    ERROR  $msg" | tee -a "$LOG"
    [[ "$no_notif" -ne 1 ]] && notif $f "$msg"

    NO_SEND_MAIL="$no_mail_orig"  # reset to previous value
}


notif() {
    local msg f

    [[ "$1" == '-F' ]] && { f='-F'; shift; }
    [[ "$-" == *i* || "$NO_NOTIF" == true ]] && return 0

    readonly msg="$1"

    if [[ "$ERR_NOTIF" == *mail* && "$NO_SEND_MAIL" != true ]]; then
        mail $f -t "$MAIL_TO" -f "$MAIL_FROM" -s "$NOTIF_SUBJECT" -a "$SMTP_ACCOUNT" -b "$msg"
    fi

    if [[ "$ERR_NOTIF" == *pushover* ]]; then
        pushover $f -s "$NOTIF_SUBJECT" -b "$msg"
    fi
}


mail() {
    local opt to from subj acc body is_fail OPTIND

    while getopts "Ft:f:s:b:a:" opt; do
        case "$opt" in
            F) is_fail=true
                ;;
            t) to="$OPTARG"
                ;;
            f) from="$OPTARG"
                ;;
            s) subj="$OPTARG"
                ;;
            b) body="$OPTARG"
                ;;
            a) acc="$OPTARG"
                ;;
            *) fail -N "$FUNCNAME called with unsupported flag(s)"
                ;;
        esac
    done
    shift "$((OPTIND-1))"

    msmtp -a "${acc:-default}" --read-envelope-from -t <<EOF
To: $to
From: $(expand_placeholders "${from:-$DEFAULT_MAIL_FROM}" "$is_fail")
Subject: $(expand_placeholders "${subj:-$DEFAULT_NOTIF_SUBJECT}" "$is_fail")

$(expand_placeholders "${body:-NO MESSAGE BODY PROVIDED}" "$is_fail")
EOF

    [[ $? -ne 0 ]] && err -N "sending mail failed w/ [$?]"
}


pushover() {
    local opt is_fail subj body OPTIND

    while getopts "Fs:b:" opt; do
        case "$opt" in
            F) is_fail=true
                ;;
            s) subj="$OPTARG"
                ;;
            b) body="$OPTARG"
                ;;
            *) fail -N "$FUNCNAME called with unsupported flag(s)"
                ;;
        esac
    done
    shift "$((OPTIND-1))"

    curl -sSLf \
        --form-string "token=$PUSHOVER_APP_TOKEN" \
        --form-string "user=$PUSHOVER_USER_KEY" \
        --form-string "title=$(expand_placeholders "${subj:-$DEFAULT_NOTIF_SUBJECT}" "$is_fail")" \
        --form-string "message=$(expand_placeholders "${body:-NO MESSAGE BODY PROVIDED}" "$is_fail")" \
        --form-string "priority=${PUSHOVER_PRIORITY:-1}" \
        --form-string "timestamp=$(date +%s)" \
        "https://api.pushover.net/1/messages.json" || err -N "sending pushover notification failed w/ [$?]"
}


validate_config_common() {
    local i vars val

    declare -a vars
    if [[ -n "$ERR_NOTIF" ]]; then
        for i in $ERR_NOTIF; do
            [[ "$i" == mail || "$i" == pushover ]] || fail "unsupported [ERR_NOTIF] value: [$i]"
        done

        if [[ "$ERR_NOTIF" == *mail* ]]; then
            vars+=(MAIL_TO)

            [[ -f "$MSMTPRC" && -s "$MSMTPRC" ]] || vars+=(
                SMTP_HOST
                SMTP_USER
                SMTP_PASS
            )
        fi

        if [[ "$ERR_NOTIF" == *pushover* ]]; then
            vars+=(
                PUSHOVER_APP_TOKEN
                PUSHOVER_USER_KEY
            )

        fi
    fi

    for i in "${vars[@]}"; do
        val="$(eval echo "\$$i")" || fail "evaling [echo \"\$$i\"] failed w/ [$?]"
        [[ -z "$val" ]] && fail "[$i] is not defined"
    done
}


expand_placeholders() {
    local m is_fail

    m="$1"
    is_fail="${2:-false}"

    m="$(sed "s/{h}/$HOST_NAME/g" <<< "$m")"
    m="$(sed "s/{p}/$ARCHIVE_PREFIX/g" <<< "$m")"
    m="$(sed "s/{i}/$JOB_ID/g" <<< "$m")"
    m="$(sed "s/{f}/$is_fail/g" <<< "$m")"

    echo "$m"
}


source /env_vars.sh || fail "failed to import /env_vars.sh"
[[ -f "$PUSHOVER_CONF" ]] && source "$PUSHOVER_CONF"

