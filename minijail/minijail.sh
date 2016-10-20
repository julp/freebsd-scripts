#!/bin/sh -e

readonly __DIR__=`cd $(dirname -- "${0}"); pwd -P`

. ${__DIR__}/../_routines.inc.sh

# use vnet ? Default: use if available
VNET=`sysctl -n kern.features.vimage`

# default cache directory
BIN_CACHE_DIR="${HOME}/.binjailcache/$(uname -r)"
# force "base" as minimal sets to install
SET_TO_INSTALL="base"

readonly DUPED_FILES="etc/passwd etc/master.passwd etc/group etc/hosts etc/login.conf etc/motd"
readonly SYMLINKED_FILES="etc/make.conf etc/spwd.db etc/pwd.db etc/login.conf.db etc/ssh/ssh_host_rsa_key etc/ssh/ssh_host_rsa_key.pub etc/ssh/ssh_host_ecdsa_key etc/ssh/ssh_host_ecdsa_key.pub etc/ssh/ssh_host_ed25519_key etc/ssh/ssh_host_ed25519_key.pub"
readonly SYMLINKED_PATHS="etc/rc.conf.d home root usr/local tmp var mnt"

[ -s /usr/local/etc/minijail.conf ] && . /usr/local/etc/minijail.conf

: ${MIRROR:='ftp.freebsd.org/pub/FreeBSD/releases'}
: ${FROM:='binaries'}
: ${SKEL_NAME:='skel'}
: ${JAILS_ROOT:='/var/jails'}
: ${SKIP_CLEAN_ON_BUILDWORLD:='NO'}

VERBOSE='false'
zpool=`zfs get -H -o value name "${JAILS_ROOT}"`
readonly ZPOOL_NAME=${zpool%%/*} # `zfs get -Ho value name "${JAILS_ROOT}" | cut -d / -f 1`

readonly USE_ZFS="`(df -T ${JAILS_ROOT} | tail -n 1 | cut -wf 2 | grep -q '^zfs$' && echo YES) || echo NO`"

usage()
{
	echo "Usage: `basename $0` [ -v ] [ -s | -b ] ACTION name..."
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
	echo '-b, --binaries (default) : use compiled sets distributed by FreeBSD to create jails and update them with freebsd-update'
	echo '-s, --sources            : use sources (have to be installed into /usr/src) to create or update jails'
	echo ''
	echo 'General options:'
	echo '-v, --verbose : display debug informations'
	exit 2
}

# install_jail_precheck(name)
install_jail_precheck()
{
	if [ -e "${JAILS_ROOT}/${1}" ]; then
		err "jail \"${1}\" already exists"
		exit 1
	fi

	if echo "${USE_ZFS}" | grep -qi '^YES$'; then
		zfs create -p "${ZPOOL_NAME}${JAILS_ROOT}/${1}"
	else
		mkdir -p "${JAILS_ROOT}/${1}"
	fi

	return 0
}

create_skel_shared()
{
	chroot "${JAILS_ROOT}/${SKEL_NAME}" /bin/sh << EOC
		# put here any command you'd need, paths are relative to the jail's root
		ln -sf dev/null kernel
		mkdir -p usr/ports
		chsh -s /bin/tcsh > /dev/null 2>&1
		tzsetup -s Europe/Paris
		touch etc/fstab
		(echo -n 'nameserver ' ; route get default | grep interface | cut -wf 3 | xargs ifconfig | grep inet | grep -v inet6 | cut -wf 3) > /etc/resolv.conf
		# /etc/host.conf
		echo 'hosts' >> etc/host.conf
		echo 'dns' >> etc/host.conf
		# /etc/rc.conf
		echo 'hostname="\$(/bin/hostname)"' >> etc/rc.conf
		#echo 'sendmail_enable="NO"' >> etc/rc.conf
		echo 'syslogd_flags="-ss"' >> etc/rc.conf
		echo 'sshd_flags="-o ListenAddress=\$(route get default | grep interface | cut -wf 3 | xargs ifconfig | grep inet | grep -v inet6 | cut -wf 3)"' >> etc/rc.conf
		# TODO: inherit current locale
		# /etc/csh.login - (t)csh
		echo 'setenv LANG fr_FR.UTF-8' >> etc/csh.login
		echo 'setenv MM_CHARSET UTF-8' >> etc/csh.login
		# /etc/profile - (ba|k|z)sh
		echo 'export LANG=fr_FR.UTF-8' >> /etc/profile
		echo 'export MM_CHARSET=UTF-8' >> /etc/profile

		# create symlink for security/ca_root_nss
		ln -s /usr/local/share/certs/ca-root-nss.crt /etc/ssl/cert.pem

		mkdir skel private
		for path in $DUPED_FILES; do
			mkdir -p "skel/\$(dirname \$path)"
			mv "\$path" "skel/\$path"
		done
		for path in $SYMLINKED_PATHS $SYMLINKED_FILES $DUPED_FILES; do
			[ -e "\$path" ] && chflags -R noschg "\$path"
			rm -fr "\$path"
			ln -snf "/private/\$path" "\$path"
		done
EOC
	if echo "${USE_ZFS}" | grep -qi '^YES$'; then
		zfs snapshot "${ZPOOL_NAME}${JAILS_ROOT}/${SKEL_NAME}@created"
	fi
}

# _rebuild_if_needed(to)
#
# Run `make buildworld` if:
# - /usr/obj/usr/src/usr.bin/uname/uname doesn't exist
# - /usr/obj/usr/src/usr.bin/uname/uname -U output is (strictly) less than FreeBSD version extracted from /usr/src/sys/sys/param.h
_rebuild_world_if_needed()
{
	local OBJ_VERSION

# 	echo "Updating sources..."
# 	svnlite update /usr/src > /dev/null 2>&1 # TODO: redirect stderr to some file?
	if [ ! -x /usr/obj/usr/src/usr.bin/uname/uname -o `/usr/obj/usr/src/usr.bin/uname/uname -U` -lt "${1}" ]; then
		echo "Compiling world, this may take some time..."
		make -C /usr/src -j$((`sysctl -n hw.ncpu`+1)) buildworld NO_CLEAN=${SKIP_CLEAN_ON_BUILDWORLD} > /dev/null 2>&1 # TODO: redirect stderr to some file?
	fi
}

# bool _is_update_needed(to)
_is_update_needed()
{
	local JAIL_VERSION

	readonly JAIL_VERSION=`chroot "${JAILS_ROOT}/${SKEL_NAME}" uname -U`

	if [ "${JAIL_VERSION}" -ge "${1}" ]; then
		info "The base jail does not need to be updated"
		return 1
	else
		info "The base jail needs to be updated (${JAIL_VERSION} => ${1})"
		return 0
	fi
}

create_skel_from_sources()
{
	local SRC_VERSION

	readonly SRC_VERSION=`grep '#define[ ][ ]*__FreeBSD_version[ ][ ]*[[:digit:]][[:digit:]]*' /usr/src/sys/sys/param.h | cut -wf 3`

	install_jail_precheck "${SKEL_NAME}"

	_rebuild_world_if_needed "${SRC_VERSION}"
	echo "Installing world..."
	make -C /usr/src installworld DESTDIR="${JAILS_ROOT}/${SKEL_NAME}" > /dev/null 2>&1 # TODO: redirect stderr to some file?
	echo "Populating etc/..."
	make -C /usr/src/etc distribution DESTDIR="${JAILS_ROOT}/${SKEL_NAME}" > /dev/null 2>&1 # TODO: redirect stderr to some file?

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

# void _post_update(to)
_post_update()
{
# 	zfs snapshot "${ZPOOL_NAME}/${JAILS_ROOT}/${SKEL_NAME}@${1}"
}

update_skel_from_binaries()
{
	local WORLD_VERSION

	readonly WORLD_VERSION=`uname -U`
	_is_update_needed "${WORLD_VERSION}"
	if [ $? -eq 0 ]; then
		[ -f /etc/freebsd-update_for_jails.conf ] || ( grep -ve '#' -e '^$' -we Components -we BackupKernel /etc/freebsd-update.conf ; echo 'Components world' ; echo 'BackupKernel no' ) > /etc/freebsd-update_for_jails.conf
		freebsd-update -b "${JAILS_ROOT}/${SKEL_NAME}" -f /etc/freebsd-update_for_jails.conf fetch install
		_post_update "${WORLD_VERSION}"
	fi
}

update_skel_from_sources()
{
	local SRC_VERSION

	readonly SRC_VERSION=`grep '#define[ ][ ]*__FreeBSD_version[ ][ ]*[[:digit:]][[:digit:]]*' /usr/src/sys/sys/param.h | cut -wf 3`
	_is_update_needed "${SRC_VERSION}"
	if [ $? -eq 0 ]; then
		_rebuild_world_if_needed "${SRC_VERSION}"
		mergemaster -p -D "${JAILS_ROOT}/${SKEL_NAME}"
		echo "Installing world..."
		make -C /usr/src installworld DESTDIR="${JAILS_ROOT}/${SKEL_NAME}" > /dev/null 2>&1 # TODO: redirect stderr to some file?
		mergemaster -PUFi --run-updates=always -D "${JAILS_ROOT}/${SKEL_NAME}"
		_post_update "${SRC_VERSION}"
	fi
}

# update_jail(name)
update_jail()
{
# 	if [ "${FROM}" = 'binaries' ]; then
# 		jexec -l "${1}" pkg upgrade
# 	else
# 		mergemaster -p -D "${JAILS_ROOT}/${1}"
# 		mergemaster -PUFi --run-updates=always -D "${JAILS_ROOT}/${1}"
# 		jexec -l "${1}" portmaster -a
# 	fi
	# TODO: rebuild binary databases (cap_mkdb, newaliases, etc)
}

# install_jail(name)
install_jail()
{
	install_jail_precheck "${1}"

	if echo "${USE_ZFS}" | grep -qi '^YES$'; then
		zfs set mountpoint="${JAILS_ROOT}/${1}" "${ZPOOL_NAME}${JAILS_ROOT}/${1}"
# 		zfs mount "${ZPOOL_NAME}${JAILS_ROOT}/${1}"
	fi
	for path in ${SYMLINKED_PATHS}; do
		mkdir -p "${JAILS_ROOT}/${1}/${path}"
	done
	chmod 1777 "${JAILS_ROOT}/${1}/tmp" # /tmp => /private/tmp ?
	for file in ${DUPED_FILES}; do
		mkdir -p "$(dirname ${JAILS_ROOT}/${1}/${file})"
		cp "${JAILS_ROOT}/${SKEL_NAME}/skel/${file}" "${JAILS_ROOT}/${1}/${file}"
	done
	mkdir -p "${JAILS_ROOT}/${1}/etc/ssh" "${JAILS_ROOT}/${1}/var/log" "${JAILS_ROOT}/${1}/var/run"
	pwd_mkdb -d "${JAILS_ROOT}/${1}/etc/" "${JAILS_ROOT}/${1}/etc/master.passwd"
# 	mount -t nullfs -o ro "${JAILS_ROOT}/${SKEL_NAME}" "${JAILS_ROOT}/${1}"
# 	mount -t devfs .  "${JAILS_ROOT}/${1}/dev"
# 	chroot "${JAILS_ROOT}/${1}" /bin/sh << EOC
# 		newaliases
# EOC
	(
		cat <<- "EOS"
			WRKDIRPREFIX=/var/ports
			DISTDIR=${WRKDIRPREFIX}/distfiles
			PACKAGES=${WRKDIRPREFIX}/packages

			OPTIONS_UNSET_FORCE=EXAMPLES NLS DOCS MAN3 MANPAGES
		EOS
	) > "${JAILS_ROOT}/${1}/etc/make.conf"
# 	umount "${JAILS_ROOT}/${1}/dev" "${JAILS_ROOT}/${1}"
	if echo "${USE_ZFS}" | grep -qi '^YES$'; then
		zfs umount "${ZPOOL_NAME}${JAILS_ROOT}/${1}"
		zfs set canmount=noauto "${ZPOOL_NAME}${JAILS_ROOT}/${1}"
	fi
# NOTE: to add host to /etc/hosts
# ( route get default | grep interface | cut -wf 3 | xargs ifconfig | grep inet | grep -v inet6 | cut -wf 3 ; hostname ) | paste - - >> /etc/hosts
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
		jail -c`${VERBOSE} && echo 'v'` "${1}"
	fi
}

# do_stop(name)
do_stop()
{
	jail -r`${VERBOSE} && echo 'v'` "${1}"
}

# do_stop(name)
do_delete()
{
	# TODO: ask for confirmation
	if echo "${USE_ZFS}" | grep -qi '^YES$'; then
		zfs destroy -r "${ZPOOL_NAME}${JAILS_ROOT}/${1}"
		[ -d "${JAILS_ROOT}/${1}" ] && rmdir "${JAILS_ROOT}/${1}"
	else
		chflags -R noschg "${JAILS_ROOT}/${1}"
		rm -fr "${JAILS_ROOT}/${1}"
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
	--update)
		ACTION='update'
		;;
	--binary)
		FROM='binaries'
		;;
	--source)
		FROM='sources'
		;;
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

while getopts 'bsv' COMMAND_LINE_ARGUMENT ; do
	case "${COMMAND_LINE_ARGUMENT}" in
	b)
		FROM='binaries'
		;;
	s)
		FROM='sources'
		;;
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

for var in "$@" ; do
	eval "do_${ACTION}" "${var}"
done
