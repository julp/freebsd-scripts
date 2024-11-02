#!/bin/sh -ex

# mountpoint used to mount the ESP partition
readonly TEMPORARY_MOUNT_POINT="/mnt"
# the (temporary - can be deleted afterwards) directory used to copy/build all we need
readonly BASE_DIR="/tmp/bootfs"
# the subdirectory used to build the MFS image
readonly BUILD_DIRECTORY="${BASE_DIR}/build"
# the output path of the MFS image
readonly BOOTFS_OUTPUT="${BASE_DIR}/bootfs.img"
# the output path of the (unsigned) loader
readonly UNSIGNED_LOADER_OUTPUT="${BASE_DIR}/loader.efi"
# the output path of the signed loader
readonly SIGNED_LOADER_OUTPUT="${BASE_DIR}/signed-loader.efi"
readonly __DIR__=`cd $(dirname -- "${0}"); pwd -P`
# extra space added to the MFS image for safety
readonly BOOTFS_EXTRA_SIZE=512

. ${__DIR__}/../_routines.inc.sh

# default values
BASE_DIRECTORY="/"
KERNCONF="GENERIC"
SOURCE_DIRECTORY="/usr/src"
OBJECT_DIRECTORY="/usr/obj"

usage()
{
    echo "Usage: `basename $0` -c CERTIFICATE -k PRIVATE_KEY -e ESP_PARTITION -b BASE_DIRECTORY"
    echo ''
    echo '-c CERTIFICATE, --cert=CERTIFICATE    : path to the certificate'
    echo '-k PRIVATE_KEY, --key=PRIVATE_KEY     : path to the private key'
    echo '-e ESP_PARTITION, --esp=ESP_PARTITION : the name (or label) of the EFI partition (default is to try to guess it)'
    echo ''
    echo '-b BASE_DIRECTORY, --base=BASE_DIRECTORY       : the base system directory (default: /, useful to point to a BE or jail)'
    echo '-r REFIND_DIRECTORY, --refind=REFIND_DIRECTORY : the directory where you unzipped the rEFInd "binary zip file"'
    echo ''
    echo '-K KERNCONF, --kernel=KERNCONF : kernel name (default: GENERIC)'
    echo '-s SOURCE_DIRECTORY, --source=SOURCE_DIRECTORY : FreeBSD sources directory (default: /usr/src)'
    echo ''
    exit 2
}

newopts=""
for var in "${@}" ; do
    case "${var}" in
    --base=*)
        BASE_DIRECTORY=`realpath "${var#--base=}"`
        ;;
    --cert=*)
        CERTIFICATE="${var#--cert=}"
        ;;
    --esp=*)
        ESP_PARTITION="${var#--esp=}"
        ;;
    --kernel=*)
        KERNCONF="${var#--kernel=}"
        ;;
    --key=*)
        PRIVATE_KEY="${var#--key=}"
        ;;
    --refind=*)
        REFIND_DIRECTORY="${var#--refind=}"
        ;;
    --source=*)
        SOURCE_DIRECTORY="${var#--source=}"
        ;;
    --*)
        usage
        ;;
    *)
        newopts="${newopts} \"${var}\""
        ;;
    esac
done

# getopt stuffs and arguments checking
eval set -- "${newopts}"
echo "$newopts"
unset var newopts

while getopts 'K:b:c:k:e:r:s:' COMMAND_LINE_ARGUMENT; do
    case "${COMMAND_LINE_ARGUMENT}" in
    K)
        KERNCONF="${OPTARG}"
        ;;
    b)
        BASE_DIRECTORY=`realpath "${OPTARG}"`
        ;;
    c)
        CERTIFICATE="${OPTARG}"
        ;;
    k)
        PRIVATE_KEY="${OPTARG}"
        ;;
    e)
        ESP_PARTITION="${OPTARG}"
        ;;
    r)
        REFIND_DIRECTORY="${OPTARG}"
        ;;
    s)
        SOURCE_DIRECTORY="${OPTARG}"
        ;;
    *)
        usage
        ;;
    esac
done
shift $(( $OPTIND - 1 ))

if [ -z "${CERTIFICATE}" ]; then
    err "option --cert/-c required to indicate the certificate used to sign binaries"
fi
if [ -z "${PRIVATE_KEY}" ]; then
    err "option --key/-k required to indicate the private key used to sign binaries"
fi

if [ ! -e "${CERTIFICATE}" ]; then
    err "certificate '${CERTIFICATE}' doesn't exist, make sure to first run /usr/share/examples/uefisign/uefikeys (its .pem output file) or double check your location"
fi
if [ ! -e "${PRIVATE_KEY}" ]; then
    err "private key '${PRIVATE_KEY}' doesn't exist, make sure to first run /usr/share/examples/uefisign/uefikeys (its .key output file) or double check your location"
fi

if [ -z "${ESP_PARTITION}" ]; then
    ESP_PARTITIONS_COUNT=`gpart show -p | grep -Fciw "EFI"`
    if [ "${ESP_PARTITIONS_COUNT}" -eq 1 ]; then
        ESP_PARTITION=`gpart show -p | grep -Fiw "EFI" | cut -wf 4`
        info "EFI partition found: ${ESP_PARTITION}"
    elif [ "${ESP_PARTITIONS_COUNT}" -eq 0 ]; then
        err "no EFI partition found, make sure to have one and if so try to use the --esp option to force its use"
    else
        err "Multiple (${ESP_PARTITIONS_COUNT}) EFI partitions found, use the --esp option to indicate which one to use"
    fi
else
    # TODO: check that type of "${ESP_PARTITION}" is EFI
fi

# create_entry_if_not_exists(path, label)
create_entry_if_not_exists()
{
    local EFI_PATH=`efibootmgr -u "${1}" | cut -wf 3`

    if [ -n "${EFI_PATH}" ]; then
        efibootmgr -v | grep -qF "${EFI_PATH}" || efibootmgr -a -c -l "${1}" -L "${2}"
    fi

    return 0
}

#SOURCE_DIRECTORY=$(realpath `make -C "${SOURCE_DIRECTORY}" -V .OBJDIR`)

# <loader.conf parsing>
set +e
. "${BASE_DIRECTORY}/boot/loader.conf" 2> /dev/null
set -e

FIND_ARGUMENTS=""
PORTS_MODULES=""
for v in $(set); do
    value=`echo "${v}" | cut -f 2 -d "="`
    variable=`echo "${v}" | cut -f 1 -d "="`
    module=${variable%_load}
    if [ "${value}" == "YES" -a "${module}" != "${variable}" ]; then
        eval location="\$${module}_name"
        if [ -z "${location}" ]; then
#             location="/boot/kernel/${module}.ko"
            FIND_ARGUMENTS="${FIND_ARGUMENTS} ! -name \"${module}.ko\""
        else
            mkdir -p `dirname "${BUILD_DIRECTORY}/${location}"`
            # NOTE: this implies that the package from which it comes from is installed on the (build) system
            port=`pkg which -qo "${location}" || true`
            if [ -n "${port}" ]; then
                PORTS_MODULES="${PORTS_MODULES} ${port}"
            fi
        fi
    fi
done
# </loader.conf parsing>

kldload -n filemon
mkdir -p "${BUILD_DIRECTORY}/boot"
# cp -r "${BASE_DIRECTORY}/boot/kernel" "${BUILD_DIRECTORY}/boot"
mtree -deUW -f "${SOURCE_DIRECTORY}/etc/mtree/BSD.root.dist" -p "${BUILD_DIRECTORY}"
mtree -deUW -f "${SOURCE_DIRECTORY}/etc/mtree/BSD.usr.dist" -p "${BUILD_DIRECTORY}/usr"
make -C "${SOURCE_DIRECTORY}/stand" clean all install DESTDIR="${BUILD_DIRECTORY}" MAKEOBJDIRPREFIX="${OBJECT_DIRECTORY}" -DWITHOUT_DEBUG_FILES -DWITHOUT_FORTH -DWITH_LOADER_LUA
# <PORTS_MODULES uses a chroot>
if [ -n "${PORTS_MODULES}" ]; then
    # TODO: it uses /usr/include/sys/param.h so this is the current kernel build system not the one we are currently building
    PATHS_TO_CHROOT="/etc /bin /libexec /lib /usr/bin /usr/lib /usr/share /usr/include /usr/local/sbin /usr/local/lib /var/run"
    for path in ${PATHS_TO_CHROOT}; do
        mkdir -p "${BUILD_DIRECTORY}/${path}"
        mount -t "nullfs" -o "ro" "${path}" "${BUILD_DIRECTORY}/${path}"
    done
fi
# </PORTS_MODULES uses a chroot>
export WITHOUT_MAN # /usr/share is read-only
make -C "${SOURCE_DIRECTORY}" buildkernel KERNCONF="${KERNCONF}" PORTS_MODULES="${PORTS_MODULES}" # MAKEOBJDIRPREFIX="${OBJECT_DIRECTORY}"
make -C "${SOURCE_DIRECTORY}" installkernel KERNCONF="${KERNCONF}" PORTS_MODULES="${PORTS_MODULES}" DESTDIR="${BUILD_DIRECTORY}" -DWITHOUT_KERNEL_SYMBOLS # MAKEOBJDIRPREFIX="${OBJECT_DIRECTORY}"
# <PORTS_MODULES uses a chroot>
if [ -n "${PORTS_MODULES}" ]; then
    for path in ${PATHS_TO_CHROOT}; do
        umount "${BUILD_DIRECTORY}/${path}"
    done
fi
# </PORTS_MODULES uses a chroot>

# TODO: /boot/device.hints ?
cp "${BASE_DIRECTORY}/boot/loader.conf" "${BUILD_DIRECTORY}/boot/"
echo "vfs.root.mountfrom=\"`df -T \"${BASE_DIRECTORY}\" | tail -n +2 | cut -wf 2`:`df \"${BASE_DIRECTORY}\" | tail -n +2 | cut -wf 1`\"" >> "${BUILD_DIRECTORY}/boot/loader.conf"

# <remove unneeded kernel modules>
eval find "${BUILD_DIRECTORY}/boot/kernel/" -name "*.ko" "${FIND_ARGUMENTS}" -delete
# </remove unneeded kernel modules>

mkdir -p "${BUILD_DIRECTORY}/etc"
cp "${BASE_DIRECTORY}/etc/fstab" "${BUILD_DIRECTORY}/etc/fstab"

makefs "${BOOTFS_OUTPUT}" "${BUILD_DIRECTORY}"
# NOTE/reminder: make clean only removes intermediary/object files (not the final "binary" files)
# rm -fr /usr/obj/usr/src/stand
BOOTFS_SIZE=`stat -f "%z" "${BOOTFS_OUTPUT}"`
BOOTFS_SIZE_PLUS_SAFETY=$((BOOTFS_EXTRA_SIZE + BOOTFS_SIZE))
make -C "${SOURCE_DIRECTORY}/stand" clean all install MD_IMAGE_SIZE=${BOOTFS_SIZE_PLUS_SAFETY} DESTDIR="${BUILD_DIRECTORY}" MAKEOBJDIRPREFIX="${OBJECT_DIRECTORY}" -DWITHOUT_DEBUG_FILES -DWITHOUT_FORTH -DWITH_LOADER_LUA

# find "${OBJECT_DIRECTORY}" -name "*.efi" -delete
cp "${BUILD_DIRECTORY}/boot/loader.efi" "${UNSIGNED_LOADER_OUTPUT}"
# cp "${UNSIGNED_LOADER_OUTPUT}" "${UNSIGNED_LOADER_OUTPUT}.before.embed_mfs"
# cp "${BOOTFS_OUTPUT}" "${BOOTFS_OUTPUT}.before.embed_mfs"
/bin/sh "${SOURCE_DIRECTORY}/sys/tools/embed_mfs.sh" "${UNSIGNED_LOADER_OUTPUT}" "${BOOTFS_OUTPUT}"

uefisign -c "${CERTIFICATE}" -k "${PRIVATE_KEY}" -o "${SIGNED_LOADER_OUTPUT}" "${UNSIGNED_LOADER_OUTPUT}"

mount -t msdosfs "/dev/${ESP_PARTITION}" "${TEMPORARY_MOUNT_POINT}"
if [ -n "${REFIND_DIRECTORY}" ]; then
    ARCHITECTURE=`uname -m`
    case "${ARCHITECTURE}" in
    amd64)
        REFIND_ARCHITECTURE_SUFFIX="x64"
        ;;
    # TODO: handle other architectures
    *)
        err "unknown/unhandled architecture ${ARCHITECTURE}"
        ;;
    esac

    if [ ! -f "${REFIND_DIRECTORY}/refind/refind_${REFIND_ARCHITECTURE_SUFFIX}.efi" ]; then
        err "'${REFIND_DIRECTORY}' is not the base directory of rEFInd"
    fi

    mkdir -p "${TEMPORARY_MOUNT_POINT}/EFI/refind/"
    cp -r "${REFIND_DIRECTORY}/refind/icons" "${TEMPORARY_MOUNT_POINT}/EFI/refind/"
    cp "${REFIND_DIRECTORY}/refind/drivers_${REFIND_ARCHITECTURE_SUFFIX}"/*.efi "${TEMPORARY_MOUNT_POINT}/EFI/refind/"
    cp "${REFIND_DIRECTORY}/refind/refind_${REFIND_ARCHITECTURE_SUFFIX}.efi" "${TEMPORARY_MOUNT_POINT}/EFI/refind/"
    # TODO: FreeBSD version (only major?)
    # TODO: add entries only if they don't already exist
    cat > "${TEMPORARY_MOUNT_POINT}/EFI/refind/refind.conf" <<"EOF"
timeout 20
showtools memtest, shutdown, reboot, exit, firmware
scanfor manual,external,optical
default_selection Windows
menuentry "Windows" {
    loader \EFI\Microsoft\Boot\bootmgfw.efi
    icon \EFI\refind\icons\os_win.png
}
menuentry "FreeBSD" {
    loader \EFI\Boot\signed-bootx64-freebsd-14.efi
    icon \EFI\refind\icons\os_freebsd.png
}
EOF
    create_entry_if_not_exists "${TEMPORARY_MOUNT_POINT}/EFI/refind/refind_${REFIND_ARCHITECTURE_SUFFIX}.efi" "rEFInd"
fi
# TODO: make FreeBSD's version dynamic (major.minor)
cp "${SIGNED_LOADER_OUTPUT}" "${TEMPORARY_MOUNT_POINT}/EFI/Boot/signed-bootx64-freebsd-14.efi"
create_entry_if_not_exists "${TEMPORARY_MOUNT_POINT}/EFI/Boot/signed-bootx64-freebsd-14.efi" "FreeBSD 14 (signed)"
sync
umount "${TEMPORARY_MOUNT_POINT}"

# <TEST>
UNAME_OUTPUT=$(/usr/obj/usr/src/`uname -p`.`uname -p`/usr.bin/uname/uname -U)
FREEBSD_MAJOR=$(( "${UNAME_OUTPUT}" / 100000 ))
FREEBSD_MINOR=$(( "${UNAME_OUTPUT}" / 1000 - "${FREEBSD_MAJOR}" * 100 ))
echo "/usr/obj compiled for FreeBSD-${FREEBSD_MAJOR}.${FREEBSD_MINOR} ?"
# </TEST>
