# Create a dual "secure" boot Windows/FreeBSD

## Requisites

* an EFI partition of at least 300 Mio
* FreeBSD sources installed on /usr/src

## 

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
freebsd-scripts/secure_boot/secure_boot.sh --cert=MOK.pem --key=MOK.key --refind=path/to/refind/sources
```

Then, in your BIOS, register both MOK.cer and keys/refind.cer from previously unziped rEFInd directory

## Without rEFInd

```
# as root
freebsd-scripts/secure_boot/secure_boot.sh --cert=MOK.pem --key=MOK.key
```

Then, in your BIOS, register MOK.cer

## Tested configurations

* EVGA Z370 FTW: Windows 10/FreeBSD 13.1

## Credits

* https://freebsdfoundation.org/freebsd-uefi-secure-boot/
