#!/usr/bin/env bash
#
# compact local and/or remote borg repository

readonly SELF="${0##*/}"
JOB_ID="compact-$$"

readonly usage="
    usage: $SELF [-h] [-rl] [-B BORG_OPTS] [-L LOCAL_REPO]
                [-R REMOTE] [-T REMOTE_REPO]


    Compact borg repository

    arguments:
      -h                      show help and exit
      -r                      compact only remote borg repo (remote-only)
      -l                      compact only local borg repo (local-only)
      -B BORG_OPTS            additional borg params to pass to borg compact command
      -L LOCAL_REPO           overrides container env var of same name
      -R REMOTE               overrides container env var of same name
      -T REMOTE_REPO          overrides container env var of same name
"


validate_config() {
    local vars

    declare -a vars

    [[ "$LOCAL_ONLY" -ne 1 ]] && vars+=(REMOTE REMOTE_REPO)
    [[ "$REMOTE_ONLY" -ne 1 ]] && vars+=(LOCAL_REPO)

    vars_defined "${vars[@]}"

    [[ "$REMOTE_OR_LOCAL_OPT_COUNTER" -gt 1 ]] && fail "-r & -l options are exclusive"
    [[ "$REMOTE_ONLY" -ne 1 ]] && [[ ! -d "$LOCAL_REPO" || ! -w "$LOCAL_REPO" ]] && fail "[$LOCAL_REPO] does not exist or is not writable; missing mount?"
}

# ================
# Entry
# ================
NO_NOTIF=true  # do not notify errors
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" >&2; exit 1; }
REMOTE_OR_LOCAL_OPT_COUNTER=0

unset BORG_OPTS # just in case

while getopts 'rlB:L:R:T:h' opt; do
    case "$opt" in
        r) REMOTE_ONLY=1
           let REMOTE_OR_LOCAL_OPT_COUNTER+=1
            ;;
        l) LOCAL_ONLY=1
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
        h) echo -e "$usage"
           exit 0
            ;;
        *) fail "$SELF called with unsupported flag(s)"
            ;;
    esac
done

validate_config
process_remote  # note this overwrites global REMOTE var

compact_repos

exit 0

