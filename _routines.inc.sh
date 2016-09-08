
# __log(prefix, color, message)
__log()
{
	printf "[ \033[%d;01m%s\033[0m ] %s: %s\n" $2 $1 `basename $0` "${3}"

	return 0
}

# info(message)
info()
{
	__log 'OK' 32 "${1}"

	return $?
}

# err(message)
err()
{
	__log 'ERR' 31 "${1}"
	exit 1
}
