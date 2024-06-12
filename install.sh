#!/usr/bin/env bash

## Installer script suitable for osync / obackup / pmocr

PROGRAM=osync

PROGRAM_VERSION=$(grep "PROGRAM_VERSION=" $PROGRAM.sh)
PROGRAM_VERSION=${PROGRAM_VERSION#*=}
PROGRAM_BINARY=$PROGRAM".sh"
PROGRAM_BATCH=$PROGRAM"-batch.sh"
SSH_FILTER="ssh_filter.sh"

SCRIPT_BUILD=2023061101
INSTANCE_ID="installer-$SCRIPT_BUILD"

## osync / obackup / pmocr / zsnap install script
## Tested on RHEL / CentOS 6 & 7, Fedora 23, Debian 7 & 8, Mint 17 and FreeBSD 8, 10 and 11
## Please adapt this to fit your distro needs

_OFUNCTIONS_VERSION=2.5.1
_OFUNCTIONS_BUILD=2023061401
_OFUNCTIONS_BOOTSTRAP=true

if ! type "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

## Correct output of sort command (language agnostic sorting)
export LC_ALL=C

## Default umask for file creation
umask 0077

# Standard alert mail body
MAIL_ALERT_MSG="Execution of $PROGRAM instance $INSTANCE_ID on $(date) has warnings/errors."

# Environment variables that can be overriden by programs
_DRYRUN=false
_LOGGER_SILENT=false
_LOGGER_VERBOSE=false
_LOGGER_ERR_ONLY=false
_LOGGER_PREFIX="date"
_LOGGER_WRITE_PARTIAL_LOGS=false			# Writes partial log files to /tmp so sending logs via alerts can feed on them
_OFUNCTIONS_SHOW_SPINNER=true				# Show spinner in ExecTasks function
if [ "$KEEP_LOGGING" == "" ]; then
	KEEP_LOGGING=1801
fi

# Initial error status, logging 'WARN', 'ERROR' or 'CRITICAL' will enable alerts flags
ERROR_ALERT=false
WARN_ALERT=false


## allow debugging from command line with _DEBUG=true
if [ ! "$_DEBUG" == true ]; then
	_DEBUG=false
	_LOGGER_VERBOSE=false
else
	trap 'TrapError ${LINENO} $?' ERR
	_LOGGER_VERBOSE=true
fi

if [ "$SLEEP_TIME" == "" ]; then # Leave the possibity to set SLEEP_TIME as environment variable when runinng with bash -x in order to avoid spamming console
	SLEEP_TIME=.05
fi

# The variables SCRIPT_PID and TSTAMP needs to be declared as soon as the program begins. The function PoorMansRandomGenerator is needed for TSTAMP (since some systems date function does not give nanoseconds)

SCRIPT_PID=$$

# Get a random number of digits length on Windows BusyBox alike, also works on most Unixes that have dd
function PoorMansRandomGenerator {
	local digits="${1}" # The number of digits to generate
	local number

	# Some read bytes cannot be used, se we read twice the number of required bytes
	dd if=/dev/urandom bs=$digits count=2 2> /dev/null | while read -r -n1 char; do
		number=$number$(printf "%d" "'$char")
		if [ ${#number} -ge $digits ]; then
			echo ${number:0:$digits}
			break;
		fi
	done
}

# Initial TSTMAP value before function declaration
TSTAMP=$(date '+%Y%m%dT%H%M%S').$(PoorMansRandomGenerator 5)

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

if [ "$PROGRAM" == "" ]; then
	PROGRAM="ofunctions"
fi

## Default log file until config file is loaded
if [ -w /var/log ]; then
	LOG_FILE="/var/log/$PROGRAM.log"
elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
	LOG_FILE="$HOME/$PROGRAM.log"
elif [ -w . ]; then
	LOG_FILE="./$PROGRAM.log"
else
	LOG_FILE="/tmp/$PROGRAM.log"
fi

## Default directory where to store temporary run files

if [ -w /tmp ]; then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]; then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi

## Special note when remote target is on the same host as initiator (happens for unit tests): we'll have to differentiate RUN_DIR so remote CleanUp won't affect initiator.
## If the same program gets remotely executed, add _REMOTE_EXECUTION=true to environment so it knows it has to write into a separate directory
## This will thus not affect local $RUN_DIR variables
if [ "$_REMOTE_EXECUTION" == true ]; then
	mkdir -p "$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP"
	RUN_DIR="$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP"
fi

# Default alert attachment filename
ALERT_LOG_FILE="$RUN_DIR/$PROGRAM.$SCRIPT_PID.$TSTAMP.last.log"

# Set error exit code if a piped command fails
set -o pipefail
set -o errtrace


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
		if [ "$_LOGGER_WRITE_PARTIAL_LOGS" == true ] && [ "$RUN_DIR/$PROGRAM" != "/" ]; then
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
		prefix="RTIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ "$_DEBUG" == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[31m$value\e[0m" true
		if [ "$_DEBUG" == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ "$_DEBUG" == true ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ "$_LOGGER_ERR_ONLY" != true ]; then
			_Logger "" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ "$_LOGGER_VERBOSE" == true ]; then
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
	value="${value/env _REMOTE_TOKEN=$_REMOTE_TOKEN/env _REMOTE_TOKEN=__o_O__}"
	value="${value/env _REMOTE_TOKEN=\$_REMOTE_TOKEN/env _REMOTE_TOKEN=__o_O__}"

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[1;33;41m$value\e[0m" true
		ERROR_ALERT=true
		# ERROR_ALERT / WARN_ALERT is not set in main when Logger is called from a subprocess. We need to create these flag files for ERROR_ALERT / WARN_ALERT to be picked up by Alert
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.ERROR_ALERT.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[91m$value\e[0m" true
		ERROR_ALERT=true
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.ERROR_ALERT.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[33m$value\e[0m" true
		WARN_ALERT=true
		echo -e "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$\n$prefix($level):$value" >> "$RUN_DIR/$PROGRAM.WARN_ALERT.$SCRIPT_PID.$TSTAMP"
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ "$_LOGGER_ERR_ONLY" != true ]; then
			_Logger "$prefix$value" "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ "$_LOGGER_VERBOSE" == true ]; then
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

# Function is busybox compatible since busybox ash does not understand direct regex, we use expr
function IsInteger {
	local value="${1}"

	if type expr > /dev/null 2>&1; then
		expr "$value" : '^[0-9]\{1,\}$' > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			echo 1
		else
			echo 0
		fi
	else
		if [[ $value =~ ^[0-9]+$ ]]; then
			echo 1
		else
			echo 0
		fi
	fi
}

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}" # Parent pid to kill childs
	local self="${2:-false}" # Should parent be killed too ?

	# Paranoid checks, we can safely assume that $pid should not be 0 nor 1
	if [ $(IsInteger "$pid") -eq 0 ] || [ "$pid" == "" ] || [ "$pid" == "0" ] || [ "$pid" == "1" ]; then
		Logger "Bogus pid given [$pid]." "CRITICAL"
		return 1
	fi

	if kill -0 "$pid" > /dev/null 2>&1; then
		if children="$(pgrep -P "$pid")"; then
			if [[ "$pid" == *"$children"* ]]; then
				Logger "Bogus pgrep implementation." "CRITICAL"
				children="${children/$pid/}"
			fi
			for child in $children; do
				KillChilds "$child" true
			done
		fi
	fi

	# Try to kill nicely, if not, wait 15 seconds to let Trap actions happen before killing
	if [ "$self" == true ]; then
		# We need to check for pid again because it may have disappeared after recursive function call
		if kill -0 "$pid" > /dev/null 2>&1; then
			kill -s TERM "$pid"
			Logger "Sent SIGTERM to process [$pid]." "DEBUG"
			if [ $? -ne 0 ]; then
				sleep 15
				Logger "Sending SIGTERM to process [$pid] failed." "DEBUG"
				kill -9 "$pid"
				if [ $? -ne 0 ]; then
					Logger "Sending SIGKILL to process [$pid] failed." "DEBUG"
					return 1
				fi	# Simplify the return 0 logic here
			else
				return 0
			fi
		else
			return 0
		fi
	else
		return 0
	fi
}

function KillAllChilds {
	local pids="${1}" # List of parent pids to kill separated by semi-colon
	local self="${2:-false}" # Should parent be killed too ?


	local errorcount=0

	IFS=';' read -a pidsArray <<< "$pids"
	for pid in "${pidsArray[@]}"; do
		KillChilds $pid $self
		if [ $? -ne 0 ]; then
			errorcount=$((errorcount+1))
			fi
	done
	return $errorcount
}

function GenericTrapQuit {
	local exitcode=0

	# Get ERROR / WARN alert flags from subprocesses that call Logger
	if [ -f "$RUN_DIR/$PROGRAM.WARN_ALERT.$SCRIPT_PID.$TSTAMP" ]; then
		WARN_ALERT=true
		exitcode=2
	fi
	if [ -f "$RUN_DIR/$PROGRAM.ERROR_ALERT.$SCRIPT_PID.$TSTAMP" ]; then
		ERROR_ALERT=true
		exitcode=1
	fi

	CleanUp
	exit $exitcode
}


function CleanUp {
	# Exit controlmaster before the socket gets deleted
	if [ "$SSH_CONTROLMASTER" == true ] && [ "$SSH_CMD" != "" ]; then
		$SSH_CMD -O exit
	fi

	if [ "$_DEBUG" != true ]; then
		# Removing optional remote $RUN_DIR that goes into local $RUN_DIR
		if [ -d "$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP" ]; then
			rm -rf "$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP"
                fi
		# Removing all temporary run files
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
	fi
}



# Get current install.sh path from http://stackoverflow.com/a/246128/2635443
SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

_LOGGER_SILENT=false
_STATS=1
ACTION="install"
FAKEROOT=""

## Default log file
if [ -w "$FAKEROOT/var/log" ]; then
	LOG_FILE="$FAKEROOT/var/log/$PROGRAM-install.log"
elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
	LOG_FILE="$HOME/$PROGRAM-install.log"
else
	LOG_FILE="./$PROGRAM-install.log"
fi

## Modified version of https://gist.github.com/cdown/1163649
function UrlEncode {
	local length="${#1}"

	local i

	local LANG=C
	for i in $(seq 0 $((length-1))); do
		local c="${1:i:1}"
		case $c in
			[a-zA-Z0-9.~_-])
			printf "$c"
			;;
			*)
			printf '%%%02X' "'$c"
			;;
		esac
	done
}
function GetLocalOS {
	local localOsVar
	local localOsName
	local localOsVer

	# There is no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	elif set -o | grep "winxp" > /dev/null; then
		localOsVar="BusyBox-w32"
	else
		# Detecting the special ubuntu userland in Windows 10 bash
		if grep -i Microsoft /proc/sys/kernel/osrelease > /dev/null 2>&1; then
			localOsVar="Microsoft"
		else
			localOsVar="$(uname -spior 2>&1)"
			if [ $? -ne 0 ]; then
				localOsVar="$(uname -v 2>&1)"
				if [ $? -ne 0 ]; then
					localOsVar="$(uname)"
				fi
			fi
		fi
	fi

	case $localOsVar in
		# Android uname contains both linux and android, keep it before linux entry
		*"Android"*)
		LOCAL_OS="Android"
		;;
		*"qnap"*)
		LOCAL_OS="Qnap"
		;;
		*"Linux"*)
		LOCAL_OS="Linux"
		;;
		*"BSD"*)
		LOCAL_OS="BSD"
		;;
		*"MINGW32"*|*"MINGW64"*|*"MSYS"*)
		LOCAL_OS="msys"
		;;
		*"CYGWIN"*)
		LOCAL_OS="Cygwin"
		;;
		*"Microsoft"*|*"MS/Windows"*)
		LOCAL_OS="WinNT10"
		;;
		*"Darwin"*)
		LOCAL_OS="MacOSX"
		;;
		*"BusyBox"*)
		LOCAL_OS="BusyBox"
		;;
		*)
		if [ "$IGNORE_OS_TYPE" == true ]; then
			Logger "Running on unknown local OS [$localOsVar]." "WARN"
			return
		fi
		if [ "$_OFUNCTIONS_VERSION" != "" ]; then
			Logger "Running on >> $localOsVar << not supported. Please report to the author." "ERROR"
		fi
		exit 1
		;;
	esac

	# Get linux versions
	if [ -f "/etc/os-release" ]; then
		localOsName="$(GetConfFileValue "/etc/os-release" "NAME" true)"
		localOsVer="$(GetConfFileValue "/etc/os-release" "VERSION" true)"
	elif [ "$LOCAL_OS" == "BusyBox" ]; then
		localOsVer="$(ls --help 2>&1 | head -1 | cut -f2 -d' ')"
		localOsName="BusyBox"
	fi

	# Get Host info for Windows
	if [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "BusyBox" ] || [ "$LOCAL_OS" == "Cygwin" ] || [ "$LOCAL_OS" == "WinNT10" ]; then
		localOsVar="$localOsVar $(uname -a)"
		if [ "$PROGRAMW6432" != "" ]; then
			LOCAL_OS_BITNESS=64
			LOCAL_OS_FAMILY="Windows"
		elif [ "$PROGRAMFILES" != "" ]; then
			LOCAL_OS_BITNESS=32
			LOCAL_OS_FAMILY="Windows"
		# Case where running on BusyBox but no program files defined
		elif [ "$LOCAL_OS" == "BusyBox" ]; then
			LOCAL_OS_FAMILY="Unix"
		fi
	# Get Host info for Unix
	else
		LOCAL_OS_FAMILY="Unix"
	fi

	if [ "$LOCAL_OS_FAMILY" == "Unix" ]; then
		if uname -m | grep '64' > /dev/null 2>&1; then
			LOCAL_OS_BITNESS=64
		else
			LOCAL_OS_BITNESS=32
		fi
	fi

	LOCAL_OS_FULL="$localOsVar ($localOsName $localOsVer) $LOCAL_OS_BITNESS-bit $LOCAL_OS_FAMILY"

	if [ "$_OFUNCTIONS_VERSION" != "" ]; then
		Logger "Local OS: [$LOCAL_OS_FULL]." "DEBUG"
	fi
}
function GetConfFileValue () {
	local file="${1}"
	local name="${2}"
	local noError="${3:-false}"

	local value

	value=$(grep "^$name=" "$file")
	if [ $? -eq 0 ]; then
		value="${value##*=}"
		echo "$value"
	else
		if [ $noError == true ]; then
			Logger "Cannot get value for [$name] in config file [$file]." "DEBUG"
		else
			Logger "Cannot get value for [$name] in config file [$file]." "ERROR"
		fi
	fi
}

function CleanUp {
	# Exit controlmaster before the socket gets deleted
	if [ "$SSH_CONTROLMASTER" == true ] && [ "$SSH_CMD" != "" ]; then
		$SSH_CMD -O exit
	fi

	if [ "$_DEBUG" != true ]; then
		# Removing optional remote $RUN_DIR that goes into local $RUN_DIR
		if [ -d "$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP" ]; then
			rm -rf "$RUN_DIR/$PROGRAM.remote.$SCRIPT_PID.$TSTAMP"
                fi
		# Removing all temporary run files
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
	fi
}

function GenericTrapQuit {
	local exitcode=0

	# Get ERROR / WARN alert flags from subprocesses that call Logger
	if [ -f "$RUN_DIR/$PROGRAM.WARN_ALERT.$SCRIPT_PID.$TSTAMP" ]; then
		WARN_ALERT=true
		exitcode=2
	fi
	if [ -f "$RUN_DIR/$PROGRAM.ERROR_ALERT.$SCRIPT_PID.$TSTAMP" ]; then
		ERROR_ALERT=true
		exitcode=1
	fi

	CleanUp
	exit $exitcode
}


function SetLocalOSSettings {
	USER=root
	DO_INIT=true

	# LOCAL_OS and LOCAL_OS_FULL are global variables set at GetLocalOS

	case $LOCAL_OS in
		*"BSD"*)
		GROUP=wheel
		;;
		*"MacOSX"*)
		GROUP=admin
		DO_INIT=false
		;;
		*"Cygwin"*|*"Android"*|*"msys"*|*"BusyBox"*)
		USER=""
		GROUP=""
		DO_INIT=false
		;;
		*)
		GROUP=root
		;;
	esac

	if [ "$LOCAL_OS" == "Android" ] || [ "$LOCAL_OS" == "BusyBox" ]; then
		Logger "Cannot be installed on [$LOCAL_OS]. Please use $PROGRAM.sh directly." "CRITICAL"
		exit 1
	fi

	if ([ "$USER" != "" ] && [ "$(whoami)" != "$USER" ] && [ "$FAKEROOT" == "" ]); then
		Logger "Must be run as $USER." "CRITICAL"
		exit 1
	fi

	OS=$(UrlEncode "$LOCAL_OS_FULL")
}

function GetInit {
	init="none"
	if [ -f /sbin/openrc-run ]; then
		init="openrc"
		Logger "Detected openrc." "NOTICE"
	elif [ -f /usr/lib/systemd/systemd ]; then
		init="systemd"
		Logger "Detected systemd." "NOTICE"
	elif [ -f /sbin/init ]; then
		if type -p file > /dev/null 2>&1; then
			if file /sbin/init | grep systemd > /dev/null; then
				init="systemd"
				Logger "Detected systemd." "NOTICE"
			else
				init="initV"
			fi
		else
			init="initV"
		fi

		if [ $init == "initV" ]; then
			Logger "Detected initV." "NOTICE"
		fi
	else
		Logger "Can't detect initV, systemd or openRC. Service files won't be installed. You can still run $PROGRAM manually or via cron." "WARN"
		init="none"
	fi
}

function CreateDir {
	local dir="${1}"
	local dirMask="${2}"
	local dirUser="${3}"
	local dirGroup="${4}"

	if [ ! -d "$dir" ]; then
		(
		if [ $(IsInteger $dirMask) -eq 1 ]; then
			umask $dirMask
		fi
		mkdir -p "$dir"
		)
		if [ $? == 0 ]; then
			Logger "Created directory [$dir]." "NOTICE"
		else
			Logger "Cannot create directory [$dir]." "CRITICAL"
			exit 1
		fi
	fi

	if [ "$dirUser" != "" ]; then
		userGroup="$dirUser"
		if [ "$dirGroup" != "" ]; then
			userGroup="$userGroup"":$dirGroup"
		fi
		chown "$userGroup" "$dir"
		if [ $? != 0 ]; then
			Logger "Could not set directory ownership on [$dir] to [$userGroup]." "CRITICAL"
			exit 1
		else
			Logger "Set file ownership on [$dir] to [$userGroup]." "NOTICE"
		fi
	fi
}

function CopyFile {
	local sourcePath="${1}"
	local destPath="${2}"
	local sourceFileName="${3}"
	local destFileName="${4}"
	local fileMod="${5}"
	local fileUser="${6}"
	local fileGroup="${7}"
	local overwrite="${8:-false}"

	local userGroup=""

	if [ "$destFileName" == "" ]; then
		destFileName="$sourceFileName"
	fi

	if [ -f "$destPath/$destFileName" ] && [ $overwrite == false ]; then
		destFileName="$sourceFileName.new"
		Logger "Copying [$sourceFileName] to [$destPath/$destFileName]." "NOTICE"
	fi

	cp "$sourcePath/$sourceFileName" "$destPath/$destFileName"
	if [ $? != 0 ]; then
		Logger "Cannot copy [$sourcePath/$sourceFileName] to [$destPath/$destFileName]. Make sure to run install script in the directory containing all other files." "CRITICAL"
		Logger "Also make sure you have permissions to write to [$BIN_DIR]." "ERROR"
		exit 1
	else
		Logger "Copied [$sourcePath/$sourceFileName] to [$destPath/$destFileName]." "NOTICE"
		if [ "$(IsInteger $fileMod)" -eq 1 ]; then
			chmod "$fileMod" "$destPath/$destFileName"
			if [ $? != 0 ]; then
				Logger "Cannot set file permissions of [$destPath/$destFileName] to [$fileMod]." "CRITICAL"
				exit 1
			else
				Logger "Set file permissions to [$fileMod] on [$destPath/$destFileName]." "NOTICE"
			fi
		elif [ "$fileMod" != "" ]; then
			Logger "Bogus filemod [$fileMod] for [$destPath] given." "WARN"
		fi

		if [ "$fileUser" != "" ]; then
			userGroup="$fileUser"

			if [ "$fileGroup" != "" ]; then
				userGroup="$userGroup"":$fileGroup"
			fi

			chown "$userGroup" "$destPath/$destFileName"
			if [ $? != 0 ]; then
				Logger "Could not set file ownership on [$destPath/$destFileName] to [$userGroup]." "CRITICAL"
				exit 1
			else
				Logger "Set file ownership on [$destPath/$destFileName] to [$userGroup]." "NOTICE"
			fi
		fi
	fi
}

function CopyExampleFiles {
	exampleFiles=()
	exampleFiles[0]="sync.conf.example"		# osync
	exampleFiles[1]="host_backup.conf.example"	# obackup
	exampleFiles[2]="exclude.list.example"		# osync & obackup
	exampleFiles[3]="snapshot.conf.example"		# zsnap
	exampleFiles[4]="default.conf"			# pmocr

	for file in "${exampleFiles[@]}"; do
		if [ -f "$SCRIPT_PATH/$file" ]; then
			CopyFile "$SCRIPT_PATH" "$CONF_DIR" "$file" "$file" "" "" "" false
		fi
	done
}

function CopyProgram {
	binFiles=()
	binFiles[0]="$PROGRAM_BINARY"
	if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "obackup" ]; then
		binFiles[1]="$PROGRAM_BATCH"
		binFiles[2]="$SSH_FILTER"
	fi

	local user=""
	local group=""

	if ([ "$USER" != "" ] && [ "$FAKEROOT" == "" ]); then
		user="$USER"
	fi
	if ([ "$GROUP" != "" ] && [ "$FAKEROOT" == "" ]); then
		group="$GROUP"
	fi

	for file in "${binFiles[@]}"; do
		CopyFile "$SCRIPT_PATH" "$BIN_DIR" "$file" "$file" 755 "$user" "$group" true
	done
}

function CopyServiceFiles {
	if ([ "$init" == "systemd" ] && [ -f "$SCRIPT_PATH/$SERVICE_FILE_SYSTEMD_SYSTEM" ]); then
		CreateDir "$SERVICE_DIR_SYSTEMD_SYSTEM"
		CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_SYSTEMD_SYSTEM" "$SERVICE_FILE_SYSTEMD_SYSTEM" "$SERVICE_FILE_SYSTEMD_SYSTEM" "" "" "" true
		if [ -f "$SCRIPT_PATH/$SERVICE_FILE_SYSTEMD_USER" ]; then
			CreateDir "$SERVICE_DIR_SYSTEMD_USER"
			CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_SYSTEMD_USER" "$SERVICE_FILE_SYSTEMD_USER" "$SERVICE_FILE_SYSTEMD_USER" "" "" "" true
		fi

		if [ -f "$SCRIPT_PATH/$TARGET_HELPER_SERVICE_FILE_SYSTEMD_SYSTEM" ]; then
			CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_SYSTEMD_SYSTEM" "$TARGET_HELPER_SERVICE_FILE_SYSTEMD_SYSTEM" "$TARGET_HELPER_SERVICE_FILE_SYSTEMD_SYSTEM" "" "" "" true
			Logger "Created optional service [$TARGET_HELPER_SERVICE_NAME] with same specifications as below." "NOTICE"
		fi
		if [ -f "$SCRIPT_PATH/$TARGET_HELPER_SERVICE_FILE_SYSTEMD_USER" ]; then
			CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_SYSTEMD_USER" "$TARGET_HELPER_SERVICE_FILE_SYSTEMD_USER" "$TARGET_HELPER_SERVICE_FILE_SYSTEMD_USER" "" "" "" true
		fi


		Logger "Created [$SERVICE_NAME] service in [$SERVICE_DIR_SYSTEMD_SYSTEM] and [$SERVICE_DIR_SYSTEMD_USER]." "NOTICE"
		Logger "Can be activated with [systemctl start SERVICE_NAME@instance.conf] where instance.conf is the name of the config file in $CONF_DIR." "NOTICE"
		Logger "Can be enabled on boot with [systemctl enable $SERVICE_NAME@instance.conf]." "NOTICE"
		Logger "In userland, active with [systemctl --user start $SERVICE_NAME@instance.conf]." "NOTICE"
	elif ([ "$init" == "initV" ] && [ -f "$SCRIPT_PATH/$SERVICE_FILE_INIT" ] && [ -d "$SERVICE_DIR_INIT" ]); then
		#CreateDir "$SERVICE_DIR_INIT"
		CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_INIT" "$SERVICE_FILE_INIT" "$SERVICE_FILE_INIT" "755" "" "" true
		if [ -f "$SCRIPT_PATH/$TARGET_HELPER_SERVICE_FILE_INIT" ]; then
			CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_INIT" "$TARGET_HELPER_SERVICE_FILE_INIT" "$TARGET_HELPER_SERVICE_FILE_INIT" "755" "" "" true
			Logger "Created optional service [$TARGET_HELPER_SERVICE_NAME] with same specifications as below." "NOTICE"
		fi
		Logger "Created [$SERVICE_NAME] service in [$SERVICE_DIR_INIT]." "NOTICE"
		Logger "Can be activated with [service $SERVICE_FILE_INIT start]." "NOTICE"
		Logger "Can be enabled on boot with [chkconfig $SERVICE_FILE_INIT on]." "NOTICE"
	elif ([ "$init" == "openrc" ] && [ -f "$SCRIPT_PATH/$SERVICE_FILE_OPENRC" ] && [ -d "$SERVICE_DIR_OPENRC" ]); then
		# Rename service to usual service file
		CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_OPENRC" "$SERVICE_FILE_OPENRC" "$SERVICE_FILE_INIT" "755" "" "" true
		if [ -f "$SCRPT_PATH/$TARGET_HELPER_SERVICE_FILE_OPENRC" ]; then
			CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_OPENRC" "$TARGET_HELPER_SERVICE_FILE_OPENRC" "$TARGET_HELPER_SERVICE_FILE_OPENRC" "755" "" "" true
			Logger "Created optional service [$TARGET_HELPER_SERVICE_NAME] with same specifications as below." "NOTICE"
		fi
		Logger "Created [$SERVICE_NAME] service in [$SERVICE_DIR_OPENRC]." "NOTICE"
		Logger "Can be activated with [rc-update add $SERVICE_NAME.instance] where instance is a configuration file found in /etc/osync." "NOTICE"
	else
		Logger "Cannot properly find how to deal with init on this system. Skipping service file installation." "NOTICE"
	fi
}

function Statistics {
	if type wget > /dev/null 2>&1; then
		wget -qO- "$STATS_LINK" > /dev/null 2>&1
		if [ $? == 0 ]; then
			return 0
		fi
	fi

	if type curl > /dev/null 2>&1; then
		curl "$STATS_LINK" -o /dev/null > /dev/null 2>&1
		if [ $? == 0 ]; then
			return 0
		fi
	fi

	Logger "Neiter wget nor curl could be used for. Cannot run statistics. Use the provided link please." "WARN"
	return 1
}

function RemoveFile {
	local file="${1}"

	if [ -f "$file" ]; then
		rm -f "$file"
		if [ $? != 0 ]; then
			Logger "Could not remove file [$file]." "ERROR"
		else
			Logger "Removed file [$file]." "NOTICE"
		fi
	else
		Logger "File [$file] not found. Skipping." "NOTICE"
	fi
}

function RemoveAll {
	RemoveFile "$BIN_DIR/$PROGRAM_BINARY"

	if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "obackup" ]; then
		RemoveFile "$BIN_DIR/$PROGRAM_BATCH"
	fi

	if [ ! -f "$BIN_DIR/osync.sh" ] && [ ! -f "$BIN_DIR/obackup.sh" ]; then		# Check if any other program requiring ssh filter is present before removal
		RemoveFile "$BIN_DIR/$SSH_FILTER"
	else
		Logger "Skipping removal of [$BIN_DIR/$SSH_FILTER] because other programs present that need it." "NOTICE"
	fi

	# Try to uninstall every possible service file
	#if [ $init == "systemd" ]; then
		RemoveFile "$SERVICE_DIR_SYSTEMD_SYSTEM/$SERVICE_FILE_SYSTEMD_SYSTEM"
		RemoveFile "$SERVICE_DIR_SYSTEMD_USER/$SERVICE_FILE_SYSTEMD_USER"
		RemoveFile "$SERVICE_DIR_SYSTEMD_SYSTEM/$TARGET_HELPER_SERVICE_FILE_SYSTEMD_SYSTEM"
		RemoveFile "$SERVICE_DIR_SYSTEMD_USER/$TARGET_HELPER_SERVICE_FILE_SYSTEMD_USER"
	#elif [ $init == "initV" ]; then
		RemoveFile "$SERVICE_DIR_INIT/$SERVICE_FILE_INIT"
		RemoveFile "$SERVICE_DIR_INIT/$TARGET_HELPER_SERVICE_FILE_INIT"
	#elif [ $init == "openrc" ]; then
		RemoveFile "$SERVICE_DIR_OPENRC/$SERVICE_FILE_OPENRC"
		RemoveFile "$SERVICE_DIR_OPENRC/$TARGET_HELPER_SERVICE_FILE_OPENRC"
	#else
		#Logger "Can't uninstall from initV, systemd or openRC." "WARN"
	#fi

	Logger "Skipping configuration files in [$CONF_DIR]. You may remove this directory manually." "NOTICE"
}

function Usage {
	echo "Installs $PROGRAM into $BIN_DIR"
	echo "options:"
	echo "--silent		Will log and bypass user interaction."
	echo "--no-stats	Used with --silent in order to refuse sending anonymous install stats."
	echo "--remove          Remove the program."
	echo "--prefix=/path    Use prefix to install path."
	exit 127
}

############################## Script entry point

function GetCommandlineArguments {
        for i in "$@"; do
                case $i in
			--prefix=*)
                        FAKEROOT="${i##*=}"
                        ;;
			--silent)
			_LOGGER_SILENT=true
			;;
			--no-stats)
			_STATS=0
			;;
			--remove)
			ACTION="uninstall"
			;;
			--help|-h|-?)
			Usage
			;;
                        *)
			Logger "Unknown option '$i'" "ERROR"
			Usage
			exit
                        ;;
                esac
	done
}

GetCommandlineArguments "$@"

CONF_DIR=$FAKEROOT/etc/$PROGRAM
BIN_DIR="$FAKEROOT/usr/local/bin"
SERVICE_DIR_INIT=$FAKEROOT/etc/init.d
# Should be /usr/lib/systemd/system, but /lib/systemd/system exists on debian & rhel / fedora
SERVICE_DIR_SYSTEMD_SYSTEM=$FAKEROOT/lib/systemd/system
SERVICE_DIR_SYSTEMD_USER=$FAKEROOT/etc/systemd/user
SERVICE_DIR_OPENRC=$FAKEROOT/etc/init.d

if [ "$PROGRAM" == "osync" ]; then
	SERVICE_NAME="osync-srv"
	TARGET_HELPER_SERVICE_NAME="osync-target-helper-srv"

	TARGET_HELPER_SERVICE_FILE_INIT="$TARGET_HELPER_SERVICE_NAME"
	TARGET_HELPER_SERVICE_FILE_SYSTEMD_SYSTEM="$TARGET_HELPER_SERVICE_NAME@.service"
	TARGET_HELPER_SERVICE_FILE_SYSTEMD_USER="$TARGET_HELPER_SERVICE_NAME@.service.user"
	TARGET_HELPER_SERVICE_FILE_OPENRC="$TARGET_HELPER_SERVICE_NAME-openrc"
elif [ "$PROGRAM" == "pmocr" ]; then
	SERVICE_NAME="pmocr-srv"
fi

SERVICE_FILE_INIT="$SERVICE_NAME"
SERVICE_FILE_SYSTEMD_SYSTEM="$SERVICE_NAME@.service"
SERVICE_FILE_SYSTEMD_USER="$SERVICE_NAME@.service.user"
SERVICE_FILE_OPENRC="$SERVICE_NAME-openrc"

## Generic code

trap GenericTrapQuit TERM EXIT HUP QUIT

if [ ! -w "$(dirname $LOG_FILE)" ]; then
        echo "Cannot write to log [$(dirname $LOG_FILE)]."
else
        Logger "Script begin, logging to [$LOG_FILE]." "DEBUG"
fi

# Set default umask
umask 0022

GetLocalOS
SetLocalOSSettings
# On Mac OS this always produces a warning which causes the installer to fail with exit code 2
# Since we know it won't work anyway, and that's fine, just skip this step
if $DO_INIT; then
	GetInit
fi

STATS_LINK="http://instcount.netpower.fr?program=$PROGRAM&version=$PROGRAM_VERSION&os=$OS&action=$ACTION"

if [ "$ACTION" == "uninstall" ]; then
	RemoveAll
	Logger "$PROGRAM uninstalled." "NOTICE"
else
	CreateDir "$CONF_DIR"
	CreateDir "$BIN_DIR"
	CopyExampleFiles
	CopyProgram
	if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "pmocr" ]; then
		CopyServiceFiles
	fi
	Logger "$PROGRAM installed. Use with $BIN_DIR/$PROGRAM_BINARY" "NOTICE"
	if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "obackup" ]; then
		echo ""
		Logger "If connecting remotely, consider setup ssh filter to enhance security." "NOTICE"
		echo ""
	fi
fi

if [ $_STATS -eq 1 ]; then
	if [ $_LOGGER_SILENT == true ]; then
		Statistics
	else
		Logger "In order to make usage statistics, the script would like to connect to $STATS_LINK" "NOTICE"
		read -r -p "No data except those in the url will be send. Allow [Y/n] " response
		case $response in
			[nN])
			exit
			;;
			*)
			Statistics
			exit $?
			;;
		esac
	fi
fi
