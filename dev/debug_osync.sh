#!/usr/bin/env bash

PROGRAM="osync" # Rsync based two way sync engine with fault tolerance
AUTHOR="(L) 2013-2015 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION=1.1-pre
PROGRAM_BUILD=2015112804
IS_STABLE=no

FUNC_BUILD=2015111901
## BEGIN Generic functions for osync & obackup written in 2013-2015 by Orsiris de Jong - http://www.netpower.fr - ozy@netpower.fr

## type -p does not work on platforms other than linux (bash). If if does not work, always assume output is not a zero exitcode
if ! type "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

# Environment variables
_DRYRUN=0
_SILENT=0

# Initial error status, logging 'WARN', 'ERROR' or 'CRITICAL' will enable alerts flags
ERROR_ALERT=0
WARN_ALERT=0

## allow function call checks			#__WITH_PARANOIA_DEBUG
if [ "$_PARANOIA_DEBUG" == "yes" ];then		#__WITH_PARANOIA_DEBUG
	_DEBUG=yes				#__WITH_PARANOIA_DEBUG
fi						#__WITH_PARANOIA_DEBUG

## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	SLEEP_TIME=.1
	_VERBOSE=0
else
	SLEEP_TIME=1
	trap 'TrapError ${LINENO} $?' ERR
	_VERBOSE=1
fi

SCRIPT_PID=$$

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

## Default log file until config file is loaded
if [ -w /var/log ]; then
	LOG_FILE="/var/log/$PROGRAM.log"
else
	LOG_FILE="./$PROGRAM.log"
fi

## Default directory where to store temporary run files
if [ -w /tmp ]; then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]; then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi

## Log a state message every $KEEP_LOGGING seconds. Should not be equal to soft or hard execution time so your log will not be unnecessary big.
KEEP_LOGGING=1801

## Correct output of sort command (language agnostic sorting)
export LC_ALL=C

# Standard alert mail body
MAIL_ALERT_MSG="Execution of $PROGRAM instance $INSTANCE_ID on $(date) has warnings/errors."

# Default alert attachment filename
ALERT_LOG_FILE="$RUN_DIR/$PROGRAM.last.log"

# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace


function Dummy {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG
	sleep .1
}

#__FUNC:Logger
function _Logger {
	local svalue="${1}" # What to log to screen
	local lvalue="${2:-$svalue}" # What to log to logfile, defaults to screen value
	echo -e "$lvalue" >> "$LOG_FILE"

	if [ $_SILENT -eq 0 ]; then
		echo -e "$svalue"
	fi
}

function Logger {
	local value="${1}" # Sentence to log (in double quotes)
	local level="${2}" # Log level: PARANOIA_DEBUG, DEBUG, NOTICE, WARN, ERROR, CRITIAL

	# <OSYNC SPECIFIC> Special case in daemon mode we should timestamp instead of counting seconds
	if [ "$sync_on_changes" == "1" ]; then
		prefix="$(date) - "
	else
		prefix="TIME: $SECONDS - "
	fi
	# </OSYNC SPECIFIC>

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix\e[41m$value\e[0m" "$prefix$value"
		ERROR_ALERT=1
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix\e[91m$value\e[0m" "$prefix$value"
		ERROR_ALERT=1
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix\e[93m$value\e[0m" "$prefix$value"
		WARN_ALERT=1
		return
	elif [ "$level" == "NOTICE" ]; then
		_Logger "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "$prefix$value"
			return
		fi
	elif [ "$level" == "PARANOIA_DEBUG" ]; then		#__WITH_PARANOIA_DEBUG
		if [ "$_PARANOIA_DEBUG" == "yes" ]; then	#__WITH_PARANOIA_DEBUG
			_Logger "$prefix$value"			#__WITH_PARANOIA_DEBUG
			return					#__WITH_PARANOIA_DEBUG
		fi						#__WITH_PARANOIA_DEBUG
	else
		_Logger "\e[41mLogger function called without proper loglevel.\e[0m"
		_Logger "$prefix$value"
	fi
}
#__ENDFUNC

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}"
	local self="${2:-false}"

	if children="$(pgrep -P "$pid")"; then
		for child in $children; do
			KillChilds "$child" true
		done
	fi

	# Try to kill nicely, if not, wait 30 seconds to let Trap actions happen before killing
	if [ "$self" == true ]; then
		kill -s SIGTERM "$pid" || (sleep 30 && kill -9 "$pid" &)
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

function SedStripQuotes {
        echo $(echo $1 | sed "s/^\([\"']\)\(.*\)\1\$/\2/g")
}

function StripSingleQuotes {
	local string="${1}"
	string="${string/#\'/}" # Remove singlequote if it begins string
	string="${string/%\'/}" # Remove singlequote if it ends string
	echo "$string"
}

function StripDoubleQuotes {
	local string="${1}"
	string="${string/#\"/}"
	string="${string/%\"/}"
	echo "$string"
}

function StripQuotes {
	local string="${1}"
	echo "$(StripSingleQuotes $(StripDoubleQuotes $string))"
}

function EscapeSpaces {
	local string="${1}" # String on which spaces will be escaped
	echo "${string// /\ }"
}

function IsNumeric {
	eval "local value=\"${1}\"" # Needed so variable variables can be processed

	local re="^-?[0-9]+([.][0-9]+)?$"
	if [[ $value =~ $re ]]; then
		echo 1
	else
		echo 0
	fi
}

function CleanUp {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$_DEBUG" != "yes" ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID"
	fi
}

function SendAlert {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$_DEBUG" == "yes" ]; then
		Logger "Debug mode, no warning email will be sent." "NOTICE"
		return 0
	fi

	# <OSYNC SPECIFIC>
	if [ "$_QUICK_SYNC" == "2" ]; then
		Logger "Current task is a quicksync task. Will not send any alert." "NOTICE"
		return 0
	fi
	# </OSYNC SPECIFIC>

	eval "cat \"$LOG_FILE\" $COMPRESSION_PROGRAM > $ALERT_LOG_FILE"
	MAIL_ALERT_MSG="$MAIL_ALERT_MSG"$'\n\n'$(tail -n 50 "$LOG_FILE")
	if [ $ERROR_ALERT -eq 1 ]; then
		subject="Error alert for $INSTANCE_ID"
	elif [ $WARN_ALERT -eq 1 ]; then
		subject="Warning alert for $INSTANCE_ID"
	else
		subject="Alert for $INSTANCE_ID"
	fi

	# Need better fallback if mail sending does not succeed
	if type mutt > /dev/null 2>&1 ; then
		echo "$MAIL_ALERT_MSG" | $(type -p mutt) -x -s "$subject" $DESTINATION_MAILS -a "$ALERT_LOG_FILE"
		if [ $? != 0 ]; then
			Logger "WARNING: Cannot send alert email via $(type -p mutt) !!!" "WARN"
		else
			Logger "Sent alert mail using mutt." "NOTICE"
			return 0
		fi
	fi

	if type mail > /dev/null 2>&1 ; then
		echo "$MAIL_ALERT_MSG" | $(type -p mail) -a "$ALERT_LOG_FILE" -s "$subject" $DESTINATION_MAILS
		if [ $? != 0 ]; then
			Logger "WARNING: Cannot send alert email via $(type -p mail) with attachments !!!" "WARN"
			echo "$MAIL_ALERT_MSG" | $(type -p mail) -s "$subject" $DESTINATION_MAILS
			if [ $? != 0 ]; then
				Logger "WARNING: Cannot send alert email via $(type -p mail) without attachments !!!" "WARN"
			else
				Logger "Sent alert mail using mail command without attachment." "NOTICE"
				return 0
			fi
		else
			Logger "Sent alert mail using mail command." "NOTICE"
			return 0
		fi
	fi

	if type sendmail > /dev/null 2>&1 ; then
		echo -e "$subject\r\n$MAIL_ALERT_MSG" | $(type -p sendmail) $DESTINATION_MAILS
		if [ $? != 0 ]; then
			Logger "WARNING: Cannot send alert email via $(type -p sendmail) !!!" "WARN"
		else
			Logger "Sent alert mail using sendmail command without attachment." "NOTICE"
			return 0
		fi
	fi

	if type sendemail > /dev/null 2>&1 ; then
		if [ "$SMTP_USER" != "" ] && [ "$SMTP_PASSWORD" != "" ]; then
			SMTP_OPTIONS="-xu $SMTP_USER -xp $SMTP_PASSWORD"
		else
			SMTP_OPTIONS=""
		fi
		$(type -p sendemail) -f $SENDER_MAIL -t $DESTINATION_MAILS -u "$subject" -m "$MAIL_ALERT_MSG" -s $SMTP_SERVER $SMTP_OPTIONS > /dev/null 2>&1
		if [ $? != 0 ]; then
			Logger "WARNING: Cannot send alert email via $(type -p sendemail) !!!" "WARN"
		else
			Logger "Sent alert mail using sendemail command without attachment." "NOTICE"
			return 0
		fi
	fi

	# If function has not returned 0 yet, assume it's critical that no alert can be sent
	Logger "/!\ CRITICAL: Cannot send alert" "ERROR" # Is not marked critical because execution must continue

	# Delete tmp log file
	if [ -f "$ALERT_LOG_FILE" ]; then
		rm "$ALERT_LOG_FILE"
	fi
}

function LoadConfigFile {
	__CheckArguments 1 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	local config_file="${1}"

	if [ ! -f "$config_file" ]; then
		Logger "Cannot load configuration file [$config_file]. Cannot start." "CRITICAL"
		exit 1
	elif [[ "$1" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$config_file]. Cannot start." "CRITICAL"
		exit 1
	else
		grep '^[^ ]*=[^;&]*' "$config_file" > "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" # WITHOUT COMMENTS
		# Shellcheck source=./sync.conf
		source "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID"
	fi
}

function GetLocalOS {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

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
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		local cmd=$SSH_CMD' "uname -spio" > "'$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID'" 2>&1'
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd" &
		WaitForTaskCompletion $! 120 240 $FUNCNAME"-1"
		retval=$?
		if [ $retval != 0 ]; then
			local cmd=$SSH_CMD' "uname -v" > "'$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID'" 2>&1'
			Logger "cmd: $cmd" "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 120 240 $FUNCNAME"-2"
			retval=$?
			if [ $retval != 0 ]; then
				local cmd=$SSH_CMD' "uname" > "'$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID'" 2>&1'
				Logger "cmd: $cmd" "DEBUG"
				eval "$cmd" &
				WaitForTaskCompletion $! 120 240 $FUNCNAME"-3"
				retval=$?
				if [ $retval != 0 ]; then
					Logger "Cannot Get remote OS type." "ERROR"
				fi
			fi
		fi

		local remote_os_var=$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)

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
	local caller_name="${4}" # Who called this function
	Logger "$FUNCNAME called by [$caller_name]." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	__CheckArguments 4 $# $FUNCNAME "$@"				#__WITH_PARANOIA_DEBUG

	local soft_alert=0 # Does a soft alert need to be triggered, if yes, send an alert once
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
				SendAlert

			fi
			if [ $exec_time -gt $hard_max_time ] && [ $hard_max_time -ne 0 ]; then
				Logger "Max hard execution time exceeded for task. Stopping task execution." "ERROR"
				kill -s SIGTERM $pid
				if [ $? == 0 ]; then
					Logger "Task stopped succesfully" "NOTICE"
				else
					Logger "Sending SIGTERM to proces failed. Trying the hard way." "ERROR"
					sleep 5 && kill -9 $pid
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
	local retval=$?
	Logger "$FUNCNAME ended for [$caller_name] with status $retval." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	return $retval
}

function WaitForCompletion {
	local pid="${1}" # pid to wait for
	local soft_max_time="${2}" # If program with pid $pid takes longer than $soft_max_time seconds, will log a warning, unless $soft_max_time equals 0.
	local hard_max_time="${3}" # If program with pid $pid takes longer than $hard_max_time seconds, will stop execution, unless $hard_max_time equals 0.
	local caller_name="${4}" # Who called this function
	Logger "$FUNCNAME called by [$caller_name]" "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	__CheckArguments 4 $# $FUNCNAME "$@"				#__WITH_PARANOIA_DEBUG

	local soft_alert=0 # Does a soft alert need to be triggered, if yes, send an alert once
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
				SendAlert
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
	retval=$?
	Logger "$FUNCNAME ended for [$caller_name] with status $retval." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	return $retval
}

function RunLocalCommand {
	local command="${1}" # Command to run
	local hard_max_time="${2}" # Max time to wait for command to compleet
	__CheckArguments 2 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ $_DRYRUN -ne 0 ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on local host." "NOTICE"
	eval "$command" > "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" 2>&1 &
	WaitForTaskCompletion $! 0 $hard_max_time $FUNCNAME
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ $_VERBOSE -eq 1 ] || [ $retval -ne 0 ]; then
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "NOTICE"
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
	__CheckArguments 2 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	if [ $_DRYRUN -ne 0 ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on remote host." "NOTICE"
	cmd=$SSH_CMD' "$command" > "'$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 0 $hard_max_time $FUNCNAME
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ -f "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" ] && ([ $_VERBOSE -eq 1 ] || [ $retval -ne 0 ])
	then
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "NOTICE"
	fi

	if [ "$STOP_ON_CMD_ERROR" == "yes" ] && [ $retval -ne 0 ]; then
		Logger "Stopping on command execution error." "CRITICAL"
		exit 1
	fi
}

function RunBeforeHook {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$LOCAL_RUN_BEFORE_CMD" != "" ]; then
		RunLocalCommand "$LOCAL_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE
	fi

	if [ "$REMOTE_RUN_BEFORE_CMD" != "" ]; then
		RunRemoteCommand "$REMOTE_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE
	fi
}

function RunAfterHook {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$LOCAL_RUN_AFTER_CMD" != "" ]; then
		RunLocalCommand "$LOCAL_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER
	fi

	if [ "$REMOTE_RUN_AFTER_CMD" != "" ]; then
		RunRemoteCommand "$REMOTE_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER
	fi
}

function CheckConnectivityRemoteHost {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug

		if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_OPERATION" != "no" ]; then
			eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1" &
			WaitForTaskCompletion $! 180 180 $FUNCNAME
			if [ $? != 0 ]; then
				Logger "Cannot ping $REMOTE_HOST" "CRITICAL"
				return 1
			fi
		fi
	fi
}

function CheckConnectivity3rdPartyHosts {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug

		if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]; then
			remote_3rd_party_success=0
			OLD_IFS=$IFS
			IFS=$' \t\n'
			for i in $REMOTE_3RD_PARTY_HOSTS
			do
				eval "$PING_CMD $i > /dev/null 2>&1" &
				WaitForTaskCompletion $! 360 360 $FUNCNAME
				if [ $? != 0 ]; then
					Logger "Cannot ping 3rd party host $i" "WARN"
				else
					remote_3rd_party_success=1
				fi
			done
			IFS=$OLD_IFS
			if [ $remote_3rd_party_success -ne 1 ]; then
				Logger "No remote 3rd party host responded to ping. No internet ?" "CRITICAL"
				return 1
			fi
		fi
	fi
}

#__BEGIN_WITH_PARANOIA_DEBUG
function __CheckArguments {
	# Checks the number of arguments of a function and raises an error if some are missing

	if [ "$_DEBUG" == "yes" ]; then
                local number_of_arguments="${1}" # Number of arguments the tested function should have
                local number_of_given_arguments="${2}" # Number of arguments that have been passed
                local function_name="${3}" # Function name that called __CheckArguments

		if [ "$_PARANOIA_DEBUG" == "yes" ]; then
			Logger "Entering function [$function_name]." "DEBUG"
		fi

                # All arguments of the function to check are passed as array in ${4} (the function call waits for $@)
                # If any of the arguments contains spaces, bash things there are two aguments
                # In order to avoid this, we need to iterate over ${4} and count

                local iterate=4
                local fetch_arguments=1
                local arg_list=""
                while [ $fetch_arguments -eq 1 ]; do
                        cmd='argument=${'$iterate'}'
                        eval $cmd
                        if [ "$argument" = "" ]; then
                                fetch_arguments=0
                        else
                                arg_list="$arg_list [Argument $(($iterate-3)): $argument]"
                                iterate=$(($iterate+1))
                        fi
                done
                local counted_arguments=$((iterate-4))

                if [ $counted_arguments -ne $number_of_arguments ]; then
                        Logger "Function $function_name may have inconsistent number of arguments. Expected: $number_of_arguments, count: $counted_arguments, see log file." "ERROR"
                        Logger "Arguments passed: $arg_list" "ERROR"
                fi
	fi
}


function old__CheckArguments {
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
				echo "Argument list (including checks): $*" >> "$LOG_FILE"
			fi
		fi

		if [ $number_of_arguments -ne $number_of_given_arguments ]; then
			Logger "Inconsistnent number of arguments in $function_name. Should have $number_of_arguments arguments, has $number_of_given_arguments arguments, see log file." "CRITICAL"
			# Cannot user Logger here because $@ is a list of arguments
			echo "Argumnt list: $4" >> "$LOG_FILE"
		fi

	fi
}
#__END_WITH_PARANOIA_DEBUG

function PreInit {
	 __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	## SSH compression
        if [ "$SSH_COMPRESSION" != "no" ]; then
                SSH_COMP=-C
        else
                SSH_COMP=
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

	 ## Set compression executable and extension
        COMPRESSION_LEVEL=3
        if type xz > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| xz -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.xz
        elif type lzma > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| lzma -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.lzma
        elif type pigz > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| pigz -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.gz
                COMPRESSION_OPTIONS=--rsyncable
        elif type gzip > /dev/null 2>&1
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

function PostInit {
        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	# Define remote commands
        SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
        SCP_CMD="$(type -p scp) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY -P $REMOTE_PORT"
        RSYNC_SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY -p $REMOTE_PORT"
}

function InitLocalOSSettings {
        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

        ## If running under Msys, some commands do not run the same way
        ## Using mingw version of find instead of windows one
        ## Getting running processes is quite different
        ## Ping command is not the same
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
        __CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

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

## END Generic functions

## Working directory. This is the name of the osync subdirectory contained in every replica.
OSYNC_DIR=".osync_workdir"

function TrapStop {
	if [ $soft_stop -eq 0 ]; then
		Logger " /!\ WARNING: Manual exit of osync is really not recommended. Sync will be in inconsistent state." "WARN"
		Logger " /!\ WARNING: If you are sure, please hit CTRL+C another time to quit." "WARN"
		soft_stop=1
		return 1
	fi

	if [ $soft_stop -eq 1 ]; then
		Logger " /!\ WARNING: CTRL+C hit twice. Exiting osync. Please wait while replicas get unlocked..." "WARN"
		soft_stop=2
		exit 1
	fi
}

function TrapQuit {
	if [ $ERROR_ALERT -ne 0 ]; then
		UnlockReplicas
		CleanUp
		Logger "$PROGRAM finished with errors." "ERROR"
		exitcode=1
	elif [ $WARN_ALERT -ne 0 ]; then
		UnlockReplicas
		CleanUp
		Logger "$PROGRAM finished with warnings." "WARN"
	else
		UnlockReplicas
		CleanUp
		Logger "$PROGRAM finished." "NOTICE"
		exitcode=0
	fi

#TODO: Check new KillChilds function for service mode

#	if ps -p $OSYNC_SUB_PID > /dev/null 2>&1
#	then
#		kill -s SIGTERM $OSYNC_SUB_PID
#		if [ $? == 0 ]; then
#			Logger "Stopped sub process [$OSYNC_SUB_PID]." "DEBUG"
#		else
#			Logger "Could not terminate sub process [$OSYNC_SUB_PID]. Trying the hard way." "DEBUG"
#			kill -9 $OSYNC_SUB_PID
#			if [ $? != 0 ]; then
#				Logger "Could not kill sub process [$OSYNC_SUB_PID]." "ERROR"
#			fi
#		fi
#	fi

	KillChilds $$ > /dev/null 2>&1

	exit $exitcode
}

function CheckEnvironment {
	__CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		if ! type ssh > /dev/null 2>&1 ; then
			Logger "ssh not present. Cannot start sync." "CRITICAL"
			exit 1
		fi
	fi

	if ! type rsync > /dev/null 2>&1 ; then
		Logger "rsync not present. Sync cannot start." "CRITICAL"
		exit 1
	fi
}

function CheckCurrentConfig {
	__CheckArguments 0 $# $FUNCNAME "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$INSTANCE_ID" == "" ]; then
		Logger "No INSTANCE_ID defined in config file." "CRITICAL"
		exit 1
	fi

	if [ "$INITIATOR_SYNC_DIR" == "" ]; then
		Logger "No INITIATOR_SYNC_DIR set in config file." "CRITICAL"
		exit 1
	fi

	if [ "$TARGET_SYNC_DIR" == "" ]; then
		Logger "Not TARGET_SYNC_DIR set in config file." "CRITICAL"
		exit 1
	fi

	# Check all variables that should contain "yes" or "no"
	declare -a yes_no_vars=(CREATE_DIRS SUDO_EXEC SSH_COMPRESSION REMOTE_HOST_PING PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS CHECKSUM RSYNC_COMPRESS CONFLICT_BACKUP CONFLICT_BACKUP_MULTIPLE SOFT_DELETE RESUME_SYNC FORCE_STRANGER_LOCK_RESUME PARTIAL DELTA_COPIES STOP_ON_CMD_ERROR)
	for i in ${yes_no_vars[@]}; do
		test="if [ \"\$$i\" != \"yes\" ] && [ \"\$$i\" != \"no\" ]; then Logger \"Bogus $i value defined in config file.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done

	# Check all variables that should contain a numerical value >= 0
	declare -a num_vars=(MINIMUM_SPACE BANDWIDTH SOFT_MAX_EXEC_TIME HARD_MAX_EXEC_TIME MIN_WAIT MAX_WAIT CONFLICT_BACKUP_DAYS SOFT_DELETE_DAYS RESUME_TRY)
	for i in ${num_vars[@]}; do
		test="if [ $(IsNumeric \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value defined in config file.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done

	#TODO-v2.1: Add runtime variable tests (RSYNC_ARGS etc)
}

###### Osync specific functions (non shared)

function _CreateStateDirsLocal {
	local replica_state_dir="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if ! [ -d "$replica_state_dir" ]; then
		$COMMAND_SUDO mkdir -p "$replica_state_dir" > "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" 2>&1
		if [ $? != 0 ]; then
			Logger "Cannot create state dir [$replica_state_dir]." "CRITICAL"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
			exit 1
		fi
	fi
}

function _CreateStateDirsRemote {
	local replica_state_dir="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if ! [ -d \"'$replica_state_dir'\" ]; then '$COMMAND_SUDO' mkdir -p \"'$replica_state_dir'\"; fi" > "'$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 $FUNCNAME
	if [ $? != 0 ]; then
		Logger "Cannot create remote state dir [$replica_state_dir]." "CRITICAL"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
		exit 1
	fi
}

function CreateStateDirs {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	_CreateStateDirsLocal "$INITIATOR_STATE_DIR"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CreateStateDirsLocal "$TARGET_STATE_DIR"
	else
		_CreateStateDirsRemote "$TARGET_STATE_DIR"
	fi
}

function _CheckReplicaPathsLocal {
	local replica_path="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ ! -d "$replica_path" ]; then
		if [ "$CREATE_DIRS" == "yes" ]; then
			$COMMAND_SUDO mkdir -p "$replica_path" > "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" 2>&1
			if [ $? != 0 ]; then
				Logger "Cannot create local replica path [$replica_path]." "CRITICAL"
				Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)"
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
	__CheckArguments 1 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	cmd=$SSH_CMD' "if ! [ -d \"'$replica_path'\" ]; then if [ \"'$CREATE_DIRS'\" == \"yes\" ]; then '$COMMAND_SUDO' mkdir -p \"'$replica_path'\"; fi; fi" > "'$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 $FUNCNAME
	if [ $? != 0 ]; then
		Logger "Cannot create remote replica path [$replica_path]." "CRITICAL"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "ERROR"
		exit 1
	fi

	cmd=$SSH_CMD' "if [ ! -w \"'$replica_path'\" ];then exit 1; fi" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 $FUNCNAME
	if [ $? != 0 ]; then
		Logger "Remote replica path [$replica_path] is not writable." "CRITICAL"
		exit 1
	fi
}

function CheckReplicaPaths {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	#INITIATOR_SYNC_DIR_CANN=$(realpath "$INITIATOR_SYNC_DIR")	#TODO: investigate realpath & readlink issues on MSYS and busybox here
	#TARGET_SYNC_DIR_CANN=$(realpath "$TARGET_SYNC_DIR")

	#if [ "$REMOTE_OPERATION" != "yes" ]; then
	#	if [ "$INITIATOR_SYNC_DIR_CANN" == "$TARGET_SYNC_DIR_CANN" ]; then
	#		Logger "Master directory [$INITIATOR_SYNC_DIR] cannot be the same as target directory." "CRITICAL"
	#		exit 1
	#	fi
	#fi

	_CheckReplicaPathsLocal "$INITIATOR_SYNC_DIR"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CheckReplicaPathsLocal "$TARGET_SYNC_DIR"
	else
		_CheckReplicaPathsRemote "$TARGET_SYNC_DIR"
	fi
}

function _CheckDiskSpaceLocal {
	local replica_path="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	Logger "Checking minimum disk space in [$replica_path]." "NOTICE"

	local initiator_space=$(df -P "$replica_path" | tail -1 | awk '{print $4}')
	if [ $initiator_space -lt $MINIMUM_SPACE ]; then
		Logger "There is not enough free space on initiator [$initiator_space KB]." "WARN"
	fi
}

function _CheckDiskSpaceRemote {
	local replica_path="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	Logger "Checking minimum disk space on target [$replica_path]." "NOTICE"

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "'$COMMAND_SUDO' df -P \"'$replica_path'\"" > "'$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 $FUNCNAME
	if [ $? != 0 ]; then
		Logger "Cannot get free space on target [$replica_path]." "ERROR"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "NOTICE"
	else
		local target_space=$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID | tail -1 | awk '{print $4}')
		if [ $target_space -lt $MINIMUM_SPACE ]; then
			Logger "There is not enough free space on target [$replica_path]." "WARN"
		fi
	fi
}

function CheckDiskSpace {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	_CheckDiskSpaceLocal "$INITIATOR_SYNC_DIR"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CheckDiskSpaceLocal "$TARGET_SYNC_DIR"
	else
		_CheckDiskSpaceRemote "$TARGET_SYNC_DIR"
	fi
}

function RsyncPatternsAdd {
	local pattern="${1}"
	local pattern_type="${2}"	# exclude or include

	__CheckArguments 2 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	# Disable globbing so wildcards from exclusions do not get expanded
	set -f
	rest="$pattern"
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
			if [ "$RSYNC_PATTERNS" == "" ]; then
			RSYNC_PATTERNS="--"$pattern_type"=\"$str\""
		else
			RSYNC_PATTERNS="$RSYNC_PATTERNS --"$pattern_type"=\"$str\""
		fi
	done
	set +f
}

function RsyncPatternsFromAdd {
	local pattern_from="${1}"
	local pattern_type="${2}"

	__CheckArguments 2 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ ! "$pattern_from" == "" ]; then
		## Check if the exclude list has a full path, and if not, add the config file path if there is one
		if [ "$(basename $pattern_from)" == "$pattern_from" ]; then
			pattern_from=$(dirname $ConfigFile)/$pattern_ffrom
		fi

		if [ -e "$pattern_from" ]; then
			RSYNC_PATTERNS="$RSYNC_PATTERNS --"$pattern_type"-from=\"$pattern_from\""
		fi
	fi
}

function RsyncPatterns {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$RSYNC_PATTERN_FIRST" == "exclude" ]; then
		RsyncPatternsAdd "$RSYNC_EXCLUDE_PATTERN" "exclude"
		RsyncPatternsFromAdd "$RSYNC_EXCLUDE_FROM" "exclude"
		RsyncPatternsAdd "$RSYNC_INCLUDE_PATTERN" "include"
		RsyncPatternsFromAdd "$RSYNC_INCLUDE_FROM" "include"
	elif [ "$RSYNC_PATTERN_FIRST" == "include" ]; then
		RsyncPatternsAdd "$RSYNC_INCLUDE_PATTERN" "include"
		RsyncPatternsFromAdd "$RSYNC_EXCLUDE_FROM" "include"
		RsyncPatternsAdd "$RSYNC_EXCLUDE_PATTERN" "exclude"
		RsyncPatternsFromAdd "$RSYNC_EXCLUDE_FROM" "exclude"
	else
		Logger "Bogus RSYNC_PATTERN_FIRST value in config file. Will not use rsync patterns." "WARN"
	fi
}

function _WriteLockFilesLocal {
	local lockfile="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	$COMMAND_SUDO echo "$SCRIPT_PID@$INSTANCE_ID" > "$lockfile" #TODO: Determine best format for lockfile for v2
	if [ $?	!= 0 ]; then
		Logger "Could not create lock file [$lockfile]." "CRITICAL"
		exit 1
	else
		Logger "Locked replica on [$lockfile]." "DEBUG"
	fi
}

function _WriteLockFilesRemote {
	local lockfile="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "echo '$SCRIPT_PID@$INSTANCE_ID' | '$COMMAND_SUDO' tee \"'$lockfile'\"" > /dev/null 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 $FUNCNAME
	if [ $? != 0 ]; then
		Logger "Could not set lock on remote target replica." "CRITICAL"
		exit 1
	else
		Logger "Locked remote target replica." "DEBUG"
	fi
}

function WriteLockFiles {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	_WriteLockFilesLocal "$INITIATOR_LOCKFILE"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_WriteLockFilesLocal "$TARGET_LOCKFILE"
	else
		_WriteLockFilesRemote "$TARGET_LOCKFILE"
	fi
}

function _CheckLocksLocal {
	local lockfile="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ -f "$lockfile" ]; then
		local lockfile_content=$(cat $lockfile)
		Logger "Master lock pid present: $lockfile_content" "DEBUG"
		local lock_pid=${lockfile_content%@*}
		local lock_instance_id=${lockfile_content#*@}
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
	__CheckArguments 1 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if [ -f \"'$lockfile'\" ]; then cat \"'$lockfile'\"; fi" > "'$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID'"'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 $FUNCNAME
	if [ $? != 0 ]; then
		if [ -f "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" ]; then
			local lockfile_content=$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)
		else
			Logger "Cannot get remote lockfile." "CRITICAL"
			exit 1
		fi
	fi

	local lock_pid=${lockfile_content%@*}
	local lock_instance_id=${lockfile_content#*@}

	if [ "$lock_pid" != "" ] && [ "$lock_instance_id" != "" ]; then
		Logger "Remote lock is: $lock_pid@$lock_instance_id" "DEBUG"

		ps -p$lock_pid > /dev/null 2>&1
		if [ $? != 0 ]; then
			if [ "$lock_instance_id" == "$INSTANCE_ID" ]; then
				Logger "There is a dead osync lock on target replica that corresponds to this initiator sync id [$lock_instance_id]. Instance [$lock_pid] no longer running. Resuming." "NOTICE"
			else
				if [ "$FORCE_STRANGER_LOCK_RESUME" == "yes" ]; then
					Logger "WARNING: There is a dead osync lock on target replica that does not correspond to this initiator sync-id [$lock_instance_id]. Forcing resume." "WARN"
				else
					Logger "There is a dead osync lock on target replica that does not correspond to this initiator sync-id [$lock_instance_id]. Will not resume." "CRITICAL"
					exit 1
				fi
			fi
		else
			Logger "There is already a local instance of osync that locks target replica [$lock_pid@$lock_instance_id]. Cannot start." "CRITICAL"
			exit 1
		fi
	fi
}

function CheckLocks {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ $_NOLOCKS -eq 1 ]; then
		return 0
	fi

	# Do not bother checking for locks when FORCE_UNLOCK is set
	if [ $FORCE_UNLOCK -eq 1 ]; then
		WriteLockFiles
		if [ $? != 0 ]; then
			exit 1
		fi
	fi
	_CheckLocksLocal "$INITIATOR_LOCKFILE"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CheckLocksLocal "$TARGET_LOCKFILE"
	else
		_CheckLocksRemote "$TARGET_LOCKFILE"
	fi

	WriteLockFiles
}

function _UnlockReplicasLocal {
	local lockfile="${1}"
	__CheckArguments 1 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

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
	__CheckArguments 1 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if [ -f \"'$lockfile'\" ]; then '$COMMAND_SUDO' rm -f \"'$lockfile'\"; fi" > "'$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 $FUNCNAME
	if [ $? != 0 ]; then
		Logger "Could not unlock remote replica." "ERROR"
		Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "NOTICE"
	else
		Logger "Removed remote replica lock." "DEBUG"
	fi
}

function UnlockReplicas {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ $_NOLOCKS -eq 1 ]; then
		return 0
	fi

	_UnlockReplicasLocal "$INITIATOR_LOCKFILE"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_UnlockReplicasLocal "$TARGET_LOCKFILE"
	else
		_UnlockReplicasRemote "$TARGET_LOCKFILE"
	fi
}

###### Sync core functions

	## Rsync does not like spaces in directory names, considering it as two different directories. Handling this schema by escaping space.
	## It seems this only happens when trying to execute an rsync command through weval $rsync_cmd on a remote host.
	## So I am using unescaped $INITIATOR_SYNC_DIR for local rsync calls and escaped $ESC_INITIATOR_SYNC_DIR for remote rsync calls like user@host:$ESC_INITIATOR_SYNC_DIR
	## The same applies for target sync dir..............................................T.H.I.S..I.S..A..P.R.O.G.R.A.M.M.I.N.G..N.I.G.H.T.M.A.R.E

function tree_list {
	local replica_path="${1}" # path to the replica for which a tree needs to be constructed
	local replica_type="${2}" # replica type: initiator, target
	local tree_filename="${3}" # filename to output tree (will be prefixed with $replica_type)
	__CheckArguments 3 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	local escaped_replica_path=$(EscapeSpaces "$replica_path") #TODO: See if escpaed still needed when using singlequotes instead of doublequotes for command eval

	Logger "Creating $replica_type replica file list [$replica_path]." "NOTICE"
	if [ "$REMOTE_OPERATION" == "yes" ] && [ "$replica_type" == "target" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -8 --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE -e \"$RSYNC_SSH_CMD\" --list-only $REMOTE_USER@$REMOTE_HOST:\"$escaped_replica_path/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.$replica_type.$SCRIPT_PID\" &"
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -8 --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --list-only \"$replica_path/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.$replica_type.$SCRIPT_PID\" &"
	fi
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	## Redirect commands stderr here to get rsync stderr output in logfile
	eval "$rsync_cmd" 2>> "$LOG_FILE"
	WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $FUNCNAME
	retval=$?
	## Retval 24 = some files vanished while creating list
	if ([ $retval == 0 ] || [ $retval == 24 ]) && [ -f "$RUN_DIR/$PROGRAM.$replica_type.$SCRIPT_PID" ]; then
		mv -f "$RUN_DIR/$PROGRAM.$replica_type.$SCRIPT_PID" "$INITIATOR_STATE_DIR/$replica_type$tree_filename"
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
	local deleted_failed_list_file="${5}" # file containing files that could not be deleted on last run, will be prefixed with replica type
	__CheckArguments 5 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	# TODO: Check why external filenames are used (see _DRYRUN option because of NOSUFFIX)

	Logger "Creating $replica_type replica deleted file list." "NOTICE"
	if [ -f "$INITIATOR_STATE_DIR/$replica_type$TREE_AFTER_FILENAME_NO_SUFFIX" ]; then
		## Same functionnality, comm is much faster than grep but is not available on every platform
		if type comm > /dev/null 2>&1 ; then
			cmd="comm -23 \"$INITIATOR_STATE_DIR/$replica_type$TREE_AFTER_FILENAME_NO_SUFFIX\" \"$INITIATOR_STATE_DIR/$replica_type$tree_file_current\" > \"$INITIATOR_STATE_DIR/$replica_type$deleted_list_file\""
		else
			## The || : forces the command to have a good result
			cmd="(grep -F -x -v -f \"$INITIATOR_STATE_DIR/$replica_type$tree_file_current\" \"$INITIATOR_STATE_DIR/$replica_type$TREE_AFTER_FILENAME_NO_SUFFIX\" || :) > \"$INITIATOR_STATE_DIR/$replica_type$deleted_list_file\""
		fi

		Logger "CMD: $cmd" "DEBUG"
		eval "$cmd" 2>> "$LOG_FILE"
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
	__CheckArguments 3 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

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

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		if [ "$source_replica" == "initiator" ]; then
			rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $BACKUP_DIR --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"$INITIATOR_STATE_DIR/$source_replica$delete_list_filename\" --exclude-from=\"$INITIATOR_STATE_DIR/$destination_replica$delete_list_filename\" \"$SOURCE_DIR/\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_DEST_DIR/\" > $RUN_DIR/$PROGRAM.update.$destination_replica.$SCRIPT_PID 2>&1 &"
		else
			rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $BACKUP_DIR --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"$INITIATOR_STATE_DIR/$destination_replica$delete_list_filename\" --exclude-from=\"$INITIATOR_STATE_DIR/$source_replica$delete_list_filename\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_SOURCE_DIR/\" \"$DEST_DIR/\" > $RUN_DIR/$PROGRAM.update.$destination_replica.$SCRIPT_PID 2>&1 &"
		fi
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $SYNC_OPTS $BACKUP_DIR --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"$INITIATOR_STATE_DIR/$source_replica$delete_list_filename\" --exclude-from=\"$INITIATOR_STATE_DIR/$destination_replica$delete_list_filename\" \"$SOURCE_DIR/\" \"$DEST_DIR/\" > $RUN_DIR/$PROGRAM.update.$destination_replica.$SCRIPT_PID 2>&1 &"
	fi
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	eval "$rsync_cmd"
	WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $FUNCNAME
	retval=$?
	if [ $_VERBOSE -eq 1 ] && [ -f "$RUN_DIR/$PROGRAM.update.$destination_replica.$SCRIPT_PID" ]; then
		Logger "List:\n$(cat $RUN_DIR/$PROGRAM.update.$destination_replica.$SCRIPT_PID)" "NOTICE"
	fi

	if [ $retval != 0 ] && [ $retval != 24 ]; then
		Logger "Updating $destination_replica replica failed. Stopping execution." "CRITICAL"
		if [ $_VERBOSE -eq 0 ] && [ -f "$RUN_DIR/$PROGRAM.update.$destination_replica.$SCRIPT_PID" ]; then
			Logger "Rsync output:\n$(cat $RUN_DIR/$PROGRAM.update.$destination_replica.$SCRIPT_PID)" "NOTICE"
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
	local deleted_failed_list_file="${4}" # file containing files that could not be deleted on last run, will be prefixed with replica type
	__CheckArguments 4 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	## On every run, check wheter the next item is already deleted because it is included in a directory already deleted
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
						rm -rf "${replica_dir:?}$deletion_dir/$files"
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
	local deleted_failed_list_file="${4}" # file containing files that could not be deleted on last run, will be prefixed with replica type
	__CheckArguments 4 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	## This is a special coded function. Need to redelcare local functions on remote host, passing all needed variables as escaped arguments to ssh command.
	## Anything beetween << ENDSSH and ENDSSH will be executed remotely

	# Additionnaly, we need to copy the deletetion list to the remote state folder
	ESC_DEST_DIR="$(EscapeSpaces "$TARGET_STATE_DIR")"
	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" \"$INITIATOR_STATE_DIR/$2\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_DEST_DIR/\" > $RUN_DIR/$PROGRAM.$FUNCNAME.precopy.$SCRIPT_PID 2>&1"
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	eval "$rsync_cmd" 2>> "$LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot copy the deletion list to remote replica." "ERROR"
		if [ -f "$RUN_DIR/$PROGRAM.$FUNCNAME.precopy.$SCRIPT_PID" ]; then
			Logger "$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.precopy.$SCRIPT_PID)" "ERROR"
		fi
		exit 1
	fi

$SSH_CMD ERROR_ALERT=0 sync_on_changes=$sync_on_changes _SILENT=$_SILENT _DEBUG=$_DEBUG _DRYRUN=$_DRYRUN _VERBOSE=$_VERBOSE COMMAND_SUDO=$COMMAND_SUDO FILE_LIST="$(EscapeSpaces "$TARGET_STATE_DIR/$deleted_list_file")" REPLICA_DIR="$(EscapeSpaces "$replica_dir")" DELETE_DIR="$(EscapeSpaces "$deletion_dir")" FAILED_DELETE_LIST="$(EscapeSpaces "$TARGET_STATE_DIR/$deleted_failed_list_file")" 'bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID" 2>&1 &

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

	## On every run, check wheter the next item is already deleted because it is included in a directory already deleted
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
						$COMMAND_SUDO mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$DELETE_DIR"1
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
	#TODO: Need to check if file exists prior to copy (or add a filemask and copy all state files)
	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_SOURCE_FILE\" \"$INITIATOR_STATE_DIR\" > \"$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID\""
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	eval "$rsync_cmd" 2>> "$LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot copy back the failed deletion list to initiator replica." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID" ]; then
			Logger "Comand output: $(cat $RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID)" "NOTICE"
		fi
		exit 1
	fi



	exit $?
}

# delete_propagation(replica name, deleted_list_filename, deleted_failed_file_list)
function deletion_propagation {
	local replica_type="${1}" # Contains replica type: initiator, target
	local deleted_list_file="${2}" # file containing deleted file list, will be prefixed with replica type
	local deleted_failed_list_file="${3}" # file containing files that could not be deleted on last run, will be prefixed with replica type
	__CheckArguments 3 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	Logger "Propagating deletions to $replica_type replica." "NOTICE"

	if [ "$replica_type" == "initiator" ]; then
		REPLICA_DIR="$INITIATOR_SYNC_DIR"
		DELETE_DIR="$INITIATOR_DELETE_DIR"

		_delete_local "$REPLICA_DIR" "target$deleted_list_file" "$DELETE_DIR" "target$deleted_failed_list_file" &
		WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $FUNCNAME
		retval=$?
		if [ $retval != 0 ]; then
			Logger "Deletion on replica $replica_type failed." "CRITICAL"
			exit 1
		fi
	else
		REPLICA_DIR="$TARGET_SYNC_DIR"
		DELETE_DIR="$TARGET_DELETE_DIR"

		if [ "$REMOTE_OPERATION" == "yes" ]; then
			_delete_remote "$REPLICA_DIR" "initiator$deleted_list_file" "$DELETE_DIR" "initiator$deleted_failed_list_file" &
		else
			_delete_local "$REPLICA_DIR" "initiator$deleted_list_file" "$DELETE_DIR" "initiator$deleted_failed_list_file" &
		fi
		WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $FUNCNAME
		retval=$?
		if [ $retval == 0 ]; then
			if [ -f "$RUN_DIR/$PROGRAM._delete_remote.$SCRIPT_PID" ] && [ $_VERBOSE -eq 1 ]; then
				Logger "Remote:\n$(cat $RUN_DIR/$PROGRAM._delete_remote.$SCRIPT_PID)" "DEBUG"
			fi
			return $retval
		else
			Logger "Deletion on remote system failed." "CRITICAL"
			if [ -f "$RUN_DIR/$PROGRAM_remote_deletion_$SCRIPT_PID" ]; then
				Logger "Remote:\n$(cat $RUN_DIR/$PROGRAM._delete_remote.$SCRIPT_PID)" "CRITICAL"
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
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

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
			Logger "Will not resume aborted osync execution. Too many resume tries [$resume_count]." "WARN"
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
	__CheckArguments 3 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ -d "$replica_deletion_path" ]; then
		if [ $_DRYRUN -eq 1 ]; then
			Logger "Listing files older than $change_time days on $replica_type replica. Does not remove anything." "NOTICE"
		else
			Logger "Removing files older than $change_time days on $replica_type replica." "NOTICE"
		fi
			if [ $_VERBOSE -eq 1 ]; then
			# Cannot launch log function from xargs, ugly hack
			$FIND_CMD "$replica_deletion_path/" -type f -ctime +$change_time -print0 | xargs -0 -I {} echo "Will delete file {}" > "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "NOTICE"
			$FIND_CMD "$replica_deletion_path/" -type d -empty -ctime +$change_time -print0 | xargs -0 -I {} echo "Will delete directory {}" > "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "NOTICE"
		fi
			if [ $_DRYRUN -ne 1 ]; then
			$FIND_CMD "$replica_deletion_path/" -type f -ctime +$change_time -print0 | xargs -0 -I {} rm -f "{}" && $FIND_CMD "$replica_deletion_path/" -type d -empty -ctime +$change_time -print0 | xargs -0 -I {} rm -rf "{}" > "$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID" 2>&1 &
		else
			Dummy &
		fi
		WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $FUNCNAME
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Error while executing cleanup on $replica_type replica." "ERROR"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "NOTICE"
		else
			Logger "Cleanup complete on $replica_type replica." "NOTICE"
		fi
	elif [ -d "$replica_deletion_path" ] && ! [ -w "$replica_deletion_path" ]; then
		Logger "Warning: $replica_type replica dir [$replica_deletion_path] is not writable. Cannot clean old files." "ERROR"
	fi
}

function _SoftDeleteRemote {
	local replica_type="${1}"
	local replica_deletion_path="${2}" # Contains the full path to softdelete / backup directory without ending slash
	local change_time="${3}"
	__CheckArguments 3 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	if [ $_DRYRUN -eq 1 ]; then
		Logger "Listing files older than $change_time days on target replica. Does not remove anything." "NOTICE"
	else
		Logger "Removing files older than $change_time days on target replica." "NOTICE"
	fi

	if [ $_VERBOSE -eq 1 ]; then
		# Cannot launch log function from xargs, ugly hack
		cmd=$SSH_CMD' "if [ -w \"'$replica_deletion_path'\" ]; then '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replica_deletion_path'/\" -type f -ctime +'$change_time' -print0 | xargs -0 -I {} echo Will delete file {} && '$REMOTE_FIND_CMD' \"'$replica_deletion_path'/\" -type d -empty -ctime '$change_time' -print0 | xargs -0 -I {} echo Will delete directory {}; else echo \"Directory not writable\"; return 1; fi" > "'$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID'" 2>&1'
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd" &
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "NOTICE"
	fi

	if [ $_DRYRUN -ne 1 ]; then
		cmd=$SSH_CMD' "if [ -w \"'$replica_deletion_path'\" ]; then '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replica_deletion_path'/\" -type f -ctime +'$change_time' -print0 | xargs -0 -I {} rm -f \"{}\" && '$REMOTE_FIND_CMD' \"'$replica_deletion_path'/\" -type d -empty -ctime '$change_time' -print0 | xargs -0 -I {} rm -rf \"{}\"; else echo \"Directory not writable\"; return 1; fi" > "'$RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID'" 2>&1'
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd" &
	else
		Dummy &
	fi
	WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $FUNCNAME
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Error while executing cleanup on remote target replica." "ERROR"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.$FUNCNAME.$SCRIPT_PID)" "NOTICE"
	else
		Logger "Cleanup complete on target replica." "NOTICE"
	fi
}

function SoftDelete {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$CONFLICT_BACKUP" != "no" ] && [ $CONFLICT_BACKUP_DAYS -ne 0 ]; then
		Logger "Running conflict backup cleanup." "NOTICE"

		_SoftDeleteLocal "intiator" "$INITIATOR_SYNC_DIR$INITIATOR_BACKUP_DIR" $CONFLICT_BACKUP_DAYS
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_SoftDeleteLocal "target" "$TARGET_SYNC_DIR$TARGET_BACKUP_DIR" $CONFLICT_BACKUP_DAYS
		else
			_SoftDeleteRemote "target" "$TARGET_SYNC_DIR$TARGET_BACKUP_DIR" $CONFLICT_BACKUP_DAYS
		fi
	fi

	if [ "$SOFT_DELETE" != "no" ] && [ $SOFT_DELETE_DAYS -ne 0 ]; then
		Logger "Running soft deletion cleanup." "NOTICE"

		_SoftDeleteLocal "initiator" "$INITIATOR_SYNC_DIR$INITIATOR_DELETE_DIR" $SOFT_DELETE_DAYS
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_SoftDeleteLocal "target" "$TARGET_SYNC_DIR$TARGET_DELETE_DIR" $SOFT_DELETE_DAYS
		else
			_SoftDeleteRemote "target" "$TARGET_SYNC_DIR$TARGET_DELETE_DIR" $SOFT_DELETE_DAYS
		fi
	fi
}

function Init {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

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

	## Test if target dir is a ssh uri, and if yes, break it down it its values
	if [ "${TARGET_SYNC_DIR:0:6}" == "ssh://" ]; then
		REMOTE_OPERATION="yes"

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
		RSYNC_PARTIAL_EXCLUDE="--exclude=\"$PARTIAL_DIR\""
	fi

	if [ "$DELTA_COPIES" != "no" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" --no-whole-file"
	else
		RSYNC_ARGS=$RSYNC_ARGS" --whole-file"
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

	## Add Rsync include / exclude patterns
	RsyncPatterns

	## Filenames for state files
	if [ $_DRYRUN -eq 1 ]; then
		dry_suffix="-dry"
	fi

	TREE_CURRENT_FILENAME="-tree-current-$INSTANCE_ID$dry_suffix"
	TREE_AFTER_FILENAME="-tree-after-$INSTANCE_ID$dry_suffix"
	TREE_AFTER_FILENAME_NO_SUFFIX="-tree-after-$INSTANCE_ID"
	DELETED_LIST_FILENAME="-deleted-list-$INSTANCE_ID$dry_suffix"
	FAILED_DELETE_LIST_FILENAME="-failed-delete-$INSTANCE_ID$dry_suffix"
	INITIATOR_LAST_ACTION="$INITIATOR_STATE_DIR/last-action-$INSTANCE_ID$dry_suffix"
	INITIATOR_RESUME_COUNT="$INITIATOR_STATE_DIR/resume-count-$INSTANCE_ID$dry_suffix"

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
}

function Main {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	CreateStateDirs
	CheckLocks
	Sync
}

function Usage {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$IS_STABLE" != "yes" ]; then
		echo -e "\e[93mThis is an unstable dev build. Please use with caution.\e[0m"
	fi

	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo $AUTHOR
	echo $CONTACT
	echo ""
	echo "You may use osync with a full blown configuration file, or use its default options for quick command line sync."
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
	echo "--initiator=\"\"		Master replica path. Will contain state and backup directory (is mandatory)"
	echo "--target=\"\" 		Local or remote target replica path. Can be a ssh uri like ssh://user@host.com:22//path/to/target/replica (is mandatory)"
	echo "--rsakey=\"\"		Alternative path to rsa private key for ssh connection to target replica"
	echo "--instance-id=\"\"	Optional sync task name to identify this synchronization task when using multiple targets"
	echo ""
	echo "Additionaly, you may set most osync options at runtime. eg:"
	echo "SOFT_DELETE_DAYS=365 osync.sh --initiator=/path --target=/other/path"
	echo ""
	exit 128
}

function SyncOnChanges {
	__CheckArguments 0 $# $FUNCNAME "$@"	#__WITH_PARANOIA_DEBUG

	if ! type inotifywait > /dev/null 2>&1 ; then
		Logger "No inotifywait command found. Cannot monitor changes." "CRITICAL"
		exit 1
	fi

	Logger "#### Running osync in file monitor mode." "NOTICE"

	while true
	do
		if [ "$ConfigFile" != "" ]; then
			cmd='bash '$osync_cmd' "'$ConfigFile'" '$opts
		else
			cmd='bash '$osync_cmd' '$opts
		fi
		Logger "daemon cmd: $cmd" "DEBUG"
		eval "$cmd"
		retval=$?
		if [ $retval != 0 ]; then
			Logger "osync child exited with error." "CRITICAL"
			exit $retval
		fi

		Logger "#### Monitoring now." "NOTICE"
		inotifywait --exclude $OSYNC_DIR $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE -qq -r -e create -e modify -e delete -e move -e attrib --timeout "$MAX_WAIT" "$INITIATOR_SYNC_DIR" &
		OSYNC_SUB_PID=$!
		wait $OSYNC_SUB_PID
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

stats=0
PARTIAL=0
FORCE_UNLOCK=0
no_maxtime=0
# Alert flags
opts=""
soft_alert_total=0
ERROR_ALERT=0
soft_stop=0
_QUICK_SYNC=0
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
		_QUICK_SYNC=$(($_QUICK_SYNC + 1))
		no_maxtime=1
		INITIATOR_SYNC_DIR=${i##*=}
		opts=$opts" --initiator=\"$INITIATOR_SYNC_DIR\""
		;;
		--target=*)
		_QUICK_SYNC=$(($_QUICK_SYNC + 1))
		TARGET_SYNC_DIR=${i##*=}
		opts=$opts" --target=\"$TARGET_SYNC_DIR\""
		no_maxtime=1
		;;
		--rsakey=*)
		SSH_RSA_PRIVATE_KEY=${i##*=}
		opts=$opts" --rsakey=\"$SSH_RSA_PRIVATE_KEY\""
		;;
		--instance-id=*)
		INSTANCE_ID=${i##*=}
		opts=$opts" --instance-id=\"$INSTANCE_ID\""
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

	## Here we set default options for quicksync tasks when no configuration file is provided.

	if [ $_QUICK_SYNC -eq 2 ]; then
		if [ "$INSTANCE_ID" == "" ]; then
			INSTANCE_ID="quicksync_task"
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
		REMOTE_OPERATION=no
	else
		ConfigFile="${1}"
		LoadConfigFile "$ConfigFile"
	fi

	if [ "$LOGFILE" == "" ]; then
		if [ -w /var/log ]; then
			LOG_FILE=/var/log/$PROGRAM_$INSTANCE_ID.log
		else
			LOG_FILE=./$PROGRAM_$INSTANCE_ID.log
		fi
	else
		LOG_FILE="$LOGFILE"
	fi

	if [ "$IS_STABLE" != "yes" ]; then
		Logger "This is an unstable dev build. Please use with caution." "WARN"
	fi

	GetLocalOS
	InitLocalOSSettings
	PreInit
	Init
	PostInit
	CheckCurrentConfig
	GetRemoteOS
	InitRemoteOSSettings

	if [ $sync_on_changes -eq 1 ]; then
		SyncOnChanges
	else
		DATE=$(date)
		Logger "-------------------------------------------------------------" "NOTICE"
		Logger "$DRY_WARNING $DATE - $PROGRAM $PROGRAM_VERSION script begin." "NOTICE"
		Logger "-------------------------------------------------------------" "NOTICE"
		Logger "Sync task [$INSTANCE_ID] launched as $LOCAL_USER@$LOCAL_HOST (PID $SCRIPT_PID)" "NOTICE"
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
