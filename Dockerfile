FROM          alpine:3

ENV LANG=C.UTF-8 \
    BORG_VERSION=1.4.0-r0

ADD scripts/* /usr/local/sbin/

RUN apk update && \
    apk add --no-cache \
        grep curl bash mysql-client postgresql-client ca-certificates tzdata msmtp logrotate \
        openssh-client \
        openssh-keygen \
        borgbackup=$BORG_VERSION \
        docker-cli && \
    chown -R root:root /usr/local/sbin/ && \
    chmod -R 755 /usr/local/sbin/ && \
    mkdir /root/.ssh && \
    ln -s /usr/local/sbin/setup.sh /setup.sh && \
    ln -s /usr/local/sbin/backup.sh /backup.sh && \
    ln -s /usr/local/sbin/scripts_common.sh /scripts_common.sh && \
    rm -rf /var/cache/apk/* /tmp/*

VOLUME ["/root/.cache/borg", "/root/.config/borg"]
ENTRYPOINT ["/usr/local/sbin/entry.sh"]

