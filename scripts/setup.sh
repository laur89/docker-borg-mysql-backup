#!/usr/bin/env bash
#
# this is service bootstrap logic to be called from container entrypoint.
#
# - initialises crontab;
# - sets ssh key, if available & adds our remote borg to know_hosts;
# - configures msmtprc for mail notifications;

readonly SELF="${0##*/}"
JOB_ID="setup-$$"


check_dependencies() {
    local i

    for i in curl docker mysql mysqldump borg ssh-keygen ssh-keyscan tr sed find msmtp run-parts; do
        command -v "$i" >/dev/null || fail "[$i] not installed"
    done
}


setup_crontab() {
    #local cron_target
    #readonly cron_target='/var/spool/cron/crontabs/root'

    if [[ -f "$CRON_FILE" && -s "$CRON_FILE" ]]; then
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

    readonly ssh_key_target="$HOME/.ssh/id_rsa"

    [[ -d "$HOME/.ssh" ]] || fail "[~/.ssh] is not a dir; is ssh client installed?"
    if [[ -f "$SSH_KEY" && -s "$SSH_KEY" ]]; then
        cp -- "$SSH_KEY" "$ssh_key_target" || fail "ssh keyfile copy failed w/ $?"
        ssh-keygen -y -P "" -f "$ssh_key_target" &>/dev/null || fail "provided ssh key is password-protected - this is not supported"
    fi

    # sanitize .ssh perms:
    chmod -R u=rwX,g=,o= -- ~/.ssh

    [[ -n "$REMOTE" ]] && add_remote_to_known_hosts_if_missing "$REMOTE"
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

account common
host ${SMTP_HOST}
user ${SMTP_USER}
password ${SMTP_PASS}

# set default account:
account default : common
EOF
    fi
}


setup_logrotate() {
    local opt rotate interval size name pattern rotate_confdir target_conf OPTIND

    while getopts 'r:i:s:n:p:' opt; do
        case "$opt" in
            r) rotate="$OPTARG"
                ;;
            i) interval="$OPTARG"
                ;;
            s) size="$OPTARG"
                ;;
            n) name="$OPTARG"
                ;;
            p) pattern="$OPTARG"
                ;;
            *) fail "$FUNCNAME called with unsupported flag(s)"
                ;;
        esac
    done
    shift "$((OPTIND-1))"

    [[ -z "$rotate" ]] && rotate=5
    [[ -z "$interval" ]] && interval=weekly
    [[ -z "$size" ]] && size=10M
    [[ -z "$name" ]] && name=common-config
    [[ -z "$pattern" ]] && pattern="$LOG_ROOT/*.log"


    rotate_confdir='/etc/logrotate.d'
    target_conf="$rotate_confdir/$name"

    [[ -d "$rotate_confdir" ]] || fail "[$rotate_confdir] is not a dir - is logrotate installed?"

    if [[ -f "$LOGROTATE_CONF" && -s "$LOGROTATE_CONF" ]]; then
        cat -- "$LOGROTATE_CONF" > "$target_conf"
    else
        cat > "$target_conf" <<EOF
$pattern {
                   rotate $rotate
                   $interval
                   size $size
                   copytruncate
                   compress
                   missingok
                   notifempty
}
EOF
    fi
}


NO_SEND_MAIL=true  # stop sending mails during startup/setup; allow other notifications
#printenv | sed 's/^\(\w\+\)=\(.*\)$/export \1="\2"/g' > /env_vars.sh || { echo -e "    ERROR: printenv failed" | tee -a "$LOG"; exit 1; }
#env | sed -r "s/'/\\\'/gm" | sed -r "s/^([^=]+=)(.*)\$/\1'\2'/gm" \ > /etc/environment
#declare -p | grep -Ev '\b(BASHOPTS|BASH_VERSINFO|EUID|PPID|SHELLOPTS|UID)=' > /container.env || { echo -e "    ERROR: printenv failed" | tee -a "$LOG"; exit 1; }
source /scripts_common.sh || { echo -e "    ERROR: failed to import /scripts_common.sh" >&2; exit 1; }

#chmod 600 /container.env || fail "chmod-ing /container.env failed w/ [$?]"

check_dependencies
validate_config_common -i
setup_crontab
install_ssh_key
setup_msmtp
setup_logrotate
unset NO_SEND_MAIL

exit 0

