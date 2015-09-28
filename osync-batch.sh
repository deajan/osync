#!/usr/bin/env bash

PROGRAM="Osync-batch" # Batch program to run osync instances sequentially and rerun failed ones
AUTHOR="(L) 2013-2014 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_BUILD=2015092801

## Runs an osync instance for every conf file found
## If an instance fails, run it again if time permits

## Configuration file path. The path where all the osync conf files are, usually /etc/osync
CONF_FILE_PATH=/etc/osync

## If maximum execution time is not reached, failed instances will be rerun. Max exec time is in seconds. Example is set to 10 hours.
MAX_EXECUTION_TIME=36000

## Specifies the number of reruns an instance may get
MAX_RERUNS=3

## Log file path
if [ -w /var/log ]; then
	LOG_FILE=/var/log/osync-batch.log
else
	LOG_FILE=./osync-batch.log
fi

# No need to edit under this line ##############################################################

function _logger {
	local value="${1}" # What to log
	echo -e "$value" >> "$LOG_FILE"

	if [ $silent -eq 0 ]; then
		echo -e "$value"
	fi
}

function Logger {
	local value="${1}" # What to log
	local level="${2}" # Log level: DEBUG, NOTICE, WARN, ERROR, CRITIAL

	# Special case in daemon mode we should timestamp instead of counting seconds
	if [ $sync_on_changes -eq 1 ]; then
		prefix="$(date) - "
	else
		prefix="TIME: $SECONDS - "
	fi

	if [ "$level" == "CRITICAL" ]; then
		_logger "$prefix\e[41m$value\e[0m"
		ERROR_ALERT=1
	elif [ "$level" == "ERROR" ]; then
		_logger "$prefix\e[91m$value\e[0m"
		ERROR_ALERT=1
	elif [ "$level" == "WARN" ]; then
		_logger "$prefix\e[93m$value\e[0m"
	elif [ "$level" == "NOTICE" ]; then
		_logger "$prefix$value"
	elif [ "$level" == "DEBUG" ]; then
		if [ "$DEBUG" == "yes" ]; then
			_logger "$prefix$value"
		fi
	else
		_logger "\e[41mLogger function called without proper loglevel.\e[0m"
		_logger "$prefix$value"
	fi
}

function CheckEnvironment {
	## Osync executable full path can be set here if it cannot be found on the system
	if ! type -p osync.sh > /dev/null 2>&1
	then
		if [ -f /usr/local/bin/osync.sh ]
		then
			OSYNC_EXECUTABLE=/usr/local/bin/osync.sh
		else
			Logger "Could not find osync.sh" "CRITICAL"
			exit 1
		fi
	else
		OSYNC_EXECUTABLE=$(type -p osync.sh)
	fi

	## Check for CONF_FILE_PATH
	if [ ! -d "$CONF_FILE_PATH" ]; then
		Logger "Cannot find conf file path $CONF_FILE_PATH" "CRITICAL"
		Usage
	fi
}

function Batch {
	## Get list of .conf files
	for i in $(ls $CONF_FILE_PATH/*.conf)
	do
		if [ "$RUN" == "" ]; then
			RUN="$i"
		else
			RUN=$RUN" $i"
		fi
	done

	RERUNS=0
	while ([ $MAX_EXECUTION_TIME -gt $SECONDS ] || [ $MAX_EXECUTION_TIME -eq 0 ]) && [ "$RUN" != "" ] && [ $MAX_RERUNS -gt $RERUNS ]
	do
		Logger "Osync instances will be run for: $RUN" "NOTICE"
		for i in $RUN
		do
			$OSYNC_EXECUTABLE "$i" $opts
			if [ $? != 0 ]; then
				Logger "Run instance $(basename $i) failed" "ERROR"
				if [ "RUN_AGAIN" == "" ]; then
					RUN_AGAIN="$i"
				else
					RUN_AGAIN=$RUN_AGAIN" $i"
				fi
			else
				Logger "Run instance $(basename $i) succeed." "NOTICE"
			fi
		done
		RUN="$RUN_AGAIN"
		RUN_AGAIN=""
		RERUNS=$(($RERUNS + 1))
	done
}

function Usage {
	echo "$PROGRAM $PROGRAM_BUILD"
	echo $AUTHOR
	echo $CONTACT
	echo ""
	echo "Batch script to sequentially run osync instances and rerun failed ones."
	echo "Usage: osync-batch.sh [OPTIONS]"
	echo ""
	echo "[OPTIONS]"
	echo "--path=/path/to/conf      Path to osync conf files, defaults to /etc/osync"
	echo "--max-reruns=X            Number of runs  max for failed instances, (defaults to 3)"
	echo "--max-exec-time=X         Retry failed instances only if max execution time not reached (defaults to 36000 seconds). Set to 0 to bypass execution time check."
	echo "--no-maxtime		Run osync without honoring conf file defined timeouts"
	echo "--dry                     Will run osync without actually doing anything; just testing"
	echo "--silent                  Will run osync without any output to stdout, used for cron jobs"
	echo "--verbose                 Increases output"
	exit 128
}

silent=0
dry=0
verbose=0
opts=""
for i in "$@"
do
	case $i in
		--silent)
		silent=1
		opts=$opts" --silent"
		;;
		--dry)
		dry=1
		opts=$opts" --dry"
		;;
		--verbose)
		verbose=1
		opts=$opts" --verbose"
		;;
		--no-maxtime)
		opts=$opts" --no-maxtime"
		;;
		--path=*)
		CONF_FILE_PATH=${i##*=}
		;;
		--max-reruns=*)
		MAX_RERUNS=${i##*=}
		;;
		--max-exec-time=*)
		MAX_EXECUTION_TIME=${i##*=}
		;;
		--help|-h|-?)
		Usage
		;;
		*)
		Logger "Unknown param '$i'" "CRITICAL"
		Usage
		;;
	esac
done

CheckEnvironment
Logger "$(date) Osync batch run" "NOTICE"
Batch
