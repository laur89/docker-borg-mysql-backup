#!/bin/bash
#
# this file is to be placed in /etc/my_init.d/
#
# writes down env vars so they can be sourced by the scripts executed by cron.
# also initialises cron & sets ssh key, if available.

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

    [[ -d ~/.ssh ]] || fail "[~/.ssh] is not a dir; is ssh client installed?"
    [[ -f "$SSH_KEY" ]] && cp -- "$SSH_KEY" "$ssh_key_target"
}


source /scripts_common.sh || { echo -e "failed to import /scripts_common.sh"; exit 1; }
printenv | sed 's/^\(\w\+\)=\(.*\)$/export \1="\2"/g' > /env_vars.sh

install_crontab
install_ssh_key

exit 0
