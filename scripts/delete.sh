#!/usr/bin/env bash
#
# delete archive or whole repository

readonly SELF="${0##*/}"
readonly LOG="/var/log/${SELF}.log"
JOB_ID="delete-$$"

readonly usage="
    usage: $SELF [-h] [-rl] [-p ARCHIVE_PREFIX] [-a ARCHIVE] [-B BORG_OPTS]
             [-L LOCAL_REPO] [-R REMOTE] [-T REMOTE_REPO]

    Delete whole borg repository or archives in it

    arguments:
      -h                      show help and exit
      -r                      operate on remote repo
      -l                      operate on local repo
      -r                      only delete from remote borg repo (remote-only)
      -l                      only delete from local borg repo (local-only)
      -p ARCHIVE_PREFIX       delete archives with given prefix; same as providing
                              -B '--prefix ARCHIVE_PREFIX'
      -a ARCHIVE              archive name to delete; -p & -a are mutually exclusive
      -B BORG_OPTS            additional borg params to pass to borg delete command
      -L LOCAL_REPO           overrides container env var of same name
      -R REMOTE               overrides container env var of same name
      -T REMOTE_REPO          overrides container env var of same name
"


# TODO: do not fail() if err code <=1?
_del_common() {
    local l_or_r repo

    l_or_r="$1"
    repo="$2"

    log "=> starting delete operation on $l_or_r repo [$repo]..."
    borg delete --stats --show-rc \
        $BORG_OPTS \
        "${repo}${ARCHIVE:+::$ARCHIVE}" > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || fail "delete operation on $l_or_r repo [$repo] failed w/ [$?]"
}


delete() {
    if [[ "$REMOTE_ONLY" -ne 1 ]]; then
        _del_common local "$LOCAL_REPO"  # no need to background
    fi

    if [[ "$LOCAL_ONLY" -ne 1 ]]; then
        _del_common remote "$REMOTE"  # no need to background
    fi
}


validate_config() {
    local vars

    declare -a vars

    [[ "$LOCAL_ONLY" -ne 1 ]] && vars+=(REMOTE REMOTE_REPO)
    [[ "$REMOTE_ONLY" -ne 1 ]] && vars+=(LOCAL_REPO)

    vars_defined "${vars[@]}"

    [[ "$REMOTE_OR_LOCAL_OPT_COUNTER" -gt 1 ]] && fail "-r & -l options are exclusive"
    [[ "$REMOTE_ONLY" -ne 1 ]] && [[ ! -d "$LOCAL_REPO" || ! -w "$LOCAL_REPO" ]] && fail "[$LOCAL_REPO] does not exist or is not writable; missing mount?"
    [[ "$ARCHIVE_OR_PREFIX_OPT_COUNTER" -gt 1 ]] && fail "defining both archive prefix & full archive name are mutually exclusive"
}

# ================
# Entry
# ================
NO_NOTIF=true  # do not notify errors
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" | tee -a "$LOG"; exit 1; }
REMOTE_OR_LOCAL_OPT_COUNTER=0
ARCHIVE_OR_PREFIX_OPT_COUNTER=0

unset ARCHIVE ARCHIVE_PREFIX BORG_OPTS  # just in case

while getopts "rlp:a:B:L:R:T:h" opt; do
    case "$opt" in
        r) REMOTE_ONLY=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        l) LOCAL_ONLY=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        p) ARCHIVE_PREFIX="$OPTARG"
           let ARCHIVE_OR_PREFIX_OPT_COUNTER+=1
            ;;
        a) ARCHIVE="$OPTARG"
           let ARCHIVE_OR_PREFIX_OPT_COUNTER+=1
            ;;
        B) BORG_OPTS="$OPTARG"
            ;;
        L) LOCAL_REPO="$OPTARG"  # overrides env var of same name
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

validate_config
[[ -n "$REMOTE" ]] && add_remote_to_known_hosts_if_missing "$REMOTE"
readonly REMOTE+=":$REMOTE_REPO"  # define after validation

[[ -n "$ARCHIVE_PREFIX" ]] && BORG_OPTS+=" --prefix $ARCHIVE_PREFIX"
delete

exit 0

