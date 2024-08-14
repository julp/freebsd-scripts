# Create a dual "secure" boot Windows/FreeBSD

This is not about security but how to create a dual boot and make Windows >= 11 happy.

## Requirements

* an EFI partition of at least 300 Mio (per FreeBSD loader)
* FreeBSD sources installed on /usr/src

## Before usage

Download sources, one way:

```
git clone https://github.com/julp/freebsd-scripts.git
```

Before the first run, generate your certificates + private key by executing:

```
/bin/sh /usr/share/examples/uefisign/uefikeys MOK
```

(backup the files MOK.{cer,pem,key} somewhere)

## With rEFInd (only once/the first time)

[Download and unzip rEFInd](https://www.rodsbooks.com/refind/getting.html)

```
# as root
freebsd-scripts/secure_boot/secure_boot.sh --cert=MOK.pem --key=MOK.key --refind=path/to/the/unzipped/rEFInd/binary/zip/file
```

Then, in your BIOS, register both MOK.cer and keys/refind.cer from previously unziped rEFInd directory

## Without rEFInd

```
# as root
freebsd-scripts/secure_boot/secure_boot.sh --cert=MOK.pem --key=MOK.key
```

Then, in your BIOS, register MOK.cer

## Tested configurations

* EVGA Z370 FTW: Windows 10/FreeBSD 13.[12] (without rEFInd - it was already setup)
* MSI Z690 Unify-X: Windows 11/FreeBSD 13.2/14.[01] (without rEFInd - it was already setup)

## Importants notes

* I highly suggest to run this script before `make installkernel` when performing a system upgrade else /usr/obj might be recompiled from the upgraded world and you won't be able to reuse /usr/obj to upgrade an other system
* prefer loading modules from /etc/rc.conf (`kld_list="space-separated list of module names to be loaded"`) instead of /boot/loader.conf (when possible)

## TODO

* remove unused modules
* preserve the BE menu at FreeBSD boot menu (`currdev` ? `rootdev` ?)

## Credits

* https://freebsdfoundation.org/freebsd-uefi-secure-boot/
