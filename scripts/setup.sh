#!/usr/bin/env bash
#
# this file is to be placed in /etc/my_init.d/
#
# writes down env vars so they can be sourced by the scripts executed by cron.
# also initialises cron & sets ssh key, if available.

readonly SELF="${0##*/}"
readonly LOG="/var/log/${SELF}.log"

setup_crontab() {
    local cron_target

    readonly cron_target='/var/spool/cron/crontabs/root'

    [[ -f "$cron_target" ]] || fail "[$cron_target] does not exist; is cron installed?"
    [[ -f "$CRON_FILE" ]] && cp -- "$CRON_FILE" "$cron_target"
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


setup_msmtp() {
    rm -f /usr/sbin/sendmail || fail "rm sendmail failed w/ $?"
    ln -s /usr/bin/msmtp /usr/sbin/sendmail || fail "linking sendmail failed w/ $?"

    if true; then  # TODO
        rm -f /usr/sbin/sendmail
        ln -s /usr/bin/msmtp /usr/sbin/sendmail

        if [[ -f "$MSMTPRC" ]]; then
            cat -- "$MSMTPRC" > /etc/msmtprc
        else
            cat > /etc/msmtprc <<EOF
### Automatically generated on container start. See documentation on how to set!'
account default
host ${SMTP_HOST}
port ${SMTP_PORT}
#from ${SMTP_FROM}
${SMTP_AUTH:+auth $SMTP_AUTH}
${SMTP_USER:+user $SMTP_USER}
${SMTP_PASS:+password $SMTP_PASS}
tls ${SMTP_TLS}
tls_starttls ${SMTP_STARTTLS}
tls_certcheck ${SMTP_TLSCERTCHECK}
logfile /var/log/msmtp.log
### Gmail Specific SMTP Config
#if var_true "$ENABLE_SMTP_GMAIL" ; then echo "auto_from on"; fi
EOF
        fi
    fi
}


printenv | sed 's/^\(\w\+\)=\(.*\)$/export \1="\2"/g' > /env_vars.sh || { echo -e "    ERROR: printenv failed" | tee -a "$LOG"; exit 1; }
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" | tee -a "$LOG"; exit 1; }
chmod 600 /env_vars.sh || fail "chmod-ing /env_vars.sh failed w/ $?"

setup_crontab
install_ssh_key
setup_msmtp

exit 0
