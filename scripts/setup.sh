#!/usr/bin/env bash
#
# this is service bootstrap logic to be called from container entrypoint.
#
# - initialises crontab;
# - sets ssh key, if available & adds our remote borg to know_hosts;
# - configures msmtprc for mail notifications;

readonly SELF="${0##*/}"
readonly LOG="/var/log/${SELF}.log"
JOB_ID="setup-$$"


check_dependencies() {
    local i

    for i in curl docker mysql mysqldump borg ssh-keygen ssh-keyscan tr sed find msmtp; do
        command -v "$i" >/dev/null || fail "[$i] not installed"
    done
}


setup_crontab() {
    #local cron_target
    #readonly cron_target='/var/spool/cron/crontabs/root'

    if [[ -f "$CRON_FILE" ]]; then
        ## TODO: this won't work, as /config is mounted read-only:
        #grep -q '^BASH_ENV=' "$CRON_FILE" || sed -i '1s+^+BASH_ENV=/container.env\n+' "$CRON_FILE"
        #grep -q '^SHELL=' "$CRON_FILE" || sed -i '1s+^+SHELL=/bin/bash\n+' "$CRON_FILE"

        #[[ -f "$cron_target" ]] || fail "[$cron_target] does not exist; is cron installed?"
        #cp -- "$CRON_FILE" "$cron_target"

        # or, alterntaively, install via $crontab:
        /usr/bin/crontab "$CRON_FILE" || fail "crontab installation failed w/ [$?]"
    fi
}


install_ssh_key() {
    local ssh_key_target

    readonly ssh_key_target=~/.ssh/id_rsa

    _add_remote_to_known_hosts_if_missing() {
        local remote_host

        remote_host="$(grep -Po '^.*@\K.*(?=:.*$)' <<< "$REMOTE")"
        [[ $? -ne 0 || -z "$remote_host" ]] && fail "could not extract remote host from REMOTE [$REMOTE]"

        if [[ -z "$(ssh-keygen -F "$remote_host")" ]]; then
            ssh-keyscan -H "$remote_host" >> ~/.ssh/known_hosts || fail "adding host [$remote_host] to ~/.ssh/known_hosts failed w/ [$?]"
        fi
    }

    [[ -d ~/.ssh ]] || fail "[~/.ssh] is not a dir; is ssh client installed?"
    [[ -f "$SSH_KEY" ]] && cp -- "$SSH_KEY" "$ssh_key_target"
    [[ -n "$REMOTE" ]] && _add_remote_to_known_hosts_if_missing

    # sanitize .ssh perms:
    chmod -R u=rwX,g=,o= -- ~/.ssh
}


setup_msmtp() {
    local target_conf

    target_conf='/etc/msmtprc'

    rm -f /usr/sbin/sendmail || fail "rm sendmail failed w/ $?"
    ln -s /usr/bin/msmtp /usr/sbin/sendmail || fail "linking sendmail failed w/ $?"

    if [[ -f "$MSMTPRC" && -s "$MSMTPRC" ]]; then
        cat -- "$MSMTPRC" > "$target_conf"
    else
        cat > "$target_conf" <<EOF
### Auto-generated at container startup ###
defaults
auth ${SMTP_AUTH:-on}
tls ${SMTP_TLS:-on}
tls_starttls ${SMTP_STARTTLS:-on}
#tls_certcheck ${SMTP_TLSCERTCHECK:-on}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log
protocol smtp
port ${SMTP_PORT:-587}

account default
host ${SMTP_HOST}
user ${SMTP_USER}
password ${SMTP_PASS}
EOF
    fi
}


NO_SEND_MAIL=true  # stop sending mails during startup/setup; allow other notifications
#printenv | sed 's/^\(\w\+\)=\(.*\)$/export \1="\2"/g' > /env_vars.sh || { echo -e "    ERROR: printenv failed" | tee -a "$LOG"; exit 1; }
#env | sed -r "s/'/\\\'/gm" | sed -r "s/^([^=]+=)(.*)\$/\1'\2'/gm" \ > /etc/environment
#declare -p | grep -Ev '\b(BASHOPTS|BASH_VERSINFO|EUID|PPID|SHELLOPTS|UID)=' > /container.env || { echo -e "    ERROR: printenv failed" | tee -a "$LOG"; exit 1; }
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" | tee -a "$LOG"; exit 1; }
#chmod 600 /container.env || fail "chmod-ing /container.env failed w/ [$?]"

check_dependencies
validate_config_common
setup_crontab
install_ssh_key
setup_msmtp
unset NO_SEND_MAIL

exit 0

