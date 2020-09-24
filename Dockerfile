FROM          alpine:3.12.0
MAINTAINER    Laur Aliste

ENV LANG=C.UTF-8

# check docker versions from https://download.docker.com/linux/static/stable/x86_64/

ENV DOCKER_VERSION=18.06.3-ce
ENV BORG_VERSION=1.1.13

ADD scripts/* /usr/local/sbin/

#ADD cron.template setup.sh entry.sh gad.sh   /
RUN apk add --no-cache \
        curl bash tar mysql-client ca-certificates && \
    curl -fsSL -o /usr/local/sbin/borg https://github.com/borgbackup/borg/releases/download/${BORG_VERSION}/borg-linux64 && \
    curl -fsSL -o /tmp/docker.tgz https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz && \
        tar xzvf /tmp/docker.tgz --strip 1 -C /usr/local/sbin docker/docker && \
    chown -R root:root /usr/local/sbin/ && \
    chmod -R 755 /usr/local/sbin/ && \
    ln -s /usr/local/sbin/setup.sh /setup.sh && \
    ln -s /usr/local/sbin/backup.sh /backup.sh && \
    ln -s /usr/local/sbin/scripts_common.sh /scripts_common.sh && \
    rm -rf /tmp/*

# TODO: prolly need to add these apk pacakges:
#openssh-keygen
#openssh-client

#CMD ["/entry.sh"]
ENTRYPOINT ["/usr/local/sbin/entry.sh"]

