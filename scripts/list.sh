#!/usr/bin/env bash
#
# lists contents of local or remote archive

readonly SELF="${0##*/}"
readonly LOG="/var/log/${SELF}.log"
JOB_ID="list-$$"

readonly usage="
    usage: $SELF [-h] [-rl] [-p ARCHIVE_PREFIX] [-B BORG_OPTS] [-L LOCAL_REPO]
             [-R REMOTE] [-T REMOTE_REPO] [-a ARCHIVE_NAME]


    List archives in a borg repository or contents of an archive

    arguments:
      -h                      show help and exit
      -r                      list remote borg repo
      -l                      list local borg repo
      -p ARCHIVE_PREFIX       list archives with given prefix; same as providing
                              [-B '--glob-archives ARCHIVE_PREFIX*']
      -B BORG_OPTS            additional borg params to pass to borg list command
      -L LOCAL_REPO           overrides container env var of same name
      -R REMOTE               overrides container env var of same name
      -T REMOTE_REPO          overrides container env var of same name
      -a ARCHIVE_NAME         full name of the borg archive whose contents to list
"


# TODO: do not fail() if err code <=1?
_list_common() {
    local l_or_r repo

    l_or_r="$1"
    repo="$2"

    borg list --show-rc \
        $COMMON_OPTS \
        $BORG_OPTS \
        "${repo}${ARCHIVE_NAME:+::$ARCHIVE_NAME}" > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || fail "listing $l_or_r repo [$repo] failed w/ [$?]"
}


list_repos() {

    if [[ "$LOC" -eq 1 ]]; then
        _list_common local "$LOCAL_REPO"
    elif [[ "$REM" -eq 1 ]]; then
        _list_common remote "$REMOTE"
    else
        fail "need to select local or remote repo"
    fi
}


validate_config() {
    local vars

    declare -a vars

    [[ "$REM" -eq 1 ]] && vars+=(REMOTE REMOTE_REPO)
    [[ "$LOC" -eq 1 ]] && vars+=(LOCAL_REPO)

    vars_defined "${vars[@]}"

    [[ "$REMOTE_OR_LOCAL_OPT_COUNTER" -ne 1 ]] && fail "need to select whether to list local or remote repo"
    [[ "$LOC" -eq 1 ]] && [[ ! -d "$LOCAL_REPO" || ! -w "$LOCAL_REPO" ]] && fail "[$LOCAL_REPO] does not exist or is not writable; missing mount?"
    [[ -n "$ARCHIVE_PREFIX" && -n "$ARCHIVE_NAME" ]] && fail "ARCHIVE_NAME & ARCHIVE_PREFIX options are mutually exclusive"
}

# ================
# Entry
# ================
NO_NOTIF=true  # do not notify errors
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" | tee -a "$LOG"; exit 1; }
REMOTE_OR_LOCAL_OPT_COUNTER=0

unset ARCHIVE_PREFIX BORG_OPTS ARCHIVE_NAME  # just in case

while getopts 'rlp:B:L:R:T:a:h' opt; do
    case "$opt" in
        r) REM=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        l) LOC=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        p) ARCHIVE_PREFIX="$OPTARG"
            ;;
        B) BORG_OPTS="$OPTARG"
            ;;
        L) LOCAL_REPO="$OPTARG"  # overrides env var of same name
            ;;
        R) REMOTE="$OPTARG"  # overrides env var of same name
            ;;
        T) REMOTE_REPO="$OPTARG"  # overrides env var of same name
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

[[ -n "$ARCHIVE_PREFIX" ]] && BORG_OPTS+=" --glob-archives ${ARCHIVE_PREFIX}*"
list_repos

exit 0

