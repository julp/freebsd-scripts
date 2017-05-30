zfsbackup: backup a ZFS file system to an external (local or remote) disk/pool

Settings to define in /usr/local/etc/zfsbackup.conf:
* LOCAL_POOL_NAME (default: try to guess it by running `zfs get -H -o value name / | cut -d / -f 1`): the name of the pool to send/backup
* REMOTE_POOL_NAME (default: 'backup'): the name of the pool which receives the backup
* REMOTE_HOST (default: ''): name of the remote host (keep empty if on the same host)
* REMOTE_USER (default: ''): name of the remote user name (if you need to explicit one)

Important notes:
* do **NOT** forget to set *altroot* property on zpool creation or, at least, when you (re)import it (if your backup disk is unplugged) to be sure to not replace some current mountpoints by the one of your backup
* be sure to `zfs set readonly=on` on root's backup zpool right after creating it

If you (un)plug your backup disk, you first need to `zfs import` it and `zfs export` it after finishing the backup.
