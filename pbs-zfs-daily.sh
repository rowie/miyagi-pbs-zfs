#!/bin/bash
set -o allexport
source /root/scripts/.env set

# Requirements for Myiagi ultimate Backup
#  Proxmox Source Host:
#    - only daily Autosnapshots
#    - pub ssh key from Proxmox Destination Host in the ./ssh/authorized_keys file
#    - running check_mk Agent 



###################################
## Warm-up & Preparing the Host ##
#################################

# Install Requiered Bashclub CheckZFS
wget -q --no-cache -O /usr/local/bin/checkzfs https://raw.githubusercontent.com/bashclub/check-zfs-replication/main/checkzfs.py
chmod +x /usr/local/bin/checkzfs

# Install Requiered Bashclub Zsync
wget -q --no-cache -O /usr/local/bin/bashclub-zsync https://git.bashclub.org/bashclub/zsync/raw/branch/dev/bashclub-zsync/usr/bin/bashclub-zsync
chmod +x /usr/local/bin/bashclub-zsync


#Disable ZFS Auto Snapshot on Destination
zfs set com.sun:auto-snapshot=false $ZFSTRGT

#Mark Source for full Backup with Zsync
ssh root@$SOURCEHOST zfs set $ZPUSHTAG=all $ZFSROOT
ssh root@$SOURCEHOST zfs set $ZPUSHTAG=all $ZFSSECOND

# Loop for Excludes and create the zsync config
echo "target=$ZFSTRGT" > /etc/bashclub/$SOURCEHOST.conf
echo "source=root@$SOURCEHOST" >> /etc/bashclub/$SOURCEHOST.conf
echo "sshport=$SSHPORT" >> /etc/bashclub/$SOURCEHOST.conf
echo "tag=$ZPUSHTAG" >> /etc/bashclub/$SOURCEHOST.conf
echo "snapshot_filter=\"$ZPUSHFILTER\"" >> /etc/bashclub/$SOURCEHOST.conf
echo "min_keep=$ZPUSHMINKEEP" >> /etc/bashclub/$SOURCEHOST.conf
echo "zfs_auto_snapshot_keep=$ZPUSHKEEP" >> /etc/bashclub/$SOURCEHOST.conf
echo "zfs_auto_snapshot_label=$ZPUSHLABEL" >> /etc/bashclub/$SOURCEHOST.conf



#################################
## Pulling Snapshots from PVE ##
###############################

# Let the magic happend !!! 
/usr/bin/bashclub-zsync -d -c /etc/bashclub/$SOURCEHOST.conf


# create reports and push it to check_mk
# Remember: One Day has 1440 Minutes, so we go condition Yellow on 1500
/usr/local/bin/checkzfs --source $SOURCEHOST --replicafilter "$ZFSTRGT/" --filter "#$ZFSROOT/|#$ZFSSECOND/" --threshold 1500,2000 --output checkmk --prefix pull-$(hostname):$ZPUSHTAG> /tmp/cmk_tmp.out && ( echo "<<<local>>>" ; cat /tmp/cmk_tmp.out ) > /tmp/90000_checkzfs

scp /tmp/90000_checkzfs $SOURCEHOST:/var/lib/check_mk_agent/spool/90000_checkzfs_$(hostname)-${ZPOOLSRC}



###################
## Maintainance ##
#################

# check, if Maintenance Day !!

   if [ $(date +%u) == $MAINTDAY ]; then 
	echo "MAINTENANCE"

    	ssh root@$PBSHOST proxmox-backup-manager garbage-collection start $BACKUPSTOREPBS
    	ssh root@$PBSHOST proxmox-backup-manager prune-job run $PRUNEJOB
	#optional delete all zfs-auto-snapshots   
 	ssh root@$PBSHOST proxmox-backup-manager verify backup

else
    echo "Today no Maintenance"
fi

# stop SCRUB on TARGET and SOURCE POOL
ssh root@$SOURCEHOST zpool scrub -s $ZPOOLSRC
zpool scrub -s $ZPOOLDST




#############################
## Create Backup with PBS ##
###########################

# enable PBS Backup Store on Proxmox Source Host
ssh root@$SOURCEHOST pvesm set $BACKUPSTORE --disable 0

# Start PBS Backup Job
# Rembeber: one Day has 86400 Seconds, so we going Condition grey if no new Status File will be pushed
ssh root@$SOURCEHOST vzdump --node $SOURCEHOSTNAME --storage $BACKUPSTORE --exclude  $BACKUPEXCLUDE --mode snapshot --all 1 --notes-template '{{guestname}}' 

if [ $? -eq 0 ]; then
    echo command returned 0 is good
    echo 0 "DailyPBS" - Daily Backup  > /tmp/cmk_tmp.out && ( echo "<<<local>>>" ; cat /tmp/cmk_tmp.out ) > /tmp/90000_checkpbs
else
    echo command returned other not good
    echo 2 "DailyPBS" - Daily Backup  > /tmp/cmk_tmp.out && ( echo "<<<local>>>" ; cat /tmp/cmk_tmp.out ) > /tmp/90000_checkpbs

fi

# push it to check_mk
scp  /tmp/90000_checkpbs  root@$SOURCEHOST:/var/lib/check_mk_agent/spool

# disable PBS Backup Store on Proxmox Source Host
ssh root@$SOURCEHOST pvesm set $BACKUPSTORE --disable 1

# protect all "Datasets/ZVOLs" except the Replicas with a daily Snapshot
/etc/cron.daily/zfs-auto-snapshot 

# doing updates without regeret
apt update && apt dist-upgrade -y
