#!/usr/bin/env bash
#
# lists contents of local or remote archive

readonly SELF="${0##*/}"
readonly LOG="/var/log/${SELF}.log"
JOB_ID="list-$$"

readonly usage="
    usage: $SELF [-h] [-r] [-l] [-N BORG_LOCAL_REPO_NAME]

    List archives in a borg repository

    arguments:
      -h                      show help and exit
      -r                      list remote borg repo
      -l                      list local borg repo
      -N BORG_LOCAL_REPO_NAME overrides container env variable BORG_LOCAL_REPO_NAME; optional;
"


list_repos() {

    if [[ "$LOCAL_REPO" -eq 1 ]]; then
        borg list \
            $BORG_EXTRA_OPTS \
            $BORG_LOCAL_EXTRA_OPTS \
            "$BORG_LOCAL_REPO" || fail "listing local repo [$BORG_LOCAL_REPO] failed w/ [$?]"
    elif [[ "$REMOTE_REPO" -eq 1 ]]; then
        borg list \
            $BORG_EXTRA_OPTS \
            $BORG_REMOTE_EXTRA_OPTS \
            "$REMOTE" || fail "listing [$REMOTE] failed w/ [$?]"
    else
        fail "need to select local or remote repo"
    fi
}


validate_config() {
    local i val vars

    declare -a vars

    [[ "$REMOTE_REPO" -eq 1 ]] && vars+=(REMOTE)

    for i in "${vars[@]}"; do
        val="$(eval echo "\$$i")" || fail "evaling [echo \"\$$i\"] failed w/ [$?]"
        [[ -z "$val" ]] && fail "[$i] is not defined"
    done

    [[ "$REMOTE_OR_LOCAL_OPT_COUNTER" -ne 1 ]] && fail "need to select whether to list local or remote repo"
    [[ "$BORG_LOCAL_REPO_NAME" == /* ]] && fail "BORG_LOCAL_REPO_NAME should not start with a slash"
}

# ================
# Entry
# ================
NO_NOTIF=true  # do not notify errors
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" | tee -a "$LOG"; exit 1; }
REMOTE_OR_LOCAL_OPT_COUNTER=0

while getopts "rlNh" opt; do
    case "$opt" in
        r) REMOTE_REPO=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        l) LOCAL_REPO=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        N) BORG_LOCAL_REPO_NAME="$OPTARG"  # overrides env var of same name
            ;;
        h) echo -e "$usage"
           exit 0
            ;;
        *) fail "$SELF called with unsupported flag(s)"
            ;;
    esac
done

readonly BORG_LOCAL_REPO="$BACKUP_ROOT/${BORG_LOCAL_REPO_NAME:-$DEFAULT_LOCAL_REPO_NAME}"

validate_config
list_repos

exit 0

