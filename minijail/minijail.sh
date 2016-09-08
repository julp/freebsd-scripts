#!/bin/sh

set -e

readonly __DIR__=`cd $(dirname "${0}"); pwd -P`

. ${__DIR__}/../_routines.inc.sh

# use vnet ? Default: use if available
VNET=`sysctl -n kern.features.vimage`

MIRROR="ftp.freebsd.org/pub/FreeBSD/releases"
# default cache directory
BIN_CACHE_DIR="${HOME}/.binjailcache/$(uname -r)"
# force "base" as minimal sets to install
SET_TO_INSTALL="base"

readonly DUPED_FILES="etc/passwd etc/master.passwd etc/group"
readonly SYMLINKED_FILES="etc/spwd.db etc/pwd.db etc/host.conf"
readonly SYMLINKED_PATHS="home root usr/local tmp var"

[ -s /usr/local/etc/minijail.conf ] && . /usr/local/etc/minijail.conf

: ${FROM:='binaries'}
: ${SKEL_NAME:='skel'}
: ${JAILS_ROOT:='/var/jails'}

usage()
{
	echo "Usage: `basename $0` [ -s | -b ] ACTION name..."
	echo ''
	echo "ACTION is one of:"
	echo '--install : create a jail'
	echo '--update  : upgrade a jail'
	echo '--delete  : drop a jail'
	echo '--shell   : acquire a root shell into the jail'
	echo '--start   : start a jail (if not yet active)'
	echo '--stop    : stop a jail (currently running)'
	echo ''
	echo 'Options for --install or --update:'
	echo '-b, --binaries (default) : use compiled sets distributed by FreeBSD to create or update jails'
	echo '-s, --sources            : use sources (have to be installed into /usr/src) to create or update jails'
	echo ''
	exit 2
}

# install_jail_precheck(name)
install_jail_precheck()
{
	if [ -e "${JAILS_ROOT}/${1}" ]; then
		err "jail \"${1}\" already exists"
		exit 1
	fi

	mkdir -p "${JAILS_ROOT}/${1}"

	return 0
}

create_skel_shared()
{
	chroot "${JAILS_ROOT}/${SKEL_NAME}" /bin/sh << EOC
# 	if [ 'x' = 'y' ]; then
		# put here any command you'd need, paths are relative to the jail's root
		ln -sf dev/null kernel
		mkdir -p usr/ports
		chsh -s /bin/tcsh
		tzsetup -s Europe/Paris
		touch etc/fstab
		# newaliases # TODO: ensure name resolving first
		# TODO: resolv.conf
		# /etc/rc.conf
		echo 'hostname="\$(/bin/hostname)"' >> etc/rc.conf
		echo 'sendmail_enable="NO"' >> etc/rc.conf
		echo 'syslogd_flags="-ss"' >> etc/rc.conf
		# /etc/csh.login
		echo 'setenv LANG fr_FR.UTF-8' >> etc/csh.login
		echo 'setenv MM_CHARSET UTF-8' >> etc/csh.login

		mkdir {skel,private}
		for path in $DUPED_FILES; do
			mkdir -p "skel/\$(dirname \$path)"
			mv "\$path" "skel/\$path"
		done
# 	fi
		for path in $SYMLINKED_PATHS $SYMLINKED_FILES $DUPED_FILES; do
			rm -fr "\$path"
			ln -snf "/private/\$path" "\$path"
		done
EOC
}

create_skel_from_sources()
{
	install_jail_precheck "${SKEL_NAME}"

	make -C /usr/src -j$((`sysctl -n hw.ncpu`+1)) buildworld NO_CLEAN=YES
	make -C /usr/src installworld DESTDIR="${JAILS_ROOT}/${SKEL_NAME}"
	make -C /usr/src/etc distribution DESTDIR="${JAILS_ROOT}/${SKEL_NAME}"

	create_skel_shared
}

create_skel_from_binaries()
{
	local line set s

	install_jail_precheck "${SKEL_NAME}"

	# fetch, check and extract sets
	mkdir -p "${BIN_CACHE_DIR}"
	for s in "${SET_TO_INSTALL}"; do
		if [ ! -f "${BIN_CACHE_DIR}/${s}.txz" ]; then
			fetch -o "${BIN_CACHE_DIR}/${s}.txz" "ftp://${MIRROR}/$(uname -m)/$(uname -r)/${s}.txz"
		fi
	done

	fetch -qo - "ftp://${MIRROR}/$(uname -m)/$(uname -r)/MANIFEST" | while read line; do
		set=$(echo "$line" | cut -d. -f 1)
		cksum=$(echo "$line" | cut -f 2)
		if eval echo " ${line} " | grep -q " ${set} "; then
			if [ -f "${BIN_CACHE_DIR}/${set}.txz" ]; then
				if ! eval sha256 -qc "${cksum}" "${BIN_CACHE_DIR}/${set}.txz" > /dev/null; then
					err "checksum failed for ${set}"
					rm -f "${BIN_CACHE_DIR}/${set}.txz"
					exit 1
				fi
			fi
		fi
	done

	for set in $SET_TO_INSTALL; do
		tar -xJf "${BIN_CACHE_DIR}/${set}.txz" -C "${JAILS_ROOT}/${SKEL_NAME}"
	done

	create_skel_shared
}

update_skel_from_binaries()
{
	[ -f /etc/freebsd-update_for_jails.conf ] || ( grep -ve '#' -e '^$' -we Components -we BackupKernel /etc/freebsd-update.conf ; echo 'Components world' ; echo 'BackupKernel no' ) > /etc/freebsd-update_for_jails.conf
	freebsd-update -b "${JAILS_ROOT}/${SKEL_NAME}" -f /etc/freebsd-update_for_jails.conf fetch install
}

update_skel_from_sources()
{
	make -C /usr/src -j$((`sysctl -n hw.ncpu`+1)) buildworld NO_CLEAN=YES
	mergemaster -p -D "${JAILS_ROOT}/${SKEL_NAME}"
	make -C /usr/src installworld DESTDIR="${JAILS_ROOT}/${SKEL_NAME}"
	mergemaster -iF --run-updates=always -D "${JAILS_ROOT}/${SKEL_NAME}"
}

# update_jail(name)
update_jail()
{
# 	mergemaster -p -D "${JAILS_ROOT}/${1}"
# 	mergemaster -iF --run-updates=always -D "${JAILS_ROOT}/${1}"
	# TODO: rebuild databases (cap_mkdb, newaliases, etc)
}

# install_jail(name)
install_jail()
{
	install_jail_precheck "${1}"

	zfs create -p "`zpool list -Ho name`${JAILS_ROOT}/${1}"
	zfs set mountpoint="${JAILS_ROOT}/${1}" "`zpool list -Ho name`${JAILS_ROOT}/${1}"
# 	zfs mount "`zpool list -Ho name`${JAILS_ROOT}/${1}"
	for path in ${SYMLINKED_PATHS}; do
		mkdir -p "${JAILS_ROOT}/${1}/${path}" # private/${path}
	done
	for file in ${DUPED_FILES}; do
		mkdir -p "$(dirname ${JAILS_ROOT}/${1}/${file})" # private/${file}
		cp "${JAILS_ROOT}/${SKEL_NAME}/skel/${file}" "${JAILS_ROOT}/${1}/${file}" # private/${file}
	done
	mkdir -p ${JAILS_ROOT}/${1}/var/log ${JAILS_ROOT}/${1}/var/run # private/ * 2
	pwd_mkdb -d "${JAILS_ROOT}/${1}/etc/" "${JAILS_ROOT}/${1}/etc/master.passwd" # private/etc * 2
	zfs umount "`zpool list -Ho name`${JAILS_ROOT}/${1}"
	zfs set canmount=noauto "`zpool list -Ho name`${JAILS_ROOT}/${1}"
}

# do_install(name)
do_install()
{
	if [ "${1}" = "${SKEL_NAME}" ]; then
		if [ "${FROM}" = 'binaries' ]; then
			create_skel_from_binaries
		else
			create_skel_from_sources
		fi
	else
		install_jail "${1}"
	fi
}

# do_update(name)
do_update()
{
	if [ "${1}" = "${SKEL_NAME}" ]; then
		# TODO: create a snapshot
		if [ "${FROM}" = 'binaries' ]; then
			update_skel_from_binaries
		else
			update_skel_from_sources
		fi
	else
		update_jail "${1}"
	fi
}

# do_shell(name)
do_shell()
{
	jexec -l "${1}" login -f root
}

# do_start(name)
do_start()
{
	JID=`jls -j "${1}" jid 2> /dev/null || true`
	if [ -z "${JID}" ]; then
		jail -c "${1}"
	fi
}

# do_stop(name)
do_stop()
{
	jail -r "${1}"
}

# do_stop(name)
do_delete()
{
	if [ "${1}" = "${SKEL_NAME}" ]; then
		chflags -R "${JAILS_ROOT}/${1}"
		rm -fr "${JAILS_ROOT}/${1}"
	else
		zfs destroy "`zpool list -Ho name`${JAILS_ROOT}/${1}"
	fi
}

newopts=""
for var in "$@" ; do
	case "$var" in
	--delete)
		ACTION="delete"
		;;
	--install)
		ACTION="install"
		;;
	--update)
		ACTION="update"
		;;
	--binary)
		FROM="binaries"
		;;
	--source)
		FROM="sources"
		;;
	--shell)
		ACTION="shell"
		;;
	--start)
		ACTION="start"
		;;
	--stop)
		ACTION="stop"
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

while getopts 'bs' COMMAND_LINE_ARGUMENT ; do
	case "${COMMAND_LINE_ARGUMENT}" in
	b)
		FROM="binaries"
		;;
	s)
		FROM="sources"
		;;
	*)
		usage
		;;
	esac
done
shift $(( $OPTIND - 1 ))

[ $# -eq 0 ] && usage
[ -z "${ACTION}" ] && usage

for var in "$@" ; do
	eval "do_${ACTION}" "${var}"
done
