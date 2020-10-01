#!/usr/bin/env bash
#
# restores selected borg archive from either local or remote repo to $BACKUP_ROOT

readonly SELF="${0##*/}"
readonly LOG="/var/log/${SELF}.log"
JOB_ID="restore-$$"

readonly usage="
    usage: $SELF [-h] [-d] [-c CONTAINERS] [-r] [-l]
                   [-N BORG_LOCAL_REPO_NAME] -a ARCHIVE_NAME

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
      -N BORG_LOCAL_REPO_NAME overrides container env variable BORG_LOCAL_REPO_NAME; optional;
      -a ARCHIVE_NAME         name of the borg archive to restore/extract data from
"

# checks whether chosen borg repo really is a valid repo
# TODO: deprecate, as we did in backup?
verify_borg() {

    if [[ "$LOCAL_REPO" -eq 1 ]]; then
        borg list "$BORG_LOCAL_REPO" > /dev/null || fail "[borg list $BORG_LOCAL_REPO] failed w/ [$?]; is it a borg repo?"
    elif [[ "$REMOTE_REPO" -eq 1 ]]; then
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


do_restore() {

    log "=> Restore started"
    pushd -- "$RESTORE_DIR" &> /dev/null || fail "unable to pushd into [$RESTORE_DIR]"

    if [[ "$LOCAL_REPO" -eq 1 ]]; then
        borg extract -v --list --show-rc \
            $BORG_EXTRA_OPTS \
            $BORG_LOCAL_EXTRA_OPTS \
            "${BORG_LOCAL_REPO}::${ARCHIVE_NAME}" || fail "extracting local [$BORG_LOCAL_REPO::$ARCHIVE_NAME] failed w/ [$?]"
    elif [[ "$REMOTE_REPO" -eq 1 ]]; then
        borg extract -v --list --show-rc \
            $BORG_EXTRA_OPTS \
            $BORG_REMOTE_EXTRA_OPTS \
            "${REMOTE}::${ARCHIVE_NAME}" || fail "extracting [$REMOTE::$ARCHIVE_NAME] failed w/ [$?]"
    fi

    popd &> /dev/null
    KEEP_DIR=1  # from this point onward, we should not delete $RESTORE_DIR on failure
    restore_db
    log "=> Restore finished OK, contents are in [$RESTORE_DIR]"
}


validate_config() {
    local i val vars

    declare -a vars=(
        ARCHIVE_NAME
    )
    [[ "$RESTORE_DB" -eq 1 ]] && vars+=(
            MYSQL_HOST
            MYSQL_PORT
            MYSQL_USER
            MYSQL_PASS
        )
    [[ "$REMOTE_REPO" -eq 1 ]] && vars+=(REMOTE)

    for i in "${vars[@]}"; do
        val="$(eval echo "\$$i")" || fail "evaling [echo \"\$$i\"] failed w/ [$?]"
        [[ -z "$val" ]] && fail "[$i] is not defined"
    done

    [[ "$REMOTE_OR_LOCAL_OPT_COUNTER" -ne 1 ]] && fail "need to select whether to restore from local or remote repo"
    [[ -d "$BACKUP_ROOT" ]] || fail "[$BACKUP_ROOT] is not mounted"
    [[ "$BORG_LOCAL_REPO_NAME" == /* ]] && fail "BORG_LOCAL_REPO_NAME should not start with a slash"
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

while getopts "dc:rlN:a:h" opt; do
    case "$opt" in
        d) RESTORE_DB=1
            ;;
        c) declare -ar CONTAINERS=($OPTARG)
            ;;
        r) REMOTE_REPO=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        l) LOCAL_REPO=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        N) BORG_LOCAL_REPO_NAME="$OPTARG"  # overrides env var of same name
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

readonly RESTORE_DIR="$BACKUP_ROOT/restored-${ARCHIVE_NAME}"  # dir where selected borg archive will be restored into
readonly BORG_LOCAL_REPO="$BACKUP_ROOT/${BORG_LOCAL_REPO_NAME:-$DEFAULT_LOCAL_REPO_NAME}"

[[ -e "$RESTORE_DIR" ]] && fail "[$RESTORE_DIR] already exists, abort"

validate_config
create_dirs
verify_borg

start_or_stop_containers stop
do_restore
# do not start containers, so we'd have time to manualy move the data files back, if any

exit 0

