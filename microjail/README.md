*microjail* is an alternative approach to *minijail*. Its advantage on *minijail* is that it don't rely on a base jail but directly on the host system/world. This to avoid:

* symlinks overhead
* to maintain one more world (this base jail)

Before use:

1. create a symlink to ../minijail/mounted.c (`cd path/to/microjail` then `ln -s ../minijail/mounted.c .`)
2. download base.txz (the FreeBSD base set) to this directory
3. configure /etc/jail.conf as follows:

```
mount.devfs;
path = "/var/jails/$name";

exec.start +=
    "/bin/sh /etc/rc"
;

exec.stop +=
    "/bin/sh /etc/rc.shutdown"
;

exec.prestart =
    "/sbin/mount -t nullfs -o ro /bin ${path}/bin",
    "/sbin/mount -t nullfs -o ro,nosuid,noexec /boot ${path}/boot",
    "/sbin/mount -t nullfs -o ro,nosuid /lib ${path}/lib",
    "/sbin/mount -t nullfs -o ro,nosuid /libexec ${path}/libexec",
    "/sbin/mount -t nullfs -o ro,nosuid /rescue ${path}/rescue",
    "/sbin/mount -t nullfs -o ro /sbin ${path}/sbin",
    "/sbin/mount -t nullfs -o ro /usr/bin ${path}/usr/bin",
    "/sbin/mount -t nullfs -o ro,nosuid,noexec /usr/include ${path}/usr/include",
    "/sbin/mount -t nullfs -o ro,nosuid /usr/lib ${path}/usr/lib",
    "/sbin/mount -t nullfs -o ro,nosuid /usr/lib32 ${path}/usr/lib32",
    "/sbin/mount -t nullfs -o ro,nosuid,noexec /usr/libdata ${path}/usr/libdata",
    "/sbin/mount -t nullfs -o ro /usr/libexec ${path}/usr/libexec",
    "/sbin/mount -t nullfs -o ro /usr/sbin ${path}/usr/sbin",
    #"/sbin/mount -t nullfs -o ro,nosuid,noexec /usr/src ${path}/usr/src",
    "/sbin/mount -t nullfs -o ro,nosuid,noexec /usr/ports ${path}/usr/ports",
    "/sbin/mount -t nullfs -o ro,nosuid,noexec /usr/share ${path}/usr/share"
;

exec.poststop =
    "/sbin/umount ${path}/bin",
    "/sbin/umount ${path}/boot",
    "/sbin/umount ${path}/lib",
    "/sbin/umount ${path}/libexec",
    "/sbin/umount ${path}/rescue",
    "/sbin/umount ${path}/sbin",
    "/sbin/umount ${path}/usr/bin",
    "/sbin/umount ${path}/usr/include",
    "/sbin/umount ${path}/usr/lib",
    "/sbin/umount ${path}/usr/lib32",
    "/sbin/umount ${path}/usr/libdata",
    "/sbin/umount ${path}/usr/libexec",
    "/sbin/umount ${path}/usr/sbin",
    #"/sbin/umount ${path}/usr/src",
    "/sbin/umount ${path}/usr/ports",
    "/sbin/umount ${path}/usr/share"
;

myjail {
    jid = 1;
}
```

Use:

Same as *minijail*, see its README without the options `--update` (`--upgrade`) and `--source` (`-s`)/`--binary` (`-b`)
