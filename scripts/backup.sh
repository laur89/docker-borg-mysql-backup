#!/usr/bin/env bash
#
# backs up mysql/postgres dump and/or other data to local and/or remote borg repository

readonly SELF="${0##*/}"

readonly usage="
    usage: $SELF [-h] [-d MYSQL_DBS] [-g POSTGRES_DBS] [-c CONTAINERS] [-rl]
                  [-P PRUNE_OPTS] [-B|-Z CREATE_OPTS] [-E EXCLUDE_PATHS]
                  [-L LOCAL_REPO] [-e ERR_NOTIF] [-A SMTP_ACCOUNT] [-D MYSQL_FAIL_FATAL]
                  [-G POSTGRES_FAIL_FATAL] [-S SCRIPT_FAIL_FATAL] [-R REMOTE]
                  [-T REMOTE_REPO] [-C] [-H HC_ID] -p PREFIX  [NODES_TO_BACK_UP...]

    Create new archive

    arguments:
      -h                      show help and exit
      -d MYSQL_DBS            comma-separated mysql database names to back up; use value of
                              __all__ to back up all dbs on the server
      -g POSTGRES_DBS         comma-separated postgresql database names to back up; use value of
                              __all__ to back up all dbs on the server
      -c CONTAINERS           comma-separated container names to stop for the backup process;
                              requires mounting the docker socket (-v /var/run/docker.sock:/var/run/docker.sock);
                              note containers will be stopped in given order; after backup
                              completion, containers are started in reverse order; only containers
                              that were stopped by the script will be re-started afterwards
      -r                      only back to remote borg repo (remote-only)
      -l                      only back to local borg repo (local-only)
      -P PRUNE_OPTS           overrides container env var of same name; only required when
                              container var is not defined or needs to be overridden;
      -1 LOCAL_PRUNE_OPTS     prune options for local borg repo; overrides PRUNE_OPTS (& -P);
      -2 REMOTE_PRUNE_OPTS    prune options for remote borg repo; overrides PRUNE_OPTS (& -P);
      -B CREATE_OPTS          additional borg params; note it doesn't overwrite the
                              env var of same name, but extends it;
      -Z CREATE_OPTS          additional borg params; note it _overrides_ the env
                              var of same name;
      -E EXCLUDE_PATHS        comma-separated paths to exclude from backup;
                              [-E '/p1,/p2'] would be equivalent to [-B '-e /p1 -e /p2']
      -L LOCAL_REPO           overrides container env var of same name;
      -e ERR_NOTIF            overrides container env var of same name;
      -A SMTP_ACCOUNT         overrides container env var of same name;
      -D MYSQL_FAIL_FATAL     overrides container env var of same name;
      -G POSTGRES_FAIL_FATAL  overrides container env var of same name;
      -S SCRIPT_FAIL_FATAL    overrides container env var of same name;
      -R REMOTE               overrides container env var of same name;
      -T REMOTE_REPO          overrides container env var of same name;
      -C                      run compact command against repo after backup/prune;
      -H HC_ID                the unique/id part of healthcheck url, replacing the '{id}'
                              placeholder in HC_URL; may also provide new full url to call
                              instead, overriding the env var HC_URL
      -p PREFIX               borg archive name prefix. note that the full archive name already
                              contains HOST_ID env var and timestamp, so omit those.
      NODES_TO_BACK_UP...     last arguments to $SELF are files&directories to be
                              included in the backup
"

# expands the $NODES_TO_BACK_UP with files in $TMP/, if there are any
expand_nodes_to_back_up() {
    local i

    is_dir_empty "$TMP" && return 0

    while IFS= read -r -d $'\0' i; do
        i="$(basename -- "$i")"  # note relative path; we don't want borg archive to contain "$TMP_ROOT" path
        contains "$i" "${NODES_TO_BACK_UP[@]}" && continue
        NODES_TO_BACK_UP+=("$i")
    done < <(find "$TMP" -mindepth 1 -maxdepth 1 -print0)
}


# dumps selected mariadb/mysql db(s) to $TMP
dump_mysql() {
    local output_filename dbs dbs_log err_code start_timestamp err_ t

    [[ "${#MYSQL_DB[@]}" -eq 0 ]] && return 0  # no db specified, meaning db dump not required

    if [[ "${MYSQL_DB[*]}" == "$ALL_DBS_MARKER" ]]; then
        dbs_log='all databases'
        output_filename='all-dbs'
        dbs=('--all-databases')
    else
        dbs_log="databases [${MYSQL_DB[*]}]"
        output_filename="$(tr '[:blank:]' '+' <<< "${MYSQL_DB[*]}")"  # let the filename reflect which dbs it contains
        dbs=('--databases' "${MYSQL_DB[@]}")
    fi

    log "=> starting mysql db dump for ${dbs_log}..."
    start_timestamp="$(date +%s)"

    # TODO: add following column-stats option back once mysqldump from alpine accepts it:
            #--column-statistics=0 \
    # TODO: add --routines ?
    # TODO: add --add-locks ?
    mysqldump \
            --add-drop-database \
            --max-allowed-packet=512M \
            --host="${MYSQL_HOST}" \
            --port="${MYSQL_PORT}" \
            --user="${MYSQL_USER}" \
            --password="${MYSQL_PASS}" \
            ${MYSQL_EXTRA_OPTS} \
            "${dbs[@]}" > "$TMP/mysql:${output_filename}.sql" 2> >(tee -a "$LOG" >&2)

    err_code="$?"
    if [[ "$err_code" -ne 0 ]]; then
        local msg
        msg="mysql db dump step for input args [${MYSQL_DB[*]}] failed w/ [$err_code]"
        [[ "${MYSQL_FAIL_FATAL:-true}" == true ]] && fail "${msg}; aborting" || err "${msg}; not aborting"
        err_=failed
    fi

    t="$(( $(date +%s) - start_timestamp ))"
    log "=> mysql db dump ${err_:-succeeded} in $(print_time "$t")"
}


# dumps selected postgres db(s) to $TMP
# https://www.postgresql.org/docs/15/backup-dump.html
dump_postgres() {
    local err_code start_timestamp err_ t d

    [[ "${#POSTGRES_DB[@]}" -eq 0 ]] && return 0  # no db specified, meaning db dump not required

    start_timestamp="$(date +%s)"
    export PGPASSWORD="$POSTGRES_PASS"

    if [[ "${POSTGRES_DB[*]}" == "$ALL_DBS_MARKER" ]]; then
        log "=> starting postgres db dump for all databases..."

        pg_dumpall \
            --clean \
            --if-exists \
            --quote-all-identifiers \
            -h "$POSTGRES_HOST" \
            -p "$POSTGRES_PORT" \
            -U "$POSTGRES_USER" \
            ${POSTGRES_EXTRA_OPTS} > "$TMP/postgres:all-dbs.sql" 2> >(tee -a "$LOG" >&2) # !! restore.sh references filename

        err_code="$?"
    else
        log "=> starting postgres db dump for databases [${POSTGRES_DB[*]}]..."
        err_code=0

        for d in "${POSTGRES_DB[@]}"; do
            pg_dump \
                --clean \
                --if-exists \
                --quote-all-identifiers \
                --create \
                -h "$POSTGRES_HOST" \
                -p "$POSTGRES_PORT" \
                -U "$POSTGRES_USER" \
                ${POSTGRES_EXTRA_OPTS} \
                -d "$d" > "$TMP/postgres:${d}.sql" 2> >(tee -a "$LOG" >&2) || { err_code=$?; err "pg_dump for db [$d] failed w/ $err_code"; }
        done
    fi

    if [[ "$err_code" -ne 0 ]]; then
        local msg
        msg="postgres db dump step for input args [${POSTGRES_DB[*]}] failed w/ [$err_code]"
        [[ "${POSTGRES_FAIL_FATAL:-true}" == true ]] && fail "${msg}; aborting" || err "${msg}; not aborting"
        err_=failed
    fi

    t="$(( $(date +%s) - start_timestamp ))"
    log "=> postgres db dump ${err_:-succeeded} in $(print_time "$t")"
}


# TODO: should we err() or fail() from here, as they are backgrounded anyway?
_backup_common() {
    local l_or_r repo extra_opts start_timestamp err_code opts t

    l_or_r="$1"
    repo="$2"
    extra_opts="$3"

    opts="$(join -s ' ' -- "$COMMON_OPTS" "$CREATE_OPTS" "$extra_opts")"

    log "=> starting $l_or_r backup to [$repo]..."
    log "=> effective $l_or_r create opts = [$opts]"
    start_timestamp="$(date +%s)"

    borg create --stats --show-rc \
        $opts \
        "${repo}::${ARCHIVE_NAME}" \
        "${NODES_TO_BACK_UP[@]}" > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || { err "$l_or_r borg create exited w/ [$?]"; err_code=1; }

    t="$(( $(date +%s) - start_timestamp ))"
    log "=> $l_or_r backup ${err_code:-succeeded} in $(print_time "$t")"

    return "${err_code:-0}"
}


# TODO: should we err() or fail() from here, as they are backgrounded anyway?
_prune_common() {
    local l_or_r repo prune_opts start_timestamp err_code opts t

    l_or_r="$1"
    repo="$2"
    prune_opts="$3"  # local/remote specific prune opts, optional

    opts="$(join -s ' ' -- "$COMMON_OPTS" "${prune_opts:-$PRUNE_OPTS}")"

    log "=> starting $l_or_r prune from [$repo]..."
    log "=> effective $l_or_r prune opts = [$opts]"
    start_timestamp="$(date +%s)"

    borg prune --show-rc \
        $opts \
        --glob-archives "${PREFIX_WITH_HOSTNAME}*" \
        "$repo" > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || { err "$l_or_r borg prune exited w/ [$?]"; err_code=1; }

    t="$(( $(date +%s) - start_timestamp ))"
    log "=> $l_or_r prune ${err_code:-succeeded} in $(print_time "$t")"

    return "${err_code:-0}"
}


backup_local() {
    _backup_common local "${LOCAL_REPO}" "$LOCAL_CREATE_OPTS"
}


backup_remote() {
    _backup_common remote "${REMOTE}" "$REMOTE_CREATE_OPTS"
}


prune_local() {
    _prune_common local "${LOCAL_REPO}" "$LOCAL_PRUNE_OPTS"
}


prune_remote() {
    _prune_common remote "${REMOTE}" "$REMOTE_PRUNE_OPTS"
}


# backup selected data
# note the borg processes are executed in a sub-shell, so local & remote backup could be
# run in parallel
#
# TODO: should we skip prune if create exits w/ code >=2?
do_backup() {
    local started_pids start_timestamp i err_ t

    declare -a started_pids=()

    log "=> Backup started"
    log "=> ARCHIVE_NAME = [$ARCHIVE_NAME]"

    start_timestamp="$(date +%s)"

    run_scripts  before-mysql-dump
    dump_mysql
    run_scripts  after-mysql-dump

    run_scripts  before-postgres-dump
    dump_postgres
    run_scripts  after-postgres-dump

    expand_nodes_to_back_up  # adds dump sql (and any possible custom script additions) to NODES_TO_BACK_UP

    run_scripts  before-backup

    expand_nodes_to_back_up  # once again, in case any of the custom scripts added files
    [[ "${#NODES_TO_BACK_UP[@]}" -eq 0 ]] && fail "no items selected for backup"

    pushd -- "$TMP" &> /dev/null || fail "unable to pushd into [$TMP]"  # cd there because files in $TMP are added without full path (to avoid "$TMP_ROOT" prefix in borg repo)

    # note! log files/types out _after_ pushd to $TMP, otherwise some files would not resolve
    log "following ${#NODES_TO_BACK_UP[@]} file(s) will be backed up:"
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

    run_scripts  after-backup

    # backup is done, we can go ahead and start the containers while pruning:
    # TODO: should start_containers() be called when we errored?
    start_containers "${CONTAINERS_TO_START[@]}" &
    CONTAINERS_TO_START=()  # empty so no secondary start attempts would be made after

    started_pids=()  # reset

    run_scripts  before-prune

    if [[ "$REMOTE_ONLY" -ne 1 ]]; then
        prune_local &
        started_pids+=("$!")
    fi

    if [[ "$LOCAL_ONLY" -ne 1 ]]; then
        prune_remote &
        started_pids+=("$!")
    fi

    for i in "${started_pids[@]}"; do
        wait "$i" || err_=TRUE
    done

    run_scripts  after-prune

    if [[ -n "$COMPACT" ]]; then
        run_scripts  before-compact
        compact_repos || err_=TRUE
        run_scripts  after-compact
    fi

    t="$(( $(date +%s) - start_timestamp ))"
    log "=> Backup+prune${COMPACT:++compact} finished, duration $(print_time "$t")${err_:+; at least one step failed or produced warning}"

    return 0
}


validate_config() {
    local i vars

    validate_config_common

    declare -a vars=(
        ARCHIVE_PREFIX
        BORG_PASSPHRASE
        HOST_ID
    )
    [[ -n "${MYSQL_DB[*]}" ]] && vars+=(
        MYSQL_HOST
        MYSQL_PORT
        MYSQL_USER
        MYSQL_PASS
    )
    [[ -n "${POSTGRES_DB[*]}" ]] && vars+=(
        POSTGRES_HOST
        POSTGRES_PORT
        POSTGRES_USER
        POSTGRES_PASS
    )
    [[ "$LOCAL_ONLY" -ne 1 ]] && vars+=(REMOTE REMOTE_REPO)
    [[ "$REMOTE_ONLY" -ne 1 ]] && vars+=(LOCAL_REPO)

    # validate prune options:
    if [[ "$REMOTE_ONLY" -ne 1 && "$LOCAL_ONLY" -ne 1 ]]; then
        if [[ -z "$REMOTE_PRUNE_OPTS" && -z "$LOCAL_PRUNE_OPTS" ]]; then
            vars+=(PRUNE_OPTS)
        elif [[ -z "$REMOTE_PRUNE_OPTS" || -z "$LOCAL_PRUNE_OPTS" ]] && [[ -z "$PRUNE_OPTS" ]]; then
            fail "prune options for remote and/or local repo(s) undefined"
        fi
    elif [[ "$REMOTE_ONLY" -eq 1 && -z "$REMOTE_PRUNE_OPTS" ]] || [[ "$LOCAL_ONLY" -eq 1 && -z "$LOCAL_PRUNE_OPTS" ]]; then
        vars+=(PRUNE_OPTS)
    fi

    vars_defined "${vars[@]}"

    if [[ "${#NODES_TO_BACK_UP[@]}" -gt 0 ]]; then
        for i in "${NODES_TO_BACK_UP[@]}"; do
            [[ -e "$i" ]] || err "node [$i] to back up does not exist; missing mount?"
        done
    elif [[ "${#MYSQL_DB[@]}" -eq 0 || -z "${MYSQL_DB[*]}" ]] && [[ "${#POSTGRES_DB[@]}" -eq 0 || -z "${POSTGRES_DB[*]}" ]]; then
        fail "no databases nor nodes selected for backup - nothing to do!"
    fi

    [[ "$REMOTE_OR_LOCAL_OPT_COUNTER" -gt 1 ]] && fail "-r & -l options are exclusive"
    [[ "$BORG_OTPS_COUNTER" -gt 1 ]] && fail "-B & -Z options are exclusive"
    [[ "$REMOTE_ONLY" -ne 1 ]] && [[ ! -d "$LOCAL_REPO" || ! -w "$LOCAL_REPO" ]] && fail "[$LOCAL_REPO] does not exist or is not writable; missing mount?"

    if [[ "$LOCAL_ONLY" -ne 1 && "$-" != *i* ]]; then
        [[ -f "$SSH_KEY" && -s "$SSH_KEY" ]] || fail "[$SSH_KEY] is not a file; is /config mounted?"
    fi
}


create_dirs() {
    mkdir -p -- "$TMP" || fail "dir [$TMP] creation failed w/ [$?]"
}


cleanup() {
    [[ -d "$TMP" ]] && rm -rf -- "$TMP"
    [[ -d "$TMP_ROOT" ]] && is_dir_empty "$TMP_ROOT" && rm -rf -- "$TMP_ROOT"

    start_containers "${CONTAINERS_TO_START[@]}"  # do not background here

    # TODO: shouldn't we ping healthcheck the very first thing in cleanup()? ie it should fire regardles of the outcome of other calls in here
    ping_healthcheck
    log "==> backup script end"
}


# ================
# Entry
# ================
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" >&2; exit 1; }
REMOTE_OR_LOCAL_OPT_COUNTER=0
BORG_OTPS_COUNTER=0
BORG_EXCLUDE_PATHS=()

unset MYSQL_DB POSTGRES_DB ARCHIVE_PREFIX CONTAINERS COMPACT HC_ID  # just in case

while getopts 'd:g:p:c:rlP:1:2:B:Z:E:L:e:A:D:G:S:R:T:H:Ch' opt; do
    case "$opt" in
        d) IFS="$SEPARATOR" read -ra MYSQL_DB <<< "$OPTARG"
            ;;
        g) IFS="$SEPARATOR" read -ra POSTGRES_DB <<< "$OPTARG"
            ;;
        p) readonly ARCHIVE_PREFIX="$OPTARG"  # be careful w/ var rename! eg run_scripts() depends on many var names
           readonly JOB_ID="${OPTARG}-$$"
            ;;
        c) IFS="$SEPARATOR" read -ra CONTAINERS <<< "$OPTARG"
            ;;
        r) REMOTE_ONLY=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        l) LOCAL_ONLY=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        P) PRUNE_OPTS="$OPTARG"  # overrides env var of same name
            ;;
        1) LOCAL_PRUNE_OPTS="$OPTARG"  # overrides env var of same name
            ;;
        2) REMOTE_PRUNE_OPTS="$OPTARG"  # overrides env var of same name
            ;;
        B) CREATE_OPTS+=" $OPTARG"  # _extends_ env var of same name
           let BORG_OTPS_COUNTER+=1
            ;;
        Z) CREATE_OPTS="$OPTARG"  # overrides env var of same name
           let BORG_OTPS_COUNTER+=1
            ;;
        E) IFS="$SEPARATOR" read -ra BORG_EXCLUDE_PATHS <<< "$OPTARG"
            ;;
        L) LOCAL_REPO="$OPTARG"  # overrides env var of same name
            ;;
        e) ERR_NOTIF="$OPTARG"  # overrides env var of same name
            ;;
        A) SMTP_ACCOUNT="$OPTARG"
            ;;
        D) MYSQL_FAIL_FATAL="$OPTARG"
            ;;
        G) POSTGRES_FAIL_FATAL="$OPTARG"
            ;;
        S) SCRIPT_FAIL_FATAL="$OPTARG"
            ;;
        R) REMOTE="$OPTARG"  # overrides env var of same name
            ;;
        T) REMOTE_REPO="$OPTARG"  # overrides env var of same name
            ;;
        C) COMPACT=TRUE
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

trap -- 'cleanup; exit' EXIT HUP INT QUIT PIPE TERM

NODES_TO_BACK_UP=("$@")
JOB_SCRIPT_ROOT="$SCRIPT_ROOT/jobs/$ARCHIVE_PREFIX"

readonly TMP_ROOT="/tmp/${SELF}.tmp"
readonly TMP="$TMP_ROOT/${ARCHIVE_PREFIX}-$RANDOM"

[[ -f "$ENV_ROOT/${ARCHIVE_PREFIX}.conf" ]] && source "$ENV_ROOT/${ARCHIVE_PREFIX}.conf"  # load job-specific config if avail

# process these _after_ sourcing job-specific config:
if [[ "${#BORG_EXCLUDE_PATHS[@]}" -gt 0 ]]; then
    for i in "${BORG_EXCLUDE_PATHS[@]}"; do
        BORG_EXCLUDE_OPTS+=" --exclude $i"
    done
    unset BORG_EXCLUDE_PATHS i
fi

[[ -n "$BORG_EXCLUDE_OPTS" ]] && CREATE_OPTS+=" $BORG_EXCLUDE_OPTS"
unset BORG_EXCLUDE_OPTS

readonly PREFIX_WITH_HOSTNAME="${ARCHIVE_PREFIX}-${HOST_ID}-"  # used for pruning
readonly ARCHIVE_NAME="$PREFIX_WITH_HOSTNAME"'{now:%Y-%m-%d-%H%M%S}'

validate_config
process_remote  # note this overwrites global REMOTE var
create_dirs

run_scripts  before

stop_containers
do_backup

run_scripts  after

exit 0

