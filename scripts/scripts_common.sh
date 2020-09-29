#!/usr/bin/env bash
#
# common vars & functions

readonly BACKUP_ROOT='/backup'
readonly CONF_ROOT='/config'
readonly SCRIPTS_ROOT="$CONF_ROOT/scripts"

readonly CRON_FILE="$CONF_ROOT/crontab"
readonly MSMTPRC="$CONF_ROOT/msmtprc"
readonly SSH_KEY="$CONF_ROOT/id_rsa"
readonly LOG_TIMESTAMP_FORMAT='+%F %T'

readonly DEFAULT_LOCAL_REPO_NAME=repo
readonly DEFAULT_MAIL_FROM='{h} backup reporter'
readonly DEFAULT_MAIL_SUBJECT='[{p}] backup error on {h}'
JOB_ID="id-$$"  # default id for logging


check_dependencies() {
    local i

    for i in docker mysql mysqldump borg ssh-keygen ssh-keyscan tr sed msmtp; do
        command -v "$i" >/dev/null || fail "[$i] not installed"
    done
}


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
    err --fail "$@"
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
    local msg f

    [[ "$1" == '--fail' ]] && { f='--fail'; shift; }

    readonly msg="$1"
    echo -e "[$(date "$LOG_TIMESTAMP_FORMAT")] [$JOB_ID]\t    ERROR  $msg" | tee -a "$LOG"
    notif $f "$msg"
}


notif() {
    local msg f

    [[ "$1" == '--fail' ]] && { f='-F'; shift; }
    [[ "$-" == *i* || "$NO_NOTIF" == true ]] && return 0

    readonly msg="$1"

    if [[ "$ERR_NOTIF" == *mail* && "$NO_SEND_MAIL" != true ]]; then
        mail $f -t "$MAIL_TO" -f "$MAIL_FROM" -s "$MAIL_SUBJECT" -a "$SMTP_ACCOUNT" -b "$msg"
    fi
}


mail() {
    local opt to from subj acc body is_fail

    is_fail=false

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
            *) fail "$FUNCNAME called with unsupported flag(s)"
                ;;
        esac
    done

    msmtp -a "${acc:-default}" --read-envelope-from -t <<EOF
To: $to
From: $(expand_placeholders "${from:-$DEFAULT_MAIL_FROM}" "$is_fail")
Subject: $(expand_placeholders "${subj:-$DEFAULT_MAIL_SUBJECT}" "$is_fail")

$(expand_placeholders "${body:-NO MESSAGE BODY PROVIDED}" "$is_fail")
EOF
}


validate_config_common() {
    local i vars val

    if [[ -n "$ERR_NOTIF" ]]; then
        for i in $ERR_NOTIF; do
            [[ "$i" == mail || "$i" == unraid ]] || fail "unsupported [ERR_NOTIF] value: [$i]"
        done

        if [[ "$ERR_NOTIF" == *mail* ]]; then
            declare -a vars=(
                MAIL_TO
            )

            [[ -f "$MSMTPRC" && -s "$MSMTPRC" ]] || vars+=(
                SMTP_HOST
                SMTP_USER
                SMTP_PASS
            )

            for i in "${vars[@]}"; do
                val="$(eval echo "\$$i")" || fail "evaling [echo \"\$$i\"] failed w/ [$?]"
                [[ -z "$val" ]] && fail "[$i] is not defined"
            done
        fi
    fi
}


expand_placeholders() {
    local m is_fail
    m="$1"
    is_fail="$2"

    m="$(sed "s/{h}/$HOST_NAME/g" <<< "$m")"
    m="$(sed "s/{p}/$ARCHIVE_PREFIX/g" <<< "$m")"
    m="$(sed "s/{i}/$JOB_ID/g" <<< "$m")"
    m="$(sed "s/{f}/$is_fail/g" <<< "$m")"

    echo "$m"
}


source /env_vars.sh || fail "failed to import /env_vars.sh"
check_dependencies
