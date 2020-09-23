#!/usr/bin/env bash
#
# this file is to be placed in /etc/my_init.d/
#
# writes down env vars so they can be sourced by the scripts executed by cron.
# also initialises cron & sets ssh key, if available.

readonly SELF="${0##*/}"
readonly LOG="/var/log/${SELF}.log"

install_crontab() {
    local cron_dir

    readonly cron_dir='/etc/cron.d'

    [[ -d "$cron_dir" ]] || fail "[$cron_dir] is not a dir; is cron installed?"
    rm -r "${cron_dir:?}/"* 2> /dev/null  # remove previous cron file(s)
    [[ -f "$CRON_FILE" ]] && cp -- "$CRON_FILE" "$cron_dir/"
}


install_ssh_key() {
    local ssh_key_target

    readonly ssh_key_target=~/.ssh/id_rsa

    _add_remote_to_known_hosts_if_missing() {
        local remote_host

        remote_host="$(grep -Po '^.*@\K.*(?=:.*$)' <<< "$REMOTE")"
        [[ -z "$remote_host" ]] && fail "could not extract remote host from REMOTE [$REMOTE]"

        if [[ -z "$(ssh-keygen -F "$remote_host")" ]]; then
            ssh-keyscan -H "$remote_host" >> ~/.ssh/known_hosts || fail "adding host [$remote_host] to ~/.ssh/known_hosts failed"
        fi
    }

    [[ -d ~/.ssh ]] || fail "[~/.ssh] is not a dir; is ssh client installed?"
    [[ -f "$SSH_KEY" ]] && cp -- "$SSH_KEY" "$ssh_key_target"
    [[ -n "$REMOTE" ]] && _add_remote_to_known_hosts_if_missing
    # sanitize .ssh perms:
    chmod -R u=rwX,g=,o= -- ~/.ssh
}


source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" | tee "$LOG"; exit 1; }

install_crontab
install_ssh_key

exit 0
