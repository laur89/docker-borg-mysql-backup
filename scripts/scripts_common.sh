#!/usr/bin/env bash
#
# common vars & functions

readonly CONF_ROOT='/config'
readonly SCRIPTS_ROOT="$CONF_ROOT/scripts"

readonly CRON_FILE="$CONF_ROOT/crontab"
readonly MSMTPRC="$CONF_ROOT/msmtprc"
readonly LOGROTATE_CONF="$CONF_ROOT/logrotate.conf"
readonly ENV_CONF="$CONF_ROOT/env.conf"
readonly SSH_KEY="$CONF_ROOT/id_rsa"
LOG_TIMESTAMP_FORMAT='+%F %T'
readonly DEFAULT_NOTIF_TAIL_MSG='\n
----------------
host: {h}
archive prefix: {p}
job id: {i}
fatal?: {f}'


DEFAULT_MAIL_FROM='{h} backup reporter'
DEFAULT_NOTIF_SUBJECT='{p}: backup error on {h}'
CURL_FLAGS=(
    -w '\n'
    --max-time 6
    --connect-timeout 3
    -s -S --fail -L
)

export BORG_RSH='ssh -oBatchMode=yes'  # https://borgbackup.readthedocs.io/en/stable/usage/notes.html#ssh-batch-mode

# No one can answer if Borg asks these questions, it is better to just fail quickly
# instead of hanging: (from https://borgbackup.readthedocs.io/en/stable/deployment/automated-local.html#configuring-the-system)
export BORG_RELOCATED_REPO_ACCESS_IS_OK=no
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=no


stop_containers() {
    local c

    [[ "${#CONTAINERS[@]}" -eq 0 ]] && return 0  # no containers defined, return

    for c in "${CONTAINERS[@]}"; do
        log "=> stopping container [$c]..."
        docker stop "$c" || fail "stopping container [$c] failed w/ [$?]"
    done

    log "=> all containers stopped"

    return 0
}


start_containers() {
    local c idx

    [[ "${#CONTAINERS[@]}" -eq 0 ]] && return 0  # no containers defined, return

    for (( idx=${#CONTAINERS[@]}-1 ; idx>=0 ; idx-- )); do
        c="${CONTAINERS[idx]}"
        log "=> starting container [$c]..."
        docker start "$c" || fail "starting container [$c] failed w/ [$?]"
    done

    log "=> all containers started"

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
        [[ -n "$msg" ]] && log "$msg"
        read -r yno
        case "${yno^^}" in
            Y | YES )
                log "Ok, continuing...";
                return 0
                ;;
            N | NO )
                log "Abort.";
                return 1
                ;;
            *)
                err -N "incorrect answer; try again. (y/n accepted)"
                ;;
        esac
    done
}


fail() {
    err -F "$@"
    err -N " - ABORTING -"
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
            F) f='-F'  # only to be provided by fail() !
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


# note no notifications are generated if shell is in interactive mode
notif() {
    local msg f msg_tail

    [[ "$1" == '-F' ]] && { f='-F'; shift; }
    [[ "$-" == *i* || "$NO_NOTIF" == true ]] && return 0

    msg="$1"

    if [[ "${ADD_NOTIF_TAIL:-true}" == true ]]; then
        msg_tail="$(echo -e "${NOTIF_TAIL_MSG:-$DEFAULT_NOTIF_TAIL_MSG}")"
        msg+="$msg_tail"
    fi

    if [[ "$ERR_NOTIF" == *mail* && "$NO_SEND_MAIL" != true ]]; then
        mail $f -t "$MAIL_TO" -f "$MAIL_FROM" -s "$NOTIF_SUBJECT" -a "$SMTP_ACCOUNT" -b "$msg" &
    fi

    if [[ "$ERR_NOTIF" == *pushover* ]]; then
        pushover $f -s "$NOTIF_SUBJECT" -b "$msg" &
    fi

    if [[ "$ERR_NOTIF" == *healthchecksio* ]]; then
        hcio $f -b "$msg" &
    fi
}


mail() {
    local opt to from subj acc body is_fail err_code account OPTIND

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
            *) fail -M "$FUNCNAME called with unsupported flag(s)"
                ;;
        esac
    done
    shift "$((OPTIND-1))"

    [[ -n "$acc" ]] && declare -a account=('-a' "$acc")

    msmtp "${account[@]}" --read-envelope-from -t <<EOF
To: $to
From: $(expand_placeholders "${from:-$DEFAULT_MAIL_FROM}" "$is_fail")
Subject: $(expand_placeholders "${subj:-$DEFAULT_NOTIF_SUBJECT}" "$is_fail")

$(expand_placeholders "${body:-NO MESSAGE BODY PROVIDED}" "$is_fail")
EOF

    err_code="$?"
    [[ "$err_code" -ne 0 ]] && err -M "sending mail failed w/ [$err_code]"
}


pushover() {
    local opt is_fail subj body prio retry expire hdrs OPTIND

    while getopts "Fs:b:p:r:e:" opt; do
        case "$opt" in
            F) is_fail=true
                ;;
            s) subj="$OPTARG"
                ;;
            b) body="$OPTARG"
                ;;
            p) prio="$OPTARG"
                ;;
            r) retry="$OPTARG"
                ;;
            e) expire="$OPTARG"
                ;;
            *) fail -N "$FUNCNAME called with unsupported flag(s)"
                ;;
        esac
    done
    shift "$((OPTIND-1))"

    [[ -z "$prio" ]] && prio="${PUSHOVER_PRIORITY:-1}"

    declare -a hdrs
    if [[ "$prio" -eq 2 ]]; then  # emergency priority
        [[ -z "$retry" ]] && retry="${PUSHOVER_RETRY:-60}"
        [[ "$retry" -lt 30 ]] && retry=30  # as per pushover docs

        [[ -z "$expire" ]] && expire="${PUSHOVER_EXPIRE:-3600}"
        [[ "$expire" -gt 10800 ]] && expire=10800  # as per pushover docs

        hdrs+=(
            --form-string "retry=$retry"
            --form-string "expire=$expire"
        )
    fi

    curl "${CURL_FLAGS[@]}" \
        --retry 2 \
        --form-string "token=$PUSHOVER_APP_TOKEN" \
        --form-string "user=$PUSHOVER_USER_KEY" \
        --form-string "title=$(expand_placeholders "${subj:-$DEFAULT_NOTIF_SUBJECT}" "$is_fail")" \
        --form-string "message=$(expand_placeholders "${body:-NO MESSAGE BODY PROVIDED}" "$is_fail")" \
        --form-string "priority=$prio" \
        "${hdrs[@]}" \
        --form-string "timestamp=$(date +%s)" \
        "https://api.pushover.net/1/messages.json" || err -N "sending pushover notification failed w/ [$?]"
}


hcio() {
    local opt is_fail body OPTIND url

    while getopts "Fb:" opt; do
        case "$opt" in
            F) is_fail=true
                ;;
            b) body="$OPTARG"
                ;;
            *) fail -N "$FUNCNAME called with unsupported flag(s)"
                ;;
        esac
    done
    shift "$((OPTIND-1))"

    url="$HC_URL"
    [[ "$url" != */ ]] && url+='/'
    url+='fail'

    curl "${CURL_FLAGS[@]}" \
        --retry 5 \
        --user-agent "$HOST_NAME" \
        --data-raw "$(expand_placeholders "${body:-NO MESSAGE BODY PROVIDED}" "$is_fail")" \
        "$url" || err -N "pinging healthchecks.io endpoint [$url] failed w/ [$?]"
}


add_remote_to_known_hosts_if_missing() {
    local input host

    input="$1"
    [[ -z "$input" ]] && return 0

    host="${input#*@}"  # everything after '@'
    host="${host%%:*}"  # everything before ':'

    [[ -z "$host" ]] && fail "could not extract host from remote [$input]"

    if [[ -z "$(ssh-keygen -F "$host")" ]]; then
        ssh-keyscan -H "$host" >> "$HOME/.ssh/known_hosts" || fail "adding host [$host] to ~/.ssh/known_hosts failed w/ [$?]"
    fi
}


validate_config_common() {
    local i vars

    declare -a vars
    if [[ -n "$ERR_NOTIF" ]]; then
        for i in $ERR_NOTIF; do
            [[ "$i" =~ ^(mail|pushover|healthchecksio)$ ]] || fail "unsupported [ERR_NOTIF] value: [$i]"
        done

        if [[ "$ERR_NOTIF" == *mail* ]]; then
            vars+=(MAIL_TO)

            [[ -f "$MSMTPRC" && -s "$MSMTPRC" ]] || vars+=(
                SMTP_HOST
                SMTP_USER
                SMTP_PASS
            )
        fi

        [[ "$ERR_NOTIF" == *pushover* ]] && vars+=(
            PUSHOVER_APP_TOKEN
            PUSHOVER_USER_KEY
        )

        # note we cannot validate healthchecksio in here - url can/will be modified by backup.sh invocation
    fi

    vars_defined "${vars[@]}"

    [[ -n "$MYSQL_FAIL_FATAL" ]] && ! is_true_false "$MYSQL_FAIL_FATAL" && fail "MYSQL_FAIL_FATAL value, when given, can be either [true] or [false]"
    [[ -n "$ADD_NOTIF_TAIL" ]] && ! is_true_false "$ADD_NOTIF_TAIL" && fail "ADD_NOTIF_TAIL value, when given, can be either [true] or [false]"
}


vars_defined() {
    local i val

    for i in "$@"; do
        val="$(eval echo "\$$i")" || fail "evaling [echo \"\$$i\"] failed w/ [$?]"
        [[ -z "$val" ]] && fail "[$i] is not defined"
    done
}


is_true_false() {
    #local i

    #i="$(tr '[:upper:]' '[:lower:]' <<< "$*")"
    #[[ "$i" == 1 ]] && i=true
    #[[ "$i" == 0 ]] && i=false

    [[ "$*" =~ ^(true|false)$ ]]
}


expand_placeholders() {
    local m is_fatal

    m="$1"
    is_fatal="${2:-false}"  # true|false; indicates whether given error caused job to abort/exit

    m="$(sed "s/{h}/$HOST_NAME/g" <<< "$m")"
    m="$(sed "s/{p}/$ARCHIVE_PREFIX/g" <<< "$m")"
    m="$(sed "s/{i}/$JOB_ID/g" <<< "$m")"
    m="$(sed "s/{f}/$is_fatal/g" <<< "$m")"

    echo "$m"
}


file_type() {
    if [[ -h "$*" ]]; then
        echo symlink
    elif [[ -f "$*" ]]; then
        echo file
    elif [[ -d "$*" ]]; then
        echo dir
    elif [[ -p "$*" ]]; then
        echo 'named pipe'
    elif [[ -c "$*" ]]; then
        echo 'character special'
    elif [[ -b "$*" ]]; then
        echo 'block special'
    elif [[ -S "$*" ]]; then
        echo socket
    elif ! [[ -e "$*" ]]; then
        echo 'does not exist'
    else
        echo UNKNOWN
    fi
}


# Checks whether given url is a valid one.
#
# @param {string}  url   url which validity to test.
#
# @returns {bool}  true, if provided url was a valid url.
is_valid_url() {
    local regex

    readonly regex='^(https?|ftp|file)://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]'

    [[ "$1" =~ $regex ]]
}


ping_healthcheck() {
    [[ -z "$HC_URL" ]] && return 0

    curl "${CURL_FLAGS[@]}" \
        --retry 5 \
        --user-agent "$HOST_NAME" \
        "$HC_URL" || err "pinging healthcheck service at [$HC_URL] failed w/ [$?]"
}


[[ -f "$ENV_CONF" ]] && source "$ENV_CONF"

true  # always exit w/ good code
