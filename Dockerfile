FROM          alpine:3.12.0
MAINTAINER    Laur Aliste

ENV LANG=C.UTF-8 \
    BORG_VERSION=1.1.13-r1

ADD scripts/* /usr/local/sbin/

# note we install borg from community repo as borg doesn't release musl-linked binaries
RUN echo "@community http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories && \
    apk update && \
    apk add --no-cache \
        grep curl bash mysql-client ca-certificates tzdata msmtp \
        openssh-client \
        openssh-keygen \
        borgbackup@community=$BORG_VERSION \
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

