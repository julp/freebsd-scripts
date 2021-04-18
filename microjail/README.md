*microjail* is a script to setup minimalist jails by mounting read-only most of their base system from the host with nullfs

Configure /etc/jail.conf as follows:

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

Usage:

* Create a jail: `microjail.sh --install foo`
* Drop a jail: `microjail.sh --delete foo`
* Start the *foo* jail: `microjail.sh --start foo`
* Stop the *foo* jail: `microjail.sh --stop foo`
* Get a root shell to *foo* jail: `microjail.sh --shell foo`

To apply the patch to prepend commands (operator `[=`) in jail.conf:
```
# svn
svnlite patch /.../freebsd-scripts/microjail/usr.sbin_jail_11.2RELEASE.diff
# git
git apply /.../freebsd-scripts/microjail/usr.sbin_jail_13.0RELEASE.diff

# then
make -C /usr/src/usr.sbin/jail
make -C /usr/src/usr.sbin/jail install
```
