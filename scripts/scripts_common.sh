#!/usr/bin/env bash
#
# common vars & functions

set -o noglob
set -o pipefail

readonly CONF_ROOT='/config'
readonly LOG_ROOT="$CONF_ROOT/logs"  # note path is also tied to logrotate config
readonly ENV_ROOT="$CONF_ROOT/env"
readonly SCRIPT_ROOT="$CONF_ROOT/scripts"
export LOG="$LOG_ROOT/${SELF}.log"  # note SELF is defined by importing file

[[ "$SEPARATOR" == space ]] && SEPARATOR=' '
[[ "$SEPARATOR" == comma ]] && SEPARATOR=','
[[ "$SEPARATOR" == colon ]] && SEPARATOR=':'
[[ "$SEPARATOR" == semicolon ]] && SEPARATOR=';'
readonly SEPARATOR="${SEPARATOR:-,}"  # default to comma

readonly CRON_FILE="$CONF_ROOT/crontab"
readonly MSMTPRC="$CONF_ROOT/msmtprc"
readonly LOGROTATE_CONF="$CONF_ROOT/logrotate.conf"
readonly SSH_KEY="$CONF_ROOT/id_rsa"
LOG_TIMESTAMP_FORMAT='+%F %T'
readonly DEFAULT_NOTIF_TAIL_MSG='\n
----------------
host: {h}
archive prefix: {p}
job id: {i}
fatal?: {f}'
readonly ALL_DBS_MARKER='__all__'


DEFAULT_MAIL_FROM='{h} backup reporter'
DEFAULT_NOTIF_SUBJECT='{p}: backup error on {h}'
# make sure CURL_FLAGS don't contain $SEPARATOR! (as we join the array into string to export)
CURL_FLAGS=(
    -w '\n'
    --output /dev/null
    --max-time 6
    --connect-timeout 3
    -s -S --fail -L
)
declare -A CONTAINER_TO_RUNNING_STATE=()  # container_name->is_running<bool> mappings at the beginning of script
declare -a CONTAINERS_TO_START=()  # list of containers that were stopped by this script and should be started back up upon completion

export BORG_RSH='ssh -oBatchMode=yes'  # https://borgbackup.readthedocs.io/en/stable/usage/notes.html#ssh-batch-mode

# No one can answer if Borg asks these questions, it is better to just fail quickly
# instead of hanging: (from https://borgbackup.readthedocs.io/en/stable/deployment/automated-local.html#configuring-the-system)
export BORG_RELOCATED_REPO_ACCESS_IS_OK=no
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=no


stop_containers() {
    local c

    [[ "${#CONTAINERS[@]}" -eq 0 ]] && return 0  # no containers defined, return

    log "going to stop following containers before starting with backup job: [${CONTAINERS[*]}]"
    for c in "${CONTAINERS[@]}"; do
        if [[ "${CONTAINER_TO_RUNNING_STATE[$c]}" == true ]]; then
            log "=> stopping container [$c]..."
            docker stop "$c" 2> >(tee -a "$LOG" >&2) || fail "stopping container [$c] failed w/ [$?]"
            CONTAINERS_TO_START+=("$c")
        else
            log "=> container [$c] already stopped"
        fi
    done

    log "=> all containers stopped"

    return 0
}


# caller might be backgrounding!
start_containers() {
    local containers c idx err_

    containers=("$@")
    [[ "${#containers[@]}" -eq 0 ]] && return 0  # no containers given, return

    log "going to start following containers that were previously stopped by this job: [${containers[*]}]"
    for (( idx=${#containers[@]}-1 ; idx>=0 ; idx-- )); do
        c="${containers[idx]}"
        log "=> starting container [$c]..."
        docker start "$c" 2> >(tee -a "$LOG" >&2) || { err "starting container [$c] failed w/ [$?]"; err_='at least one container failed to start'; }
    done

    log "=> ${err_:-all containers started}"

    return 0
}


_compact_common() {
    local l_or_r repo start_timestamp t err_code

    l_or_r="$1"
    repo="$2"

    log "=> starting compact operation on $l_or_r repo [$repo]..."
    start_timestamp="$(date +%s)"

    borg compact --show-rc \
        $COMMON_OPTS \
        $BORG_OPTS \
        "$repo" > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || { err "$l_or_r borg compact exited w/ [$?]"; err_code=1; }

    t="$(( $(date +%s) - start_timestamp ))"
    log "=> $l_or_r compact ${err_code:-succeeded} in $(print_time "$t")"

    return "${err_code:-0}"
}


# note this is called both by compact.sh & backup.sh, so be careful by changing global vars!
compact_repos() {
    local started_pids start_timestamp i err_code t

    declare -a started_pids=()

    start_timestamp="$(date +%s)"

    if [[ "$REMOTE_ONLY" -ne 1 ]]; then
        _compact_common local "$LOCAL_REPO" &
        started_pids+=("$!")
    fi

    if [[ "$LOCAL_ONLY" -ne 1 ]]; then
        _compact_common remote "$REMOTE" &
        started_pids+=("$!")
    fi

    for i in "${started_pids[@]}"; do
        wait "$i" || err_code="$?"
    done

    t="$(( $(date +%s) - start_timestamp ))"
    log "=> Compact finished, duration $(print_time "$t")${err_code:+; at least one step failed or produced warning}"

    return "${err_code:-0}"
}


# dir existence needs to be verified by the caller!
#
# note this fun is exported
is_dir_empty() {
    local dir

    readonly dir="$1"

    [[ -d "$dir" ]] || fail "[$dir] is not a valid dir."
    find -L "$dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .
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


# note this fun is exported
fail() {
    err -F "$@"
    err -N " - ABORTING -"
    exit 1
}


# info lvl logging
#
# note this fun is exported
log() {
    local msg
    readonly msg="$1"
    echo -e "[$(date "$LOG_TIMESTAMP_FORMAT")] [$JOB_ID]\tINFO  $msg" | tee -a "$LOG"
    return 0
}


#
# note this fun is exported
err() {
    local opt msg f no_notif OPTIND no_mail_orig

    no_mail_orig="$NO_SEND_MAIL"

    while getopts 'FNM' opt; do
        case "$opt" in
            F) f='-F'  # only to be provided by fail(), ie do not pass -F flag to err() yourself!
                ;;
            N) no_notif=1
                ;;
            M) NO_SEND_MAIL=true  # note this would be redundant if -N is already given
                ;;
            *) fail -N "$FUNCNAME called with unsupported flag(s) [$opt]"
                ;;
        esac
    done
    shift "$((OPTIND-1))"

    readonly msg="$1"
    echo -e "[$(date "$LOG_TIMESTAMP_FORMAT")] [$JOB_ID]\t    ERROR  $msg" | tee -a "$LOG" >&2
    [[ "$no_notif" -ne 1 ]] && notif $f "$msg"

    NO_SEND_MAIL="$no_mail_orig"  # reset to previous value
}


# note no notifications are generated if shell is in interactive mode
#
# note this fun is exported
notif() {
    local msg f msg_tail

    [[ "$1" == '-F' ]] && { f='-F'; shift; }
    [[ "$-" == *i* || "$NO_NOTIF" == true ]] && return 0

    msg="$1"

    if [[ "${ADD_NOTIF_TAIL:-true}" == true ]]; then
        msg_tail="$(echo -e "${NOTIF_TAIL_MSG:-$DEFAULT_NOTIF_TAIL_MSG}")"
        msg+="$msg_tail"
    fi

    # if this function was called from a script that accesses this function via exported vars:
    [[ -n "${ERR_NOTIF[*]}" && "${#ERR_NOTIF[@]}" -eq 1 && "${ERR_NOTIF[*]}" == *"$SEPARATOR"* ]] && IFS="$SEPARATOR" read -ra ERR_NOTIF <<< "$ERR_NOTIF"

    if contains mail "${ERR_NOTIF[@]}" && [[ "$NO_SEND_MAIL" != true ]]; then
        mail $f -t "$MAIL_TO" -f "$MAIL_FROM" -s "$NOTIF_SUBJECT" -a "$SMTP_ACCOUNT" -b "$msg" &
    fi

    if contains pushover "${ERR_NOTIF[@]}"; then
        pushover $f -s "$NOTIF_SUBJECT" -b "$msg" &
    fi

    if contains healthchecksio "${ERR_NOTIF[@]}"; then
        hcio $f -b "$msg" &
    fi
}


#
# note this fun is exported
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
            *) fail -M "$FUNCNAME called with unsupported flag(s) [$opt]"
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


#
# note this fun is exported
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
            *) fail -N "$FUNCNAME called with unsupported flag(s) [$opt]"
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

    # if this function was called from a script that accesses this function via exported vars:
    [[ -n "${CURL_FLAGS[*]}" && "${#CURL_FLAGS[@]}" -eq 1 && "${CURL_FLAGS[*]}" == *"$SEPARATOR"* ]] && IFS="$SEPARATOR" read -ra CURL_FLAGS <<< "$CURL_FLAGS"

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


#
# note this fun is exported
hcio() {
    local opt is_fail body OPTIND url

    while getopts "Fb:" opt; do
        case "$opt" in
            F) is_fail=true
                ;;
            b) body="$OPTARG"
                ;;
            *) fail -N "$FUNCNAME called with unsupported flag(s) [$opt]"
                ;;
        esac
    done
    shift "$((OPTIND-1))"

    url="$HC_URL"
    [[ "$url" != */ ]] && url+='/'
    url+='fail'

    # if this function was called from a script that accesses this function via exported vars:
    [[ -n "${CURL_FLAGS[*]}" && "${#CURL_FLAGS[@]}" -eq 1 && "${CURL_FLAGS[*]}" == *"$SEPARATOR"* ]] && IFS="$SEPARATOR" read -ra CURL_FLAGS <<< "$CURL_FLAGS"

    curl "${CURL_FLAGS[@]}" \
        --retry 5 \
        --user-agent "$HOST_ID" \
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


# note this validation can't be called for anything else than backup & notif-test scripts;
# eg list/extract scripts shouldn't validate existence of SMTP_* env vars.
# !! it's also called by setup.sh, but with -i flag to skip some checks.
#
# also note we expand the ERR_NOTIF env var into an array here!
validate_config_common() {
    local i vars init

    [[ "$1" == -i ]] && init=1

    declare -a vars

    if [[ "$init" -ne 1 ]]; then
        if [[ -n "$HC_ID" ]]; then
            if is_valid_url "$HC_ID"; then
                HC_URL="$HC_ID"
            elif [[ "$HC_ID" == disable* ]]; then
                unset HC_URL
            elif [[ -z "$HC_URL" ]]; then
                err "[HC_ID] given, but no healthcheck url template provided"
            elif [[ "$HC_URL" != *'{id}'* ]]; then
                err "[HC_URL] template does not contain id placeholder [{id}]"
            else
                HC_URL="$(sed "s/{id}/$HC_ID/g" <<< "$HC_URL")"
            fi
        fi

        if [[ "$HC_URL" == *'{id}'* ]]; then
            err "[HC_URL] with {id} placeholder defined, but no replacement value provided"
        fi
    fi

    IFS="$SEPARATOR" read -ra ERR_NOTIF <<< "$ERR_NOTIF"

    if [[ "${#ERR_NOTIF[@]}" -gt 0 ]]; then
        for i in "${ERR_NOTIF[@]}"; do
            [[ "$i" =~ ^(mail|pushover|healthchecksio)$ ]] || fail "unsupported [ERR_NOTIF] value: [$i]"
        done

        if contains mail "${ERR_NOTIF[@]}"; then
            vars+=(MAIL_TO)

            [[ -f "$MSMTPRC" && -s "$MSMTPRC" ]] || vars+=(
                SMTP_HOST
                SMTP_USER
                SMTP_PASS
            )
        fi

        contains pushover "${ERR_NOTIF[@]}" && vars+=(
            PUSHOVER_APP_TOKEN
            PUSHOVER_USER_KEY
        )

        if [[ "$init" -ne 1 ]] && contains healthchecksio "${ERR_NOTIF[@]}"; then
            #vars+=(HC_URL)

            local hcio_rgx='^https?://hc-ping.com/[-a-z0-9]+/?$'
            if ! [[ "$HC_URL" =~ $hcio_rgx ]]; then
                err "healthchecksio selected for notifications, but configured HC_URL [$HC_URL] does not match expected healthchecks.io url pattern [$hcio_rgx]"
            fi
        fi
    fi

    vars_defined "${vars[@]}"

    vars=()  # reset
    [[ -n "$MYSQL_FAIL_FATAL" ]] && vars+=(MYSQL_FAIL_FATAL)
    [[ -n "$POSTGRES_FAIL_FATAL" ]] && vars+=(POSTGRES_FAIL_FATAL)
    [[ -n "$ADD_NOTIF_TAIL" ]] && vars+=(ADD_NOTIF_TAIL)
    [[ -n "$SCRIPT_FAIL_FATAL" ]] && vars+=(SCRIPT_FAIL_FATAL)
    validate_true_false "${vars[@]}"

    validate_containers
}


# validate valid container names have been given
# and store their current running state globally
validate_containers() {
    local c running

    [[ "${#CONTAINERS[@]}" -eq 0 ]] && return 0

    for c in "${CONTAINERS[@]}"; do
        running="$(docker container inspect -f '{{.State.Running}}' "$c")"
        if [[ "$?" -ne 0 ]]; then
            # TODO: should we fail here instead?
            err "container [$c] inspection failed - does the container exist?"
        else
            is_true_false "$running" || err "container [$c] inspection result not true|false: [$running]"
            CONTAINER_TO_RUNNING_STATE[$c]="$running"
        fi
    done
}


vars_defined() {
    local i val

    for i in "$@"; do
        val="$(eval echo "\$$i")" || fail "evaling [echo \"\$$i\"] failed w/ [$?]"
        [[ -z "$val" ]] && fail "[$i] is not defined"
    done
}


validate_true_false() {
    local i val

    for i in "$@"; do
        val="$(eval echo "\$$i")" || fail "evaling [echo \"\$$i\"] failed w/ [$?]"
        is_true_false "$val" || fail "$i value, when given, can be either [true] or [false]"
    done
}


is_true_false() {
    [[ "$*" =~ ^(true|false)$ ]]
}


#
# note this fun is exported
expand_placeholders() {
    local m is_fatal

    m="$1"
    is_fatal="${2:-false}"  # true|false; indicates whether given error caused job to abort/exit

    m="$(sed "s/{h}/$HOST_ID/g" <<< "$m")"
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
#
# note this fun is exported
is_valid_url() {
    local regex

    readonly regex='^(https?|ftp|file)://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]'

    [[ "$1" =~ $regex ]]
}


ping_healthcheck() {
    [[ -z "$HC_URL" ]] && return 0

    curl "${CURL_FLAGS[@]}" \
        --retry 5 \
        --user-agent "$HOST_ID" \
        "$HC_URL" || err "pinging healthcheck service at [$HC_URL] failed w/ [$?]"
}


run_scripts() {
    local stage dir flags msg

    stage="$1"

    flags=()
    [[ "${SCRIPT_FAIL_FATAL:-true}" == true ]] && flags+=('--exit-on-error')
    flags+=(
        -a "$stage"
        -a "$ARCHIVE_PREFIX"
        -a "$TMP"
        -a "$CONF_ROOT"
        -a "$(join -- "${NODES_TO_BACK_UP[@]}")"
        -a "$(join -- "${CONTAINERS[@]}")"
    )

    # export all the necessary args & functions that child processes might want/need to use:
    export LOG LOG_TIMESTAMP_FORMAT JOB_ID ARCHIVE_PREFIX HOST_ID SEPARATOR
    export NO_SEND_MAIL NO_NOTIF ADD_NOTIF_TAIL NOTIF_TAIL_MSG DEFAULT_NOTIF_TAIL_MSG
    export MAIL_TO MAIL_FROM DEFAULT_MAIL_FROM NOTIF_SUBJECT DEFAULT_NOTIF_SUBJECT SMTP_ACCOUNT
    export PUSHOVER_USER_KEY PUSHOVER_APP_TOKEN PUSHOVER_PRIORITY PUSHOVER_EXPIRE
    export HC_URL
    #export ERR_NOTIF CURL_FLAGS  # arrays, need to be joined and passed directly to the command below
    export -f fail err log notif mail pushover hcio expand_placeholders contains is_dir_empty print_time is_valid_url


    for dir in \
            "$SCRIPT_ROOT/each" \
            "$SCRIPT_ROOT/$stage" \
            "$JOB_SCRIPT_ROOT/each" \
            "$JOB_SCRIPT_ROOT/$stage"; do

        [[ -d "$dir" ]] || continue
        is_dir_empty "$dir" && continue

        log "stage [$stage]: executing following scripts in [$dir]:"
        run-parts --test "${flags[@]}" "$dir" > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || err "run-parts dry-run for stage [$stage] in [$dir] failed w/ $?"

        ERR_NOTIF="$(join -- "${ERR_NOTIF[@]}")" \
                CURL_FLAGS="$(join -- "${CURL_FLAGS[@]}")" \
                run-parts "${flags[@]}" "$dir" 2> >(tee -a "$LOG" >&2)  # no need to log stdout right?
        if [[ "$?" -ne 0 ]]; then
            msg="custom script execution for stage [$stage] in [$dir] failed"
            [[ "${SCRIPT_FAIL_FATAL:-true}" == true ]] && fail "${msg}; aborting" || err "${msg}; not aborting"
        fi
    done
}


#
# note this fun is exported
contains() {
    local src i

    [[ "$#" -lt 2 ]] && { err "at least 2 args needed for $FUNCNAME"; return 2; }

    src="$1"
    shift

    for i in "$@"; do
        [[ "$i" == "$src" ]] && return 0
    done

    return 1
}


join() {
    local opt OPTIND sep list i

    sep="$SEPARATOR"  # default

    while getopts "s:" opt; do
        case "$opt" in
            s) sep="$OPTARG"
                ;;
            *) fail "$FUNCNAME called with unsupported flag(s) [$opt]"
                ;;
        esac
    done
    shift "$((OPTIND-1))"

    for i in "$@"; do
        [[ -z "$i" ]] && continue
        list+="${i}$sep"
    done

    echo "${list:0:$(( ${#list} - ${#sep} ))}"
}


#
# note this fun is exported
print_time() {
    local sec tot r

    sec="$1"

    tot=$((sec%60))
    r="${tot}s"

    if [[ "$sec" -gt "$tot" ]]; then
        r="$((sec%3600/60))m:$r"
        let tot+=$((sec%3600))
    fi

    if [[ "$sec" -gt "$tot" ]]; then
        r="$((sec%86400/3600))h:$r"
        let tot+=$((sec%86400))
    fi

    if [[ "$sec" -gt "$tot" ]]; then
        r="$((sec/86400))d:$r"
    fi

    echo -n "$r"
}


mkdir -p "$LOG_ROOT" || { echo -e "    ERROR: [mkdir -p $LOG_ROOT] failed w/ $?" >&2; exit 1; }
[[ -f "$ENV_ROOT/common-env.conf" ]] && source "$ENV_ROOT/common-env.conf"

if [[ "$DEBUG" == true ]]; then
    set -x
    printenv
    echo
fi

true  # always exit common w/ good code
