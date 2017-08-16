#!/bin/sh -e

readonly __DIR__=`cd $(dirname -- "${0}"); pwd -P`

. ${__DIR__}/../_routines.inc.sh

readonly MOUNTPOINT="/mnt"

readonly LABEL__="freebsd-root"
readonly LABEL_ETC="freebsd-etc"
readonly LABEL_BOOT="freebsd-boot"
readonly LABEL_ROOT="freebsd-home-root"
readonly LABEL_USR_HOME="freebsd-home"
readonly LABEL_USR_LOCAL_ETC="freebsd-usr-local-etc"
readonly LABEL_VAR="freebsd-var"

readonly MOUNPOINTS_UFS="etc root usr/home usr/local/etc var"
readonly MOUNTPOINTS_MISC="dev proc tmp"

readonly POOL_NAME="zroot"

usage()
{
	# TODO
	exit 2
}

do_setup()
{
	# TODO: ZFS support
	# NOTE: list of disks : sysctl kern.disks
	# NOTE: size of a disk in bytes: diskinfo "${DEVICE}" | cut -wf 3

	gpart destroy -F "${DEVICE}"
	gpart create -s gpt "${DEVICE}"
	gpart add -t freebsd-boot -l gpboot -b 40 -s 512K "${DEVICE}"
	#if ! $ZFS; then
		gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 1 "${DEVICE}"
	#else
		#gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 "${DEVICE}"
	#fi
	gpart add -t efi -l "${LABEL_BOOT}" -a4k -s492k "${DEVICE}"
	newfs_msdos "/dev/${DEVICE}p2"
	mount -t msdosfs "/dev/${DEVICE}p2" "${MOUNTPOINT}"
	mkdir -p "${MOUNTPOINT}/EFI/BOOT"
	cp /boot/boot1.efi "${MOUNTPOINT}/EFI/BOOT/"
	umount "${MOUNTPOINT}"
	#if ! $ZFS; then
		gpart add -t freebsd-ufs -l "${LABEL__}" -b 1M -s 2G "${DEVICE}"
		# swap: 2 * RAM (optionnal - you don't want one on a thumb drive or memory card)
		#gpart add -t freebsd-swap -l "${LABEL_SWAP}" -s `echo -e "define ceil(x){\nauto os,xx;x=-x;os=scale;scale=0;xx=x/1;if(xx>x)xx=xx--;scale=os;return(-xx);};2*2^ceil(l(`sysctl -n hw.physmem`) / l(2))" | bc -l` "${DEVICE}"
		# TODO: /tmp on disk instead of ram as option?
		gpart add -t freebsd-ufs -l "${LABEL_ETC}" -s 8M "${DEVICE}"
		gpart add -t freebsd-ufs -l "${LABEL_ROOT}" -s 16M "${DEVICE}"
		gpart add -t freebsd-ufs -l "${LABEL_USR_LOCAL_ETC}" -s 16M "${DEVICE}"
		gpart add -t freebsd-ufs -l "${LABEL_VAR}" -s 2G "${DEVICE}"
		gpart add -t freebsd-ufs -l "${LABEL_USR_HOME}" -a 1M "${DEVICE}"

		for mntpoint in / $MOUNPOINTS_UFS; do
			LABEL=`echo "${mntpoint}" | tr '/a-z' '_A-Z'`
			eval "newfs -U \"/dev/gpt/\${LABEL_$LABEL}\""
		done
		# mount /
		mount -t ufs "/dev/gpt/${LABEL__}" "${MOUNTPOINT}"
		# create submontpoints directories
		for mntpoint in $MOUNTPOINTS_MISC $MOUNPOINTS_UFS; do
			mkdir -p "${MOUNTPOINT}/${mntpoint}"
		done
		# mount submounpoints
		for mntpoint in $MOUNPOINTS_UFS; do
			mount -t ufs "/dev/gpt/${TODO}" "${MOUNTPOINT}/${mntpoint}"
		done
	#else
		# TODO: swap (same as above)
		#gpart add -t freebsd-zfs -l "${LABEL_ZFS}" -a 1M "${DEVICE}"
		#kldload opensolaris.ko zfs.ko
		#zpool create "${POOL_NAME}" "/dev/gpt/${LABEL_ZFS}"
		#zpool set "bootfs=${POOL_NAME}" "${POOL_NAME}"
		# TODO: tmp (same as above)
		#zfs set atime=off "${POOL_NAME}"
		#zfs create -o atime=off -o exec=off -o setuid=off "${POOL_NAME}/etc"
		#zfs create -o atime=off -o exec=off -o setuid=off "${POOL_NAME}/usr/local/etc"
		#zfs create -o atime=off -o setuid=off "${POOL_NAME}/root"
		#zfs create -o atime=off -o exec=off -o setuid=off "${POOL_NAME}/var"
		#zfs create -o atime=off -o setuid=off "${POOL_NAME}/usr/home"
		# TODO: zfs set readonly=on "${POOL_NAME}"
	#fi

	mount -t devfs . "${MOUNTPOINT}/dev"
	mount -t procfs . "${MOUNTPOINT}/proc"
	# TODO: mount -t tmpfs ... "${MOUNTPOINT}/tmp" ?
	make DESTDIR="${MOUNTPOINT}" -C /usr/src installkernel installworld distrib-dirs distribution
	chroot "${MOUNTPOINT}" /bin/sh <<-EOC
		chsh -s /bin/tcsh

		# /etc/fstab
		# /
		echo '/dev/gpt/${LABEL__} / ufs ro,noatime 1 1' >> /etc/fstab
		# TODO: 1 1 ?
		#if ! $ZFS; then
			echo '/dev/gpt/${LABEL_ETC} /etc ufs rw,noatime,noexec,nosuid 2 2' >> /etc/fstab
			echo '/dev/gpt/${LABEL_USR_LOCAL_ETC} /usr/local/etc ufs rw,noatime,noexec,nosuid 2 2' >> /etc/fstab
			echo '/dev/gpt/${LABEL_ROOT} /root ufs rw,noatime,nosuid 2 2' >> /etc/fstab
			echo '/dev/gpt/${LABEL_VAR} /var ufs rw,noatime,noexec,nosuid 2 2' >> /etc/fstab
			echo '/dev/gpt/${LABEL_USR_HOME} /usr/home ufs rw,noatime,nosuid 2 2' >> /etc/fstab
		#else
			#echo 'zfs_enable="YES"' >> etc/rc.conf
			#echo 'zfs_load="YES"' >> /boot/loader.conf
			#echo "vfs.root.mountfrom=\"zfs:${POOL_NAME}\"" >> /boot/loader.conf
		#fi
		# tmpfs for /tmp
		echo 'tmpfs /tmp tmpfs rw,mode=01777,noexec,nosuid 0 0' >> /etc/fstab
		# symlink /var/tmp to /tmp
		rm -fr /var/tmp
		ln -s /tmp /var/tmp
	EOC
	# umount submounpoints (in reverse order)
	for mntpoint in $(echo "$MOUNTPOINTS_MISC $MOUNPOINTS_UFS" | awk '{do printf "%s"(NF>1?FS:RS),$NF;while(--NF)}'); do
		umount "${MOUNTPOINT}/${mntpoint}" # TODO: zfs umount ?
	done
	# umount /
	umount "${MOUNTPOINT}"
}

do_upgrade()
{
	# TODO: rebuild world (+ mergemaster) + kernel
	# et les installer je ne sais où ?
}

do_deploy()
{
	# TODO: rsync vs zfs send/receive
}
