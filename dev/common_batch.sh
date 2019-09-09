#!/usr/bin/env bash
SUBPROGRAM=[prgname]
PROGRAM="$SUBPROGRAM-batch" # Batch program to run osync / obackup instances sequentially and rerun failed ones
AUTHOR="(L) 2013-2019 by Orsiris de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_BUILD=2019090901

## Runs an osync /obackup instance for every conf file found
## If an instance fails, run it again if time permits

if ! type "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

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

## Default directory where to store temporary run files
if [ -w /tmp ]; then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]; then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi
# No need to edit under this line ##############################################################

include #### Logger SUBSET ####
include #### CleanUp SUBSET ####

function TrapQuit {
        local exitcode=0

        # Get ERROR / WARN alert flags from subprocesses that call Logger
        if [ -f "$RUN_DIR/$PROGRAM.Logger.warn.$SCRIPT_PID.$TSTAMP" ]; then
                WARN_ALERT=true
                exitcode=2
        fi
        if [ -f "$RUN_DIR/$PROGRAM.Logger.error.$SCRIPT_PID.$TSTAMP" ]; then
                ERROR_ALERT=true
                exitcode=1
        fi

        CleanUp
        exit $exitcode
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
			( >&2 echo "Could not find [/usr/local/bin/$SUBPROGRAM.sh]" )
			exit 1
		fi
	else
		SUBPROGRAM_EXECUTABLE=$(type -p $SUBPROGRAM.sh)
	fi

	if [ "$CONF_FILE_PATH" == "" ]; then
		Usage
	fi
}

function Batch {
	local runs=1 # Number of batch runs
	local runList # Actual conf file list to run
	local runAgainList # List of failed conf files sto run again

	local confFile
	local result

	local i

	# Using -e because find will accept directories or files
	if [ ! -e "$CONF_FILE_PATH" ]; then
		Logger "Cannot find conf file path [$CONF_FILE_PATH]." "CRITICAL"
		Usage
	else
		# Ugly hack to read files into an array while preserving special characters
		runList=()
		while IFS= read -d $'\0' -r file; do runList+=("$file"); done < <(find "$CONF_FILE_PATH" -maxdepth 1 -iname "*.conf" -print0)

		while ([ $MAX_EXECUTION_TIME -gt $SECONDS ] || [ $MAX_EXECUTION_TIME -eq 0 ]) && [ "${#runList[@]}" -gt 0 ] && [ $runs -le $MAX_RUNS ]; do
			runAgainList=()
			Logger "Sequential run n°$runs of $SUBPROGRAM instances for:" "NOTICE"
			for confFile in "${runList[@]}"; do
				Logger "$(basename $confFile)" "NOTICE"
			done
			for confFile in "${runList[@]}"; do
				$SUBPROGRAM_EXECUTABLE "$confFile" --silent $opts &
				wait $!
				result=$?
				if [ $result != 0 ]; then
					if [ $result == 1 ] || [ $result == 128 ]; then # Do not handle exit code 128 because it is already handled here
						Logger "Instance $(basename $confFile) failed with exit code [$result]." "ERROR"
						runAgainList+=("$confFile")
					elif [ $result == 2 ]; then
						Logger "Instance $(basename $confFile) finished with warnings." "WARN"
					fi
				else
					Logger "Instance $(basename $confFile) succeed." "NOTICE"
				fi
			done
			runList=("${runAgainList[@]}")
			runs=$((runs + 1))
		done
	fi
}

function Usage {
	echo "$PROGRAM $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo "$CONTACT"
	echo ""
	echo "Batch script to sequentially run osync or obackup instances and rerun failed ones."
	echo "Usage: $PROGRAM.sh [OPTIONS] [$SUBPROGRAM OPTIONS]"
	echo ""
	echo "[OPTIONS]"
	echo "--path=/path/to/conf      Path to osync / obackup conf files, defaults to /etc/osync or /etc/obackup"
	echo "--max-runs=X              Number of max runs per instance, (defaults to 3)"
	echo "--max-exec-time=X         Retry failed instances only if max execution time not reached (defaults to 36000 seconds). Set to 0 to bypass execution time check"
	echo "[$SUBPROGRAM OPTIONS]"
	echo "Specify whatever options $PROGRAM accepts. Example"
	echo "$PROGRAM.sh --path=/etc/$SUBPROGRAM --no-maxtime"
	echo ""
	echo "No output will be written to stdout/stderr."
	echo "Verify log file in [$LOG_FILE]."
	exit 128
}

trap TrapQuit TERM EXIT HUP QUIT

opts=""
for i in "$@"
do
	case $i in
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
		opts="$opts$i "
		;;
	esac
done

CheckEnvironment
Logger "$(date) $SUBPROGRAM batch run" "NOTICE"
Batch
