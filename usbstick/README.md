FreeBSD run from a (customized) USB stick (built from sources - /usr/src)

Any package can be added at any time: `_mount && pkg -c "${MOUNTPOINT}" install <list of packages>`

Create your system: `stick.sh --create -d da0 -m /mnt` \*
Upgrade your system: `stick.sh --upgrade -d da0 -m /mnt` \*
Get a chrooted shell into this subsystem: `stick.sh --shell -d da0 -m /mnt` \*

\* with your stick as /dev/da0 and mounted on /mnt

Disclaimer:
* I decline all responsabilities of the usage made of this tool, there is no warranty
* UEFI not tested
* FreeBSD does not (yet) support UEFI with secure boot enabled
* the script have to be run as root

Credits:
* http://www.wonkity.com/~wblock/docs/html/disksetup.html

TODO:
* add swap?
* generates a resolv.conf or enable and configure unbound
