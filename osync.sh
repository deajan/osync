#!/usr/bin/env bash

PROGRAM="Osync" # Rsync based two way sync engine with fault tolerance
AUTHOR="(L) 2013-2015 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION=1.1-unstable
PROGRAM_BUILD=2015091204

## type doesn't work on platforms other than linux (bash). If if doesn't work, always assume output is not a zero exitcode
if ! type -p "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

## allow debugging from command line with DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	SLEEP_TIME=.1
else
	SLEEP_TIME=1
fi

## allow function call checks
if [ "$_PARANOIA_DEBUG" == "yes" ];then
	_DEBUG=yes
	SLEEP_TIME=1
fi

SCRIPT_PID=$$

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

## Default log file until config file is loaded
if [ -w /var/log ]; then
	LOG_FILE=/var/log/osync.log
else
	LOG_FILE=./osync.log
fi

## Default directory where to store temporary run files
if [ -w /tmp ]; then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]; then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi

## Working directory. This is the name of the osync subdirectory contained in every replica.
OSYNC_DIR=".osync_workdir"

## Log a state message every $KEEP_LOGGING seconds. Should not be equal to soft or hard execution time so your log won't be unnecessary big.
KEEP_LOGGING=1801

## Correct output of sort command (language agnostic sorting)
export LC_ALL=C

ALERT_LOG_FILE=$RUN_DIR/osync_lastlog

function Dummy {
	sleep .1
}

function _Logger {
	local value="${1}" # What to log
	echo -e "$value" >> "$LOG_FILE"
	
	if [ $_SILENT -eq 0 ]; then
		echo -e "$value"
	fi
}

function Logger {
	local value="${1}" # Sentence to log (in double quotes)
	local level="${2}" # Log level: DEBUG, NOTICE, WARN, ERROR, CRITIAL

	# Special case in daemon mode we should timestamp instead of counting seconds
	if [ $sync_on_changes -eq 1 ]; then
		prefix="$(date) - "
	else
		prefix="TIME: $SECONDS - "
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix\e[41m$value\e[0m"
		ERROR_ALERT=1
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix\e[91m$value\e[0m"
		ERROR_ALERT=1
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix\e[93m$value\e[0m"
		return
	elif [ "$level" == "NOTICE" ]; then
		_Logger "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "$prefix$value"
			return
		fi
	else
		_Logger "\e[41mLogger function called without proper loglevel.\e[0m"
		_Logger "$prefix$value"
	fi
}

function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"
	if [ $_SILENT -eq 0 ]; then
		echo -e " /!\ ERROR in ${job}: Near line ${line}, exit code ${code}"
	fi
}

function TrapStop {
	if [ $soft_stop -eq 0 ]; then
		Logger " /!\ WARNING: Manual exit of osync is really not recommended. Sync will be in inconsistent state." "WARN"
		Logger " /!\ WARNING: If you are sure, please hit CTRL+C another time to quit." "WARN"
		soft_stop=1
		return 1
	fi

	if [ $soft_stop -eq 1 ]; then
		Logger " /!\ WARNING: CTRL+C hit twice. Quitting osync. Please wait..." "WARN"
		soft_stop=2
		exit 1
	fi
}

function TrapQuit {
	if [ $error_alert -ne 0 ]; then
		if [ "$_DEBUG" != "yes" ]; then
			SendAlert
		else
			Logger "Debug mode, no alert mail will be sent." "NOTICE"
		fi
		UnlockReplicas
		CleanUp
		Logger "Osync finished with errors." "WARN"
		exitcode=1
	else
		UnlockReplicas
		CleanUp
		Logger "Osync finished." "NOTICE"
		exitcode=0
	fi

	if ps -p $child_pid > /dev/null 2>&1
	then
		kill -9 $child_pid
	fi

	if ps -p $sub_pid > /dev/null 2>&1
	then
		kill -9 $sub_pid
	fi

	exit $exitcode
}

function Spinner {
	if [ $_SILENT -eq 1 ]; then
		return 0
	fi

	case $toggle
	in
	1)
	echo -n " \ "
	echo -ne "\r"
	toggle="2"
	;;

	2)
	echo -n " | "
	echo -ne "\r"
	toggle="3"
	;;

	3)
	echo -n " / "
	echo -ne "\r"
	toggle="4"
	;;

	*)
	echo -n " - "
	echo -ne "\r"
	toggle="1"
	;;
	esac
}

function EscapeSpaces {
	local string="${1}" # String on which spaces will be escaped
	echo $(echo "$string" | sed 's/ /\\ /g')
}

function CleanUp {
	if [ "$_DEBUG" != "yes" ]; then
		rm -f "$RUN_DIR/osync_*_$SCRIPT_PID"
	fi
}

function SendAlert {
	if [ "$quick_sync" == "2" ]; then
		Logger "Current task is a quicksync task. Will not send any alert." "NOTICE"
		return 0
	fi
	eval "cat \"$LOG_FILE\" $COMPRESSION_PROGRAM > $ALERT_LOG_FILE"
	MAIL_ALERT_MSG=$MAIL_ALERT_MSG$'\n\n'$(tail -n 25 "$LOG_FILE")
	if type -p mutt > /dev/null 2>&1
	then
		echo $MAIL_ALERT_MSG | $(type -p mutt) -x -s "Sync alert for $SYNC_ID" $DESTINATION_MAILS -a "$ALERT_LOG_FILE"
		if [ $? != 0 ]; then
			Logger "WARNING: Cannot send alert email via $(type -p mutt) !!!" "WARN"
		else
			Logger "Sent alert mail using mutt." "NOTICE"
		fi
	elif type -p mail > /dev/null 2>&1
	then
		echo $MAIL_ALERT_MSG | $(type -p mail) -a "$ALERT_LOG_FILE" -s "Sync alert for $SYNC_ID" $DESTINATION_MAILS
		if [ $? != 0 ]; then
			Logger "WARNING: Cannot send alert email via $(type -p mail) with attachments !!!" "WARN"
			echo $MAIL_ALERT_MSG | $(type -p mail) -s "Sync alert for $SYNC_ID" $DESTINATION_MAILS
			if [ $? != 0 ]; then
				Logger "WARNING: Cannot send alert email via $(type -p mail) without attachments !!!" "WARN"
			else
				Logger "Sent alert mail using mail command without attachment." "NOTICE"
			fi
		else
			Logger "Sent alert mail using mail command." "NOTICE"
		fi
	elif type -p sendemail > /dev/null 2>&1
	then
		if [ "$SMTP_USER" != "" ] && [ "$SMTP_PASSWORD" != "" ]; then
			$SMTP_OPTIONS="-xu $SMTP_USER -xp $SMTP_PASSWORD"
		else
			$SMTP_OPTIONS=""
		fi
		$(type -p sendemail) -f $SENDER_MAIL -t $DESTINATION_MAILS -u "Backup alert for $BACKUP_ID" -m "$MAIL_ALERT_MSG" -s $SMTP_SERVER $SMTP_OPTIONS > /dev/null 2>&1
		if [ $? != 0 ]; then
			Logger "WARNING: Cannot send alert email via $(type -p sendemail) !!!" "WARN"
		else
			Logger "Sent alert mail using sendemail command without attachment." "NOTICE"
		fi
	else
		Logger "WARNING: Cannot send alert email (no mutt / mail present) !!!" "WARN"
		return 1
	fi

	if [ -f "$ALERT_LOG_FILE" ]; then
		rm "$ALERT_LOG_FILE"
	fi
}

function LoadConfigFile {
	local config_file="${1}"

	if [ ! -f "$config_file" ]; then
		Logger "Cannot load configuration file [$config_file]. Sync cannot start." "CRITICAL"
		exit 1
	elif [[ "$1" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$config_file]. Sync cannot start." "CRITICAL"
		exit 1
	else
		egrep '^#|^[^ ]*=[^;&]*'  "$config_file" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID
		source "$RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID"
	fi
}

function CheckEnvironment {
	if [ "$REMOTE_SYNC" == "yes" ]; then
		if ! type -p ssh > /dev/null 2>&1
		then
			Logger "ssh not present. Cannot start sync." "CRITICAL"
			return 1
		fi
	fi

	if ! type -p rsync > /dev/null 2>&1
	then
		Logger "rsync not present. Sync cannot start." "CRITICAL"
		return 1
	fi
}

function GetLocalOS {
	__CheckArguments 0 $# $FUNCNAME "$*"
	local local_os_var=$(uname -spio 2>&1)
	if [ $? != 0 ]; then
		local local_os_var=$(uname -v 2>&1)
		if [ $? != 0 ]; then
			local local_os_var=($uname)
		fi
	fi

	case $local_os_var in
		*"Linux"*)
		LOCAL_OS="Linux"
		;;
		*"BSD"*)
		LOCAL_OS="BSD"
		;;
		*"MINGW32"*)
		LOCAL_OS="msys"
		;;
		*"Darwin"*)
		LOCAL_OS="MacOSX"
		;;
		*)
		Logger "Running on >> $local_os_var << not supported. Please report to the author." "ERROR"
		exit 1
		;;
	esac
	Logger "Local OS: [$local_os_var]." "DEBUG"
}

function GetRemoteOS {
	__CheckArguments 0 $# $FUNCNAME "$*"

	if [ "$REMOTE_SYNC" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		eval "$SSH_CMD \"uname -spio\" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID 2>&1" &
		child_pid=$!
		WaitForTaskCompletion $child_pid 120 240
		retval=$?
		if [ $retval != 0 ]; then
			eval "$SSH_CMD \"uname -v\" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID 2>&1" &
			child_pid=$!
			WaitForTaskCompletion $child_pid 120 240
			retval=$?
			if [ $retval != 0 ]; then
				eval "$SSH_CMD \"uname\" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID 2>&1" &
				child_pid=$!
				WaitForTaskCompletion $child_pid 120 240
				retval=$?
				if [ $retval != 0 ]; then
					Logger "Cannot Get remote OS type." "ERROR"
				fi
			fi
		fi

		local remote_os_var=$(cat $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID)

		case $remote_os_var in
			*"Linux"*)
			REMOTE_OS="Linux"
			;;
			*"BSD"*)
			REMOTE_OS="BSD"
			;;
			*"MINGW32"*)
			REMOTE_OS="msys"
			;;
			*"Darwin"*)
			REMOTE_OS="MacOSX"
			;;
			*"ssh"*|*"SSH"*)
			Logger "Cannot connect to remote system." "CRITICAL"
			exit 1
			;;
			*)
			Logger "Running on remote OS failed. Please report to the author if the OS is not supported." "CRITICAL"
			Logger "Remote OS said:\n$remote_os_var" "CRITICAL"
			exit 1
		esac

		Logger "Remote OS: [$remote_os_var]." "DEBUG"
	fi
}

function WaitForTaskCompletion {
	local pid="${1}" # pid to wait for
	local soft_max_time="${2}" # If program with pid $pid takes longer than $soft_max_time seconds, will log a warning, unless $soft_max_time equals 0.
	local hard_max_time="${3}" # If program with pid $pid takes longer than $hard_max_time seconds, will stop execution, unless $hard_max_time equals 0.
	__CheckArguments 3 $# $FUNCNAME "$*"

	local soft_alert=0 # Does a soft alert need to be triggered
	local log_ttime=0 # local time instance for comparaison

	local seconds_begin=$SECONDS # Seconds since the beginning of the script
	local exec_time=0 # Seconds since the beginning of this function

	while eval "$PROCESS_TEST_CMD" > /dev/null
	do
		Spinner
		exec_time=$(($SECONDS - $seconds_begin))
		if [ $((($exec_time + 1) % $KEEP_LOGGING)) -eq 0 ]; then
			if [ $log_ttime -ne $exec_time ]; then
				log_ttime=$exec_time
				Logger "Current task still running." "NOTICE"
			fi
		fi
		if [ $exec_time -gt $soft_max_time ]; then
			if [ $soft_alert -eq 0 ] && [ $soft_max_time -ne 0 ]; then
				Logger "Max soft execution time exceeded for task." "WARN"
				soft_alert=1
			fi
			if [ $exec_time -gt $hard_max_time ] && [ $hard_max_time -ne 0 ]; then
				Logger "Max hard execution time exceeded for task. Stopping task execution." "ERROR"
				kill -s SIGTERM $pid
				if [ $? == 0 ]; then
					Logger "Task stopped succesfully" "NOTICE"
				else
					Logger "Sending SIGTERM to proces failed. Trying the hard way." "ERROR"
					kill -9 $pid
					if [ $? != 0 ]; then
						Logger "Could not stop task." "ERROR"
					fi
				fi
				return 1
			fi
		fi
		sleep $SLEEP_TIME
	done
	wait $pid
	return $?
}

function WaitForCompletion {
	local pid="${1}" # pid to wait for
	local soft_max_time="${2}" # If program with pid $pid takes longer than $soft_max_time seconds, will log a warning, unless $soft_max_time equals 0.
	local hard_max_time="${3}" # If program with pid $pid takes longer than $hard_max_time seconds, will stop execution, unless $hard_max_time equals 0.
	__CheckArguments 3 $# $FUNCNAME "$*"

	local soft_alert=0 # Does a soft alert need to be triggered
	local log_ttime=0 # local time instance for comparaison

	local seconds_begin=$SECONDS # Seconds since the beginning of the script
	local exec_time=0 # Seconds since the beginning of this function

	while eval "$PROCESS_TEST_CMD" > /dev/null
	do
		Spinner
		if [ $((($SECONDS + 1) % $KEEP_LOGGING)) -eq 0 ]; then
			if [ $log_time -ne $SECONDS ]; then
				log_time=$SECONDS
				Logger "Current task still running." "NOTICE"
			fi
		fi
		if [ $SECONDS -gt $soft_max_time ]; then
			if [ $soft_alert -eq 0 ] && [ $soft_max_time != 0 ]; then
				Logger "Max soft execution time exceeded for script." "WARN"
				soft_alert=1
			fi
			if [ $SECONDS -gt $hard_max_time ] && [ $hard_max_time != 0 ]; then
				Logger "Max hard execution time exceeded for script. Stopping current task execution." "ERROR"
				kill -s SIGTERM $pid
				if [ $? == 0 ]; then
					Logger "Task stopped succesfully" "NOTICE"
				else
					Logger "Sending SIGTERM to proces failed. Trying the hard way." "ERROR"
					kill -9 $pid
					if [ $? != 0 ]; then
						Logger "Could not stop task." "ERROR"
					fi
				fi
				return 1
			fi
		fi
		sleep $SLEEP_TIME
	done
	wait $pid
	return $?
}

function RunLocalCommand {
	local command="${1}" # Command to run
	local hard_max_time="${2}" # Max time to wait for command to compleet
	__CheckArguments 2 $# $FUNCNAME "$*"

	if [ $_DRYRUN -ne 0 ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 1
	fi
	Logger "Running command [$command] on local host." "NOTICE"
	eval "$command" > $RUN_DIR/osync_run_local_$SCRIPT_PID 2>&1 &
	child_pid=$!
	WaitForTaskCompletion $child_pid 0 $hard_max_time
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ $_VERBOSE -eq 1 ] || [ $retval -ne 0 ]; then
		Logger "Command output:\n$(cat $RUN_DIR/osync_run_local_$SCRIPT_PID)" "NOTICE"
	fi

	if [ "$STOP_ON_CMD_ERROR" == "yes" ] && [ $retval -ne 0 ]; then
		Logger "Stopping on command execution error." "CRITICAL"
		exit 1
	fi
}

## Runs remote command $1 and waits for completition in $2 seconds
function RunRemoteCommand {
	local command="${1}" # Command to run
	local hard_max_time="${2}" # Max time to wait for command to compleet
	__CheckArguments 2 $# $FUNCNAME "$*"

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	if [ $_DRYRUN -ne 0 ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 1
	fi
	Logger "Running command [$command] on remote host." "NOTICE"
	eval "$SSH_CMD \"$command\" > $RUN_DIR/osync_run_remote_$SCRIPT_PID 2>&1 &"
	child_pid=$!
	WaitForTaskCompletion $child_pid 0 $hard_max_time
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ -f $RUN_DIR/osync_run_remote_$SCRIPT_PID ] && ([ $_VERBOSE -eq 1 ] || [ $retval -ne 0 ])
	then
		Logger "Command output:\n$(cat $RUN_DIR/osync_run_remote_$SCRIPT_PID)" "NOTICE"
	fi

	if [ "$STOP_ON_CMD_ERROR" == "yes" ] && [ $retval -ne 0 ]; then
		Logger "Stopping on command execution error." "CRITICAL"
		exit 1
	fi
}

function RunBeforeHook {
	if [ "$LOCAL_RUN_BEFORE_CMD" != "" ]; then
		RunLocalCommand "$LOCAL_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE
	fi

	if [ "$REMOTE_RUN_BEFORE_CMD" != "" ]; then
		RunRemoteCommand "$REMOTE_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE
	fi
}

function RunAfterHook {
	if [ "$LOCAL_RUN_AFTER_CMD" != "" ]; then
		RunLocalCommand "$LOCAL_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER
	fi

	if [ "$REMOTE_RUN_AFTER_CMD" != "" ]; then
		RunRemoteCommand "$REMOTE_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER
	fi
}

function CheckConnectivityRemoteHost {
	__CheckArguments 0 $# $FUNCNAME "$*"

	if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_SYNC" != "no" ]; then
		eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1"
		if [ $? != 0 ]; then
			Logger "Cannot ping $REMOTE_HOST" "CRITICAL"
			exit 1
		fi
	fi
}

function CheckConnectivity3rdPartyHosts {
	__CheckArguments 0 $# $FUNCNAME "$*"

	if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]; then
		remote_3rd_party_success=0
		OLD_IFS=$IFS
		IFS=$' \t\n'
		for i in $REMOTE_3RD_PARTY_HOSTS
		do
			eval "$PING_CMD $i > /dev/null 2>&1"
			if [ $? != 0 ]; then
				Logger "Cannot ping 3rd party host $i" "WARN"
			else
				remote_3rd_party_success=1
			fi
		done
		IFS=$OLD_IFS
		if [ $remote_3rd_party_success -ne 1 ]; then
			Logger "No remote 3rd party host responded to ping. No internet ?" "CRITICAL"
			exit 1
		fi
	fi
}

function __CheckArguments {
	# Checks the number of arguments and raises an error if some are missing

	if [ "$_DEBUG" == "yes" ]; then

		local number_of_arguments="${1}" # Number of arguments a function should have
		local number_of_given_arguments="${2}" # Number of arguments that have been passed
		local function_name="${3}" # Function name that called __CheckArguments
		local arguments="${4}" # All other arguments

		if [ "$_PARANOIA_DEBUG" == "yes" ]; then
			Logger "Entering function [$function_name]." "DEBUG"

			# Paranoia check... Can help finding empty arguments. __CheckArguments should be grepped out in production builds.
			local count=-3 # Number of arguments minus the function calls for __CheckArguments
			for i in $@; do
				count=$((count + 1))
			done
			if [ $count -ne $1 ]; then
				Logger "Function $function_name may have inconsistent number of arguments. Expected: $number_of_arguments, count: $count, see log file." "WARN"
				echo "Argument list (including checks): $@" >> "$LOG_FILE"
			fi
		fi

		if [ $number_of_arguments -ne $number_of_given_arguments ]; then
			Logger "Inconsistnent number of arguments in $function_name. Should have $number_of_arguments arguments, has $number_of_given_arguments arguments, see log file." "CRITICAL"
			# Cannot user Logger here because $@ is a list of arguments
			echo "Argumnt list: $4" >> "$LOG_FILE"
		fi

	fi
}

###### realpath.sh implementation from https://github.com/mkropat/sh-realpath

realpath() {
    canonicalize_path "$(resolve_symlinks "$1")"
}

resolve_symlinks() {
    _resolve_symlinks "$1"
}

_resolve_symlinks() {
    _assert_no_path_cycles "$@" || return

    local dir_context path
    path=$(readlink -- "$1")
    if [ $? -eq 0 ]; then
	dir_context=$(dirname -- "$1")
	_resolve_symlinks "$(_prepend_dir_context_if_necessary "$dir_context" "$path")" "$@"
    else
	printf '%s\n' "$1"
    fi
}

_prepend_dir_context_if_necessary() {
    if [ "$1" = . ]; then
	printf '%s\n' "$2"
    else
	_prepend_path_if_relative "$1" "$2"
    fi
}

_prepend_path_if_relative() {
    case "$2" in
	/* ) printf '%s\n' "$2" ;;
	 * ) printf '%s\n' "$1/$2" ;;
    esac
}

_assert_no_path_cycles() {
    local target path

    target=$1
    shift

    for path in "$@"; do
	if [ "$path" = "$target" ]; then
	    return 1
	fi
    done
}

canonicalize_path() {
    if [ -d "$1" ]; then
	_canonicalize_dir_path "$1"
    else
	_canonicalize_file_path "$1"
    fi
}

_canonicalize_dir_path() {
    (cd "$1" 2>/dev/null && pwd -P)
}

_canonicalize_file_path() {
    local dir file
    dir=$(dirname -- "$1")
    file=$(basename -- "$1")
    (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$file")
}

# Optionally, you may also want to include:

### readlink emulation ###

readlink() {
    if  _has_command readlink; then
	_system_readlink "$@"
    else
	_emulated_readlink "$@"
    fi
}

_has_command() {
    hash -- "$1" 2>/dev/null
}

_system_readlink() {
    command readlink "$@"
}

_emulated_readlink() {
    if [ "$1" = -- ]; then
	shift
    fi

    _gnu_stat_readlink "$@" || _bsd_stat_readlink "$@"
}

_gnu_stat_readlink() {
    local output
    output=$(stat -c %N -- "$1" 2>/dev/null) &&

    printf '%s\n' "$output" |
	sed "s/^‘[^’]*’ -> ‘\(.*\)’/\1/
	     s/^'[^']*' -> '\(.*\)'/\1/"
    # FIXME: handle newlines
}

_bsd_stat_readlink() {
    stat -f %Y -- "$1" 2>/dev/null
}

###### Osync specific functions (non shared)

function _CreateStateDirsLocal {
	local replica_state_dir="${1}"
	__CheckArguments 1 $# $FUNCNAME "$*"

	if ! [ -d "$replica_state_dir" ]; then
		$COMMAND_SUDO mkdir -p "$replica_state_dir" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID 2>&1
		if [ $? != 0 ]; then
			Logger "Cannot create state dir [$replica_state_dir]." "CRITICAL"
			Logger "Command output:\n$RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID" "ERROR"
			exit 1
		fi
	fi
}

function _CreateStateDirsRemote {
	local replica_state_dir="${1}"
	__CheckArguments 1 $# $FUNCNAME "$*"

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	$cmd = "$SSH_CMD \"if ! [ -d \\\"$replica_state_dir\\\" ]; then $COMMAND_SUDO mkdir -p \\\"$replica_state_dir\\\"; fi 2>&1\" &"
	eval $cmd > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID 2>&1
	WaitForTaskCompletion $! 0 1800
	if [ $? != 0 ]; then
		Logger "Cannot create remote state dir [$replica_state_dir]." "CRITICAL"
		Logger "Command output:\n$RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID" "ERROR"
		exit 1
	fi
}

function CreateStateDirs {
	__CheckArguments 0 $# $FUNCNAME "$*"

	_CreateStateDirsLocal "$INITIATOR_STATE_DIR"
	if [ "$REMOTE_SYNC" == "no" ]; then
		_CreateStateDirsLocal "$TARGET_STATE_DIR"
	else
		_CreateStateDirsRemote "$TARGET_STATE_DIR"
	fi
}

function _CheckReplicaPathsLocal {
	local replica_path="${1}"
	__CheckArguments 1 $# $FUNCNAME "$*"
		
	if [ ! -d "$replica_path" ]; then
		if [ "$CREATE_DIRS" == "yes" ]; then
			$COMMAND_SUDO mkdir -p "$replica_path" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID 2>&1
			if [ $? != 0 ]; then
				Logger "Cannot create local replica path [$replica_path]." "CRITICAL"
				Logger "Command output:\n$(cat $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID)"
				exit 1
			else
				Logger "Created local replica path [$replica_path]." "NOTICE"
			fi
		else
			Logger "Local replica path [$replica_path] does not exist." "CRITICAL"
			exit 1
		fi
	fi

	if [ ! -w "$replica_path" ]; then
		Logger "Local replica path [$replica_path] is not writable." "CRITICAL"
		exit 1
	fi
}

function _CheckReplicaPathsRemote {
	local replica_path="${1}"
	__CheckArguments 1 $# $FUNCNAME "$*"

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd="$SSH_CMD \"if ! [ -d \\\"$replica_path\\\" ]; then if [ "$CREATE_DIRS" == "yes" ]; then $COMMAND_SUDO mkdir -p \\\"$replica_path\\\"; fi; fi 2>&1\" &" 
	eval $cmd > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID 2>&1
	WaitForTaskCompletion $! 0 1800
	if [ $? != 0 ]; then
		Logger "Cannot create remote replica path [$replica_path]." "CRITICAL"
		Logger "Command output:\n$RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID" "ERROR"
		exit 1
	fi

	cmd="$SSH_CMD \"if [ ! -w "$replica_path" ];then exit 1; fi 2>&1\" &"
	eval $cmd
	WaitForTaskCompletion $! 0 1800
	if [ $? != 0 ]; then
		Logger "Remote replica path [$replica_path] is not writable." "CRITICAL"
		exit 1
	fi
}

function CheckReplicaPaths {
	__CheckArguments 0 $# $FUNCNAME "$*"

	#INITIATOR_SYNC_DIR_CANN=$(realpath "$INITIATOR_SYNC_DIR")	#TODO: investigate realpath & readlink issues on MSYS and busybox here
	#TARGET_SYNC_DIR_CANN=$(realpath "$TARGET_SYNC_DIR")

	#if [ "$REMOTE_SYNC" != "yes" ]; then
	#	if [ "$INITIATOR_SYNC_DIR_CANN" == "$TARGET_SYNC_DIR_CANN" ]; then
	#		Logger "Master directory [$INITIATOR_SYNC_DIR] can't be the same as target directory." "CRITICAL"
	#		exit 1
	#	fi
	#fi

	_CheckReplicaPathsLocal "$INITIATOR_STATE_DIR"
	if [ "$REMOTE_SYNC" == "no" ]; then
		_CheckReplicaPathsLocal "$TARGET_STATE_DIR"
	else
		_CheckReplicaPathsRemote "$TARGET_STATE_DIR"
	fi
}

function _CheckDiskSpaceLocal {
	local replica_path="${1}"
	__CheckArguments 1 $# $FUNCNAME "$*"

	Logger "Checking minimum disk space in [$replica_path]." "NOTICE"

	local initiator_space=$(df -P "$replica_path" | tail -1 | awk '{print $4}')
	if [ $initiator_space -lt $MINIMUM_SPACE ]; then
		Logger "There is not enough free space on initiator [$initiator_space KB]." "WARN"
	fi
}

function _CheckDiskSpaceRemote {
	local replica_path="${1}"
	__CheckArguments 1 $# $FUNCNAME "$*"

	Logger "Checking minimum disk space on target [$replica_path]." "NOTICE"
	
	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd="$SSH_CMD \"$COMMAND_SUDO df -P \\\"$replca_path\\\"\" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID 2>&1 &"
	eval $cmd
	WaitForTaskCompletion $! 0 1800
	if [ $? != 0 ]; then
		Logger "Cannot get free space on target [$replica_path]." "ERROR"
		Logger "Command output:\n$(cat $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID)"
	else
		local target_space=$(cat $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID | tail -1 | awk '{print $4}')
		if [ $target_space -lt $MINIMUM_SPACE ]; then
			Logger "There is not enough free space on target [$replica_path]." "WARN"
		fi
	fi
}

function CheckDiskSpace {
	__CheckArguments 0 $# $FUNCNAME "$*"

	_CheckDiskSpaceLocal "$INITIATOR_SYNC_DIR"
	if [ "$REMOTE_SYNC" == "no" ]; then
		_CheckDiskSpaceLocal "$TARGET_SYNC_DIR"
	else
		_CheckDiskSpaceRemote "$TARGET_SYNC_DIR"
	fi
}

function RsyncExcludePattern {
	__CheckArguments 0 $# $FUNCNAME "$*"

	# Disable globbing so wildcards from exclusions don't get expanded
	set -f
	rest="$RSYNC_EXCLUDE_PATTERN"
	while [ -n "$rest" ]
	do
		# Take the string until first occurence until $PATH_SEPARATOR_CHAR
		str=${rest%%;*}
		# Handle the last case
		if [ "$rest" = "${rest/$PATH_SEPARATOR_CHAR/}" ]; then
			rest=
		else
			# Cut everything before the first occurence of $PATH_SEPARATOR_CHAR
			rest=${rest#*$PATH_SEPARATOR_CHAR}
		fi

		if [ "$RSYNC_EXCLUDE" == "" ]; then
			RSYNC_EXCLUDE="--exclude=\"$str\""
		else
			RSYNC_EXCLUDE="$RSYNC_EXCLUDE --exclude=\"$str\""
		fi
	done
	set +f
}

function RsyncExcludeFrom {
	__CheckArguments 0 $# $FUNCNAME "$*"

	if [ ! "$RSYNC_EXCLUDE_FROM" == "" ]; then
		## Check if the exclude list has a full path, and if not, add the config file path if there is one
		if [ "$(basename $RSYNC_EXCLUDE_FROM)" == "$RSYNC_EXCLUDE_FROM" ]; then
			RSYNC_EXCLUDE_FROM=$(dirname $ConfigFile)/$RSYNC_EXCLUDE_FROM
		fi

		if [ -e "$RSYNC_EXCLUDE_FROM" ]; then
			RSYNC_EXCLUDE="$RSYNC_EXCLUDE --exclude-from=\"$RSYNC_EXCLUDE_FROM\""
		fi
	fi
}

function _WriteLockFilesLocal {
	local lockfile="${1}"
	__CheckArguments 1 $# $FUNCNAME "$*"

	$COMMAND_SUDO echo "$SCRIPT_PID@$SYNC_ID" > "$lockfile" #TODO: Determine best format for lockfile for v2
	if [ $?	!= 0 ]; then
		Logger "Could not create lock file [$lockfile]." "CRITICAL"
		exit 1
	else
		Logger "Locked replica on [$lockfile]." "DEBUG"
	fi
}

function _WriteLockFilesRemote {
	local lockfile="${1}"
	__CheckArguments 1 $# $FUNCNAME "$*"

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHosts

	cmd="$SSH_CMD \"echo $SCRIPT_PID@$SYNC_ID | $COMMAND_SUDO tee \\\"$lock_file\\\" > /dev/null \"" &	
	eval $cmd
	WaitForTaskCompletion $? 0 1800
	if [ $? != 0 ]; then
		Logger "Could not set lock on remote target replica." "CRITICAL"
		exit 1
	else
		Logger "Locked remote target replica." "DEBUG"
	fi
}

function WriteLockFiles {
	__CheckArguments 0 $# $FUNCNAME "$*"

	_WriteLockFilesLocal "$INITIATOR_LOCKFILE"
	if [ "$REMOTE_SYNC" != "yes" ]; then
		_WriteLockFilesLocal "$TARGET_LOCKFILE"
	else
		_WriteLockFilesRemote "$TARGET_LOCKFILE"
	fi
}	

function _CheckLocksLocal {
	local lockfile="${1}"
	__CheckArguments 1 $# $FUNCNAME "$*"

	if [ -f "$lockfile" ]; then
		local lockfile_content=$(cat $lockfile)
		Logger "Master lock pid present: $lockfile_content" "DEBUG"
		local lock_pid=${lockfile_content%@*}
		local lock_sync_id=${lockfile_content#*@}
		ps -p$lock_pid > /dev/null 2>&1
		if [ $? != 0 ]; then
			Logger "There is a dead osync lock in [$lockfile]. Instance [$lock_pid] no longer running. Resuming." "NOTICE"
		else
			Logger "There is already a local instance of osync running [$lock_pid]. Cannot start." "CRITICAL"
			exit 1
		fi
	fi
}

function _CheckLocksRemote { #TODO: Rewrite this a bit more beautiful
	local lockfile="${1}"
	__CheckArguments 1 $# $FUNCNAME "$*"

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHosts

	cmd="$SSH_CMD \"if [ -f \\\"$lockfile\\\" ]; then cat \\\"$lockfile\\\"; fi\" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID" &
	eval $cmd
	WaitForTaskCompletion $? 0 1800
	if [ $? != 0 ]; then
		if [ -f $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID ]; then
			local lockfile_content=$(cat $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID)
		else
			Logger "No remote lockfile found." "NOTICE"
		fi
	else
		Logger "Cannot get remote lockfile." "CRITICAL"
		exit 1
	fi

	local lock_pid=${lockfile_content%@*}
	local lock_sync_id=${lockfile_content#*@}

	if [ "$lock_pid" != "" ] && [ "$lock_sync_id" != "" ]; then
		Logger "Remote lock is: $lock_pid@$lock_sync_id" "DEBUG"

		ps -p$lock_pid > /dev/null 2>&1
		if [ $? != 0 ]; then
			if [ "$lock_sync_id" == "$SYNC_ID" ]; then
				Logger "There is a dead osync lock on target replica that corresponds to this initiator sync id [$lock_sync_id]. Instance [$lock_pid] no longer running. Resuming." "NOTICE"
			else
				if [ "$FORCE_STRANGER_LOCK_RESUME" == "yes" ]; then
					Logger "WARNING: There is a dead osync lock on target replica that does not correspond to this initiator sync-id [$lock_sync_id]. Forcing resume." "WARN"
				else
					Logger "There is a dead osync lock on target replica that does not correspond to this initiator sync-id [$lock_sync_id]. Will not resume." "CRITICAL"
					exit 1
				fi
			fi
		else
			Logger "There is already a local instance of osync that locks target replica [$lock_pid@$lock_sync_id]. Cannot start." "CRITICAL"
			exit 1
		fi
	fi
}

function CheckLocks {
	__CheckArguments 0 $# $FUNCNAME "$*"

	if [ $_NOLOCKS -eq 1 ]; then
		return 0
	fi

	# Don't bother checking for locks when FORCE_UNLOCK is set
	if [ $FORCE_UNLOCK -eq 1 ]; then
		WriteLockFiles
		if [ $? != 0 ]; then
			exit 1
		fi
	fi
	_CheckLocksLocal "$INITIATOR_LOCKFILE"
	if [ "$REMOTE_SYNC" != "yes" ]; then
		_CheckLocksLocal "$TARGET_LOCKFILE"
	else
		_CheckLocksRemote "$TARGET_LOCKFILE"
	fi

	WriteLockFiles
}

function _UnlockReplicasLocal {
	local lockfile="${1}"
	__CheckArguments 1 $# $FUNCNAME "$*"

	if [ -f "$lockfile" ]; then
		$COMMAND_SUDO rm "$lockfile"
		if [ $? != 0 ]; then
			Logger "Could not unlock local replica." "ERROR"
		else
			Logger "Removed local replica lock." "DEBUG"
		fi
	fi
}

function _UnlockReplicasRemote {
	local lockfile="${1}"
	__CheckArguments 1 $# $FUNCNAME "$*"

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd="$SSH_CMD \"if [ -f \\\"$localfile\\\" ]; then $COMMAND_SUDO rm \\\"$lockfile\\\"; fi 2>&1\"" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID &
	eval $cmd
	WaitForTaskCompletion $? 0 1800
	if [ $? != 0 ]; then
		Logger "Could not unlock remote replica." "ERROR"
		Logger "Command Output:\n$(cat $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID)" "NOTICE"
	else
		Logger "Removed remote replica lock." "DEBUG"
	fi
}

function UnlockReplicas {
	__CheckArguments 0 $# $FUNCNAME "$*"

	if [ $_NOLOCKS -eq 1 ]; then
		return 0
	fi

	_UnlockReplicasLocal "$INITIATOR_LOCKFILE"
	if [ "$REMOTE_SYNC" != "yes" ]; then
		_UnlockReplicasLocal "$TARGET_LOCKFILE"
	else
		_UnlockReplicasRemote "$TARGET_LOCKFILE"
	fi
}

###### Sync core functions

	## Rsync does not like spaces in directory names, considering it as two different directories. Handling this schema by escaping space.
	## It seems this only happens when trying to execute an rsync command through eval $rsync_cmd on a remote host.
	## So i'm using unescaped $INITIATOR_SYNC_DIR for local rsync calls and escaped $ESC_INITIATOR_SYNC_DIR for remote rsync calls like user@host:$ESC_INITIATOR_SYNC_DIR
	## The same applies for target sync dir..............................................T.H.I.S..I.S..A..P.R.O.G.R.A.M.M.I.N.G..N.I.G.H.T.M.A.R.E

function tree_list {
	local replica_path="${1}" # path to the replica for which a tree needs to be constructed
	local replica_type="${2}" # replica type: initiator, target
	local tree_filename="${3}" # filename to output tree (will be prefixed with $replica_type)
	__CheckArguments 3 $# $FUNCNAME "$*"

	local escaped_replica_path=$(EscapeSpaces "$replica_path") #TODO: See if escpaed still needed when using ' instead of " for command eval

	Logger "Creating $replica_type replica file list [$replica_path]." "NOTICE"
	if [ "$REMOTE_SYNC" == "yes" ] && [ "$replica_type" == "target" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -8 --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE -e \"$RSYNC_SSH_CMD\" --list-only $REMOTE_USER@$REMOTE_HOST:\"$escaped_replica_path/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/osync_$replica_type_$SCRIPT_PID\" &"
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -8 --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --list-only \"$replica_path/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/osync_$replica_type_$SCRIPT_PID\" &"
	fi
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	## Redirect commands stderr here to get rsync stderr output in logfile
	eval $rsync_cmd 2>> "$LOG_FILE"
	child_pid=$!
	WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
	retval=$?
	## Retval 24 = some files vanished while creating list
	if ([ $retval == 0 ] || [ $retval == 24 ]) && [ -f $RUN_DIR/osync_$replica_type_$SCRIPT_PID ]; then
		mv -f $RUN_DIR/osync_$replica_type_$SCRIPT_PID "$INITIATOR_STATE_DIR/$replica_type$tree_filename"
		return $?
	else
		Logger "Cannot create replica file list." "CRITICAL"
		exit $retval
	fi
}

# delete_list(replica, tree-file-after, tree-file-current, deleted-list-file, deleted-failed-list-file): Creates a list of files vanished from last run on replica $1 (initiator/target)
function delete_list {
	local replica_type="${1}" # replica type: initiator, target
	local tree_file_after="${2}" # tree-file-after, will be prefixed with replica type
	local tree_file_current="${3}" # tree-file-current, will be prefixed with replica type
	local deleted_list_file="${4}" # file containing deleted file list, will be prefixed with replica type
	local deleted_failed_list_file="${5}" # file containing files that couldn't be deleted on last run, will be prefixed with replica type
	__CheckArguments 5 $# $FUNCNAME "$*"

	# TODO: Check why external filenames are used (see _DRYRUN option because of NOSUFFIX)

	Logger "Creating $replica_type replica deleted file list." "NOTICE"
	if [ -f "$INITIATOR_STATE_DIR/$replica_type$TREE_AFTER_FILENAME_NO_SUFFIX" ]; then
		## Same functionnality, comm is much faster than grep but is not available on every platform
		if type -p comm > /dev/null 2>&1
		then
			cmd="comm -23 \"$INITIATOR_STATE_DIR/$replica_type$TREE_AFTER_FILENAME_NO_SUFFIX\" \"$INITIATOR_STATE_DIR/$replica_type$tree_file_current\" > \"$INITIATOR_STATE_DIR/$replica_type$deleted_list_file\""
		else
			## The || : forces the command to have a good result
			cmd="(grep -F -x -v -f \"$INITIATOR_STATE_DIR/$replica_type$tree_file_current\" \"$INITIATOR_STATE_DIR/$replica_type$TREE_AFTER_FILENAME_NO_SUFFIX\" || :) > \"$INITIATOR_STATE_DIR/$replica_type$deleted_list_file\""
		fi

		Logger "CMD: $cmd" "DEBUG"
		eval $cmd 2>> "$LOG_FILE"
		retval=$?

		# Add delete failed file list to current delete list and then empty it
		if [ -f "$INITIATOR_STATE_DIR/$replica_type$deleted_failed_list_file" ]; then
			cat "$INITIATOR_STATE_DIR/$replica_type$deleted_failed_list_file" >> "$INITIATOR_STATE_DIR/$replica_type$deleted_list_file"
			rm -f "$INITIATOR_STATE_DIR/$replica_type$deleted_failed_list_file"
		fi

		return $retval
	else
		touch "$INITIATOR_STATE_DIR/$replica_type$deleted_list_file"
		return $retval
	fi
}

# sync_update(source replica, destination replica, delete_list_filename)
function sync_update {
	local source_replica="${1}" # Contains replica type of source: initiator, target
	local destination_replica="${2}" # Contains replica type of destination: initiator, target
	local delete_list_filename="${3}" # Contains deleted list filename, will be prefixed with replica type
	__CheckArguments 3 $# $FUNCNAME "$*"

	Logger "Updating $destination_replica replica." "NOTICE"
	if [ "$source_replica" == "initiator" ]; then
		SOURCE_DIR="$INITIATOR_SYNC_DIR"
		ESC_SOURCE_DIR=$(EscapeSpaces "$INITIATOR_SYNC_DIR")
		DEST_DIR="$TARGET_SYNC_DIR"
		ESC_DEST_DIR=$(EscapeSpaces "$TARGET_SYNC_DIR")
		BACKUP_DIR="$TARGET_BACKUP"
	else
		SOURCE_DIR="$TARGET_SYNC_DIR"
		ESC_SOURCE_DIR=$(EscapeSpaces "$TARGET_SYNC_DIR")
		DEST_DIR="$INITIATOR_SYNC_DIR"
		ESC_DEST_DIR=$(EscapeSpaces "$INITIATOR_SYNC_DIR")
		BACKUP_DIR="$INITIATOR_BACKUP"
	fi

	if [ "$REMOTE_SYNC" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		if [ "$source_replica" == "initiator" ]; then
			rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $BACKUP_DIR --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from=\"$INITIATOR_STATE_DIR/$source_replica$delete_list_filename\" --exclude-from=\"$INITIATOR_STATE_DIR/$destination_replica$delete_list_filename\" \"$SOURCE_DIR/\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_DEST_DIR/\" > $RUN_DIR/osync_update_$destination_replica_replica_$SCRIPT_PID 2>&1 &"
		else
			rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $BACKUP_DIR --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from=\"$INITIATOR_STATE_DIR/$destination_replica$delete_list_filename\" --exclude-from=\"$INITIATOR_STATE_DIR/$source_replica$delete_list_filename\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_SOURCE_DIR/\" \"$DEST_DIR/\" > $RUN_DIR/osync_update_$destination_replica_replica_$SCRIPT_PID 2>&1 &"
		fi
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $SYNC_OPTS $BACKUP_DIR --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from=\"$INITIATOR_STATE_DIR/$source_replica$delete_list_filename\" --exclude-from=\"$INITIATOR_STATE_DIR/$destination_replica$delete_list_filename\" \"$SOURCE_DIR/\" \"$DEST_DIR/\" > $RUN_DIR/osync_update_$destination_replica_replica_$SCRIPT_PID 2>&1 &"
	fi
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	eval "$rsync_cmd"
	child_pid=$!
	WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
	retval=$?
	if [ $_VERBOSE -eq 1 ] && [ -f $RUN_DIR/osync_update_$destination_replica_replica_$SCRIPT_PID ]; then
		Logger "List:\n$(cat $RUN_DIR/osync_update_$destination_replica_replica_$SCRIPT_PID)" "NOTICE"
	fi

	if [ $retval != 0 ] && [ $retval != 24 ]; then
		Logger "Updating $destination_replica replica failed. Stopping execution." "CRITICAL"
		if [ $_VERBOSE -eq 0 ] && [ -f $RUN_DIR/osync_update_$destination_replica_replica_$SCRIPT_PID ]; then
			Logger "Rsync output:\n$(cat $RUN_DIR/osync_update_$destination_replica_replica_$SCRIPT_PID)" "NOTICE"
		fi
		exit $retval
	else
		Logger "Updating $destination_replica replica succeded." "NOTICE"
		return 0
	fi
}

# delete_local(replica dir, delete file list, delete dir, delete failed file)
function _delete_local {
	local replica_dir="${1}" # Full path to replica
	local deleted_list_file="${2}" # file containing deleted file list, will be prefixed with replica type
	local deletion_dir="${3}" # deletion dir in format .[workdir]/deleted
	local deleted_failed_list_file="${4}" # file containing files that couldn't be deleted on last run, will be prefixed with replica type
	__CheckArguments 4 $# $FUNCNAME "$*"

	## On every run, check wheter the next item is already deleted because it's included in a directory already deleted
	previous_file=""
	OLD_IFS=$IFS
	IFS=$'\r\n'
	for files in $(cat "$INITIATOR_STATE_DIR/$deleted_list_file")
	do
		if [[ "$files" != "$previous_file/"* ]] && [ "$files" != "" ]; then
			if [ "$SOFT_DELETE" != "no" ]; then
				if [ ! -d "$replica_dir$deletion_dir" ]; then
					mkdir -p "$replica_dir$deletion_dir"
					if [ $? != 0 ]; then
						Logger "Cannot create replica deletion directory." "ERROR"
					fi
				fi

				if [ $_VERBOSE -eq 1 ]; then
					Logger "Soft deleting $replica_dir$files" "NOTICE"
				fi

				if [ $_DRYRUN -ne 1 ]; then
					if [ -e "$replica_dir$deletion_dir/$files" ]; then
						rm -rf "$replica_dir$deletion_dir/$files"
					fi
					# In order to keep full path on soft deletion, create parent directories before move
					parentdir="$(dirname "$files")"
					if [ "$parentdir" != "." ]; then
						mkdir --parents "$replica_dir$deletion_dir/$parentdir"
						mv -f "$replica_dir$files" "$replica_dir$deletion_dir/$parentdir"
					else
						mv -f "$replica_dir$files" "$replica_dir$deletion_dir"
					fi
					if [ $? != 0 ]; then
						Logger "Cannot move $replica_dir$files to deletion directory." "ERROR"
						echo "$files" >> "$INITIATOR_STATE_DIR/$deleted_failed_list_file"
					fi
				fi
			else
				if [ $_VERBOSE -eq 1 ]; then
					Logger "Deleting $replica_dir$files" "NOTICE"
				fi

				if [ $_DRYRUN -ne 1 ]; then
					rm -rf "$replica_dir$files"
					if [ $? != 0 ]; then
						Logger "Cannot delete $replica_dir$files" "ERROR"
						echo "$files" >> "$INITIATOR_STATE_DIR/$deleted_failed_list_file"
					fi
				fi
			fi
			previous_file="$files"
		fi
	done
	IFS=$OLD_IFS
}

function _delete_remote {
	local replica_dir="${1}" # Full path to replica
	local deleted_list_file="${2}" # file containing deleted file list, will be prefixed with replica type
	local deletion_dir="${3}" # deletion dir in format .[workdir]/deleted
	local deleted_failed_list_file="${4}" # file containing files that couldn't be deleted on last run, will be prefixed with replica type
	__CheckArguments 4 $# $FUNCNAME "$*"

	## This is a special coded function. Need to redelcare local functions on remote host, passing all needed variables as escaped arguments to ssh command.
	## Anything beetween << ENDSSH and ENDSSH will be executed remotely

	# Additionnaly, we need to copy the deletetion list to the remote state folder
	ESC_DEST_DIR="$(EscapeSpaces "$TARGET_STATE_DIR")"
	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" \"$INITIATOR_STATE_DIR/$2\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_DEST_DIR/\" > $RUN_DIR/osync_remote_deletion_list_copy_$SCRIPT_PID 2>&1"
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	eval $rsync_cmd 2>> "$LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot copy the deletion list to remote replica." "CRITICAL"
		if [ -f $RUN_DIR/osync_remote_deletion_list_copy_$SCRIPT_PID ]; then
			Logger "$(cat $RUN_DIR/osync_remote_deletion_list_copy_$SCRIPT_PID)" "CRITICAL" #TODO: remote deletion is critical. local deletion isn't. What to do ?
		fi
		exit 1
	fi

$SSH_CMD error_alert=0 sync_on_changes=$sync_on_changes _SILENT=$_SILENT _DEBUG=$_DEBUG _DRYRUN=$_DRYRUN _VERBOSE=$_VERBOSE COMMAND_SUDO=$COMMAND_SUDO FILE_LIST="$(EscapeSpaces "$TARGET_STATE_DIR/$deleted_list_file")" REPLICA_DIR="$(EscapeSpaces "$replica_dir")" DELETE_DIR="$(EscapeSpaces "$deletion_dir")" FAILED_DELETE_LIST="$(EscapeSpaces "$TARGET_STATE_DIR/$deleted_failed_list_file")" 'bash -s' << 'ENDSSH' > $RUN_DIR/osync_remote_deletion_$SCRIPT_PID 2>&1 &

	## The following lines are executed remotely
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

		# Special case in daemon mode we should timestamp instead of counting seconds
		if [ $sync_on_changes -eq 1 ]; then
			prefix="$(date) - "
		else
			prefix="RTIME: $SECONDS - "
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
			if [ "$_DEBUG" == "yes" ]; then
				_logger "$prefix$value"
			fi
		else
			_logger "\e[41mLogger function called without proper loglevel.\e[0m"
			_logger "$prefix$value"
		fi
	}
	
	## Empty earlier failed delete list
	> "$FAILED_DELETE_LIST"

	## On every run, check wheter the next item is already deleted because it's included in a directory already deleted
	previous_file=""
	OLD_IFS=$IFS
	IFS=$'\r\n'
	for files in $(cat "$FILE_LIST")
	do
		if [[ "$files" != "$previous_file/"* ]] && [ "$files" != "" ]; then
			if [ ! -d "$REPLICA_DIR$DELETE_DIR" ]; then
					$COMMAND_SUDO mkdir -p "$REPLICA_DIR$DELETE_DIR"
					if [ $? != 0 ]; then
						Logger "Cannot create replica deletion directory." "ERROR"
					fi
				fi

			if [ "$SOFT_DELETE" != "no" ]; then
				if [ $_VERBOSE -eq 1 ]; then
					Logger "Soft deleting $REPLICA_DIR$files" "NOTICE"
				fi

				if [ $_DRYRUN -ne 1 ]; then
					if [ -e "$REPLICA_DIR$DELETE_DIR/$files" ]; then
						$COMMAND_SUDO rm -rf "$REPLICA_DIR$DELETE_DIR/$files"
					fi
					# In order to keep full path on soft deletion, create parent directories before move
					parentdir="$(dirname "$files")"
					if [ "$parentdir" != "." ]; then
						$COMMAND_SUDO mkdir --parents "$REPLICA_DIR$DELETE_DIR/$parentdir"
						$COMMAND_SUDO mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$DELETE_DIR/$parentdir"
					else
						$COMMAND_SUDO mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$DELETE_DIR"
					fi
					if [ $? != 0 ]; then
						Logger "Cannot move $REPLICA_DIR$files to deletion directory." "ERROR"
						echo "$files" >> "$FAILED_DELETE_LIST"
					fi
				fi
			else
				if [ $_VERBOSE -eq 1 ]; then
					Logger "Deleting $REPLICA_DIR$files" "NOTICE"
				fi

				if [ $_DRYRUN -ne 1 ]; then
					$COMMAND_SUDO rm -rf "$REPLICA_DIR$files"
					if [ $? != 0 ]; then
						Logger "Cannot delete $REPLICA_DIR$files" "ERROR"
						echo "$files" >> "$TARGET_STATE_DIR/$FAILED_DELETE_LIST"
					fi
				fi
			fi
			previous_file="$files"
		fi
	done
	IFS=$OLD_IFS
ENDSSH

	## Need to add a trivial sleep time to give ssh time to log to local file
	sleep 5

	## Copy back the deleted failed file list
	ESC_SOURCE_FILE="$(EscapeSpaces "$TARGET_STATE_DIR/$deleted_failed_list_file")"
	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_SOURCE_FILE\" \"$INITIATOR_STATE_DIR\" > $RUN_DIR/osync_remote_failed_deletion_list_copy_$SCRIPT_PID"
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	eval $rsync_cmd 2>> "$LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot copy back the failed deletion list to initiator replica." "CRITICAL"
		if [ -f $RUN_DIR/osync_remote_failed_deletion_list_copy_$SCRIPT_PID ]; then
			Logger "$(cat $RUN_DIR/osync_remote_failed_deletion_list_copy_$SCRIPT_PID)" "NOTICE"
		fi
		exit 1
	fi



	exit $?
}


# delete_propagation(replica name, deleted_list_filename, deleted_failed_file_list)
function deletion_propagation {
	local replica_type="${1}" # Contains replica type: initiator, target
	local deleted_list_file="${2}" # file containing deleted file list, will be prefixed with replica type
	local deleted_failed_list_file="${3}" # file containing files that couldn't be deleted on last run, will be prefixed with replica type
	__CheckArguments 3 $# $FUNCNAME "$*"

	Logger "Propagating deletions to $replica_type replica." "NOTICE"

	if [ "$replica_type" == "initiator" ]; then
		REPLICA_DIR="$INITIATOR_SYNC_DIR"
		DELETE_DIR="$INITIATOR_DELETE_DIR"

		_delete_local "$REPLICA_DIR" "target$deleted_list_file" "$DELETE_DIR" "target$deleted_failed_list_file" &
		child_pid=$!
		WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
		retval=$?
		if [ $retval != 0 ]; then
			Logger "Deletion on replica $replica_type failed." "CRITICAL"
			exit 1
		fi
	else
		REPLICA_DIR="$TARGET_SYNC_DIR"
		DELETE_DIR="$TARGET_DELETE_DIR"

		if [ "$REMOTE_SYNC" == "yes" ]; then
			_delete_remote "$REPLICA_DIR" "initiator$deleted_list_file" "$DELETE_DIR" "initiator$deleted_failed_list_file" &
		else
			_delete_local "$REPLICA_DIR" "initiator$deleted_list_file" "$DELETE_DIR" "initiator$deleted_failed_list_file" &
		fi
		child_pid=$!
		WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
		retval=$?
		if [ $retval == 0 ]; then
			if [ -f $RUN_DIR/osync_remote_deletion_$SCRIPT_PID ] && [ $_VERBOSE -eq 1 ]; then
				Logger "Remote:\n$(cat $RUN_DIR/osync_remote_deletion_$SCRIPT_PID)" "DEBUG"
			fi
			return $retval
		else
			Logger "Deletion on remote system failed." "CRITICAL"
			if [ -f $RUN_DIR/osync_remote_deletion_$SCRIPT_PID ]; then
				Logger "Remote:\n$(cat $RUN_DIR/osync_remote_deletion_$SCRIPT_PID)" "CRITICAL"
			fi
			exit 1
		fi
	fi
}

###### Sync function in 5 steps of each 2 runs (functions above)
######
###### Step 1: Create current tree list for initiator and target replicas (Steps 1M and 1S)
###### Step 2: Create deleted file list for initiator and target replicas (Steps 2M and 2S)
###### Step 3: Update initiator and target replicas (Steps 3M and 3S, order depending on conflict prevalence)
###### Step 4: Deleted file propagation to initiator and target replicas (Steps 4M and 4S)
###### Step 5: Create after run tree list for initiator and target replicas (Steps 5M and 5S)

function Sync {
	__CheckArguments 0 $# $FUNCNAME "$*"

	Logger "Starting synchronization task." "NOTICE"
	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	if [ -f "$INITIATOR_LAST_ACTION" ] && [ "$RESUME_SYNC" != "no" ]; then
		resume_sync=$(cat "$INITIATOR_LAST_ACTION")
		if [ -f "$INITIATOR_RESUME_COUNT" ]; then
			resume_count=$(cat "$INITIATOR_RESUME_COUNT")
		else
			resume_count=0
		fi

		if [ $resume_count -lt $RESUME_TRY ]; then
			if [ "$resume_sync" != "sync.success" ]; then
				Logger "WARNING: Trying to resume aborted osync execution on $($STAT_CMD "$INITIATOR_LAST_ACTION") at task [$resume_sync]. [$resume_count] previous tries." "WARN"
				echo $(($resume_count+1)) > "$INITIATOR_RESUME_COUNT"
			else
				resume_sync=none
			fi
		else
			Logger "Will not resume aborted osync execution. Too much resume tries [$resume_count]." "WARN"
			echo "noresume" > "$INITIATOR_LAST_ACTION"
			echo "0" > "$INITIATOR_RESUME_COUNT"
			resume_sync=none
		fi
	else
		resume_sync=none
	fi


	################################################################################################################################################# Actual sync begins here

	## This replaces the case statement because ;& operator is not supported in bash 3.2... Code is more messy than case :(
	if [ "$resume_sync" == "none" ] || [ "$resume_sync" == "noresume" ] || [ "$resume_sync" == "initiator-replica-tree.fail" ]; then
		#initiator_tree_current
		tree_list "$INITIATOR_SYNC_DIR" initiator "$TREE_CURRENT_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[0]}.success" > "$INITIATOR_LAST_ACTION"
		else
			echo "${SYNC_ACTION[0]}.fail" > "$INITIATOR_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[0]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[1]}.fail" ]; then
		#target_tree_current
		tree_list "$TARGET_SYNC_DIR" target "$TREE_CURRENT_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[1]}.success" > "$INITIATOR_LAST_ACTION"
		else
			echo "${SYNC_ACTION[1]}.fail" > "$INITIATOR_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[1]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[2]}.fail" ]; then
		delete_list initiator "$TREE_AFTER_FILENAME" "$TREE_CURRENT_FILENAME" "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[2]}.success" > "$INITIATOR_LAST_ACTION"
		else
			echo "${SYNc_ACTION[2]}.fail" > "$INITIATOR_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[2]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.fail" ]; then
		delete_list target "$TREE_AFTER_FILENAME" "$TREE_CURRENT_FILENAME" "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[3]}.success" > "$INITIATOR_LAST_ACTION"
		else
			echo "${SYNC_ACTION[3]}.fail" > "$INITIATOR_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.fail" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.fail" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.success" ]; then
		if [ "$CONFLICT_PREVALANCE" != "initiator" ]; then
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.fail" ]; then
				sync_update target initiator "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[4]}.success" > "$INITIATOR_LAST_ACTION"
				else
					echo "${SYNC_ACTION[4]}.fail" > "$INITIATOR_LAST_ACTION"
				fi
				resume_sync="resumed"
			fi
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.fail" ]; then
				sync_update initiator target "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[5]}.success" > "$INITIATOR_LAST_ACTION"
				else
					echo "${SYNC_ACTION[5]}.fail" > "$INITIATOR_LAST_ACTION"
				fi
				resume_sync="resumed"
			fi
		else
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.fail" ]; then
				sync_update initiator target "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[5]}.success" > "$INITIATOR_LAST_ACTION"
				else
					echo "${SYNC_ACTION[5]}.fail" > "$INITIATOR_LAST_ACTION"
				fi
				resume_sync="resumed"
			fi
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.fail" ]; then
				sync_update target initiator "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[4]}.success" > "$INITIATOR_LAST_ACTION"
				else
					echo "${SYNC_ACTION[4]}.fail" > "$INITIATOR_LAST_ACTION"
				fi
				resume_sync="resumed"
			fi
		fi
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[6]}.fail" ]; then
		deletion_propagation target "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[6]}.success" > "$INITIATOR_LAST_ACTION"
		else
			echo "${SYNC_ACTION[6]}.fail" > "$INITIATOR_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[6]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[7]}.fail" ]; then
		deletion_propagation initiator "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[7]}.success" > "$INITIATOR_LAST_ACTION"
		else
			echo "${SYNC_ACTION[7]}.fail" > "$INITIATOR_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[7]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[8]}.fail" ]; then
		#initiator_tree_after
		tree_list "$INITIATOR_SYNC_DIR" initiator "$TREE_AFTER_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[8]}.success" > "$INITIATOR_LAST_ACTION"
		else
			echo "${SYNC_ACTION[8]}.fail" > "$INITIATOR_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[8]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[9]}.fail" ]; then
		#target_tree_after
		tree_list "$TARGET_SYNC_DIR" target "$TREE_AFTER_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[9]}.success" > "$INITIATOR_LAST_ACTION"
		else
			echo "${SYNC_ACTION[9]}.fail" > "$INITIATOR_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi

	Logger "Finished synchronization task." "NOTICE"
	echo "${SYNC_ACTION[10]}" > "$INITIATOR_LAST_ACTION"

	echo "0" > "$INITIATOR_RESUME_COUNT"
}

function _SoftDeleteLocal {
	local replica_type="${1}" # replica type (initiator, target)
	local replica_deletion_path="${2}" # Contains the full path to softdelete / backup directory without ending slash
	local change_time="${3}"
	__CheckArguments 3 $# $FUNCNAME "$*"

	if [ -d "$replica_deletion_path" ]; then
		if [ $_DRYRUN -eq 1 ]; then
			Logger "Listing files older than $change_time days on [$replica_type] replica. Won't remove anything." "NOTICE"
		else
			Logger "Removing files older than $change_time days on [$replica_type] replica." "NOTICE"
		fi
			if [ $_VERBOSE -eq 1 ]; then
			# Cannot launch log function from xargs, ugly hack
			$FIND_CMD "$replica_deletion_path/" -type f -ctime +$change_time -print0 | xargs -0 -I {} echo "Will delete file {}" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID
			Logger "Command output:\n$(cat $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID)" "NOTICE"
			$FIND_CMD "$replica_deletion_path/" -type d -empty -ctime +$change_time -print0 | xargs -0 -I {} echo "Will delete directory {}" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID
			Logger "Command output:\n$(cat $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID)" "NOTICE"
		fi
			if [ $_DRYRUN -ne 1 ]; then
			$FIND_CMD "$replica_deletion_path/" -type f -ctime +$change_time -print0 | xargs -0 -I {} rm -f "{}" && $FIND_CMD "$replica_deletion_path/" -type d -empty -ctime +$change_time -print0 | xargs -0 -I {} rm -rf "{}" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID 2>&1 &
		else
			Dummy &
		fi
		WaitForCompletion $? $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Error while executing cleanup on [$replica_type] replica." "ERROR"
			Logger "Command output:\n$(cat $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID)" "NOTICE"
		else
			Logger "Cleanup complete on [$replica_type] replica." "NOTICE"
		fi
	elif [ -d "$replica_deletion_path" ] && ! [ -w "$replica_deletion_path" ]; then
		Logger "Warning: [$replica_type] replica dir [$replica_deletion_path] isn't writable. Cannot clean old files." "ERROR"
	fi
}

function _SoftDeleteRemote {
	local replica_type="${1}"
	local replica_deletion_path="${2}" # Contains the full path to softdelete / backup directory without ending slash
	local change_time"${3}"
	__CheckArguments 3 $# $FUNCNAME "$*"

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	if [ $_DRYRUN -eq 1 ]; then
		Logger "Listing files older than $change_time days on target replica. Won't remove anything." "NOTICE"
	else
		Logger "Removing files older than $change_time days on target replica." "NOTICE"
	fi
	
	if [ $_VERBOSE -eq 1 ]; then
		# Cannot launch log function from xargs, ugly hack
		eval "$SSH_CMD \"if [ -w \\\"$replica_deletion_path\\\" ]; then $COMMAND_SUDO $REMOTE_FIND_CMD \\\"$replica_deletion_path/\\\" -type f -ctime +$change_time -print0 | xargs -0 -I {} echo Will delete file {} && $REMOTE_FIND_CMD \\\"$replica_deletion_path/\\\" -type d -empty -ctime $change_time -print0 | xargs -0 -I {} echo Will delete directory {}; fi\"" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID
		Logger "Command output:\n$(cat $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID)" "NOTICE"
	fi

	if [ $_DRYRUN -ne 1 ]; then
		eval "$SSH_CMD \"if [ -w \\\"$replica_deletion_path\\\" ]; then $COMMAND_SUDO $REMOTE_FIND_CMD \\\"$replica_deletion_path/\\\" -type f -ctime +$change_time -print0 | xargs -0 -I {} rm -f \\\"{}\\\" && $REMOTE_FIND_CMD \\\"$replica_deletion_path/\\\" -type d -empty -ctime $change_time -print0 | xargs -0 -I {} rm -rf \\\"{}\\\"; fi 2>&1\"" > $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID &
	else
		Dummy &
	fi
	WaitForCompletion $? $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Error while executing cleanup on remote target replica." "ERROR"
		Logger "Command output:\n$(cat $RUN_DIR/osync_$FUNCNAME_$SCRIPT_PID)" "NOTICE"
	else
		Logger "Cleanup complete on target replica." "NOTICE"
	fi
}

function SoftDelete {
	__CheckArguments 0 $# $FUNCNAME "$*"

	if [ "$CONFLICT_BACKUP" != "no" ] && [ $CONFLICT_BACKUP_DAYS -ne 0 ]; then
		Logger "Running conflict backup cleanup." "NOTICE"

		_SoftDeleteLocal "intiator" "$INITIATOR_SYNC_DIR$INITIATOR_BACKUP_DIR" $CONFLICT_BACKUP_DAYS
		if [ "$REMOTE_SYNC" != "yes" ]; then
			_SoftDeleteLocal "target" "$TARGET_SYNC_DIR$TARGET_BACKUP_DIR" $CONFLICT_BACKUP_DAYS
		else
			_SoftDeleteRemote "target" "$TARGET_SYNC_DIR$TARGET_BACKUP_DIR" $CONFLICT_BACKUP_DAYS
		fi
	fi

	if [ "$SOFT_DELETE" != "no" ] && [ $SOFT_DELETE_DAYS -ne 0 ]; then
		Logger "Running soft deletion cleanup." "NOTICE"

		_SoftDeleteLocal "initiator" "$INITIATOR_SYNC_DIR$INITIATOR_DELETE_DIR" $SOFT_DELETE_DAYS
		if [ "$REMOTE_SYNC" != "yes" ]; then
			_SoftDeleteLocal "target" "$TARGET_SYNC_DIR$TARGET_DELETE_DIR" $SOFT_DELETE_DAYS
		else
			_SoftDeleteRemote "target" "$TARGET_SYNC_DIR$TARGET_DELETE_DIR" $SOFT_DELETE_DAYS
		fi
	fi	
}

function Init {
	__CheckArguments 0 $# $FUNCNAME "$*"

	# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace

	# Do not use exit and quit traps if osync runs in monitor mode
	if [ $sync_on_changes -eq 0 ]; then
		trap TrapStop SIGINT SIGKILL SIGHUP SIGTERM SIGQUIT
		trap TrapQuit SIGKILL EXIT
	else
		trap TrapQuit SIGTERM EXIT SIGKILL SIGHUP SIGQUIT
	fi

	if [ "$_DEBUG" == "yes" ]; then
		trap 'TrapError ${LINENO} $?' ERR
	fi

	MAIL_ALERT_MSG="Warning: Execution of osync instance $OSYNC_ID (pid $SCRIPT_PID) as $LOCAL_USER@$LOCAL_HOST produced errors on $(date)."

	## Test if target dir is a ssh uri, and if yes, break it down it its values
	if [ "${TARGET_SYNC_DIR:0:6}" == "ssh://" ]; then
		REMOTE_SYNC="yes"

		# remove leadng 'ssh://'
		uri=${TARGET_SYNC_DIR#ssh://*}
		if [[ "$uri" == *"@"* ]]; then
			# remove everything after '@'
			REMOTE_USER=${uri%@*}
		else
			REMOTE_USER=$LOCAL_USER
		fi

		if [ "$SSH_RSA_PRIVATE_KEY" == "" ]; then
			SSH_RSA_PRIVATE_KEY=~/.ssh/id_rsa
		fi

		# remove everything before '@'
		_hosturiandpath=${uri#*@}
		# remove everything after first '/'
		_hosturi=${_hosturiandpath%%/*}
		if [[ "$_hosturi" == *":"* ]]; then
			REMOTE_PORT=${_hosturi##*:}
		else
			REMOTE_PORT=22
		fi
		REMOTE_HOST=${_hosturi%%:*}

		# remove everything before first '/'
		TARGET_SYNC_DIR=${_hosturiandpath#*/}
	fi

	## Make sure there is only one trailing slash on path
	INITIATOR_SYNC_DIR="${INITIATOR_SYNC_DIR%/}/"
	TARGET_SYNC_DIR="${TARGET_SYNC_DIR%/}/"

	INITIATOR_STATE_DIR="$INITIATOR_SYNC_DIR$OSYNC_DIR/state"
	TARGET_STATE_DIR="$TARGET_SYNC_DIR$OSYNC_DIR/state"
	STATE_DIR="$OSYNC_DIR/state"
	INITIATOR_LOCKFILE="$INITIATOR_STATE_DIR/lock"
	TARGET_LOCKFILE="$TARGET_STATE_DIR/lock"

	## Working directories to keep backups of updated / deleted files
	INITIATOR_BACKUP_DIR="$OSYNC_DIR/backups"
	INITIATOR_DELETE_DIR="$OSYNC_DIR/deleted"
	TARGET_BACKUP_DIR="$OSYNC_DIR/backups"
	TARGET_DELETE_DIR="$OSYNC_DIR/deleted"

	## Partial downloads dirs
	PARTIAL_DIR=$OSYNC_DIR"_partial"

	## SSH compression
	if [ "$SSH_COMPRESSION" != "no" ]; then
		SSH_COMP=-C
	else
		SSH_COMP=
	fi

	## Define which runner (local bash or distant ssh) to use for standard commands and rsync commands
	if [ "$REMOTE_SYNC" == "yes" ]; then
		SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
		SCP_CMD="$(type -p scp) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY -P $REMOTE_PORT"
		RSYNC_SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY -p $REMOTE_PORT"
	fi

	## Support for older config files without RSYNC_EXECUTABLE option
	if [ "$RSYNC_EXECUTABLE" == "" ]; then
		RSYNC_EXECUTABLE=rsync
	fi

	## Sudo execution option
	if [ "$SUDO_EXEC" == "yes" ]; then
		if [ "$RSYNC_REMOTE_PATH" != "" ]; then
			RSYNC_PATH="sudo $RSYNC_REMOTE_PATH/$RSYNC_EXECUTABLE"
		else
			RSYNC_PATH="sudo $RSYNC_EXECUTABLE"
		fi
		COMMAND_SUDO="sudo"
	else
		if [ "$RSYNC_REMOTE_PATH" != "" ]; then
			RSYNC_PATH="$RSYNC_REMOTE_PATH/$RSYNC_EXECUTABLE"
		else
			RSYNC_PATH="$RSYNC_EXECUTABLE"
		fi
		COMMAND_SUDO=""
	fi

	## Set rsync default arguments
	RSYNC_ARGS="-rlptgoD"

	if [ "$PRESERVE_ACL" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -A"
	fi
	if [ "$PRESERVE_XATTR" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -X"
	fi
	if [ "$RSYNC_COMPRESS" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -z"
	fi
	if [ "$COPY_SYMLINKS" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -L"
	fi
	if [ "$KEEP_DIRLINKS" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -K"
	fi
	if [ "$PRESERVE_HARDLINKS" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -H"
	fi
	if [ "$CHECKSUM" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --checksum"
	fi
	if [ $_DRYRUN -eq 1 ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -n"
		DRY_WARNING="/!\ DRY RUN"
	fi

	if [ "$BANDWIDTH" != "" ] && [ "$BANDWIDTH" != "0" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --bwlimit=$BANDWIDTH"
	fi

	## Set sync only function arguments for rsync
	SYNC_OPTS="-u"

	if [ $_VERBOSE -eq 1 ]; then
		SYNC_OPTS=$SYNC_OPTS"i"
	fi

	if [ $stats -eq 1 ]; then
		SYNC_OPTS=$SYNC_OPTS" --stats"
	fi

	if [ "$PARTIAL" == "yes" ]; then
		SYNC_OPTS=$SYNC_OPTS" --partial --partial-dir=\"$PARTIAL_DIR\""
		RSYNC_EXCLUDE="$RSYNC_EXCLUDE --exclude=\"$PARTIAL_DIR\""
	fi

	## Conflict options
	if [ "$CONFLICT_BACKUP" != "no" ]; then
		INITIATOR_BACKUP="--backup --backup-dir=\"$INITIATOR_BACKUP_DIR\""
		TARGET_BACKUP="--backup --backup-dir=\"$TARGET_BACKUP_DIR\""
		if [ "$CONFLICT_BACKUP_MULTIPLE" == "yes" ]; then
			INITIATOR_BACKUP="$INITIATOR_BACKUP --suffix .$(date +%Y.%m.%d-%H.%M.%S)"
			TARGET_BACKUP="$TARGET_BACKUP --suffix .$(date +%Y.%m.%d-%H.%M.%S)"
		fi
	else
		INITIATOR_BACKUP=
		TARGET_BACKUP=
	fi

	## Add Rsync exclude patterns
	RsyncExcludePattern
	## Add Rsync exclude from file
	RsyncExcludeFrom

	## Filenames for state files
	if [ $_DRYRUN -eq 1 ]; then
		dry_suffix="-dry"
	fi

	TREE_CURRENT_FILENAME="-tree-current-$SYNC_ID$dry_suffix"
	TREE_AFTER_FILENAME="-tree-after-$SYNC_ID$dry_suffix"
	TREE_AFTER_FILENAME_NO_SUFFIX="-tree-after-$SYNC_ID"
	DELETED_LIST_FILENAME="-deleted-list-$SYNC_ID$dry_suffix"
	FAILED_DELETE_LIST_FILENAME="-failed-delete-$SYNC_ID$dry_suffix"
	INITIATOR_LAST_ACTION="$INITIATOR_STATE_DIR/last-action-$SYNC_ID$dry_suffix"
	INITIATOR_RESUME_COUNT="$INITIATOR_STATE_DIR/resume-count-$SYNC_ID$dry_suffix"

	## Sync function actions (0-9)
	SYNC_ACTION=(
	'initiator-replica-tree'
	'target-replica-tree'
	'initiator-deleted-list'
	'target-deleted-list'
	'update-initiator-replica'
	'update-target-replica'
	'delete-propagation-target'
	'delete-propagation-initiator'
	'initiator-replica-tree-after'
	'target-replica-tree-after'
	'sync.success'
	)

	## Set compression executable and extension
	COMPRESSION_LEVEL=3
	if type -p xz > /dev/null 2>&1
	then
		COMPRESSION_PROGRAM="| xz -$COMPRESSION_LEVEL"
		COMPRESSION_EXTENSION=.xz
	elif type -p lzma > /dev/null 2>&1
	then
		COMPRESSION_PROGRAM="| lzma -$COMPRESSION_LEVEL"
		COMPRESSION_EXTENSION=.lzma
	elif type -p pigz > /dev/null 2>&1
	then
		COMPRESSION_PROGRAM="| pigz -$COMPRESSION_LEVEL"
		COMPRESSION_EXTENSION=.gz
		COMPRESSION_OPTIONS=--rsyncable
	elif type -p gzip > /dev/null 2>&1
	then
		COMPRESSION_PROGRAM="| gzip -$COMPRESSION_LEVEL"
		COMPRESSION_EXTENSION=.gz
		COMPRESSION_OPTIONS=--rsyncable
	else
		COMPRESSION_PROGRAM=
		COMPRESSION_EXTENSION=
	fi
	ALERT_LOG_FILE="$ALERT_LOG_FILE$COMPRESSION_EXTENSION"
}

function InitLocalOSSettings {
	__CheckArguments 0 $# $FUNCNAME "$*"

	## If running under Msys, some commands don't run the same way
	## Using mingw version of find instead of windows one
	## Getting running processes is quite different
	## Ping command isn't the same
	if [ "$LOCAL_OS" == "msys" ]; then
		FIND_CMD=$(dirname $BASH)/find
		#TODO: The following command needs to be checked on msys. Does the $1 variable substitution work ?
		# PROCESS_TEST_CMD assumes there is a variable $pid
		PROCESS_TEST_CMD='ps -a | awk "{\$1=\$1}\$1" | awk "{print \$1}" | grep $pid'
		PING_CMD="ping -n 2"
	else
		FIND_CMD=find
		# PROCESS_TEST_CMD assumes there is a variable $pid
		PROCESS_TEST_CMD='ps -p$pid'
		PING_CMD="ping -c 2 -i .2"
	fi

	## Stat command has different syntax on Linux and FreeBSD/MacOSX
	if [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "BSD" ]; then
		STAT_CMD="stat -f \"%Sm\""
	else
		STAT_CMD="stat --format %y"
	fi
}

function InitRemoteOSSettings {
	__CheckArguments 0 $# $FUNCNAME "$*"

	## MacOSX does not use the -E parameter like Linux or BSD does (-E is mapped to extended attrs instead of preserve executability)
	if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -E"
	fi

	if [ "$REMOTE_OS" == "msys" ]; then
		REMOTE_FIND_CMD=$(dirname $BASH)/find
	else
		REMOTE_FIND_CMD=find
	fi
}

function Main {
	__CheckArguments 0 $# $FUNCNAME "$*"

	CreateStateDirs
	CheckLocks
	Sync
}

function Usage {
	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo $AUTHOR
	echo $CONTACT
	echo ""
	echo -e "\e[41mWARNING: This is an unstable dev build\e[0m"
	echo "You may use Osync with a full blown configuration file, or use its default options for quick command line sync."
	echo "Usage: osync.sh /path/to/config/file [OPTIONS]"
	echo "or     osync.sh --initiator=/path/to/initiator/replica --target=/path/to/target/replica [OPTIONS] [QUICKSYNC OPTIONS]"
	echo "or     osync.sh --initiator=/path/to/initiator/replica --target=ssh://[backupuser]@remotehost.com[:portnumber]//path/to/target/replica [OPTIONS] [QUICKSYNC OPTIONS]"
	echo ""
	echo "[OPTIONS]"
	echo "--dry             Will run osync without actually doing anything; just testing"
	echo "--silent          Will run osync without any output to stdout, used for cron jobs"
	echo "--verbose         Increases output"
	echo "--stats           Adds rsync transfer statistics to verbose output"
	echo "--partial         Allows rsync to keep partial downloads that can be resumed later (experimental)"
	echo "--no-maxtime      Disables any soft and hard execution time checks"
	echo "--force-unlock    Will override any existing active or dead locks on initiator and target replica"
	echo "--on-changes      Will launch a sync task after a short wait period if there is some file activity on initiator replica. You should try daemon mode instead"
	echo ""
	echo "[QUICKSYNC OPTIONS]"
	echo "--initiator=\"\"	Master replica path. Will contain state and backup directory (is mandatory)"
	echo "--target=\"\" 	Local or remote target replica path. Can be a ssh uri like ssh://user@host.com:22//path/to/target/replica (is mandatory)"
	echo "--rsakey=\"\"	Alternative path to rsa private key for ssh connection to target replica"
	echo "--sync-id=\"\"	Optional sync task name to identify this synchronization task when using multiple targets"
	echo ""
	echo "Additionnaly, you may set most osync options at runtime. eg:"
	echo "SOFT_DELETE_DAYS=365 osync.sh --initiator=/path --target=/other/path"
	echo ""
	exit 128
}

function SyncOnChanges {
	__CheckArguments 0 $# $FUNCNAME "$*"

	if ! type -p inotifywait > /dev/null 2>&1
	then
		Logger "No inotifywait command found. Cannot monitor changes." "CRITICAL"
		exit 1
	fi

	Logger "#### Running Osync in file monitor mode." "NOTICE"

	while true
	do
		if [ "$ConfigFile" != "" ]; then
			cmd="bash $osync_cmd \"$ConfigFile\" $opts"
		else
			cmd="bash $osync_cmd $opts"
		fi
		eval $cmd
		retval=$?
		if [ $retval != 0 ]; then
			Logger "osync child exited with error." "CRITICAL"
			exit $retval
		fi

		Logger "#### Monitoring now." "NOTICE"
		inotifywait --exclude $OSYNC_DIR $RSYNC_EXCLUDE -qq -r -e create -e modify -e delete -e move -e attrib --timeout "$MAX_WAIT" "$INITIATOR_SYNC_DIR" &
		sub_pid=$!
		wait $sub_pid
		retval=$?
		if [ $retval == 0 ]; then
			Logger "#### Changes detected, waiting $MIN_WAIT seconds before running next sync." "NOTICE"
			sleep $MIN_WAIT
		elif [ $retval == 2 ]; then
			Logger "#### $MAX_WAIT timeout reached, running sync." "NOTICE"
		else
			Logger "#### inotify error detected, waiting $MIN_WAIT seconds before running next sync." "ERROR"
			sleep $MIN_WAIT
		fi
	done

}

# Comand line argument flags
_DRYRUN=0
_SILENT=0

if [ "$_DEBUG" == "yes" ]
then
	_VERBOSE=1
else
	_VERBOSE=0
fi

stats=0
PARTIAL=0
FORCE_UNLOCK=0
no_maxtime=0
# Alert flags
opts=""
soft_alert_total=0
error_alert=0
soft_stop=0
quick_sync=0
sync_on_changes=0
_NOLOCKS=0
osync_cmd=$0

if [ $# -eq 0 ]
then
	Usage
fi

first=1
for i in "$@"
do
	case $i in
		--dry)
		_DRYRUN=1
		opts=$opts" --dry"
		;;
		--_SILENT)
		_SILENT=1
		opts=$opts" --_SILENT"
		;;
		--verbose)
		_VERBOSE=1
		opts=$opts" --_VERBOSE"
		;;
		--stats)
		stats=1
		opts=$opts" --stats"
		;;
		--partial)
		PARTIAL="yes"
		opts=$opts" --partial"
		;;
		--force-unlock)
		FORCE_UNLOCK=1
		opts=$opts" --force-unlock"
		;;
		--no-maxtime)
		no_maxtime=1
		opts=$opts" --no-maxtime"
		;;
		--help|-h|--version|-v)
		Usage
		;;
		--initiator=*)
		quick_sync=$(($quick_sync + 1))
		no_maxtime=1
		INITIATOR_SYNC_DIR=${i##*=}
		opts=$opts" --initiator=\"$INITIATOR_SYNC_DIR\""
		;;
		--target=*)
		quick_sync=$(($quick_sync + 1))
		TARGET_SYNC_DIR=${i##*=}
		opts=$opts" --target=\"$TARGET_SYNC_DIR\""
		no_maxtime=1
		;;
		--rsakey=*)
		SSH_RSA_PRIVATE_KEY=${i##*=}
		opts=$opts" --rsakey=\"$SSH_RSA_PRIVATE_KEY\""
		;;
		--sync-id=*)
		SYNC_ID=${i##*=}
		opts=$opts" --sync-id=\"$SYNC_ID\""
		;;
		--on-changes)
		sync_on_changes=1
		_NOLOCKS=1
		;;
		--no-locks)
		_NOLOCKS=1
		;;
		*)
		if [ $first == "0" ]; then
			Logger "Unknown option '$i'" "CRITICAL"
			Usage
		fi
		;;
	esac
	first=0
done

# Remove leading space if there is one
opts="${opts# *}"

CheckEnvironment
if [ $? == 0 ]
then

	## Here we set default options for quicksync tasks when no configuration file is provided.

	if [ $quick_sync -eq 2 ]; then
		if [ "$SYNC_ID" == "" ]; then
			SYNC_ID="quicksync_task"
		fi

		# Let the possibility to initialize those values directly via command line like SOFT_DELETE_DAYS=60 ./osync.sh

		if [ "$MINIMUM_SPACE" == "" ]; then
			MINIMUM_SPACE=1024
		fi

		if [ "$CONFLICT_BACKUP_DAYS" == "" ]; then
			CONFLICT_BACKUP_DAYS=30
		fi

		if [ "$SOFT_DELETE_DAYS" == "" ]; then
			SOFT_DELETE_DAYS=30
		fi

		if [ "$RESUME_TRY" == "" ]; then
			RESUME_TRY=1
		fi

		if [ "$SOFT_MAX_EXEC_TIME" == "" ]; then
			SOFT_MAX_EXEC_TIME=0
		fi

		if [ "$HARD_MAX_EXEC_TIME" == "" ]; then
			HARD_MAX_EXEC_TIME=0
		fi

		MIN_WAIT=30
		REMOTE_SYNC=no
	else
		ConfigFile="${1}"
		LoadConfigFile "$ConfigFile"
	fi

	if [ "$LOGFILE" == "" ]; then
		if [ -w /var/log ]; then
			LOG_FILE=/var/log/osync_$SYNC_ID.log
		else
			LOG_FILE=./osync_$SYNC_ID.log
		fi
	else
		LOG_FILE="$LOGFILE"
	fi
	GetLocalOS
	InitLocalOSSettings
	Init
	GetRemoteOS
	InitRemoteOSSettings
	if [ $sync_on_changes -eq 1 ]; then
		SyncOnChanges
	else
		DATE=$(date)
		Logger "-------------------------------------------------------------" "NOTICE"
		Logger "$DRY_WARNING $DATE - $PROGRAM $PROGRAM_VERSION script begin." "NOTICE"
		Logger "-------------------------------------------------------------" "NOTICE"
		Logger "Sync task [$SYNC_ID] launched as $LOCAL_USER@$LOCAL_HOST (PID $SCRIPT_PID)" "NOTICE"
		if [ $no_maxtime -eq 1 ]; then
			SOFT_MAX_EXEC_TIME=0
			HARD_MAX_EXEC_TIME=0
		fi
		CheckReplicaPaths
		CheckDiskSpace
		RunBeforeHook
		Main
		if [ $? == 0 ]; then
			SoftDelete
		fi
		RunAfterHook
	fi
else
	Logger "Environment not suitable to run osync." "CRITICAL"
	exit 1
fi
