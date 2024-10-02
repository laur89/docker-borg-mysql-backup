#!/usr/bin/env bash
#
# check local and/or remote borg repositories

readonly SELF="${0##*/}"
JOB_ID="check-$$"

readonly usage="
    usage: $SELF [-h] [-rlF] [-p ARCHIVE_PREFIX] [-a ARCHIVE] [-B BORG_OPTS]
             [-L LOCAL_REPO] [-R REMOTE] [-T REMOTE_REPO]

    Verify the consistency of a repo and its archives.

    arguments:
      -h                      show help and exit
      -r                      only check remote borg repo (remote-only)
      -l                      only check local borg repo (local-only)
      -F                      attempt to repair/fix inconsistencies; dangerous, see docs!
      -p ARCHIVE_PREFIX       check archives with given prefix; same as providing
                              -B '--glob-archives ARCHIVE_PREFIX*'
      -a ARCHIVE              archive name to check; -p & -a are mutually exclusive
      -B BORG_OPTS            additional borg params to pass to borg check command
      -L LOCAL_REPO           overrides container env var of same name
      -R REMOTE               overrides container env var of same name
      -T REMOTE_REPO          overrides container env var of same name
"


_check_common() {
    local l_or_r repo start_timestamp err_code t

    l_or_r="$1"
    repo="$2"

    log "=> starting check operation on $l_or_r repo [$repo]..."
    start_timestamp="$(date +%s)"

    borg check --verify-data $REPAIR --stats --show-rc \
        $COMMON_OPTS \
        $BORG_OPTS \
        "${repo}${ARCHIVE:+::$ARCHIVE}" > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || { err "check operation on $l_or_r repo [$repo] failed w/ [$?]"; err_code=1; }

    t="$(( $(date +%s) - start_timestamp ))"
    log "=> $l_or_r repo check ${err_code:-succeeded} in $(print_time "$t")"

    return "${err_code:-0}"
}


check() {
    if [[ "$REMOTE_ONLY" -ne 1 ]]; then
        _check_common local "$LOCAL_REPO"  # do not background; even remote check takes resources locally
    fi

    if [[ "$LOCAL_ONLY" -ne 1 ]]; then
        _check_common remote "$REMOTE"  # do not background; even remote check takes resources locally
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
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" >&2; exit 1; }
REMOTE_OR_LOCAL_OPT_COUNTER=0
ARCHIVE_OR_PREFIX_OPT_COUNTER=0

unset ARCHIVE ARCHIVE_PREFIX BORG_OPTS REPAIR  # just in case

while getopts 'rlFp:a:B:L:R:T:h' opt; do
    case "$opt" in
        r) REMOTE_ONLY=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        l) LOCAL_ONLY=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        F) REPAIR='--repair'
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
process_remote  # note this overwrites global REMOTE var

[[ -n "$ARCHIVE_PREFIX" ]] && BORG_OPTS+=" --glob-archives ${ARCHIVE_PREFIX}*"
check

exit 0

