#!/usr/local/bin/bash
#
# zfsrestore.sh is an ugly hack used to restore a zfs file system from a set
# of saved streams.  
# Use it with extreme caution.
#
# Tristram Scott
# April 2018
DATE=/bin/date
MBUFFER=/usr/local/bin/mbuffer
ZFS=/sbin/zfs
SSH=/usr/bin/ssh

# Shouldn't need to modify below here
verstr=1.1
verb=0
port=8131
zroot=stor-pri-a
snaphost=stor-snap-01-1014
backupuser=backup
thishost=stor-pri-01-1014
fsn=
fn=/tmp/zfsr.txt
snappath=/stor-snap-01/stor-pri-02
resume=0
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
	$sfn -fpzr
	$sfn -h
	$sfn -v
        
Most flags require arguments.
        
	-f zfs filesystem name to restore
	-p port for remote (mbuffer) communication
	-z zroot the (local) root zfs file system for the restore
	-r resume.  Pick up from the last good monthly snapshot.

EOF
}

#
# Parse command line arguments
#
while getopts f:p:z:rv c
do
	case $c in
	f)	fsn=$OPTARG;;
	p)	port=$OPTARG;;
	z)	zroot=$OPTARG;;
	r)	resume=1;;
	v)	verb=1;;
	\?)     
		verb=1
		showusage
		exit 1;;
	esac
done

ruser=${backupuser}@${snaphost}
sn=x1_${fsn}
ffsn=${zroot}/${fsn}

verecho
qecho "ruser is ${ruser}\n"
qecho "zfs filesystem is ${ffsn}\n"

if [ -z "$fsn" ] ; then
	qecho "No zfs file system specified, so exiting now.\n"
	exit 1
fi

if [[ $resume -eq 0 ]] ; then 
	# Not resuming, so aim for the complete restore
	if ( $ZFS list ${ffsn} > /dev/null 2>&1 ) ; then
		qecho "Zfs file system ${ffsn} already exists, so exiting now.\n"
		exit 2
	fi
	$SSH ${ruser} "ls ${snappath}" > ${fn} 
	flist=`cat ${fn} | sed -n /^${sn}\@.*_I_.*monthly/p`
	qecho "The flist is ${flist} \n\n\n"

	fname=${sn}@Initial
	qecho "Attempting to restore using ${fname}\n"
	$SSH ${ruser} "ls -lh ${snappath}/${fname}"
	( $SSH ${ruser} "sleep 5 ; cat ${snappath}/${fname} | mbuffer -q -H -s 128k -m 1G -O ${thishost}:${port}" ) &
	mbuffer -q -H -s 128k -m 1G -4 -I ${port} | $ZFS receive -v ${ffsn} 
	sleep 5

	for fname in $flist ; do
		qecho "Attempting to restore using ${fname}"
		$SSH ${ruser} "ls -lh ${snappath}/${fname}"
		$ZFS list -tsnapshot -r ${ffsn} 
		sleep 5
		( $SSH ${ruser} "sleep 5 ; cat ${snappath}/${fname} | mbuffer -q -H -s 128k -m 1G -O ${thishost}:${port}" ) &
		mbuffer -q -H -s 128k -m 1G -4 -I ${port} | $ZFS receive -v ${ffsn} 
		sleep 5
	done
else
	# Resuming.  Try and pick up from where we are.
	lastsnap=`$ZFS list -t snapshot -o name,com.sun:auto-snapshot-label \
		-s creation -r ${ffsn} | \
		sed -n '/Initial/p ; /monthly/p' | tail -1 | \
		sed -e 's/.*@\(.*\) .*/\1/ ; s/ //g' `
	qecho "Attempting to resume.  \nLast snapshot for ${ffsn} is ${lastsnap}.\n"
	$SSH ${ruser} "ls ${snappath}" > ${fn} 
	flist=`cat ${fn} | sed -n "/${fsn}.*monthly/p ;/${fsn}.*Initial$/p"`
	qecho "The long flist is \n${flist} \n\n\n"
	if ( ! $ZFS list ${ffsn} > /dev/null 2>&1 ) ; then
		qecho "Zfs file system ${ffsn} does not already exist.  No problem...\n"
		qecho "We will use the long list as the short one.\n"
		sflist=${flist}
	else
		sflist=`cat ${fn} | sed -n "/${fsn}.*monthly/p ;/${fsn}.*Initial$/p" | sed -n "/${lastsnap}_I_/,$$p"`
	fi
	qecho "The (shorter) sflist is \n${sflist} \n\n\n"
	qecho "Beginning to process restores for the sflist at `$DATE`.\n"
	for fname in $sflist ; do
		qecho "Attempting to restore using ${fname} at `$DATE`.\n"
		qecho "We are currently here:\n"
		$ZFS list -tsnapshot -r ${ffsn} | tail -2
		$SSH ${ruser} "ls -lh ${snappath}/${fname}"

		sleep 2
		( $SSH ${ruser} "sleep 5 ; cat ${snappath}/${fname} | mbuffer -q -H -s 128k -m 1G -O ${thishost}:${port}" ) &
		mbuffer -q -H -s 128k -m 1G -4 -I ${port} | $ZFS receive -v ${ffsn} 
		sleep 5
		qecho "Finished restoring from ${fname} at `$DATE`.\n"
	done
	qecho "Finished processing all restores for the sflist at `$DATE`.\n"
fi
qecho "All finished at `$DATE`.\n"

