#!/usr/bin/env bash

PROGRAM="osync" # Rsync based two way sync engine with fault tolerance
AUTHOR="(C) 2013-2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION=1.2-beta2
PROGRAM_BUILD=2016111502
IS_STABLE=no

# Execution order						#__WITH_PARANOIA_DEBUG
#	Function Name				Is parallel	#__WITH_PARANOIA_DEBUG

#	GetLocalOS				no		#__WITH_PARANOIA_DEBUG
#	InitLocalOSSettings			no		#__WITH_PARANOIA_DEBUG
#	CheckEnvironment			no		#__WITH_PARANOIA_DEBUG
#	PreInit					no		#__WITH_PARANOIA_DEBUG
#	Init					no		#__WITH_PARANOIA_DEBUG
#	PostInit				no		#__WITH_PARANOIA_DEBUG
#	GetRemoteOS				no		#__WITH_PARANOIA_DEBUG
#	InitRemoteOSSettings			no		#__WITH_PARANOIA_DEBUG
#	CheckReplicaPaths			yes		#__WITH_PARANOIA_DEBUG
#	CheckDiskSpace				yes		#__WITH_PARANOIA_DEBUG
#	RunBeforeHook				yes		#__WITH_PARANOIA_DEBUG
#	Main					no		#__WITH_PARANOIA_DEBUG
#		CreateStateDirs			yes		#__WITH_PARANOIA_DEBUG
#	 	CheckLocks			yes		#__WITH_PARANOIA_DEBUG
#	 	WriteLockFiles			yes		#__WITH_PARANOIA_DEBUG
#	 	Sync				no		#__WITH_PARANOIA_DEBUG
#			treeList		yes		#__WITH_PARANOIA_DEBUG
#			treeList		yes		#__WITH_PARANOIA_DEBUG
#			deleteList		yes		#__WITH_PARANOIA_DEBUG
#			deleteList		yes		#__WITH_PARANOIA_DEBUG
#			syncAttrs		no		#__WITH_PARANOIA_DEBUG
#			_getFileCtimeMtime	yes		#__WITH_PARANOIA_DEBUG
#			syncUpdate		no		#__WITH_PARANOIA_DEBUG
#			syncUpdate		no		#__WITH_PARANOIA_DEBUG
#			deletionPropagation	yes		#__WITH_PARANOIA_DEBUG
#			deletionPropagation	yes		#__WITH_PARANOIA_DEBUG
#			treeList		yes		#__WITH_PARANOIA_DEBUG
#			treeList		yes		#__WITH_PARANOIA_DEBUG
#		SoftDelete			yes		#__WITH_PARANOIA_DEBUG
#	RunAfterHook				yes		#__WITH_PARANOIA_DEBUG
#	UnlockReplicas				yes		#__WITH_PARANOIA_DEBUG
#	CleanUp					no		#__WITH_PARANOIA_DEBUG

#### MINIMAL-FUNCTION-SET BEGIN ####

## FUNC_BUILD=2016111503
## BEGIN Generic bash functions written in 2013-2016 by Orsiris de Jong - http://www.netpower.fr - ozy@netpower.fr

## To use in a program, define the following variables:
## PROGRAM=program-name
## INSTANCE_ID=program-instance-name
## _DEBUG=yes/no
## _LOGGER_STDERR=true/false
## _LOGGER_ERR_ONLY=true/false
## _LOGGER_PREFIX="date"/"time"/""

#TODO: Windows checks, check sendmail & mailsend

if ! type "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

## Correct output of sort command (language agnostic sorting)
export LC_ALL=C

# Standard alert mail body
MAIL_ALERT_MSG="Execution of $PROGRAM instance $INSTANCE_ID on $(date) has warnings/errors."

# Environment variables that can be overriden by programs
_DRYRUN=false
_SILENT=false
_VERBOSE=false
_LOGGER_PREFIX="date"
_LOGGER_STDERR=false
if [ "$KEEP_LOGGING" == "" ]; then
        KEEP_LOGGING=1801
fi

# Initial error status, logging 'WARN', 'ERROR' or 'CRITICAL' will enable alerts flags
ERROR_ALERT=false
WARN_ALERT=false

# Log from current run
CURRENT_LOG=""

## allow function call checks			#__WITH_PARANOIA_DEBUG
if [ "$_PARANOIA_DEBUG" == "yes" ];then		#__WITH_PARANOIA_DEBUG
	_DEBUG=yes				#__WITH_PARANOIA_DEBUG
fi						#__WITH_PARANOIA_DEBUG

## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	SLEEP_TIME=.05 # Tested under linux and FreeBSD bash, #TODO tests on cygwin / msys
	_VERBOSE=false
else
	if [ "$SLEEP_TIME" == "" ]; then
		SLEEP_TIME=1
	fi
	trap 'TrapError ${LINENO} $?' ERR
	_VERBOSE=true
fi

SCRIPT_PID=$$

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
ALERT_LOG_FILE="$RUN_DIR/$PROGRAM.$SCRIPT_PID.last.log"

# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace


function Dummy {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	sleep $SLEEP_TIME
}

# Sub function of Logger
function _Logger {
	local svalue="${1}" # What to log to stdout
	local lvalue="${2:-$svalue}" # What to log to logfile, defaults to screen value
	local evalue="${3}" # What to log to stderr

	echo -e "$lvalue" >> "$LOG_FILE"
	CURRENT_LOG="$CURRENT_LOG"$'\n'"$lvalue"

	if [ $_LOGGER_STDERR == true ] && [ "$evalue" != "" ]; then
		cat <<< "$evalue" 1>&2
	elif [ "$_SILENT" == false ]; then
		echo -e "$svalue"
	fi
}

# General log function with log levels:
# CRITICAL, ERROR, WARN are colored in stdout, prefixed in stderr
# NOTICE is standard level
# VERBOSE is only sent to stdout / stderr if _VERBOSE=true
# DEBUG & PARANOIA_DEBUG are only sent if _DEBUG=yes
function Logger {
	local value="${1}" # Sentence to log (in double quotes)
	local level="${2}" # Log level: PARANOIA_DEBUG, DEBUG, VERBOSE, NOTICE, WARN, ERROR, CRITIAL

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="$(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix\e[41m$value\e[0m" "$prefix$level:$value" "$level:$value"
		ERROR_ALERT=true
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "$prefix\e[91m$value\e[0m" "$prefix$level:$value" "$level:$value"
		ERROR_ALERT=true
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "$prefix\e[33m$value\e[0m" "$prefix$level:$value" "$level:$value"
		WARN_ALERT=true
		return
	elif [ "$level" == "NOTICE" ]; then
		if [ "$_LOGGER_ERR_ONLY" != true ]; then
			_Logger "$prefix$value"
		fi
		return
	elif [ "$level" == "VERBOSE" ]; then
		if [ $_VERBOSE == true ]; then
			_Logger "$prefix$value"
		fi
		return
	elif [ "$level" == "ALWAYS" ]; then
		if [ $_SILENT != true ]; then
			_Logger "$prefix$value" "$prefix$level:$value" "$level:$value"
		fi
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
		_Logger "\e[41mLogger function called without proper loglevel [$level].\e[0m"
		_Logger "Value was: $prefix$value"
	fi
}

# QuickLogger subfunction, can be called directly
function _QuickLogger {
	local value="${1}"
	local destination="${2}" # Destination: stdout, log, both

	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if ([ "$destination" == "log" ] || [ "$destination" == "both" ]); then
		echo -e "$(date) - $value" >> "$LOG_FILE"
	elif ([ "$destination" == "stdout" ] || [ "$destination" == "both" ]); then
		echo -e "$value"
	fi
}

# Generic quick logging function
function QuickLogger {
	local value="${1}"

	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ $_SILENT == true ]; then
		_QuickLogger "$value" "log"
	else
		_QuickLogger "$value" "stdout"
	fi
}

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}" # Parent pid to kill childs
	local self="${2:-false}" # Should parent be killed too ?


	if children="$(pgrep -P "$pid")"; then
		for child in $children; do
			Logger "Launching KillChilds \"$child\" true" "DEBUG"	#__WITH_PARANOIA_DEBUG
			KillChilds "$child" true
		done
	fi
		# Try to kill nicely, if not, wait 15 seconds to let Trap actions happen before killing
	if ( [ "$self" == true ] && kill -0 $pid > /dev/null 2>&1); then
		Logger "Sending SIGTERM to process [$pid]." "DEBUG"
		kill -s TERM "$pid"
		if [ $? != 0 ]; then
			sleep 15
			Logger "Sending SIGTERM to process [$pid] failed." "DEBUG"
			kill -9 "$pid"
			if [ $? != 0 ]; then
				Logger "Sending SIGKILL to process [$pid] failed." "DEBUG"
				return 1
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

	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local errorcount=0

	IFS=';' read -a pidsArray <<< "$pids"
	for pid in "${pidsArray[@]}"; do
		KillChilds $pid $self
		if [ $? != 0 ]; then
			errorcount=$((errorcount+1))
			fi
	done
	return $errorcount
}

# osync/obackup/pmocr script specific mail alert function, use SendEmail function for generic mail sending
function SendAlert {
	local runAlert="${1:-false}" # Specifies if current message is sent while running or at the end of a run

	__CheckArguments 0-1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local attachment=
	local attachmentFile=
	local subject=
	local body=

	if [ "$DESTINATION_MAILS" == "" ]; then
		return 0
	fi

	if [ "$_DEBUG" == "yes" ]; then
		Logger "Debug mode, no warning mail will be sent." "NOTICE"
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
		attachment=false
	else
		attachment=true
	fi
	body="$MAIL_ALERT_MSG"$'\n\n'"$CURRENT_LOG"

	if [ $ERROR_ALERT == true ]; then
		subject="Error alert for $INSTANCE_ID"
	elif [ $WARN_ALERT == true ]; then
		subject="Warning alert for $INSTANCE_ID"
	else
		subject="Alert for $INSTANCE_ID"
	fi

	if [ $runAlert == true ]; then
		subject="Currently runing - $subject"
	else
		subject="Fnished run - $subject"
	fi

	if [ "$attachment" == true ]; then
		attachmentFile="$ALERT_LOG_FILE"
	fi

	SendEmail "$subject" "$body" "$DESTINATION_MAILS" "$attachmentFile" "$SENDER_MAIL" "$SMTP_SERVER" "$SMTP_PORT" "$ENCRYPTION" "SMTP_USER" "$SMTP_PASSWORD"

	# Delete tmp log file
	if [ "$attachment" == true ]; then
		if [ -f "$ALERT_LOG_FILE" ]; then
			rm -f "$ALERT_LOG_FILE"
		fi
	fi
}

# Generic email sending function.
# Usage (linux / BSD), attachment is optional, can be "/path/to/my.file" or ""
# SendEmail "subject" "Body text" "receiver@example.com receiver2@otherdomain.com" "/path/to/attachment.file"
# Usage (Windows, make sure you have mailsend.exe in executable path, see http://github.com/muquit/mailsend)
# attachment is optional but must be in windows format like "c:\\some\path\\my.file", or ""
# smtp_server.domain.tld is mandatory, as is smtpPort (should be 25, 465 or 587)
# encryption can be set to tls, ssl or none
# smtpUser and smtpPassword are optional
# SendEmail "subject" "Body text" "receiver@example.com receiver2@otherdomain.com" "/path/to/attachment.file" "senderMail@example.com" "smtpServer.domain.tld" "smtpPort" "encryption" "smtpUser" "smtpPassword"
function SendEmail {
	local subject="${1}"
	local message="${2}"
	local destinationMails="${3}"
	local attachment="${4}"
	local senderMail="${5}"
	local smtpServer="${6}"
	local smtpPort="${7}"
	local encryption="${8}"
	local smtpUser="${9}"
	local smtpPassword="${10}"

	# CheckArguments will report a warning that can be ignored if used in Windows with paranoia debug enabled
	__CheckArguments 4 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local mail_no_attachment=
	local attachment_command=

	local encryption_string=
	local auth_string=

	if [ ! -f "$attachment" ]; then
		attachment_command="-a $attachment"
		mail_no_attachment=1
	else
		mail_no_attachment=0
	fi

	if [ "$LOCAL_OS" == "BUSYBOX" ]; then
		if type sendmail > /dev/null 2>&1; then
			if [ "$ENCRYPTION" == "tls" ]; then
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$SenderMail" -H "exec openssl s_client -quiet -tls1_2 -starttls smtp -connect $smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			elif [ "$ENCRYPTION" == "ssl" ]; then
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$SenderMail" -H "exec openssl s_client -quiet -connect $smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			else
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$SenderMail" -S "$smtpServer:$SmtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			fi

			if [ $? != 0 ]; then
				Logger "Cannot send alert mail via $(type -p sendmail) !!!" "WARN"
				# Don't bother try other mail systems with busybox
				return 1
			else
				return 0
			fi
		else
			Logger "Sendmail not present. Won't send any mail" "WARN"
			return 1
		fi
	fi

	if type mutt > /dev/null 2>&1 ; then
		echo "$message" | $(type -p mutt) -x -s "$subject" "$destinationMails" $attachment_command
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p mutt) !!!" "WARN"
		else
			Logger "Sent mail using mutt." "NOTICE"
			return 0
		fi
	fi

	if type mail > /dev/null 2>&1 ; then
		if [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V | grep "GNU" > /dev/null; then
			attachment_command="-A $attachment"
		elif [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V > /dev/null; then
			attachment_command="-a$attachment"
		else
			attachment_command=""
		fi
		echo "$message" | $(type -p mail) $attachment_command -s "$subject" "$destinationMails"
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p mail) with attachments !!!" "WARN"
			echo "$message" | $(type -p mail) -s "$subject" "$destinationMails"
			if [ $? != 0 ]; then
				Logger "Cannot send mail via $(type -p mail) without attachments !!!" "WARN"
			else
				Logger "Sent mail using mail command without attachment." "NOTICE"
				return 0
			fi
		else
			Logger "Sent mail using mail command." "NOTICE"
			return 0
		fi
	fi

	if type sendmail > /dev/null 2>&1 ; then
		echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) "$destinationMails"
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p sendmail) !!!" "WARN"
		else
			Logger "Sent mail using sendmail command without attachment." "NOTICE"
			return 0
		fi
	fi

	# Windows specific
	if type "mailsend.exe" > /dev/null 2>&1 ; then
		if [ "$senderMail" == "" ]; then
			Logger "Missing sender email." "ERROR"
			return 1
		fi
		if [ "$smtpServer" == "" ]; then
			Logger "Missing smtp port." "ERROR"
			return 1
		fi
		if [ "$smtpPort" == "" ]; then
			Logger "Missing smtp port, assuming 25." "WARN"
			smtpPort=25
		fi
		if [ "$encryption" != "tls" ] && [ "$encryption" != "ssl" ]  && [ "$encryption" != "none" ]; then
			Logger "Bogus smtp encryption, assuming none." "WARN"
			encryption_string=
		elif [ "$encryption" == "tls" ]; then
			encryption_string=-starttls
		elif [ "$encryption" == "ssl" ]:; then
			encryption_string=-ssl
		fi
		if [ "$smtpUser" != "" ] && [ "$smtpPassword" != "" ]; then
			auth_string="-auth -user \"$smtpUser\" -pass \"$smtpPassword\""
		fi
		$(type mailsend.exe) -f "$senderMail" -t "$destinationMails" -sub "$subject" -M "$message" -attach "$attachment" -smtp "$smtpServer" -port "$smtpPort" $encryption_string $auth_string
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type mailsend.exe) !!!" "WARN"
		else
			Logger "Sent mail using mailsend.exe command with attachment." "NOTICE"
			return 0
		fi
	fi

	# pfSense specific
	if [ -f /usr/local/bin/mail.php ]; then
		echo "$message" | /usr/local/bin/mail.php -s="$subject"
		if [ $? != 0 ]; then
			Logger "Cannot send mail via /usr/local/bin/mail.php (pfsense) !!!" "WARN"
		else
			Logger "Sent mail using pfSense mail.php." "NOTICE"
			return 0
		fi
	fi

	# If function has not returned 0 yet, assume it is critical that no alert can be sent
	Logger "Cannot send mail (neither mutt, mail, sendmail, sendemail, mailsend (windows) or pfSense mail.php could be used)." "ERROR" # Is not marked critical because execution must continue
}

function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_SILENT == false ]; then
		echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m"
	fi
}

function LoadConfigFile {
	local configFile="${1}"

	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG


	if [ ! -f "$configFile" ]; then
		Logger "Cannot load configuration file [$configFile]. Cannot start." "CRITICAL"
		exit 1
	elif [[ "$configFile" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$configFile]. Cannot start." "CRITICAL"
		exit 1
	else
		# Remove everything that is not a variable assignation
		grep '^[^ ]*=[^;&]*' "$configFile" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
		source "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
	fi

	CONFIG_FILE="$configFile"
}

function Spinner {
	if [ $_SILENT == true ] || [ "$_LOGGER_ERR_ONLY" == true ]; then
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

# Array to string converter, see http://stackoverflow.com/questions/1527049/bash-join-elements-of-an-array
# usage: joinString separaratorChar Array
function joinString {
	local IFS="$1"; shift; echo "$*";
}

# Time control function for background processes, suitable for multiple synchronous processes
# Fills a global variable called WAIT_FOR_TASK_COMPLETION that contains list of failed pids in format pid1:result1;pid2:result2
# Warning: Don't imbricate this function into another run if you plan to use the global variable output

function WaitForTaskCompletion {
	local pids="${1}" # pids to wait for, separated by semi-colon
	local softMaxTime="${2}" # If program with pid $pid takes longer than $softMaxTime seconds, will log a warning, unless $softMaxTime equals 0.
	local hardMaxTime="${3}" # If program with pid $pid takes longer than $hardMaxTime seconds, will stop execution, unless $hardMaxTime equals 0.
	local callerName="${4}" # Who called this function
	local counting="${5:-true}" # Count time since function has been launched if true, since script has been launched if false
	local keepLogging="${6:-0}" # Log a standby message every X seconds. Set to zero to disable logging

	Logger "${FUNCNAME[0]} called by [$callerName]." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	__CheckArguments 6 $# ${FUNCNAME[0]} "$@"				#__WITH_PARANOIA_DEBUG

	local soft_alert=false # Does a soft alert need to be triggered, if yes, send an alert once
	local log_ttime=0 # local time instance for comparaison

	local seconds_begin=$SECONDS # Seconds since the beginning of the script
	local exec_time=0 # Seconds since the beginning of this function

	local retval=0 # return value of monitored pid process
	local errorcount=0 # Number of pids that finished with errors

	local pid	# Current pid working on
	local pidCount # number of given pids
	local pidState # State of the process

	local pidsArray # Array of currently running pids
	local newPidsArray # New array of currently running pids

	local hasPids=false # Are any valable pids given to function ?		#__WITH_PARANOIA_DEBUG

	IFS=';' read -a pidsArray <<< "$pids"
	pidCount=${#pidsArray[@]}

	WAIT_FOR_TASK_COMPLETION=""

	while [ ${#pidsArray[@]} -gt 0 ]; do
		newPidsArray=()

		Spinner
		if [ $counting == true ]; then
			exec_time=$(($SECONDS - $seconds_begin))
		else
			exec_time=$SECONDS
		fi

		if [ $keepLogging -ne 0 ]; then
			if [ $((($exec_time + 1) % $keepLogging)) -eq 0 ]; then
				if [ $log_ttime -ne $exec_time ]; then # Fix when sleep time lower than 1s
					log_ttime=$exec_time
					Logger "Current tasks still running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
				fi
			fi
		fi

		if [ $exec_time -gt $softMaxTime ]; then
			if [ $soft_alert == true ] && [ $softMaxTime -ne 0 ]; then
				Logger "Max soft execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]." "WARN"
				soft_alert=true
				SendAlert true

			fi
			if [ $exec_time -gt $hardMaxTime ] && [ $hardMaxTime -ne 0 ]; then
				Logger "Max hard execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]. Stopping task execution." "ERROR"
				for pid in "${pidsArray[@]}"; do
					KillChilds $pid true
					if [ $? == 0 ]; then
						Logger "Task with pid [$pid] stopped successfully." "NOTICE"
					else
						Logger "Could not stop task with pid [$pid]." "ERROR"
					fi
				done
				SendAlert true
			fi
		fi

		for pid in "${pidsArray[@]}"; do
			if [ $(IsInteger $pid) -eq 1 ]; then
				if kill -0 $pid > /dev/null 2>&1; then
					# Handle uninterruptible sleep state or zombies by ommiting them from running process array (How to kill that is already dead ? :)
					#TODO(high): have this tested on *BSD, Mac, Win & busybox.
					#TODO(high): propagate changes to ParallelExec
					#pidState=$(ps -p$pid -o state= 2 > /dev/null)
					pidState="$(eval $PROCESS_STATE_CMD)"
					if [ "$pidState" != "D" ] && [ "$pidState" != "Z" ]; then
						newPidsArray+=($pid)
					fi
				else
					# pid is dead, get it's exit code from wait command
					wait $pid
					retval=$?
					if [ $retval -ne 0 ]; then
						errorcount=$((errorcount+1))
						Logger "${FUNCNAME[0]} called by [$callerName] finished monitoring [$pid] with exitcode [$retval]." "DEBUG"
						if [ "$WAIT_FOR_TASK_COMPLETION" == "" ]; then
							WAIT_FOR_TASK_COMPLETION="$pid:$retval"
						else
							WAIT_FOR_TASK_COMPLETION=";$pid:$retval"
						fi
					fi
				fi
				hasPids=true					##__WITH_PARANOIA_DEBUG
			fi
		done

		if [ $hasPids == false ]; then					##__WITH_PARANOIA_DEBUG
			Logger "No valable pids given." "ERROR" 		##__WITH_PARANOIA_DEBUG
		fi								##__WITH_PARANOIA_DEBUG

		pidsArray=("${newPidsArray[@]}")
		# Trivial wait time for bash to not eat up all CPU
		sleep $SLEEP_TIME
	done

	Logger "${FUNCNAME[0]} ended for [$callerName] using [$pidCount] subprocesses with [$errorcount] errors." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG

	# Return exit code if only one process was monitored, else return number of errors
	if [ $pidCount -eq 1 ] && [ $errorcount -eq 0 ]; then
		return $errorcount
	else
		return $errorcount
	fi
}

# Take a list of commands to run, runs them sequentially with numberOfProcesses commands simultaneously runs
# Returns the number of non zero exit codes from commands
# Use cmd1;cmd2;cmd3 syntax for small sets, use file for large command sets
function ParallelExec {
	local numberOfProcesses="${1}" # Number of simultaneous commands to run
	local commandsArg="${2}" # Semi-colon separated list of commands, or file containing one command per line
	local readFromFile="${3:-false}" # Is commandsArg a file or a string ?
	local softMaxTime="${4:-0}"
	local hardMaxTime="${5:-0}"
	local callerName="${6}" # Who called this function
	local counting="${7:-true}" # Count time since function has been launched if true, since script has been launched if false
	local keepLogging="${8:-0}" # Log a standby message every X seconds. Set to zero to disable logging

	__CheckArguments 8 $# ${FUNCNAME[0]} "$@"				#__WITH_PARANOIA_DEBUG

	local commandCount
	local command
	local pid
	local counter=0
	local commandsArray
	local pidsArray
	local newPidsArray
	local retval
	local errorCount=0
	local pidState
	local commandsArrayPid

	local hasPids=false # Are any valable pids given to function ?		#__WITH_PARANOIA_DEBUG

	if [ $readFromFile == true ];then
		if [ -f "$commandsArg" ]; then
			commandCount=$(wc -l < "$commandsArg")
		else
			commandCount=0
		fi
	else
		IFS=';' read -r -a commandsArray <<< "$commandsArg"
		commandCount=${#commandsArray[@]}
	fi

	Logger "Runnning $commandCount commands in $numberOfProcesses simultaneous processes." "DEBUG"

	while [ $counter -lt "$commandCount" ] || [ ${#pidsArray[@]} -gt 0 ]; do

		while [ $counter -lt "$commandCount" ] && [ ${#pidsArray[@]} -lt $numberOfProcesses ]; do
			if [ $readFromFile == true ]; then
				#TODO: Checked on FreeBSD 10, also check on Win
				command=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$commandsArg")
			else
				command="${commandsArray[$counter]}"
			fi
			Logger "Running command [$command]." "DEBUG"
			eval "$command" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1 &
			pid=$!
			pidsArray+=($pid)
			commandsArrayPid[$pid]="$command"
			counter=$((counter+1))
		done


		newPidsArray=()
		for pid in "${pidsArray[@]}"; do
			if [ $(IsInteger $pid) -eq 1 ]; then
				# Handle uninterruptible sleep state or zombies by ommiting them from running process array (How to kill that is already dead ? :)
				if kill -0 $pid > /dev/null 2>&1; then
					#pidState=$(ps -p$pid -o state= 2 > /dev/null)
					pidState="$(eval $PROCESS_STATE_CMD)"
					if [ "$pidState" != "D" ] && [ "$pidState" != "Z" ]; then
						newPidsArray+=($pid)
					fi
				else
					# pid is dead, get it's exit code from wait command
					wait $pid
					retval=$?
					if [ $retval -ne 0 ]; then
						Logger "Command [${commandsArrayPid[$pid]}] failed with exit code [$retval]." "ERROR"
						errorCount=$((errorCount+1))
					fi
				fi
				hasPids=true					##__WITH_PARANOIA_DEBUG
			fi
		done

		if [ $hasPids == false ]; then					##__WITH_PARANOIA_DEBUG
			Logger "No valable pids given." "ERROR"			##__WITH_PARANOIA_DEBUG
		fi								##__WITH_PARANOIA_DEBUG
		pidsArray=("${newPidsArray[@]}")

		# Trivial wait time for bash to not eat up all CPU
		sleep $SLEEP_TIME
	done

	return $errorCount
}

function CleanUp {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$_DEBUG" != "yes" ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.tmp"
	fi
}

# obsolete, use StripQuotes
function SedStripQuotes {
	echo $(echo $1 | sed "s/^\([\"']\)\(.*\)\1\$/\2/g")
}

# Usage: var=$(StripSingleQuotes "$var")
function StripSingleQuotes {
	local string="${1}"

	string="${string/#\'/}" # Remove singlequote if it begins string
	string="${string/%\'/}" # Remove singlequote if it ends string
	echo "$string"
}

# Usage: var=$(StripDoubleQuotes "$var")
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

# Usage var=$(EscapeSpaces "$var") or var="$(EscapeSpaces "$var")"
function EscapeSpaces {
	local string="${1}" # String on which spaces will be escaped

	echo "${string// /\\ }"
}

function IsNumericExpand {
	eval "local value=\"${1}\"" # Needed eval so variable variables can be processed

	local re="^-?[0-9]+([.][0-9]+)?$"

	if [[ $value =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
		echo 1
	else
		echo 0
	fi
}

# Usage [ $(IsNumeric $var) -eq 1 ]
function IsNumeric {
	local value="${1}"

	if [[ $value =~ ^[0-9]+([.][0-9]+)?$ ]]; then
		echo 1
	else
		echo 0
	fi
}

function IsInteger {
	local value="${1}"

	if [[ $value =~ ^[0-9]+$ ]]; then
		echo 1
	else
		echo 0
	fi
}

# Converts human readable sizes into integer kilobyte sizes
# Usage numericSize="$(HumanToNumeric $humanSize)"
function HumanToNumeric {
	local value="${1}"

	local notation
	local suffix
	local suffixPresent
	local multiplier

	notation=(K M G T P E)
	for suffix in "${notation[@]}"; do
		multiplier=$((multiplier+1))
		if [[ "$value" == *"$suffix"* ]]; then
			suffixPresent=$suffix
			break;
		fi
	done

	if [ "$suffixPresent" != "" ]; then
		value=${value%$suffix*}
		value=${value%.*}
		# /1024 since we convert to kilobytes instead of bytes
		value=$((value*(1024**multiplier/1024)))
	else
		value=${value%.*}
	fi

	echo $value
}

## from https://gist.github.com/cdown/1163649
function urlEncode {
	local length="${#1}"

	local LANG=C
	for (( i = 0; i < length; i++ )); do
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

function urlDecode {
	local urlEncoded="${1//+/ }"

	printf '%b' "${urlEncoded//%/\\x}"
}

## Modified version of http://stackoverflow.com/a/8574392
## Usage: arrayContains "needle" "${haystack[@]}"
arrayContains () {
	local e

	if [ "$2" == "" ]; then
		echo 0 && return 0
	fi

	for e in "${@:2}"; do
		[[ "$e" == "$1" ]] && echo 1 && return 1
	done
	echo 0 && return 0
}

function GetLocalOS {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local localOsVar

	# There's no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	else
		localOsVar="$(uname -spio 2>&1)"
		if [ $? != 0 ]; then
			localOsVar="$(uname -v 2>&1)"
			if [ $? != 0 ]; then
				localOsVar="$(uname)"
			fi
		fi
	fi

	case $localOsVar in
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
		*"BusyBox"*)
		LOCAL_OS="BUSYBOX"
		;;
		*)
		if [ "$IGNORE_OS_TYPE" == "yes" ]; then		#TODO(doc): Undocumented option
			Logger "Running on unknown local OS [$localOsVar]." "WARN"
			return
		fi
		Logger "Running on >> $localOsVar << not supported. Please report to the author." "ERROR"
		exit 1
		;;
	esac
	Logger "Local OS: [$localOsVar]." "DEBUG"
}

#### MINIMAL-FUNCTION-SET END ####

function GetRemoteOS {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local remoteOsVar

$SSH_CMD bash -s << 'ENDSSH' >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1

function GetOs {
	local localOsVar

	# There's no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	else
		localOsVar="$(uname -spio 2>&1)"
		if [ $? != 0 ]; then
			localOsVar="$(uname -v 2>&1)"
			if [ $? != 0 ]; then
				localOsVar="$(uname)"
			fi
		fi
	fi

	echo "$localOsVar"
}

GetOs

ENDSSH

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
		remoteOsVar=$(cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID")
		case $remoteOsVar in
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
			*"BusyBox"*)
			REMOTE_OS="BUSYBOX"
			;;
			*"ssh"*|*"SSH"*)
			Logger "Cannot connect to remote system." "CRITICAL"
			exit 1
			;;
			*)
			if [ "$IGNORE_OS_TYPE" == "yes" ]; then		#DOC: Undocumented debug only setting
				Logger "Running on unknown remote OS [$remoteOsVar]." "WARN"
				return
			fi
			Logger "Running on remote OS failed. Please report to the author if the OS is not supported." "CRITICAL"
			Logger "Remote OS said:\n$remoteOsVar" "CRITICAL"
			exit 1
		esac
		Logger "Remote OS: [$remoteOsVar]." "DEBUG"
	else
		Logger "Cannot get Remote OS" "CRITICAL"
	fi
}

function RunLocalCommand {
	local command="${1}" # Command to run
	local hardMaxTime="${2}" # Max time to wait for command to compleet
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ $_DRYRUN == true ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on local host." "NOTICE"
	eval "$command" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1 &
	WaitForTaskCompletion $! 0 $hardMaxTime ${FUNCNAME[0]} true $KEEP_LOGGING
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ $_VERBOSE == true ] || [ $retval -ne 0 ]; then
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
	local hardMaxTime="${2}" # Max time to wait for command to compleet
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	if [ $_DRYRUN == true ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on remote host." "NOTICE"
	cmd=$SSH_CMD' "$command" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 0 $hardMaxTime ${FUNCNAME[0]} true $KEEP_LOGGING
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ] && ([ $_VERBOSE == true ] || [ $retval -ne 0 ])
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

	local pids

	if [ "$LOCAL_RUN_BEFORE_CMD" != "" ]; then
		RunLocalCommand "$LOCAL_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE &
		pids="$!"
	fi

	if [ "$REMOTE_RUN_BEFORE_CMD" != "" ]; then
		RunRemoteCommand "$REMOTE_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE &
		pids="$pids;$!"
	fi
	if [ "$pids" != "" ]; then
		WaitForTaskCompletion $pids 0 0 ${FUNCNAME[0]} true $KEEP_LOGGING
	fi
}

function RunAfterHook {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	if [ "$LOCAL_RUN_AFTER_CMD" != "" ]; then
		RunLocalCommand "$LOCAL_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER &
		pids="$!"
	fi

	if [ "$REMOTE_RUN_AFTER_CMD" != "" ]; then
		RunRemoteCommand "$REMOTE_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER &
		pids="$pids;$!"
	fi
	if [ "$pids" != "" ]; then
		WaitForTaskCompletion $pids 0 0 ${FUNCNAME[0]} true $KEEP_LOGGING
	fi
}

function CheckConnectivityRemoteHost {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug

		if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_OPERATION" != "no" ]; then
			eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1" &
			WaitForTaskCompletion $! 60 180 ${FUNCNAME[0]} true $KEEP_LOGGING
			retval=$?
			if [ $retval != 0 ]; then
				Logger "Cannot ping [$REMOTE_HOST]. Return code [$retval]." "WARN"
				return $retval
			fi
		fi
	fi
}

function CheckConnectivity3rdPartyHosts {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local remote3rdPartySuccess
	local retval

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug

		if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]; then
			remote3rdPartySuccess=false
			for i in $REMOTE_3RD_PARTY_HOSTS
			do
				eval "$PING_CMD $i > /dev/null 2>&1" &
				WaitForTaskCompletion $! 180 360 ${FUNCNAME[0]} true $KEEP_LOGGING
				retval=$?
				if [ $retval != 0 ]; then
					Logger "Cannot ping 3rd party host [$i]. Return code [$retval]." "NOTICE"
				else
					remote3rdPartySuccess=true
				fi
			done

			if [ $remote3rdPartySuccess == false ]; then
				Logger "No remote 3rd party host responded to ping. No internet ?" "WARN"
				return 1
			else
				return 0
			fi
		fi
	fi
}

#__BEGIN_WITH_PARANOIA_DEBUG
function __CheckArguments {
	# Checks the number of arguments of a function and raises an error if some are missing

	if [ "$_DEBUG" == "yes" ]; then
		local numberOfArguments="${1}" # Number of arguments the tested function should have, can be a number of a range, eg 0-2 for zero to two arguments
		local numberOfGivenArguments="${2}" # Number of arguments that have been passed
		local functionName="${3}" # Function name that called __CheckArguments

		local minArgs
		local maxArgs

		if [ "$_PARANOIA_DEBUG" == "yes" ]; then
			Logger "Entering function [$functionName]." "DEBUG"
		fi

		# All arguments of the function to check are passed as array in ${4} (the function call waits for $@)
		# If any of the arguments contains spaces, bash things there are two aguments
		# In order to avoid this, we need to iterate over ${4} and count

		local iterate=4
		local fetchArguments=true
		local argList=""
		local countedArguments
		while [ $fetchArguments == true ]; do
			cmd='argument=${'$iterate'}'
			eval $cmd
			if [ "$argument" = "" ]; then
				fetchArguments=false
			else
				argList="$arg_list [Argument $(($iterate-3)): $argument]"
				iterate=$(($iterate+1))
			fi
		done
		countedArguments=$((iterate-4))

		if [ $(IsNumeric "$numberOfArguments") -eq 1 ]; then
			minArgs=$numberOfArguments
			maxArgs=$numberOfArguments
		else
			IFS='-' read minArgs maxArgs <<< "$numberOfArguments"
		fi

		if ! ([ $countedArguments -ge $minArgs ] && [ $countedArguments -le $maxArgs ]); then
			Logger "Function $functionName may have inconsistent number of arguments. Expected min: $minArgs, max: $maxArgs, count: $countedArguments, bash seen: $numberOfGivenArguments. see log file." "ERROR"
			Logger "Arguments passed: $argList" "ERROR"
		fi
	fi
}

#__END_WITH_PARANOIA_DEBUG

function RsyncPatternsAdd {
	local patternType="${1}"	# exclude or include
	local pattern="${2}"
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local rest

	# Disable globbing so wildcards from exclusions do not get expanded
	set -f
	rest="$pattern"
	while [ -n "$rest" ]
	do
		# Take the string until first occurence until $PATH_SEPARATOR_CHAR
		str=${rest%%;*} #TODO: replace ; with $PATH_SEPARATOR_CHAR
		# Handle the last case
		if [ "$rest" = "${rest/$PATH_SEPARATOR_CHAR/}" ]; then
			rest=
		else
			# Cut everything before the first occurence of $PATH_SEPARATOR_CHAR
			rest=${rest#*$PATH_SEPARATOR_CHAR}
		fi
			if [ "$RSYNC_PATTERNS" == "" ]; then
			RSYNC_PATTERNS="--"$patternType"=\"$str\""
		else
			RSYNC_PATTERNS="$RSYNC_PATTERNS --"$patternType"=\"$str\""
		fi
	done
	set +f
}

function RsyncPatternsFromAdd {
	local patternType="${1}"
	local patternFrom="${2}"
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	## Check if the exclude list has a full path, and if not, add the config file path if there is one
	if [ "$(basename $patternFrom)" == "$patternFrom" ]; then
		patternFrom="$(dirname $CONFIG_FILE)/$patternFrom"
	fi

	if [ -e "$patternFrom" ]; then
		RSYNC_PATTERNS="$RSYNC_PATTERNS --"$patternType"-from=\"$patternFrom\""
	fi
}

function RsyncPatterns {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

       if [ "$RSYNC_PATTERN_FIRST" == "exclude" ]; then
		if [ "$RSYNC_EXCLUDE_PATTERN" != "" ]; then
			RsyncPatternsAdd "exclude" "$RSYNC_EXCLUDE_PATTERN"
		fi
		if [ "$RSYNC_EXCLUDE_FROM" != "" ]; then
			RsyncPatternsFromAdd "exclude" "$RSYNC_EXCLUDE_FROM"
		fi
		if [ "$RSYNC_INCLUDE_PATTERN" != "" ]; then
			RsyncPatternsAdd "$RSYNC_INCLUDE_PATTERN" "include"
		fi
		if [ "$RSYNC_INCLUDE_FROM" != "" ]; then
			RsyncPatternsFromAdd "include" "$RSYNC_INCLUDE_FROM"
		fi
	# Use default include first for quicksync runs
	elif [ "$RSYNC_PATTERN_FIRST" == "include" ] || [ "$_QUICK_SYNC" == "2" ]; then
		if [ "$RSYNC_INCLUDE_PATTERN" != "" ]; then
			RsyncPatternsAdd "include" "$RSYNC_INCLUDE_PATTERN"
		fi
		if [ "$RSYNC_INCLUDE_FROM" != "" ]; then
			RsyncPatternsFromAdd "include" "$RSYNC_INCLUDE_FROM"
		fi
		if [ "$RSYNC_EXCLUDE_PATTERN" != "" ]; then
			RsyncPatternsAdd "exclude" "$RSYNC_EXCLUDE_PATTERN"
		fi
		if [ "$RSYNC_EXCLUDE_FROM" != "" ]; then
			RsyncPatternsFromAdd "exclude" "$RSYNC_EXCLUDE_FROM"
		fi
	else
		Logger "Bogus RSYNC_PATTERN_FIRST value in config file. Will not use rsync patterns." "WARN"
	fi
}

function PreInit {
	 __CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	local compressionString

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
	if [ "$_DRYRUN" == true ]; then
		RSYNC_DRY_ARG="-n"
		DRY_WARNING="/!\ DRY RUN "
	else
		RSYNC_DRY_ARG=""
	fi

	RSYNC_ATTR_ARGS=""
	if [ "$PRESERVE_PERMISSIONS" != "no" ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -p"
	fi
	if [ "$PRESERVE_OWNER" != "no" ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -o"
	fi
	if [ "$PRESERVE_GROUP" != "no" ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -g"
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
	if [ "$(IsInteger $COMPRESSION_LEVEL)" -eq 0 ]; then
		COMPRESSION_LEVEL=3
	fi

	## Busybox fix (Termux xz command doesn't support compression at all)
	if [ "$LOCAL_OS" == "BUSYBOX" ] || [ "$REMOTE_OS" == "BUSYBOX" ]; then
		compressionString=""
		if type gzip > /dev/null 2>&1
		then
			COMPRESSION_PROGRAM="| gzip -c$compressionString"
			COMPRESSION_EXTENSION=.gz
			# obackup specific
		else
			COMPRESSION_PROGRAM=
			COMPRESSION_EXTENSION=
		fi
	else
		compressionString=" -$COMPRESSION_LEVEL"

		if type xz > /dev/null 2>&1
		then
			COMPRESSION_PROGRAM="| xz -c$compressionString"
			COMPRESSION_EXTENSION=.xz
		elif type lzma > /dev/null 2>&1
		then
			COMPRESSION_PROGRAM="| lzma -c$compressionString"
			COMPRESSION_EXTENSION=.lzma
		elif type pigz > /dev/null 2>&1
		then
			COMPRESSION_PROGRAM="| pigz -c$compressionString"
			COMPRESSION_EXTENSION=.gz
			# obackup specific
			COMPRESSION_OPTIONS=--rsyncable
		elif type gzip > /dev/null 2>&1
		then
			COMPRESSION_PROGRAM="| gzip -c$compressionString"
			COMPRESSION_EXTENSION=.gz
			# obackup specific
			COMPRESSION_OPTIONS=--rsyncable
		else
			COMPRESSION_PROGRAM=
			COMPRESSION_EXTENSION=
		fi
	fi
	ALERT_LOG_FILE="$ALERT_LOG_FILE$COMPRESSION_EXTENSION"
}

function PostInit {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	# Define remote commands
	if [ -f "$SSH_RSA_PRIVATE_KEY" ]; then
		SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $SSH_OPTS $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
		SCP_CMD="$(type -p scp) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY -P $REMOTE_PORT"
		RSYNC_SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $SSH_OPTS -p $REMOTE_PORT"
	elif [ -f "$SSH_PASSWORD_FILE" ]; then
		SSH_CMD="$(type -p sshpass) -f $SSH_PASSWORD_FILE $(type -p ssh) $SSH_COMP $SSH_OPTS $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
		SCP_CMD="$(type -p sshpass) -f $SSH_PASSWORD_FILE $(type -p scp) $SSH_COMP -P $REMOTE_PORT"
		RSYNC_SSH_CMD="$(type -p sshpass) -f $SSH_PASSWORD_FILE $(type -p ssh) $SSH_COMP $SSH_OPTS -p $REMOTE_PORT"
	else
		SSH_PASSWORD=""
		SSH_CMD=""
		SCP_CMD=""
		RSYNC_SSH_CMD=""
	fi
}

function InitLocalOSSettings {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	## If running under Msys, some commands do not run the same way
	## Using mingw version of find instead of windows one
	## Getting running processes is quite different
	## Ping command is not the same
	if [ "$LOCAL_OS" == "msys" ]; then
		FIND_CMD=$(dirname $BASH)/find
		PING_CMD='$SYSTEMROOT\system32\ping -n 2'
	else
		FIND_CMD=find
		PING_CMD="ping -c 2 -i .2"
	fi

	if [ "$LOCAL_OS" == "BUSYBOX" ]; then
		PROCESS_STATE_CMD="echo none"
	else
		PROCESS_STATE_CMD='ps -p$pid -o state= 2 > /dev/null'
	fi

	## Stat command has different syntax on Linux and FreeBSD/MacOSX
	if [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "BSD" ]; then
		# Tested on BSD and Mac
		STAT_CMD="stat -f \"%Sm\""
		STAT_CTIME_MTIME_CMD="stat -f %N;%c;%m"
	else
		# Tested on GNU stat and busybox
		STAT_CMD="stat -c %y"
		STAT_CTIME_MTIME_CMD="stat -c %n;%Z;%Y"
	fi
}

function InitRemoteOSSettings {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

	## MacOSX does not use the -E parameter like Linux or BSD does (-E is mapped to extended attrs instead of preserve executability)
	if [ "$PRESERVE_EXECUTABILITY" != "no" ];then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ]; then
			RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -E"
		fi
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

## IFS debug function
function PrintIFS {
	printf "IFS is: %q" "$IFS"
}

# Process debugging
# Recursive function to get all parents from a pid
function ParentPid {
	local pid="${1}" # Pid to analyse
	local parent

	parent=$(ps -p $pid -o ppid=)
	echo "$pid is a child of $parent"
	if [ $parent -gt 0 ]; then
		ParentPid $parent
	fi
}

## END Generic functions
_LOGGER_PREFIX="time"

## Working directory. This directory exists in any replica and contains state files, backups, soft deleted files etc
OSYNC_DIR=".osync_workdir"

function TrapStop {
	if [ $SOFT_STOP -eq 0 ]; then
		Logger " /!\ WARNING: Manual exit of osync is really not recommended. Sync will be in inconsistent state." "WARN"
		Logger " /!\ WARNING: If you are sure, please hit CTRL+C another time to quit." "WARN"
		SOFT_STOP=1
		return 1
	fi

	if [ $SOFT_STOP -eq 1 ]; then
		Logger " /!\ WARNING: CTRL+C hit twice. Exiting osync. Please wait while replicas get unlocked..." "WARN"
		SOFT_STOP=2
		exit 2
	fi
}

function TrapQuit {
	local exitcode

	if [ $ERROR_ALERT == true ]; then
		UnlockReplicas
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
		CleanUp
		Logger "$PROGRAM finished with errors." "ERROR"
		if [ "$_DEBUG" != "yes" ]
		then
			SendAlert
		else
			Logger "Debug mode, no alert mail will be sent." "NOTICE"
		fi
		exitcode=1
	elif [ $WARN_ALERT == true ]; then
		UnlockReplicas
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
		CleanUp
		Logger "$PROGRAM finished with warnings." "WARN"
		if [ "$_DEBUG" != "yes" ]
		then
			SendAlert
		else
			Logger "Debug mode, no alert mail will be sent." "NOTICE"
		fi
		exitcode=2	# Warning exit code must not force daemon mode to quit
	else
		UnlockReplicas
		RunAfterHook
		CleanUp
		Logger "$PROGRAM finished." "NOTICE"
		exitcode=0
	fi

	KillChilds $$ > /dev/null 2>&1

	exit $exitcode
}

function CheckEnvironment {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"    #__WITH_PARANOIA_DEBUG

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		if ! type ssh > /dev/null 2>&1 ; then
			Logger "ssh not present. Cannot start sync." "CRITICAL"
			exit 1
		fi

		if [ "$SSH_PASSWORD_FILE" != "" ] && ! type sshpass > /dev/null 2>&1 ; then
			Logger "sshpass not present. Cannot use password authentication." "CRITICAL"
			exit 1
		fi
	fi

	if ! type rsync > /dev/null 2>&1 ; then
		Logger "rsync not present. Sync cannot start." "CRITICAL"
		exit 1
	fi
}

function CheckCurrentConfig {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"    #__WITH_PARANOIA_DEBUG

	# Check all variables that should contain "yes" or "no"
	declare -a yes_no_vars=(CREATE_DIRS SUDO_EXEC SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING PRESERVE_PERMISSIONS PRESERVE_OWNER PRESERVE_GROUP PRESERVE_EXECUTABILITY PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS CHECKSUM RSYNC_COMPRESS CONFLICT_BACKUP CONFLICT_BACKUP_MULTIPLE SOFT_DELETE RESUME_SYNC FORCE_STRANGER_LOCK_RESUME PARTIAL DELTA_COPIES STOP_ON_CMD_ERROR RUN_AFTER_CMD_ON_ERROR)
	for i in "${yes_no_vars[@]}"; do
		test="if [ \"\$$i\" != \"yes\" ] && [ \"\$$i\" != \"no\" ]; then Logger \"Bogus $i value [\$$i] defined in config file. Correct your config file or update it using the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done

	# Check all variables that should contain a numerical value >= 0
	declare -a num_vars=(MINIMUM_SPACE BANDWIDTH SOFT_MAX_EXEC_TIME HARD_MAX_EXEC_TIME KEEP_LOGGING MIN_WAIT MAX_WAIT CONFLICT_BACKUP_DAYS SOFT_DELETE_DAYS RESUME_TRY MAX_EXEC_TIME_PER_CMD_BEFORE MAX_EXEC_TIME_PER_CMD_AFTER)
	for i in "${num_vars[@]}"; do
		test="if [ $(IsNumericExpand \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value [\$$i] defined in config file. Correct your config file or update it using the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done
}

function CheckCurrentConfigAll {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"    #__WITH_PARANOIA_DEBUG

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

	#TODO(low): Add runtime variable tests (RSYNC_ARGS etc)
	if [ "$REMOTE_OPERATION" == "yes" ] && ([ ! -f "$SSH_RSA_PRIVATE_KEY" ] && [ ! -f "$SSH_PASSWORD_FILE" ]); then
		Logger "Cannot find rsa private key [$SSH_RSA_PRIVATE_KEY] nor password file [$SSH_PASSWORD_FILE]. No authentication method provided." "CRITICAL"
		exit 1
	fi

	if [ "$SKIP_DELETION" != "" ] && [ $(arrayContains "${INITIATOR[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ] && [ $(arrayContains "${TARGET[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ]; then
		Logger "Bogus skip deletion parameter." "CRITICAL"
		exit 1
	fi
}

###### Osync specific functions (non shared)

function _CheckReplicaPathsLocal {
	local replica_path="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	if [ ! -w "$replica_path" ]; then
		Logger "Local replica path [$replica_path] is not writable." "CRITICAL"
		exit 1
	fi

	if [ ! -d "$replica_path" ]; then
		if [ "$CREATE_DIRS" == "yes" ]; then
			$COMMAND_SUDO mkdir -p "$replica_path" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1
			if [ $? != 0 ]; then
				Logger "Cannot create local replica path [$replica_path]." "CRITICAL"
				Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)"
				exit 1
			else
				Logger "Created local replica path [$replica_path]." "NOTICE"
			fi
		else
			Logger "Local replica path [$replica_path] does not exist." "CRITICAL"
			exit 1
		fi
	fi
}

function _CheckReplicaPathsRemote {
	local replica_path="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if [ ! -w \"'$replica_path'\" ];then exit 1; fi" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Remote replica path [$replica_path] is not writable." "CRITICAL"
		exit 1
	fi

	cmd=$SSH_CMD' "if ! [ -d \"'$replica_path'\" ]; then if [ \"'$CREATE_DIRS'\" == \"yes\" ]; then '$COMMAND_SUDO' mkdir -p \"'$replica_path'\"; fi; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Cannot create remote replica path [$replica_path]." "CRITICAL"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		exit 1
	fi
}

function CheckReplicaPaths {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	# Use direct comparaison before having a portable realpath implementation
	#INITIATOR_SYNC_DIR_CANN=$(realpath "${INITIATOR[$__replicaDir]}")	#TODO(verylow): investigate realpath & readlink issues on MSYS and busybox here
	#TARGET_SYNC_DIR_CANN=$(realpath "${TARGET[$__replicaDir]}")

	if [ "$REMOTE_OPERATION" != "yes" ]; then
		if [ "${INITIATOR[$__replicaDir]}" == "${TARGET[$__replicaDir]}" ]; then
			Logger "Initiator and target path [${INITIATOR[$__replicaDir]}] cannot be the same." "CRITICAL"
			exit 1
		fi
	fi

	_CheckReplicaPathsLocal "${INITIATOR[$__replicaDir]}" &
	pids="$!"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CheckReplicaPathsLocal "${TARGET[$__replicaDir]}" &
		pids="$pids;$!"
	else
		_CheckReplicaPathsRemote "${TARGET[$__replicaDir]}" &
		pids="$pids;$!"
	fi
	WaitForTaskCompletion $pids 720 1800 ${FUNCNAME[0]} false $KEEP_LOGGING
	if [ $? -ne 0 ]; then
		Logger "Cancelling task." "CRITICAL"
		exit 1
	fi
}

function _CheckDiskSpaceLocal {
	local replica_path="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local diskSpace

	Logger "Checking minimum disk space in [$replica_path]." "NOTICE"

	diskSpace=$(df "$replica_path" | tail -1 | awk '{print $4}')

	# Ugly fix for df in some busybox environments that can only show human formats
	if [ $(IsInteger $diskSpace) -eq 0 ]; then
		diskSpace=$(HumanToNumeric $diskSpace)
	fi

	if [ $diskSpace -lt $MINIMUM_SPACE ]; then
		Logger "There is not enough free space on replica [$replica_path] ($diskSpace KB)." "WARN"
	fi
}

function _CheckDiskSpaceRemote {
	local replica_path="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	Logger "Checking remote minimum disk space in [$replica_path]." "NOTICE"

	local cmd
	local diskSpace

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "'$COMMAND_SUDO' df \"'$replica_path'\"" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Cannot get free space on target [$replica_path]." "ERROR"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	else
		diskSpace=$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID | tail -1 | awk '{print $4}')

		# Ugly fix for df in some busybox environments that can only show human formats
		if [ $(IsInteger $diskSpace) -eq 0 ]; then
			diskSpace=$(HumanToNumeric $diskSpace)
		fi

		if [ $diskSpace -lt $MINIMUM_SPACE ]; then
			Logger "There is not enough free space on replica [$replica_path] ($diskSpace KB)." "WARN"
		fi
	fi
}

function CheckDiskSpace {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	if [ $MINIMUM_SPACE -eq 0 ]; then
		Logger "Skipped minimum space check." "NOTICE"
		return 0
	fi

	_CheckDiskSpaceLocal "${INITIATOR[$__replicaDir]}" &
	pids="$!"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CheckDiskSpaceLocal "${TARGET[$__replicaDir]}" &
		pids="$pids;$!"
	else
		_CheckDiskSpaceRemote "${TARGET[$__replicaDir]}" &
		pids="$pids;$!"
	fi
	WaitForTaskCompletion $pids 720 1800 ${FUNCNAME[0]} true $KEEP_LOGGING
}


function _CreateStateDirsLocal {
	local replica_state_dir="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	if ! [ -d "$replica_state_dir" ]; then
		$COMMAND_SUDO mkdir -p "$replica_state_dir" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1
		if [ $? != 0 ]; then
			Logger "Cannot create state dir [$replica_state_dir]." "CRITICAL"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
			exit 1
		fi
	fi
}

function _CreateStateDirsRemote {
	local replica_state_dir="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if ! [ -d \"'$replica_state_dir'\" ]; then '$COMMAND_SUDO' mkdir -p \"'$replica_state_dir'\"; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Cannot create remote state dir [$replica_state_dir]." "CRITICAL"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		exit 1
	fi
}

function CreateStateDirs {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	_CreateStateDirsLocal "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}" &
	pids="$!"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CreateStateDirsLocal "${TARGET[$__replicaDir]}${TARGET[$__stateDir]}" &
		pids="$pids;$!"
	else
		_CreateStateDirsRemote "${TARGET[$__replicaDir]}${TARGET[$__stateDir]}" &
		pids="$pids;$!"
	fi
	WaitForTaskCompletion $pids 720 1800 ${FUNCNAME[0]} true $KEEP_LOGGING
	if [ $? -ne 0 ]; then
		Logger "Cancelling task." "CRITICAL"
		exit 1
	fi
}

function _CheckLocksLocal {
	local lockfile="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local lockfile_content
	local lock_pid
	local lock_instance_id

	if [ -f "$lockfile" ]; then
		lockfile_content=$(cat $lockfile)
		Logger "Master lock pid present: $lockfile_content" "DEBUG"
		lock_pid=${lockfile_content%@*}
		lock_instance_id=${lockfile_content#*@}
		kill -9 $lock_pid > /dev/null 2>&1
		if [ $? != 0 ]; then
			Logger "There is a dead osync lock in [$lockfile]. Instance [$lock_pid] no longer running. Resuming." "NOTICE"
			#rm "$lockfile"
			#if [ $? != 0 ]; then
			#	Logger "Cannot remove lock in [$lockfile]." "CRITICAL"
			#	exit 1
			#fi
		else
			Logger "There is already a local instance of osync running [$lock_pid] for this replica. Cannot start." "CRITICAL"
			exit 1
		fi
	fi
}

function _CheckLocksRemote {
	local lockfile="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd
	local lock_pid
	local lock_instance_id
	local lockfile_content

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if [ -f \"'$lockfile'\" ]; then cat \"'$lockfile'\"; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'"'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
			lockfile_content=$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)
		else
			Logger "Cannot get remote lockfile." "CRITICAL"
			exit 1
		fi
	fi

	lock_pid=${lockfile_content%@*}
	lock_instance_id=${lockfile_content#*@}

	if [ "$lock_pid" != "" ] && [ "$lock_instance_id" != "" ]; then
		Logger "Remote lock is: $lock_pid@$lock_instance_id" "DEBUG"

		kill -0 $lock_pid > /dev/null 2>&1
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
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	if [ $_NOLOCKS == true ]; then
		return 0
	fi

	# Do not bother checking for locks when FORCE_UNLOCK is set
	if [ $FORCE_UNLOCK == true ]; then
		WriteLockFiles
		if [ $? != 0 ]; then
			exit 1
		fi
	else
		_CheckLocksLocal "${INITIATOR[$__lockFile]}" &
		pids="$!"
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_CheckLocksLocal "${TARGET[$__lockFile]}" &
			pids="$pids;$!"
		else
			_CheckLocksRemote "${TARGET[$__lockFile]}" &
			pids="$pids;$!"
		fi
		WaitForTaskCompletion $pids 720 1800 ${FUNCNAME[0]} true $KEEP_LOGGING
		if [ $? -ne 0 ]; then
			Logger "Cancelling task." "CRITICAL"
			exit 1
		fi
		WriteLockFiles
	fi
}

function _WriteLockFilesLocal {
	local lockfile="${1}"
	local replicaType="${2}"
	__CheckArguments 2 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	(
		set -o noclobber
		$COMMAND_SUDO echo "$SCRIPT_PID@$INSTANCE_ID" > "$lockfile" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-$replicaType.$SCRIPT_PID"
	)
	if [ $?	!= 0 ]; then
		Logger "Could not create lock file on local $replicaType in [$lockfile]." "CRITICAL"
		Logger "Command output\n$($RUN_DIR/$PROGRAM.${FUNCNAME[0]}-$replicaType.$SCRIPT_PID)" "NOTICE"
		return 1
	else
		Logger "Locked local $replicaType replica in [$lockfile]." "DEBUG"
	fi
}

function _WriteLockFilesRemote {
	local lockfile="${1}"
	local replicaType="${2}"
	__CheckArguments 2 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "( set -o noclobber; echo '$SCRIPT_PID@$INSTANCE_ID' | '$COMMAND_SUDO' tee \"'$lockfile'\")" > /dev/null 2> $RUN_DIR/$PROGRAM._WriteLockFilesRemote.$replicaType.$SCRIPT_PID'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Could not create lock file on remote $replicaType in [$lockfile]." "CRITICAL"
		Loggxer "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID)" "NOTICE"
		return 1
	else
		Logger "Locked remote $replicaType replica in [$lockfile]." "DEBUG"
	fi
}

function WriteLockFiles {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local initiatorPid
	local targetPid
	local pidArray
	local pid

	_WriteLockFilesLocal "${INITIATOR[$__lockFile]}" "${INITIATOR[$__type]}"&
	initiatorPid="$!"

	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_WriteLockFilesLocal "${TARGET[$__lockFile]}" "${TARGET[$__type]}" &
		targetPid="$!"
	else
		_WriteLockFilesRemote "${TARGET[$__lockFile]}" "${TARGET[$__type]}" &
		targetPid="$!"
	fi

	INITIATOR_LOCK_FILE_EXISTS=true
	TARGET_LOCK_FILE_EXISTS=true
	WaitForTaskCompletion "$initiatorPid;$targetPid" 720 1800 ${FUNCNAME[0]} true $KEEP_LOGGING
	if [ $? -ne 0 ]; then
		IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION"
		for pid in "${pidArray[@]}"; do
			pid=${pid%:*}
			if [ "$pid" == "$initiatorPid" ]; then
				INITIATOR_LOCK_FILE_EXISTS=false
			elif [ "$pid" == "$targetPid" ]; then
				TARGET_LOCK_FILE_EXISTS=false
			fi
		done

		Logger "Cancelling task." "CRITICAL"
		exit 1
	fi
}

function _UnlockReplicasLocal {
	local lockfile="${1}"
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

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
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd=

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if [ -f \"'$lockfile'\" ]; then '$COMMAND_SUDO' rm -f \"'$lockfile'\"; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Could not unlock remote replica." "ERROR"
		Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	else
		Logger "Removed remote replica lock." "DEBUG"
	fi
}

function UnlockReplicas {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	if [ $_NOLOCKS == true ]; then
		return 0
	fi

	if [ $INITIATOR_LOCK_FILE_EXISTS == true ]; then
		_UnlockReplicasLocal "${INITIATOR[$__lockFile]}" &
		pids="$!"
	fi

	if [ $TARGET_LOCK_FILE_EXISTS == true ]; then
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_UnlockReplicasLocal "${TARGET[$__lockFile]}" &
			pids="$pids;$!"
		else
			_UnlockReplicasRemote "${TARGET[$__lockFile]}" &
			pids="$pids;$!"
		fi
	fi

	if [ "$pids" != "" ]; then
		WaitForTaskCompletion $pids 720 1800 ${FUNCNAME[0]} true $KEEP_LOGGING
	fi
}

###### Sync core functions

	## Rsync does not like spaces in directory names, considering it as two different directories. Handling this schema by escaping space.
	## It seems this only happens when trying to execute an rsync command through weval $rsyncCmd on a remote host.
	## So I am using unescaped $INITIATOR_SYNC_DIR for local rsync calls and escaped $ESC_INITIATOR_SYNC_DIR for remote rsync calls like user@host:$ESC_INITIATOR_SYNC_DIR
	## The same applies for target sync dir..............................................T.H.I.S..I.S..A..P.R.O.G.R.A.M.M.I.N.G..N.I.G.H.T.M.A.R.E

function treeList {
	local replicaPath="${1}" # path to the replica for which a tree needs to be constructed
	local replicaType="${2}" # replica type: initiator, target
	local treeFilename="${3}" # filename to output tree (will be prefixed with $replicaType)

	local escapedReplicaPath
	local rsyncCmd

	__CheckArguments 3 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	escapedReplicaPath=$(EscapeSpaces "$replicaPath")

	Logger "Creating $replicaType replica file list [$replicaPath]." "NOTICE"
	if [ "$REMOTE_OPERATION" == "yes" ] && [ "$replicaType" == "${TARGET[$__type]}" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -L $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS -8 --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE -e \"$RSYNC_SSH_CMD\" --list-only $REMOTE_USER@$REMOTE_HOST:\"$escapedReplicaPath\" 2> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID\" | (grep -E \"^-|^d|^l\" || :) | (awk '{\$1=\$2=\$3=\$4=\"\" ;print}' || :) | (awk '{\$1=\$1 ;print}' || :) | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID\""
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -L $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS -8 --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --list-only \"$replicaPath\" 2> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID\" | (grep -E \"^-|^d|^l\" || :) | (awk '{\$1=\$2=\$3=\$4=\"\" ;print}' || :) | (awk '{\$1=\$1 ;print}' || :) | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID\""
	fi
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	retval=$?

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID" ]; then
		mv -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType$treeFilename"
	fi

	## Retval 24 = some files vanished while creating list
	if ([ $retval == 0 ] || [ $retval == 24 ]) then
		return $?
	elif [ $retval == 23 ]; then
		Logger "Some files could not be listed in [$replicaPath]. Check for failing symlinks." "ERROR"
		Logger "Command output\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID)" "NOTICE"
		return 0
	else
		Logger "Cannot create replica file list in [$replicaPath]." "CRITICAL"
		return $retval
	fi
}

# deleteList(replicaType): Creates a list of files vanished from last run on replica $1 (initiator/target)
function deleteList {
	local replicaType="${1}" # replica type: initiator, target
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd

	Logger "Creating $replicaType replica deleted file list." "NOTICE"
	if [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeAfterFileNoSuffix]}" ]; then
		## Same functionnality, comm is much faster than grep but is not available on every platform
		if type comm > /dev/null 2>&1 ; then
			cmd="comm -23 \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeAfterFileNoSuffix]}\" \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeCurrentFile]}\" > \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}\""
		else
			## The || : forces the command to have a good result
			cmd="(grep -F -x -v -f \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeCurrentFile]}\" \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeAfterFileNoSuffix]}\" || :) > \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}\""
		fi

		Logger "CMD: $cmd" "DEBUG"
		eval "$cmd" 2>> "$LOG_FILE"
		retval=$?

		# Add delete failed file list to current delete list and then empty it
		if [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__failedDeletedListFile]}" ]; then
			cat "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__failedDeletedListFile]}" >> "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}"
			if [ $? == 0 ]; then
				rm -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__failedDeletedListFile]}"
			else
				Logger "Cannot add failed deleted list to current deleted list for replica [$replicaType]." "ERROR"
			fi
		fi
		return $retval
	else
		touch "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}"
		return $retval
	fi
}

function _getFileCtimeMtimeLocal {
	local replicaPath="${1}" # Contains replica path
	local replicaType="${2}" # Initiator / Target
	local fileList="${3}" # Contains list of files to get time attrs
	__CheckArguments 3 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	echo -n "" > "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID"
	while read -r file; do $STAT_CTIME_MTIME_CMD "$replicaPath$file" | sort >> "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID"; done < "$fileList"
	if [ $? != 0 ]; then
		Logger "Getting file attributes failed [$retval] on $replicaType. Stopping execution." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID)" "VERBOSE"
		fi
		exit 1
	fi

}

function _getFileCtimeMtimeRemote {
	local replicaPath="${1}" # Contains replica path
	local replicaType="${2}"
	local fileList="${3}"
	__CheckArguments 3 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd

	cmd='cat "'$fileList'" | '$SSH_CMD' "while read -r file; do '$REMOTE_STAT_CTIME_MTIME_CMD' \"'$replicaPath'\$file\"; done | sort" > "'$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID'"'
	Logger "CMD: $cmd" "DEBUG"
	eval "$cmd"
	if [ $? != 0 ]; then
		Logger "Getting file attributes failed [$retval] on $replicaType. Stopping execution." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID)" "VERBOSE"
		fi
		exit 1
	fi
}

# rsync does sync with mtime, but file attribute modifications only change ctime.
# Hence, detect newer ctime on the replica that gets updated first with CONFLICT_PREVALANCE and update all newer file attributes on this replica before real update
function syncAttrs {
	local initiatorReplica="${1}"
	local targetReplica="${2}"
	__CheckArguments 2 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local rsyncCmd
	local retval

	local sourceDir
	local destDir
	local escSourceDir
	local escDestDir
	local destReplica

	if [ "$LOCAL_OS" == "BUSYBOX" ]; then
		Logger "Skipping acl synchronization. Busybox does not have join command." "NOTICE"
		return 0
	fi

	Logger "Getting list of files that need updates." "NOTICE"

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -i -n -8 $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_PARTIAL_EXCLUDE -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE \"$initiatorReplica\" $REMOTE_USER@$REMOTE_HOST:\"$targetReplica\" >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1 &"
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -i -n -8 $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_PARTIAL_EXCLUDE --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE \"$initiatorReplica\" \"$targetReplica\" >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1 &"
	fi
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]} false $KEEP_LOGGING
	retval=$?

	if [ $retval != 0 ] && [ $retval != 24 ]; then
		Logger "Getting list of files that need updates failed [$retval]. Stopping execution." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
			Logger "Rsync output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
		fi
		exit 1
	else
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
			Logger "List:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "VERBOSE"
		fi
		( grep -Ev "^[^ ]*(c|s|t)[^ ]* " "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" || :) | ( grep -E "^[^ ]*(p|o|g|a)[^ ]* " || :) | sed -e 's/^[^ ]* //' >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID"
		if [ $? != 0 ]; then
			Logger "Cannot prepare file list for attribute sync." "CRITICAL"
			exit 1
		fi
	fi

	Logger "Getting ctimes for pending files on initiator." "NOTICE"
	_getFileCtimeMtimeLocal "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID" &
	pids="$!"

	Logger "Getting ctimes for pending files on target." "NOTICE"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_getFileCtimeMtimeLocal "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID" &
		pids="$pids;$!"
	else
		_getFileCtimeMtimeRemote "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID" &
		pids="$pids;$!"
	fi
	WaitForTaskCompletion $pids 1800 0 ${FUNCNAME[0]} true $KEEP_LOGGING

	# If target gets updated first, then sync_attr must update initiators attrs first
	# For join, remove leading replica paths

	sed -i'.tmp' "s;^${INITIATOR[$__replicaDir]};;g" "$RUN_DIR/$PROGRAM.ctime_mtime.${INITIATOR[$__type]}.$SCRIPT_PID"
	sed -i'.tmp' "s;^${TARGET[$__replicaDir]};;g" "$RUN_DIR/$PROGRAM.ctime_mtime.${TARGET[$__type]}.$SCRIPT_PID"

	if [ "$CONFLICT_PREVALANCE" == "${TARGET[$__type]}" ]; then
		sourceDir="${INITIATOR[$__replicaDir]}"
		escSourceDir=$(EscapeSpaces "${INITIATOR[$__replicaDir]}")
		destDir="${TARGET[$__replicaDir]}"
		escDestDir=$(EscapeSpaces "${TARGET[$__replicaDir]}")
		destReplica="${TARGET[$__type]}"
		join -j 1 -t ';' -o 1.1,1.2,2.2 "$RUN_DIR/$PROGRAM.ctime_mtime.${INITIATOR[$__type]}.$SCRIPT_PID" "$RUN_DIR/$PROGRAM.ctime_mtime.${TARGET[$__type]}.$SCRIPT_PID" | awk -F';' '{if ($2 > $3) print $1}' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID"
	else
		sourceDir="${TARGET[$__replicaDir]}"
		escSourceDir=$(EscapeSpaces "${TARGET[$__replicaDir]}")
		destDir="${INITIATOR[$__replicaDir]}"
		escDestDir=$(EscapeSpaces "${INITIATOR[$__replicaDir]}")
		destReplica="${INITIATOR[$__type]}"
		join -j 1 -t ';' -o 1.1,1.2,2.2 "$RUN_DIR/$PROGRAM.ctime_mtime.${TARGET[$__type]}.$SCRIPT_PID" "$RUN_DIR/$PROGRAM.ctime_mtime.${INITIATOR[$__type]}.$SCRIPT_PID" | awk -F';' '{if ($2 > $3) print $1}' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID"
	fi

	if [ $(wc -l < "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID") -eq 0 ]; then
		Logger "Updating file attributes on $destReplica not required" "NOTICE"
		return 0
	fi

	Logger "Updating file attributes on $destReplica." "NOTICE"

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost

		# No rsync args (hence no -r) because files are selected with --from-file
		if [ "$destReplica" == "${INITIATOR[$__type]}" ]; then
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID\" $REMOTE_USER@$REMOTE_HOST:\"$escSourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID 2>&1 &"
		else
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID\" \"$sourceDir\" $REMOTE_USER@$REMOTE_HOST:\"$escDestDir\" >> $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID 2>&1 &"
		fi
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID\" \"$sourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID 2>&1 &"

	fi

	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]} false $KEEP_LOGGING
	retval=$?

	if [ $retval != 0 ] && [ $retval != 24 ]; then
		Logger "Updating file attributes on $destReplica [$retval]. Stopping execution." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID" ]; then
			Logger "Rsync output:\n$(cat $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID)" "NOTICE"
		fi
		exit 1
	else
		if [ -f "$RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID" ]; then
			Logger "List:\n$(cat $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID)" "VERBOSE"
		fi
		Logger "Successfully updated file attributes on $destReplica replica." "NOTICE"
	fi
}

# syncUpdate(source replica, destination replica, delete_list_filename)
function syncUpdate {
	local sourceReplica="${1}" # Contains replica type of source: initiator, target
	local destinationReplica="${2}" # Contains replica type of destination: initiator, target
	__CheckArguments 2 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local rsyncCmd
	local retval

	local sourceDir
	local escSourceDir
	local destDir
	local escDestDir

	local backupArgs

	Logger "Updating $destinationReplica replica." "NOTICE"
	if [ "$sourceReplica" == "${INITIATOR[$__type]}" ]; then
		sourceDir="${INITIATOR[$__replicaDir]}"
		destDir="${TARGET[$__replicaDir]}"
		backupArgs="$TARGET_BACKUP"

		escSourceDir=$(EscapeSpaces "${INITIATOR[$__replicaDir]}")
		escDestDir=$(EscapeSpaces "${TARGET[$__replicaDir]}")
	else
		sourceDir="${TARGET[$__replicaDir]}"
		destDir="${INITIATOR[$__replicaDir]}"
		backupArgs="$INITIATOR_BACKUP"

		escSourceDir=$(EscapeSpaces "${TARGET[$__replicaDir]}")
		escDestDir=$(EscapeSpaces "${INITIATOR[$__replicaDir]}")
	fi

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		if [ "$sourceReplica" == "${INITIATOR[$__type]}" ]; then
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $backupArgs --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$sourceReplica${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$destinationReplica${INITIATOR[$__deletedListFile]}\" \"$sourceDir\" $REMOTE_USER@$REMOTE_HOST:\"$escDestDir\" >> $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID 2>&1"
		else
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $backupArgs --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$destinationReplica${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$sourceReplica${INITIATOR[$__deletedListFile]}\" $REMOTE_USER@$REMOTE_HOST:\"$escSourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID 2>&1"
		fi
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS $backupArgs --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$sourceReplica${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$destinationReplica${INITIATOR[$__deletedListFile]}\" \"$sourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID 2>&1"
	fi
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	retval=$?

	if [ $retval != 0 ] && [ $retval != 24 ]; then
		Logger "Updating $destinationReplica replica failed. Stopping execution." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID" ]; then
			Logger "Rsync output:\n$(cat $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID)" "NOTICE"
		fi
		exit 1
	else
		if [ -f "$RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID" ]; then
			Logger "List:\n$(cat $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID)" "VERBOSE"
		fi
		Logger "Updating $destinationReplica replica succeded." "NOTICE"
		return 0
	fi
}

function _deleteLocal {
	local replicaType="${1}" # Replica type
	local replicaDir="${2}" # Full path to replica
	local deletionDir="${3}" # deletion dir in format .[workdir]/deleted
	__CheckArguments 3 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local parentdir
	local previousFile=""
	local result

	local deletionListFromReplica

	if [ "$replicaType" == "${INITIATOR[$__type]}" ]; then
		deletionListFromReplica="${TARGET[$__type]}"
	elif [ "$replicaType" == "${TARGET[$__type]}" ]; then
		deletionListFromReplica="${INITIATOR[$__type]}"
	else
		Logger "Bogus replicaType in [${FUNCNAME[0]}]." "CRITICAL"
		exit 1
	fi

	if [ ! -d "$replicaDir$deletionDir" ] && [ $_DRYRUN == false ]; then
		$COMMAND_SUDO mkdir -p "$replicaDir$deletionDir"
		if [ $? != 0 ]; then
			Logger "Cannot create local replica deletion directory in [$replicaDir$deletionDir]." "ERROR"
			exit 1
		fi
	fi

	while read -r files; do
		## On every run, check wheter the next item is already deleted because it is included in a directory already deleted
		if [[ "$files" != "$previousFile/"* ]] && [ "$files" != "" ]; then

			if [ "$SOFT_DELETE" != "no" ]; then
				if [ $_DRYRUN == false ]; then
					if [ -e "$replicaDir$deletionDir/$files" ]; then
						rm -rf "${replicaDir:?}$deletionDir/$files"
					fi

					if [ -e "$replicaDir$files" ]; then
						# In order to keep full path on soft deletion, create parent directories before move
						parentdir="$(dirname "$files")"
						if [ "$parentdir" != "." ]; then
							mkdir -p "$replicaDir$deletionDir/$parentdir"
							Logger "Moving deleted file [$replicaDir$files] to [$replicaDir$deletionDir/$parentdir]." "VERBOSE"
							mv -f "$replicaDir$files" "$replicaDir$deletionDir/$parentdir"
						else
							Logger "Moving deleted file [$replicaDir$files] to [$replicaDir$deletionDir]." "VERBOSE"
							mv -f "$replicaDir$files" "$replicaDir$deletionDir"
						fi
						if [ $? != 0 ]; then
							Logger "Cannot move [$replicaDir$files] to deletion directory." "ERROR"
							echo "$files" >> "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__failedDeletedListFile]}"
						else
							echo "$files" >> "$RUN_DIR/$PROGRAM.delete.$replicaType.$SCRIPT_PID"
						fi
					fi
				fi
			else
				if [ $_DRYRUN == false ]; then
					if [ -e "$replicaDir$files" ]; then
						rm -rf "$replicaDir$files"
						result=$?
						Logger "Deleting [$replicaDir$files]." "VERBOSE"
						if [ $result != 0 ]; then
							Logger "Cannot delete [$replicaDir$files]." "ERROR"
							echo "$files" >> "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__failedDeletedListFile]}"
						else
							echo "$files" >> "$RUN_DIR/$PROGRAM.delete.$replicaType.$SCRIPT_PID"
						fi
					fi
				fi
			fi
			previousFile="$files"
		fi
	done < "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$deletionListFromReplica${INITIATOR[$__deletedListFile]}"
}

function _deleteRemote {
	local replicaType="${1}" # Replica type
	local replicaDir="${2}" # Full path to replica
	local deletionDir="${3}" # deletion dir in format .[workdir]/deleted
	__CheckArguments 3 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local escDestDir
	local rsyncCmd

	local failedDeleteList
	local successDeleteList

	local deletionListFromReplica

	if [ "$replicaType" == "${INITIATOR[$__type]}" ]; then
		deletionListFromReplica="${TARGET[$__type]}"
	elif [ "$replicaType" == "${TARGET[$__type]}" ]; then
		deletionListFromReplica="${INITIATOR[$__type]}"
	else
		Logger "Bogus replicaType in [${FUNCNAME[0]}]." "CRITICAL"
		exit 1
	fi

	failedDeleteList="$(EscapeSpaces ${TARGET[$__replicaDir]}${TARGET[$__stateDir]}/$replicaType${TARGET[$__failedDeletedListFile]})"
	successDeleteList="$(EscapeSpaces ${TARGET[$__replicaDir]}${TARGET[$__stateDir]}/$replicaType${TARGET[$__successDeletedListFile]})"

	## This is a special coded function. Need to redelcare local functions on remote host, passing all needed variables as escaped arguments to ssh command.
	## Anything beetween << ENDSSH and ENDSSH will be executed remotely

	# Additionnaly, we need to copy the deletetion list to the remote state folder
	escDestDir="$(EscapeSpaces "${TARGET[$__replicaDir]}${TARGET[$__stateDir]}")"
	rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$deletionListFromReplica${INITIATOR[$__deletedListFile]}\" $REMOTE_USER@$REMOTE_HOST:\"$escDestDir/\" >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID 2>&1"
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" 2>> "$LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot copy the deletion list to remote replica." "ERROR"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID" ]; then
			Logger "$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID)" "ERROR"
		fi
		exit 1
	fi

$SSH_CMD ERROR_ALERT=0 sync_on_changes=$sync_on_changes _DEBUG=$_DEBUG _DRYRUN=$_DRYRUN _VERBOSE=$_VERBOSE COMMAND_SUDO=$COMMAND_SUDO FILE_LIST="$(EscapeSpaces "${TARGET[$__replicaDir]}${TARGET[$__stateDir]}/$deletionListFromReplica${INITIATOR[$__deletedListFile]}")" REPLICA_DIR="$(EscapeSpaces "$replicaDir")" SOFT_DELETE=$SOFT_DELETE DELETION_DIR="$(EscapeSpaces "$deletionDir")" FAILED_DELETE_LIST="$failedDeleteList" SUCCESS_DELETE_LIST="$successDeleteList" 'bash -s' << 'ENDSSH' >> "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID" 2>&1

	## The following lines are executed remotely
	function _logger {
		local value="${1}" # What to log
		echo -e "$value"
	}

	function Logger {
		local value="${1}" # What to log
		local level="${2}" # Log level: DEBUG, NOTICE, WARN, ERROR, CRITIAL

		local prefix="RTIME: $SECONDS - "

		if [ "$level" == "CRITICAL" ]; then
			_logger "$prefix\e[41m$value\e[0m"
			return
		elif [ "$level" == "ERROR" ]; then
			_logger "$prefix\e[91m$value\e[0m"
			return
		elif [ "$level" == "WARN" ]; then
			_logger "$prefix\e[93m$value\e[0m"
			return
		elif [ "$level" == "NOTICE" ]; then
			_logger "$prefix$value"
			return
		elif [ "$level" == "VERBOSE" ]; then
			if [ $_VERBOSE == true ]; then
				_logger "$prefix$value"
			fi
			return
		elif [ "$level" == "DEBUG" ]; then
			if [ "$_DEBUG" == "yes" ]; then
				_logger "$prefix$value"
			fi
			return
		else
			_logger "\e[41mLogger function called without proper loglevel [$level].\e[0m"
			_logger "$prefix$value"
		fi
	}

	## Empty earlier failed delete list
	> "$FAILED_DELETE_LIST"
	> "$SUCCESS_DELETE_LIST"

	parentdir=
	previousFile=""

	if [ ! -d "$REPLICA_DIR$DELETION_DIR" ] && [ $_DRYRUN == false ]; then
		$COMMAND_SUDO mkdir -p "$REPLICA_DIR$DELETION_DIR"
		if [ $? != 0 ]; then
			Logger "Cannot create remote replica deletion directory in [$REPLICA_DIR$DELETION_DIR]." "ERROR"
			exit 1
		fi
	fi

	while read -r files; do
		## On every run, check wheter the next item is already deleted because it is included in a directory already deleted
		if [[ "$files" != "$previousFile/"* ]] && [ "$files" != "" ]; then

			if [ "$SOFT_DELETE" != "no" ]; then
				if [ $_DRYRUN == false ]; then
					if [ -e "$REPLICA_DIR$DELETION_DIR/$files" ]; then
						$COMMAND_SUDO rm -rf "$REPLICA_DIR$DELETION_DIR/$files"
					fi

					if [ -e "$REPLICA_DIR$files" ]; then
						# In order to keep full path on soft deletion, create parent directories before move
						parentdir="$(dirname "$files")"
						if [ "$parentdir" != "." ]; then
							$COMMAND_SUDO mkdir -p "$REPLICA_DIR$DELETION_DIR/$parentdir"
							$COMMAND_SUDO mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$DELETION_DIR/$parentdir"
							Logger "Moving deleted file [$REPLICA_DIR$files] to [$REPLICA_DIR$DELETION_DIR/$parentdir]." "VERBOSE"
						else
							$COMMAND_SUDO mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$DELETION_DIR"
							Logger "Moving deleted file [$REPLICA_DIR$files] to [$REPLICA_DIR$DELETION_DIR]." "VERBOSE"
						fi
						if [ $? != 0 ]; then
							Logger "Cannot move [$REPLICA_DIR$files] to deletion directory." "ERROR"
							# Using $files instead of $REPLICA_DIR$files here so the list is ready for next run
							echo "$files" >> "$FAILED_DELETE_LIST"
						else
							echo "$files" >> "$SUCCESS_DELETE_LIST"
						fi
					fi
				fi
			else
				if [ $_DRYRUN == false ]; then
					if [ -e "$REPLICA_DIR$files" ]; then
						$COMMAND_SUDO rm -rf "$REPLICA_DIR$files"
						$result=$?
						Logger "Deleting [$REPLICA_DIR$files]." "VERBOSE"
						if [ $result != 0 ]; then
							Logger "Cannot delete [$REPLICA_DIR$files]." "ERROR"
							echo "$files" >> "$FAILED_DELETE_LIST"
						else
							echo "$files" >> "$SUCCESS_DELETE_LIST"
						fi
					fi
				fi
			fi
			previousFile="$files"
		fi
	done < "$FILE_LIST"
ENDSSH

	if [ -f "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID" ]; then
		Logger "Remote Deletion:\n$(cat $RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID)" "VERBOSE"
	fi

	## Copy back the deleted failed file list
	rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" $REMOTE_USER@$REMOTE_HOST:\"{$failedDeleteList,$successDeleteList}\" \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}\" > \"$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID\""
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" 2>> "$LOG_FILE"
	result=$?
	if [ $result != 0 ]; then
		Logger "Cannot copy back the failed deletion list to initiator replica." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID" ]; then
			Logger "Comand output: $(cat $RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID)" "NOTICE"
		fi
		exit 1
	fi
	return 0
}

# delete_Propagation(replica type)
function deletionPropagation {
	local replicaType="${1}" # Contains replica type: initiator, target where to delete
	__CheckArguments 1 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local replicaDir
	local deleteDir

	Logger "Propagating deletions to $replicaType replica." "NOTICE"

	if [ "$replicaType" == "${INITIATOR[$__type]}" ]; then
		if [ $(arrayContains "${INITIATOR[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ]; then
			replicaDir="${INITIATOR[$__replicaDir]}"
			deleteDir="${INITIATOR[$__deleteDir]}"

			_deleteLocal "${INITIATOR[$__type]}" "$replicaDir" "$deleteDir"
			retval=$?
			if [ $retval != 0 ]; then
				Logger "Deletion on $replicaType replica failed." "CRITICAL"
				exit 1
			fi
		else
			Logger "Skipping deletion on replica $replicaType." "NOTICE"
		fi
	elif [ "$replicaType" == "${TARGET[$__type]}" ]; then
		if [ $(arrayContains "${TARGET[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ]; then
			replicaDir="${TARGET[$__replicaDir]}"
			deleteDir="${TARGET[$__deleteDir]}"

			if [ "$REMOTE_OPERATION" == "yes" ]; then
				_deleteRemote "${TARGET[$__type]}" "$replicaDir" "$deleteDir"
			else
				_deleteLocal "${TARGET[$__type]}" "$replicaDir" "$deleteDir"
			fi
			retval=$?
			if [ $retval == 0 ]; then
				if [ -f "$RUN_DIR/$PROGRAM._delete_remote.$SCRIPT_PID" ]; then
					Logger "Remote:\n$(cat $RUN_DIR/$PROGRAM._delete_remote.$SCRIPT_PID)" "VERBOSE"
				fi
				return $retval
			else
				Logger "Deletion on $replicaType failed." "CRITICAL"
				if [ -f "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID" ]; then
					Logger "Remote:\n$(cat $RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID)" "CRITICAL"
				fi
				exit 1
			fi
		else
			Logger "Skipping deletion on replica $replicaType." "NOTICE"
		fi
	fi
}

###### Sync function in 6 steps
######
###### Step 0a & 0b: Create current file list of replicas
###### Step 1a & 1b: Create deleted file list of replicas
###### Step 3: Update file attributes
###### Step 3a & 3b: Update replicas
###### Step 4a & 4b: Propagate deletions on replicas
###### Step 5a & 5b: Create after run file list of replicas

function Sync {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local resumeCount
	local resumeInitiator
	local resumeTarget

	local initiatorPid
	local targetPid

	local initiatorFail
	local targetFail

	Logger "Starting synchronization task." "NOTICE"

	if [ "$RESUME_SYNC" != "no" ]; then
		if [ -f "${INITIATOR[$__resumeCount]}" ]; then
			resumeCount=$(cat "${INITIATOR[$__resumeCount]}")
		else
			resumeCount=0
		fi

		if [ $resumeCount -lt $RESUME_TRY ]; then
			if [ -f "${INITIATOR[$__initiatorLastActionFile]}" ]; then
				resumeInitiator=$(cat "${INITIATOR[$__initiatorLastActionFile]}")
			else
				resumeInitiator="synced"
			fi

			if [ -f "${INITIATOR[$__targetLastActionFile]}" ]; then
				resumeTarget=$(cat "${INITIATOR[$__targetLastActionFile]}")
			else
				resumeTarget="synced"
			fi

			if [ "$resumeInitiator" != "synced" ]; then
				Logger "WARNING: Trying to resume aborted execution on $($STAT_CMD "${INITIATOR[$__initiatorLastActionFile]}") at task [$resumeInitiator] for initiator. [$resumeCount] previous tries." "WARN"
				echo $(($resumeCount+1)) > "${INITIATOR[$__resumeCount]}"
			else
				resumeInitiator="none"
			fi

			if [ "$resumeTarget" != "synced" ]; then
				Logger "WARNING: Trying to resume aborted execution on $($STAT_CMD "${INITIATOR[$__targetLastActionFile]}") as task [$resumeTarget] for target. [$resumeCount] previous tries." "WARN"
				echo $(($resumeCount+1)) > "${INITIATOR[$__resumeCount]}"
			else
				resumeTarget="none"
			fi
		else
			Logger "Will not resume aborted execution. Too many resume tries [$resumeCount]." "WARN"
			echo "0" > "${INITIATOR[$__resumeCount]}"
			resumeInitiator="none"
			resumeTarget="none"
		fi
	else
		resumeInitiator="none"
		resumeTarget="none"
	fi


	################################################################################################################################################# Actual sync begins here

	## Step 0a & 0b
	if [ "$resumeInitiator" == "none" ] || [ "$resumeTarget" == "none" ] || [ "$resumeInitiator" == "${SYNC_ACTION[0]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[0]}" ]; then
		if [ "$resumeInitiator" == "none" ] || [ "$resumeInitiator" == "${SYNC_ACTION[0]}" ]; then
			treeList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__treeCurrentFile]}" &
			initiatorPid="$!"
		fi

		if [ "$resumeTarget" == "none" ] || [ "$resumeTarget" == "${SYNC_ACTION[0]}" ]; then
			treeList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__treeCurrentFile]}" &
			targetPid="$!"
		fi

		WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]} false $KEEP_LOGGING
		if [ $? != 0 ]; then
			IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION"
			initiatorFail=false
			targetFail=false
			for pid in "${pidArray[@]}"; do
				pid=${pid%:*}
				if [ "$pid" == "$initiatorPid" ]; then
					echo "${SYNC_ACTION[0]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					initiatorFail=true
				elif [ "$pid" == "$targetPid" ]; then
					echo "${SYNC_ACTION[0]}" > "${INITIATOR[$__targetLastActionFile]}"
					targetFail=true
				fi
			done

			if [ $initiatorFail == false ]; then
				echo "${SYNC_ACTION[1]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			fi

			if [ $targetFail == false ]; then
				echo "${SYNC_ACTION[1]}" > "${INITIATOR[$__targetLastActionFile]}"
			fi

			exit 1
		else
			echo "${SYNC_ACTION[1]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[1]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[1]}"
			resumeTarget="${SYNC_ACTION[1]}"
		fi
	fi

	## Step 1a & 1b
	if [ "$resumeInitiator" == "${SYNC_ACTION[1]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[1]}" ]; then
		if [ "$resumeInitiator" == "${SYNC_ACTION[1]}" ]; then
			deleteList "${INITIATOR[$__type]}" &
			initiatorPid="$!"
		fi

		if [ "$resumeTarget" == "${SYNC_ACTION[1]}" ]; then
			deleteList "${TARGET[$__type]}" &
			targetPid="$!"
		fi

		WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]} false $KEEP_LOGGING
		if [ $? != 0 ]; then
			IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION"
			initiatorFail=false
			targetFail=false
			for pid in "${pidArray[@]}"; do
				pid=${pid%:*}
				if [ "$pid" == "$initiatorPid" ]; then
					echo "${SYNC_ACTION[1]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					initiatorFail=true
				elif [ "$pid" == "$targetPid" ]; then
					echo "${SYNC_ACTION[1]}" > "${INITIATOR[$__targetLastActionFile]}"
					targetFail=true
				fi
			done

			if [ $initiatorFail == false ]; then
				echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			fi

			if [ $targetFail == false ]; then
				echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__targetLastActionFile]}"
			fi

			exit 1
		else
			echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[2]}"
			resumeTarget="${SYNC_ACTION[2]}"
		fi
	fi

	## Step 2
	if [ "$resumeInitiator" == "${SYNC_ACTION[2]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[2]}" ]; then
		#TODO(high) only -X and -A (xattr & acl) should trigger this 
		if [ "$RSYNC_ATTR_ARGS" != "" ]; then
			syncAttrs "${INITIATOR[$__replicaDir]}" "$TARGET_SYNC_DIR"
			WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]} false $KEEP_LOGGING
			if [ $? != 0 ]; then
				echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__initiatorLastActionFile]}"
				echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__targetLastActionFile]}"
				exit 1
			else
				echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__initiatorLastActionFile]}"
				echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__targetLastActionFile]}"
				resumeInitiator="${SYNC_ACTION[3]}"
				resumeTarget="${SYNC_ACTION[3]}"

			fi
		else
			echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[3]}"
			resumeTarget="${SYNC_ACTION[3]}"
		fi
	fi

	## Step 3a & 3b
	if [ "$resumeInitiator" == "${SYNC_ACTION[3]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[3]}" ]; then
		if [ "$CONFLICT_PREVALANCE" == "${TARGET[$__type]}" ]; then
			if [ "$resumeTarget" == "${SYNC_ACTION[3]}" ]; then
				syncUpdate "${TARGET[$__type]}" "${INITIATOR[$__type]}"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__targetLastActionFile]}"
					resumeTarget="${SYNC_ACTION[4]}"
				fi
			fi
			if [ "$resumeInitiator" == "${SYNC_ACTION[3]}" ]; then
				syncUpdate "${INITIATOR[$__type]}" "${TARGET[$__type]}"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					resumeInitiator="${SYNC_ACTION[4]}"
				fi
			fi
		else
			if [ "$resumeInitiator" == "${SYNC_ACTION[3]}" ]; then
				syncUpdate "${INITIATOR[$__type]}" "${TARGET[$__type]}"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					resumeInitiator="${SYNC_ACTION[4]}"
				fi
			fi
			if [ "$resumeTarget" == "${SYNC_ACTION[3]}" ]; then
				syncUpdate "${TARGET[$__type]}" "${INITIATOR[$__type]}"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__targetLastActionFile]}"
					resumeTarget="${SYNC_ACTION[4]}"
				fi
			fi
		fi
	fi

	## Step 4a & 4b
	if [ "$resumeInitiator" == "${SYNC_ACTION[4]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[4]}" ]; then
		if [ "$resumeInitiator" == "${SYNC_ACTION[4]}" ]; then
			deletionPropagation "${INITIATOR[$__type]}" &
			initiatorPid="$!"
		fi

		if [ "$resumeTarget" == "${SYNC_ACTION[4]}" ]; then
			deletionPropagation "${TARGET[$__type]}" &
			targetPid="$!"
		fi

		WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]} false $KEEP_LOGGING
		if [ $? != 0 ]; then
			IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION"
			initiatorFail=false
			targetFail=false
			for pid in "${pidArray[@]}"; do
				pid=${pid%:*}
				if [ "$pid" == "$initiatorPid" ]; then
					echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					initiatorFail=true
				elif [ "$pid" == "$targetPid" ]; then
					echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__targetLastActionFile]}"
					targetFail=true
				fi
			done

			if [ $initiatorFail == false ]; then
				echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			fi

			if [ $targetFail == false ]; then
				echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__targetLastActionFile]}"
			fi

			exit 1
		else
			echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[5]}"
			resumeTarget="${SYNC_ACTION[5]}"

		fi
	fi

	## Step 5a & 5b
	if [ "$resumeInitiator" == "${SYNC_ACTION[5]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[5]}" ]; then
		if [ "$resumeInitiator" == "${SYNC_ACTION[5]}" ]; then
			treeList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__treeAfterFile]}" &
			initiatorPid="$!"
		fi

		if [ "$resumeTarget" == "${SYNC_ACTION[5]}" ]; then
			treeList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__treeAfterFile]}" &
			targetPid="$!"
		fi

		WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]} false $KEEP_LOGGING
		if [ $? != 0 ]; then
			IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION"
			initiatorFail=false
			targetFail=false
			for pid in "${pidArray[@]}"; do
				pid=${pid%:*}
				if [ "$pid" == "$initiatorPid" ]; then
					echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					initiatorFail=true
				elif [ "$pid" == "$targetPid" ]; then
					echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__targetLastActionFile]}"
					targetFail=true
				fi
			done

			if [ $initiatorFail == false ]; then
				echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			fi

			if [ $targetFail == false ]; then
				echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__targetLastActionFile]}"
			fi

			exit 1
		else
			echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[6]}"
			resumeTarget="${SYNC_ACTION[6]}"
		fi
	fi

	Logger "Finished synchronization task." "NOTICE"
	echo "0" > "${INITIATOR[$__resumeCount]}"
}

function _SoftDeleteLocal {
	local replicaType="${1}" # replica type (initiator, target)
	local replicaDeletionPath="${2}" # Contains the full path to softdelete / backup directory without ending slash
	local changeTime="${3}" # Delete files older than changeTime days
	local deletionType="${4}" # Trivial deletion type string

	__CheckArguments 4 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ "$LOCAL_OS" == "BUSYBOX" ]; then
		Logger "Skipping $deletionType deletion on $replicaType. Busybox find -ctime not supported." "NOTICE"
		return 0
	fi

	if [ -d "$replicaDeletionPath" ]; then
		if [ $_DRYRUN == true ]; then
			Logger "Listing files older than $changeTime days on $replicaType replica for $deletionType deletion. Does not remove anything." "NOTICE"
		else
			Logger "Removing files older than $changeTime days on $replicaType replica for $deletionType deletion." "NOTICE"
		fi

		if [ $_VERBOSE == true ]; then
			# Cannot launch log function from xargs, ugly hack
			$COMMAND_SUDO $FIND_CMD "$replicaDeletionPath/" -type f -ctime +$changeTime -print0 | xargs -0 -I {} echo "Will delete file {}" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "VERBOSE"
			$COMMAND_SUDO $FIND_CMD "$replicaDeletionPath/" -type d -empty -ctime +$changeTime -print0 | xargs -0 -I {} echo "Will delete directory {}" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "VERBOSE"
		fi

		if [ $_DRYRUN == false ]; then
			$COMMAND_SUDO $FIND_CMD "$replicaDeletionPath/" -type f -ctime +$changeTime -print0 | xargs -0 -I {} $COMMAND_SUDO rm -f "{}" && $COMMAND_SUDO $FIND_CMD "$replicaDeletionPath/" -type d -empty -ctime +$changeTime -print0 | xargs -0 -I {} $COMMAND_SUDO rm -rf "{}" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1
		else
			Dummy
		fi
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Error while executing cleanup on $replicaType replica." "ERROR"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
		else
			Logger "Cleanup complete on $replicaType replica." "NOTICE"
		fi
	elif [ -d "$replicaDeletionPath" ] && ! [ -w "$replicaDeletionPath" ]; then
		Logger "The $replicaType replica dir [$replicaDeletionPath] is not writable. Cannot clean old files." "ERROR"
	else
		Logger "The $replicaType replica dir [$replicaDeletionPath] does not exist. Skipping cleaning of old files." "VERBOSE"
	fi
}

function _SoftDeleteRemote {
	local replicaType="${1}"
	local replicaDeletionPath="${2}" # Contains the full path to softdelete / backup directory without ending slash
	local changeTime="${3}" # Delete files older than changeTime days
	local deletionType="${4}" # Trivial deletion type string

	__CheckArguments 4 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ "$REMOTE_OS" == "BUSYBOX" ]; then
		Logger "Skipping $deletionType deletion on $replicaType. Busybox find -ctime not supported." "NOTICE"
		return 0
	fi

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	if [ $_DRYRUN == true ]; then
		Logger "Listing files older than $changeTime days on $replicaType replica for $deletionType deletion. Does not remove anything." "NOTICE"
	else
		Logger "Removing files older than $changeTime days on $replicaType replica for $deletionType deletion." "NOTICE"
	fi

	if [ $_VERBOSE == true ]; then
		# Cannot launch log function from xargs, ugly hack
		cmd=$SSH_CMD' "if [ -d \"'$replicaDeletionPath'\" ]; then '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replicaDeletionPath'/\" -type f -ctime +'$changeTime' -print0 | xargs -0 -I {} echo Will delete file {} && '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replicaDeletionPath'/\" -type d -empty -ctime '$changeTime' -print0 | xargs -0 -I {} echo Will delete directory {}; else echo \"The $replicaType replica dir [$replicaDeletionPath] does not exist. Skipping cleaning of old files.\"; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "VERBOSE"
	fi

	if [ $_DRYRUN == false ]; then
		cmd=$SSH_CMD' "if [ -d \"'$replicaDeletionPath'\" ]; then '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replicaDeletionPath'/\" -type f -ctime +'$changeTime' -print0 | xargs -0 -I {} '$COMMAND_SUDO' rm -f \"{}\" && '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replicaDeletionPath'/\" -type d -empty -ctime '$changeTime' -print0 | xargs -0 -I {} '$COMMAND_SUDO' rm -rf \"{}\"; else echo \"The $replicaType replicaDir [$replicaDeletionPath] does not exist. Skipping cleaning of old files.\"; fi" >> "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'

		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd"
	else
		Dummy
	fi
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Error while executing cleanup on remote $replicaType replica." "ERROR"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	else
		Logger "Cleanup complete on $replicaType replica." "NOTICE"
	fi
}

function SoftDelete {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	if [ "$CONFLICT_BACKUP" != "no" ] && [ $CONFLICT_BACKUP_DAYS -ne 0 ]; then
		Logger "Running conflict backup cleanup." "NOTICE"

		_SoftDeleteLocal "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__backupDir]}" $CONFLICT_BACKUP_DAYS "conflict backup" &
		pids="$!"
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_SoftDeleteLocal "${TARGET[$__type]}" "${TARGET[$__replicaDir]}${TARGET[$__backupDir]}" $CONFLICT_BACKUP_DAYS "conflict backup" &
			pids="$pids;$!"
		else
			_SoftDeleteRemote "${TARGET[$__type]}" "${TARGET[$__replicaDir]}${TARGET[$__backupDir]}" $CONFLICT_BACKUP_DAYS "conflict backup" &
			pids="$pids;$!"
		fi
		WaitForTaskCompletion $pids 720 1800 ${FUNCNAME[0]} true $KEEP_LOGGING
	fi

	if [ "$SOFT_DELETE" != "no" ] && [ $SOFT_DELETE_DAYS -ne 0 ]; then
		Logger "Running soft deletion cleanup." "NOTICE"

		_SoftDeleteLocal "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__deleteDir]}" $SOFT_DELETE_DAYS "softdelete" &
		pids="$!"
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_SoftDeleteLocal "${TARGET[$__type]}" "${TARGET[$__replicaDir]}${TARGET[$__deleteDir]}" $SOFT_DELETE_DAYS "softdelete" &
			pids="$pids;$!"
		else
			_SoftDeleteRemote "${TARGET[$__type]}" "${TARGET[$__replicaDir]}${TARGET[$__deleteDir]}" $SOFT_DELETE_DAYS "softdelete" &
			pids="$pids;$!"
		fi
		WaitForTaskCompletion $pids 720 1800 ${FUNCNAME[0]} true $KEEP_LOGGING
	fi
}

function _SummaryFromFile {
	local replicaPath="${1}"
	local summaryFile="${2}"
	local direction="${3}"

	__CheckArguments 2 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	if [ -f "$summaryFile" ]; then
		while read -r file; do
			Logger "$direction $replicaPath$(echo $file | awk '{for (i=2; i<NF; i++) printf $i " "; print $NF}')" "ALWAYS"
		done < "$summaryFile"
	fi
}

function Summary {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local prefix

	prefix="$_LOGGER_PREFIX"
	_LOGGER_PREFIX=""

	Logger "Attrib updates: INITIATOR << >> TARGET" "ALWAYS"

	_SummaryFromFile "${TARGET[$__replicaDir]}" "$RUN_DIR/$PROGRAM.attr-update.target.$SCRIPT_PID" "~ >>"
	_SummaryFromFile "${INITIATOR[$__replicaDir]}" "$RUN_DIR/$PROGRAM.attr-update.initiator.$SCRIPT_PID" "~ <<"

	Logger "File transfers: INITIATOR << >> TARGET" "ALWAYS"
	_SummaryFromFile "${TARGET[$__replicaDir]}" "$RUN_DIR/$PROGRAM.update.target.$SCRIPT_PID" "+ >>"
	_SummaryFromFile "${INITIATOR[$__replicaDir]}" "$RUN_DIR/$PROGRAM.update.initiator.$SCRIPT_PID" "+ <<"

	#WIP: remote deletion summary does not work
	Logger "File deletions: INITIATOR << >> TARGET" "ALWAYS"
	if [ "$REMOTE_OPERATION" == "yes" ]; then
		_SummaryFromFile "${TARGET[$__replicaDir]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/target${TARGET[$__successDeletedListFile]}" "- >>"
	else
		_SummaryFromFile "${TARGET[$__replicaDir]}" "$RUN_DIR/$PROGRAM.delete.target.$SCRIPT_PID" "- >>"
	fi
	_SummaryFromFile "${INITIATOR[$__replicaDir]}" "$RUN_DIR/$PROGRAM.delete.initiator.$SCRIPT_PID" "- <<"

	_LOGGER_PREFIX="$prefix"
}

function Init {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace

	# Do not use exit and quit traps if osync runs in monitor mode
	if [ $sync_on_changes == false ]; then
		trap TrapStop INT HUP TERM QUIT
		trap TrapQuit EXIT
	else
		trap TrapQuit TERM EXIT HUP QUIT
	fi

	local uri
	local hosturiandpath
	local hosturi


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
			if [ ! -f "$SSH_PASSWORD_FILE" ]; then
				# Assume that there might exist a standard rsa key
				SSH_RSA_PRIVATE_KEY=~/.ssh/id_rsa
			fi
		fi

		# remove everything before '@'
		hosturiandpath=${uri#*@}
		# remove everything after first '/'
		hosturi=${hosturiandpath%%/*}
		if [[ "$hosturi" == *":"* ]]; then
			REMOTE_PORT=${hosturi##*:}
		else
			REMOTE_PORT=22
		fi
		REMOTE_HOST=${hosturi%%:*}

		# remove everything before first '/'
		TARGET_SYNC_DIR=${hosturiandpath#*/}
	else
		REMOTE_OPERATION="no"
	fi

	if [ "$INITIATOR_SYNC_DIR" == "" ] || [ "$TARGET_SYNC_DIR" == "" ]; then
		Logger "Initiator or target path empty." "CRITICAL"
		exit 1
	fi

	## Make sure there is only one trailing slash on path
	INITIATOR_SYNC_DIR="${INITIATOR_SYNC_DIR%/}/"
	TARGET_SYNC_DIR="${TARGET_SYNC_DIR%/}/"

	# Expand ~ if exists
	INITIATOR_SYNC_DIR="${INITIATOR_SYNC_DIR/#\~/$HOME}"
	TARGET_SYNC_DIR="${TARGET_SYNC_DIR/#\~/$HOME}"
	SSH_RSA_PRIVATE_KEY="${SSH_RSA_PRIVATE_KEY/#\~/$HOME}"
	SSH_PASSWORD_FILE="${SSH_PASSWORD_FILE/#\~/$HOME}"

	## Replica format
	## Why the f*** does bash not have simple objects ?
	# Local variables used for state filenames
	local lockFilename="lock"
	local stateDir="state"
	local backupDir="backup"
	local deleteDir="deleted"
	local partialDir="_partial"
	local lastAction="last-action"
	local resumeCount="resume-count"
	if [ "$_DRYRUN" == true ]; then
		local drySuffix="-dry"
	else
		local drySuffix=
	fi

	# The following associative like array definitions are used for bash ver < 4 compat
	readonly __type=0
	readonly __replicaDir=1
	readonly __lockFile=2
	readonly __stateDir=3
	readonly __backupDir=4
	readonly __deleteDir=5
	readonly __partialDir=6
	readonly __initiatorLastActionFile=7
	readonly __targetLastActionFile=8
	readonly __resumeCount=9
	readonly __treeCurrentFile=10
	readonly __treeAfterFile=11
	readonly __treeAfterFileNoSuffix=12
	readonly __deletedListFile=13
	readonly __failedDeletedListFile=14
	readonly __successDeletedListFile=15

	INITIATOR=()
	INITIATOR[$__type]='initiator'
	INITIATOR[$__replicaDir]="$INITIATOR_SYNC_DIR"
	INITIATOR[$__lockFile]="$INITIATOR_SYNC_DIR$OSYNC_DIR/$lockFilename"
	INITIATOR[$__stateDir]="$OSYNC_DIR/$stateDir"
	INITIATOR[$__backupDir]="$OSYNC_DIR/$backupDir"
	INITIATOR[$__deleteDir]="$OSYNC_DIR/$deleteDir"
	INITIATOR[$__partialDir]="$OSYNC_DIR/$partialDir"
	INITIATOR[$__initiatorLastActionFile]="$INITIATOR_SYNC_DIR$OSYNC_DIR/$stateDir/initiator-$lastAction-$INSTANCE_ID$drySuffix"
	INITIATOR[$__targetLastActionFile]="$INITIATOR_SYNC_DIR$OSYNC_DIR/$stateDir/target-$lastAction-$INSTANCE_ID$drySuffix"
	INITIATOR[$__resumeCount]="$INITIATOR_SYNC_DIR$OSYNC_DIR/$stateDir/$resumeCount-$INSTANCE_ID$drySuffix"
	INITIATOR[$__treeCurrentFile]="-tree-current-$INSTANCE_ID$drySuffix"
	INITIATOR[$__treeAfterFile]="-tree-after-$INSTANCE_ID$drySuffix"
	INITIATOR[$__treeAfterFileNoSuffix]="-tree-after-$INSTANCE_ID"
	INITIATOR[$__deletedListFile]="-deleted-list-$INSTANCE_ID$drySuffix"
	INITIATOR[$__failedDeletedListFile]="-failed-delete-$INSTANCE_ID$drySuffix"
	INITIATOR[$__successDeletedListFile]="-success-delete-$INSTANCE_ID$drySuffix"

	TARGET=()
	TARGET[$__type]='target'
	TARGET[$__replicaDir]="$TARGET_SYNC_DIR"
	TARGET[$__lockFile]="$TARGET_SYNC_DIR$OSYNC_DIR/$lockFilename"
	TARGET[$__stateDir]="$OSYNC_DIR/$stateDir"
	TARGET[$__backupDir]="$OSYNC_DIR/$backupDir"
	TARGET[$__deleteDir]="$OSYNC_DIR/$deleteDir"
	TARGET[$__partialDir]="$OSYNC_DIR/$partialDir"											# unused
	TARGET[$__initiatorLastActionFile]="$TARGET_SYNC_DIR$OSYNC_DIR/$stateDir/initiator-$lastAction-$INSTANCE_ID$drySuffix"		# unused
	TARGET[$__targetLastActionFile]="$TARGET_SYNC_DIR$OSYNC_DIR/$stateDir/target-$lastAction-$INSTANCE_ID$drySuffix"		# unused
	TARGET[$__resumeCount]="$TARGET_SYNC_DIR$OSYNC_DIR/$stateDir/$resumeCount-$INSTANCE_ID$drySuffix"				# unused
	TARGET[$__treeCurrentFile]="-tree-current-$INSTANCE_ID$drySuffix"								# unused
	TARGET[$__treeAfterFile]="-tree-after-$INSTANCE_ID$drySuffix"									# unused
	TARGET[$__treeAfterFileNoSuffix]="-tree-after-$INSTANCE_ID"									# unused
	TARGET[$__deletedListFile]="-deleted-list-$INSTANCE_ID$drySuffix"								# unused
	TARGET[$__failedDeletedListFile]="-failed-delete-$INSTANCE_ID$drySuffix"
	TARGET[$__successDeletedListFile]="-success-delete-$INSTANCE_ID$drySuffix"

	PARTIAL_DIR="${INITIATOR[$__partialDir]}"

	## Set sync only function arguments for rsync
	SYNC_OPTS="-u"

	if [ $_VERBOSE == true ] || [ $_SUMMARY == true ]; then
		SYNC_OPTS=$SYNC_OPTS" -i"
	fi

	if [ $STATS == true ]; then
		SYNC_OPTS=$SYNC_OPTS" --stats"
	fi

	## Add Rsync include / exclude patterns
	RsyncPatterns

	## Conflict options
	if [ "$CONFLICT_BACKUP" != "no" ]; then
		INITIATOR_BACKUP="--backup --backup-dir=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__backupDir]}\""
		TARGET_BACKUP="--backup --backup-dir=\"${TARGET[$__replicaDir]}${TARGET[$__backupDir]}\""
		if [ "$CONFLICT_BACKUP_MULTIPLE" == "yes" ]; then
			INITIATOR_BACKUP="$INITIATOR_BACKUP --suffix .$(date +%Y.%m.%d-%H.%M.%S)"
			TARGET_BACKUP="$TARGET_BACKUP --suffix .$(date +%Y.%m.%d-%H.%M.%S)"
		fi
	else
		INITIATOR_BACKUP=""
		TARGET_BACKUP=""
	fi

	SYNC_ACTION=(
	'replica-tree'
	'deleted-list'
	'sync_attrs'
	'update-replica'
	'delete-propagation'
	'replica-tree-after'
	'synced'
	)
}

function Main {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	CreateStateDirs
	CheckLocks
	Sync
}

function Usage {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$IS_STABLE" != "yes" ]; then
		echo -e "\e[93mThis is an unstable dev build. Please use with caution.\e[0m"
	fi

	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo "$CONTACT"
	echo ""
	echo "You may use osync with a full blown configuration file, or use its default options for quick command line sync."
	echo "Usage: osync.sh /path/to/config/file [OPTIONS]"
	echo "or     osync.sh --initiator=/path/to/initiator/replica --target=/path/to/target/replica [OPTIONS] [QUICKSYNC OPTIONS]"
	echo "or     osync.sh --initiator=/path/to/initiator/replica --target=ssh://[backupuser]@remotehost.com[:portnumber]//path/to/target/replica [OPTIONS] [QUICKSYNC OPTIONS]"
	echo ""
	echo "[OPTIONS]"
	echo "--dry             Will run osync without actually doing anything; just testing"
	echo "--no-prefix       Will suppress time / date suffix from output"
	echo "--silent          Will run osync without any output to stdout, used for cron jobs"
	echo "--errors-only     Output only errors (can be combined with silent or verbose)"
	echo "--summary         Outputs a list of transferred / deleted files at the end of the run"
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
	echo "--password-file=\"\"      If no rsa private key is used for ssh authentication, a password file can be used"
	echo "--instance-id=\"\"	Optional sync task name to identify this synchronization task when using multiple targets"
	echo "--skip-deletion=\"\"      You may skip deletion propagation on initiator or target. Valid values: initiator target initiator,target"
	echo ""
	echo "Additionaly, you may set most osync options at runtime. eg:"
	echo "SOFT_DELETE_DAYS=365 osync.sh --initiator=/path --target=/other/path"
	echo ""
	exit 128
}

function SyncOnChanges {
	__CheckArguments 0 $# "${FUNCNAME[0]}" "$@"	#__WITH_PARANOIA_DEBUG

	local cmd
	local retval

	if ! type inotifywait > /dev/null 2>&1 ; then
		Logger "No inotifywait command found. Cannot monitor changes." "CRITICAL"
		exit 1
	fi

	Logger "#### Running osync in file monitor mode." "NOTICE"

	while true; do
		if [ "$ConfigFile" != "" ]; then
			cmd='bash '$osync_cmd' "'$ConfigFile'" '$opts
		else
			cmd='bash '$osync_cmd' '$opts
		fi
		Logger "daemon cmd: $cmd" "DEBUG"
		eval "$cmd"
		retval=$?
		if [ $retval != 0 ] && [ $retval != 2 ]; then
			Logger "osync child exited with error." "ERROR"
		fi

		Logger "#### Monitoring now." "NOTICE"
		inotifywait --exclude $OSYNC_DIR $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE -qq -r -e create -e modify -e delete -e move -e attrib --timeout "$MAX_WAIT" "$INITIATOR_SYNC_DIR" &
		wait $!
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

# quicksync mode settings, overriden by config file
STATS=false
PARTIAL=no
if [ "$CONFLICT_PREVALANCE" == "" ]; then
	CONFLICT_PREVALANCE=initiator
fi

INITIATOR_LOCK_FILE_EXISTS=false
TARGET_LOCK_FILE_EXISTS=false
FORCE_UNLOCK=false
no_maxtime=false
opts=""
ERROR_ALERT=false
WARN_ALERT=false
# Number of CTRL+C
SOFT_STOP=0
# Number of given replicas in command line
_QUICK_SYNC=0
sync_on_changes=false
_NOLOCKS=false
osync_cmd=$0
_SUMMARY=false

if [ $# -eq 0 ]
then
	Usage
fi

first=1
for i in "$@"; do
	case $i in
		--dry)
		_DRYRUN=true
		opts=$opts" --dry"
		;;
		--silent)
		_SILENT=true
		opts=$opts" --silent"
		;;
		--verbose)
		_VERBOSE=true
		opts=$opts" --verbose"
		;;
		--stats)
		STATS=true
		opts=$opts" --stats"
		;;
		--partial)
		PARTIAL="yes"
		opts=$opts" --partial"
		;;
		--force-unlock)
		FORCE_UNLOCK=true
		opts=$opts" --force-unlock"
		;;
		--no-maxtime)
		no_maxtime=true
		opts=$opts" --no-maxtime"
		;;
		--help|-h|--version|-v)
		Usage
		;;
		--initiator=*)
		_QUICK_SYNC=$(($_QUICK_SYNC + 1))
		INITIATOR_SYNC_DIR=${i##*=}
		opts=$opts" --initiator=\"$INITIATOR_SYNC_DIR\""
		no_maxtime=true
		;;
		--target=*)
		_QUICK_SYNC=$(($_QUICK_SYNC + 1))
		TARGET_SYNC_DIR=${i##*=}
		opts=$opts" --target=\"$TARGET_SYNC_DIR\""
		no_maxtime=true
		;;
		--rsakey=*)
		SSH_RSA_PRIVATE_KEY=${i##*=}
		opts=$opts" --rsakey=\"$SSH_RSA_PRIVATE_KEY\""
		;;
		--password-file=*)
		SSH_PASSWORD_FILE=${i##*=}
		opts=$opts" --password-file\"$SSH_PASSWORD_FILE\""
		;;
		--instance-id=*)
		INSTANCE_ID=${i##*=}
		opts=$opts" --instance-id=\"$INSTANCE_ID\""
		;;
		--skip-deletion=*)
		opts=$opts" --skip-deletion=\"${i##*=}\""
		IFS=',' read -r -a SKIP_DELETION <<< ${i##*=}
		;;
		--on-changes)
		sync_on_changes=true
		_NOLOCKS=true
		_LOGGER_PREFIX="date"
		_LOGGER_STDERR=true
		;;
		--no-locks)
		_NOLOCKS=true
		;;
		--errors-only)
		#TODO: let err_only only output to stderr
		#_LOGGER_STDERR=true
		_LOGGER_ERR_ONLY=true
		;;
		--summary)
		_SUMMARY=true
		;;
		--no-prefix)
		_LOGGER_PREFIX=""
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
	else
		ConfigFile="${1}"
		LoadConfigFile "$ConfigFile"
	fi

if [ "$LOGFILE" == "" ]; then
	if [ -w /var/log ]; then
		LOG_FILE="/var/log/$PROGRAM.$INSTANCE_ID.log"
	elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
		LOG_FILE="$HOME/$PROGRAM.$INSTANCE_ID.log"
	else
		LOG_FILE="./$PROGRAM.$INSTANCE_ID.log"
	fi
else
	LOG_FILE="$LOGFILE"
fi
if [ ! -w "$(dirname $LOG_FILE)" ]; then
	echo "Cannot write to log [$(dirname $LOG_FILE)]."
else
	Logger "Script begin, logging to [$LOG_FILE]." "DEBUG"
fi

if [ "$IS_STABLE" != "yes" ]; then
	Logger "This is an unstable dev build [$PROGRAM_BUILD]. Please use with caution." "WARN"
	fi

GetLocalOS
InitLocalOSSettings
PreInit
Init
CheckEnvironment
PostInit
if [ $_QUICK_SYNC -lt 2 ]; then
	CheckCurrentConfig
fi
CheckCurrentConfigAll
DATE=$(date)
Logger "-------------------------------------------------------------" "NOTICE"
Logger "$DRY_WARNING$DATE - $PROGRAM $PROGRAM_VERSION script begin." "ALWAYS"
Logger "-------------------------------------------------------------" "NOTICE"
Logger "Sync task [$INSTANCE_ID] launched as $LOCAL_USER@$LOCAL_HOST (PID $SCRIPT_PID)" "NOTICE"
if [ $sync_on_changes == true ]; then
	SyncOnChanges
else
	GetRemoteOS
	InitRemoteOSSettings
	if [ $no_maxtime == true ]; then
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
	if [ $_SUMMARY == true ]; then
		Summary
	fi
fi
