#!/usr/bin/env bash
#
# lists contents of local or remote archive

readonly SELF="${0##*/}"
readonly LOG="/var/log/${SELF}.log"
JOB_ID="list-$$"

readonly usage="
    usage: $SELF [-h] [-rl] [-L BORG_LOCAL_REPO] [-R REMOTE] [-T REMOTE_REPO]

    List archives in a borg repository

    arguments:
      -h                      show help and exit
      -r                      list remote borg repo
      -l                      list local borg repo
      -L BORG_LOCAL_REPO      overrides container env variable of same name
      -R REMOTE               remote connection; overrides env var of same name
      -T REMOTE_REPO          path to repo on remote host; overrides env var of same name
"


_list_common() {
    local l_or_r repo extra_opts

    l_or_r="$1"
    repo="$2"
    extra_opts="$3"

    borg list --show-rc \
        $BORG_EXTRA_OPTS \
        $extra_opts \
        "$repo" > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2) || fail "listing $l_or_r repo [$repo] failed w/ [$?]"
}


# TODO: do not fail() if err code <=1?
list_repos() {

    if [[ "$LOC" -eq 1 ]]; then
        _list_common local "$BORG_LOCAL_REPO" "$BORG_LOCAL_EXTRA_OPTS"
    elif [[ "$REM" -eq 1 ]]; then
        _list_common remote "$REMOTE" "$BORG_REMOTE_EXTRA_OPTS"
    else
        fail "need to select local or remote repo"
    fi
}


validate_config() {
    local vars

    declare -a vars

    [[ "$REM" -eq 1 ]] && vars+=(REMOTE REMOTE_REPO)
    [[ "$LOC" -eq 1 ]] && vars+=(BORG_LOCAL_REPO)

    vars_defined "${vars[@]}"

    [[ "$REMOTE_OR_LOCAL_OPT_COUNTER" -ne 1 ]] && fail "need to select whether to list local or remote repo"
    [[ "$LOC" -eq 1 ]] && [[ ! -d "$BORG_LOCAL_REPO" || ! -w "$BORG_LOCAL_REPO" ]] && fail "[$BORG_LOCAL_REPO] does not exist or is not writable; missing mount?"
}

# ================
# Entry
# ================
NO_NOTIF=true  # do not notify errors
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" | tee -a "$LOG"; exit 1; }
REMOTE_OR_LOCAL_OPT_COUNTER=0

while getopts "rlL:R:T:h" opt; do
    case "$opt" in
        r) REM=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        l) LOC=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        L) BORG_LOCAL_REPO="$OPTARG"  # overrides env var of same name
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
[[ -n "$REMOTE" ]] && add_remote_to_known_hosts_if_missing
readonly REMOTE+=":$REMOTE_REPO"  # define after validation
list_repos

exit 0

