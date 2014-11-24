#!/usr/bin/env bash

PROGRAM="Osync-batch" # Batch program to run osync instances sequentially and rerun failed ones
AUTHOR="(L) 2013-2014 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_BUILD=2411201401

## Runs an osync instance for every conf file found
## If an instance fails, run it again if time permits

## Configuration file path. The path where all the osync conf files are, usually /etc/osync
CONF_FILE_PATH=/etc/osync

## If maximum execution time is not reached, failed instances will be rerun. Max exec time is in seconds. Example is set to 10 hours.
MAX_EXECUTION_TIME=36000

## Max retries specifies the number of reruns an instance may get
MAX_RETRIES=36000


## Osync executable full path can be set here if it cannot be found on the system
if ! type -p osync.sh > /dev/null 2>&1
then
	OSYNC_EXECUTABLE=osync.sh
else
	OSYNC_EXECUTABLE=$(type -p osync.sh)
fi

## Log file path
if [ -w /var/log ]
then
        LOG_FILE=/var/log/osync-batch.log
else
        LOG_FILE=./osync-batch.log
fi

# No need to edit under this line ##############################################################

function Log
{
        prefix="TIME: $SECONDS - "
        echo -e "$prefix$1" >> "$LOG_FILE"

        if [ $silent -eq 0 ]
        then
                echo -e "$prefix$1"
        fi
}


function Batch
{
	## Get list of .conf files
	for i in $(ls $CONF_FILE_PATH/*.conf)
	do
		if [ "$RUN" == "" ]
		then
			RUN="$i"
		else
			RUN=$RUN" $i"
		fi
	done 

	RETRIES=0
	while [ $MAX_EXECUTION_TIME -gt $SECONDS ] && [ "$RUN" != "" ] && [ $MAX_RETRIES -gt $RETRIES ]
	do
		Log "Osync instances will be run for: $RUN" 
		for i in $RUN
		do
			$OSYNC_EXECUTABLE $i --silent
			if [ $? != 0 ]
			then
				Log "Run instance $(basename $i) failed"
				if [ "RUN_AGAIN" == "" ]
				then
					RUN_AGAIN="$i"
				else
					RUN_AGAIN=$RUN_AGAIN" $i"
				fi
			else
				Log "Run instance $(basename $i) succeed."
			fi
		done
		RUN="$RUN_AGAIN"
		RUN_AGAIN=""
		RETRIES=$(($RETRIES + 1))
	done
}

silent=0
for i in "$@"
do
        case $i in
                --silent)
                silent=1
                ;;
	esac
done

Log "$(date) Osync batch run"
Batch

