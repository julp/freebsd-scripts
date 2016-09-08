#!/bin/sh

set -e

readonly __DIR__=`cd $(dirname "${0}"); pwd -P`

. ${__DIR__}/../_routines.inc.sh

readonly LABEL_BOOT="gpefiboot"
readonly LABEL_ROOT="freebsd-root"

usage()
{
	echo "Usage: `basename $0` -d DEVICE -m MOUNPOINT ACTION"
	echo ''
	echo '-d DEVICE, --device=DEVICE           : the name of the device to use as support for the live system (eg: da0)'
	echo '-m MOUNPOINT, --mountpoint=MOUNPOINT : the name of the directory to use as mountpoint (eg: /mnt)'
	echo ''
	echo "ACTION is one of:"
	echo '-c, --create  : create a live system on the usb stick which will be fully erased (implies having FreeBSD sources installed into /usr/src)'
	echo '-s, --shell   : open a chrooted shell into the live system on the usb stick'
	echo '-u, --upgrade : upgrade a live system (implies having FreeBSD sources installed into /usr/src)'
	echo ''
	exit 2
}

_mount()
{
# 	if [ ! -d "${MOUNTPOINT}" ]; then
# 		err "${MOUNTPOINT} is not a directory"
# 		exit 1
# 	fi
	mount -t ufs "/dev/${DEVICE}p3" "${MOUNTPOINT}" # TODO: use label (/dev/gpt/freebsd-root) instead of /dev/da0p3?
}

_rebuild_sources_if_needed()
{
	make -C /usr/src -j$((`sysctl -n hw.ncpu`+1)) buildworld NO_CLEAN=YES
	make -C /usr/src buildkernel NO_CLEAN=YES # TODO: choose KERNCONF?
}

do_unmount()
{
	unmount "${MOUNTPOINT}"
}

# NOTE: usb stick is mounted but not unmounted
do_create()
{
	# TODO: ask for confirmation
	gpart destroy -F "${DEVICE}"
	gpart create -s gpt "${DEVICE}"
	gpart add -t freebsd-boot -l gpboot -b 40 -s 512K "${DEVICE}"
	gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 1 "${DEVICE}"
	gpart add -t efi -l "${LABEL_BOOT}" -a4k -s492k "${DEVICE}"
	newfs_msdos "/dev/${DEVICE}p2"
	mount -t msdosfs "/dev/${DEVICE}p2" "${MOUNTPOINT}"
	mkdir -p "${MOUNTPOINT}/EFI/BOOT"
	cp /boot/boot1.efi "${MOUNTPOINT}/EFI/BOOT/"
	umount "${MOUNTPOINT}"
	gpart add -t freebsd-ufs -l "${LABEL_ROOT}" -b 1M "${DEVICE}"

	_rebuild_sources_if_needed
	_mount
	make DESTDIR="${MOUNTPOINT}" -C /usr/src installkernel installworld distrib-dirs distribution
	chroot "${MOUNTPOINT}" /bin/sh << EOC
		chsh -s /bin/tcsh

		# /etc/fstab
		# /
		echo '/dev/gpt/${LABEL_ROOT} / ufs rw,noatime 1 1' >> /etc/fstab
		# use tmpfs (24Mo) for /tmp
		echo 'tmpfs /tmp tmpfs rw,mode=01777,noexec,nosuid,size=24M 0 0' >> /etc/fstab
		# symlink /var/tmp to /tmp
		rm -fr /var/tmp
		ln -s /tmp /var/tmp
		# use a small (2Mo) tmpfs for /var/run
		rm -fr /var/run/*
		echo 'tmpfs /var/run tmpfs rw,mode=01777,noexec,nosuid,size=2M 0 0' >> /etc/fstab
		# use tmpfs (32Mo) for /var/log
		rm -fr /var/log/*
		echo 'tmpfs /var/log tmpfs rw,mode=01777,nosuid,size=32M 0 0' >> /etc/fstab

		tzsetup -s Europe/Paris

		# /etc/csh.login
		echo 'setenv LANG fr_FR.UTF-8' >> etc/csh.login
		echo 'setenv MM_CHARSET UTF-8' >> etc/csh.login

		# /boot/loader.conf
		echo 'kern.vty=vt' >> /boot/loader.conf

		# /etc/rc.conf
		(
			cat <<-"EOF"
				keymap="fr.acc"
				sshd_enable="YES"
				ntpdate_enable="YES"
				ntpdate_hosts="fr.pool.ntp.org"
				ifconfig_DEFAULT="SYNCDHCP" # TODO: ifconfig_DEFAULT is mentioned in rc.conf(5) but I didn't find it in /etc/{rc.d/*,defaults/rc.conf,*.rc}
			EOF
		) >> /etc/rc.conf
EOC
}

# NOTE: usb stick mounted but not unmounted
do_upgrade()
{
	_mount
	_rebuild_sources_if_needed
	mergemaster -p -D "${MOUNTPOINT}"
	make DESTDIR="${MOUNTPOINT}" -C /usr/src installkernel installworld
	mergemaster -iF --run-updates=always -D "${MOUNTPOINT}"
}

# NOTE: usb stick mounted but not unmounted
do_shell()
{
	_mount
	chroot "${MOUNTPOINT}" /bin/tcsh
}

newopts=""
for var in "$@" ; do
	case "$var" in
	--device)
		DEVICE="${var#--device=}"
		;;
	--mountpoint)
		MOUNTPOINT="${var#--mountpoint=}"
		;;
	--shell|--create|--upgrade|--unmount)
		ACTION="${var#--}"
		;;
	--*)
		usage
		;;
	*)
		newopts="${newopts} ${var}"
		;;
	esac
done

# getopt stuffs and arguments checking
set -- $newopts
unset var newopts

while getopts 'd:m:suc' COMMAND_LINE_ARGUMENT; do
	case "${COMMAND_LINE_ARGUMENT}" in
	d)
		DEVICE="${OPTARG}"
		;;
	m)
		MOUNTPOINT="${OPTARG}"
		;;
	s)
		ACTION="shell"
		;;
	u)
		ACTION="upgrade"
		;;
	c)
		ACTION="create"
		;;
	*)
		usage
		;;
	esac
done
shift $(( $OPTIND - 1 ))

# [ $# -eq 0 ] && usage
[ -z "${DEVICE}" -o -z "${MOUNTPOINT}" -o -z "${ACTION}" ] && usage

eval "do_${ACTION}" "$@"
