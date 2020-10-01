#!/usr/bin/env bash
#
# backs up mysql dump and/or other data to local and/or remote borg repository

readonly SELF="${0##*/}"
readonly LOG="/var/log/${SELF}.log"

readonly usage="
    usage: $SELF [-h] [-d MYSQL_DBS] [-n NODES_TO_BACKUP] [-c CONTAINERS] [-rl]
                  [-P BORG_PRUNE_OPTS] [-B|-Z BORG_EXTRA_OPTS] [-N BORG_LOCAL_REPO_NAME]
                  [-e ERR_NOTIF] [-A SMTP_ACCOUNT] [-D MYSQL_FAIL_FATAL] -p PREFIX

    Create new archive

    arguments:
      -h                      show help and exit
      -d MYSQL_DBS            space separated database names to back up; use __all__ to back up
                              all dbs on the server
      -n NODES_TO_BACKUP      space separated files/directories to back up (in addition to db dumps);
                              path may not contain spaces, as space is the separator
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
      -N BORG_LOCAL_REPO_NAME overrides container env variable BORG_LOCAL_REPO_NAME;
      -e ERR_NOTIF            space separated error notification methods; overrides
                              env var of same name;
      -A SMTP_ACCOUNT         msmtp account to use; defaults to 'default'; overrides
                              env var of same name;
      -D MYSQL_FAIL_FATAL     whether unsuccessful db dump should abort backup; overrides
                              env var of same name; true|false
      -p PREFIX               borg archive name prefix. note that the full archive name already
                              contains HOST_NAME and timestamp, so omit those.
"

# expands the $NODES_TO_BACK_UP with files in $TMP/, if there are any
expand_nodes_to_back_up() {
    local i

    is_dir_empty "$TMP" && return 0

    for i in "$TMP/"*; do
        NODES_TO_BACK_UP+=("$(basename -- "$i")")  # note relative path; we don't want borg archive to contain "$TMP_ROOT" path
    done
}


# dumps selected db(s) to $TMP
dump_db() {
    local output_filename mysql_db_orig err_code start_timestamp err_

    MYSQL_DB="$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$MYSQL_DB")"  # strip leading&trailing whitespace

    [[ -z "$MYSQL_DB" ]] && return 0  # no db specified, meaning db dump not required

    MYSQL_DB="$(tr -s ' ' <<< "$MYSQL_DB")"  # squash multiple spaces
    readonly mysql_db_orig="$MYSQL_DB"

    # alternatively this, to squash multiple spaces & replace w/ '+' in one go:   MYSQL_DB="${MYSQL_DB//+( )/+}"
    if [[ "$MYSQL_DB" == __all__ ]]; then
        output_filename='all-dbs'
        MYSQL_DB='--all-databases'
    else
        output_filename="${MYSQL_DB// /+}"  # let the filename reflect which dbs it contains
        MYSQL_DB="--databases $MYSQL_DB"
    fi

    log "=> starting db dump..."
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
            ${MYSQL_DB} > "$TMP/${output_filename}.sql" 2> >(tee -a "$LOG" >&2)

    err_code="$?"
    if [[ "$err_code" -ne 0 ]]; then
        local msg
        msg="db dump for [$mysql_db_orig] failed w/ [$err_code]"
        [[ "${MYSQL_FAIL_FATAL:-true}" == true ]] && fail "$msg" || err "$msg"
        err_=failed
    fi

    log "=> db dump ${err_:-succeeded} in $(( $(date +%s) - start_timestamp )) seconds"
}


# TODO: should we skip prune if create exits w/ code >=2?
_backup_common() {
    local local_or_remote repo extra_opts start_timestamp err_code err_

    local_or_remote="$1"
    repo="$2"
    extra_opts="$3"

    log "=> starting $local_or_remote backup..."
    start_timestamp="$(date +%s)"

    borg create --stats --show-rc \
        $BORG_EXTRA_OPTS \
        $extra_opts \
        "${repo}::${ARCHIVE_NAME}" \
        "${NODES_TO_BACK_UP[@]}" > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || { err "$local_or_remote borg create exited w/ [$?]"; err_code=1; err_=failed; }
    log "=> $local_or_remote backup ${err_:-succeeded} in $(( $(date +%s) - start_timestamp )) seconds"

    unset err_  # reset

    log "=> starting $local_or_remote prune..."
    start_timestamp="$(date +%s)"

    borg prune --show-rc \
        "$repo" \
        --prefix "$PREFIX_WITH_HOSTNAME" \
        $BORG_PRUNE_OPTS > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || { err "$local_or_remote borg prune exited w/ [$?]"; err_code=1; err_=failed; }
    log "=> $local_or_remote prune ${err_:-succeeded} in $(( $(date +%s) - start_timestamp )) seconds"

    return "${err_code:-0}"
}


backup_local() {
    _backup_common local "${BORG_LOCAL_REPO}" "$BORG_LOCAL_EXTRA_OPTS"
}


backup_remote() {
    _backup_common remote "${REMOTE}" "$BORG_REMOTE_EXTRA_OPTS"
}


# backup selected data
# note the borg processes are executed in a sub-shell, so local & remote backup could be
# run in parallel
do_backup() {
    local started_pids start_timestamp pid err_

    declare -a started_pids=()

    log "=> Backup started"
    start_timestamp="$(date +%s)"

    dump_db
    expand_nodes_to_back_up

    [[ "${#NODES_TO_BACK_UP[@]}" -eq 0 ]] && fail "no items selected for backup"
    pushd -- "$TMP" &> /dev/null || fail "unable to pushd into [$TMP]"  # cd there because files in $TMP are added without full path (to avoid "$TMP_ROOT" prefix in borg repo)

    if [[ "$REMOTE_ONLY" -ne 1 ]]; then
        backup_local &
        started_pids+=("$!")
    fi

    if [[ "$LOCAL_ONLY" -ne 1 ]]; then
        backup_remote &
        started_pids+=("$!")
    fi

    for pid in "${started_pids[@]}"; do
        wait "$pid" || err_=TRUE
    done

    popd &> /dev/null
    log "=> Backup finished, duration $(( $(date +%s) - start_timestamp )) seconds${err_:+; at least one step failed or produced warning}"

    return 0
}


init_local_borg_repo() {
    local msg err_code

    if [[ "$REMOTE_ONLY" -ne 1 ]]; then
        if [[ ! -d "$BORG_LOCAL_REPO" ]] || is_dir_empty "$BORG_LOCAL_REPO"; then
            log "=> initialising local repo [$BORG_LOCAL_REPO]..."
            borg init --make-parent-dirs --show-rc "$BORG_LOCAL_REPO" > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2)
            err_code="$?"

            if [[ "$err_code" -ne 0 ]]; then
                msg="=> local borg repo init @ [$BORG_LOCAL_REPO] failed w/ [$?]"
                [[ "$LOCAL_ONLY" -eq 1 ]] && fail "$msg" || { err "$msg"; LOCAL_ONLY=0; REMOTE_ONLY=1; }  # local would fail for sure; force remote_only
            else
                log "=> local repo [$BORG_LOCAL_REPO] initialised successfully"
            fi
        fi
    fi
}


validate_config() {
    local i val vars

    validate_config_common

    declare -a vars=(
        ARCHIVE_PREFIX
        BORG_PASSPHRASE
        BORG_PRUNE_OPTS
        HOST_NAME
    )
    [[ -n "$MYSQL_DB" ]] && vars+=(
        MYSQL_HOST
        MYSQL_PORT
        MYSQL_USER
        MYSQL_PASS
    )
    [[ "$LOCAL_ONLY" -ne 1 ]] && vars+=(REMOTE REMOTE_REPO)

    for i in "${vars[@]}"; do
        val="$(eval echo "\$$i")" || fail "evaling [echo \"\$$i\"] failed w/ [$?]"
        [[ -z "$val" ]] && fail "[$i] is not defined"
    done

    if [[ "${#NODES_TO_BACK_UP[@]}" -gt 0 ]]; then
        for i in "${NODES_TO_BACK_UP[@]}"; do
            [[ -e "$i" ]] || err "node [$i] to back up does not exist; missing mount?"
        done
    fi

    [[ "$REMOTE_OR_LOCAL_OPT_COUNTER" -gt 1 ]] && fail "-r & -l options are exclusive"
    [[ "$BORG_OTPS_COUNTER" -gt 1 ]] && fail "-B & -Z options are exclusive"
    [[ "$REMOTE_ONLY" -ne 1 && ! -d "$BACKUP_ROOT" ]] && fail "[$BACKUP_ROOT] is not mounted"
    [[ "$BORG_LOCAL_REPO_NAME" == /* ]] && fail "BORG_LOCAL_REPO_NAME should not start with a slash"

    if [[ "$LOCAL_ONLY" -ne 1 && "$-" != *i* ]]; then
        [[ -f "$SSH_KEY" ]] || fail "[$SSH_KEY] is not a file; is /config mounted?"
    fi
}


create_dirs() {
    mkdir -p -- "$TMP" || fail "dir [$TMP] creation failed w/ [$?]"
}


cleanup() {
    # make sure stopped containers are started on exit:
    start_or_stop_containers start

    [[ -d "$TMP" ]] && rm -rf -- "$TMP"
    [[ -d "$TMP_ROOT" ]] && is_dir_empty "$TMP_ROOT" && rm -rf -- "$TMP_ROOT"

    log "==> backup script end"
}


# ================
# Entry
# ================
trap -- 'cleanup; exit' EXIT HUP INT QUIT PIPE TERM
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" | tee -a "$LOG"; exit 1; }
REMOTE_OR_LOCAL_OPT_COUNTER=0
BORG_OTPS_COUNTER=0

while getopts "d:n:p:c:rlP:B:Z:N:e:A:D:R:T:h" opt; do
    case "$opt" in
        d) MYSQL_DB="$OPTARG"
            ;;
        n) NODES_TO_BACK_UP+=($OPTARG)
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
        N) BORG_LOCAL_REPO_NAME="$OPTARG"  # overrides env var of same name
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
        h) echo -e "$usage"
           exit 0
            ;;
        *) fail "$SELF called with unsupported flag(s)"
            ;;
    esac
done

readonly TMP_ROOT="/tmp/${SELF}.tmp"
readonly TMP="$TMP_ROOT/${ARCHIVE_PREFIX}-$RANDOM"

readonly PREFIX_WITH_HOSTNAME="${ARCHIVE_PREFIX}-${HOST_NAME}-"  # used for pruning
readonly ARCHIVE_NAME="$PREFIX_WITH_HOSTNAME"'{now:%Y-%m-%d-%H%M%S}'
readonly BORG_LOCAL_REPO="$BACKUP_ROOT/${BORG_LOCAL_REPO_NAME:-$DEFAULT_LOCAL_REPO_NAME}"

validate_config
readonly REMOTE+=":$REMOTE_REPO"  # define after validation
create_dirs
init_local_borg_repo

start_or_stop_containers stop
do_backup

exit 0

