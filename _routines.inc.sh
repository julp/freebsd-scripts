
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
