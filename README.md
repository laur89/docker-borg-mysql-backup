# borg-mysql-backup

This image is for backing up mysql or postgres dumps to local and/or remote
[borg](https://github.com/borgbackup/borg) repos.
Other files&dirs may be included in the backup, and database dumps can be excluded
altogether.

The container features `backup`, `restore`, `list`, `delete` and `notif-test` scripts that can
either be ran as one-off jobs or by cron - latter being the preferred method for `backup`.

For cron and/or remote borg usage, you also need to mount container configuration
at `/config`, containing crontab file (named `crontab`) and/or ssh key (named `id_rsa`).
Note ssh key, when provided, is expected to be passwordless.

Both remote & local repositories need to be
[initialised](https://borgbackup.readthedocs.io/en/stable/usage/init.html) manually
beforehand. You still may use this image to do so - just start a container in an
interactive mode and use the shell.

In case some containers need to be stopped for the backup (eg to ensure there won't
be any mismatch between data and database), you can specify those container names to
the `backup` script (see below). Note that this requires mounting docker socket with
`-v /var/run/docker.sock:/var/run/docker.sock`, but keep in mind it has security
implications - borg-mysql-backup will have essentially root permissions on the host.

To synchronize container tz with that of host's, then also add following mount:
`-v /etc/localtime:/etc/localtime:ro`. You'll likely want to do this for cron times
to match the host time.

It's possible to get notified of _any_ errors that occur during backups.
Currently supported notification methods are

- sending mail via SMTP
- sending [pushover](https://pushover.net/) notifications
- posting to [healthchecks.io](https://healthchecks.io/) `/fail` endpoint (see
note on healtchchecks in following paragraphs)

If you wish to provide your own msmtprc config file instead of defining `SMTP_*` env
vars, create it at the `/config` mount, named `msmtprc`.

Dead man's switch support is provided via healthchecks; healthcheck provider will
always be pinged when backup job runs - regardless of the outcome; ie it's only
there to monitor the scheduled backup is being executed, not that it succeeds.
For error notifications you still need to configure notifications (see `ERR_NOTIF`).
Note if you've configured healthchecks.io as your healthcheck provider, then you
may also use it for error notifications (see above). 

Additionally, following bindings are _strongly_ recommended:
`-v /host/borg-conf/.borg/cache:/root/.cache/borg`
`-v /host/borg-conf/.borg/config:/root/.config/borg`
You might want to change where borg conf & cache are located via
`BORG_CONFIG_DIR` & `BORG_CACHE_DIR` env vars as described [in docs](https://borgbackup.readthedocs.io/en/stable/usage/general.html?highlight=BORG_CACHE_DIR#environment-variables)

You might also wish to expose the logs:
`-v /host/borg-conf/logs:/var/log`

Every time any config is changed in `/config`, container needs to be restarted for
the changes to get picked up.


## Repo init examples:

### For rsync.net (or other remote location):

Running command from your computer: `BORG_REMOTE_PATH=borg14 borg init
--encryption=repokey 12345@ch-s010.rsync.net:dir/path`

### Local repo:

`borg init --encryption=repokey /path/to/local/repo`


## Be careful

**Please make sure to verify you're able to access your offsite (ie remote)
backups without your local repo/config! You don't want to find yourself unable
to access remote backups in case local configuration/repository gets nuked.**
Refer to [brog docs](https://borgbackup.readthedocs.io/en/stable/quickstart.html#repository-encryption)
as to how and what to back up, depending on the encryption mode used.

You should be able to access your offsite backups from _any_ system.

Remember - "Untested backup is no backup at all"


## Container Parameters

Note all `BORG_`-prefixed env vars are [borg native ones](https://borgbackup.readthedocs.io/en/stable/usage/general.html#environment-variables).

    MYSQL_HOST              the host/ip of your mysql database
    MYSQL_PORT              the port number of your mysql database
    MYSQL_USER              the username of your mysql database
    MYSQL_PASS              the password of your mysql database
    MYSQL_FAIL_FATAL        whether unsuccessful db dump should abort backup,
                            defaults to 'true';
    MYSQL_EXTRA_OPTS        the extra options to pass to 'mariadb-dump' command; optional

    POSTGRES_HOST           the host/ip of your postgresql database
    POSTGRES_PORT           the port number of your postgresql database
    POSTGRES_USER           the username of your postgresql database
    POSTGRES_PASS           the password of your postgresql database
    POSTGRES_FAIL_FATAL     whether unsuccessful db dump should abort backup,
                            defaults to 'true';
    POSTGRES_EXTRA_OPTS     the extra options to pass to 'pg_dump' or 'pg_dumpall' commands; optional
      mysql & postgres env variables are only required if you intend to back up databases


    HOST_ID                 host identifier to include in the borg archive name
    REMOTE                  remote connection - user & host with optional port; eg for
                            rsync.net it'd be something like '12345@ch-s010.rsync.net[:1234]'
                            optional - can be omitted when only backing up to local
                            borg repo, or if providing value via script
    REMOTE_REPO             path to repo on remote host, eg '/backup/repo'
                            optional - can be omitted when only backing up to local
                            borg repo, or if providing value via script
    LOCAL_REPO              path to local borg repo; optional - can be omitted
                            when only backing up to remote borg repo, or if
                            providing value via script
    COMMON_OPTS             additional borg params to be used with _all_ borg
                            commands. see
                            https://borgbackup.readthedocs.io/en/stable/usage/general.html#common-options
    CREATE_OPTS             additional borg params to the borg backup command
                            (for both local & remote borg commands); optional
    LOCAL_CREATE_OPTS       additional borg params for local borg backup command; optional
    REMOTE_CREATE_OPTS      additional borg params for remote borg backup command; optional
    BORG_REMOTE_PATH        remote borg executable path; eg with rsync.net
                            you'd  want to use value 'borg14'; optional
    BORG_PASSPHRASE         borg repo password
    PRUNE_OPTS              options for borg prune (both local and remote); not 
                            required when it's defined by backup script -P param
                            (which overrides this container env var)
    LOCAL_PRUNE_OPTS        prune options for local borg repo; overrides PRUNE_OPTS;
    REMOTE_PRUNE_OPTS       prune options for remote borg repo; overrides PRUNE_OPTS;
    SCRIPT_FAIL_FATAL       whether failure of custom script execution should abort
                            backup, defaults to 'true';

    HC_URL                  healthcheck url to ping upon script completion; may contain
                            {id} placeholder to define general template and provide the
                            unique/id value via backup script option HC_ID
    ERR_NOTIF               comma separated error notification methods; supported values
                            are {mail,pushover,healthchecksio}; optional
    NOTIF_SUBJECT           notifications' subject/title; defaults to '{p}: backup error on {h}'
    ADD_NOTIF_TAIL          whether all error messages should contain the
                            trailing block of additional info; defaults to 'true';
    NOTIF_TAIL_MSG          replaces the default contents of trailing error
                            notifications; only in effect if ADD_NOTIF_TAIL=true

      following {MAIL,SMTP}_* params are only used if ERR_NOTIF value contains 'mail';
      also note all SMTP_* env vars besides SMTP_ACCOUNT are ignored if you've
      provided smtp config file at /config/msmtprc
    MAIL_TO                 address to send notifications to
    MAIL_FROM               name of the notification sender; defaults to '{h} backup reporter'
    SMTP_HOST               smtp server host; only required if MSMTPRC file not provided
    SMTP_USER               login user to the smtp account; only required if MSMTPRC file not provided
    SMTP_PASS               login password to the smtp account; only required if MSMTPRC file not provided
    SMTP_PORT               smtp server port; defaults to 587
    SMTP_AUTH               defaults to 'on'
    SMTP_TLS                defaults to 'on'
    SMTP_STARTTLS           defaults to 'on'
    SMTP_ACCOUNT            smtp account to use for sending mail;
                            makes sense only if you've provided your own MSMTPRC
                            config at /config/msmtprc that defines multiple accounts

      following params are only used/required if ERR_NOTIF value contains 'pushover':
    PUSHOVER_USER_KEY       your pushover account key
    PUSHOVER_APP_TOKEN      token of a registered app to send notifications from
    PUSHOVER_PRIORITY       defaults to 1
    PUSHOVER_RETRY          only in use if priority=2; defaults to 60
    PUSHOVER_EXPIRE         only in use if priority=2; defaults to 3600

## Script usage

Container incorporates `backup`, `compact`, `restore`, `list`, `delete`,
`check` and `notif-test` scripts.

### backup.sh

`backup` script is mostly intended to be ran by cron, but can also be executed
as a one-off command for a single backup.

    usage: backup [-h] [-d MYSQL_DBS] [-g POSTGRES_DBS] [-c CONTAINERS] [-rl]
                  [-P PRUNE_OPTS] [-B|-Z CREATE_OPTS] [-E EXCLUDE_PATHS]
                  [-L LOCAL_REPO] [-e ERR_NOTIF] [-A SMTP_ACCOUNT] [-D MYSQL_FAIL_FATAL]
                  [-G POSTGRES_FAIL_FATAL] [-S SCRIPT_FAIL_FATAL] [-R REMOTE]
                  [-T REMOTE_REPO] [-C] [-H HC_ID] -p PREFIX  [NODES_TO_BACK_UP...]
    
    Create new archive
    
    arguments:
      -h                      show help and exit
      -d MYSQL_DBS            comma-separated mysql database names to back up; use value of
                              __all__ to back up all dbs on the server
      -g POSTGRES_DBS         comma-separated postgresql database names to back up; use value of
                              __all__ to back up all dbs on the server
      -c CONTAINERS           comma-separated container names to stop for the backup process;
                              requires mounting the docker socket (-v /var/run/docker.sock:/var/run/docker.sock);
                              note containers will be stopped in given order; after backup
                              completion, containers are started in reverse order; only containers
                              that were stopped by the script will be re-started afterwards
      -r                      only back to remote borg repo (remote-only)
      -l                      only back to local borg repo (local-only)
      -P PRUNE_OPTS           overrides container env var of same name; only required when
                              container var is not defined or needs to be overridden;
      -1 LOCAL_PRUNE_OPTS     prune options for local borg repo; overrides PRUNE_OPTS (& -P);
      -2 REMOTE_PRUNE_OPTS    prune options for remote borg repo; overrides PRUNE_OPTS (& -P);
      -B CREATE_OPTS          additional borg params; note it doesn't overwrite the
                              env var of same name, but extends it;
      -Z CREATE_OPTS          additional borg params; note it _overrides_ the env
                              var of same name;
      -E EXCLUDE_PATHS        comma-separated paths to exclude from backup; 
                              [-E '/p1,/p2'] would be equivalent to [-B '-e /p1 -e /p2']
      -L LOCAL_REPO           overrides container env var of same name;
      -e ERR_NOTIF            overrides container env var of same name;
      -A SMTP_ACCOUNT         overrides container env var of same name;
      -D MYSQL_FAIL_FATAL     overrides container env var of same name;
      -G POSTGRES_FAIL_FATAL  overrides container env var of same name;
      -S SCRIPT_FAIL_FATAL    overrides container env var of same name;
      -R REMOTE               overrides container env var of same name;
      -T REMOTE_REPO          overrides container env var of same name;
      -C                      run `compact` command against repo after backup/prune;
      -H HC_ID                the unique/id part of healthcheck url, replacing the '{id}'
                              placeholder in HC_URL; may also provide new full url to call
                              instead, overriding the env var HC_URL
      -p PREFIX               borg archive name prefix. note that the full archive name already
                              contains HOST_ID env var and timestamp, so omit those.
      NODES_TO_BACK_UP...     last arguments to backup.sh are files&directories to be
                              included in the backup

#### Usage examples

##### Back up App1 & App2 mysql databases and app1's data directory /app1-data daily at 05:15 to both local and remote borg repos

    docker run -d \
        -e MYSQL_HOST=mysql.host \
        -e MYSQL_PORT=27017 \
        -e MYSQL_USER=admin \
        -e MYSQL_PASS=password \
        -e HOST_ID=hostname-to-use-in-archive-prefix \
        -e REMOTE=remoteuser@server.com \
        -e REMOTE_REPO=repo/location \
        -e LOCAL_REPO=/backup/repo \
        -e CREATE_OPTS='--compression zlib,5 --lock-wait 60' \
        -e BORG_PASSPHRASE=borgrepopassword \
        -e PRUNE_OPTS='--keep-daily=7 --keep-weekly=4' \
        -v /etc/localtime:/etc/localtime:ro \
        -v /host/backup:/backup \
        -v /host/borg-conf:/config:ro \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
        -v /app1-data-on-host:/app1-data:ro \
           layr/borg-mysql-backup

`/config/crontab` contents:

    15 05 * * *   /backup.sh -p app1-app2 -d "App1,App2" /app1-data 

##### Back up all postgres databases daily at 04:10 and 16:10 to local&remote borg repos, stopping containers myapp1 & myapp2 for the process

    docker run -d \
        -e POSTGRES_HOST=postgre.host \
        -e POSTGRES_PORT=5432 \
        -e POSTGRES_USER=postgres \
        -e POSTGRES_PASS=password \
        -e HOST_ID=hostname-to-use-in-archive-prefix \
        -e REMOTE=remoteuser@server.com \
        -e REMOTE_REPO=repo/location \
        -e LOCAL_REPO=/backup/repo \
        -e BORG_PASSPHRASE=borgrepopassword \
        -e PRUNE_OPTS='--keep-daily=7 --keep-weekly=4' \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /etc/localtime:/etc/localtime:ro \
        -v /host/backup:/backup \
        -v /host/borg-conf:/config:ro \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
           layr/borg-mysql-backup

`/config/crontab` contents:

    10 04,16 * * *   /backup.sh -p myapp-prefix -g __all__ -c "myapp1,myapp2"

##### Back up directories /app1 & /app2 every 6 hours to local borg repo (ie remote is excluded)

    docker run -d \
        -e HOST_ID=hostname-to-use-in-archive-prefix \
        -e LOCAL_REPO=/backup/repo \
        -e BORG_PASSPHRASE=borgrepopassword \
        -e PRUNE_OPTS='--keep-daily=7 --keep-weekly=4' \
        -e HC_URL='https://hc-ping.com/{id}' \
        -v /host/backup:/backup \
        -v /host/borg-conf:/config:ro \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
        -v /app1:/app1:ro \
        -v /app2:/app2:ro \
           layr/borg-mysql-backup

`/config/crontab` contents:

    0 */6 * * *   /backup.sh -l -p my_app_prefix -H eb095278-f28d-448d-87fb-7b75c171a6aa /app1 /app2

Note we didn't need to define mysql- or remote borg repo related docker env vars.
Also there's no need to have ssh key in `/config`, as we're not connecting to a remote server.
Additionally, there was no need to mount `/etc/localtime`, as cron doesn't
define absolute time, but simply an interval.
Note also how we define the healthcheck url HC_URL template, whose {id} placeholder
is replaced by -H value provided by backup.sh

##### Same as above, but report errors via mail

    Use same docker command as above, with following env vars added:

        -e ERR_NOTIF=mail \
        -e MAIL_TO=receiver@example.com \
        -e NOTIF_SUBJECT='{i} backup error' \
        -e SMTP_HOST='smtp.gmail.com' \
        -e SMTP_USER='your.google.username' \
        -e SMTP_PASS='your-google-app-password-you-created-for-this' \

Same as the example before, but we've also opted to get notified of any backup
errors via email.

##### Back up directory /emby once to remote borg repo (ie local is excluded)

    docker run -it --rm \
        -e HOST_ID=hostname-to-use-in-archive-prefix \
        -e REMOTE=remoteuser@server.com \
        -e REMOTE_REPO=repo/location \
        -e BORG_PASSPHRASE=borgrepopassword \
        -e PRUNE_OPTS='--keep-daily=7 --keep-weekly=4' \
        -e HC_URL='https://hc-ping.com/eb095278-f28d-448d-87fb-7b75c171a6aa' \
        -v /host/borg-conf:/config:ro \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
        -v /host/emby/dir:/emby:ro \
           layr/borg-mysql-backup backup.sh -r -p emby /emby 

Note there's no need to have a crontab file in `/config`, as we're executing this
command just once, after which container exits and is removed (ie we're not using
scheduled backups). Also note there's no `/backup` mount for local borg repo as
we're operating only against the remote borg repo.
Note also the healtcheck url that will get pinged.

### restore.sh

`restore` script should be executed directly with docker in interactive mode. All data
will be extracted into `/$RESTORE_DIR/restored-{archive_name}`.

Note none of the data is
copied/moved automatically - user is expected to carry this operation out on their own.
Only db will be restored from a dump, given the option is provided to the script.

    usage: restore [-h] [-d] [-g] [-c CONTAINERS] [-rl] [-B BORG_OPTS] [-L LOCAL_REPO]
                   [-R REMOTE] [-T REMOTE_REPO] -O RESTORE_DIR -a ARCHIVE_NAME
    
    Restore data from borg archive
    
    arguments:
      -h                      show help and exit
      -d                      automatically restore mysql database from dumped file; if this
                              option is provided and archive doesn't contain exactly one dump-file,
                              it's an error; be careful, this is a destructive operation!
      -g                      automatically restore postgresql database from dumped file; if this
                              option is provided and archive contains no sql dumps, it's an error;
                              be careful, this is a destructive operation!
      -c CONTAINERS           comma-separated container names to stop before the restore begins;
                              note they won't be started afterwards, as there might be need
                              to restore other data (only sql dumps are restored automatically);
                              requires mounting the docker socket (-v /var/run/docker.sock:/var/run/docker.sock)
      -r                      restore from remote borg repo
      -l                      restore from local borg repo
      -B BORG_OPTS            additional borg params to pass to extract command
      -L LOCAL_REPO           overrides container env var of same name
      -R REMOTE               overrides container env var of same name
      -T REMOTE_REPO          overrides container env var of same name
      -O RESTORE_DIR          path to directory where archive will get extracted to
      -a ARCHIVE_NAME         full name of the borg archive to extract data from

#### Usage examples

##### Restore archive from remote borg repo & restore mysql with restored dumpfile

    docker run -it --rm \
        -e MYSQL_HOST=mysql.host \
        -e MYSQL_PORT=27017 \
        -e MYSQL_USER=admin \
        -e MYSQL_PASS=password \
        -e REMOTE=remoteuser@server.com \
        -e REMOTE_REPO=repo/location \
        -e BORG_PASSPHRASE=borgrepopassword \
        -v /host/backup:/backup \
        -v /host/borg-conf:/config:ro \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
           layr/borg-mysql-backup restore.sh -r -d -O /backup -a my_prefix-HOSTNAME-2017-02-27-160159

##### Restore archive from local borg repo & stop container app1 beforehand

    docker run -it --rm \
        -e LOCAL_REPO=/backup/repo \
        -e BORG_PASSPHRASE=borgrepopassword \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /host/backup:/backup \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
           layr/borg-mysql-backup restore.sh -l -c app1 -O /backup -a my_prefix-HOSTNAME-2017-02-27-160159

Note there's no need to mount `/config`, as we're not using cron nor connecting to remote borg.
Also we're not providing mysql env vars, as script isn't invoked with `-d` option, meaning
db won't be automatically restored with the included .sql dumpfile (if there was one).

##### Restore archive from overridden local borg repo

    docker run -it --rm \
        -e LOCAL_REPO=/backup/repo \
        -v /host/backup:/backup \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
           layr/borg-mysql-backup restore.sh -l -L /backup/otherrepo -O /backup -a my_prefix-HOSTNAME-2017-02-27-160159

Data will be restored from a local borg repo `/backup/otherrepo` that overrides the 
env-var-configured value `/backup/repo`. Also note missing
env variable `BORG_PASSPHRASE`, which will be required to be typed in manually.

Note the `CREATE_OPTS`, `LOCAL_CREATE_OPTS`, `REMOTE_CREATE_OPTS` env
variables are not usable with `restore`.

### list.sh

`list` script is for listing archives in a borg repo or contents of an archive.

    usage: list [-h] [-rl] [-p ARCHIVE_PREFIX] [-B BORG_OPTS] [-L LOCAL_REPO]
             [-R REMOTE] [-T REMOTE_REPO] [-a ARCHIVE_NAME]
    
    List archives in a borg repository or contents of an archive
    
    arguments:
      -h                      show help and exit
      -r                      list remote borg repo
      -l                      list local borg repo
      -p ARCHIVE_PREFIX       list archives with given prefix; same as providing
                              [-B '--glob-archives ARCHIVE_PREFIX*']
      -B BORG_OPTS            additional borg params to pass to borg list command
      -L LOCAL_REPO           overrides container env var of same name
      -R REMOTE               overrides container env var of same name
      -T REMOTE_REPO          overrides container env var of same name
      -a ARCHIVE_NAME         full name of the borg archive whose contents to list

#### Usage examples

##### List the local repository contents

    docker run -it --rm \
        -e BORG_PASSPHRASE=borgrepopassword \
        -v /host/backup:/backup \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
           layr/borg-mysql-backup list.sh -l -L /backup/repo

##### List the remote repository contents

    docker run -it --rm \
        -e REMOTE=remoteuser@server.com \
        -e BORG_PASSPHRASE=borgrepopassword \
        -v /host/borg-conf:/config:ro \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
           layr/borg-mysql-backup list.sh -r -T repo/location -p my-prefix

Note the `CREATE_OPTS`, `LOCAL_CREATE_OPTS`, `REMOTE_CREATE_OPTS` env
variables are not usable with `list`.

### delete.sh

`delete` script is for deleting archives in a borg repo (or whole repo itself)

    usage: delete [-h] [-rl] [-p ARCHIVE_PREFIX] [-a ARCHIVE] [-B BORG_OPTS]
             [-L LOCAL_REPO] [-R REMOTE] [-T REMOTE_REPO]

    Delete whole borg repository or archives in it

    arguments:
      -h                      show help and exit
      -r                      only delete from remote borg repo (remote-only)
      -l                      only delete from local borg repo (local-only)
      -p ARCHIVE_PREFIX       delete archives with given prefix; same as providing
                              -B '--glob-archives ARCHIVE_PREFIX*'
      -a ARCHIVE              archive name to delete; -p & -a are mutually exclusive
      -B BORG_OPTS            additional borg params to pass to borg delete command
      -L LOCAL_REPO           overrides container env var of same name
      -R REMOTE               overrides container env var of same name
      -T REMOTE_REPO          overrides container env var of same name

#### Usage examples

##### Delete the local archives starting with 'prefix-HOST'

    docker run -it --rm \
        -e BORG_PASSPHRASE=borgrepopassword \
        -v /host/backup:/backup \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
           layr/borg-mysql-backup delete.sh -l -p 'prefix-HOST'

##### Delete a specific archive from local repository

    docker run -it --rm \
        -e BORG_PASSPHRASE=borgrepopassword \
        -v /host/backup:/backup \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
           layr/borg-mysql-backup delete.sh -l -a 'prefix-HOST-timestamp'

##### Delete the contents of a whole remote repository 

    docker run -it --rm \
        -e REMOTE=remoteuser@server.com \
        -e BORG_PASSPHRASE=borgrepopassword \
        -v /host/borg-conf:/config:ro \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
           layr/borg-mysql-backup delete.sh -r -T repo/location

Note the `CREATE_OPTS`, `LOCAL_CREATE_OPTS`, `REMOTE_CREATE_OPTS` env
variables are not usable with `delete`.

### compact.sh

`compact` script is for freeing repository space by compacting segments.

    usage: compact [-h] [-rl] [-B BORG_OPTS] [-L LOCAL_REPO]
                [-R REMOTE] [-T REMOTE_REPO]


    Compact borg repository

    arguments:
      -h                      show help and exit
      -r                      compact only remote borg repo (remote-only)
      -l                      compact only local borg repo (local-only)
      -B BORG_OPTS            additional borg params to pass to borg compact command
      -L LOCAL_REPO           overrides container env var of same name
      -R REMOTE               overrides container env var of same name
      -T REMOTE_REPO          overrides container env var of same name


#### Usage examples

##### Compact the local repository

    docker run -it --rm \
        -e BORG_PASSPHRASE=borgrepopassword \
        -v /host/backup:/backup \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
           layr/borg-mysql-backup compact.sh -l

### check.sh

`check` script is for verifying repo/archive integrity and optionally
attempting to fix any issues.

    usage: check [-h] [-rlF] [-p ARCHIVE_PREFIX] [-a ARCHIVE] [-B BORG_OPTS]
             [-L LOCAL_REPO] [-R REMOTE] [-T REMOTE_REPO]

    Verify the consistency of a repo and its archives.

    arguments:
      -h                      show help and exit
      -r                      only check remote borg repo (remote-only)
      -l                      only check local borg repo (local-only)
      -F                      attempt to repair/fix inconsistencies; dangerous, see docs!
      -p ARCHIVE_PREFIX       check archives with given prefix; same as providing
                              -B '--glob-archives ARCHIVE_PREFIX*'
      -a ARCHIVE              archive name to check; -p & -a are mutually exclusive
      -B BORG_OPTS            additional borg params to pass to borg check command
      -L LOCAL_REPO           overrides container env var of same name
      -R REMOTE               overrides container env var of same name
      -T REMOTE_REPO          overrides container env var of same name


#### Usage examples

##### Check/verify the local repository

    docker run -it --rm \
        -e BORG_PASSPHRASE=borgrepopassword \
        -v /host/backup:/backup \
        -v /host/borg-conf/.borg/cache:/root/.cache/borg \
        -v /host/borg-conf/.borg/config:/root/.config/borg \
        -v /host/borg-conf/logs:/var/log \
           layr/borg-mysql-backup check.sh -l

### notif-test.sh

`notif-test` script is for testing your configured notifications.

    usage: notif-test.sh [-hpIHsTFAmef]

    Test configured notifications. Running it will fire notification via each of
    the configured channels.

    arguments:
      -p ARCHIVE_PREFIX
      -I HOST_ID
      -H HC_ID (id to replace in healthcheck url)
      -s NOTIF_SUBJECT
      -T MAIL_TO
      -F MAIL_FROM
      -A SMTP_ACCOUNT
      -m MSG
      -e ERR_NOTIF
      -f                      marks the error as fatal (ie halting the script)

#### Usage examples

##### Simulate an error message to test all the notifications at once

    docker run -it --rm \
        -e PUSHOVER_USER_KEY='key' \
        -e PUSHOVER_APP_TOKEN='token' \
        -e MAIL_TO='your@mail.com' \
        -e SMTP_HOST='smtp.gmail.com' \
        -e SMTP_USER='your.google.username' \
        -e SMTP_PASS='your-google-app-password-you-created-for-this' \
        -e ERR_NOTIF='mail,pushover' \
        -e HOST_ID='our-hostname' \
           layr/borg-mysql-backup notif-test.sh -p 'my-prefix' [-f]


## See also/recommended
- [restic](https://github.com/restic/restic)
- [duplicacy](https://github.com/gilbertchen/duplicacy) - alternatives to borg. lock-free!
- [docker-db-backup](https://github.com/tiredofit/docker-db-backup) - similar service; supports multiple dbs
- [this blog](https://ifnull.org/articles/borgbackup_rsyncnet/) for borg setup
- [borgmatic](https://github.com/witten/borgmatic) - declarative borg config
- [this dockerised borgmatic](https://hub.docker.com/r/b3vis/borgmatic/) - provides same as this service, and more
- main offsite hostings: [rsync.net](https://www.rsync.net) & [BorgBase](https://www.borgbase.com/)
- [vorta](https://github.com/borgbase/vorta) - mac & linux desktop client; by borgbase
- for backups from k8s:
  - [velero](https://github.com/vmware-tanzu/velero)
  - [k8up](https://github.com/vshn/k8up) - based on restic
  - [stash](https://github.com/stashed/stash)
- [web interface for borg](https://github.com/borgbackup/borgweb/)

