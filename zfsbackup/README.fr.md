zfsbackup: sauvegarde/copie d'un système de fichiers ZFS sur une autre zpool, locale ou distante

En termes simples : le but est d'effectuer une copie (incrémentale) d'un système de fichiers ZFS de base (vos home par exemple) sur un disque dur dédié, qui peut être branché (hotplug) sur la même machine (votre serveur) comme une autre

* Initialisation du disque de sauvegarde :
	1. créer un système de fichiers ZFS (`zpool create -m none -R /backup backup da0` - remplacer da0 par le nom de votre disque)
	2. le mettre en lecture seule de façon à ce que vous ne l'altériez pas et reste une copie conforme (`zfs set readonly=on backup`)
	3. exporter le disque (`zpool export backup`)
* Procédure de sauvegarde :
	1. brancher le disque
	2. l'importer (`zpool import -R /backup backup`)
	3. lancer la copie/zfsbackup.sh
	4. l'exporter (`zpool export backup`)
	5. débrancher le disque

Ce "disque dur de sauvegarde" peut en réalité être un système secondaire dont le système de fichiers ZFS peut être constitué de plusieurs disques (d'un RAID1 à RAIDZ3). Auquel cas, bien sûr, (dé)brancher ne s'appliquent plus et les étapes d'initialisation.

Paramètres de configuration à définir dans /usr/local/etc/zfsbackup.conf:
* LOCAL_POOL_NAME (par défaut, elle est devinée par la commande `zfs get -H -o value name / | cut -d / -f 1`): le nom de la zpool à envoyer/sauvegarder
* REMOTE_POOL_NAME (valeur par défaut : 'backup'): le nom de la zpool qui reçoit la sauvegarde
* REMOTE_HOST (valeur par défaut : ''): le nom ou l'adresse de la machine recevant la sauvegarde (laisser vide si l'opération est réalisée depuis le même système)
* REMOTE_USER (valeur par défaut : ''): nom d'utilisateur sur la machine distante (si besoin/différent)
