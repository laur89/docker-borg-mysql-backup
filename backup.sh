#!/bin/bash
#
# backs up mysql dump and/or other data to local and/or remote borg repository


readonly usage="
    usage: backup [-h] [-d MYSQL_DBS] [-n NODES_TO_BACKUP] [-c CONTAINERS]
                  [-r] [-l] [-P BORG_PRUNE_OPTS] [-N BORG_LOCAL_REPO_NAME] -p PREFIX

    Create new archive

    arguments:
      -h                      show help and exit
      -d MYSQL_DBS            space separated database names to back up; __all__ to back up
                              all dbs on the server
      -n NODES_TO_BACKUP      space separated files/directories to back up (in addition to db dumps);
                              filenames may not contain spaces, as space is the separator
      -c CONTAINERS           space separated container names to stop for the backup process;
                              requires mounting the docker socket (-v /var/run/docker.sock:/var/run/docker.sock)
      -r                      only back to remote borg repo (remote-only)
      -l                      only back to local borg repo (local-only)
      -P BORG_PRUNE_OPTS      overrides container env variable BORG_PRUNE_OPTS; only required when
                              container var is not defined;
      -N BORG_LOCAL_REPO_NAME overrides container env variable BORG_LOCAL_REPO_NAME; optional;
      -p PREFIX               borg archive name prefix. note that the full archive name already
                              contains hostname and timestamp.
"

# expands the $NODES_TO_BACK_UP with files in $TMP/, if there are any
expand_nodes_to_back_up() {
    if ! is_dir_empty "$TMP"; then
        for i in "$TMP/"*; do
            NODES_TO_BACK_UP+=("$(basename -- "$i")")  # note relative path; we don't want borg archive to contain "$TMP_ROOT" path
        done
    fi
}


# dumps selected db(s) to $TMP
dump_db() {
    local output_filename

    [[ -z "$MYSQL_DB" ]] && return 0  # no db specified, meaning db dump not required

    if [[ "$MYSQL_DB" == __all__ ]]; then
        output_filename='all-dbs'
        MYSQL_DB='--all-databases'
    else
        output_filename="${MYSQL_DB// /+}"  # let the filename reflect which dbs it contains
        MYSQL_DB="--databases $MYSQL_DB"
    fi

    mysqldump \
            --add-drop-database \
            -h${MYSQL_HOST} \
            -P${MYSQL_PORT} \
            -u${MYSQL_USER} \
            -p${MYSQL_PASS} \
            ${MYSQL_EXTRA_OPTS} \
            ${MYSQL_DB} > "$TMP/${output_filename}.sql"

    return "$?"
}


# backup selected data
do_backup() {
    local start_time end_time

    readonly start_time="$(date +%H:%M:%S)"

    echo "=> Backup started at [$start_time]"

    dump_db || fail "db dump failed with [$?]"
    expand_nodes_to_back_up

    [[ "${#NODES_TO_BACK_UP[@]}" -eq 0 ]] && fail "no items selected for backup"
    pushd -- "$TMP" || fail "unable to pushd into [$TMP]"  # cd there because files in $TMP are added without full path (to avoid "$TMP_ROOT" prefix in borg repo)

    if [[ "$REMOTE_ONLY" -ne 1 ]]; then
        borg create -v --stats \
            $BORG_EXTRA_OPTS \
            $BORG_LOCAL_EXTRA_OPTS \
            "$BORG_LOCAL_REPO"::"$ARCHIVE_NAME" \
            "${NODES_TO_BACK_UP[@]}"

        borg prune -v --list \
            "$BORG_LOCAL_REPO" \
            --prefix "$PREFIX_WITH_HOSTNAME" \
            $BORG_PRUNE_OPTS
    fi

    if [[ "$LOCAL_ONLY" -ne 1 ]]; then
        # duplicate to remote location: (http://borgbackup.readthedocs.io/en/latest/faq.html#can-i-copy-or-synchronize-my-repo-to-another-location)
        borg create -v --stats \
            $BORG_EXTRA_OPTS \
            $BORG_REMOTE_EXTRA_OPTS \
            "$REMOTE"::"$ARCHIVE_NAME" \
            "${NODES_TO_BACK_UP[@]}"

        borg prune -v --list \
            "$REMOTE" \
            --prefix "$PREFIX_WITH_HOSTNAME" \
            $BORG_PRUNE_OPTS
    fi

    popd
    readonly end_time="$(date +%H:%M:%S)"
    echo "=> Backup finished at [$end_time]"

    return 0
}


# if $BORG_LOCAL_REPO is empty, initialises repo there; if it's not empty, checks if
# it really is a borg repo;
# remote repo existence is simply verified; we won't try to init those automatically.
init_or_verify_borg() {
    local i val

    if [[ "$REMOTE_ONLY" -ne 1 ]]; then
        if [[ ! -d "$BORG_LOCAL_REPO" ]] || is_dir_empty "$BORG_LOCAL_REPO"; then
            borg init "$BORG_LOCAL_REPO" || fail "borg repo init @ [$BORG_LOCAL_REPO] failed"
        else
            borg list "$BORG_LOCAL_REPO" > /dev/null || fail "[borg list $BORG_LOCAL_REPO] failed. is it a borg repo?"
        fi
    fi

    if [[ "$LOCAL_ONLY" -ne 1 ]]; then
        borg list "$REMOTE" > /dev/null || fail "[borg list $REMOTE] failed; please create remote repos manually beforehand"
    fi
}


validate_config() {
    local i val vars

    declare -a vars=(
        ARCHIVE_PREFIX
        BORG_PASSPHRASE
        BORG_PRUNE_OPTS
    )
    [[ -n "$MYSQL_DB" ]] && vars+=(
            MYSQL_HOST
            MYSQL_PORT
            MYSQL_USER
            MYSQL_PASS
        )
    [[ "$LOCAL_ONLY" -ne 1 ]] && vars+=(REMOTE)

    for i in "${vars[@]}"; do
        val="$(eval echo "\$$i")" || fail "evaling [echo $i] failed with code [$?]"
        [[ -z "$val" ]] && fail "[$i] is not defined"
    done

    if [[ "${#NODES_TO_BACK_UP[@]}" -gt 0 ]]; then
        for i in "${NODES_TO_BACK_UP[@]}"; do
            [[ -e "$i" ]] || fail "node [$i] to back up does not exist"
        done
    fi

    [[ "$REMOTE_OR_LOCAL_OPT_COUNTER" -gt 1 ]] && fail "-r & -l options are exclusive"
    [[ -d "$BACKUP_ROOT" ]] || fail "[$BACKUP_ROOT] is not mounted"
    [[ "$BORG_LOCAL_REPO_NAME" == /* ]] && fail "BORG_LOCAL_REPO_NAME should not start with a slash"

    if [[ "$LOCAL_ONLY" -ne 1 && "$-" != *i* ]]; then
        [[ -f "$SSH_KEY" ]] || fail "[$SSH_KEY] is not a file; is /config mounted?"
    fi
}


create_dirs() {
    mkdir -p -- "$TMP" || fail "dir [$TMP] creation failed"
}


cleanup() {
    [[ -d "$TMP" ]] && rm -rf -- "$TMP"
    [[ -d "$TMP_ROOT" ]] && is_dir_empty "$TMP_ROOT" && rm -rf -- "$TMP_ROOT"
}


# ================
# Entry
# ================
trap -- 'cleanup; exit' EXIT HUP INT QUIT PIPE TERM
source /scripts_common.sh || { echo -e "failed to import /scripts_common.sh"; exit 1; }
source /env_vars.sh || fail "failed to import /env_vars.sh"
REMOTE_OR_LOCAL_OPT_COUNTER=0

while getopts "d:n:p:c:rlP:N:h" opt; do
    case "$opt" in
        d) MYSQL_DB="$OPTARG"
            ;;
        n) NODES_TO_BACK_UP+=($OPTARG)
            ;;
        p) ARCHIVE_PREFIX="$OPTARG"
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
        N) BORG_LOCAL_REPO_NAME="$OPTARG"  # overrides env var of same name
            ;;
        h) echo -e "$usage"
           exit 0
            ;;
        *) exit 1
            ;;
    esac
done

readonly TMP_ROOT="$BACKUP_ROOT/.tmp"
readonly TMP="$TMP_ROOT/$RANDOM"

readonly PREFIX_WITH_HOSTNAME="${ARCHIVE_PREFIX}-${HOST_HOSTNAME:-$HOSTNAME}-"  # needs to come after sourcing env_vars
readonly ARCHIVE_NAME="$PREFIX_WITH_HOSTNAME"'{now:%Y-%m-%d-%H%M%S}'
readonly BORG_LOCAL_REPO="$BACKUP_ROOT/${BORG_LOCAL_REPO_NAME:-repo}"

validate_config
check_dependencies
create_dirs
init_or_verify_borg

start_or_stop_containers stop "${CONTAINERS[@]}"
do_backup
start_or_stop_containers start "${CONTAINERS[@]}"

exit 0

