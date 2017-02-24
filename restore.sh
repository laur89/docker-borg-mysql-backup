#!/bin/bash
#
# restores selected borg archive from either local or remote repo to $BACKUP_ROOT


readonly usage="
    usage: ${0##*/} [-h] [-d] [-c CONTAINERS] [-r] [-l]
                   [-N BORG_LOCAL_REPO_NAME] -a ARCHIVE_NAME

    Restore data from borg archive

    arguments:
      -h                      show help and exit
      -d                      restore mysql database from dumped file
      -c CONTAINERS           space separated container names to stop before the restore begins;
                              note they won't be started afterwards, as there might be need
                              to restore other data (only sql dumps are restored automatically);
                              requires mounting the docker socket (-v /var/run/docker.sock:/var/run/docker.sock)
      -r                      restore from remote borg repo
      -l                      restore from local borg repo
      -N BORG_LOCAL_REPO_NAME overrides container env variable BORG_LOCAL_REPO_NAME; optional;
      -a ARCHIVE_NAME         name of the borg archive to restore data from
"

# checks whether chosen borg repo really is a valid repo
verify_borg() {

    if [[ "$LOCAL_REPO" -eq 1 ]]; then
        borg list "$BORG_LOCAL_REPO" > /dev/null || fail "[borg list $BORG_LOCAL_REPO] failed. is it a borg repo?"
    elif [[ "$REMOTE_REPO" -eq 1 ]]; then
        borg list "$REMOTE" > /dev/null || fail "[borg list $REMOTE] failed; please create remote repos manually beforehand"
    fi
}


restore_db() {
    local sql_files i

    declare -a sql_files

    [[ "$RESTORE_DB" -eq 1 ]] || return 0

    while IFS= read -r -d $'\0' i; do
        sql_files+=("$i")
    done < <(find "$RESTORE_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.sql' -print0)
    [[ "${#sql_files[@]}" -ne 1 ]] && fail "expected to find 1 .sql file in the root of [$RESTORE_DIR], but found ${#sql_files[@]}"
    confirm "restore db from mysql dump [${sql_files[*]}]?" || return

    if mysql \
            -h${MYSQL_HOST} \
            -P${MYSQL_PORT} \
            -u${MYSQL_USER} \
            -p${MYSQL_PASS} < "${sql_files[@]}"; then

        echo "   Restore succeeded"
    else
        echo "   Restore failed"
    fi
}


do_restore() {

    pushd -- "$RESTORE_DIR" || fail "unable to pushd into [$RESTORE_DIR]"

    if [[ "$LOCAL_REPO" -eq 1 ]]; then
        borg extract -v --list \
            $BORG_EXTRA_OPTS \
            $BORG_LOCAL_EXTRA_OPTS \
            "$BORG_LOCAL_REPO"::"$ARCHIVE_NAME" || fail "restoring [$BORG_LOCAL_REPO::$ARCHIVE_NAME] failed"
    elif [[ "$REMOTE_REPO" -eq 1 ]]; then
        borg extract -v --list \
            $BORG_EXTRA_OPTS \
            $BORG_REMOTE_EXTRA_OPTS \
            "$REMOTE"::"$ARCHIVE_NAME" || fail "restoring [$REMOTE::$ARCHIVE_NAME] failed"
    fi

    popd &> /dev/null
    KEEP_DIR=1  # from this point onward, we should not delete $RESTORE_DIR on failure
    restore_db
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
        val="$(eval echo "\$$i")" || fail "evaling [echo $i] failed with code [$?]"
        [[ -z "$val" ]] && fail "[$i] is not defined"
    done

    [[ "$REMOTE_OR_LOCAL_OPT_COUNTER" -ne 1 ]] && fail "need to select whether to restore from local or remote repo"
    [[ -d "$BACKUP_ROOT" ]] || fail "[$BACKUP_ROOT] is not mounted"
    [[ "$BORG_LOCAL_REPO_NAME" == /* ]] && fail "BORG_LOCAL_REPO_NAME should not start with a slash"
}


create_dirs() {
    mkdir -p -- "$RESTORE_DIR" || fail "dir [$RESTORE_DIR] creation failed"
}


cleanup() {
    [[ "$KEEP_DIR" -ne 1 && -d "$RESTORE_DIR" ]] && rm -r -- "$RESTORE_DIR"
    [[ -d "$RESTORE_DIR" ]] && echo -e "\n\n    -> restored files are in [$RESTORE_DIR]"
}


# ================
# Entry
# ================
trap -- 'cleanup; exit' EXIT HUP INT QUIT PIPE TERM
source /scripts_common.sh || { echo -e "failed to import /scripts_common.sh"; exit 1; }
source /env_vars.sh || fail "failed to import /env_vars.sh"
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
        *) exit 1
            ;;
    esac
done

readonly RESTORE_DIR="$BACKUP_ROOT/restored-${ARCHIVE_NAME}"  # dir where selected borg archive will be restored into
readonly BORG_LOCAL_REPO="$BACKUP_ROOT/${BORG_LOCAL_REPO_NAME:-repo}"

validate_config
check_dependencies
create_dirs
verify_borg

start_or_stop_containers stop "${CONTAINERS[@]}"
do_restore
# do not start containers, so we'd have time to manualy move the data files back, if any

exit 0

