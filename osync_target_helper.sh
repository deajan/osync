#!/usr/bin/env bash

PROGRAM="osync-target-helper" # Rsync based two way sync engine with fault tolerance
AUTHOR="(C) 2013-2017 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION=1.2.2-dev
PROGRAM_BUILD=2017061901
IS_STABLE=no


_OFUNCTIONS_VERSION=2.1.4-rc1
_OFUNCTIONS_BUILD=2017060903
_OFUNCTIONS_BOOTSTRAP=true

## BEGIN Generic bash functions written in 2013-2017 by Orsiris de Jong - http://www.netpower.fr - ozy@netpower.fr

## To use in a program, define the following variables:
## PROGRAM=program-name
## INSTANCE_ID=program-instance-name
## _DEBUG=yes/no
## _LOGGER_SILENT=true/false
## _LOGGER_VERBOSE=true/false
## _LOGGER_ERR_ONLY=true/false
## _LOGGER_PREFIX="date"/"time"/""

## Logger sets {ERROR|WARN}_ALERT variable when called with critical / error / warn loglevel
## When called from subprocesses, variable of main process can't be set. Status needs to be get via $RUN_DIR/$PROGRAM.Logger.{error|warn}.$SCRIPT_PID.$TSTAMP

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
if [ "$KEEP_LOGGING" == "" ]; then
	KEEP_LOGGING=1801
fi

# Initial error status, logging 'WARN', 'ERROR' or 'CRITICAL' will enable alerts flags
ERROR_ALERT=false
WARN_ALERT=false


## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	_LOGGER_VERBOSE=false
else
	trap 'TrapError ${LINENO} $?' ERR
	_LOGGER_VERBOSE=true
fi

if [ "$SLEEP_TIME" == "" ]; then # Leave the possibity to set SLEEP_TIME as environment variable when runinng with bash -x in order to avoid spamming console
	SLEEP_TIME=.05
fi

SCRIPT_PID=$$

# TODO: Check if %N works on MacOS
TSTAMP=$(date '+%Y%m%dT%H%M%S.%N')

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


# Default alert attachment filename
ALERT_LOG_FILE="$RUN_DIR/$PROGRAM.$SCRIPT_PID.$TSTAMP.last.log"

# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace


function Dummy {

	sleep $SLEEP_TIME
}

#### Logger SUBSET ####

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
		# Current log file
		echo -e "$logValue" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
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

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[91m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
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
		_Logger  "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
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
# VERBOSE sent to stdout if _LOGGER_VERBOSE = true
# ALWAYS is sent to stdout unless _LOGGER_SILENT = true
# DEBUG & PARANOIA_DEBUG are only sent to stdout if _DEBUG=yes
function Logger {
	local value="${1}"		# Sentence to log (in double quotes)
	local level="${2}"		# Log level
	local retval="${3:-undef}"	# optional return value of command

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="$(date) - "
	else
		prefix=""
	fi

	## Obfuscate _REMOTE_TOKEN in logs (for ssh_filter usage only in osync and obackup)
	value="${value/env _REMOTE_TOKEN=$_REMOTE_TOKEN/__(o_O)__}"
	value="${value/env _REMOTE_TOKEN=\$_REMOTE_TOKEN/__(o_O)__}"

	if [ "$level" == "CRITICAL" ]; then
		_Logger "$prefix($level):$value" "$prefix\e[1;33;41m$value\e[0m" true
		ERROR_ALERT=true
		# ERROR_ALERT / WARN_ALERT isn't set in main when Logger is called from a subprocess. Need to keep this flag.
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
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "$prefix$value" "$prefix$value"
			return
		fi
	else
		_Logger "\e[41mLogger function called without proper loglevel [$level].\e[0m" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "Value was: $prefix$value" "Value was: $prefix$value" true
	fi
}
#### Logger SUBSET END ####

# QuickLogger subfunction, can be called directly
function _QuickLogger {
	local value="${1}"
	local destination="${2}" # Destination: stdout, log, both

	if ([ "$destination" == "log" ] || [ "$destination" == "both" ]); then
		echo -e "$(date) - $value" >> "$LOG_FILE"
	elif ([ "$destination" == "stdout" ] || [ "$destination" == "both" ]); then
		echo -e "$value"
	fi
}

# Generic quick logging function
function QuickLogger {
	local value="${1}"

	if [ "$_LOGGER_SILENT" == true ]; then
		_QuickLogger "$value" "log"
	else
		_QuickLogger "$value" "stdout"
	fi
}

# Portable child (and grandchild) kill function tester under Linux, BSD and MacOS X
function KillChilds {
	local pid="${1}" # Parent pid to kill childs
	local self="${2:-false}" # Should parent be killed too ?

	# Paranoid checks, we can safely assume that $pid shouldn't be 0 nor 1
	if [ $(IsNumeric "$pid") -eq 0 ] || [ "$pid" == "" ] || [ "$pid" == "0" ] || [ "$pid" == "1" ]; then
		Logger "Bogus pid given [$pid]." "CRITICAL"
		return 1
	fi

	if kill -0 "$pid" > /dev/null 2>&1; then
		# Warning: pgrep is not native on cygwin, have this checked in CheckEnvironment
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
			if [ $? != 0 ]; then
				sleep 15
				Logger "Sending SIGTERM to process [$pid] failed." "DEBUG"
				kill -9 "$pid"
				if [ $? != 0 ]; then
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
		if [ $? != 0 ]; then
			errorcount=$((errorcount+1))
			fi
	done
	return $errorcount
}

# osync/obackup/pmocr script specific mail alert function, use SendEmail function for generic mail sending
function SendAlert {
	local runAlert="${1:-false}" # Specifies if current message is sent while running or at the end of a run


	local attachment
	local attachmentFile
	local subject
	local body

	if [ "$DESTINATION_MAILS" == "" ]; then
		return 0
	fi

	if [ "$_DEBUG" == "yes" ]; then
		Logger "Debug mode, no warning mail will be sent." "NOTICE"
		return 0
	fi

	eval "cat \"$LOG_FILE\" $COMPRESSION_PROGRAM > $ALERT_LOG_FILE"
	if [ $? != 0 ]; then
		attachment=false
	else
		attachment=true
	fi
	if [ -e "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP" ]; then
		if [ "$MAIL_BODY_CHARSET" != "" ] && type iconv > /dev/null 2>&1; then
			iconv -f UTF-8 -t $MAIL_BODY_CHARSET "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP" > "$RUN_DIR/$PROGRAM._Logger.iconv.$SCRIPT_PID.$TSTAMP"
			body="$MAIL_ALERT_MSG"$'\n\n'"$(cat $RUN_DIR/$PROGRAM._Logger.iconv.$SCRIPT_PID.$TSTAMP)"
		else
			body="$MAIL_ALERT_MSG"$'\n\n'"$(cat $RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP)"
		fi
	fi

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
		subject="Finished run - $subject"
	fi

	if [ "$attachment" == true ]; then
		attachmentFile="$ALERT_LOG_FILE"
	fi

	SendEmail "$subject" "$body" "$DESTINATION_MAILS" "$attachmentFile" "$SENDER_MAIL" "$SMTP_SERVER" "$SMTP_PORT" "$SMTP_ENCRYPTION" "$SMTP_USER" "$SMTP_PASSWORD"

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

	if [ "$LOCAL_OS" == "Busybox" ] || [ "$LOCAL_OS" == "Android" ]; then
		if [ "$smtpPort" == "" ]; then
			Logger "Missing smtp port, assuming 25." "WARN"
			smtpPort=25
		fi
		if type sendmail > /dev/null 2>&1; then
			if [ "$encryption" == "tls" ]; then
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$senderMail" -H "exec openssl s_client -quiet -tls1_2 -starttls smtp -connect $smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			elif [ "$encryption" == "ssl" ]; then
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$senderMail" -H "exec openssl s_client -quiet -connect $smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
			else
				echo -e "Subject:$subject\r\n$message" | $(type -p sendmail) -f "$senderMail" -S "$smtpServer:$smtpPort" -au"$smtpUser" -ap"$smtpPassword" "$destinationMails"
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
		# We need to replace spaces with comma in order for mutt to be able to process multiple destinations
		echo "$message" | $(type -p mutt) -x -s "$subject" "${destinationMails// /,}" $attachment_command
		if [ $? != 0 ]; then
			Logger "Cannot send mail via $(type -p mutt) !!!" "WARN"
		else
			Logger "Sent mail using mutt." "NOTICE"
			return 0
		fi
	fi

	if type mail > /dev/null 2>&1 ; then
		# We need to detect which version of mail is installed
		if ! $(type -p mail) -V > /dev/null 2>&1; then
			# This may be MacOS mail program
			attachment_command=""
		elif [ "$mail_no_attachment" -eq 0 ] && $(type -p mail) -V | grep "GNU" > /dev/null; then
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

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
	fi
}

function LoadConfigFile {
	local configFile="${1}"



	if [ ! -f "$configFile" ]; then
		Logger "Cannot load configuration file [$configFile]. Cannot start." "CRITICAL"
		exit 1
	elif [[ "$configFile" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$configFile]. Cannot start." "CRITICAL"
		exit 1
	else
		# Remove everything that is not a variable assignation
		grep '^[^ ]*=[^;&]*' "$configFile" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
		source "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	CONFIG_FILE="$configFile"
}

_OFUNCTIONS_SPINNER="|/-\\"
function Spinner {
	if [ $_LOGGER_SILENT == true ] || [ "$_LOGGER_ERR_ONLY" == true ]; then
		return 0
	else
		printf " [%c]  \b\b\b\b\b\b" "$_OFUNCTIONS_SPINNER"
		#printf "\b\b\b\b\b\b"
		_OFUNCTIONS_SPINNER=${_OFUNCTIONS_SPINNER#?}${_OFUNCTIONS_SPINNER%%???}
		return 0
	fi
}



# Time control function for background processes, suitable for multiple synchronous processes
# Fills a global variable called WAIT_FOR_TASK_COMPLETION_$callerName that contains list of failed pids in format pid1:result1;pid2:result2
# Also sets a global variable called HARD_MAX_EXEC_TIME_REACHED_$callerName to true if hardMaxTime is reached

# Standard wait $! emulation would be WaitForTaskCompletion $! 0 0 1 0 true false true false

function WaitForTaskCompletion {
	local pids="${1}" # pids to wait for, separated by semi-colon
	local softMaxTime="${2:-0}"	# If process(es) with pid(s) $pids take longer than $softMaxTime seconds, will log a warning, unless $softMaxTime equals 0.
	local hardMaxTime="${3:-0}"	# If process(es) with pid(s) $pids take longer than $hardMaxTime seconds, will stop execution, unless $hardMaxTime equals 0.
	local sleepTime="${4:-.05}"	# Seconds between each state check, the shorter this value, the snappier it will be, but as a tradeoff cpu power will be used (general values between .05 and 1).
	local keepLogging="${5:-0}"	# Every keepLogging seconds, an alive log message is send. Setting this value to zero disables any alive logging.
	local counting="${6:-true}"	# Count time since function has been launched (true), or since script has been launched (false)
	local spinner="${7:-true}"	# Show spinner (true), don't show anything (false)
	local noErrorLog="${8:-false}"	# Log errors when reaching soft / hard max time (false), don't log errors on those triggers (true)

	local callerName="${FUNCNAME[1]}"

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


	if [ $counting == true ]; then 	# If counting == false _SOFT_ALERT should be a global value so no more than one soft alert is shown
		local _SOFT_ALERT=false # Does a soft alert need to be triggered, if yes, send an alert once
	fi

	IFS=';' read -a pidsArray <<< "$pids"
	pidCount=${#pidsArray[@]}

	# Set global var default
	eval "WAIT_FOR_TASK_COMPLETION_$callerName=\"\""
	eval "HARD_MAX_EXEC_TIME_REACHED_$callerName=false"

	while [ ${#pidsArray[@]} -gt 0 ]; do
		newPidsArray=()

		if [ $spinner == true ]; then
			Spinner
		fi
		if [ $counting == true ]; then
			exec_time=$((SECONDS - seconds_begin))
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
			if [ "$_SOFT_ALERT" != true ] && [ $softMaxTime -ne 0 ] && [ $noErrorLog != true ]; then
				Logger "Max soft execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]." "WARN"
				_SOFT_ALERT=true
				SendAlert true
			fi
		fi

		if [ $exec_time -gt $hardMaxTime ] && [ $hardMaxTime -ne 0 ]; then
			if [ $noErrorLog != true ]; then
				Logger "Max hard execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]. Stopping task execution." "ERROR"
			fi
			for pid in "${pidsArray[@]}"; do
				KillChilds $pid true
				if [ $? == 0 ]; then
					Logger "Task with pid [$pid] stopped successfully." "NOTICE"
				else
					Logger "Could not stop task with pid [$pid]." "ERROR"
				fi
				errorcount=$((errorcount+1))
			done
			if [ $noErrorLog != true ]; then
				SendAlert true
			fi
			eval "HARD_MAX_EXEC_TIME_REACHED_$callerName=true"
			return $errorcount
		fi

		for pid in "${pidsArray[@]}"; do
			if [ $(IsInteger $pid) -eq 1 ]; then
				if kill -0 $pid > /dev/null 2>&1; then
					# Handle uninterruptible sleep state or zombies by ommiting them from running process array (How to kill that is already dead ? :)
					pidState="$(eval $PROCESS_STATE_CMD)"
					if [ "$pidState" != "D" ] && [ "$pidState" != "Z" ]; then
						newPidsArray+=($pid)
					fi
				else
					# pid is dead, get it's exit code from wait command
					wait $pid
					retval=$?
					if [ $retval -ne 0 ]; then
						Logger "${FUNCNAME[0]} called by [$callerName] finished monitoring [$pid] with exitcode [$retval]." "DEBUG"
						errorcount=$((errorcount+1))
						# Welcome to variable variable bash hell
						if [ "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_$callerName\")" == "" ]; then
							eval "WAIT_FOR_TASK_COMPLETION_$callerName=\"$pid:$retval\""
						else
							eval "WAIT_FOR_TASK_COMPLETION_$callerName=\";$pid:$retval\""
						fi
					fi
				fi
			fi
		done


		pidsArray=("${newPidsArray[@]}")
		# Trivial wait time for bash to not eat up all CPU
		sleep $sleepTime


	done


	# Return exit code if only one process was monitored, else return number of errors
	# As we cannot return multiple values, a global variable WAIT_FOR_TASK_COMPLETION contains all pids with their return value
	if [ $pidCount -eq 1 ]; then
		return $retval
	else
		return $errorcount
	fi
}

# Take a list of commands to run, runs them sequentially with numberOfProcesses commands simultaneously runs
# Returns the number of non zero exit codes from commands
# Use cmd1;cmd2;cmd3 syntax for small sets, use file for large command sets
# Only 2 first arguments are mandatory
# Sets a global variable called HARD_MAX_EXEC_TIME_REACHED to true if hardMaxTime is reached

function ParallelExec {
	local numberOfProcesses="${1}" 		# Number of simultaneous commands to run
	local commandsArg="${2}" 		# Semi-colon separated list of commands, or path to file containing one command per line
	local readFromFile="${3:-false}" 	# commandsArg is a file (true), or a string (false)
	local softMaxTime="${4:-0}"		# If process(es) with pid(s) $pids take longer than $softMaxTime seconds, will log a warning, unless $softMaxTime equals 0.
	local hardMaxTime="${5:-0}"		# If process(es) with pid(s) $pids take longer than $hardMaxTime seconds, will stop execution, unless $hardMaxTime equals 0.
	local sleepTime="${6:-.05}"		# Seconds between each state check, the shorter this value, the snappier it will be, but as a tradeoff cpu power will be used (general values between .05 and 1).
	local keepLogging="${7:-0}"		# Every keepLogging seconds, an alive log message is send. Setting this value to zero disables any alive logging.
	local counting="${8:-true}"		# Count time since function has been launched (true), or since script has been launched (false)
	local spinner="${9:-false}"		# Show spinner (true), don't show spinner (false)
	local noErrorLog="${10:-false}"		# Log errors when reaching soft / hard max time (false), don't log errors on those triggers (true)

	local callerName="${FUNCNAME[1]}"

	local log_ttime=0 # local time instance for comparaison

	local seconds_begin=$SECONDS # Seconds since the beginning of the script
	local exec_time=0 # Seconds since the beginning of this function

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


	# Set global var default
	eval "HARD_MAX_EXEC_TIME_REACHED_$callerName=false"

	if [ $counting == true ]; then 	# If counting == false _SOFT_ALERT should be a global value so no more than one soft alert is shown
		local _SOFT_ALERT=false # Does a soft alert need to be triggered, if yes, send an alert once
	fi

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

		if [ $spinner == true ]; then
			Spinner
		fi

		if [ $counting == true ]; then
			exec_time=$((SECONDS - seconds_begin))
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
			if [ "$_SOFT_ALERT" != true ] && [ $softMaxTime -ne 0 ] && [ $noErrorLog != true ]; then
				Logger "Max soft execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]." "WARN"
				_SOFT_ALERT=true
				SendAlert true
			fi
		fi
		if [ $exec_time -gt $hardMaxTime ] && [ $hardMaxTime -ne 0 ]; then
			if [ $noErrorLog != true ]; then
				Logger "Max hard execution time exceeded for task [$callerName] with pids [$(joinString , ${pidsArray[@]})]. Stopping task execution." "ERROR"
			fi
			for pid in "${pidsArray[@]}"; do
				KillChilds $pid true
				if [ $? == 0 ]; then
					Logger "Task with pid [$pid] stopped successfully." "NOTICE"
				else
					Logger "Could not stop task with pid [$pid]." "ERROR"
				fi
			done
			if [ $noErrorLog != true ]; then
				SendAlert true
			fi
			eval "HARD_MAX_EXEC_TIME_REACHED_$callerName=true"
			# Return the number of commands that haven't run / finished run
			return $((commandCount - counter + ${#pidsArray[@]}))
		fi

		while [ $counter -lt "$commandCount" ] && [ ${#pidsArray[@]} -lt $numberOfProcesses ]; do
			if [ $readFromFile == true ]; then
				command=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$commandsArg")
			else
				command="${commandsArray[$counter]}"
			fi
			Logger "Running command [$command]." "DEBUG"
			eval "$command" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$callerName.$SCRIPT_PID.$TSTAMP" 2>&1 &
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
			fi
		done

		pidsArray=("${newPidsArray[@]}")

		# Trivial wait time for bash to not eat up all CPU
		sleep $sleepTime

	done

	return $errorCount
}

function CleanUp {

	if [ "$_DEBUG" != "yes" ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
	fi
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
function UrlEncode {
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

function UrlDecode {
	local urlEncoded="${1//+/ }"

	printf '%b' "${urlEncoded//%/\\x}"
}

## Modified version of http://stackoverflow.com/a/8574392
## Usage: [ $(ArrayContains "needle" "${haystack[@]}") -eq 1 ]
function ArrayContains () {
	local needle="${1}"
	local haystack="${2}"
	local e

	if [ "$needle" != "" ] && [ "$haystack" != "" ]; then
		for e in "${@:2}"; do
			if [ "$e" == "$needle" ]; then
				echo 1
				return
			fi
		done
	fi
	echo 0
	return
}

function GetLocalOS {
	local localOsVar
	local localOsName
	local localOsVer

	# There's no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	else
		# Detecting the special ubuntu userland in Windows 10 bash
		if grep -i Microsoft /proc/sys/kernel/osrelease > /dev/null 2>&1; then
			localOsVar="Microsoft"
		else
			localOsVar="$(uname -spior 2>&1)"
			if [ $? != 0 ]; then
				localOsVar="$(uname -v 2>&1)"
				if [ $? != 0 ]; then
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
		*"Microsoft"*)
		LOCAL_OS="WinNT10"
		;;
		*"Darwin"*)
		LOCAL_OS="MacOSX"
		;;
		*"BusyBox"*)
		LOCAL_OS="BusyBox"
		;;
		*)
		if [ "$IGNORE_OS_TYPE" == "yes" ]; then
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
		localOsName=$(GetConfFileValue "/etc/os-release" "NAME")
		localOsVer=$(GetConfFileValue "/etc/os-release" "VERSION")
	fi

	# Add a global variable for statistics in installer
	LOCAL_OS_FULL="$localOsVar ($localOsName $localOsVer)"

	if [ "$_OFUNCTIONS_VERSION" != "" ]; then
		Logger "Local OS: [$LOCAL_OS_FULL]." "DEBUG"
	fi
}



function GetRemoteOS {

	if [ "$REMOTE_OPERATION" != "yes" ]; then
		return 0
	fi

	local remoteOsVar

$SSH_CMD env LC_ALL=C env _REMOTE_TOKEN="$_REMOTE_TOKEN" bash -s << 'ENDSSH' >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1


function GetOs {
	local localOsVar
	local localOsName
	local localOsVer

	local osInfo="/etc/os-release"

	# There's no good way to tell if currently running in BusyBox shell. Using sluggish way.
	if ls --help 2>&1 | grep -i "BusyBox" > /dev/null; then
		localOsVar="BusyBox"
	else
		# Detecting the special ubuntu userland in Windows 10 bash
		if grep -i Microsoft /proc/sys/kernel/osrelease > /dev/null 2>&1; then
			localOsVar="Microsoft"
		else
			localOsVar="$(uname -spior 2>&1)"
			if [ $? != 0 ]; then
				localOsVar="$(uname -v 2>&1)"
				if [ $? != 0 ]; then
					localOsVar="$(uname)"
				fi
			fi
		fi
	fi
	# Get linux versions
	if [ -f "$osInfo" ]; then
		localOsName=$(grep "^NAME=" "$osInfo")
                localOsName="${localOsName##*=}"
		localOsVer=$(grep "^VERSION=" "$osInfo")
		localOsVer="${localOsVer##*=}"
	fi

	echo "$localOsVar ($localOsName $localOsVer)"
}

GetOs

ENDSSH

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
		remoteOsVar=$(cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")
		case $remoteOsVar in
			*"Android"*)
			REMOTE_OS="Android"
			;;
			*"Linux"*)
			REMOTE_OS="Linux"
			;;
			*"BSD"*)
			REMOTE_OS="BSD"
			;;
			*"MINGW32"*|*"MINGW64"*|*"MSYS"*)
			REMOTE_OS="msys"
			;;
			*"CYGWIN"*)
			REMOTE_OS="Cygwin"
			;;
			*"Microsoft"*)
			REMOTE_OS="WinNT10"
			;;
			*"Darwin"*)
			REMOTE_OS="MacOSX"
			;;
			*"BusyBox"*)
			REMOTE_OS="BusyBox"
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

	if [ $_DRYRUN == true ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on local host." "NOTICE"
	eval "$command" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1 &

	WaitForTaskCompletion $! 0 $hardMaxTime $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ $_LOGGER_VERBOSE == true ] || [ $retval -ne 0 ]; then
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "NOTICE"
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


	if [ "$REMOTE_OPERATION" != "yes" ]; then
		Logger "Ignoring remote command [$command] because remote host is not configured." "WARN"
		return 0
	fi

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	if [ $_DRYRUN == true ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on remote host." "NOTICE"
	cmd=$SSH_CMD' "env LC_ALL=C env _REMOTE_TOKEN="'$_REMOTE_TOKEN'" $command" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 0 $hardMaxTime $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
	if [ $retval -eq 0 ]; then
		Logger "Command succeded." "NOTICE"
	else
		Logger "Command failed." "ERROR"
	fi

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ] && ([ $_LOGGER_VERBOSE == true ] || [ $retval -ne 0 ])
	then
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "NOTICE"
	fi

	if [ "$STOP_ON_CMD_ERROR" == "yes" ] && [ $retval -ne 0 ]; then
		Logger "Stopping on command execution error." "CRITICAL"
		exit 1
	fi
}

function RunBeforeHook {

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
		WaitForTaskCompletion $pids 0 0 $SLEEP_TIME $KEEP_LOGGING true true false
	fi
}

function RunAfterHook {

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
		WaitForTaskCompletion $pids 0 0 $SLEEP_TIME $KEEP_LOGGING true true false
	fi
}

function CheckConnectivityRemoteHost {

	local retval


		if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_OPERATION" != "no" ]; then
			eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1" &
			WaitForTaskCompletion $! 60 180 $SLEEP_TIME $KEEP_LOGGING true true false
			retval=$?
			if [ $retval != 0 ]; then
				Logger "Cannot ping [$REMOTE_HOST]. Return code [$retval]." "WARN"
				return $retval
			fi
		fi
}

function CheckConnectivity3rdPartyHosts {

	local remote3rdPartySuccess
	local retval


		if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]; then
			remote3rdPartySuccess=false
			for i in $REMOTE_3RD_PARTY_HOSTS
			do
				eval "$PING_CMD $i > /dev/null 2>&1" &
				WaitForTaskCompletion $! 180 360 $SLEEP_TIME $KEEP_LOGGING true true false
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
}

function RsyncPatternsAdd {
	local patternType="${1}"	# exclude or include
	local pattern="${2}"

	local rest

	# Disable globbing so wildcards from exclusions do not get expanded
	set -f
	rest="$pattern"
	while [ -n "$rest" ]
	do
		# Take the string until first occurence until $PATH_SEPARATOR_CHAR
		str="${rest%%$PATH_SEPARATOR_CHAR*}"
		# Handle the last case
		if [ "$rest" == "${rest/$PATH_SEPARATOR_CHAR/}" ]; then
			rest=
		else
			# Cut everything before the first occurence of $PATH_SEPARATOR_CHAR
			rest="${rest#*$PATH_SEPARATOR_CHAR}"
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

	## Check if the exclude list has a full path, and if not, add the config file path if there is one
	if [ "$(basename $patternFrom)" == "$patternFrom" ]; then
		patternFrom="$(dirname $CONFIG_FILE)/$patternFrom"
	fi

	if [ -e "$patternFrom" ]; then
		RSYNC_PATTERNS="$RSYNC_PATTERNS --"$patternType"-from=\"$patternFrom\""
	fi
}

function RsyncPatterns {

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
		COMMAND_SUDO="sudo -E"
	else
		if [ "$RSYNC_REMOTE_PATH" != "" ]; then
			RSYNC_PATH="$RSYNC_REMOTE_PATH/$RSYNC_EXECUTABLE"
		else
			RSYNC_PATH="$RSYNC_EXECUTABLE"
		fi
		COMMAND_SUDO=""
	fi

	## Set compression executable and extension
	if [ "$(IsInteger $COMPRESSION_LEVEL)" -eq 0 ]; then
		COMPRESSION_LEVEL=3
	fi
}

function PostInit {

	# Define remote commands
	if [ -f "$SSH_RSA_PRIVATE_KEY" ]; then
		SSH_CMD="$(type -p ssh) $SSH_COMP -q -i $SSH_RSA_PRIVATE_KEY $SSH_OPTS $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
		SCP_CMD="$(type -p scp) $SSH_COMP -q -i $SSH_RSA_PRIVATE_KEY -P $REMOTE_PORT"
		RSYNC_SSH_CMD="$(type -p ssh) $SSH_COMP -q -i $SSH_RSA_PRIVATE_KEY $SSH_OPTS -p $REMOTE_PORT"
	elif [ -f "$SSH_PASSWORD_FILE" ]; then
		SSH_CMD="$(type -p sshpass) -f $SSH_PASSWORD_FILE $(type -p ssh) $SSH_COMP -q $SSH_OPTS $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
		SCP_CMD="$(type -p sshpass) -f $SSH_PASSWORD_FILE $(type -p scp) $SSH_COMP -q -P $REMOTE_PORT"
		RSYNC_SSH_CMD="$(type -p sshpass) -f $SSH_PASSWORD_FILE $(type -p ssh) $SSH_COMP -q $SSH_OPTS -p $REMOTE_PORT"
	else
		SSH_PASSWORD=""
		SSH_CMD=""
		SCP_CMD=""
		RSYNC_SSH_CMD=""
	fi
}

function SetCompression {
	## Busybox fix (Termux xz command doesn't support compression at all)
	if [ "$LOCAL_OS" == "BusyBox" ] || [ "$REMOTE_OS" == "Busybox" ] || [ "$LOCAL_OS" == "Android" ] || [ "$REMOTE_OS" == "Android" ]; then
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

	if [ ".${ALERT_LOG_FILE##*.}" != "$COMPRESSION_EXTENSION" ]; then
		ALERT_LOG_FILE="$ALERT_LOG_FILE$COMPRESSION_EXTENSION"
	fi
}

function InitLocalOSDependingSettings {

	## If running under Msys, some commands do not run the same way
	## Using mingw version of find instead of windows one
	## Getting running processes is quite different
	## Ping command is not the same
	if [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
		FIND_CMD=$(dirname $BASH)/find
		PING_CMD='$SYSTEMROOT\system32\ping -n 2'

	# On BSD, when not root, min ping interval is 1s
	elif [ "$LOCAL_OS" == "BSD" ] && [ "$LOCAL_USER" != "root" ]; then
		FIND_CMD=find
		PING_CMD="ping -c 2 -i 1"
	else
		FIND_CMD=find
		PING_CMD="ping -c 2 -i .2"
	fi

	if [ "$LOCAL_OS" == "BusyBox" ] || [ "$LOCAL_OS" == "Android" ] || [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
		PROCESS_STATE_CMD="echo none"
		DF_CMD="df"
	else
		PROCESS_STATE_CMD='ps -p$pid -o state= 2 > /dev/null'
		# CentOS 5 needs -P for one line output
		DF_CMD="df -P"
	fi

	## Stat command has different syntax on Linux and FreeBSD/MacOSX
	if [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "BSD" ]; then
		# Tested on BSD and Mac
		STAT_CMD="stat -f \"%Sm\""
		STAT_CTIME_MTIME_CMD="stat -f %N;%c;%m"
	else
		# Tested on GNU stat, busybox and Cygwin
		STAT_CMD="stat -c %y"
		STAT_CTIME_MTIME_CMD="stat -c %n;%Z;%Y"
	fi

	# Set compression first time when we know what local os we have
	SetCompression
}

# Gets executed regardless of the need of remote connections. It's just that this code needs to get executed after we know if there is a remote os, and if yes, which one
function InitRemoteOSDependingSettings {

	if [ "$REMOTE_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
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

	## Set rsync default arguments
	RSYNC_ARGS="-rltD -8"
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
	if [ "$PRESERVE_EXECUTABILITY" != "no" ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" --executability"
	fi
	if [ "$PRESERVE_ACL" == "yes" ]; then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ] && [ "$LOCAL_OS" != "msys" ] && [ "$REMOTE_OS" != "msys" ] && [ "$LOCAL_OS" != "Cygwin" ] && [ "$REMOTE_OS" != "Cygwin" ] && [ "$LOCAL_OS" != "BusyBox" ] && [ "$REMOTE_OS" != "BusyBox" ] && [ "$LOCAL_OS" != "Android" ] && [ "$REMOTE_OS" != "Android" ]; then
			RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -A"
		else
			Logger "Disabling ACL synchronization on [$LOCAL_OS] due to lack of support." "NOTICE"

		fi
	fi
	if [ "$PRESERVE_XATTR" == "yes" ]; then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ] && [ "$LOCAL_OS" != "msys" ] && [ "$REMOTE_OS" != "msys" ] && [ "$LOCAL_OS" != "Cygwin" ] && [ "$REMOTE_OS" != "Cygwin" ] && [ "$LOCAL_OS" != "BusyBox" ] && [ "$REMOTE_OS" != "BusyBox" ]; then
			RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -X"
		else
			Logger "Disabling extended attributes synchronization on [$LOCAL_OS] due to lack of support." "NOTICE"
		fi
	fi
	if [ "$RSYNC_COMPRESS" == "yes" ]; then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ]; then
			RSYNC_ARGS=$RSYNC_ARGS" -zz --skip-compress=gz/xz/lz/lzma/lzo/rz/jpg/mp3/mp4/7z/bz2/rar/zip/sfark/s7z/ace/apk/arc/cab/dmg/jar/kgb/lzh/lha/lzx/pak/sfx"
		else
			Logger "Disabling compression skips on synchronization on [$LOCAL_OS] due to lack of support." "NOTICE"
		fi
	fi
	if [ "$COPY_SYMLINKS" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -L"
	fi
	if [ "$KEEP_DIRLINKS" == "yes" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" -K"
	fi
	if [ "$RSYNC_OPTIONAL_ARGS" != "" ]; then
		RSYNC_ARGS=$RSYNC_ARGS" "$RSYNC_OPTIONAL_ARGS
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

	# Set compression options again after we know what remote OS we're dealing with
	SetCompression
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

# Neat version compare function found at http://stackoverflow.com/a/4025065/2635443
# Returns 0 if equal, 1 if $1 > $2 and 2 if $1 < $2
function VerComp () {
	if [ "$1" == "" ] || [ "$2" == "" ]; then
		Logger "Bogus Vercomp values [$1] and [$2]." "WARN"
		return 1
	fi

	if [[ $1 == $2 ]]
		then
			echo 0
		return
	fi

	local IFS=.
	local i ver1=($1) ver2=($2)
	# fill empty fields in ver1 with zeros
	for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
	do
        	ver1[i]=0
	done
	for ((i=0; i<${#ver1[@]}; i++))
	do
		if [[ -z ${ver2[i]} ]]
		then
			# fill empty fields in ver2 with zeros
			ver2[i]=0
		fi
		if ((10#${ver1[i]} > 10#${ver2[i]}))
		then
			echo 1
			return
        	fi
        	if ((10#${ver1[i]} < 10#${ver2[i]}))
        	then
			echo 2
            		return
        	fi
    	done

    	echo 0
	return
}

function GetConfFileValue () {
        local file="${1}"
        local name="${2}"
        local value

        value=$(grep "^$name=" "$file")
        if [ $? == 0 ]; then
                value="${value##*=}"
                echo "$value"
        else
		Logger "Cannot get value for [$name] in config file [$file]." "ERROR"
        fi
}

function SetConfFileValue () {
        local file="${1}"
        local name="${2}"
        local value="${3}"
	local separator="${4:-#}"

        if grep "^$name=" "$file" > /dev/null; then
                # Using -i.tmp for BSD compat
                sed -i.tmp "s$separator^$name=.*$separator$name=$value$separator" "$file"
                rm -f "$file.tmp"
		Logger "Set [$name] to [$value] in config file [$file]." "DEBUG"
        else
		Logger "Cannot set value [$name] to [$value] in config file [$file]." "ERROR"
        fi
}

# Function can replace [ -f /some/file* ] tests
# Modified version of http://stackoverflow.com/a/6364244/2635443
function WildcardFileExists () {
        local file="${1}"
        local exists=0

        for f in $file; do
                ## Check if the glob gets expanded to existing files.
                ## If not, f here will be exactly the pattern above
                ## and the exists test will evaluate to false.
                if [ -e "$f" ]; then
                        exists=1
                        break
                fi
        done

        if [ $exists -eq 1 ]; then
                echo 1
        else
                echo 0
        fi
}

# If using "include" statements, make sure the script does not get executed unless it's loaded by bootstrap
_OFUNCTIONS_BOOTSTRAP=true
[ "$_OFUNCTIONS_BOOTSTRAP" != true ] && echo "Please use bootstrap.sh to load this dev version of $(basename $0)" && exit 1

_LOGGER_PREFIX="time"

## Working directory. This directory exists in any replica and contains state files, backups, soft deleted files etc
OSYNC_DIR=".osync_workdir"

function TrapQuit {
	local exitcode

	# Get ERROR / WARN alert flags from subprocesses that call Logger
	if [ -f "$RUN_DIR/$PROGRAM.Logger.warn.$SCRIPT_PID.$TSTAMP" ]; then
		WARN_ALERT=true
	fi
	if [ -f "$RUN_DIR/$PROGRAM.Logger.error.$SCRIPT_PID.$TSTAMP" ]; then
		ERROR_ALERT=true
	fi

	if [ $ERROR_ALERT == true ]; then
		Logger "$PROGRAM finished with errors." "ERROR"
		if [ "$_DEBUG" != "yes" ]
		then
			SendAlert
		else
			Logger "Debug mode, no alert mail will be sent." "NOTICE"
		fi
		exitcode=1
	elif [ $WARN_ALERT == true ]; then
		Logger "$PROGRAM finished with warnings." "WARN"
		if [ "$_DEBUG" != "yes" ]
		then
			SendAlert
		else
			Logger "Debug mode, no alert mail will be sent." "NOTICE"
		fi
		exitcode=2	# Warning exit code must not force daemon mode to quit
	else
		Logger "$PROGRAM finished." "ALWAYS"
		exitcode=0
	fi
	CleanUp
	KillChilds $SCRIPT_PID > /dev/null 2>&1

	exit $exitcode
}

function CheckEnvironment {

	if ! type ssh > /dev/null 2>&1 ; then
		Logger "ssh not present. Cannot start sync." "CRITICAL"
		exit 1
	fi

	if [ "$SSH_PASSWORD_FILE" != "" ] && ! type sshpass > /dev/null 2>&1 ; then
		Logger "sshpass not present. Cannot use password authentication." "CRITICAL"
		exit 1
	fi
}

# Only gets checked in config file mode where all values should be present
function CheckCurrentConfig {

	# Check all variables that should contain "yes" or "no"
	declare -a yes_no_vars=(SUDO_EXEC SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING)
	for i in "${yes_no_vars[@]}"; do
		test="if [ \"\$$i\" != \"yes\" ] && [ \"\$$i\" != \"no\" ]; then Logger \"Bogus $i value [\$$i] defined in config file. Correct your config file or update it using the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done

	# Check all variables that should contain a numerical value >= 0
	declare -a num_vars=(MIN_WAIT MAX_WAIT)
	for i in "${num_vars[@]}"; do
		test="if [ $(IsNumericExpand \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value [\$$i] defined in config file. Correct your config file or update it using the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done
}

# Gets checked in quicksync and config file mode
function CheckCurrentConfigAll {

	local tmp

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

	if ([ ! -f "$SSH_RSA_PRIVATE_KEY" ] && [ ! -f "$SSH_PASSWORD_FILE" ]); then
		Logger "Cannot find rsa private key [$SSH_RSA_PRIVATE_KEY] nor password file [$SSH_PASSWORD_FILE]. No authentication method provided." "CRITICAL"
		exit 1
	fi
}

function TriggerInitiatorUpdate {

$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" env INSTANCE_ID="'$INSTANCE_ID'" \
env PUSH_FILE="'$(EscapeSpaces "${INITIATOR[$__updateTriggerFIle]}")'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1

## allow debugging from command line with _DEBUG=yes
if [ ! "$_DEBUG" == "yes" ]; then
	_DEBUG=no
	_LOGGER_VERBOSE=false
else
	trap 'TrapError ${LINENO} $?' ERR
	_LOGGER_VERBOSE=true
fi

if [ "$SLEEP_TIME" == "" ]; then # Leave the possibity to set SLEEP_TIME as environment variable when runinng with bash -x in order to avoid spamming console
	SLEEP_TIME=.05
fi
function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
	fi
}

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
		# Current log file
		echo -e "$logValue" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
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

	if [ "$_LOGGER_PREFIX" == "time" ]; then
		prefix="TIME: $SECONDS - "
	elif [ "$_LOGGER_PREFIX" == "date" ]; then
		prefix="R $(date) - "
	else
		prefix=""
	fi

	if [ "$level" == "CRITICAL" ]; then
		_Logger "" "$prefix\e[1;33;41m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "ERROR" ]; then
		_Logger "" "$prefix\e[91m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
			_Logger -e "" "[$retval] in [$(joinString , ${FUNCNAME[@]})] SP=$SCRIPT_PID P=$$" true
		fi
		return
	elif [ "$level" == "WARN" ]; then
		_Logger "" "$prefix\e[33m$value\e[0m" true
		if [ $_DEBUG == "yes" ]; then
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
		_Logger  "" "$prefix$value"
		return
	elif [ "$level" == "DEBUG" ]; then
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "" "$prefix$value"
			return
		fi
	else
		_Logger "" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "" "Value was: $prefix$value" true
	fi
}

	echo "$INSTANCE_ID $(date '+%Y%m%dT%H%M%S.%N')" >> "$PUSH_FILE"
ENDSSH

	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ] || [ $? != 0 ]; then
		(
		_LOGGER_PREFIX="RR"
		Logger "$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "ERROR"
		)
		return 1
	fi
	return 0
}

function Init {

	# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace

	trap TrapQuit TERM EXIT HUP QUIT

	local uri
	local hosturiandpath
	local hosturi


	## Test if target dir is a ssh uri, and if yes, break it down it its values
	if [ "${INITIATOR_SYNC_DIR:0:6}" == "ssh://" ]; then
		REMOTE_OPERATION="yes"

		# remove leadng 'ssh://'
		uri=${INITIATOR_SYNC_DIR#ssh://*}
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
		Logger "No valid remote initiator URI found in [$INITIATOR_SYNC_DIR]." "CRITICAL"
		exit 1
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
	readonly __timestampCurrentFile=16
	readonly __timestampAfterFile=17
	readonly __timestampAfterFileNoSuffix=18
	readonly __conflictListFile=19
	readonly __updateTriggerFile=20


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
	INITIATOR[$__timestampCurrentFile]="-timestamps-current-$INSTANCE_ID$drySuffix"
	INITIATOR[$__timestampAfterFile]="-timestamps-after-$INSTANCE_ID$drySuffix"
	INITIATOR[$__timestampAfterFileNoSuffix]="-timestamps-after-$INSTANCE_ID"
	INITIATOR[$__conflictListFile]="conflicts-$INSTANCE_ID$drySuffix"
	INITIATOR[$__updateTriggerFile]="$INITIATOR_SYNC_DIR$OSYNC_DIR/.osnyc-update.push"

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
	TARGET[$__timestampCurrentFile]="-timestamps-current-$INSTANCE_ID$drySuffix"
	TARGET[$__timestampAfterFile]="-timestamps-after-$INSTANCE_ID$drySuffix"
	TARGET[$__timestampAfterFileNoSuffix]="-timestamps-after-$INSTANCE_ID"
	TARGET[$__conflictListFile]="conflicts-$INSTANCE_ID$drySuffix"
	TARGET[$__updateTriggerFile]="$TARGET_SYNC_DIR$OSYNC_DIR/.osync-update.push"
}

function Usage {

	if [ "$IS_STABLE" != "yes" ]; then
		echo -e "\e[93mThis is an unstable dev build. Please use with caution.\e[0m"
	fi

	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo "$CONTACT"
	echo ""
	echo "You must use $PROGRAM with a full blown configuration file."
	echo "Usage: $0 /path/to/config/file [OPTIONS]"
	echo ""
	echo "[OPTIONS]"
	echo "--no-prefix            Will suppress time / date suffix from output"
	echo "--silent               Will run osync without any output to stdout, used for cron jobs"
	echo "--errors-only          Output only errors (can be combined with silent or verbose)"
	echo "--verbose              Increases output"
	echo "--on-changes           Will launch a sync task after a short wait period if there is some file activity on initiator replica. You should try daemon mode instead"
	echo ""
	exit 128
}

function OnChangesHelper {

	local cmd
	local retval

	if [ "$LOCAL_OS" == "MacOSX" ]; then
		if ! type fswatch > /dev/null 2>&1 ; then
			Logger "No inotifywait command found. Cannot monitor changes." "CRITICAL"
			exit 1
		fi
	else
		if ! type inotifywait > /dev/null 2>&1 ; then
			Logger "No inotifywait command found. Cannot monitor changes." "CRITICAL"
			exit 1
		fi
	fi

	if [ ! -d "$TARGET_SYNC_DIR" ]; then
		Logger "Target directory [$TARGET_SYNC_DIR] does not exist. Cannot monitor." "CRITICAL"
		exit 1
	fi

	Logger "#### Running $PROGRAM in file monitor mode." "NOTICE"

	while true; do
		if [ "$LOCAL_OS" == "MacOSX" ]; then
			fswatch $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude "$OSYNC_DIR" -1 "$TARGET_SYNC_DIR" > /dev/null &
			# Mac fswatch doesn't have timeout switch, replacing wait $! with WaitForTaskCompletion without warning nor spinner and increased SLEEP_TIME to avoid cpu hogging. This sims wait $! with timeout
			WaitForTaskCompletion $! 0 $MAX_WAIT 1 0 true false true
		else
			inotifywait $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude "$OSYNC_DIR" -qq -r -e create -e modify -e delete -e move -e attrib --timeout "$MAX_WAIT" "$TARGET_SYNC_DIR" &
			wait $!
		fi
		retval=$?
		if [ $retval -eq 0 ]; then
			Logger "#### Changes detected, waiting $MIN_WAIT seconds before triggering update on initiator." "NOTICE"
			sleep $MIN_WAIT
		# inotifywait --timeout result is 2, WaitForTaskCompletion HardTimeout is 1
		elif [ "$LOCAL_OS" == "MacOSX" ]; then
			Logger "#### Changes or error detected, waiting $MIN_WAIT seconds before triggering update on initiator." "NOTICE"
		elif [ $retval -eq 2 ]; then
			Logger "#### $MAX_WAIT timeout reached, running sync." "NOTICE"
		elif [ $retval -eq 1 ]; then
			Logger "#### inotify error detected, waiting $MIN_WAIT seconds before triggering update on initiator." "ERROR" $retval
			sleep $MIN_WAIT
		fi

		TriggerInitiatorUpdate
	done

}

#### SCRIPT ENTRY POINT

DESTINATION_MAILS=""
ERROR_ALERT=false
WARN_ALERT=false

if [ $# -eq 0 ]
then
	Usage
fi

first=1
for i in "$@"; do
	case $i in
		--silent)
		_LOGGER_SILENT=true
		;;
		--verbose)
		_LOGGER_VERBOSE=true
		;;
		--help|-h|--version|-v)
		Usage
		;;
		--errors-only)
		_LOGGER_ERR_ONLY=true
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

ConfigFile="${1}"
LoadConfigFile "$ConfigFile"

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
InitLocalOSDependingSettings
PreInit
Init
CheckEnvironment
PostInit
CheckCurrentConfig
CheckCurrentConfigAll
DATE=$(date)
Logger "-------------------------------------------------------------" "NOTICE"
Logger "$DRY_WARNING$DATE - $PROGRAM $PROGRAM_VERSION script begin." "ALWAYS"
Logger "-------------------------------------------------------------" "NOTICE"
Logger "Sync task [$INSTANCE_ID] launched as $LOCAL_USER@$LOCAL_HOST (PID $SCRIPT_PID)" "NOTICE"

OnChangesHelper
