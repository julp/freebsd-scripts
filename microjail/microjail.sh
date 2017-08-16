#!/bin/sh -e

readonly __DIR__=`cd $(dirname -- "${0}"); pwd -P`

. ${__DIR__}/../_routines.inc.sh

readonly MOUNT_RO="/bin /sbin /usr/bin /usr/libexec /usr/sbin"
# NOTE: mmap'ing of libraries requires exec
readonly MOUNT_RO_NOSUID="/lib /libexec /rescue /usr/lib /usr/lib32"
readonly MOUNT_RO_NOSUID_NOEXEC="/boot /usr/include /usr/libdata /usr/share"

: ${JAILS_ROOT:='/var/jails'}

VERBOSE='false'

usage()
{
	echo "Usage: `basename $0` [ -v ] [ -s | -b ] ACTION name..."
	echo ''
	echo "ACTION is one of:"
	echo '--install			 : create a jail'
#	 echo '--update or --upgrade : upgrade a jail'
	echo '--delete			  : drop a jail'
	echo '--shell			   : acquire a root shell into the jail'
	echo '--start			   : start a jail (if not yet active)'
	echo '--stop				: stop a jail (currently running)'
#	 echo '--deploy=<host>	   : copy a jail on remote <host>'
	echo ''
	echo 'General options:'
	echo '-v, --verbose : display debug informations'
	exit 2
}

# do_install(name)
do_install()
{
	local ZPOOL_NAME=`zpool_name "${JAILS_ROOT}"`

	if [ -e "${JAILS_ROOT}/${1}" ]; then
		err "jail \"${1}\" already exists"
		exit 1
	fi

	if is_on_zfs "${JAILS_ROOT}"; then
		zfs create -p "${ZPOOL_NAME}${JAILS_ROOT}/${1}"
# 		zfs set mountpoint="${JAILS_ROOT}/${1}" "${ZPOOL_NAME}${JAILS_ROOT}/${1}"
	else
		mkdir -p "${JAILS_ROOT}/${1}"
	fi

	tar -xJf ${__DIR__}/base.txz --include=.cshrc --include=.profile --include='etc/*' --include='var/*' --include='root/*' --include='boot/*' -C "${JAILS_ROOT}/${1}"
	rm -fr "${JAILS_ROOT}/${1}/boot" # TODO: better, mount it (before tar) as tmpfs (and umount it here)?
	for path in ${MOUNT_RO} ${MOUNT_RO_NOSUID} ${MOUNT_RO_NOSUID_NOEXEC} /var /dev /etc /tmp; do
		mkdir -p "${JAILS_ROOT}/${1}${path}"
	done
	chmod 1777 "${JAILS_ROOT}/${1}/tmp"
	info "Populating etc/..."
	make -C /usr/src/etc distribution DESTDIR="${JAILS_ROOT}/${1}" > /dev/null 2>&1 # TODO: redirect stderr to some file?

	for path in ${MOUNT_RO}; do
		mount -t nullfs -o ro "${path}" "${JAILS_ROOT}/${1}${path}"
	done
	for path in ${MOUNT_RO_NOSUID}; do
		mount -t nullfs -o ro,nosuid "${path}" "${JAILS_ROOT}/${1}${path}"
	done
	for path in ${MOUNT_RO_NOSUID_NOEXEC}; do
		mount -t nullfs -o ro,nosuid,noexec "${path}" "${JAILS_ROOT}/${1}${path}"
	done

	chroot "${JAILS_ROOT}/${1}" /bin/sh << EOC
		# put here any command you'd need, paths are relative to the jail's root
		ln -sf dev/null kernel
		mkdir -p usr/ports
		chsh -s /bin/tcsh > /dev/null 2>&1
		# TODO: inherit current timezone or make it configurable
		tzsetup -s Europe/Paris
		touch etc/fstab
		(echo -n 'nameserver ' ; route get default | grep interface | cut -wf 3 | xargs ifconfig | grep inet | grep -v inet6 | cut -wf 3) > /etc/resolv.conf
		# /etc/host.conf
		echo 'hosts' >> etc/host.conf
		echo 'dns' >> etc/host.conf
		# /etc/rc.conf
		echo 'hostname="\$(/bin/hostname)"' >> etc/rc.conf
		#echo 'sendmail_enable="NO"' >> etc/rc.conf
		echo 'sendmail_cert_create="NO"' >> etc/rc.conf
		echo 'syslogd_flags="-ss"' >> etc/rc.conf
		echo 'sshd_flags="-o ListenAddress=\$(route get default | grep interface | cut -wf 3 | xargs ifconfig | grep inet | grep -v inet6 | cut -wf 3)"' >> etc/rc.conf
		echo 'clear_tmp_enable="YES"' >> etc/rc.conf
		# TODO: inherit current locale or make it configurable
		# /etc/csh.login - (t)csh
		echo 'setenv LANG fr_FR.UTF-8' >> etc/csh.login
		echo 'setenv MM_CHARSET UTF-8' >> etc/csh.login
		# /etc/profile - (ba|k|z)sh
		echo 'export LANG=fr_FR.UTF-8' >> etc/profile
		echo 'export MM_CHARSET=UTF-8' >> etc/profile
		# disable periodic
		sed -i '' '/^[^#].*periodic/s/^/#/' etc/crontab
		(
			cat <<- "EOS"
				WRKDIRPREFIX=/var/ports
				DISTDIR=${WRKDIRPREFIX}/distfiles
				PACKAGES=${WRKDIRPREFIX}/packages

				OPTIONS_UNSET_FORCE=EXAMPLES MANPAGES MAN3 NLS DOCS DOC HELP
			EOS
		) > etc/make.conf
EOC

	for path in ${MOUNT_RO} ${MOUNT_RO_NOSUID} ${MOUNT_RO_NOSUID_NOEXEC}; do
		umount "${JAILS_ROOT}/${1}${path}"
	done

	if is_on_zfs "${JAILS_ROOT}"; then
		zfs snapshot "${ZPOOL_NAME}${JAILS_ROOT}/${1}@created"
# 		zfs umount "${ZPOOL_NAME}${JAILS_ROOT}/${1}"
# 		zfs set canmount=noauto "${ZPOOL_NAME}${JAILS_ROOT}/${1}"
	fi
}

# do_fix(name)
do_fix()
{
	${__DIR__}/mounted -p "${JAILS_ROOT}/${1}" | while read mnt; do
		umount "$mnt"
	done
}

# do_shell(name)
do_shell()
{
	jexec -l "${1}" login -f root
}

_is_jail_running()
{
	JID=`jls -j "${1}" jid 2> /dev/null || true`
	[ -n "${JID}" ]

	return $?
}

# do_start(name)
do_start()
{
	if ! _is_jail_running "${1}"; then
		jail -c`${VERBOSE} && echo 'v'` "${1}"
	else
		info "jail ${1} is already running"
	fi
}

# do_stop(name)
do_stop()
{
	if _is_jail_running "${1}"; then
		if jail -r`${VERBOSE} && echo 'v'` "${1}"; then
			if [ `${__DIR__}/mounted -p "${JAILS_ROOT}/${1}" | wc -l` -ne 0 ]; then
				do_fix "${1}"
			fi
		fi
	else
		info "jail ${1} is not running"
	fi
}

# do_delete(name)
do_delete()
{
	if ask "Delete jail ${1}?"; then
		if is_on_zfs "${JAILS_ROOT}"; then
			zfs destroy -r "`zpool_name "${JAILS_ROOT}"`${JAILS_ROOT}/${1}"
			[ -d "${JAILS_ROOT}/${1}" ] && rmdir "${JAILS_ROOT}/${1}"
		else
			chflags -R noschg "${JAILS_ROOT}/${1}"
			rm -fr "${JAILS_ROOT}/${1}"
		fi
	fi
}

newopts=""
for var in "$@" ; do
	case "$var" in
	--delete)
		ACTION='delete'
		;;
	--install)
		ACTION='install'
		;;
#	 --update|--upgrade)
#		 ACTION='update'
#		 ;;
	--shell)
		ACTION='shell'
		;;
	--start)
		ACTION='start'
		;;
	--stop)
		ACTION='stop'
		;;
	--verbose)
		VERBOSE='true'
		;;
	--fix)
		ACTION='fix'
		;;
#	 --deploy=*)
#		 ACTION='deploy'
#		 HOST=${var#--deploy=}
#		 ;;
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

while getopts 'v' COMMAND_LINE_ARGUMENT ; do
	case "${COMMAND_LINE_ARGUMENT}" in
	v)
		VERBOSE='true'
		;;
	*)
		usage
		;;
	esac
done
shift $(( $OPTIND - 1 ))

[ $# -eq 0 ] && usage
[ -z "${ACTION}" ] && usage

if [ ! -f "${__DIR__}/mounted" ]; then
	cc "${__DIR__}/mounted.c" -o "${__DIR__}/mounted" -ljail
fi

for var in "$@" ; do
	eval "do_${ACTION}" "${var}"
done
