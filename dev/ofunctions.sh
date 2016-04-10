## FUNC_BUILD=2016041001
## BEGIN Generic functions for osync & obackup written in 2013-2016 by Orsiris de Jong - http://www.netpower.fr - ozy@netpower.fr

## type -p does not work on platforms other than linux (bash). If if does not work, always assume output is not a zero exitcode
if ! type "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

#### obackup & osync specific code BEGIN ####

## Log a state message every $KEEP_LOGGING seconds. Should not be equal to soft or hard execution time so your log will not be unnecessary big.
KEEP_LOGGING=1801

## Correct output of sort command (language agnostic sorting)
export LC_ALL=C

# Standard alert mail body
MAIL_ALERT_MSG="Execution of $PROGRAM instance $INSTANCE_ID on $(date) has warnings/errors."

#### obackup & osync specific code END ####

#### MINIMAL-FUNCTION-SET BEGIN ####

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
elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
	LOG_FILE="$HOME/$PROGRAM.log"
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


# Default alert attachment filename
ALERT_LOG_FILE="$RUN_DIR/$PROGRAM.last.log"

# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace


function Dummy {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG
	sleep .1
}

function _Logger {
	local svalue="${1}" # What to log to stdout
	local lvalue="${2:-$svalue}" # What to log to logfile, defaults to screen value
	local evalue="${3}" # What to log to stderr
	echo -e "$lvalue" >> "$LOG_FILE"

	# <OSYNC SPECIFIC> Special case in daemon mode where systemctl doesn't need double timestamps
	if [ "$sync_on_changes" == "1" ]; then
		cat <<< "$evalue" 1>&2	# Log to stderr in daemon mode
	elif [ $_SILENT -eq 0 ]; then
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
		_Logger "$prefix\e[41m$value\e[0m" "$prefix$level:$value" "$level:$value"
		ERROR_ALERT=1
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix\e[91m$value\e[0m" "$prefix$level:$value" "$level:$value"
		ERROR_ALERT=1
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix\e[93m$value\e[0m" "$prefix$level:$value" "$level:$value"
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

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}"
	local self="${2:-false}"

	if children="$(pgrep -P "$pid")"; then
		for child in $children; do
			Logger "Launching KillChilds \"$child\" true" "DEBUG"
			KillChilds "$child" true
		done
	fi

	# Try to kill nicely, if not, wait 15 seconds to let Trap actions happen before killing
	if [ "$self" == true ]; then
		Logger "Killing process $pid" "DEBUG"
		kill -s SIGTERM "$pid"
		if [ $? != 0 ]; then
			sleep 15 && kill -9 "$pid" &
			return 1
		else
			return 0
		fi
	fi
	# sleep 15 needs to wait before killing itself
}

function SendAlert {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local mail_no_attachment=
	local attachment_command=
	local subject=

	if [ "$DESTINATION_MAILS" == "" ]; then
		return 0
	fi

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
	if [ $? != 0 ]; then
		Logger "Cannot create [$ALERT_LOG_FILE]" "WARN"
		mail_no_attachment=1
	else
		mail_no_attachment=0
	fi
	MAIL_ALERT_MSG="$MAIL_ALERT_MSG"$'\n\n'$(tail -n 50 "$LOG_FILE")
	if [ $ERROR_ALERT -eq 1 ]; then
		subject="Error alert for $INSTANCE_ID"
	elif [ $WARN_ALERT -eq 1 ]; then
		subject="Warning alert for $INSTANCE_ID"
	else
		subject="Alert for $INSTANCE_ID"
	fi

	if [ "$mail_no_attachment" -eq 0 ]; then
		attachment_command="-a $ALERT_LOG_FILE"
	fi
	if type mutt > /dev/null 2>&1 ; then
		echo "$MAIL_ALERT_MSG" | $(type -p mutt) -x -s "$subject" $DESTINATION_MAILS $attachment_command
		if [ $? != 0 ]; then
			Logger "Cannot send alert email via $(type -p mutt) !!!" "WARN"
		else
			Logger "Sent alert mail using mutt." "NOTICE"
			return 0
		fi
	fi

	if type mail > /dev/null 2>&1 ; then
		if [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V | grep "GNU" > /dev/null; then
			attachment_command="-A $ALERT_LOG_FILE"
		elif [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V > /dev/null; then
			attachment_command="-a$ALERT_LOG_FILE"
		else
			attachment_command=""
		fi
		echo "$MAIL_ALERT_MSG" | $(type -p mail) $attachment_command -s "$subject" $DESTINATION_MAILS
		if [ $? != 0 ]; then
			Logger "Cannot send alert email via $(type -p mail) with attachments !!!" "WARN"
			echo "$MAIL_ALERT_MSG" | $(type -p mail) -s "$subject" $DESTINATION_MAILS
			if [ $? != 0 ]; then
				Logger "Cannot send alert email via $(type -p mail) without attachments !!!" "WARN"
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
		echo -e "Subject:$subject\r\n$MAIL_ALERT_MSG" | $(type -p sendmail) $DESTINATION_MAILS
		if [ $? != 0 ]; then
			Logger "Cannot send alert email via $(type -p sendmail) !!!" "WARN"
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
			Logger "Cannot send alert email via $(type -p sendemail) !!!" "WARN"
		else
			Logger "Sent alert mail using sendemail command without attachment." "NOTICE"
			return 0
		fi
	fi

	# pfSense specific
	if [ -f /usr/local/bin/mail.php ]; then
		echo "$MAIL_ALERT_MSG" | /usr/local/bin/mail.php -s="$subject"
		if [ $? != 0 ]; then
			Logger "Cannot send alert email via /usr/local/bin/mail.php (pfsense) !!!" "WARN"
		else
			Logger "Sent alert mail using pfSense mail.php." "NOTICE"
			return 0
		fi
	fi

	# If function has not returned 0 yet, assume it's critical that no alert can be sent
	Logger "Cannot send alert (neither mutt, mail, sendmail, sendemail or pfSense mail.php could be used)." "ERROR" # Is not marked critical because execution must continue

	# Delete tmp log file
	if [ -f "$ALERT_LOG_FILE" ]; then
		rm "$ALERT_LOG_FILE"
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

function LoadConfigFile {
	local config_file="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG


	if [ ! -f "$config_file" ]; then
		Logger "Cannot load configuration file [$config_file]. Cannot start." "CRITICAL"
		exit 1
	elif [[ "$1" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$config_file]. Cannot start." "CRITICAL"
		exit 1
	else
		grep '^[^ ]*=[^;&]*' "$config_file" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" # WITHOUT COMMENTS
		# Shellcheck source=./sync.conf
		source "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
	fi

	CONFIG_FILE="$config_file"
}

#### MINIMAL-FUNCTION-SET END ####

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
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$_DEBUG" != "yes" ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID"
	fi
}

function GetLocalOS {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local local_os_var=

	local_os_var="$(uname -spio 2>&1)"
	if [ $? != 0 ]; then
		local_os_var="$(uname -v 2>&1)"
		if [ $? != 0 ]; then
			local_os_var="$(uname)"
		fi
	fi

	case $local_os_var in
		*"Linux"*)
		LOCAL_OS="Linux"
		;;
		*"BSD"*)
		LOCAL_OS="BSD"
		;;
		*"MINGW32"*|*"CYGWIN"*)
		LOCAL_OS="msys"
		;;
		*"Darwin"*)
		LOCAL_OS="MacOSX"
		;;
		*)
		if [ "$IGNORE_OS_TYPE" == "yes" ]; then		#DOC: Undocumented option
			Logger "Running on unknown local OS [$local_os_var]." "WARN"
			return
		fi
		Logger "Running on >> $local_os_var << not supported. Please report to the author." "ERROR"
		exit 1
		;;
	esac
	Logger "Local OS: [$local_os_var]." "DEBUG"
}

function GetRemoteOS {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local cmd=
	local remote_os_var=


	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		cmd=$SSH_CMD' "uname -spio" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd" &
		WaitForTaskCompletion $! 120 240 ${FUNCNAME[0]}"-1"
		retval=$?
		if [ $retval != 0 ]; then
			cmd=$SSH_CMD' "uname -v" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
			Logger "cmd: $cmd" "DEBUG"
			eval "$cmd" &
			WaitForTaskCompletion $! 120 240 ${FUNCNAME[0]}"-2"
			retval=$?
			if [ $retval != 0 ]; then
				cmd=$SSH_CMD' "uname" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
				Logger "cmd: $cmd" "DEBUG"
				eval "$cmd" &
				WaitForTaskCompletion $! 120 240 ${FUNCNAME[0]}"-3"
				retval=$?
				if [ $retval != 0 ]; then
					Logger "Cannot Get remote OS type." "ERROR"
				fi
			fi
		fi

		remote_os_var=$(cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID")

		case $remote_os_var in
			*"Linux"*)
			REMOTE_OS="Linux"
			;;
			*"BSD"*)
			REMOTE_OS="BSD"
			;;
			*"MINGW32"*|*"CYGWIN"*)
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
			if [ "$IGNORE_OS_TYPE" == "yes" ]; then		#DOC: Undocumented option
				Logger "Running on unknown remote OS [$remote_os_var]." "WARN"
				return
			fi
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
	Logger "${FUNCNAME[0]} called by [$caller_name]." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	__CheckArguments 4 $# ${FUNCNAME[0]} "$@"				#__WITH_PARANOIA_DEBUG

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
				Logger "Current task still running with pid [$pid]." "NOTICE"
			fi
		fi
		if [ $exec_time -gt $soft_max_time ]; then
			if [ $soft_alert -eq 0 ] && [ $soft_max_time -ne 0 ]; then
				Logger "Max soft execution time exceeded for task [$caller_name] with pid [$pid]." "WARN"
				soft_alert=1
				SendAlert

			fi
			if [ $exec_time -gt $hard_max_time ] && [ $hard_max_time -ne 0 ]; then
				Logger "Max hard execution time exceeded for task [$caller_name] with pid [$pid]. Stopping task execution." "ERROR"
				KillChilds $pid
				if [ $? == 0 ]; then
					Logger "Task stopped successfully" "NOTICE"
					return 0
				else
					return 1
				fi
			fi
		fi
		sleep $SLEEP_TIME
	done
	wait $pid
	local retval=$?
	Logger "${FUNCNAME[0]} ended for [$caller_name] with status $retval." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	return $retval
}

function WaitForCompletion {
	local pid="${1}" # pid to wait for
	local soft_max_time="${2}" # If program with pid $pid takes longer than $soft_max_time seconds, will log a warning, unless $soft_max_time equals 0.
	local hard_max_time="${3}" # If program with pid $pid takes longer than $hard_max_time seconds, will stop execution, unless $hard_max_time equals 0.
	local caller_name="${4}" # Who called this function
	Logger "${FUNCNAME[0]} called by [$caller_name]" "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	__CheckArguments 4 $# ${FUNCNAME[0]} "$@"				#__WITH_PARANOIA_DEBUG

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
				Logger "Max hard execution time exceeded for script in [$caller_name]. Stopping current task execution." "ERROR"
				KillChilds $pid
				if [ $? == 0 ]; then
					Logger "Task stopped successfully" "NOTICE"
					return 0
				else
					return 1
				fi
			fi
		fi
		sleep $SLEEP_TIME
	done
	wait $pid
	retval=$?
	Logger "${FUNCNAME[0]} ended for [$caller_name] with status $retval." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	return $retval
}

function RunLocalCommand {
	local command="${1}" # Command to run
	local hard_max_time="${2}" # Max time to wait for command to compleet
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ $_DRYRUN -ne 0 ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on local host." "NOTICE"
	eval "$command" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1 &
	WaitForTaskCompletion $! 0 $hard_max_time ${FUNCNAME[0]}
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ $_VERBOSE -eq 1 ] || [ $retval -ne 0 ]; then
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
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
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	if [ $_DRYRUN -ne 0 ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on remote host." "NOTICE"
	cmd=$SSH_CMD' "$command" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 0 $hard_max_time ${FUNCNAME[0]}
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ] && ([ $_VERBOSE -eq 1 ] || [ $retval -ne 0 ])
	then
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	fi

	if [ "$STOP_ON_CMD_ERROR" == "yes" ] && [ $retval -ne 0 ]; then
		Logger "Stopping on command execution error." "CRITICAL"
		exit 1
	fi
}

function RunBeforeHook {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$LOCAL_RUN_BEFORE_CMD" != "" ]; then
		RunLocalCommand "$LOCAL_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE
	fi

	if [ "$REMOTE_RUN_BEFORE_CMD" != "" ]; then
		RunRemoteCommand "$REMOTE_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE
	fi
}

function RunAfterHook {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$LOCAL_RUN_AFTER_CMD" != "" ]; then
		RunLocalCommand "$LOCAL_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER
	fi

	if [ "$REMOTE_RUN_AFTER_CMD" != "" ]; then
		RunRemoteCommand "$REMOTE_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER
	fi
}

function CheckConnectivityRemoteHost {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug

		if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_OPERATION" != "no" ]; then
			eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1" &
			WaitForTaskCompletion $! 180 180 ${FUNCNAME[0]}
			if [ $? != 0 ]; then
				Logger "Cannot ping $REMOTE_HOST" "ERROR"
				return 1
			fi
		fi
	fi
}

function CheckConnectivity3rdPartyHosts {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug

		if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]; then
			remote_3rd_party_success=0
			OLD_IFS=$IFS
			IFS=$' \t\n'
			for i in $REMOTE_3RD_PARTY_HOSTS
			do
				eval "$PING_CMD $i > /dev/null 2>&1" &
				WaitForTaskCompletion $! 360 360 ${FUNCNAME[0]}
				if [ $? != 0 ]; then
					Logger "Cannot ping 3rd party host $i" "NOTICE"
				else
					remote_3rd_party_success=1
				fi
			done
			IFS=$OLD_IFS
			if [ $remote_3rd_party_success -ne 1 ]; then
				Logger "No remote 3rd party host responded to ping. No internet ?" "ERROR"
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
                        Logger "Function $function_name may have inconsistent number of arguments. Expected: $number_of_arguments, count: $counted_arguments, bash seen: $number_of_given_arguments. see log file." "ERROR"
                        Logger "Arguments passed: $arg_list" "ERROR"
                fi
	fi
}

#__END_WITH_PARANOIA_DEBUG

function RsyncPatternsAdd {
	local pattern_type="${1}"	# exclude or include
	local pattern="${2}"
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local rest=

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
        local pattern_type="${1}"
        local pattern_from="${2}"
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local pattern_from=

        ## Check if the exclude list has a full path, and if not, add the config file path if there is one
        if [ "$(basename $pattern_from)" == "$pattern_from" ]; then
                pattern_from="$(dirname $CONFIG_FILE)/$pattern_from"
        fi

        if [ -e "$pattern_from" ]; then
                RSYNC_PATTERNS="$RSYNC_PATTERNS --"$pattern_type"-from=\"$pattern_from\""
        fi
}

function RsyncPatterns {
        __CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

        if [ "$RSYNC_PATTERN_FIRST" == "exclude" ]; then
                RsyncPatternsAdd "exclude" "$RSYNC_EXCLUDE_PATTERN"
                if [ "$RSYNC_EXCLUDE_FROM" != "" ]; then
                        RsyncPatternsFromAdd "exclude" "$RSYNC_EXCLUDE_FROM"
                fi
                RsyncPatternsAdd "$RSYNC_INCLUDE_PATTERN" "include"
                if [ "$RSYNC_INCLUDE_FROM" != "" ]; then
                        RsyncPatternsFromAdd "include" "$RSYNC_INCLUDE_FROM"
                fi
        elif [ "$RSYNC_PATTERN_FIRST" == "include" ]; then
                RsyncPatternsAdd "include" "$RSYNC_INCLUDE_PATTERN"
                if [ "$RSYNC_INCLUDE_FROM" != "" ]; then
                        RsyncPatternsFromAdd "include" "$RSYNC_INCLUDE_FROM"
                fi
                RsyncPatternsAdd "exclude" "$RSYNC_EXCLUDE_PATTERN"
                if [ "$RSYNC_EXCLUDE_FROM" != "" ]; then
                        RsyncPatternsFromAdd "exclude" "$RSYNC_EXCLUDE_FROM"
                fi
        else
                Logger "Bogus RSYNC_PATTERN_FIRST value in config file. Will not use rsync patterns." "WARN"
        fi
}

function PreInit {
	 __CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	## SSH compression
        if [ "$SSH_COMPRESSION" != "no" ]; then
                SSH_COMP=-C
        else
                SSH_COMP=
        fi

	## Ignore SSH known host verification
	if [ "$SSH_IGNORE_KNOWN_HOSTS" == "yes" ]; then
		SSH_OPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
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
        RSYNC_ARGS="-rltD"
	RSYNC_ATTR_ARGS="-pgo"
	if [ "$_DRYRUN" -eq 1 ]; then
		RSYNC_DRY_ARG="-n"
                DRY_WARNING="/!\ DRY RUN"
	else
		RSYNC_DRY_ARG=""
	fi

        if [ "$PRESERVE_ACL" == "yes" ]; then
                RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -A"
        fi
        if [ "$PRESERVE_XATTR" == "yes" ]; then
                RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -X"
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
                RSYNC_TYPE_ARGS=$RSYNC_TYPE_ARGS" --checksum"
        fi
        if [ "$BANDWIDTH" != "" ] && [ "$BANDWIDTH" != "0" ]; then
                RSYNC_ARGS=$RSYNC_ARGS" --bwlimit=$BANDWIDTH"
        fi

        if [ "$PARTIAL" == "yes" ]; then
                RSYNC_ARGS=$RSYNC_ARGS" --partial --partial-dir=\"$PARTIAL_DIR\""
                RSYNC_PARTIAL_EXCLUDE="--exclude=\"$PARTIAL_DIR\""
        fi

	if [ "$DELTA_COPIES" != "no" ]; then
                RSYNC_ARGS=$RSYNC_ARGS" --no-whole-file"
        else
            	RSYNC_ARGS=$RSYNC_ARGS" --whole-file"
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
		# obackup specific
                COMPRESSION_OPTIONS=--rsyncable
        elif type gzip > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| gzip -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.gz
		# obackup specific
                COMPRESSION_OPTIONS=--rsyncable
        else
                COMPRESSION_PROGRAM=
                COMPRESSION_EXTENSION=
        fi
        ALERT_LOG_FILE="$ALERT_LOG_FILE$COMPRESSION_EXTENSION"
}

function PostInit {
        __CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	# Define remote commands
        SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $SSH_OPTS $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
        SCP_CMD="$(type -p scp) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY -P $REMOTE_PORT"
        RSYNC_SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $SSH_OPTS -p $REMOTE_PORT"
}

function InitLocalOSSettings {
        __CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

        ## If running under Msys, some commands do not run the same way
        ## Using mingw version of find instead of windows one
        ## Getting running processes is quite different
        ## Ping command is not the same
        if [ "$LOCAL_OS" == "msys" ]; then
                FIND_CMD=$(dirname $BASH)/find
                # PROCESS_TEST_CMD assumes there is a variable $pid
		# Tested on MSYS and cygwin
                PROCESS_TEST_CMD='ps -a | awk "{\$1=\$1}\$1" | awk "{print \$1}" | grep $pid'
                PING_CMD='$SYSTEMROOT\system32\ping -n 2'
        else
                FIND_CMD=find
                # PROCESS_TEST_CMD assumes there is a variable $pid
                PROCESS_TEST_CMD='ps -p$pid'
                PING_CMD="ping -c 2 -i .2"
        fi

        ## Stat command has different syntax on Linux and FreeBSD/MacOSX
        if [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "BSD" ]; then
                STAT_CMD="stat -f \"%Sm\""
		STAT_CTIME_MTIME_CMD="stat -f %N;%c;%m"
        else
                STAT_CMD="stat --format %y"
		STAT_CTIME_MTIME_CMD="stat -c %n;%Z;%Y"
        fi
}

function InitRemoteOSSettings {
        __CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

        ## MacOSX does not use the -E parameter like Linux or BSD does (-E is mapped to extended attrs instead of preserve executability)
        if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ]; then
                RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -E"
        fi

        if [ "$REMOTE_OS" == "msys" ]; then
                REMOTE_FIND_CMD=$(dirname $BASH)/find
        else
                REMOTE_FIND_CMD=find
        fi

        ## Stat command has different syntax on Linux and FreeBSD/MacOSX
        if [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "BSD" ]; then
                REMOTE_STAT_CMD="stat -f \"%Sm\""
		REMOTE_STAT_CTIME_MTIME_CMD="stat -f \\\"%N;%c;%m\\\""
        else
                REMOTE_STAT_CMD="stat --format %y"
		REMOTE_STAT_CTIME_MTIME_CMD="stat -c \\\"%n;%Z;%Y\\\""
        fi

}

## END Generic functions
