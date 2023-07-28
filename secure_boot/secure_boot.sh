#!/bin/sh -e

# mountpoint used to mount the ESP partition
readonly TEMPORARY_MOUNT_POINT="/mnt"
# the (temporary - can be deleted afterwards) directory used to copy/build all we need
readonly BASE_DIR="/tmp/bootfs"
# the subdirectory used to build the MFS image
readonly BUILD_DIR="${BASE_DIR}/build"
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
BASE_DIRECTORY=""

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
    exit 2
}

newopts=""
for var in "$@" ; do
    case "$var" in
    --base=*)
        BASE_DIRECTORY="${var#--base=}"
        ;;
    --cert=*)
        CERTIFICATE="${var#--cert=}"
        ;;
    --esp=*)
        ESP_PARTITION="${var#--esp=}"
        ;;
    --key=*)
        PRIVATE_KEY="${var#--key=}"
        ;;
    --refind=*)
        REFIND_DIRECTORY="${var#--refind=}"
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

while getopts 'b:c:k:e:' COMMAND_LINE_ARGUMENT; do
    case "${COMMAND_LINE_ARGUMENT}" in
    b)
        BASE_DIRECTORY="${OPTARG}"
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

mkdir -p "${BUILD_DIR}/boot"
cp -r "${BASE_DIRECTORY}/boot/kernel" "${BUILD_DIR}/boot"
# TODO: we don't need both, the old Forth loader (likely retired soon) and the new written in Lua
cp "${BASE_DIRECTORY}/boot"/*.4th "${BUILD_DIR}/boot"
cp -r "${BASE_DIRECTORY}/boot/lua" "${BUILD_DIR}/boot"
cp -r "${BASE_DIRECTORY}/boot/defaults" "${BUILD_DIR}/boot"
cp "${BASE_DIRECTORY}/boot/loader.conf" "${BUILD_DIR}/boot"
cp "${BASE_DIRECTORY}/boot"/*.rc "${BUILD_DIR}/boot"
cp "${BASE_DIRECTORY}/boot/device.hints" "${BUILD_DIR}/boot"
#cp "${BASE_DIRECTORY}/boot/loader.help" "${BUILD_DIR}/boot" # this file doesn't exist anymore?
echo "vfs.root.mountfrom=\"`df -T \"${BASE_DIRECTORY}\" | tail -n +2 | cut -wf 2`:`df \"${BASE_DIRECTORY}\" | tail -n +2 | cut -wf 1`\"" >> "${BUILD_DIR}/boot/loader.conf"

mkdir -p "${BUILD_DIR}/etc"
cp "${BASE_DIRECTORY}/etc/fstab" "${BUILD_DIR}/etc/fstab"

makefs "${BOOTFS_OUTPUT}" "${BUILD_DIR}"
BOOTFS_SIZE=`stat -f "%z" "${BOOTFS_OUTPUT}"`
BOOTFS_SIZE_PLUS_SAFETY=$((BOOTFS_EXTRA_SIZE + BOOTFS_SIZE))
make -C /usr/src/stand MD_IMAGE_SIZE=${BOOTFS_SIZE_PLUS_SAFETY}
# NOTE: it seems, to me, that's not /usr/src/stand/Makefile who build/creates loader.efi but /usr/src/release/Makefile
make -C /usr/src/release NOPORTS=YES NOSRC=YES NODOC=YES WITHOUT_DEBUG_FILES=YES MD_IMAGE_SIZE=${BOOTFS_SIZE_PLUS_SAFETY} base.txz

# find /usr/obj/ -name "*.efi" -delete
cp /usr/obj/usr/src/amd64.amd64/release/dist/base/boot/loader.efi "${UNSIGNED_LOADER_OUTPUT}"
# cp "${UNSIGNED_LOADER_OUTPUT}" "${UNSIGNED_LOADER_OUTPUT}.before.embed_mfs"
# cp "${BOOTFS_OUTPUT}" "${BOOTFS_OUTPUT}.before.embed_mfs"
/bin/sh /usr/src/sys/tools/embed_mfs.sh "${UNSIGNED_LOADER_OUTPUT}" "${BOOTFS_OUTPUT}"

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
    loader \EFI\Boot\signed-bootx64-freebsd-13.efi
    icon \EFI\refind\icons\os_freebsd.png
}
EOF
    efibootmgr -a -c -l "${TEMPORARY_MOUNT_POINT}/EFI/refind/refind_${REFIND_ARCHITECTURE_SUFFIX}.efi" -L "rEFInd"
fi
cp "${SIGNED_LOADER_OUTPUT}" "${TEMPORARY_MOUNT_POINT}/EFI/Boot/signed-bootx64-freebsd-13.efi"
efibootmgr -a -c -l "${TEMPORARY_MOUNT_POINT}/EFI/Boot/signed-bootx64-freebsd-13.efi" -L "FreeBSD 13 (signed)"
sync
umount "${TEMPORARY_MOUNT_POINT}"
