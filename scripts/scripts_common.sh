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
JOB_ID="id-$$"  # default id for logging


check_dependencies() {
    local i

    for i in docker mysql mysqldump borg ssh-keygen ssh-keyscan flock tr sed msmtp; do
        command -v "$i" >/dev/null || fail "[$i] not installed"
    done
}


start_or_stop_containers() {
    local start_or_stop

    readonly start_or_stop="$1"; shift

    [[ "$#" -eq 0 ]] && return 0  # no container names were passed, return
    docker "$start_or_stop" "$@" || fail "${start_or_stop}ing container(s) [$*] failed"

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

    [[ "$1" == '--fail' ]] && { f=1; shift; }

    readonly msg="$1"
    echo -e "\n\n    ERROR: $msg\n\n"
    echo -e "[$(date "$LOG_TIMESTAMP_FORMAT")] [$JOB_ID]\t    ERROR  $msg" | tee -a "$LOG"
    notif "$msg"
}


notif() {
    local msg
    readonly msg="$1"

    mail "$msg"
}


# TODO: WIP
mail() {
    local body

    body="$1"

    msmtp -a default --read-envelope-from -t <<EOF
To: $MAIL_TO
From: $MAIL_FROM
Subject: $MAIL_SUBJECT

TEST: $body
EOF

}


source /env_vars.sh || fail "failed to import /env_vars.sh"
check_dependencies
