FROM phusion/baseimage:master-amd64
MAINTAINER Laur

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update
RUN apt-get install -y --no-install-recommends \
        mysql-client \
        wget
RUN update-locale LANG=C.UTF-8

RUN wget -q https://github.com/borgbackup/borg/releases/download/1.1.13/borg-linux64
RUN mv borg-linux64 /usr/local/sbin/borg
RUN chown root:root /usr/local/sbin/borg
RUN chmod 755 /usr/local/sbin/borg

RUN wget -qO- https://get.docker.com/ | sh

ADD scripts_common.sh /scripts_common.sh
ADD setup.sh /etc/my_init.d/setup.sh

# add to $PATH:
ADD backup.sh /usr/local/sbin/backup.sh
ADD restore.sh /usr/local/sbin/restore.sh
ADD list.sh /usr/local/sbin/list.sh

# link to / for simpler reference point for cron:
RUN ln -s /usr/local/sbin/backup.sh /backup.sh

# clean up for smaller image:
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# baseimage init process:
ENTRYPOINT ["/sbin/my_init"]

