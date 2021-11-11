#!/bin/sh

# reprendre la valeur de votre variable organization créée au début
readonly ORGANIZATION=`hostname -d`

usage()
{
    echo "Usage: `basename $0` -r repository -j jail -p tree <list of clients>"
    exit 2
}

newopts=""
for var in "$@" ; do
    case "$var" in
    --jail=*)
        jail=${var#--jail=}
        ;;
    --repository=*)
        repository=${var#--repository=}
        ;;
    --tree=*)
        tree=${var#--tree=}
        ;;
    --*)
        usage
        ;;
    *)
        newopts="${newopts} ${var}"
        ;;
    esac
done

set -- $newopts
unset var newopts

while getopts 'j:p:r:' COMMAND_LINE_ARGUMENT ; do
    case "${COMMAND_LINE_ARGUMENT}" in
    j)
        jail=$OPTARG
        ;;
    p)
        tree=$OPTARG
        ;;
    r)
        repository=$OPTARG
        ;;
    *)
        usage
        ;;
    esac
done
shift $(( $OPTIND - 1 ))

: ${tree:='default'}

[ $# -eq 0 ] && usage
[ -z "${repository}" -o -z "${jail}" ] && usage

#if ! poudriere jail -j "${jail}" -i > /dev/null 2>&1; then
    #echo "jail ${jail} does not exist" >&2
    #exit 1
#fi
#if [ ! -d "/usr/local/poudriere/data/packages/${jail}-${tree}" ]; then
    #echo "the pair jail = ${jail} and tree = ${tree} does not exist" >&2
    #exit 1
#fi

mkdir -p /root/pkgng/clients/
oldumask=`umask`
umask 377
# parcours des arguments/clients
for host in "$@"; do
    # génération d'un certificat pour le client
    openssl req -new -newkey rsa:2048 -keyout /root/pkgng/clients/${host}.key -out /root/pkgng/clients/${host}.csr -sha256 -nodes -subj "/C=FR/O=${ORGANIZATION}/OU=pkgng/CN=${host}"
    # signature de celui-ci
    openssl x509 -req -days 3650 -in /root/pkgng/clients/${host}.csr -out /root/pkgng/clients/${host}.crt -CA /root/pkgng/ca/my_pkg_repo_ca.crt -CAkey /root/pkgng/ca/my_pkg_repo_ca.key -CAserial /root/pkgng/ca/my_pkg_repo_ca.serial
    cat > /tmp/$$.${host} <<EOD
# génération du fichier de configuration de pkg pour notre dépôt
${repository}: {
    ENV: {
        SSL_CA_CERT_FILE: /root/pkgng/ca/my_pkg_repo_ca.crt,
        SSL_CLIENT_KEY_FILE: /root/pkgng/self/${host}.key,
        SSL_CLIENT_CERT_FILE: /root/pkgng/self/${host}.crt
    },
    url: "https://${repository}/${jail}-${tree}",
    mirror_type: "none",
    signature_type: "pubkey",
    pubkey: "/root/pkgng/repos/${repository}.key",
    #fingerprints: "/usr/share/keys/pkg",
    enabled: yes,
    priority: 100
}
EOD
    # upload du tout sur le client
    tar czf - \
        -s '#root/pkgng/clients/#root/pkgng/self/#' \
        -s "#tmp/$$\.${host}#usr/local/etc/pkg/repos/${repository}.conf#" \
        -s "#root/pkgng/self/public\.key#root/pkgng/repos/${repository}.key#" \
        /root/pkgng/clients/${host}.crt /root/pkgng/clients/${host}.key /root/pkgng/ca/my_pkg_repo_ca.crt /tmp/$$.${host} /tmp/$$.FreeBSD.conf /root/pkgng/self/public.key | ssh root@${host} "tar xzf - -C /"
        #/root/pkgng/clients/${host}.crt /root/pkgng/clients/${host}.key /root/pkgng/ca/my_pkg_repo_ca.crt /tmp/$$.${host} /tmp/$$.FreeBSD.conf /root/pkgng/self/public.key > /tmp/${host}.tar.gz
done
umask $oldumask
# suppression des fichiers temporaires
rm -fP /tmp/$$.*
