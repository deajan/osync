#!/usr/bin/env bash

PROGRAM="Osync" # Rsync based two way sync engine with fault tolerance
AUTHOR="(L) 2013-2015 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION=1.1-dev
PROGRAM_BUILD=2015090901

## type doesn't work on platforms other than linux (bash). If if doesn't work, always assume output is not a zero exitcode
if ! type -p "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

## allow debugging from command line with preceding ocsync with DEBUG=yes
if [ ! "$DEBUG" == "yes" ]; then
	DEBUG=no
	SLEEP_TIME=.1
else
	SLEEP_TIME=3
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

## Working directory. Will keep current file states, backups and soft deleted files.
OSYNC_DIR=".osync_workdir"

## Log a state message every $KEEP_LOGGING seconds. Should not be equal to soft or hard execution time so your log won't be unnecessary big.
KEEP_LOGGING=1801

## Correct output of sort command (language agnostic sorting)
export LC_ALL=C

ALERT_LOG_FILE=$RUN_DIR/osync_lastlog

function Dummy {
	sleep .1
}

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

function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"
	if [ $silent -eq 0 ]; then
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
		if [ "$DEBUG" != "yes" ]; then
			SendAlert
		else
			Logger "Debug mode, no alert mail will be sent." "NOTICE"
		fi
		UnlockDirectories
		CleanUp
		Logger "Osync finished with errors." "WARN"
		exitcode=1
	else
		UnlockDirectories
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
	if [ $silent -eq 1 ]; then
		return 1
	fi

	case $toggle
	in
	1)
	echo -n $1" \ "
	echo -ne "\r"
	toggle="2"
	;;

	2)
	echo -n $1" | "
	echo -ne "\r"
	toggle="3"
	;;

	3)
	echo -n $1" / "
	echo -ne "\r"
	toggle="4"
	;;

	*)
	echo -n $1" - "
	echo -ne "\r"
	toggle="1"
	;;
	esac
}

function EscapeSpaces {
	local string="${1}" # String on which space will be escaped
	echo $(echo "$string" | sed 's/ /\\ /g')
}

function CleanUp {
	if [ "$DEBUG" != "yes" ]; then
		rm -f $RUN_DIR/osync_*_$SCRIPT_PID
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
		egrep '^#|^[^ ]*=[^;&]*'  "$config_file" > "$RUN_DIR/osync_config_$SCRIPT_PID"
		source "$RUN_DIR/osync_config_$SCRIPT_PID"
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
	LOCAL_OS_VAR=$(uname -spio 2>&1)
	if [ $? != 0 ]; then
		LOCAL_OS_VAR=$(uname -v 2>&1)
		if [ $? != 0 ]; then
			LOCAL_OS_VAR=($uname)
		fi
	fi

	case $LOCAL_OS_VAR in
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
		Logger "Running on >> $LOCAL_OS_VAR << not supported. Please report to the author." "ERROR"
		exit 1
		;;
	esac
	Logger "Local OS: [$LOCAL_OS_VAR]." "DEBUG"
}

function GetRemoteOS {
	if [ "$REMOTE_SYNC" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		eval "$SSH_CMD \"uname -spio\" > $RUN_DIR/osync_remote_os_$SCRIPT_PID 2>&1" &
		child_pid=$!
		WaitForTaskCompletion $child_pid 120 240
		retval=$?
		if [ $retval != 0 ]; then
			eval "$SSH_CMD \"uname -v\" > $RUN_DIR/osync_remote_os_$SCRIPT_PID 2>&1" &
			child_pid=$!
			WaitForTaskCompletion $child_pid 120 240
			retval=$?
			if [ $retval != 0 ]; then
				eval "$SSH_CMD \"uname\" > $RUN_DIR/osync_remote_os_$SCRIPT_PID 2>&1" &
				child_pid=$!
				WaitForTaskCompletion $child_pid 120 240
				retval=$?
				if [ $retval != 0 ]; then
					Logger "Cannot Get remote OS type." "ERROR"
				fi
			fi
		fi

		REMOTE_OS_VAR=$(cat $RUN_DIR/osync_remote_os_$SCRIPT_PID)

		case $REMOTE_OS_VAR in
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
			Logger "Remote OS said:\n$REMOTE_OS_VAR" "CRITICAL"
			exit 1
		esac

		Logger "Remote OS: [$REMOTE_OS_VAR]." "DEBUG"
	fi
}

function WaitForTaskCompletion {
	local pid="${1}" # pid to wait for
	local soft_max_time="${2}" # If program with pid $pid takes longer than $soft_max_time seconds, will log a warning, unless $soft_max_time equals 0.
	if [ "$soft_max_time" == "" ]; then
		Logger "Missing argument soft_max_time in ${0}" "CRITICAL"
		exit 1
	fi
	local hard_max_time="${3}" # If program with pid $pid takes longer than $hard_max_time seconds, will stop execution, unless $hard_max_time equals 0.
	if [ "$hard_max_time" == "" ]; then
		Logger "Missing argument hard_max_time in ${0}" "CRITICAL"
		exit 1
	fi

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
	if [ "$soft_max_time" == "" ]; then
		Logger "Missing argument soft_max_time in ${0}" "CRITICAL"
		exit 1
	fi
	local hard_max_time="${3}" # If program with pid $pid takes longer than $hard_max_time seconds, will stop execution, unless $hard_max_time equals 0.
	if [ "$hard_max_time" == "" ]; then
		Logger "Missing argument hard_max_time in ${0}" "CRITICAL"
		exit 1
	fi

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
	if [ "$hard_max_time" == "" ]; then
		Logger "Missing argument hard_max_time in ${0}" "CRITICAL"
		exit 1
	fi

	if [ $dryrun -ne 0 ]; then
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

	if [ $verbose -eq 1 ] || [ $retval -ne 0 ]; then
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
	if [ "$hard_max_time" == "" ]; then
		Logger "Missing argument hard_max_time in ${0}" "CRITICAL"
		exit 1
	fi

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	if [ $dryrun -ne 0 ]; then
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

	if [ -f $RUN_DIR/osync_run_remote_$SCRIPT_PID ] && ([ $verbose -eq 1 ] || [ $retval -ne 0 ])
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
	if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_SYNC" != "no" ]; then
		eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1"
		if [ $? != 0 ]; then
			Logger "Cannot ping $REMOTE_HOST" "CRITICAL"
			exit 1
		fi
	fi
}

function CheckConnectivity3rdPartyHosts {
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

############################################################################################

### realpath.sh implementation from https://github.com/mkropat/sh-realpath

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

#### Osync specific functions (non shared)

function CreateOsyncDirs {
	if ! [ -d "$MASTER_STATE_DIR" ]; then
		mkdir -p "$MASTER_STATE_DIR"
		if [ $? != 0 ]; then
			Logger "Cannot create master replica state dir [$MASTER_STATE_DIR]." "CRITICAL"
			exit 1
		fi
	fi

	if [ "$REMOTE_SYNC" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		eval "$SSH_CMD \"if ! [ -d \\\"$SLAVE_STATE_DIR\\\" ]; then $COMMAND_SUDO mkdir -p \\\"$SLAVE_STATE_DIR\\\"; fi 2>&1\"" &
		child_pid=$!
		WaitForTaskCompletion $child_pid 0 1800
	else
		if ! [ -d "$SLAVE_STATE_DIR" ]; then
			mkdir -p "$SLAVE_STATE_DIR" > $RUN_DIR/osync_createosyncdirs_$SCRIPT_PID 2>&1
		fi
	fi

	if [ $? != 0 ]; then
		Logger "Cannot create slave replica state dir [$SLAVE_STATE_DIR]." "CRITICAL"
		Logger "Command output:\n$(cat $RUN_DIR/osync_createosyncdirs_$SCRIPT_PID)" "NOTICE"
		exit 1
	fi
}

function CheckMasterSlaveDirs {
	#MASTER_SYNC_DIR_CANN=$(realpath "$MASTER_SYNC_DIR")	#TODO: investigate realpath & readlink issues on MSYS and busybox here
	#SLAVE_SYNC_DIR_CANN=$(realpath "$SLAVE_SYNC_DIR")

	#if [ "$REMOTE_SYNC" != "yes" ]; then
	#	if [ "$MASTER_SYNC_DIR_CANN" == "$SLAVE_SYNC_DIR_CANN" ]; then
	#		Logger "Master directory [$MASTER_SYNC_DIR] can't be the same as slave directory." "CRITICAL"
	#		exit 1
	#	fi
	#fi

	if ! [ -d "$MASTER_SYNC_DIR" ]; then
		if [ "$CREATE_DIRS" == "yes" ]; then
			mkdir -p "$MASTER_SYNC_DIR" > $RUN_DIR/osync_checkmasterslavedirs_$SCRIPT_PID 2>&1
			if [ $? != 0 ]; then
				Logger "Cannot create master directory [$MASTER_SYNC_DIR]." "CRITICAL"
				Logger "Command output:\n$(cat $RUN_DIR/osync_checkmasterslavedirs_$SCRIPT_PID)" "NOTICE"
				exit 1
			fi
		else 
			Logger "Master directory [$MASTER_SYNC_DIR] does not exist." "CRITICAL"
			exit 1
		fi
	fi

	if [ "$REMOTE_SYNC" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		if [ "$CREATE_DIRS" == "yes" ]; then
			eval "$SSH_CMD \"if ! [ -d \\\"$SLAVE_SYNC_DIR\\\" ]; then $COMMAND_SUDO mkdir -p \\\"$SLAVE_SYNC_DIR\\\"; fi 2>&1"\" > $RUN_DIR/osync_checkmasterslavedirs_$SCRIPT_PID &
			child_pid=$!
			WaitForTaskCompletion $child_pid 0 1800
			if [ $? != 0 ]; then
				Logger "Cannot create slave directory [$SLAVE_SYNC_DIR]." "CRITICAL"
				Logger "Command output:\n$(cat $RUN_DIR/osync_checkmasterslavedirs_$SCRIPT_PID)" "NOTICE"
				exit 1
			fi
		else
			eval "$SSH_CMD \"if ! [ -d \\\"$SLAVE_SYNC_DIR\\\" ]; then exit 1; fi"\" &
			child_pid=$!
			WaitForTaskCompletion $child_pid 0 1800
			res=$?
			if [ $res != 0 ]; then
				Logger "Slave directory [$SLAVE_SYNC_DIR] does not exist." "CRITICAL"
				exit 1
			fi
		fi
	else
		if [ ! -d "$SLAVE_SYNC_DIR" ]; then
			if [ "$CREATE_DIRS" == "yes" ]; then
				mkdir -p "$SLAVE_SYNC_DIR"
				if [ $? != 0 ]; then
					Logger "Cannot create slave directory [$SLAVE_SYNC_DIR]." "CRITICAL"
					exit 1
				else
					Logger "Created slave directory [$SLAVE_SYNC_DIR]." "NOTICE"
				fi
			else
				Logger "Slave directory [$SLAVE_SYNC_DIR] does not exist." "CRITICAL"
				exit 1
			fi
		fi
	fi
}

function CheckMinimumSpace {
	Logger "Checking minimum disk space on master and slave." "NOTICE"

	MASTER_SPACE=$(df -P "$MASTER_SYNC_DIR" | tail -1 | awk '{print $4}')
	if [ $MASTER_SPACE -lt $MINIMUM_SPACE ]; then
		Logger "There is not enough free space on master [$MASTER_SPACE KB]." "ERROR"
	fi

	if [ "$REMOTE_SYNC" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		eval "$SSH_CMD \"$COMMAND_SUDO df -P \\\"$SLAVE_SYNC_DIR\\\"\"" > $RUN_DIR/osync_slave_space_$SCRIPT_PID &
		child_pid=$!
		WaitForTaskCompletion $child_pid 0 1800
		SLAVE_SPACE=$(cat $RUN_DIR/osync_slave_space_$SCRIPT_PID | tail -1 | awk '{print $4}')
	else
		SLAVE_SPACE=$(df -P "$SLAVE_SYNC_DIR" | tail -1 | awk '{print $4}')
	fi

	if [ $SLAVE_SPACE -lt $MINIMUM_SPACE ]; then
		Logger "There is not enough free space on slave [$SLAVE_SPACE KB]." "ERROR"
	fi
}

function RsyncExcludePattern {
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

function WriteLockFiles {
	echo $SCRIPT_PID > "$MASTER_LOCK"
	if [ $? != 0 ]; then
		Logger "Could not set lock on master replica." "CRITICAL"
		exit 1
	else
		Logger "Locked master replica." "NOTICE"
	fi

	if [ "$REMOTE_SYNC" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		eval "$SSH_CMD \"echo $SCRIPT_PID@$SYNC_ID | $COMMAND_SUDO tee \\\"$SLAVE_LOCK\\\" > /dev/null \"" &
		child_pid=$!
		WaitForTaskCompletion $child_pid 0 1800
		if [ $? != 0 ]; then
			Logger "Could not set lock on remote slave replica." "CRITICAL"
			exit 1
		else
			Logger "Locked remote slave replica." "NOTICE"
		fi
	else
		echo "$SCRIPT_PID@$SYNC_ID" > "$SLAVE_LOCK"
		if [ $? != 0 ]; then
			Logger "Couuld not set lock on local slave replica." "CRITICAL"
			exit 1
		else
			Logger "Locked local slave replica." "NOTICE"
		fi
	fi
}

function LockDirectories {
	if [ $nolocks -eq 1 ]; then
		return 0
	fi

	if [ $force_unlock -eq 1 ]; then
		WriteLockFiles
		if [ $? != 0 ]; then
			exit 1
		fi
	fi

	Logger "Checking for replica locks." "NOTICE"

	if [ -f "$MASTER_LOCK" ]; then
		master_lock_pid=$(cat $MASTER_LOCK)
		Logger "Master lock pid present: $master_lock_pid" "DEBUG"
		ps -p$master_lock_pid > /dev/null 2>&1
		if [ $? != 0 ]; then
			Logger "There is a dead osync lock on master. Instance $master_lock_pid no longer running. Resuming." "NOTICE"
		else
			Logger "There is already a local instance of osync that locks master replica. Cannot start. If your are sure this is an error, plaese kill instance $master_lock_pid of osync." "CRITICAL"
			exit 1
		fi
	fi

	if [ "$REMOTE_SYNC" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		eval "$SSH_CMD \"if [ -f \\\"$SLAVE_LOCK\\\" ]; then cat \\\"$SLAVE_LOCK\\\"; fi\" > $RUN_DIR/osync_remote_slave_lock_$SCRIPT_PID" &
		child_pid=$!
		WaitForTaskCompletion $child_pid 0 1800
		if [ -f $RUN_DIR/osync_remote_slave_lock_$SCRIPT_PID ]; then
			slave_lock_pid=$(cat $RUN_DIR/osync_remote_slave_lock_$SCRIPT_PID | cut -d'@' -f1)
			slave_lock_id=$(cat $RUN_DIR/osync_remote_slave_lock_$SCRIPT_PID | cut -d'@' -f2)
		fi
	else
		if [ -f "$SLAVE_LOCK" ]; then
			slave_lock_pid=$(cat "$SLAVE_LOCK" | cut -d'@' -f1)
			slave_lock_id=$(cat "$SLAVE_LOCK" | cut -d'@' -f2)
		fi
	fi

	if [ "$slave_lock_pid" != "" ] && [ "$slave_lock_id" != "" ]; then
		Logger "Slave lock pid: $slave_lock_pid" "DEBUG"

		ps -p$slave_lock_pid > /dev/null
		if [ $? != 0 ]; then
			if [ "$slave_lock_id" == "$SYNC_ID" ]; then
				Logger "There is a dead osync lock on slave replica that corresponds to this master sync-id. Instance $slave_lock_pid no longer running. Resuming." "NOTICE"
			else
				if [ "$FORCE_STRANGER_LOCK_RESUME" == "yes" ]; then
					Logger "WARNING: There is a dead osync lock on slave replica that does not correspond to this master sync-id. Forcing resume." "WARN"
				else
					Logger "There is a dead osync lock on slave replica that does not correspond to this master sync-id. Will not resume." "CRITICAL"
					exit 1
				fi
			fi
		else
			Logger "There is already a local instance of osync that locks slave replica. Cannot start. If you are sure this is an error, please kill instance $slave_lock_pid of osync." "CRITICAL"
			exit 1
		fi
	fi

	WriteLockFiles
}

function UnlockDirectories {
	if [ $nolocks -eq 1 ]; then
		return 0
	fi

	if [ "$REMOTE_SYNC" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		eval "$SSH_CMD \"if [ -f \\\"$SLAVE_LOCK\\\" ]; then $COMMAND_SUDO rm \\\"$SLAVE_LOCK\\\"; fi 2>&1\"" > $RUN_DIR/osync_UnlockDirectories_$SCRIPT_PID &
		child_pid=$!
		WaitForTaskCompletion $child_pid 0 1800
	else
		if [ -f "$SLAVE_LOCK" ]; then
			rm "$SLAVE_LOCK" > $RUN_DIR/osync_UnlockDirectories_$SCRIPT_PID 2>&1
		fi
	fi

	if [ $? != 0 ]; then
		Logger "Could not unlock slave replica." "ERROR"
		Logger "Command Output:\n$(cat $RUN_DIR/osync_UnlockDirectories_$SCRIPT_PID)" "NOTICE"
	else
		Logger "Removed slave replica lock." "NOTICE"
	fi

	if [ -f "$MASTER_LOCK" ]; then
		rm "$MASTER_LOCK"
		if [ $? != 0 ]; then
			Logger "Could not unlock master replica." "ERROR"
		else
			Logger "Removed master replica lock." "NOTICE"
		fi
	fi
}

###### Sync core functions

	## Rsync does not like spaces in directory names, considering it as two different directories. Handling this schema by escaping space.
	## It seems this only happens when trying to execute an rsync command through eval $rsync_cmd on a remote host.
	## So i'm using unescaped $MASTER_SYNC_DIR for local rsync calls and escaped $ESC_MASTER_SYNC_DIR for remote rsync calls like user@host:$ESC_MASTER_SYNC_DIR
	## The same applies for slave sync dir..............................................T.H.I.S..I.S..A..P.R.O.G.R.A.M.M.I.N.G..N.I.G.H.T.M.A.R.E

function tree_list {
	local replica_path="${1}" # path to the replica for which a tree needs to be constructed
	local replica_type="${2}" # replica type: master, slave
	local tree_filename="${3}" # filename to output tree (will be prefixed with $replica_type)

	local escaped_replica_path=$(EscapeSpaces "$replica_path") #TODO: See if escpaed still needed when using ' instead of " for command eval

	Logger "Creating $replica_type replica file list [$replica_path]." "NOTICE"
	if [ "$REMOTE_SYNC" == "yes" ] && [ "$replica_type" == "slave" ]; then
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
		mv $RUN_DIR/osync_$replica_type_$SCRIPT_PID "$MASTER_STATE_DIR/$replica_type$tree_filename"
		return $?
	else
		Logger "Cannot create replica file list." "CRITICAL"
		exit $retval
	fi
}

# delete_list(replica, tree-file-after, tree-file-current, deleted-list-file, deleted-failed-list-file): Creates a list of files vanished from last run on replica $1 (master/slave)
function delete_list {
	local replica_type="${1}" # replica type: master, slave
	local tree_file_after_filename="${2}" # tree-file-after, will be prefixed with replica type
	local tree_file_current_filename="${3}" # tree-file-current, will be prefixed with replica type
	local deleted_list_file_filename="${4}" # file containing deleted file list, will be prefixed with replica type
	local deleted_failed_list_file_filename="${5}" # file containing files that couldn't be deleted on last run, will be prefixed with replica type
	
	# TODO: WIP here

	Logger "Creating $replica_type replica deleted file list." "NOTICE"
	if [ -f "$MASTER_STATE_DIR/$replica_type$TREE_AFTER_FILENAME_NO_SUFFIX" ]; then
		## Same functionnality, comm is much faster than grep but is not available on every platform
		if type -p comm > /dev/null 2>&1
		then
			cmd="comm -23 \"$MASTER_STATE_DIR/$replica_type$TREE_AFTER_FILENAME_NO_SUFFIX\" \"$MASTER_STATE_DIR/$replica_type$3\" > \"$MASTER_STATE_DIR/$replica_type$4\""
		else
			## The || : forces the command to have a good result
			cmd="(grep -F -x -v -f \"$MASTER_STATE_DIR/$replica_type$3\" \"$MASTER_STATE_DIR/$replica_type$TREE_AFTER_FILENAME_NO_SUFFIX\" || :) > \"$MASTER_STATE_DIR/$replica_type$4\""
		fi

		Logger "CMD: $cmd" "DEBUG"
		eval $cmd 2>> "$LOG_FILE"
		retval=$?

		# Add delete failed file list to current delete list and then empty it
		if [ -f "$MASTER_STATE_DIR/$replica_type$5" ]; then
			cat "$MASTER_STATE_DIR/$replica_type$5" >> "$MASTER_STATE_DIR/$replica_type$4"
			rm -f "$MASTER_STATE_DIR/$replica_type$5"
		fi

		return $retval
	else
		touch "$MASTER_STATE_DIR/$replica_type$4"
		return $retval
	fi
}

# sync_update(source replica, destination replica, delete_list_filename)
function sync_update {
	local source_replica="${1}" # Contains replica type of source: master, slave
	local destination_replica="${2}" # Contains replica type of destination: master, slave
	local delete_list_filename="${3}" # Contains deleted list filename, will be prefixed with replica type

	Logger "Updating $destination_replica replica." "NOTICE"
	if [ "$source_replica" == "master" ]; then
		SOURCE_DIR="$MASTER_SYNC_DIR"
		ESC_SOURCE_DIR=$(EscapeSpaces "$MASTER_SYNC_DIR")
		DEST_DIR="$SLAVE_SYNC_DIR"
		ESC_DEST_DIR=$(EscapeSpaces "$SLAVE_SYNC_DIR")
		BACKUP_DIR="$SLAVE_BACKUP"
	else
		SOURCE_DIR="$SLAVE_SYNC_DIR"
		ESC_SOURCE_DIR=$(EscapeSpaces "$SLAVE_SYNC_DIR")
		DEST_DIR="$MASTER_SYNC_DIR"
		ESC_DEST_DIR=$(EscapeSpaces "$MASTER_SYNC_DIR")
		BACKUP_DIR="$MASTER_BACKUP"
	fi

	if [ "$REMOTE_SYNC" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		if [ "$source_replica" == "master" ]; then
			rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $BACKUP_DIR --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from=\"$MASTER_STATE_DIR/$source_replica$delete_list_filename\" --exclude-from=\"$MASTER_STATE_DIR/$destination_replica$delete_list_filename\" \"$SOURCE_DIR/\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_DEST_DIR/\" > $RUN_DIR/osync_update_$destination_replica_replica_$SCRIPT_PID 2>&1 &"
		else
			rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $BACKUP_DIR --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from=\"$MASTER_STATE_DIR/$destination_replica$delete_list_filename\" --exclude-from=\"$MASTER_STATE_DIR/$source_replica$delete_list_filename\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_SOURCE_DIR/\" \"$DEST_DIR/\" > $RUN_DIR/osync_update_$destination_replica_replica_$SCRIPT_PID 2>&1 &"
		fi
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $SYNC_OPTS $BACKUP_DIR --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from=\"$MASTER_STATE_DIR/$source_replica$delete_list_filename\" --exclude-from=\"$MASTER_STATE_DIR/$destination_replica$delete_list_filename\" \"$SOURCE_DIR/\" \"$DEST_DIR/\" > $RUN_DIR/osync_update_$destination_replica_replica_$SCRIPT_PID 2>&1 &"
	fi
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	eval "$rsync_cmd"
	child_pid=$!
	WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
	retval=$?
	if [ $verbose -eq 1 ] && [ -f $RUN_DIR/osync_update_$destination_replica_replica_$SCRIPT_PID ]; then
		Logger "List:\n$(cat $RUN_DIR/osync_update_$destination_replica_replica_$SCRIPT_PID)" "NOTICE"
	fi

	if [ $retval != 0 ] && [ $retval != 24 ]; then
		Logger "Updating $destination_replica replica failed. Stopping execution." "CRITICAL"
		if [ $verbose -eq 0 ] && [ -f $RUN_DIR/osync_update_$destination_replica_replica_$SCRIPT_PID ]; then
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
	## On every run, check wheter the next item is already deleted because it's included in a directory already deleted
	previous_file=""
	OLD_IFS=$IFS
	IFS=$'\r\n'
	for files in $(cat "$MASTER_STATE_DIR/$2")
	do
		if [[ "$files" != "$previous_file/"* ]] && [ "$files" != "" ]; then
			if [ "$SOFT_DELETE" != "no" ]; then
				if [ ! -d "$REPLICA_DIR$3" ]; then
					mkdir -p "$REPLICA_DIR$3"
					if [ $? != 0 ]; then
						Logger "Cannot create replica deletion directory." "ERROR"
					fi
				fi

				if [ $verbose -eq 1 ]; then
					Logger "Soft deleting $REPLICA_DIR$files" "NOTICE"
				fi

				if [ $dryrun -ne 1 ]; then
					if [ -e "$REPLICA_DIR$3/$files" ]; then
						rm -rf "$REPLICA_DIR$3/$files"
					fi
					# In order to keep full path on soft deletion, create parent directories before move
					parentdir="$(dirname "$files")"
					if [ "$parentdir" != "." ]; then
						mkdir --parents "$REPLICA_DIR$3/$parentdir"
						mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$3/$parentdir"
					else
						mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$3"
					fi
					if [ $? != 0 ]; then
						Logger "Cannot move $REPLICA_DIR$files to deletion directory." "ERROR"
						echo "$files" >> "$MASTER_STATE_DIR/$4"
					fi
				fi
			else
				if [ $verbose -eq 1 ]; then
					Logger "Deleting $REPLICA_DIR$files" "NOTICE"
				fi

				if [ $dryrun -ne 1 ]; then
					rm -rf "$REPLICA_DIR$files"
					if [ $? != 0 ]; then
						Logger "Cannot delete $REPLICA_DIR$files" "ERROR"
						echo "$files" >> "$MASTER_STATE_DIR/$4"
					fi
				fi
			fi
			previous_file="$files"
		fi
	done
	IFS=$OLD_IFS
}

# delete_remote(replica dir, delete file list, delete dir, delete fail file list)
function _delete_remote {
	## This is a special coded function. Need to redelcare local functions on remote host, passing all needed variables as escaped arguments to ssh command.
	## Anything beetween << ENDSSH and ENDSSH will be executed remotely

	# Additionnaly, we need to copy the deletetion list to the remote state folder
	ESC_DEST_DIR="$(EscapeSpaces "$SLAVE_STATE_DIR")"
	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" \"$MASTER_STATE_DIR/$2\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_DEST_DIR/\" > $RUN_DIR/osync_remote_deletion_list_copy_$SCRIPT_PID 2>&1"
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	eval $rsync_cmd 2>> "$LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot copy the deletion list to remote replica." "CRITICAL"
		if [ -f $RUN_DIR/osync_remote_deletion_list_copy_$SCRIPT_PID ]; then
			Logger "$(cat $RUN_DIR/osync_remote_deletion_list_copy_$SCRIPT_PID)" "CRITICAL" #TODO: remote deletion is critical. local deletion isn't. What to do ?
		fi
		exit 1
	fi

$SSH_CMD error_alert=0 sync_on_changes=$sync_on_changes silent=$silent DEBUG=$DEBUG dryrun=$dryrun verbose=$verbose COMMAND_SUDO=$COMMAND_SUDO FILE_LIST="$(EscapeSpaces "$SLAVE_STATE_DIR/$2")" REPLICA_DIR="$(EscapeSpaces "$REPLICA_DIR")" DELETE_DIR="$(EscapeSpaces "$DELETE_DIR")" FAILED_DELETE_LIST="$(EscapeSpaces "$SLAVE_STATE_DIR/$4")" 'bash -s' << 'ENDSSH' > $RUN_DIR/osync_remote_deletion_$SCRIPT_PID 2>&1 &

	## The following lines are executed remotely
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
			if [ "$DEBUG" == "yes" ]; then
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
				if [ $verbose -eq 1 ]; then
					Logger "Soft deleting $REPLICA_DIR$files" "NOTICE"
				fi

				if [ $dryrun -ne 1 ]; then
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
				if [ $verbose -eq 1 ]; then
					Logger "Deleting $REPLICA_DIR$files" "NOTICE"
				fi

				if [ $dryrun -ne 1 ]; then
					$COMMAND_SUDO rm -rf "$REPLICA_DIR$files"
					if [ $? != 0 ]; then
						Logger "Cannot delete $REPLICA_DIR$files" "ERROR"
						echo "$files" >> "$SLAVE_STATE_DIR/$FAILED_DELETE_LIST"
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
	ESC_SOURCE_FILE="$(EscapeSpaces "$SLAVE_STATE_DIR/$4")"
	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_SOURCE_FILE\" \"$MASTER_STATE_DIR\" > $RUN_DIR/osync_remote_failed_deletion_list_copy_$SCRIPT_PID"
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	eval $rsync_cmd 2>> "$LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot copy back the failed deletion list to master replica." "CRITICAL"
		if [ -f $RUN_DIR/osync_remote_failed_deletion_list_copy_$SCRIPT_PID ]; then
			Logger "$(cat $RUN_DIR/osync_remote_failed_deletion_list_copy_$SCRIPT_PID)" "NOTICE"
		fi
		exit 1
	fi



	exit $?
}


# delete_propagation(replica name, deleted_list_filename, deleted_failed_file_list)
# replica name = "master" / "slave"
function deletion_propagation {
	Logger "Propagating deletions to $1 replica." "NOTICE"

	if [ "$1" == "master" ]; then
		REPLICA_DIR="$MASTER_SYNC_DIR"
		DELETE_DIR="$MASTER_DELETE_DIR"

		_delete_local "$REPLICA_DIR" "slave$2" "$DELETE_DIR" "slave$3" &
		child_pid=$!
		WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
		retval=$?
		if [ $retval != 0 ]; then
			Logger "Deletion on replica $1 failed." "CRITICAL"
			exit 1
		fi
	else
		REPLICA_DIR="$SLAVE_SYNC_DIR"
		DELETE_DIR="$SLAVE_DELETE_DIR"

		if [ "$REMOTE_SYNC" == "yes" ]; then
			_delete_remote "$REPLICA_DIR" "master$2" "$DELETE_DIR" "master$3" &
		else
			_delete_local "$REPLICA_DIR" "master$2" "$DELETE_DIR" "master$3" &
		fi
		child_pid=$!
		WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
		retval=$?
		if [ $retval == 0 ]; then
			if [ -f $RUN_DIR/osync_remote_deletion_$SCRIPT_PID ] && [ $verbose -eq 1 ]; then
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
###### Step 1: Create current tree list for master and slave replicas (Steps 1M and 1S)
###### Step 2: Create deleted file list for master and slave replicas (Steps 2M and 2S)
###### Step 3: Update master and slave replicas (Steps 3M and 3S, order depending on conflict prevalence)
###### Step 4: Deleted file propagation to master and slave replicas (Steps 4M and 4S)
###### Step 5: Create after run tree list for master and slave replicas (Steps 5M and 5S)

function Sync {
	Logger "Starting synchronization task." "NOTICE"
	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	if [ -f "$MASTER_LAST_ACTION" ] && [ "$RESUME_SYNC" != "no" ]; then
		resume_sync=$(cat "$MASTER_LAST_ACTION")
		if [ -f "$MASTER_RESUME_COUNT" ]; then
			resume_count=$(cat "$MASTER_RESUME_COUNT")
		else
			resume_count=0
		fi

		if [ $resume_count -lt $RESUME_TRY ]; then
			if [ "$resume_sync" != "sync.success" ]; then
				Logger "WARNING: Trying to resume aborted osync execution on $($STAT_CMD "$MASTER_LAST_ACTION") at task [$resume_sync]. [$resume_count] previous tries." "WARN"
				echo $(($resume_count+1)) > "$MASTER_RESUME_COUNT"
			else
				resume_sync=none
			fi
		else
			Logger "Will not resume aborted osync execution. Too much resume tries [$resume_count]." "WARN"
			echo "noresume" > "$MASTER_LAST_ACTION"
			echo "0" > "$MASTER_RESUME_COUNT"
			resume_sync=none
		fi
	else
		resume_sync=none
	fi


	################################################################################################################################################# Actual sync begins here

	## This replaces the case statement because ;& operator is not supported in bash 3.2... Code is more messy than case :(
	if [ "$resume_sync" == "none" ] || [ "$resume_sync" == "noresume" ] || [ "$resume_sync" == "master-replica-tree.fail" ]; then
		#master_tree_current
		tree_list "$MASTER_SYNC_DIR" master "$TREE_CURRENT_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[0]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[0]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[0]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[1]}.fail" ]; then
		#slave_tree_current
		tree_list "$SLAVE_SYNC_DIR" slave "$TREE_CURRENT_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[1]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[1]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[1]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[2]}.fail" ]; then
		delete_list master "$TREE_AFTER_FILENAME" "$TREE_CURRENT_FILENAME" "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[2]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNc_ACTION[2]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[2]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.fail" ]; then
		delete_list slave "$TREE_AFTER_FILENAME" "$TREE_CURRENT_FILENAME" "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[3]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[3]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.fail" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.fail" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.success" ]; then
		if [ "$CONFLICT_PREVALANCE" != "master" ]; then
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.fail" ]; then
				sync_update slave master "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[4]}.success" > "$MASTER_LAST_ACTION"
				else
					echo "${SYNC_ACTION[4]}.fail" > "$MASTER_LAST_ACTION"
				fi
				resume_sync="resumed"
			fi
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.fail" ]; then
				sync_update master slave "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[5]}.success" > "$MASTER_LAST_ACTION"
				else
					echo "${SYNC_ACTION[5]}.fail" > "$MASTER_LAST_ACTION"
				fi
				resume_sync="resumed"
			fi
		else
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.fail" ]; then
				sync_update master slave "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[5]}.success" > "$MASTER_LAST_ACTION"
				else
					echo "${SYNC_ACTION[5]}.fail" > "$MASTER_LAST_ACTION"
				fi
				resume_sync="resumed"
			fi
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.fail" ]; then
				sync_update slave master "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[4]}.success" > "$MASTER_LAST_ACTION"
				else
					echo "${SYNC_ACTION[4]}.fail" > "$MASTER_LAST_ACTION"
				fi
				resume_sync="resumed"
			fi
		fi
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[6]}.fail" ]; then
		deletion_propagation slave "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[6]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[6]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[6]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[7]}.fail" ]; then
		deletion_propagation master "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[7]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[7]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[7]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[8]}.fail" ]; then
		#master_tree_after
		tree_list "$MASTER_SYNC_DIR" master "$TREE_AFTER_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[8]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[8]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[8]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[9]}.fail" ]; then
		#slave_tree_after
		tree_list "$SLAVE_SYNC_DIR" slave "$TREE_AFTER_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[9]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[9]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi

	Logger "Finished synchronization task." "NOTICE"
	echo "${SYNC_ACTION[10]}" > "$MASTER_LAST_ACTION"

	echo "0" > "$MASTER_RESUME_COUNT"
}

function SoftDelete {
	if [ "$CONFLICT_BACKUP" != "no" ] && [ $CONFLICT_BACKUP_DAYS -ne 0 ]; then
		Logger "Running conflict backup cleanup." "NOTICE"
		_SoftDelete $CONFLICT_BACKUP_DAYS "$MASTER_SYNC_DIR$MASTER_BACKUP_DIR" "$SLAVE_SYNC_DIR$SLAVE_BACKUP_DIR"
	fi

	if [ "$SOFT_DELETE" != "no" ] && [ $SOFT_DELETE_DAYS -ne 0 ]; then
		Logger "Running soft deletion cleanup." "NOTICE"
		_SoftDelete $SOFT_DELETE_DAYS "$MASTER_SYNC_DIR$MASTER_DELETE_DIR" "$SLAVE_SYNC_DIR$SLAVE_DELETE_DIR"	
	fi	
}


# Takes 3 arguments
# $1 = ctime (CONFLICT_BACKUP_DAYS or SOFT_DELETE_DAYS), $2 = MASTER_(BACKUP/DELETED)_DIR, $3 = SLAVE_(BACKUP/DELETED)_DIR
function _SoftDelete {
	local change_time="${1}" # Contains the number of days a file needs to be old to be processed here (conflict or soft deletion)
	local master_directory="${2}" # Master backup / deleted directory to search in
	local slave_directory="${3}" # Slave backup / deleted directory to search in 


	if [ -d "$master_directory" ]; then
		if [ $dryrun -eq 1 ]; then
			Logger "Listing files older than $change_time days on master replica. Won't remove anything." "NOTICE"
		else
			Logger "Removing files older than $change_time days on master replica." "NOTICE"
		fi
			if [ $verbose -eq 1 ]; then
			# Cannot launch log function from xargs, ugly hack
			$FIND_CMD "$master_directory/" -type f -ctime +$change_time -print0 | xargs -0 -I {} echo "Will delete file {}" > $RUN_DIR/osync_soft_delete_master_$SCRIPT_PID
			Logger "Command output:\n$(cat $RUN_DIR/osync_soft_delete_master_$SCRIPT_PID)" "NOTICE"
			$FIND_CMD "$master_directory/" -type d -empty -ctime +$change_time -print0 | xargs -0 -I {} echo "Will delete directory {}" > $RUN_DIR/osync_soft_delete_master_$SCRIPT_PID
			Logger "Command output:\n$(cat $RUN_DIR/osync_soft_delete_master_$SCRIPT_PID)" "NOTICE"
		fi
			if [ $dryrun -ne 1 ]; then
			$FIND_CMD "$master_directory/" -type f -ctime +$change_time -print0 | xargs -0 -I {} rm -f "{}" && $FIND_CMD "$master_directory/" -type d -empty -ctime +$change_time -print0 | xargs -0 -I {} rm -rf "{}" > $RUN_DIR/osync_soft_delete_master_$SCRIPT_PID 2>&1 &
		else
			Dummy &
		fi
		child_pid=$!
		WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Error while executing cleanup on master replica." "ERROR"
			Logger "Command output:\n$(cat $RUN_DIR/osync_soft_delete_master_$SCRIPT_PID)" "NOTICE"
		else
			Logger "Cleanup complete on master replica." "NOTICE"
		fi
	elif [ -d "$master_directory" ] && ! [ -w "$master_directory" ]; then
		Logger "Warning: Master replica dir [$master_directory] isn't writable. Cannot clean old files." "ERROR"
	fi

	if [ "$REMOTE_SYNC" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
			if [ $dryrun -eq 1 ]; then
			Logger "Listing files older than $change_time days on slave replica. Won't remove anything." "NOTICE"
		else
			Logger "Removing files older than $change_time days on slave replica." "NOTICE"
		fi
			if [ $verbose -eq 1 ]; then
			# Cannot launch log function from xargs, ugly hack
			eval "$SSH_CMD \"if [ -w \\\"$slave_directory\\\" ]; then $COMMAND_SUDO $REMOTE_FIND_CMD \\\"$slave_directory/\\\" -type f -ctime +$change_time -print0 | xargs -0 -I {} echo Will delete file {} && $REMOTE_FIND_CMD \\\"$slave_directory/\\\" -type d -empty -ctime $change_time -print0 | xargs -0 -I {} echo Will delete directory {}; fi\"" > $RUN_DIR/osync_soft_delete_slave_$SCRIPT_PID
			Logger "Command output:\n$(cat $RUN_DIR/osync_soft_delete_slave_$SCRIPT_PID)" "NOTICE"
		fi
			if [ $dryrun -ne 1 ]; then
			eval "$SSH_CMD \"if [ -w \\\"$slave_directory\\\" ]; then $COMMAND_SUDO $REMOTE_FIND_CMD \\\"$slave_directory/\\\" -type f -ctime +$change_time -print0 | xargs -0 -I {} rm -f \\\"{}\\\" && $REMOTE_FIND_CMD \\\"$slave_directory/\\\" -type d -empty -ctime $change_time -print0 | xargs -0 -I {} rm -rf \\\"{}\\\"; fi 2>&1\"" > $RUN_DIR/osync_soft_delete_slave_$SCRIPT_PID &
		else
			Dummy &
		fi
		child_pid=$!
			WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
			retval=$?
			if [ $retval -ne 0 ]; then
				Logger "Error while executing cleanup on slave replica." "ERROR"
				Logger "Command output:\n$(cat $RUN_DIR/osync_soft_delete_slave_$SCRIPT_PID)" "NOTICE"
			else
				Logger "Cleanup complete on slave replica." "NOTICE"
			fi
	else
	if [ -w "$slave_directory" ]; then
		if [ $dryrun -eq 1 ]; then
			Logger "Listing files older than $change_time days on slave replica. Won't remove anything." "NOTICE"
		else
			Logger "Removing files older than $change_time days on slave replica." "NOTICE"
		fi
			if [ $verbose -eq 1 ]; then
			# Cannot launch log function from xargs, ugly hack
			$FIND_CMD "$slave_directory/" -type f -ctime +$change_time -print0 | xargs -0 -I {} echo "Will delete file {}" > $RUN_DIR/osync_soft_delete_slave_$SCRIPT_PID
			Logger "Command output:\n$(cat $RUN_DIR/osync_soft_delete_slave_$SCRIPT_PID)" "NOTICE"
			$FIND_CMD "$slave_directory/" -type d -empty -ctime +$change_time -print0 | xargs -0 -I {} echo "Will delete directory {}" > $RUN_DIR/osync_soft_delete_slave_$SCRIPT_PID
			Logger "Command output:\n$(cat $RUN_DIR/osync_soft_delete_slave_$SCRIPT_PID)" "NOTICE"
			Dummy &
		fi
			if [ $dryrun -ne 1 ]; then
			$FIND_CMD "$slave_directory/" -type f -ctime +$change_time -print0 | xargs -0 -I {} rm -f "{}" && $FIND_CMD "$slave_directory/" -type d -empty -ctime +$change_time -print0 | xargs -0 -I {} rm -rf "{}" > $RUN_DIR/osync_soft_delete_slave_$SCRIPT_PID &
		fi
		child_pid=$!
		WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Error while executing cleanup on slave replica." "ERROR"
			Logger "Command output:\n$(cat $RUN_DIR/osync_soft_delete_slave_$SCRIPT_PID)" "NOTICE"
		else
			Logger "Cleanup complete on slave replica." "NOTICE"
		fi
		elif [ -d "$slave_directory" ] && ! [ -w "$slave_directory" ]; then
			Logger "Warning: Slave replica dir [$slave_directory] isn't writable. Cannot clean old files." "ERROR"
		fi
	fi
	
}

function Init {
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

	if [ "$DEBUG" == "yes" ]; then
		trap 'TrapError ${LINENO} $?' ERR
	fi

	MAIL_ALERT_MSG="Warning: Execution of osync instance $OSYNC_ID (pid $SCRIPT_PID) as $LOCAL_USER@$LOCAL_HOST produced errors on $(date)."

	## Test if slave dir is a ssh uri, and if yes, break it down it its values
	if [ "${SLAVE_SYNC_DIR:0:6}" == "ssh://" ]; then
		REMOTE_SYNC="yes"

		# remove leadng 'ssh://'
		uri=${SLAVE_SYNC_DIR#ssh://*}
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
		SLAVE_SYNC_DIR=${_hosturiandpath#*/}
	fi

	## Make sure there is only one trailing slash on path
	MASTER_SYNC_DIR="${MASTER_SYNC_DIR%/}/"
	SLAVE_SYNC_DIR="${SLAVE_SYNC_DIR%/}/"

	MASTER_STATE_DIR="$MASTER_SYNC_DIR$OSYNC_DIR/state"
	SLAVE_STATE_DIR="$SLAVE_SYNC_DIR$OSYNC_DIR/state"
	STATE_DIR="$OSYNC_DIR/state"
	MASTER_LOCK="$MASTER_STATE_DIR/lock"
	SLAVE_LOCK="$SLAVE_STATE_DIR/lock"

	## Working directories to keep backups of updated / deleted files
	MASTER_BACKUP_DIR="$OSYNC_DIR/backups"
	MASTER_DELETE_DIR="$OSYNC_DIR/deleted"
	SLAVE_BACKUP_DIR="$OSYNC_DIR/backups"
	SLAVE_DELETE_DIR="$OSYNC_DIR/deleted"

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
	if [ $dryrun -eq 1 ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -n"
		DRY_WARNING="/!\ DRY RUN"
	fi

	if [ "$BANDWIDTH" != "" ] && [ "$BANDWIDTH" != "0" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --bwlimit=$BANDWIDTH"
	fi

	## Set sync only function arguments for rsync
	SYNC_OPTS="-u"

	if [ $verbose -eq 1 ]; then
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
		MASTER_BACKUP="--backup --backup-dir=\"$MASTER_BACKUP_DIR\""
		SLAVE_BACKUP="--backup --backup-dir=\"$SLAVE_BACKUP_DIR\""
		if [ "$CONFLICT_BACKUP_MULTIPLE" == "yes" ]; then
			MASTER_BACKUP="$MASTER_BACKUP --suffix .$(date +%Y.%m.%d-%H.%M.%S)"
			SLAVE_BACKUP="$SLAVE_BACKUP --suffix .$(date +%Y.%m.%d-%H.%M.%S)"
		fi
	else
		MASTER_BACKUP=
		SLAVE_BACKUP=
	fi

	## Add Rsync exclude patterns
	RsyncExcludePattern
	## Add Rsync exclude from file
	RsyncExcludeFrom

	## Filenames for state files
	if [ $dryrun -eq 1 ]; then
		dry_suffix="-dry"
	fi

	TREE_CURRENT_FILENAME="-tree-current-$SYNC_ID$dry_suffix"
	TREE_AFTER_FILENAME="-tree-after-$SYNC_ID$dry_suffix"
	TREE_AFTER_FILENAME_NO_SUFFIX="-tree-after-$SYNC_ID"
	DELETED_LIST_FILENAME="-deleted-list-$SYNC_ID$dry_suffix"
	FAILED_DELETE_LIST_FILENAME="-failed-delete-$SYNC_ID$dry_suffix"
	MASTER_LAST_ACTION="$MASTER_STATE_DIR/last-action-$SYNC_ID$dry_suffix"
	MASTER_RESUME_COUNT="$MASTER_STATE_DIR/resume-count-$SYNC_ID$dry_suffix"

	## Sync function actions (0-9)
	SYNC_ACTION=(
	'master-replica-tree'
	'slave-replica-tree'
	'master-deleted-list'
	'slave-deleted-list'
	'update-master-replica'
	'update-slave-replica'
	'delete-propagation-slave'
	'delete-propagation-master'
	'master-replica-tree-after'
	'slave-replica-tree-after'
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
	CreateOsyncDirs
	LockDirectories
	Sync
}

function Usage {
	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo $AUTHOR
	echo $CONTACT
	echo ""
	echo "You may use Osync with a full blown configuration file, or use its default options for quick command line sync."
	echo "Usage: osync.sh /path/to/config/file [OPTIONS]"
	echo "or     osync.sh --master=/path/to/master/replica --slave=/path/to/slave/replica [OPTIONS] [QUICKSYNC OPTIONS]"
	echo "or     osync.sh --master=/path/to/master/replica --slave=ssh://[backupuser]@remotehost.com[:portnumber]//path/to/slave/replica [OPTIONS] [QUICKSYNC OPTIONS]"
	echo ""
	echo "[OPTIONS]"
	echo "--dry             Will run osync without actually doing anything; just testing"
	echo "--silent          Will run osync without any output to stdout, used for cron jobs"
	echo "--verbose         Increases output"
	echo "--stats           Adds rsync transfer statistics to verbose output"
	echo "--partial         Allows rsync to keep partial downloads that can be resumed later (experimental)"
	echo "--no-maxtime      Disables any soft and hard execution time checks"
	echo "--force-unlock    Will override any existing active or dead locks on master and slave replica"
	echo "--on-changes      Will launch a sync task after a short wait period if there is some file activity on master replica. You should try daemon mode instead"
	echo ""
	echo "[QUICKSYNC OPTIONS]"
	echo "--master=\"\"	Master replica path. Will contain state and backup directory (is mandatory)"
	echo "--slave=\"\" 	Local or remote slave replica path. Can be a ssh uri like ssh://user@host.com:22//path/to/slave/replica (is mandatory)"
	echo "--rsakey=\"\"	Alternative path to rsa private key for ssh connection to slave replica"
	echo "--sync-id=\"\"	Optional sync task name to identify this synchronization task when using multiple slaves"
	echo ""
	echo "Additionnaly, you may set most osync options at runtime. eg:"
	echo "SOFT_DELETE_DAYS=365 osync.sh --master=/path --slave=/other/path"
	echo ""
	exit 128
}

function SyncOnChanges {
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
		inotifywait --exclude $OSYNC_DIR $RSYNC_EXCLUDE -qq -r -e create -e modify -e delete -e move -e attrib --timeout "$MAX_WAIT" "$MASTER_SYNC_DIR" &
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
dryrun=0
silent=0
if [ "$DEBUG" == "yes" ]
then
	verbose=1
else
	verbose=0
fi
stats=0
PARTIAL=0
force_unlock=0
no_maxtime=0
# Alert flags
opts=""
soft_alert_total=0
error_alert=0
soft_stop=0
quick_sync=0
sync_on_changes=0
nolocks=0
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
		dryrun=1
		opts=$opts" --dry"
		;;
		--silent)
		silent=1
		opts=$opts" --silent"
		;;
		--verbose)
		verbose=1
		opts=$opts" --verbose"
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
		force_unlock=1
		opts=$opts" --force-unlock"
		;;
		--no-maxtime)
		no_maxtime=1
		opts=$opts" --no-maxtime"
		;;
		--help|-h|--version|-v)
		Usage
		;;
		--master=*)
		quick_sync=$(($quick_sync + 1))
		no_maxtime=1
		MASTER_SYNC_DIR=${i##*=}
		opts=$opts" --master=\"$MASTER_SYNC_DIR\""
		;;
		--slave=*)
		quick_sync=$(($quick_sync + 1))
		SLAVE_SYNC_DIR=${i##*=}
		opts=$opts" --slave=\"$SLAVE_SYNC_DIR\""
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
		nolocks=1
		;;
		--no-locks)
		nolocks=1
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
			SYNC_ID="quicksync task"
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
		ConfigFile="$1"
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
		CheckMasterSlaveDirs
		CheckMinimumSpace
		if [ $? == 0 ]; then
			RunBeforeHook
			Main
			if [ $? == 0 ]; then
				SoftDelete
			fi
			RunAfterHook
		fi
	fi
else
	Logger "Environment not suitable to run osync." "CRITICAL"
	exit 1
fi
