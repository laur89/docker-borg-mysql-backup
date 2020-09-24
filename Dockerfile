FROM phusion/baseimage:master-amd64
MAINTAINER Laur

# check docker versions from https://download.docker.com/linux/static/stable/x86_64/

ENV DOCKER_VERSION=18.06.3-ce
ENV BORG_VERSION=1.1.13

ENV DEBIAN_FRONTEND=noninteractive

# baseimage init process:
# note it's important to keep it as entrypoint not cmd, as that way we can
# still appropriately execute one-off commands;
ENTRYPOINT ["/sbin/my_init"]

ADD setup.sh /etc/my_init.d/setup.sh
ADD scripts/* /usr/local/sbin/

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        mysql-client \
        tar \
        curl && \
    update-locale LANG=C.UTF-8 && \
    curl -fsSL -o /usr/local/sbin/borg https://github.com/borgbackup/borg/releases/download/${BORG_VERSION}/borg-linux64 && \
    curl -fsSL -o /tmp/docker.tgz https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz && \
        tar xzvf /tmp/docker.tgz --strip 1 -C /usr/local/sbin docker/docker && \
    chown -R root:root /usr/local/sbin/ && \
    chmod -R 755 /usr/local/sbin/ && \
    ln -s /usr/local/sbin/backup.sh /backup.sh && \
    ln -s /usr/local/sbin/scripts_common.sh /scripts_common.sh && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

