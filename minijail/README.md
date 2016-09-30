Disclaimer:
* I decline all responsabilities of the usage made of this tool, there is no warranty

Minijail: create jails on top of a read-only filesystem in order to:
* minimize upgrade job
* minimize filesystem occupation

/ is a read only filesystem mounted from a base jail (named skel).
/private/ is the own (writable) space of the jail.

Few files are symlinked from this base jail to /private/ to make it work:
* /etc/motd
* /etc/login.conf{,.db}
* /etc/passwd
* /etc/master.passwd
* /etc/group
* /etc/spwd.db
* /etc/pwd.db
* /etc/host.conf
* /etc/rc.conf.d/ (use /etc/rc.conf from the base jail to share your parameters to all jails)
* /home
* /root
* /usr/local
* /tmp
* /var

Requirements: be root to run it

/etc/jail.conf:
```
exec.clean;
allow.nodying;
enforce_statfs = 2;

path = "/var/jails/$name";

exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown";

mount.nodevfs; # have to be done by hand else it fails, done too early
exec.prestart = "/sbin/mount -t nullfs -o ro /var/jails/skel $path";
exec.prestart += "/sbin/mount -t devfs . $path/dev";
exec.prestart += "/sbin/mount -t zfs zroot/$path $path/private";
exec.poststop = "/sbin/umount zroot$path";
exec.poststop += "/sbin/umount $path/dev";
exec.poststop += "/sbin/umount $path";

foo {
	jid = 1;
}

bar {
	jid = 2;
}
```

Usage:

1. create the base jail: `minijail.sh --install skel`
2. create a first real jail: `minijail.sh --install foo`

* Drop a jail: `minijail.sh --delete foo`
* Upgrade the base jail: `minijail.sh --update skel` (but you'll need to recompile/reinstall all your packages or to install misc/compat\<old major version>x in your jails when major version changes)
* Start the *foo* jail: `minijail.sh --start foo`
* Stop the *foo* jail: `minijail.sh --stop foo`
* Get a root shell to *foo* jail: `minijail.sh --shell foo`

FAQ:
* vipw doesn't work: use `vipw -d /private/etc` instead as vipw try to use /etc/ as temporary directory which is not writable
* /etc/ssh/sshd_config is not writable: for simple changes, add `-o` flags to `sshd_flags` in /etc/rc.conf else add etc/ssh/sshd_config to `SYMLINKED_FILES`
* how is it different from ezjail? It goes further as a larger part of the system is shared (starting by /etc/). Only files that can't be common (eg: accounts management) are "recreated" (an empty jail currently use around 236ko)
* I follow STABLE, I can't install from binaries? A release can be forced by defining an UNAME_r environment variable (for (t)csh, run: `env UNAME_r=10.3-RELEASE minijail.sh --install skel` ; remove `env` for (z|k|ba)?sh)
* passwd doesn't work. Still the same as vipw: passwd (common call pw_init(3) of libutil in fact) try to use /etc/ as which is not writable but passwd doesn't provide any option to change its default directory. To get it working as `passwd -t /private/etc`, you need to patch (before running any minijail.sh --create skel or --update skel) passwd and the pam_unix module this way:

```
patch -p0 < passwd_tmp_dir.patch
for path in usr.bin/passwd/ lib/libpam/ usr.bin/chpass/; do make -C "/usr/src/${path}" && make -C "/usr/src/${path}" install; done
```

(run `svnlite revert -R /usr/src` before `svnlite update /usr/src` then reapply the patch)

TODO:
* /etc/mail/certs needs to be writable (sendmail)?
