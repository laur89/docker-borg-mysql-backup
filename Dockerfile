FROM        phusion/baseimage
MAINTAINER Laur

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update
RUN apt-get install -y --no-install-recommends \
        mysql-client \
        borgbackup \
        wget
RUN update-locale LANG=C.UTF-8
RUN wget -qO- https://get.docker.com/ | sh

ADD scripts_common.sh /scripts_common.sh
ADD setup.sh /etc/my_init.d/setup.sh

# add to $PATH:
ADD backup.sh /usr/local/sbin/backup.sh
ADD restore.sh /usr/local/sbin/restore.sh
ADD list.sh /usr/local/sbin/list.sh

# add to root for simpler cron reference
ADD backup.sh /backup.sh

# Clean up for smaller image
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Baseimage init process
ENTRYPOINT ["/sbin/my_init"]

