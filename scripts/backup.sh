#!/usr/bin/env bash
#
# backs up mysql dump and/or other data to local and/or remote borg repository

readonly SELF="${0##*/}"
readonly LOG="/var/log/${SELF}.log"

readonly usage="
    usage: $SELF [-h] [-d MYSQL_DBS] [-c CONTAINERS] [-rl]
                  [-P BORG_PRUNE_OPTS] [-B|-Z BORG_EXTRA_OPTS] [-L LOCAL_REPO]
                  [-e ERR_NOTIF] [-A SMTP_ACCOUNT] [-D MYSQL_FAIL_FATAL]
                  [-R REMOTE] [-T REMOTE_REPO] [-H HC_ID] -p PREFIX  [NODES_TO_BACK_UP...]

    Create new archive

    arguments:
      -h                      show help and exit
      -d MYSQL_DBS            space separated database names to back up; use value of
                              __all__ to back up all dbs on the server
      -c CONTAINERS           space separated container names to stop for the backup process;
                              requires mounting the docker socket (-v /var/run/docker.sock:/var/run/docker.sock);
                              note containers will be stopped in given order; after backup
                              completion, containers are started in reverse order;
      -r                      only back to remote borg repo (remote-only)
      -l                      only back to local borg repo (local-only)
      -P BORG_PRUNE_OPTS      overrides container env variable BORG_PRUNE_OPTS; only required when
                              container var is not defined or needs to be overridden;
      -B BORG_EXTRA_OPTS      additional borg params; note it doesn't overwrite
                              the BORG_EXTRA_OPTS env var, but extends it;
      -Z BORG_EXTRA_OPTS      additional borg params; note it _overrides_
                              the BORG_EXTRA_OPTS env var;
      -L LOCAL_REPO           overrides container env variable of same name;
      -e ERR_NOTIF            space separated error notification methods; overrides
                              env var of same name;
      -A SMTP_ACCOUNT         msmtp account to use; overrides env var of same name;
      -D MYSQL_FAIL_FATAL     whether unsuccessful db dump should abort backup; overrides
                              env var of same name; true|false
      -R REMOTE               remote connection; overrides env var of same name
      -T REMOTE_REPO          path to repo on remote host; overrides env var of same name
      -H HC_ID                the unique/id part of healthcheck url, replacing the '{id}'
                              placeholder in HC_URL; may also provide new full url to call
                              instead, overriding the env var HC_URL
      -p PREFIX               borg archive name prefix. note that the full archive name already
                              contains HOST_NAME and timestamp, so omit those.
      NODES_TO_BACK_UP...     last arguments to $SELF are files&directories to be
                              included in the backup
"

# expands the $NODES_TO_BACK_UP with files in $TMP/, if there are any
expand_nodes_to_back_up() {
    local i

    is_dir_empty "$TMP" && return 0

    while IFS= read -r -d $'\0' i; do
        NODES_TO_BACK_UP+=("$(basename -- "$i")")  # note relative path; we don't want borg archive to contain "$TMP_ROOT" path
    done < <(find "$TMP" -mindepth 1 -maxdepth 1 -print0)
}


# dumps selected db(s) to $TMP
dump_db() {
    local output_filename dbs dbs_log err_code start_timestamp err_
    local -

    set -o noglob

    [[ "${#MYSQL_DB[@]}" -eq 0 ]] && return 0  # no db specified, meaning db dump not required

    if [[ "${MYSQL_DB[*]}" == __all__ ]]; then
        dbs_log='all databases'
        output_filename='all-dbs'
        dbs=('--all-databases')
    else
        dbs_log="databases [${MYSQL_DB[*]}]"
        output_filename="$(tr ' ' '+' <<< "${MYSQL_DB[*]}")"  # let the filename reflect which dbs it contains
        dbs=('--databases' "${MYSQL_DB[@]}")
    fi

    log "=> starting db dump for ${dbs_log}..."
    start_timestamp="$(date +%s)"

    # TODO: add following column-stats option back once mysqldump from alpine accepts it:
            #--column-statistics=0 \
    mysqldump \
            --add-drop-database \
            --max-allowed-packet=512M \
            --host="${MYSQL_HOST}" \
            --port="${MYSQL_PORT}" \
            --user="${MYSQL_USER}" \
            --password="${MYSQL_PASS}" \
            ${MYSQL_EXTRA_OPTS} \
            "${dbs[@]}" > "$TMP/${output_filename}.sql" 2> >(tee -a "$LOG" >&2)

    err_code="$?"
    if [[ "$err_code" -ne 0 ]]; then
        local msg
        msg="db dump for input args [${MYSQL_DB[*]}] failed w/ [$err_code]"
        [[ "${MYSQL_FAIL_FATAL:-true}" == true ]] && fail "$msg" || err "$msg"
        err_=failed
    fi

    log "=> db dump ${err_:-succeeded} in $(( $(date +%s) - start_timestamp )) seconds"
}


# TODO: should we skip prune if create exits w/ code >=2?
_backup_common() {
    local l_or_r repo extra_opts start_timestamp err_code err_
    local -

    set -o noglob

    l_or_r="$1"
    repo="$2"
    extra_opts="$3"

    log "=> starting $l_or_r backup..."
    start_timestamp="$(date +%s)"

    borg create --stats --show-rc \
        $BORG_EXTRA_OPTS \
        $extra_opts \
        "${repo}::${ARCHIVE_NAME}" \
        "${NODES_TO_BACK_UP[@]}" > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || { err "$l_or_r borg create exited w/ [$?]"; err_code=1; err_=failed; }
    log "=> $l_or_r backup ${err_:-succeeded} in $(( $(date +%s) - start_timestamp )) seconds"

    unset err_  # reset

    log "=> starting $l_or_r prune..."
    start_timestamp="$(date +%s)"

    borg prune --show-rc \
        "$repo" \
        --prefix "$PREFIX_WITH_HOSTNAME" \
        $BORG_PRUNE_OPTS > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || { err "$l_or_r borg prune exited w/ [$?]"; err_code=1; err_=failed; }
    log "=> $l_or_r prune ${err_:-succeeded} in $(( $(date +%s) - start_timestamp )) seconds"

    return "${err_code:-0}"
}


backup_local() {
    _backup_common local "${LOCAL_REPO}" "$BORG_LOCAL_EXTRA_OPTS"
}


backup_remote() {
    _backup_common remote "${REMOTE}" "$BORG_REMOTE_EXTRA_OPTS"
}


# backup selected data
# note the borg processes are executed in a sub-shell, so local & remote backup could be
# run in parallel
do_backup() {
    local started_pids start_timestamp i err_

    declare -a started_pids=()

    log "=> Backup started"
    start_timestamp="$(date +%s)"

    dump_db
    expand_nodes_to_back_up

    [[ "${#NODES_TO_BACK_UP[@]}" -eq 0 ]] && fail "no items selected for backup"

    pushd -- "$TMP" &> /dev/null || fail "unable to pushd into [$TMP]"  # cd there because files in $TMP are added without full path (to avoid "$TMP_ROOT" prefix in borg repo)

    # note! log files/types out _after_ pushd to $TMP, otherwise some files would not resolve
    log "following ${#NODES_TO_BACK_UP[@]} files will be backed up:"
    for i in "${NODES_TO_BACK_UP[@]}"; do
        log "     - $i   (type: $(file_type "$i"))"
    done

    if [[ "$REMOTE_ONLY" -ne 1 ]]; then
        backup_local &
        started_pids+=("$!")
    fi

    if [[ "$LOCAL_ONLY" -ne 1 ]]; then
        backup_remote &
        started_pids+=("$!")
    fi

    for i in "${started_pids[@]}"; do
        wait "$i" || err_=TRUE
    done

    popd &> /dev/null
    log "=> Backup finished, duration $(( $(date +%s) - start_timestamp )) seconds${err_:+; at least one step failed or produced warning}"

    return 0
}


validate_config() {
    local i vars

    validate_config_common

    declare -a vars=(
        ARCHIVE_PREFIX
        BORG_PASSPHRASE
        BORG_PRUNE_OPTS
        HOST_NAME
    )
    [[ -n "${MYSQL_DB[*]}" ]] && vars+=(
        MYSQL_HOST
        MYSQL_PORT
        MYSQL_USER
        MYSQL_PASS
    )
    [[ "$LOCAL_ONLY" -ne 1 ]] && vars+=(REMOTE REMOTE_REPO)
    [[ "$REMOTE_ONLY" -ne 1 ]] && vars+=(LOCAL_REPO)

    vars_defined "${vars[@]}"

    if [[ "${#NODES_TO_BACK_UP[@]}" -gt 0 ]]; then
        for i in "${NODES_TO_BACK_UP[@]}"; do
            [[ -e "$i" ]] || err "node [$i] to back up does not exist; missing mount?"
        done
    elif [[ "${#MYSQL_DB[@]}" -eq 0 || -z "${MYSQL_DB[*]}" ]]; then
        fail "no databases nor nodes selected for backup - nothing to do!"
    fi

    [[ "$REMOTE_OR_LOCAL_OPT_COUNTER" -gt 1 ]] && fail "-r & -l options are exclusive"
    [[ "$BORG_OTPS_COUNTER" -gt 1 ]] && fail "-B & -Z options are exclusive"
    [[ "$REMOTE_ONLY" -ne 1 ]] && [[ ! -d "$LOCAL_REPO" || ! -w "$LOCAL_REPO" ]] && fail "[$LOCAL_REPO] does not exist or is not writable; missing mount?"

    if [[ "$LOCAL_ONLY" -ne 1 && "$-" != *i* ]]; then
        [[ -f "$SSH_KEY" ]] || fail "[$SSH_KEY] is not a file; is /config mounted?"
    fi


    if [[ -n "$HC_ID" ]]; then
        if is_valid_url "$HC_ID"; then
            HC_URL="$HC_ID"
        elif [[ "$HC_ID" == disable* ]]; then
            unset HC_URL
        elif [[ -z "$HC_URL" ]]; then
            err "[HC_ID] given, but no healthcheck url template provided"
        elif ! [[ "$HC_URL" =~ '{id}' ]]; then
            err "[HC_URL] template does not contain id placeholder [{id}]"
        else
            HC_URL="$(sed "s/{id}/$HC_ID/g" <<< "$HC_URL")"
        fi
    fi
    if [[ -n "$HC_URL" && "$HC_URL" =~ '{id}' ]]; then
        err "[HC_URL] with {id} placeholder defined, but no replacement value provided"
    fi


    if [[ "$ERR_NOTIF" == *healthchecksio* ]]; then
        local hcio_rgx='^https?://hc-ping.com/[-a-z0-9]+/?$'
        if [[ -z "$HC_URL" ]]; then
            err "healthchecksio selected for notifications, but HC_URL not defined"
        #elif [[ "$HC_URL" != *//hc-ping.com/* ]]; then
        elif ! [[ "$HC_URL" =~ $hcio_rgx ]]; then
            err "healthchecksio selected for notifications, but configured HC_URL [$HC_URL] does not match expected healthchecks.io url pattern"
        fi
    fi
}


create_dirs() {
    mkdir -p -- "$TMP" || fail "dir [$TMP] creation failed w/ [$?]"
}


# TODO: should start_containers() be called when we errored? or when -h (help) was called?
cleanup() {
    [[ -d "$TMP" ]] && rm -rf -- "$TMP"
    [[ -d "$TMP_ROOT" ]] && is_dir_empty "$TMP_ROOT" && rm -rf -- "$TMP_ROOT"

    # make sure stopped containers are started on exit:
    start_containers

    # TODO: shouldn't we ping healthcheck the very first thing in cleanup()? ie it should fire regardles of the outcome of other calls in here
    ping_healthcheck
    log "==> backup script end"
}


# ================
# Entry
# ================
trap -- 'cleanup; exit' EXIT HUP INT QUIT PIPE TERM
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" | tee -a "$LOG"; exit 1; }
REMOTE_OR_LOCAL_OPT_COUNTER=0
BORG_OTPS_COUNTER=0

while getopts "d:p:c:rlP:B:Z:L:e:A:D:R:T:hH:" opt; do
    case "$opt" in
        d) declare -ar MYSQL_DB=($OPTARG)
            ;;
        p) ARCHIVE_PREFIX="$OPTARG"
           JOB_ID="${OPTARG}-$$"
            ;;
        c) declare -ar CONTAINERS=($OPTARG)
            ;;
        r) REMOTE_ONLY=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        l) LOCAL_ONLY=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        P) BORG_PRUNE_OPTS="$OPTARG"  # overrides env var of same name
            ;;
        B) BORG_EXTRA_OPTS+=" $OPTARG"  # _extends_ env var of same name
           let BORG_OTPS_COUNTER+=1
            ;;
        Z) BORG_EXTRA_OPTS="$OPTARG"  # overrides env var of same name
           let BORG_OTPS_COUNTER+=1
            ;;
        L) LOCAL_REPO="$OPTARG"  # overrides env var of same name
            ;;
        e) ERR_NOTIF="$OPTARG"  # overrides env var of same name
            ;;
        A) SMTP_ACCOUNT="$OPTARG"
            ;;
        D) MYSQL_FAIL_FATAL="$OPTARG"
            ;;
        R) REMOTE="$OPTARG"  # overrides env var of same name
            ;;
        T) REMOTE_REPO="$OPTARG"  # overrides env var of same name
            ;;
        H) HC_ID="$OPTARG"
            ;;
        h) echo -e "$usage"
           exit 0
            ;;
        *) fail "$SELF called with unsupported flag(s)"
            ;;
    esac
done
shift "$((OPTIND-1))"

NODES_TO_BACK_UP=("$@")

readonly TMP_ROOT="/tmp/${SELF}.tmp"
readonly TMP="$TMP_ROOT/${ARCHIVE_PREFIX}-$RANDOM"

readonly PREFIX_WITH_HOSTNAME="${ARCHIVE_PREFIX}-${HOST_NAME}-"  # used for pruning
readonly ARCHIVE_NAME="$PREFIX_WITH_HOSTNAME"'{now:%Y-%m-%d-%H%M%S}'

validate_config
[[ -n "$REMOTE" ]] && add_remote_to_known_hosts_if_missing "$REMOTE"
readonly REMOTE+=":$REMOTE_REPO"  # define after validation
create_dirs

stop_containers
do_backup

exit 0

