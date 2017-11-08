#!/usr/bin/env bash
#
# zfs-pg-snap.sh
# 
# A wrapper script which facilitates using zfs to snapshot a PostgreSQL 
# database.

pguser=postgres
datafs=
archivefs=
label=frequent
keep=4

logfile=
verstr=1.0
DATE=/bin/date
ZFSAUTOSNAP=/usr/local/src/zfs-auto-snapshot/src/zfs-auto-snapshot.sh

#
# Shouldn't need to modify below here
#
sfn=${0##*/} # Short version of our filename
verb=0
showhelp=0
dryrun=0



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
        $sfn -lkdauonqv
        $sfn -h
        $sfn -V
        
Most flags require arguments.
        
        -l snapshot label, e.g. frequent, hourly, daily, weekly, monthly.
		-k Keep NUM recent snapshots and destroy older snapshots.
        -d PostgreSQL data zfs file system
        -a PostgreSQL archive zfs file system
        -u username for the postgres user.  Default is postgres.
        -o logfile
        -n dry run.  Print actions without actually doing anything.
        -h Show detailed usage.
        -q Quiet (default) or 
        -v verbose
        -V Print the version number and then exit.
        
EOF

if [ $showhelp -eq 1 ] ; then

cat << EOF
Examples: 

1. Make an hourly snapshot as the user postgres, with the
data and archive directories under /dataPool/postgresql/10.0.

        $sfn -l hourly -k 24 -d dataPool/postgresql/10.0/data \\
        -a dataPool/postgresql/10.0/archive \\
        -u postgres

2. As before, but as a dry run omly, and with verbose logging to a file.

        $sfn -l hourly -k 24 -d dataPool/postgresql/10.0/data \\
        -a dataPool/postgresql/10.0/archive \\
        -u postgres -n -v -o /var/log/zfs-pg-snap.log
EOF

fi
}


#
# Parse command line arguments
#
while getopts l:k:d:a:u:o:nvVh c
do
        case $c in
        l)      label=$OPTARG;;
        k)      keep=$OPTARG;;
        d)      datafs=$OPTARG;;
        a)      archivefs=$OPTARG;;
		u)		pguser=$OPTARG;;
		o)		logfile=$OPTARG;;
		n)		dryrun=1;;
        v)		verb=1;;
        V)      
                verb=1
                verecho
                exit 0;;
        h)      
				verb=1
                showhelp=1
                showusage
                exit 0;;
        \?)     
                verb=1
                showusage
                exit 0;;
        esac
done

#
# Announce ourselves
#
verecho

#
# Report settings
#
qecho "pguser: \t$pguser\n"
qecho "datafs:   \t$datafs\n"
qecho "archivefs: \t$archivefs\n"
qecho "label:   \t$label\n"
qecho "keep:   \t$keep\n"
qecho "logfile:   \t$logfile\n"

if [ $dryrun -eq 1 ] ; then
	qecho "Dry run selected.  No commands will be executed.\n"
fi

qecho "\n\n"

if [ -z "$datafs" ] ; then
	qecho "No data file system specified, so exiting now.\n"
	exit 1
fi
if [ -z "$archivefs" ] ; then
	qecho "No archive file system specified, so exiting now.\n"
	exit 1
fi

if [ $dryrun -eq 1 ] ; then
	qecho "sudo -u $pguser " 'psql -c "select pg_start_backup('zfs-pg-snap');"\n'
	qecho "$ZFSAUTOSNAP -l $label -k $keep $datafs\n"
	qecho "sudo -u $pguser " 'psql -c "select pg_stop_backup();"\n'
	qecho "$ZFSAUTOSNAP -l $label -k $keep $archivefs\n"
else
	qecho "sudo -u $pguser " 'psql -c "select pg_start_backup('zfs-pg-snap');"\n'
	qecho `sudo -u $pguser psql -c "select pg_start_backup('zfs-pg-snap');"` "\n"
	qecho "$ZFSAUTOSNAP -l $label -k $keep $datafs\n"
	$ZFSAUTOSNAP -l $label -k $keep $datafs
	qecho "sudo -u $pguser " 'psql -c "select pg_stop_backup();"\n'
	qecho `sudo -u $pguser psql -c "select pg_stop_backup();"` "\n"
	qecho "$ZFSAUTOSNAP -l $label -k $keep $archivefs\n"
	$ZFSAUTOSNAP -l $label -k $keep $archivefs
fi


qecho "`$DATE`: Exiting.\n"

