#!/usr/bin/env bash
#### OFUNCTIONS FULL SUBSET ####
#### OFUNCTIONS MINI SUBSET ####

#TODO: ExecTasks postponed arrays / files grow a lot. Consider having them "rolling"
#done: add checkRFC function (and use it for --destination-mails)
#done: ExecTasks still needs some better call argument list
#done: ExecTasks sub function relocate
#done: SendMail and SendEmail convert functions inverted, check on osync and obackup
#command line arguments don't take -AaqV for example

_OFUNCTIONS_VERSION=2.3.0-dev
_OFUNCTIONS_BUILD=2018031501
#### _OFUNCTIONS_BOOTSTRAP SUBSET ####
_OFUNCTIONS_BOOTSTRAP=true
#### _OFUNCTIONS_BOOTSTRAP SUBSET END ####

## BEGIN Generic bash functions written in 2013-2017 by Orsiris de Jong - http://www.netpower.fr - ozy@netpower.fr

## To use in a program, define the following variables:
## PROGRAM=program-name
## INSTANCE_ID=program-instance-name
## _DEBUG=yes/no
## _LOGGER_SILENT=true/false
## _LOGGER_VERBOSE=true/false
## _LOGGER_ERR_ONLY=true/false
## _LOGGER_PREFIX="date"/"time"/""

#TODO: global WAIT_FOR_TASK_COMPLETION_id instead of callerName has to be backported to ParallelExec and osync / obackup / pmocr ocde

## Logger sets {ERROR|WARN}_ALERT variable when called with critical / error / warn loglevel
## When called from subprocesses, variable of main process cannot be set. Status needs to be get via $RUN_DIR/$PROGRAM.Logger.{error|warn}.$SCRIPT_PID.$TSTAMP

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

#### DEBUG SUBSET ####
## allow function call checks			#__WITH_PARANOIA_DEBUG
if [ "$_PARANOIA_DEBUG" == "yes" ];then		#__WITH_PARANOIA_DEBUG
	_DEBUG=yes				#__WITH_PARANOIA_DEBUG
fi						#__WITH_PARANOIA_DEBUG

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
#### DEBUG SUBSET END ####

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
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	sleep $SLEEP_TIME
}

#### Logger SUBSET ####
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
	elif [ "$level" == "PARANOIA_DEBUG" ]; then				#__WITH_PARANOIA_DEBUG
		if [ "$_PARANOIA_DEBUG" == "yes" ]; then			#__WITH_PARANOIA_DEBUG
			_Logger "" "$prefix\e[35m$value\e[0m"			#__WITH_PARANOIA_DEBUG
			return							#__WITH_PARANOIA_DEBUG
		fi								#__WITH_PARANOIA_DEBUG
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
		if [ "$_DEBUG" == "yes" ]; then
			_Logger "$prefix$value" "$prefix$value"
			return
		fi
	elif [ "$level" == "PARANOIA_DEBUG" ]; then				#__WITH_PARANOIA_DEBUG
		if [ "$_PARANOIA_DEBUG" == "yes" ]; then			#__WITH_PARANOIA_DEBUG
			_Logger "$prefix$value" "$prefix\e[35m$value\e[0m"	#__WITH_PARANOIA_DEBUG
			return							#__WITH_PARANOIA_DEBUG
		fi								#__WITH_PARANOIA_DEBUG
	else
		_Logger "\e[41mLogger function called without proper loglevel [$level].\e[0m" "\e[41mLogger function called without proper loglevel [$level].\e[0m" true
		_Logger "Value was: $prefix$value" "Value was: $prefix$value" true
	fi
}
#### Logger SUBSET END ####

#### QuickLogger SUBSET ####
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
#### QuickLogger SUBSET END ####

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
		# Warning: pgrep is not native on cygwin, have this checked in CheckEnvironment
		if children="$(pgrep -P "$pid")"; then
			if [[ "$pid" == *"$children"* ]]; then
				Logger "Bogus pgrep implementation." "CRITICAL"
				children="${children/$pid/}"
			fi
			for child in $children; do
				Logger "Launching KillChilds \"$child\" true" "DEBUG"	#__WITH_PARANOIA_DEBUG
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

	__CheckArguments 1 $# "$@"	#__WITH_PARANOIA_DEBUG

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

	__CheckArguments 0-1 $# "$@"	#__WITH_PARANOIA_DEBUG

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

	body="$MAIL_ALERT_MSG"$'\n\n'"Last 1000 lines of log"$'\n\n'"$(tail -n 1000 $RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP)"

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

	__CheckArguments 3-10 $# "$@"	#__WITH_PARANOIA_DEBUG

	local mail_no_attachment=
	local attachment_command=

	local encryption_string=
	local auth_string=

	local i

	for i in "${destinationMails}"; do
		if [ $(CheckRFC822 "$i") -ne 1 ]; then
			Logger "Given email [$i] does not seem to be valid." "WARN"
		fi
	done

	# Prior to sending an email, convert its body if needed
	if [ "$MAIL_BODY_CHARSET" != "" ]; then
		if type iconv > /dev/null 2>&1; then
			echo "$message" | iconv -f UTF-8 -t $MAIL_BODY_CHARSET -o "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.iconv.$SCRIPT_PID.$TSTAMP"
			message="$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.iconv.$SCRIPT_PID.$TSTAMP)"
		else
			Logger "iconv utility not installed. Will not convert email charset." "NOTICE"
		fi
	fi

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
				# Do not bother try other mail systems with busybox
				return 1
			else
				return 0
			fi
		else
			Logger "Sendmail not present. Will not send any mail" "WARN"
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

#### TrapError SUBSET ####
function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
	fi
}
#### TrapError SUBSET END ####

function LoadConfigFile {
	local configFile="${1}"

	__CheckArguments 1 $# "$@"	#__WITH_PARANOIA_DEBUG


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

# Quick and dirty performance logger only used for debugging
function _PerfProfiler {												#__WITH_PARANOIA_DEBUG
	local perfString												#__WITH_PARANOIA_DEBUG
	local i														#__WITH_PARANOIA_DEBUG
															#__WITH_PARANOIA_DEBUG
	perfString=$(ps -p $$ -o args,pid,ppid,%cpu,%mem,time,etime,state,wchan)					#__WITH_PARANOIA_DEBUG
															#__WITH_PARANOIA_DEBUG
	for i in $(pgrep -P $$); do											#__WITH_PARANOIA_DEBUG
		perfString="$perfString\n"$(ps -p $i -o args,pid,ppid,%cpu,%mem,time,etime,state,wchan | tail -1)	#__WITH_PARANOIA_DEBUG
	done														#__WITH_PARANOIA_DEBUG
															#__WITH_PARANOIA_DEBUG
	if type iostat > /dev/null 2>&1; then										#__WITH_PARANOIA_DEBUG
		perfString="$perfString\n"$(iostat)									#__WITH_PARANOIA_DEBUG
	fi														#__WITH_PARANOIA_DEBUG
															#__WITH_PARANOIA_DEBUG
	Logger "PerfProfiler:\n$perfString" "PARANOIA_DEBUG"								#__WITH_PARANOIA_DEBUG
}															#__WITH_PARANOIA_DEBUG

_OFUNCTIONS_SPINNER="|/-\\"
function Spinner {
	if [ $_LOGGER_SILENT == true ] || [ "$_LOGGER_ERR_ONLY" == true ]; then
		return 0
	else
		printf " [%c]  \b\b\b\b\b\b" "$_OFUNCTIONS_SPINNER"
		_OFUNCTIONS_SPINNER=${_OFUNCTIONS_SPINNER#?}${_OFUNCTIONS_SPINNER%%???}
		return 0
	fi
}

# WaitForTaskCompletion function emulation, now uses ExecTasks
function WaitForTaskCompletion {
	local pids="${1}"
	local softMaxTime="${2:-0}"
	local hardMaxTime="${3:-0}"
	local sleepTime="${4:-.05}"
	local keepLogging="${5:-0}"
	local counting="${6:-true}"
	local spinner="${7:-true}"
	local noErrorLog="${8:-false}"
	local id="${9-base}"

	ExecTasks "$pids" "$id" false 0 0 "$softMaxTime" "$hardMaxTime" "$counting" "$sleepTime" "$keepLogging" "$spinner" "$noErrorlog"
}

# ParallelExec function emulation, now uses ExecTasks
function ParallelExec {
	local numberOfProcesses="${1}"
	local commandsArg="${2}"
	local readFromFile="${3:-false}"
	local softMaxTime="${4:-0}"
	local hardMaxTime="${5:-0}"
	local sleepTime="${6:-.05}"
	local keepLogging="${7:-0}"
	local counting="${8:-true}"
	local spinner="${9:-false}"
	local noErrorLog="${10:-false}"

	if [ $readFromFile == true ]; then
		ExecTasks "$commandsArg" "base" $readFromFile 0 0 "$softMaxTime" "$hardMaxTime" "$counting" "$sleepTime" "$keepLogging" "$spinner" "$noErrorLog" false "$numberOfProcesses"
	else
		ExecTasks "$commandsArg" "base" $readFromFile 0 0 "$softMaxTime" "$hardMaxTime" "$counting" "$sleepTime" "$keepLogging" "$spinner" "$noErrorLog" false "$numberOfProcesses"
	fi
}

## Main asynchronous execution function
## Function can work in:
## WaitForTaskCompletion mode: monitors given pid in background, and stops them if max execution time is reached. Suitable for multiple synchronous pids to monitor and wait for
## ParallExec mode: takes list of commands to execute in parallel per batch, and stops them if max execution time is reahed.

## Example of improved wait $!
## ExecTasks $! "some_identifier" false 0 0 0 0 true 1 1800 false
## Example: monitor two sleep processes, warn if execution time is higher than 10 seconds, stop after 20 seconds
## sleep 15 &
## pid=$!
## sleep 20 &
## pid2=$!
## ExecTasks "some_identifier" 0 0 10 20 1 1800 true true false false 1 "$pid;$pid2"

## Example of parallel execution of four commands, only if directories exist. Warn if execution takes more than 300 seconds. Stop if takes longer than 900 seconds. Exeute max 3 commands in parallel.
## commands="du -csh /var;du -csh /etc;du -csh /home;du -csh /usr"
## conditions="[ -d /var ];[ -d /etc ];[ -d /home];[ -d /usr]"
## ExecTasks "$commands" "some_identifier" false 0 0 300 900 true 1 1800 true false false 3 "$conditions"

## Bear in mind that given commands and conditions need to be quoted

## ExecTasks has the following ofunctions subfunction requirements:
## Spinner
## Logger
## JoinString
## KillChilds

## Full call
##ExecTasks "$mainInput" "$id" $readFromFile $softPerProcessTime $hardPerProcessTime $softMaxTime $hardMaxTime $counting $sleepTime $keepLogging $spinner $noTimeErrorLog $noErrorLogsAtAll $numberOfProcesses $auxInput $maxPostponeRetries $minTimeBetweenRetries $validExitCodes

function ExecTasks {
	# Mandatory arguments
	local mainInput="${1}"                          # Contains list of pids / commands separated by semicolons or filepath to list of pids / commands

	# Optional arguments
	local id="${2:-base}"                           # Optional ID in order to identify global variables from this run (only bash variable names, no '-'). Global variables are WAIT_FOR_TASK_COMPLETION_$id and HARD_MAX_EXEC_TIME_REACHED_$id
	local readFromFile="${3:-false}"                # Is mainInput / auxInput a semicolon separated list (true) or a filepath (false)
	local softPerProcessTime="${4:-0}"              # Max time (in seconds) a pid or command can run before a warning is logged, unless set to 0
	local hardPerProcessTime="${5:-0}"              # Max time (in seconds) a pid or command can run before the given command / pid is stopped, unless set to 0
	local softMaxTime="${6:-0}"                     # Max time (in seconds) for the whole function to run before a warning is logged, unless set to 0
	local hardMaxTime="${7:-0}"                     # Max time (in seconds) for the whole function to run before all pids / commands given are stopped, unless set to 0
	local counting="${8:-true}"                     # Should softMaxTime and hardMaxTime be accounted since function begin (true) or since script begin (false)
	local sleepTime="${9:-.5}"                      # Seconds between each state check. The shorter the value, the snappier ExecTasks will be, but as a tradeoff, more cpu power will be used (good values are between .05 and 1)
	local keepLogging="${10:-1800}"                 # Every keepLogging seconds, an alive message is logged. Setting this value to zero disables any alive logging
	local spinner="${11:-true}"                     # Show spinner (true) or do not show anything (false) while running
	local noTimeErrorLog="${12:-false}"             # Log errors when reaching soft / hard execution times (false) or do not log errors on those triggers (true)
	local noErrorLogsAtAll="${13:-false}"           # Do not log any errros at all (useful for recursive ExecTasks checks)

	# Parallelism specific arguments
	local numberOfProcesses="${14:-0}"              # Number of simulanteous commands to run, given as mainInput. Set to 0 by default (WaitForTaskCompletion mode). Setting this value enables ParallelExec mode.
	local auxInput="${15}"                          # Contains list of commands separated by semicolons or filepath fo list of commands. Exit code of those commands decide whether main commands will be executed or not
	local maxPostponeRetries="${16:-3}"             # If a conditional command fails, how many times shall we try to postpone the associated main command. Set this to 0 to disable postponing
	local minTimeBetweenRetries="${17:-300}"        # Time (in seconds) between postponed command retries
	local validExitCodes="${18:-0}"                 # Semi colon separated list of valid main command exit codes which will not trigger errors

	local i

	Logger "${FUNCNAME[0]} called by [${FUNCNAME[0]} < ${FUNCNAME[1]} < ${FUNCNAME[2]} < ${FUNCNAME[3]} < ${FUNCNAME[4]} ...]." "PARANOIA_DEBUG"     #__WITH_PARANOIA_DEBUG
	__CheckArguments 1-18 $# "$@"                                                                                                                                          #__WITH_PARANOIA_DEBUG

	# Since ExecTasks takes up to 17 arguments, do a quick preflight check in DEBUG mode
	if [ "$_DEBUG" == "yes" ]; then
		declare -a booleans=(readFromFile counting spinner noTimeErrorLog noErrorLogsAtAll)
		for i in "${booleans[@]}"; do
			test="if [ \$$i != false ] && [ \$$i != true ]; then Logger \"Bogus $i value [\$$i] given to ${FUNCNAME[0]}.\" \"CRITICAL\"; exit 1; fi"
			eval "$test"
		done
		declare -a integers=(softPerProcessTime hardPerProcessTime softMaxTime hardMaxTime keepLogging numberOfProcesses maxPostponeRetries minTimeBetweenRetries)
		for i in "${integers[@]}"; do
			test="if [ $(IsNumericExpand \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value [\$$i] given to ${FUNCNAME[0]}.\" \"CRITICAL\"; exit 1; fi"
			eval "$test"
		done
	fi

	# Change '-' to '_' in task id
	id="${id/-/_}"

	# Expand validExitCodes into array
	IFS=';' read -r -a validExitCodes <<< "$validExitCodes"

	# ParallelExec specific variables
	local auxItemCount=0            # Number of conditional commands
	local commandsArray=()          # Array containing commands
	local commandsConditionArray=() # Array containing conditional commands
	local currentCommand            # Variable containing currently processed command
	local currentCommandCondition   # Variable containing currently processed conditional command
	local commandsArrayPid=()       # Array containing pids of commands currently run
	local postponedRetryCount=0     # Number of current postponed commands retries
	local postponedItemCount=0      # Number of commands that have been postponed (keep at least one in order to check once)
	local postponedCounter=0
	local isPostponedCommand=false  # Is the current command from a postponed file ?
	local postponedExecTime=0       # How much time has passed since last postponed condition was checked
	local needsPostponing           # Does currentCommand need to be postponed
	local temp

	# Common variables
	local pid                       # Current pid working on
	local pidState                  # State of the process
	local mainItemCount=0           # number of given items (pids or commands)
	local readFromFile              # Should we read pids / commands from a file (true)
	local counter=0
	local log_ttime=0               # local time instance for comparaison

	local seconds_begin=$SECONDS    # Seconds since the beginning of the script
	local exec_time=0               # Seconds since the beginning of this function

	local retval=0                  # return value of monitored pid process
	local subRetval=0               # return value of condition commands
	local errorcount=0              # Number of pids that finished with errors
	local pidsArray                 # Array of currently running pids
	local newPidsArray              # New array of currently running pids for next iteration
	local pidsTimeArray             # Array containing execution begin time of pids
	local executeCommand            # Boolean to check if currentCommand can be executed given a condition

	local hasPids=false             # Are any valable pids given to function ?              #__WITH_PARANOIA_DEBUG

	local functionMode

	if [ $counting == true ]; then
		local softAlert=false # Does a soft alert need to be triggered, if yes, send an alert once
	else
		local softAlert=false
	fi

	# Initialise global variable
	eval "WAIT_FOR_TASK_COMPLETION_$id=\"\""
	eval "HARD_MAX_EXEC_TIME_REACHED_$id=false"

	# Init function variables depending on mode

	if [ $numberOfProcesses -gt 0 ]; then
		functionMode=ParallelExec
	else
		functionMode=WaitForTaskCompletion
	fi

	if [ $readFromFile == false ]; then
		if [ $functionMode == "WaitForTaskCompletion" ]; then
			IFS=';' read -r -a pidsArray <<< "$mainInput"
			mainItemCount="${#pidsArray[@]}"
		else
			IFS=';' read -r -a commandsArray <<< "$mainInput"
			mainItemCount="${#commandsArray[@]}"
			IFS=';' read -r -a commandsConditionArray <<< "$auxInput"
			auxItemCount="${#commandsConditionArray[@]}"
		fi
	else
		if [ -f "$mainInput" ]; then
			mainItemCount=$(wc -l < "$mainInput")
			readFromFile=true
		else
			Logger "Cannot read main file [$mainInput]." "WARN"
		fi
		if [ "$auxInput" != "" ]; then
			if [ -f "$auxInput" ]; then
				auxItemCount=$(wc -l < "$auxInput")
			else
				Logger "Cannot read aux file [$auxInput]." "WARN"
			fi
		fi
	fi

	if [ $functionMode == "WaitForTaskCompletion" ]; then
		# Force first while loop condition to be true because we don't deal with counters but pids in WaitForTaskCompletion mode
		counter=$mainItemCount
	fi

	Logger "Running ${FUNCNAME[0]} as [$functionMode] for [$mainItemCount] mainItems and [$auxItemCount] auxItems." "PARANOIA_DEBUG"              #__WITH_PARANOIA_DEBUG

	# soft / hard execution time checks that needs to be a subfunction since it is called both from main loop and from parallelExec sub loop
	function _ExecTasksTimeCheck {
		if [ $spinner == true ]; then
			Spinner
		fi
		if [ $counting == true ]; then
			exec_time=$((SECONDS - seconds_begin))
		else
			exec_time=$SECONDS
		fi

		if [ $keepLogging -ne 0 ]; then
			if [ $(((exec_time + 1) % keepLogging)) -eq 0 ]; then
				if [ $log_ttime -ne $exec_time ]; then # Fix when sleep time lower than 1 second
					log_ttime=$exec_time
					if [ $functionMode == "Wait" ]; then
						Logger "Current tasks still running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
					elif [ $functionMode == "ParallelExec" ]; then
						Logger "There are $((mainItemCount-counter+postponedItemCount)) / $mainItemCount tasks in the queue. Currently, ${#pidsArray[@]} tasks running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
					fi
				fi
			fi
		fi

		if [ $exec_time -gt $softMaxTime ]; then
			if [ "$softAlert" != true ] && [ $softMaxTime -ne 0 ] && [ $noTimeErrorLog != true ]; then
				Logger "Max soft execution time [$softMaxTime] exceeded for task [$id] with pids [$(joinString , ${pidsArray[@]})]." "WARN"
				softAlert=true
				SendAlert true
			fi
		fi

		if [ $exec_time -gt $hardMaxTime ] && [ $hardMaxTime -ne 0 ]; then
			if [ $noTimeErrorLog != true ]; then
				Logger "Max hard execution time [$hardMaxTime] exceeded for task [$id] with pids [$(joinString , ${pidsArray[@]})]. Stopping task execution." "ERROR"
			fi
			for pid in "${pidsArray[@]}"; do
				KillChilds $pid true
				if [ $? == 0 ]; then
					Logger "Task with pid [$pid] stopped successfully." "NOTICE"
				else
					if [ $noErrorLogsAtAll != true ]; then
						Logger "Could not stop task with pid [$pid]." "ERROR"
					fi
				fi
				errorcount=$((errorcount+1))
			done
			if [ $noTimeErrorLog != true ]; then
				SendAlert true
			fi
			eval "HARD_MAX_EXEC_TIME_REACHED_$id=true"
			if [ $functionMode == "WaitForTaskCompletion" ]; then
				return $errorcount
			else
				return 129
			fi
		fi
	}

	function _ExecTasksPidsCheck {
		newPidsArray=()

		for pid in "${pidsArray[@]}"; do
			if [ $(IsInteger $pid) -eq 1 ]; then
				if kill -0 $pid > /dev/null 2>&1; then
					# Handle uninterruptible sleep state or zombies by ommiting them from running process array (How to kill that is already dead ? :)
					pidState="$(eval $PROCESS_STATE_CMD)"
					if [ "$pidState" != "D" ] && [ "$pidState" != "Z" ]; then

						# Check if pid hasn't run more than soft/hard perProcessTime
						pidsTimeArray[$pid]=$((SECONDS - seconds_begin))
						if [ ${pidsTimeArray[$pid]} -gt $softPerProcessTime ]; then
							if [ "$softAlert" != true ] && [ $softPerProcessTime -ne 0 ] && [ $noTimeErrorLog != true ]; then
								Logger "Max soft execution time [$softPerProcessTime] exceeded for pid [$pid]." "WARN"
								if [ "${commandsArrayPid[$pid]}]" != "" ]; then
									Logger "Command was [${commandsArrayPid[$pid]}]]." "WARN"
								fi
								softAlert=true
								SendAlert true
							fi
						fi


						if [ ${pidsTimeArray[$pid]} -gt $hardPerProcessTime ] && [ $hardPerProcessTime -ne 0 ]; then
							if [ $noTimeErrorLog != true ] && [ $noErrorLogsAtAll != true ]; then
								Logger "Max hard execution time [$hardPerProcessTime] exceeded for pid [$pid]. Stopping command execution." "ERROR"
								if [ "${commandsArrayPid[$pid]}]" != "" ]; then
									Logger "Command was [${commandsArrayPid[$pid]}]]." "WARN"
								fi
							fi
							KillChilds $pid true
							if [ $? == 0 ]; then
								 Logger "Command with pid [$pid] stopped successfully." "NOTICE"
							else
								if [ $noErrorLogsAtAll != true ]; then
								Logger "Could not stop command with pid [$pid]." "ERROR"
								fi
							fi
							errorcount=$((errorcount+1))

							if [ $noTimeErrorLog != true ]; then
								SendAlert true
							fi
						fi

						newPidsArray+=($pid)
					fi
				else
					# pid is dead, get its exit code from wait command
					wait $pid
					retval=$?
					# Check for valid exit codes
					if [ $(ArrayContains $retval "${validExitCodes[@]}") -eq 0 ]; then
						if [ $noErrorLogsAtAll != true ]; then
							Logger "${FUNCNAME[0]} called by [$id] finished monitoring pid [$pid] with exitcode [$retval]." "ERROR"
							if [ "$functionMode" == "ParallelExec" ]; then
								Logger "Command was [${commandsArrayPid[$pid]}]." "ERROR"
							fi
						fi
						errorcount=$((errorcount+1))
						# Welcome to variable variable bash hell
						if [ "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_$id\")" == "" ]; then
							eval "WAIT_FOR_TASK_COMPLETION_$id=\"$pid:$retval\""
						else
							eval "WAIT_FOR_TASK_COMPLETION_$id=\";$pid:$retval\""
						fi
					else
						Logger "${FUNCNAME[0]} called by [$id] finished monitoring pid [$pid] with exitcode [$retval]." "DEBUG"
					fi
				fi
				hasPids=true                                    ##__WITH_PARANOIA_DEBUG
			fi
		done

		# hasPids can be false on last iteration in ParallelExec mode
		if [ $hasPids == false ] && [ "$functionMode" = "WaitForTaskCompletion" ]; then                                 ##__WITH_PARANOIA_DEBUG
			Logger "No valable pids given." "ERROR"                                                                 ##__WITH_PARANOIA_DEBUG
		fi                                                                                                              ##__WITH_PARANOIA_DEBUG
		pidsArray=("${newPidsArray[@]}")

		# Trivial wait time for bash to not eat up all CPU
		sleep $sleepTime

		if [ "$_PERF_PROFILER" == "yes" ]; then                         ##__WITH_PARANOIA_DEBUG
			_PerfProfiler                                           ##__WITH_PARANOIA_DEBUG
		fi                                                              ##__WITH_PARANOIA_DEBUG

	}

	while [ ${#pidsArray[@]} -gt 0 ] || [ $counter -lt $mainItemCount ] || [ $postponedItemCount -ne 0 ]; do
		_ExecTasksTimeCheck
		retval=$?
		if [ $retval -ne 0 ]; then
			return $retval;
		fi

		# The following execution bloc is only needed in ParallelExec mode since WaitForTaskCompletion does not execute commands, but only monitors them
		if [ $functionMode == "ParallelExec" ]; then
			while [ ${#pidsArray[@]} -lt $numberOfProcesses ] && ([ $counter -lt $mainItemCount ] || [ $postponedItemCount -ne 0 ]); do
				_ExecTasksTimeCheck
				retval=$?
				if [ $retval -ne 0 ]; then
					return $retval;
				fi

				executeCommand=false
				isPostponedCommand=false
				currentCommand=""
				currentCommandCondition=""
				needsPostponing=false

				if [ $readFromFile == true ]; then
					# awk identifies first line as 1 instead of 0 so we need to increase counter
					currentCommand=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$mainInput")
					if [ $auxItemCount -ne 0 ]; then
						currentCommandCondition=$(awk 'NR == num_line {print; exit}' num_line=$((counter+1)) "$auxInput")
					fi

					# Check if we need to fetch postponed commands
					if [ "$currentCommand" == "" ]; then
						currentCommand=$(awk 'NR == num_line {print; exit}' num_line=$((postponedCounter+1)) "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedMain.$id.$SCRIPT_PID.$TSTAMP")
						currentCommandCondition=$(awk 'NR == num_line {print; exit}' num_line=$((postponedCounter+1)) "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedAux.$id.$SCRIPT_PID.$TSTAMP")
						isPostponedCommand=true
					fi
				else
					currentCommand="${commandsArray[$counter]}"
					if [ $auxItemCount -ne 0 ]; then
						currentCommandCondition="${commandsConditionArray[$counter]}"
					fi

					if [ "$currentCommand" == "" ]; then
						currentCommand="${postponedCommandsArray[$postponedCounter]}"
						currentCommandCondition="${postponedCommandsConditionArray[$postponedCounter]}"
						isPostponedCommand=true
					fi
				fi

				# Check if we execute postponed commands, or if we delay them
				if [ $isPostponedCommand == true ]; then
					# Get first value before '@'
					postponedExecTime="${currentCommand%%@*}"
					postponedExecTime=$((SECONDS-postponedExecTime))
					# Get everything after first '@'
					temp="${currentCommand#*@}"
					# Get first value before '@'
					postponedRetryCount="${temp%%@*}"
					# Replace currentCommand with actual filtered currentCommand
					currentCommand="${temp#*@}"

					# Since we read a postponed command, we may decrase postponedItemCounter
					postponedItemCount=$((postponedItemCount-1))
					#Since we read one line, we need to increase the counter
					postponedCounter=$((postponedCounter+1))

				else
					postponedRetryCount=0
					postponedExecTime=0
				fi
				if ([ $postponedRetryCount -lt $maxPostponeRetries ] && [ $postponedExecTime -ge $((minTimeBetweenRetries)) ]) || [ $isPostponedCommand == false ]; then
					if [ "$currentCommandCondition" != "" ]; then
						Logger "Checking condition [$currentCommandCondition] for command [$currentCommand]." "DEBUG"
						eval "$currentCommandCondition" &
						ExecTasks $! "subConditionCheck" false 0 0 1800 3600 true $SLEEP_TIME $KEEP_LOGGING true true true
						subRetval=$?
						if [ $subRetval -ne 0 ]; then
							# is postponing enabled ?
							if [ $maxPostponeRetries -gt 0 ]; then
								Logger "Condition [$currentCommandCondition] not met for command [$currentCommand]. Exit code [$subRetval]. Postponing command." "NOTICE"
								postponedRetryCount=$((postponedRetryCount+1))
								if [ $postponedRetryCount -ge $maxPostponeRetries ]; then
									Logger "Max retries reached for postponed command [$currentCommand]. Skipping command." "NOTICE"
								else
									needsPostponing=true
								fi
								postponedExecTime=0
							else
								Logger "Condition [$currentCommandCondition] not met for command [$currentCommand]. Exit code [$subRetval]. Ignoring command." "NOTICE"
							fi
						else
							executeCommand=true
						fi
					else
						executeCommand=true
					fi
				else
					needsPostponing=true
				fi

				if [ $needsPostponing == true ]; then
					postponedItemCount=$((postponedItemCount+1))
					if [ $readFromFile == true ]; then
						echo "$((SECONDS-postponedExecTime))@$postponedRetryCount@$currentCommand" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedMain.$id.$SCRIPT_PID.$TSTAMP"
						echo "$currentCommandCondition" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-postponedAux.$id.$SCRIPT_PID.$TSTAMP"
					else
						postponedCommandsArray+=("$((SECONDS-postponedExecTime))@$postponedRetryCount@$currentCommand")
						postponedCommandsConditionArray+=("$currentCommandCondition")
					fi
				fi

				if [ $executeCommand == true ]; then
					Logger "Running command [$currentCommand]." "DEBUG"
					eval "$currentCommand" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$id.$SCRIPT_PID.$TSTAMP" 2>&1 &
					pid=$!
					pidsArray+=($pid)
					commandsArrayPid[$pid]="$currentCommand"
					# Initialize pid execution time array
					pidsTimeArray[$pid]=0
				else
					Logger "Skipping command [$currentCommand]." "DEBUG"
				fi

				if [ $isPostponedCommand == false ]; then
					counter=$((counter+1))
				fi
				_ExecTasksPidsCheck
			done
		fi

	_ExecTasksPidsCheck
	done

	Logger "${FUNCNAME[0]} ended for [$id] using [$mainItemCount] subprocesses with [$errorcount] errors." "PARANOIA_DEBUG" #__WITH_PARANOIA_DEBUG

	# Return exit code if only one process was monitored, else return number of errors
	# As we cannot return multiple values, a global variable WAIT_FOR_TASK_COMPLETION contains all pids with their return value

	if [ $mainItemCount -eq 1 ]; then
		return $retval
	else
		return $errorcount
	fi
}

function CleanUp {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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

#### CheckRFC822 SUBSET ####
# Checks email address validity
function CheckRFC822 {
	local mail="${1}"
	local rfc822="^[a-z0-9!#\$%&'*+/=?^_\`{|}~-]+(\.[a-z0-9!#$%&'*+/=?^_\`{|}~-]+)*@([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?\$"

	if [[ $mail =~ $rfc822 ]]; then
		echo 1
	else
		echo 0
	fi
}
#### CheckRFC822 SUBSET END ####

#### IsInteger SUBSET ####
function IsInteger {
	local value="${1}"

	if [[ $value =~ ^[0-9]+$ ]]; then
		echo 1
	else
		echo 0
	fi
}
#### IsInteger SUBSET END ####

#### HumanToNumeric SUBSET ####
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
#### HumanToNumeric SUBSET END ####

#### UrlEncode SUBSET ####
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
#### UrlEncode SUBSET END ####

function UrlDecode {
	local urlEncoded="${1//+/ }"

	printf '%b' "${urlEncoded//%/\\x}"
}

#### ArrayContains SUBSET ####
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
#### ArrayContains SUBSET END ####

#### GetLocalOS SUBSET ####
function GetLocalOS {
	local localOsVar
	local localOsName
	local localOsVer

	# There is no good way to tell if currently running in BusyBox shell. Using sluggish way.
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
		localOsName=$(GetConfFileValue "/etc/os-release" "NAME" true)
		localOsVer=$(GetConfFileValue "/etc/os-release" "VERSION" true)
	fi

	# Add a global variable for statistics in installer
	LOCAL_OS_FULL="$localOsVar ($localOsName $localOsVer)"

	if [ "$_OFUNCTIONS_VERSION" != "" ]; then
		Logger "Local OS: [$LOCAL_OS_FULL]." "DEBUG"
	fi
}
#### GetLocalOS SUBSET END ####

#__BEGIN_WITH_PARANOIA_DEBUG
function __CheckArguments {
	# Checks the number of arguments of a function and raises an error if some are missing

	if [ "$_DEBUG" == "yes" ]; then
		local numberOfArguments="${1}" # Number of arguments the tested function should have, can be a number of a range, eg 0-2 for zero to two arguments
		local numberOfGivenArguments="${2}" # Number of arguments that have been passed

		local minArgs
		local maxArgs

		# All arguments of the function to check are passed as array in ${3} (the function call waits for $@)
		# If any of the arguments contains spaces, bash things there are two aguments
		# In order to avoid this, we need to iterate over ${3} and count

		callerName="${FUNCNAME[1]}"

		local iterate=3
		local fetchArguments=true
		local argList=""
		local countedArguments
		while [ $fetchArguments == true ]; do
			cmd='argument=${'$iterate'}'
			eval $cmd
			if [ "$argument" == "" ]; then
				fetchArguments=false
			else
				argList="$argList[Argument $((iterate-2)): $argument] "
				iterate=$((iterate+1))
			fi
		done

		countedArguments=$((iterate-3))

		if [ $(IsInteger "$numberOfArguments") -eq 1 ]; then
			minArgs=$numberOfArguments
			maxArgs=$numberOfArguments
		else
			IFS='-' read minArgs maxArgs <<< "$numberOfArguments"
		fi

		Logger "Entering function [$callerName]." "PARANOIA_DEBUG"

		if ! ([ $countedArguments -ge $minArgs ] && [ $countedArguments -le $maxArgs ]); then
			Logger "Function $callerName may have inconsistent number of arguments. Expected min: $minArgs, max: $maxArgs, count: $countedArguments, bash seen: $numberOfGivenArguments." "ERROR"
			Logger "$callerName arguments: $argList" "ERROR"
		else
			if [ ! -z "$argList" ]; then
				Logger "$callerName arguments: $argList" "PARANOIA_DEBUG"
			fi
		fi
	fi
}

#__END_WITH_PARANOIA_DEBUG

#### OFUNCTIONS MINI SUBSET END ####

function GetRemoteOS {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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

	# There is no good way to tell if currently running in BusyBox shell. Using sluggish way.
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
	if [ $? != 0 ]; then
		Logger "Cannot connect to remote system [$REMOTE_HOST] port [$REMOTE_PORT]." "CRITICAL"
		exit 1
	fi


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
	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG

	if [ $_DRYRUN == true ]; then
		Logger "Dryrun: Local command [$command] not run." "NOTICE"
		return 0
	fi

	Logger "Running command [$command] on local host." "NOTICE"
	eval "$command" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1 &

	ExecTasks $! "${FUNCNAME[0]}" false 0 0 0 $hardMaxTime true $SLEEP_TIME $KEEP_LOGGING
	#ExecTasks "${FUNCNAME[0]}" 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING true true false false 1 $!
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
	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG


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
	ExecTasks $! "${FUNCNAME[0]}" false  0 0 0 $hardMaxTime true $SLEEP_TIME $KEEP_LOGGING
	#ExecTasks "${FUNCNAME[0]}" 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING true true false false 1 $!
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
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
		ExecTasks $pids "${FUNCNAME[0]}" false 0 0 0 0 true $SLEEP_TIME $KEEP_LOGGING
		#ExecTasks "${FUNCNAME[0]}" 0 0 0 0 true true false false 1 $pids
	fi
}

function RunAfterHook {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
		ExecTasks $pids "${FUNCNAME[0]}" false 0 0 0 0 true $SLEEP_TIME $KEEP_LOGGING
		#ExecTasks "${FUNCNAME[0]}" 0 0 0 0 true true false false 1 $pids
	fi
}

function CheckConnectivityRemoteHost {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug		#__WITH_PARANOIA_DEBUG

		if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_OPERATION" != "no" ]; then
			eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1" &
			ExecTasks $! "${FUNCNAME[0]}" false 0 0 60 180 true $SLEEP_TIME $KEEP_LOGGING
			#ExecTasks "${FUNCNAME[0]}" 0 0 60 180 $SLEEP_TIME $KEEP_LOGGING true true false false 1 $!
			retval=$?
			if [ $retval != 0 ]; then
				Logger "Cannot ping [$REMOTE_HOST]. Return code [$retval]." "WARN"
				return $retval
			fi
		fi
	fi											#__WITH_PARANOIA_DEBUG
}

function CheckConnectivity3rdPartyHosts {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	local remote3rdPartySuccess
	local retval
	local i

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug		#__WITH_PARANOIA_DEBUG

		if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]; then
			remote3rdPartySuccess=false
			for i in $REMOTE_3RD_PARTY_HOSTS
			do
				eval "$PING_CMD $i > /dev/null 2>&1" &
				ExecTasks $! "${FUNCNAME[0]}" false 0 0 60 180 true $SLEEP_TIME $KEEP_LOGGING
				#ExecTasks "${FUNCNAME[0]}" 0 0 180 360 $SLEEP_TIME $KEEP_LOGGING true true false false 1 $!
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
	fi											#__WITH_PARANOIA_DEBUG
}

function RsyncPatternsAdd {
	local patternType="${1}"	# exclude or include
	local pattern="${2}"
	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG

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
	__CheckArguments 2 $# "$@"    #__WITH_PARANOIA_DEBUG

	## Check if the exclude list has a full path, and if not, add the config file path if there is one
	if [ "$(basename $patternFrom)" == "$patternFrom" ]; then
		patternFrom="$(dirname $CONFIG_FILE)/$patternFrom"
	fi

	if [ -e "$patternFrom" ]; then
		RSYNC_PATTERNS="$RSYNC_PATTERNS --"$patternType"-from=\"$patternFrom\""
	fi
}

function RsyncPatterns {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

       if [ "$RSYNC_PATTERN_FIRST" == "exclude" ]; then
		if [ "$RSYNC_EXCLUDE_PATTERN" != "" ]; then
			RsyncPatternsAdd "exclude" "$RSYNC_EXCLUDE_PATTERN"
		fi
		if [ "$RSYNC_EXCLUDE_FROM" != "" ]; then
			RsyncPatternsFromAdd "exclude" "$RSYNC_EXCLUDE_FROM"
		fi
		if [ "$RSYNC_INCLUDE_PATTERN" != "" ]; then
			RsyncPatternsAdd "include" "$RSYNC_INCLUDE_PATTERN"
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
	 __CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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
	## Busybox fix (Termux xz command does not support compression at all)
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
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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
		SED_REGEX_ARG="-E"
	else
		# Tested on GNU stat, busybox and Cygwin
		STAT_CMD="stat -c %y"
		STAT_CTIME_MTIME_CMD="stat -c %n;%Z;%Y"
		SED_REGEX_ARG="-r"
	fi

	# Set compression first time when we know what local os we have
	SetCompression
}

# Gets executed regardless of the need of remote connections. It is just that this code needs to get executed after we know if there is a remote os, and if yes, which one
function InitRemoteOSDependingSettings {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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

	# Set compression options again after we know what remote OS we are dealing with
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

#### VerComp SUBSET ####
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
#### VerComp SUBSET END ####

#### GetConfFileValue SUBSET ####
function GetConfFileValue () {
	local file="${1}"
	local name="${2}"
	local noError="${3:-false}"

	local value

	value=$(grep "^$name=" "$file")
	if [ $? == 0 ]; then
		value="${value##*=}"
		echo "$value"
	else
		if [ $noError == true ]; then
			Logger "Cannot get value for [$name] in config file [$file]." "NOTICE"
		else
			Logger "Cannot get value for [$name] in config file [$file]." "ERROR"
		fi
	fi
}

#### GetConfFileValue SUBSET END ####

#### SetConfFileValue SUBSET ####
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
#### SetConfFileValue SUBSET END ####

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

#### OFUNCTIONS FULL SUBSET END ####
