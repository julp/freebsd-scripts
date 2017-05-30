
##### "logging" helpers

# __log(prefix, color, message)
__log()
{
	printf "[ \033[%d;01m%s\033[0m ] %s: %s\n" $2 $1 `basename $0` "${3}"

	return 0
}

# debug(message)
debug()
{
	__log 'DEBUG' 30 "${1}"

	return $?
}

# info(message)
info()
{
	__log 'INFO' 32 "${1}"

	return $?
}

# warn(message)
warn()
{
	__log 'WARN' 33 "${1}"

	return $?
}

# err(message)
err()
{
	__log 'ERR' 31 "${1}"
	exit 1
}

# ask(prompt)
ask()
{
	local YES_OR_NO

	read -ep "${1} [y/N] " YES_OR_NO
	case "${YES_OR_NO}" in
		[yY][eE][sS]|[yY])
			return 0
			;;
		*)
			return 1
			;;
	esac
}

##### world related helpers

# lazily_rebuild_world(system_directory)
lazily_rebuild_world()
{
	if [ ! -d /usr/src ]; then
		err "FreeBSD's sources are not installed. You may need to run first: svnlite checkout svn://svn.freebsd.org/base/releng/`freebsd-version -u | cut -f 1 -d '-'` /usr/src"
	fi
	local SVN_RELEASE_BEFORE=`svnlite info /usr/src | grep Revision | cut -wf 2`
	echo "Updating sources..."
	svnlite update /usr/src > /dev/null 2>&1 # TODO: redirect stderr to some file?
	local SVN_RELEASE_AFTER=`svnlite info /usr/src | grep 'Revision' | cut -wf 2`
	if [ "${SVN_RELEASE_BEFORE}" -ne "${SVN_RELEASE_AFTER}" -o ! -x "${1}/bin/freebsd-version" ]; then
		info "Compiling world, this may take some time..."
		make -C /usr/src -j$((`sysctl -n hw.ncpu`+1)) buildworld NO_CLEAN=${SKIP_CLEAN_ON_BUILDWORLD} WITHOUT_DEBUG_FILES=YES > /dev/null 2>&1 # TODO: redirect stderr to some file?
		return 0
	else
		info "World is up to date, no need to rebuild it"
		return 1
	fi
}

# lazily_update_world(system_directory)
lazily_update_world()
{
	local CURRENT_VERSION=`[ -x /usr/obj/usr/src/bin/freebsd-version/freebsd-version ] && /usr/obj/usr/src/bin/freebsd-version/freebsd-version -u || echo "uninstalled"`

	if [ `${1}/bin/freebsd-version -u` != "${CURRENT_VERSION}" ]; then
		mergemaster -p -D "${1}"
		info "Installing world..."
		make -C /usr/src installworld DESTDIR="${1}" WITHOUT_DEBUG_FILES=YES > /dev/null 2>&1 # TODO: redirect stderr to some file?
		mergemaster -PUFi --run-updates=always -D "${1}"
		return 0
	else
		info "Intalled world is up to date, skipping its installation"
		return 1
	fi
}

##### ZFS helpers

# is_on_zfs(directory)
is_on_zfs()
{
	# NOTE: we do not simply `return $?` because of `shopt -e` which ends the script if the command doesn't return 0
	if df -T "${1}" | tail -n 1 | cut -wf 2 | grep -q '^zfs$'; then
		return 0
	else
		return 1
	fi
}

# zpool_name(directory)
zpool_name()
{
	#if is_on_zfs "${1"}; then
	(zfs get -Ho value name "${1}"  2> /dev/null | cut -d / -f 1) || true
	#fi
}
