#!/usr/bin/env bash
#
# restores selected borg archive from either local or remote repo to $RESTORE_DIR

readonly SELF="${0##*/}"
readonly LOG="/var/log/${SELF}.log"
JOB_ID="restore-$$"

readonly usage="
    usage: $SELF [-h] [-d] [-c CONTAINERS] [-r] [-l]
                   [-N BORG_LOCAL_REPO] -a ARCHIVE_NAME

    Restore data from borg archive

    arguments:
      -h                      show help and exit
      -d                      automatically restore mysql database from dumped file; if this
                              option is given and archive contains no sql dumps, it's an error;
                              be careful, this is destructive operation!
      -c CONTAINERS           space separated container names to stop before the restore begins;
                              note they won't be started afterwards, as there might be need
                              to restore other data (only sql dumps are restored automatically);
                              requires mounting the docker socket (-v /var/run/docker.sock:/var/run/docker.sock)
      -r                      restore from remote borg repo
      -l                      restore from local borg repo
      -N BORG_LOCAL_REPO      overrides container env variable of same name; optional;
      -a ARCHIVE_NAME         name of the borg archive to restore/extract data from
"

# checks whether chosen borg repo really is a valid repo
# TODO: deprecate, as we did in backup?
verify_borg() {

    if [[ "$LOC" -eq 1 ]]; then
        borg list "$BORG_LOCAL_REPO" > /dev/null || fail "[borg list $BORG_LOCAL_REPO] failed w/ [$?]; is it a borg repo?"
    elif [[ "$REM" -eq 1 ]]; then
        borg list "$REMOTE" > /dev/null || fail "[borg list $REMOTE] failed w/ [$?]; please create remote repos manually beforehand"
    fi
}


restore_db() {
    local sql_files i

    declare -a sql_files

    [[ "$RESTORE_DB" -eq 1 ]] || return 0

    while IFS= read -r -d $'\0' i; do
        sql_files+=("$i")
    done < <(find "$RESTORE_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.sql' -print0)
    [[ "${#sql_files[@]}" -ne 1 ]] && fail "expected to find exactly 1 .sql file in the root of [$RESTORE_DIR], but found ${#sql_files[@]}"
    confirm "restore db from mysql dump [${sql_files[*]}]?" || { log "won't try to restore db"; return 0; }

    mysql \
            --host="${MYSQL_HOST}" \
            --port="${MYSQL_PORT}" \
            --user="${MYSQL_USER}" \
            --password="${MYSQL_PASS}" < "${sql_files[@]}" || fail "restoring db from [${sql_files[*]}] failed w/ [$?]"
}


_restore_common() {
    local l_or_r repo extra_opts start_timestamp

    l_or_r="$1"
    repo="$2"
    extra_opts="$3"

    pushd -- "$RESTORE_DIR" &> /dev/null || fail "unable to pushd into [$RESTORE_DIR]"

    log "=> Restore from $l_or_r repo [${repo}::${ARCHIVE_NAME}] started..."
    start_timestamp="$(date +%s)"

    borg extract -v --list --show-rc \
        $BORG_EXTRA_OPTS \
        $extra_opts \
        "${repo}::${ARCHIVE_NAME}" > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || fail "=> extracting $l_or_r repo failed w/ [$?] (duration $(( $(date +%s) - start_timestamp )) seconds)"

    log "=> Extract from $l_or_r repo succeeded in $(( $(date +%s) - start_timestamp )) seconds"

    popd &> /dev/null
    KEEP_DIR=1  # from this point onward, we should not delete $RESTORE_DIR on failure
    restore_db
    log "=> Restore finished OK in $(( $(date +%s) - start_timestamp )) seconds, contents are in [$RESTORE_DIR]"
}


# TODO: do not fail() if err code <=1?
do_restore() {

    if [[ "$LOC" -eq 1 ]]; then
        _restore_common local "$BORG_LOCAL_REPO" "$BORG_LOCAL_EXTRA_OPTS"
    elif [[ "$REM" -eq 1 ]]; then
        _restore_common remote "$REMOTE" "$BORG_REMOTE_EXTRA_OPTS"
    fi
}


validate_config() {
    local vars

    declare -a vars=(
        ARCHIVE_NAME
        RESTORE_DIR
    )
    [[ "$RESTORE_DB" -eq 1 ]] && vars+=(
            MYSQL_HOST
            MYSQL_PORT
            MYSQL_USER
            MYSQL_PASS
        )
    [[ "$REM" -eq 1 ]] && vars+=(REMOTE REMOTE_REPO)
    [[ "$LOC" -eq 1 ]] && vars+=(BORG_LOCAL_REPO)

    vars_defined "${vars[@]}"

    [[ "$REMOTE_OR_LOCAL_OPT_COUNTER" -ne 1 ]] && fail "need to select whether to restore from local or remote repo"
    [[ -d "$RESTORE_DIR" && -w "$RESTORE_DIR"  ]] || fail "[$RESTORE_DIR] is not mounted or not writable; missing mount?"
    [[ "$LOC" -eq 1 ]] && [[ ! -d "$BORG_LOCAL_REPO" || ! -w "$BORG_LOCAL_REPO" ]] && fail "[$BORG_LOCAL_REPO] does not exist or is not writable; missing mount?"
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

while getopts "dc:rlN:R:T:D:a:h" opt; do
    case "$opt" in
        d) RESTORE_DB=1
            ;;
        c) declare -ar CONTAINERS=($OPTARG)
            ;;
        r) REM=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        l) LOC=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        N) BORG_LOCAL_REPO="$OPTARG"  # overrides env var of same name
            ;;
        R) REMOTE="$OPTARG"  # overrides env var of same name
            ;;
        T) REMOTE_REPO="$OPTARG"  # overrides env var of same name
            ;;
        D) RESTORE_DIR="$OPTARG"  # dir where selected borg archive will be restored into
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
[[ -n "$REMOTE" ]] && add_remote_to_known_hosts_if_missing
readonly REMOTE+=":$REMOTE_REPO"  # define after validation
readonly RESTORE_DIR="$RESTORE_DIR/restored-${ARCHIVE_NAME}"  # define & test after validation
[[ -e "$RESTORE_DIR" ]] && fail "[$RESTORE_DIR] already exists, abort"
create_dirs
verify_borg

start_or_stop_containers stop
do_restore
# do not start containers, so we'd have time to manualy move the data files back, if any

exit 0

