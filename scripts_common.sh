#!/bin/bash
#
# common vars & functions

readonly BACKUP_ROOT='/backup'
readonly CRON_FILE='/config/crontab'
readonly SSH_KEY='/config/id_rsa'


check_dependencies() {
    local i

    for i in docker mysql mysqldump borg ssh-keygen ssh-keyscan; do
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
    local msg
    readonly msg="$1"
    echo -e "\n\n    ERROR: $msg\n\n"
    exit 1
}
