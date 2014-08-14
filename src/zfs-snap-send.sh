#!/usr/bin/env bash
#
# zfs-snap-send.sh
# 
# This is a script to handle the sending of zfs snapshots to a remote
# server.  It expects a naming scheme based on that used by the
# zfs-auto-snapshot.sh script.
#
# The snapshots should be named:
# filesystemname@zfs-auto-snap_YYYY-MM-DD-HHMM
# As well, they should have the com.sun:auto-snapshot-label property set
# to one of frequent, hourly, daily, weekly, monthly.
#
# Default action is to send an incremental stream, relative to the most 
# recent prior snapshot of a higher level.

ZFS=/sbin/zfs
SCP=/usr/bin/scp
SSH=/usr/bin/ssh
DATE=/bin/date
MBUFFER=/usr/local/bin/mbuffer
ZFSAUTOSNAP=/usr/local/src/zfs-auto-snapshot/src/zfs-auto-snapshot.sh


snaphost=stor-snap-02
backupuser=backup
snap1=
snapdir=/x1/`hostname -s`
logfile=
timestamp=`hostname -s`
rootdir=
mntpoint=
verstr=1.0
#
# Shouldn't need to modify below here
#
sfn=${0##*/} # Short version of our filename
verb=0
showhelp=0
sleeptime=120
maxit=1000000
eqeq='==========\n'
plpl='++++++++++\n'
#
# qecho Echoes argument if verbose mode is on.
# Also writes to logfile.
#
qecho() {
if [ $verb -ne 0 ] ; then
printf '%b' "$@"
fi
if [ $logfile ] ; then
printf '%b' "$@"  >> $logfile
fi
}

#
# verecho       Echoes version string.
#
verecho() {

qecho "\nThis is $0, $verstr\nStarting at `$DATE`\n"  
}

#
# showusage     Command line help message
#
showusage() {

verecho
cat << EOF
Usage: \
        $sfn -rkzpdlsxqu
        $sfn -h
        $sfn -v
        
Most flags require arguments.
        
        -r rootdir for dump streams. e.g. -r /x1/`hostname -s`
        -k timestampfile. e.g. -k `hostname -s`
        -z zfs snapshot to send. e.g. -z filesystemname@zfs-auto-snap_YYYY-MM-DD-HHMM
           The -z argument may be specified multiple times.
        -p root zfs filesystem e.g. zbackup/clones/
           Specify either -z or -p but not both.
        -d snaphost.  e.g. -d stor-snap-02
        -u username on snaphost.  Required for running remote end of mbuffer.
        -l Logfile. e.g. -l /var/log/zfssnapsend.log
        -s Loop sleep time, in seconds. e.g. -s 600
        -x Maximum number of iterations. e.g. -x 5
        -q Quiet (default) or verbose
        -h Show detailed usage.
        -v Print the version number and then exit.
        
EOF

if [ $showhelp -eq 1 ] ; then

cat << EOF
Examples: 

Send the incremental stream for the snapshot 
x1/junk@zfs-auto-snap_2014-08-02-0007 to the remote host stor-snap-02, 
logging to /var/log/zfssnapsend.log

        $sfn -d stor-snap-02 -m /mnt/stor-snap-02 -r /x1/`hostname -s`\\
        -z x1/junk@zfs-auto-snap_2014-08-02-0007 \\
        -k `hostname -s` -l /var/log/zfssnapsend.log
        
EOF

fi
}

#
# find_previous snapname
# Find the previous snapshot of lower level than the specified one.
# The result is left in the variable $lastsnap.
#
find_previous() {
	lastsnap=
	sn=$1
	if [ -z $sn ] ; then
		qecho "Warning: no snapshot specified to find_previous.\n"
		return
	fi
	# sn2 has forward slashes replaced by full stops, so we don't break sed.
	sn2=`echo $sn | sed -e 's@/@.@g'`
	# zn is the zfs filesytem name, taken as everything before the @.
	zn=`echo $sn | sed -e 's/@.*//'`
	# Find the snapshot label for $sn
	snaptype=`$ZFS list -o com.sun:auto-snapshot-label -H $sn`
	# Construct a sed filter to consider only higher level snapshots.
	# This would be greatly simplified if we used numbers rather than text labels.
	# E.g. we could work in the way of dump etc., level 0, level 1 etc.
	# But, we don't, so this will do for now.
	# Note: Monthly snapshots will send incremental from the most recent monthly.
	case $snaptype in
		frequent)	sf='/hourly$/p ; /daily$/p ; /weekly$/p ; /monthly$/p ; /@Initial/p';;
		hourly)		sf='/daily$/p ; /weekly$/p ; /monthly$/p ; /@Initial/p';;
		daily)		sf='/weekly$/p ; /monthly$/p ; /@Initial/p';;
		weekly)		sf='/monthly$/p ; /@Initial/p';;
		monthly)	sf='/monthly$/p ; /@Initial/p';;	
	esac
	lastsnap=`$ZFS list -t snapshot -o name,com.sun:auto-snapshot-label -H -r $zn \
		| sed -n "/Initial/,/$sn2/p" | sed -e "/$sn2/d" | sed -n "$sf" | tail -1 \
		| cut -f 1 -w | sed -e 's/.*@/@/' `
}

#
# find_unsent zdir
# Find snapshots more recent than the last timestamp.
# This relies on taking a zfs-auto-snapshot with a label of timestamp
#
find_unsent() {
	# zd1 should be a simple zfs filesystem name, e.g. x1/tsdspace
	zd1=$1
	unsent=`$ZFS list -t snapshot -o name,com.sun:auto-snapshot-label -H -r $zd1 \
	| sed -n '/timestamp$/,/timestamp$/p' | sed -e '/timestamp$/d ; /-$/d' | cut -f 1 -w `
}

#
# send_snap snapname
# Send the specified snapshot to $snaphost 
#
send_snap() {
	snapn=$1
	if [ -z $snapn ] ; then
		qecho "Warning: no snapshot specified to send_snap.\n"
		return
	fi
	zd2=$2
	if [ -z $zd2 ] ; then
		zd2=`echo $snapn | sed -e 's/@.*//'`
		qecho "Warning: no zdir specified to send_snap, so using derived name of $zd2.\n"
	fi
	find_previous $snapn
	if [ -z $lastsnap ] ; then
		qecho "Warning: No previous snapshot found for $snapn.\n"
		qecho "This will require manual intervention to fix.\n"
		break
	fi
	sn2s=`echo $snapn | sed -e 's/.*@/@/'`
	qecho "Labelled as $snaptype ...\n"
	qecho "Lastsnap is $lastsnap.\n"
	# uzdir has the forward slashes replaced by undersacores, and the 
	# trailing underscore (if any) removed.
	uzdir=`echo $zd2 | sed -e "s/\//_/g" | sed -e "s/_$//"`
	fn=${uzdir}${lastsnap}_I_${sn2s}_${snaptype}
	qecho "Send stream will go to $fn\n"
	# We sleep 5 seconds to allow the receive mbuffer to start on $snaphost
	( sleep 5 ;	$ZFS send -R -i $lastsnap $snapn | mbuffer -q -s 128k -m 1G -O ${snaphost}:9090 ) &
	# Start the receive mbuffer on $snaphost
	qecho "Starting receive on $snaphost.\n"
	$SSH $ruser "mbuffer -q -s128k -m 1G -4 -I 9090 -o $snapdir/$fn " 
}

#
# Parse command line arguments
#
while getopts r:z:p:l:s:x:d:k:vVhq c
do
        case $c in
        l)      logfile=$OPTARG;;
        r)      snapdir=$OPTARG;;
        k)      timestamp=$OPTARG;;
        p)      zroot=$OPTARG;;
		d)		snaphost=$OPTARG;;
        z)      snap1="$snap1$OPTARG ";;
        s)      sleeptime=$OPTARG;;
        x)      maxit=$OPTARG;;
        v)		verb=1;;
        V)      
                verb=1
                verecho
                exit 1;;
        h)      
                showhelp=1
                showusage
                exit 1;;
        \?)     
                showusage
                exit 1;;
        esac
done


updated=$snapdir/updated
received=$snapdir/$timestamp
ruser=${backupuser}@${snaphost}

if [ $verb -ne 0 ] ; then
        ZFSR="$ZFS receive -vF "
else
        ZFSR="$ZFS receive -F "
fi


#
# Announce ourselves
#
verecho

#
# Report settings
#
qecho "snapdir: \t$snapdir\n"
qecho "snap1:   \t$snap1\n"
qecho "sleeptime: \t$sleeptime\n"
qecho "maxit:   \t$maxit\n"
qecho "received: \t$received\n"
qecho "updated: \t$updated\n"
qecho "zroot:   \t$zroot\n"
qecho "backupuser: \t$backupuser\n"
qecho "ruser: \t$ruser\n"


if [ ! -z $zroot ] ; then
	qecho "Zfs file system specified, so ignoring any specified snapshot names.\n"
	snap1=
fi


for snap in $snap1 ; do 
	qecho "Working on snapshot $snap1\n"
	send_snap $snap
done

if [ -z $zroot ] ; then
	qecho "No zfs file system specified, so exiting now.\n"
	exit 0
fi

k=0
while [ $k -lt $maxit ]
do
	qecho "$eqeq`$DATE`: Beginning iteration $k of $maxit.\n\n"
	for zdir1 in $zroot ; do
		qecho "Considering filesystem $zdir1.\n"
		qecho "Updating timestamp snapshot for $zdir1.\n"
		$ZFSAUTOSNAP -q -k 2 --default-exclude -l timestamp $zdir1
		find_unsent $zdir1
		for snap2 in $unsent ; do
			qecho "Looking at snapshot $snap2 ...\n"
			send_snap $snap2 $zdir1
		done
	done
	qecho "Updating timestamp file.\n"
	$SSH $ruser "touch $received"
	qecho "$eqeq`$DATE`: End of iteration $k of $maxit.  Sleeping for $sleeptime.\n\n"
	sleep $sleeptime
    k=$(($k+1))
done


exit

if [[ ! $k -lt $maxit ]] ;
then
        qecho "Maximum iteration count reached."
fi

qecho "`$DATE`: Exiting."

