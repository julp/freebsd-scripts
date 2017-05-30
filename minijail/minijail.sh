#!/bin/sh -e

# How to find FreeBSD version?
# - /usr/src/sys/sys/param.h (for and from sources)
# - /usr/src/sys/conf/newvers.sh (for and from sources)
# - (/usr/obj/usr/src/bin/freebsd-version/)freebsd-version -u (relevant: this a script but it is (re)generated from /usr/src/sys/conf/newvers.sh)
# - (/usr/obj/usr/src/usr.bin/uname/)uname -U (but irrelevant from a jail)

readonly __DIR__=`cd $(dirname -- "${0}"); pwd -P`

. ${__DIR__}/../_routines.inc.sh

# use vnet ? Default: use if available
VNET=`sysctl -n kern.features.vimage`

# default cache directory
BIN_CACHE_DIR="${HOME}/.binjailcache/$(uname -r)"
# force "base" as minimal sets to install
SET_TO_INSTALL="base"

readonly DUPED_FILES="etc/passwd etc/master.passwd etc/group etc/hosts etc/login.conf etc/motd"
# NOTE: root is not treated as a path because the dot files in /.* are links to /root/.* and if /root/ is not on a the same filesystem as /, ln fails with a EXDEV (cross device link)
readonly SYMLINKED_FILES="root etc/make.conf etc/spwd.db etc/pwd.db etc/login.conf.db etc/ssh/ssh_host_rsa_key etc/ssh/ssh_host_rsa_key.pub etc/ssh/ssh_host_ecdsa_key etc/ssh/ssh_host_ecdsa_key.pub etc/ssh/ssh_host_ed25519_key etc/ssh/ssh_host_ed25519_key.pub"
readonly SYMLINKED_PATHS="etc/rc.conf.d home usr/local tmp var mnt"

[ -s /usr/local/etc/minijail.conf ] && . /usr/local/etc/minijail.conf

: ${MIRROR:='ftp.freebsd.org/pub/FreeBSD/releases'}
: ${FROM:='sources'}
: ${SKEL_NAME:='skel'}
: ${JAILS_ROOT:='/var/jails'}
: ${SKIP_CLEAN_ON_BUILDWORLD:='NO'}

VERBOSE='false'

usage()
{
	echo "Usage: `basename $0` [ -v ] [ -s | -b ] ACTION name..."
	echo ''
	echo "ACTION is one of:"
	echo '--install             : create a jail'
	echo '--update or --upgrade : upgrade a jail'
	echo '--delete              : drop a jail'
	echo '--shell               : acquire a root shell into the jail'
	echo '--start               : start a jail (if not yet active)'
	echo '--stop                : stop a jail (currently running)'
	echo '--deploy=<host>       : copy a jail on remote <host>'
	echo ''
	echo 'Options for --install or --update:'
	echo '-s, --sources (default) : use sources (have to be installed into /usr/src) to create or update jails'
	echo '-b, --binaries          : use compiled sets distributed by FreeBSD to create jails and update them with freebsd-update'
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

	if is_on_zfs "${JAILS_ROOT}"; then
		zfs create -p "`zpool_name "${JAILS_ROOT}"`${JAILS_ROOT}/${1}"
	else
		mkdir -p "${JAILS_ROOT}/${1}"
	fi

	return 0
}

_mount_private()
{
	if [ -d /private/ ]; then
		err "/private/ already exists"
	fi
	mkdir /private/
	# instead of writing on disk to then delete the files, use RAM
	mount -t tmpfs tmpfs /private/
	for path in $SYMLINKED_PATHS; do
		mkdir -p "/private/${path}"
	done

	return 0
}

_umount_private()
{
	umount /private/
	rmdir /private/

	return 0
}

create_skel_shared()
{
	chroot "${JAILS_ROOT}/${SKEL_NAME}" /bin/sh << EOC
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
		echo 'export LANG=fr_FR.UTF-8' >> /etc/profile
		echo 'export MM_CHARSET=UTF-8' >> /etc/profile
		# disable periodic
		sed -i '' '/^[^#].*periodic/s/^/#/' etc/crontab
		# mergemaster: skip some warnings - TODO: this doesn't seem to work (needs s#/#${JAILS_ROOT}/${SKEL_NAME}/#g?)
		echo 'IGNORE_FILES="/root /var"' > etc/mergemaster.rc

		# create symlink for security/ca_root_nss
		ln -s /usr/local/share/certs/ca-root-nss.crt /etc/ssl/cert.pem

		mkdir skel private
		for path in $DUPED_FILES; do
			mkdir -p "skel/\$(dirname \$path)"
			mv "\$path" "skel/\$path"
		done
		for path in $SYMLINKED_FILES $DUPED_FILES; do # $SYMLINKED_PATHS
			[ -e "\$path" ] && chflags -R noschg "\$path"
			rm -fr "\$path"
			ln -snf "/private/\$path" "\$path"
		done
EOC
	if is_on_zfs "${JAILS_ROOT}"; then
		zfs snapshot "`zpool_name "${JAILS_ROOT}"`${JAILS_ROOT}/${SKEL_NAME}@created"
	fi
}

# bool _is_update_needed(to)
_is_update_needed()
{
	local JAIL_VERSION

	# NOTE: we can't rely on uname (from jail), it returns the value of the host
	readonly JAIL_VERSION=`"${JAILS_ROOT}/${SKEL_NAME}/bin/freebsd-version" -u`

	if [ "${JAIL_VERSION}" = "${1}" ]; then
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

	if lazily_rebuild_world "${JAILS_ROOT}/${SKEL_NAME}"; then
		_mount_private
		for path in ${SYMLINKED_PATHS}; do
			mkdir -p $(dirname "${JAILS_ROOT}/${SKEL_NAME}/${path}")
			ln -snf "/private/${path}" "${JAILS_ROOT}/${SKEL_NAME}/${path}"
		done
		lazily_update_world "${JAILS_ROOT}/${SKEL_NAME}"
		info "Populating etc/..."
		make -C /usr/src/etc distribution DESTDIR="${JAILS_ROOT}/${SKEL_NAME}" > /dev/null 2>&1 # TODO: redirect stderr to some file?
		create_skel_shared
		_umount_private
	fi
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
# 	zfs snapshot "`zpool_name "${JAILS_ROOT}"`${JAILS_ROOT}/${SKEL_NAME}@${1}"
}

update_skel_from_binaries()
{
	local WORLD_VERSION

	readonly WORLD_VERSION=`uname -U`
	if _is_update_needed "${WORLD_VERSION}"; then
		[ -f /etc/freebsd-update_for_jails.conf ] || ( grep -ve '#' -e '^$' -we Components -we BackupKernel /etc/freebsd-update.conf ; echo 'Components world' ; echo 'BackupKernel no' ) > /etc/freebsd-update_for_jails.conf
		freebsd-update -b "${JAILS_ROOT}/${SKEL_NAME}" -f /etc/freebsd-update_for_jails.conf fetch install
		_post_update "${WORLD_VERSION}"
	fi
}

update_skel_from_sources()
{
	if lazily_rebuild_world "${JAILS_ROOT}/${SKEL_NAME}"; then
		_mount_private
		if lazily_update_world "${JAILS_ROOT}/${SKEL_NAME}"; then
			_umount_private
			_post_update "`${JAILS_ROOT}/${SKEL_NAME}/bin/freebsd-version -u`"
		fi
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
	local ZPOOL_NAME=`zpool_name "${JAILS_ROOT}"`

	if is_on_zfs "${JAILS_ROOT}"; then
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

			OPTIONS_UNSET_FORCE=EXAMPLES MANPAGES MAN3 NLS DOCS DOC HELP
			security_ca_root_nss_UNSET_FORCE=ETCSYMLINK
		EOS
	) > "${JAILS_ROOT}/${1}/etc/make.conf"
# 	umount "${JAILS_ROOT}/${1}/dev" "${JAILS_ROOT}/${1}"
	if is_on_zfs "${JAILS_ROOT}"; then
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

# do_stop(name)
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

# do_deploy(name)
do_deploy()
{
	local REMOTE_HOST=`echo "${HOST}" | cut -d ':' -f 1`
	local REMOTE_PATH=`echo "${HOST}" | cut -d ':' -f 2-`

	echo "TODO: deploy '${1}' on '${REMOTE_HOST}' (${REMOTE_PATH})"

	if is_on_zfs "${JAILS_ROOT}"; then
		local ZFS_HINTS=$(
			#cat <<-EOC
			ssh "root@${REMOTE_HOST}" /bin/sh <<-EOC
				if df -T "${REMOTE_PATH}" | tail -n 1 | cut -wf 2 | grep -q '^zfs$'; then
					ZPOOL_NAME=\$(zfs get -H -o value name "${REMOTE_PATH}" | cut -d / -f 1)

					# TODO: echo une chaîne donnant des infos ? (ZPOOL_NAME + DERNIER SNAPSHOT ?)
					# \$(zfs list -Hd 1 -t snapshot "\${ZPOOL_NAME}${REMOTE_PATH}/${1}" | wc -l)
					echo "\${ZPOOL_NAME}:"
					if [ ! -e "${REMOTE_PATH}" ]; then
						echo 'zfs create -p "\${ZPOOL_NAME}${REMOTE_PATH}/${1}"'
						exit 0
					elif zfs get -Ho value name "\${ZPOOL_NAME}${REMOTE_PATH}" > /dev/null 2>&1; then
						exit 0
					fi
				fi

				if [ ! -e "${REMOTE_PATH}" ]; then
					mkdir -p "${REMOTE_PATH}/${1}"
				fi

				exit 1
			EOC
		)
		if [ $? -eq 0 ]; then
			local LOCAL_ZPOOL_NAME=`zpool_name "${JAILS_ROOT}"`
			local REMOTE_ZPOOL_NAME=`echo "${ZFS_HINTS}" | cut -d ':' -f 1`
			#zfs send -Ri `( for snap in $(zfs list -Hrd 1 -t snapshot -o name ${LOCAL_ZPOOL_NAME}); do zfs get -Hpo name,value creation "${snap}"; done ) | sort -rnk 2 | tail -n 1 | cut -f 1` "${SNAPSHOT_NAME}" | ssh "root@${REMOTE_HOST}" zfs receive -v -sduF "${REMOTE_ZPOOL_NAME}${REMOTE_PATH}/${1}"
			return 0
		fi
	fi
	# fallback to rsync
	#rsync -avhz --progress "${JAILS_ROOT}/${1}" "root@${REMOTE_HOST}:${REMOTE_PATH}/${1}"

	# if both systems seem to use ZFS (zfs send)
	#if is_on_zfs "${JAILS_ROOT}" && ssh "root@${REMOTE_HOST}" "df -T \"${REMOTE_PATH}\" | tail -n 1 | cut -wf 2 | grep -q '^zfs$'"; then
		#local REMOTE_ZPOOL=`ssh "root@${REMOTE_HOST}" "zfs get -H -o value name '${REMOTE_PATH}'" | cut -d / -f 1`
		##local REMOTE_ZPOOL_NAME=${REMOTE_ZPOOL%%/*}

		## if jail directory doesn't exist or exist and is a ZFS filesystem => zfs send
		#if ssh "root@${REMOTE_HOST}" "zfs get -Ho value name '${REMOTE_ZPOOL}${REMOTE_PATH}'" > /dev/null 2>&1; then
			#echo "ZFS on both"
			#return 0
		##else
			##echo "ZFS found but the jails doesn't have its own ZFS filesystem"
		#fi
	#fi
	# else (rsync)
	#echo "not ZFS on both (rsync)"
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
	--update|--upgrade)
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
	--fix)
		ACTION='fix'
		;;
	--deploy=*)
		ACTION='deploy'
		HOST=${var#--deploy=}
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

if [ ! -f "${__DIR__}/mounted" ]; then
	cc "${__DIR__}/mounted.c" -o "${__DIR__}/mounted" -ljail
fi

for var in "$@" ; do
	eval "do_${ACTION}" "${var}"
done
