#!/bin/sh -e

# readonly __DIR__=`cd $(dirname -- "${0}"); pwd -P`

# . ${__DIR__}/../_routines.inc.sh

[ -s /usr/local/etc/zfsbackup.conf ] && . /usr/local/etc/zfsbackup.conf

##### local settings
# name of the local pool to backup
: ${LOCAL_POOL_NAME:=`zfs get -H -o value name / | cut -d / -f 1`}
# delete snapshots after sending it?
# originally planned with use of bookmarks, with -R flag on zfs send, you need to keep locally the snapshots you want to have on both sides
# : ${DROP_SNAPSHOT:='NO'}

readonly SNAPSHOT_NAME="${LOCAL_POOL_NAME}@`date '+%d-%m-%Y_%H:%M'`"
# NOTE: bookmarks aren't (yet?) recursive
# readonly BOOKMARK_NAME="${LOCAL_POOL_NAME}#last"

##### remote settings
# name of the remote pool where to backup
: ${REMOTE_POOL_NAME:='backup'}
# name or address of the host which receives the stream (keep empty to not use SSH)
: ${REMOTE_HOST:=''}
# user name to login as on the remote system (keep empty to receive on the same host)
: ${REMOTE_USER:=''}

zfs snapshot -r "${SNAPSHOT_NAME}"

SEND_TO=""
if [ -n "${REMOTE_HOST}" ]; then
	if [ -n "${REMOTE_USER}" ]; then
		SEND_TO="ssh ${REMOTE_USER}@${REMOTE_HOST}"
	else
		SEND_TO="ssh ${REMOTE_HOST}"
	fi
fi

#if ! zfs list -Hd 1 -t bookmark | grep -qF "${BOOKMARK_NAME}"; then
if [ `${SEND_TO} zfs list -Hd 1 -t snapshot "${REMOTE_POOL_NAME}" | wc -l` -eq 0 ]; then
	zfs send -R "${SNAPSHOT_NAME}" | ${SEND_TO} zfs receive -v -sduF "${REMOTE_POOL_NAME}"
else
	zfs send -Ri `( for snap in $(zfs list -Hrd 1 -t snapshot -o name ${LOCAL_POOL_NAME}); do zfs get -Hpo name,value creation "${snap}"; done ) | sort -rnk 2 | tail -n 1 | cut -f 1` "${SNAPSHOT_NAME}" | ${SEND_TO} zfs receive -v -sduF "${REMOTE_POOL_NAME}"
# 	zfs send -i "${BOOKMARK_NAME}" "${SNAPSHOT_NAME}" | ${SEND_TO} zfs receive -v -sduF "${REMOTE_POOL_NAME}"
# 	zfs destroy "${BOOKMARK_NAME}"
fi
# zfs bookmark "${SNAPSHOT_NAME}" "${BOOKMARK_NAME}"
# if echo "${DROP_SNAPSHOT}" | grep -qi '^YES$'; then
# 	zfs destroy "${SNAPSHOT_NAME}"
# fi

# to keep at most the last $SNAPSHOT_COUNT_TO_KEEP snapshots
# (
# 	for snap in `zfs list -Hrt snapshot -o name ${LOCAL_POOL_NAME}`; do
# 		zfs get -Hpo name,value creation "${snap}"
# 	done
# ) | sort -rnk 2 | sed "1,${SNAPSHOT_COUNT_TO_KEEP}d" | (
# 	for snap in `cut -f 1`; do
# 		echo "=> zfs destroy ${snap}"
# 	done
# )
