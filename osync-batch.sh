#!/usr/bin/env bash
SUBPROGRAM=osync
PROGRAM="$SUBPROGRAM-batch" # Batch program to run osync / obackup instances sequentially and rerun failed ones
AUTHOR="(L) 2013-2015 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_BUILD=2015103001

## Runs an osync /obackup instance for every conf file found
## If an instance fails, run it again if time permits

## Configuration file path. The path where all the osync / obackup conf files are, usually /etc/osync or /etc/obackup
CONF_FILE_PATH=/etc/$SUBPROGRAM

## If maximum execution time is not reached, failed instances will be rerun. Max exec time is in seconds. Example is set to 10 hours.
MAX_EXECUTION_TIME=36000

## Specifies the number of reruns an instance may get
MAX_RERUNS=3

## Log file path
if [ -w /var/log ]; then
	LOG_FILE=/var/log/$SUBPROGRAM-batch.log
else
	LOG_FILE=./$SUBPROGRAM-batch.log
fi

# No need to edit under this line ##############################################################

function _logger {
	local value="${1}" # What to log
	echo -e "$value" >> "$LOG_FILE"

	if [ $_SILENT -eq 0 ]; then
		echo -e "$value"
	fi
}

function Logger {
	local value="${1}" # What to log
	local level="${2}" # Log level: DEBUG, NOTICE, WARN, ERROR, CRITIAL

	prefix="$(date) - "

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
	## osync / obackup executable full path can be set here if it cannot be found on the system
	if ! type -p $SUBPROGRAM.sh > /dev/null 2>&1
	then
		if [ -f /usr/local/bin/$SUBPROGRAM.sh ]
		then
			SUBPROGRAM_EXECUTABLE=/usr/local/bin/$SUBPROGRAM.sh
		else
			Logger "Could not find $SUBPROGRAM.sh" "CRITICAL"
			exit 1
		fi
	else
		SUBPROGRAM_EXECUTABLE=$(type -p $SUBPROGRAM.sh)
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
		Logger "$SUBPROGRAM instances will be run for: $RUN" "NOTICE"
		for i in $RUN
		do
			$SUBPROGRAM_EXECUTABLE "$i" $opts &
			wait $!
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
	echo "Batch script to sequentially run osync or obackup instances and rerun failed ones."
	echo "Usage: $SUBPROGRAM-batch.sh [OPTIONS]"
	echo ""
	echo "[OPTIONS]"
	echo "--path=/path/to/conf      Path to osync / obackup conf files, defaults to /etc/osync or /etc/obackup"
	echo "--max-reruns=X            Number of runs  max for failed instances, (defaults to 3)"
	echo "--max-exec-time=X         Retry failed instances only if max execution time not reached (defaults to 36000 seconds). Set to 0 to bypass execution time check."
	echo "--no-maxtime		Run osync / obackup without honoring conf file defined timeouts"
	echo "--dry                     Will run osync / obackup without actually doing anything; just testing"
	echo "--silent                  Will run osync / obackup without any output to stdout, used for cron jobs"
	echo "--verbose                 Increases output"
	exit 128
}

_SILENT=0
_DRY=0
_VERBOSE=0
opts=""
for i in "$@"
do
	case $i in
		--silent)
		_SILENT=1
		opts=$opts" --silent"
		;;
		--dry)
		_DRY=1
		opts=$opts" --dry"
		;;
		--verbose)
		_VERBOSE=1
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
Logger "$(date) $SUBPROGRAM batch run" "NOTICE"
Batch
