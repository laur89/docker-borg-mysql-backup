FROM phusion/baseimage:master-amd64
MAINTAINER Laur

ENV DEBIAN_FRONTEND=noninteractive

ADD setup.sh /etc/my_init.d/setup.sh
ADD scripts/* /usr/local/sbin/

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        mysql-client \
        wget && \
    update-locale LANG=C.UTF-8 && \
    wget -q -O /usr/local/sbin/borg https://github.com/borgbackup/borg/releases/download/1.1.13/borg-linux64 && \
    chown -R root:root /usr/local/sbin/ && \
    chmod -R 755 /usr/local/sbin/ && \
    wget -qO- https://get.docker.com/ | sh && \
    ln -s /usr/local/sbin/backup.sh /backup.sh && \
    ln -s /usr/local/sbin/scripts_common.sh /scripts_common.sh && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# baseimage init process:
# note it's important to keep it as entrypoint not cmd, as that way we can
# still appropriately execute one-off commands;
ENTRYPOINT ["/sbin/my_init"]

