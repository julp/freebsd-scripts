Build a FreeBSD system on a host and deploy it, hardened, to another.

# Hardened

Mountpoints are:

* / (ro)
* /var (rw, nosuid, noexec)
* /root (rw)
* /etc (rw, nosuid, noexec)
* /usr/local/etc (rw, nosuid, noexec)
* /usr/home (rw)
* /proc (procfs)
* /dev (devfs)
* /tmp (tmpfs)

kern.securelevel = 3

# Deployment (install and upgrade)

The remote host needs to boot an in-memory FreeBSD system with SSH running to install or upgrade it.

This can be achieved with PXE or a live system.

(on OVH, use a FreeBSD system as rescue and boot on it)

# Goals

* consequently improve security
* reduce downtime in case of (re)installation
* almost reproducible: deploy a same FreeBSD base system to several hosts

Downsides:

* difficult to handle multiple architectures
* a "dedicated" machine is required for building and/or as reference
