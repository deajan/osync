#!/usr/bin/env bash
SUBPROGRAM=osync
PROGRAM="$SUBPROGRAM-batch" # Batch program to run osync / obackup instances sequentially and rerun failed ones
AUTHOR="(L) 2013-2018 by Orsiris de Jong"
CONTACT="http://www.netpower.fr - ozy@netpower.fr"
PROGRAM_BUILD=2018100201

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

trap TrapQuit TERM EXIT HUP QUIT

# No need to edit under this line ##############################################################

#### RemoteLogger SUBSET ####

# Array to string converter, see http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
# usage: joinString separaratorChar Array
function joinString {
	local IFS="$1"; shift; echo "$*";
}

# Sub function of Logger
function _Logger {
	local logValue="${1}"		# Log to file
	local stdValue="${2}"		# Log to screeen
	local toStdErr="${3:-false}"	# Log to stderr instead of stdout

	if [ "$logValue" != "" ]; then
		echo -e "$logValue" >> "$LOG_FILE"

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP"
		fi
	fi

	if [ "$stdValue" != "" ] && [ "$_LOGGER_SILENT" != true ]; then
		if [ $toStdErr == true ]; then
			# Force stderr color in subshell
			(>&2 echo -e "$stdValue")

		else
			echo -e "$stdValue"
		fi
	fi
}

# Remote logger similar to below Logger, without log to file and alert flags
function RemoteLogger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	local prefix

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[31m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ $_LOGGER_ERR_ONLY != true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_LOGGER_VERBOSE == true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger	 "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == true ]; then
			_Logger "" "$prefix$value"
			return
		fi
	else
		_Logger "" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "" "Value was: $prefix$value" true
	fi
}
#### RemoteLogger SUBSET END ####

# General log function with log levels:

# Environment variables
# _LOGGER_SILENT: Disables any output to stdout & stderr
# _LOGGER_ERR_ONLY: Disables any output to stdout except for ALWAYS loglevel
# _LOGGER_VERBOSE: Allows VERBOSE loglevel messages to be sent to stdout

# Loglevels
# Except for VERBOSE, all loglevels are ALWAYS sent to log file

# CRITICAL, ERROR, WARN sent to stderr, color depending on level, level also logged
# NOTICE sent to stdout
# VERBOSE sent to stdout if _LOGGER_VERBOSE=true
# ALWAYS is sent to stdout unless _LOGGER_SILENT=true
# DEBUG & PARANOIA_DEBUG are only sent to stdout if _DEBUG=true
function Logger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	local prefix

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="$(date '+%Y-%m-%d %H:%M:%S') - "
	else
		prefix=""
	fi

	## Obfuscate _REMOTE_TOKEN in logs (for ssh_filter usage only in osync and obackup)
	value="${value/env _REMOTE_TOKEN=$_REMOTE_TOKEN/__(o_O)__}"
	value="${value/env _REMOTE_TOKEN=\$_REMOTE_TOKEN/__(o_O)__}"

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[1;33;41m$value\e[0m" true
		ERROR_ALERT=true
		# ERROR_ALERT / WARN_ALERT is not set in main when Logger is called from a subprocess. Need to keep this flag.
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[91m$value\e[0m" true
		ERROR_ALERT=true
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[33m$value\e[0m" true
		WARN_ALERT=true
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.warn.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ "$_LOGGER_ERR_ONLY" != true ]; then
			_Logger "$prefix$value" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_LOGGER_VERBOSE == true ]; then
			_Logger "$prefix($level):$value" "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		_Logger "$prefix$value" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == true ]; then
			_Logger "$prefix$value" "$prefix$value"
			return
		fi
	else
		_Logger "\e[41mLogger function called without proper loglevel [$level].\e[0m" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "Value was: $prefix$value" "Value was: $prefix$value" true
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
