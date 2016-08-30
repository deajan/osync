#!/usr/bin/env bash
SUBPROGRAM=osync
PROGRAM="$SUBPROGRAM-batch" # Batch program to run osync / obackup instances sequentially and rerun failed ones
AUTHOR="(L) 2013-2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_BUILD=2016082901

## Runs an osync /obackup instance for every conf file found
## If an instance fails, run it again if time permits

if ! type "$BASH" > /dev/null; then
        echo "Please run this script only with bash shell. Tested on bash >= 3.2"
        exit 127
fi

## Configuration file path. The path where all the osync / obackup conf files are, usually /etc/osync or /etc/obackup
CONF_FILE_PATH=/etc/$SUBPROGRAM

## If maximum execution time is not reached, failed instances will be rerun. Max exec time is in seconds. Example is set to 10 hours.
MAX_EXECUTION_TIME=36000

## Specifies the number of total runs an instance may get
MAX_RUNS=3

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
}

function Logger {
	local value="${1}" # What to log
	local level="${2}" # Log level: DEBUG, NOTICE, WARN, ERROR, CRITIAL

	prefix="$(date) - "

	if [ "$level" == "CRITICAL" ]; then
		_logger "$prefix\e[41m$value\e[0m"
	elif [ "$level" == "ERROR" ]; then
		_logger "$prefix\e[91m$value\e[0m"
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
	if ! type $SUBPROGRAM.sh > /dev/null 2>&1
	then
		if [ -f /usr/local/bin/$SUBPROGRAM.sh ]
		then
			SUBPROGRAM_EXECUTABLE=/usr/local/bin/$SUBPROGRAM.sh
		else
			Logger "Could not find [/usr/local/bin/$SUBPROGRAM.sh]" "CRITICAL"
			exit 1
		fi
	else
		SUBPROGRAM_EXECUTABLE=$(type -p $SUBPROGRAM.sh)
	fi
}

function Batch {
	local runs=0 # Number of batch runs
	local runList # Actual conf file list to run
	local runAgainList # List of failed conf files sto run again

	local confFile
	local result

	## Check for CONF_FILE_PATH
	if [ -d "$CONF_FILE_PATH" ]; then
		## Get list of .conf files
		for confFile in $CONF_FILE_PATH/*.conf
		do
			if [ -f "$confFile" ]; then
				if [ "$runList" == "" ]; then
					runList="$confFile"
				else
					runList=$runList" $confFile"
				fi
			fi
		done
	elif [ -f "$CONF_FILE_PATH" ] && [ "${CONF_FILE_PATH##*.}" == "conf" ]; then
		runList="$CONF_FILE_PATH"
	fi

	if [ "$runList" == "" ]; then
		Logger "Cannot find conf file path [$CONF_FILE_PATH]." "CRITICAL"
		Usage
	fi

	while ([ $MAX_EXECUTION_TIME -gt $SECONDS ] || [ $MAX_EXECUTION_TIME -eq 0 ]) && [ "$runList" != "" ] && [ $MAX_RUNS -gt $runs ]
	do
		Logger "$SUBPROGRAM instances will be run for: $runList" "NOTICE"
		for confFile in $runList
		do
			$SUBPROGRAM_EXECUTABLE "$confFile" $opts &
			wait $!
			result=$?
			if [ $result != 0 ]; then
				if [ $result == 1 ] || [ $result == 128 ]; then # Do not handle exit code 127 because it is already handled here
					Logger "Run instance $(basename $confFile) failed with exit code [$result]." "ERROR"
					if [ "$runAgainList" == "" ]; then
						runAgainList="$confFile"
					else
						runAgainList=$runAgainList" $confFile"
					fi
				elif [ $result == 2 ]; then
					Logger "Run instance $(basename $confFile) finished with warnings." "WARN"
				fi
			else
				Logger "Run instance $(basename $confFile) succeed." "NOTICE"
			fi
		done
		runList="$runAgainList"
		runAgainList=""
		runs=$(($runs + 1))
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
	echo "--max-runs=X              Number of max runs per instance, (defaults to 3)"
	echo "--max-exec-time=X         Retry failed instances only if max execution time not reached (defaults to 36000 seconds). Set to 0 to bypass execution time check"
	echo "--no-maxtime		Run osync / obackup without honoring conf file defined timeouts"
	echo "--dry                     Will run osync / obackup without actually doing anything; just testing"
	echo "--silent                  Will run osync / obackup without any output to stdout, used for cron jobs"
	echo "--verbose                 Increases output"
	exit 128
}

opts=""
for i in "$@"
do
	case $i in
		--silent)
		opts=$opts" --silent"
		;;
		--dry)
		opts=$opts" --dry"
		;;
		--verbose)
		opts=$opts" --verbose"
		;;
		--no-maxtime)
		opts=$opts" --no-maxtime"
		;;
		--path=*)
		CONF_FILE_PATH=${i##*=}
		;;
		--max-runs=*)
		MAX_RUNS=${i##*=}
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
