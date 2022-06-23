#!/usr/bin/env bash
#
# restores selected borg archive from either local or remote repo to $RESTORE_DIR

readonly SELF="${0##*/}"
readonly LOG="/var/log/${SELF}.log"
JOB_ID="restore-$$"

readonly usage="
    usage: $SELF [-h] [-d] [-g] [-c CONTAINERS] [-rl] [-B BORG_OPTS] [-L LOCAL_REPO]
                   [-R REMOTE] [-T REMOTE_REPO] -O RESTORE_DIR -a ARCHIVE_NAME

    Restore data from borg archive

    arguments:
      -h                      show help and exit
      -d                      automatically restore mysql database from dumped file; if this
                              option is provided and archive doesn't contain exactly one dump-file,
                              it's an error; be careful, this is a destructive operation!
      -g                      automatically restore postgresql database from dumped file; if this
                              option is provided and archive contains no sql dumps, it's an error;
                              be careful, this is a destructive operation!
      -c CONTAINERS           comma-separated container names to stop before the restore begins;
                              note they won't be started afterwards, as there might be need
                              to restore other data (only sql dumps are restored automatically);
                              requires mounting the docker socket (-v /var/run/docker.sock:/var/run/docker.sock)
      -r                      restore from remote borg repo
      -l                      restore from local borg repo
      -B BORG_OPTS            additional borg params to pass to extract command
      -L LOCAL_REPO           overrides container env var of same name
      -R REMOTE               overrides container env var of same name
      -T REMOTE_REPO          overrides container env var of same name
      -O RESTORE_DIR          path to directory where archive will get extracted to
      -a ARCHIVE_NAME         full name of the borg archive to extract data from
"


# TODO: currently user-included sql files would also be picked up by find!
restore_db() {
    local mysql_files postgre_files i d

    declare -a mysql_files postgre_files

    while IFS= read -r -d $'\0' i; do
        if [[ "$i" == 'mysql:'* ]]; then
            mysql_files+=("$i")
        elif [[ "$i" == 'postgres:'* ]]; then
            postgre_files+=("$i")
        else
            err "unrecognized SQL file [$i], ignoring it..."
        fi
    done < <(find "$RESTORE_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.sql' -print0)
    unset i

    if [[ "$RESTORE_MYSQL_DB" == 1 ]]; then
        [[ "${#mysql_files[@]}" -ne 1 ]] && fail "expected to find exactly 1 mysql .sql file in the root of [$RESTORE_DIR], but found ${#mysql_files[@]}"
        if confirm "restore db from mysql dump [${mysql_files[*]}]?"; then
            mysql \
                    --host="${MYSQL_HOST}" \
                    --port="${MYSQL_PORT}" \
                    --user="${MYSQL_USER}" \
                    --password="${MYSQL_PASS}" < "${mysql_files[@]}" 2> >(tee -a "$LOG" >&2) || fail "restoring db from [${mysql_files[*]}] failed w/ [$?]"
        else
            log "skip restoring mysql db..."
        fi
    fi

    # https://www.postgresql.org/docs/15/backup-dump.html#BACKUP-DUMP-RESTORE
    if [[ "$RESTORE_POSTGRES_DB" == 1 ]]; then
        [[ "${#postgre_files[@]}" -eq 0 ]] && fail "expected to find at least 1 postgres .sql file in the root of [$RESTORE_DIR], but found none"
        if confirm "restore db from postgres dump(s) [${postgre_files[*]}]?"; then
            export PGPASSWORD="$POSTGRES_PASS"

            for i in "${postgre_files[@]}"; do
                d="$(basename -- "$i")"
                [[ "$d" == 'postgres:all-dbs.sql' ]] && d=postgres || d="$(grep -Po '^postgres:\K.*(?=\.sql$)' <<< "$d")"
                # TODO2: restoring from all-dbs.sql, then the cluster should really be empty!
                psql \
                        -h "$POSTGRES_HOST" \
                        -p "$POSTGRES_PORT" \
                        -U "$POSTGRES_USER" \
                        -d "$d" \
                        -f "$i" 2> >(tee -a "$LOG" >&2) || fail "restoring [$d] postgres db from [$i] failed w/ [$?]"
            done
        else
            log "skip restoring postgres db..."
        fi
    fi
}


# TODO: do not fail() if err code <=1?
_restore_common() {
    local l_or_r repo start_timestamp t

    l_or_r="$1"
    repo="$2"

    pushd -- "$RESTORE_DIR" &> /dev/null || fail "unable to pushd into [$RESTORE_DIR]"

    log "=> Restore from $l_or_r repo [${repo}::${ARCHIVE_NAME}] started..."
    start_timestamp="$(date +%s)"

    borg extract -v --list --show-rc \
        $COMMON_OPTS \
        $BORG_OPTS \
        "${repo}::${ARCHIVE_NAME}" > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || fail "=> extracting $l_or_r repo failed w/ [$?] (duration $(print_time "$(( $(date +%s) - start_timestamp ))"))"


    t="$(( $(date +%s) - start_timestamp ))"
    log "=> Extract from $l_or_r repo succeeded in $(print_time "$t")"

    popd &> /dev/null
    KEEP_DIR=1  # from this point onward, we should not delete $RESTORE_DIR on failure
    restore_db

    t="$(( $(date +%s) - start_timestamp ))"
    log "=> Restore finished OK in $(print_time "$t"), contents are in [$RESTORE_DIR]"
}


do_restore() {

    if [[ "$LOC" -eq 1 ]]; then
        _restore_common local "$LOCAL_REPO"
    elif [[ "$REM" -eq 1 ]]; then
        _restore_common remote "$REMOTE"
    fi
}


validate_config() {
    local vars

    declare -a vars=(
        ARCHIVE_NAME
        RESTORE_DIR
    )
    [[ "$RESTORE_MYSQL_DB" == 1 ]] && vars+=(
            MYSQL_HOST
            MYSQL_PORT
            MYSQL_USER
            MYSQL_PASS
        )
    [[ "$RESTORE_POSTGRES_DB" == 1 ]] && vars+=(
            POSTGRES_HOST
            POSTGRES_PORT
            POSTGRES_USER
            POSTGRES_PASS
        )
    [[ "$REM" -eq 1 ]] && vars+=(REMOTE REMOTE_REPO)
    [[ "$LOC" -eq 1 ]] && vars+=(LOCAL_REPO)

    vars_defined "${vars[@]}"

    [[ "$REMOTE_OR_LOCAL_OPT_COUNTER" -ne 1 ]] && fail "need to select whether to restore from local or remote repo"
    [[ -d "$RESTORE_DIR" && -w "$RESTORE_DIR"  ]] || fail "[$RESTORE_DIR] is not mounted or not writable; missing mount?"
    [[ "$LOC" -eq 1 ]] && [[ ! -d "$LOCAL_REPO" || ! -w "$LOCAL_REPO" ]] && fail "[$LOCAL_REPO] does not exist or is not writable; missing mount?"
}


create_dirs() {
    mkdir -p -- "$RESTORE_DIR" || fail "dir [$RESTORE_DIR] creation failed w/ [$?]"
}


cleanup() {
    [[ "$KEEP_DIR" -ne 1 && -d "$RESTORE_DIR" ]] && rm -r -- "$RESTORE_DIR"
    [[ -d "$RESTORE_DIR" ]] && log "\n\n    -> restored files are in [$RESTORE_DIR]"

    log "==> restore script end"
}


# ================
# Entry
# ================
trap -- 'cleanup; exit' EXIT HUP INT QUIT PIPE TERM
NO_NOTIF=true  # do not notify errors
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" | tee -a "$LOG"; exit 1; }
REMOTE_OR_LOCAL_OPT_COUNTER=0

unset RESTORE_MYSQL_DB RESTORE_POSTGRES_DB CONTAINERS REM LOC BORG_OPTS RESTORE_DIR ARCHIVE_NAME  # just in case

while getopts 'dgc:rlB:L:R:T:O:a:h' opt; do
    case "$opt" in
        d) RESTORE_MYSQL_DB=1
            ;;
        g) RESTORE_POSTGRES_DB=1
            ;;
        c) IFS="$SEPARATOR" read -ra CONTAINERS <<< "$OPTARG"
            ;;
        r) REM=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        l) LOC=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        B) BORG_OPTS="$OPTARG"
            ;;
        L) LOCAL_REPO="$OPTARG"  # overrides env var of same name
            ;;
        R) REMOTE="$OPTARG"  # overrides env var of same name
            ;;
        T) REMOTE_REPO="$OPTARG"  # overrides env var of same name
            ;;
        O) RESTORE_DIR="$OPTARG"  # dir where selected borg archive will be restored into
            ;;
        a) ARCHIVE_NAME="$OPTARG"
            ;;
        h) echo -e "$usage"
           exit 0
            ;;
        *) fail "$SELF called with unsupported flag(s)"
            ;;
    esac
done


validate_config
[[ -n "$REMOTE" ]] && add_remote_to_known_hosts_if_missing "$REMOTE"
readonly REMOTE+=":$REMOTE_REPO"  # define after validation, as we're re-defining the arg
readonly RESTORE_DIR="$RESTORE_DIR/restored-${ARCHIVE_NAME}"  # define & test after validation, as we're re-defining the arg
[[ -e "$RESTORE_DIR" ]] && fail "[$RESTORE_DIR] already exists, abort"
create_dirs

stop_containers
do_restore
# do not start containers, so we'd have time to manualy move the data files back, if any

exit 0

