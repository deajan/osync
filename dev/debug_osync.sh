#!/usr/bin/env bash

#TODO treeList, deleteList, _getFileCtimeMtime, conflictList should be called without having statedir informed. Just give the full path ?
#TODO check if _getCtimeMtime | sort removal needs to be backported
#Check dryruns with nosuffix mode for timestampList

PROGRAM="osync" # Rsync based two way sync engine with fault tolerance
AUTHOR="(C) 2013-2017 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION=1.2.2-dev
PROGRAM_BUILD=2017112201
IS_STABLE=no


##### Execution order						#__WITH_PARANOIA_DEBUG
#####	Function Name				Is parallel	#__WITH_PARANOIA_DEBUG
#	GetLocalOS				no		#__WITH_PARANOIA_DEBUG
#	InitLocalOSDependingSettings		no		#__WITH_PARANOIA_DEBUG
#	CheckEnvironment			no		#__WITH_PARANOIA_DEBUG
#	PreInit					no		#__WITH_PARANOIA_DEBUG
#	Init					no		#__WITH_PARANOIA_DEBUG
#	PostInit				no		#__WITH_PARANOIA_DEBUG
#	GetRemoteOS				no		#__WITH_PARANOIA_DEBUG
#	InitRemoteOSDependingSettings		no		#__WITH_PARANOIA_DEBUG
#	CheckReplicas				yes		#__WITH_PARANOIA_DEBUG
#	RunBeforeHook				yes		#__WITH_PARANOIA_DEBUG
#	Main					no		#__WITH_PARANOIA_DEBUG
#	 	HandleLocks			yes		#__WITH_PARANOIA_DEBUG
#	 	Sync				no		#__WITH_PARANOIA_DEBUG
#			treeList		yes		#__WITH_PARANOIA_DEBUG
#			deleteList		yes		#__WITH_PARANOIA_DEBUG
#			timestampList		yes		#__WITH_PARANOIA_DEBUG
#			conflictList		no		#__WITH_PARANOIA_DEBUG
#			syncAttrs		no		#__WITH_PARANOIA_DEBUG
#			syncUpdate		no		#__WITH_PARANOIA_DEBUG
#			syncUpdate		no		#__WITH_PARANOIA_DEBUG
#			deletionPropagation	yes		#__WITH_PARANOIA_DEBUG
#			treeList		yes		#__WITH_PARANOIA_DEBUG
#			timestampList		yes		#__WITH_PARANOIA_DEBUG
#		SoftDelete			yes		#__WITH_PARANOIA_DEBUG
#	RunAfterHook				yes		#__WITH_PARANOIA_DEBUG
#	UnlockReplicas				yes		#__WITH_PARANOIA_DEBUG
#	CleanUp					no		#__WITH_PARANOIA_DEBUG


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

	__CheckArguments 3-10 $# "$@"	#__WITH_PARANOIA_DEBUG

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

function _PerfProfiler {												#__WITH_PARANOIA_DEBUG
	local perfString												#__WITH_PARANOIA_DEBUG
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
	Logger "${FUNCNAME[0]} called by [$callerName]." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG
	__CheckArguments 8 $# "$@"				#__WITH_PARANOIA_DEBUG

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
				hasPids=true					##__WITH_PARANOIA_DEBUG
			fi
		done

		if [ $hasPids == false ]; then					##__WITH_PARANOIA_DEBUG
			Logger "No valable pids given." "ERROR" 		##__WITH_PARANOIA_DEBUG
		fi								##__WITH_PARANOIA_DEBUG

		pidsArray=("${newPidsArray[@]}")
		# Trivial wait time for bash to not eat up all CPU
		sleep $sleepTime

		if [ "$_PERF_PROFILER" == "yes" ]; then				##__WITH_PARANOIA_DEBUG
			_PerfProfiler						##__WITH_PARANOIA_DEBUG
		fi								##__WITH_PARANOIA_DEBUG

	done

	Logger "${FUNCNAME[0]} ended for [$callerName] using [$pidCount] subprocesses with [$errorcount] errors." "PARANOIA_DEBUG"	#__WITH_PARANOIA_DEBUG

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
	__CheckArguments 2-10 $# "$@"				#__WITH_PARANOIA_DEBUG

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

	local hasPids=false # Are any valable pids given to function ?		#__WITH_PARANOIA_DEBUG

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
				hasPids=true					##__WITH_PARANOIA_DEBUG
			fi
		done

		if [ $hasPids == false ]; then					##__WITH_PARANOIA_DEBUG
			Logger "No valable pids given." "ERROR"			##__WITH_PARANOIA_DEBUG
		fi								##__WITH_PARANOIA_DEBUG
		pidsArray=("${newPidsArray[@]}")

		# Trivial wait time for bash to not eat up all CPU
		sleep $sleepTime

		if [ "$_PERF_PROFILER" == "yes" ]; then				##__WITH_PARANOIA_DEBUG
			_PerfProfiler						##__WITH_PARANOIA_DEBUG
		fi								##__WITH_PARANOIA_DEBUG
	done

	return $errorCount
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
	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG

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
		WaitForTaskCompletion $pids 0 0 $SLEEP_TIME $KEEP_LOGGING true true false
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
		WaitForTaskCompletion $pids 0 0 $SLEEP_TIME $KEEP_LOGGING true true false
	fi
}

function CheckConnectivityRemoteHost {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug		#__WITH_PARANOIA_DEBUG

		if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_OPERATION" != "no" ]; then
			eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1" &
			WaitForTaskCompletion $! 60 180 $SLEEP_TIME $KEEP_LOGGING true true false
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

	if [ "$_PARANOIA_DEBUG" != "yes" ]; then # Do not loose time in paranoia debug		#__WITH_PARANOIA_DEBUG

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

# The catch CRTL+C behavior can be changed at script entry point with SOFT_STOP=0
function TrapStop {
	if [ $SOFT_STOP -eq 2 ]; then
		Logger " /!\ WARNING: Manual exit of osync is really not recommended. Sync will be in inconsistent state." "WARN"
		Logger " /!\ WARNING: If you are sure, please hit CTRL+C another time to quit." "WARN"
		SOFT_STOP=1
		return 1
	fi

	if [ $SOFT_STOP -lt 2 ]; then
		Logger " /!\ WARNING: CTRL+C hit. Exiting osync. Please wait while replicas get unlocked..." "WARN"
		SOFT_STOP=0
		exit 2
	fi
}

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
		UnlockReplicas
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
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
		Logger "$PROGRAM finished." "ALWAYS"
		exitcode=0
	fi
	CleanUp
	KillChilds $SCRIPT_PID > /dev/null 2>&1

	exit $exitcode
}

function CheckEnvironment {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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

	if ! type pgrep > /dev/null 2>&1 ; then
		Logger "pgrep not present. Sync cannot start." "CRITICAL"
		exit 1
	fi

	if [ "$SUDO_EXEC" == "yes" ]; then
		if ! type sudo > /dev/null 2>&1 ; then
			Logger "sudo not present. Sync cannot start." "CRITICAL"
			exit 1
		fi
	fi
}

# Only gets checked in config file mode where all values should be present
function CheckCurrentConfig {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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

# Gets checked in quicksync and config file mode
function CheckCurrentConfigAll {
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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

	if [ "$REMOTE_OPERATION" == "yes" ] && ([ ! -f "$SSH_RSA_PRIVATE_KEY" ] && [ ! -f "$SSH_PASSWORD_FILE" ]); then
		Logger "Cannot find rsa private key [$SSH_RSA_PRIVATE_KEY] nor password file [$SSH_PASSWORD_FILE]. No authentication method provided." "CRITICAL"
		exit 1
	fi

	if [ "$SKIP_DELETION" != "" ]; then
		tmp="$SKIP_DELETION"
		IFS=',' read -r -a SKIP_DELETION <<< "$tmp"
		if [ $(ArrayContains "${INITIATOR[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ] && [ $(ArrayContains "${TARGET[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ]; then
			Logger "Bogus skip deletion parameter [$SKIP_DELETION]." "CRITICAL"
			exit 1
		fi
	fi
}

###### Osync specific functions (non shared)

function _CheckReplicasLocal {
	local replicaPath="${1}"
	local replicaType="${2}"

	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local diskSpace

	if [ ! -d "$replicaPath" ]; then
		if [ "$CREATE_DIRS" == "yes" ]; then
			mkdir -p "$replicaPath" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
			retval=$?
			if [ $retval -ne 0 ]; then
				Logger "Cannot create local replica path [$replicaPath]." "CRITICAL" $retval
				Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
				return 1
			else
				Logger "Created local replica path [$replicaPath]." "NOTICE"
			fi
		else
			Logger "Local replica path [$replicaPath] does not exist / is not writable." "CRITICAL"
			return 1
		fi
	fi

	if [ ! -w "$replicaPath" ]; then
		Logger "Local replica path [$replicaPath] is not writable." "CRITICAL"
		return 1
	fi

	Logger "Checking minimum disk space in local replica [$replicaPath]." "NOTICE"
	diskSpace=$($DF_CMD "$replicaPath" | tail -1 | awk '{print $4}')
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Cannot get free space." "ERROR" $retval
	else
		# Ugly fix for df in some busybox environments that can only show human formats
		if [ $(IsInteger $diskSpace) -eq 0 ]; then
			diskSpace=$(HumanToNumeric $diskSpace)
		fi

		if [ $diskSpace -lt $MINIMUM_SPACE ]; then
			Logger "There is not enough free space on local replica [$replicaPath] ($diskSpace KB)." "WARN"
		fi
	fi
}

function _CheckReplicasRemote {
	local replicaPath="${1}"
	local replicaType="${2}"

	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local cmd

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" \
env replicaPath="'$replicaPath'" env CREATE_DIRS="'$CREATE_DIRS'" env DF_CMD="'$DF_CMD'" env MINIMUM_SPACE="'$MINIMUM_SPACE'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
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
function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
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

function _CheckReplicasRemoteSub {
	if [ ! -d "$replicaPath" ]; then
		if [ "$CREATE_DIRS" == "yes" ]; then
			mkdir -p "$replicaPath"
			retval=$?
			if [ $retval -ne 0 ]; then
				RemoteLogger "Cannot create remote replica path [$replicaPath]." "CRITICAL" $retval
				exit 1
			else
				RemoteLogger "Created remote replica path [$replicaPath]." "NOTICE"
			fi
		else
			RemoteLogger "Remote replica path [$replicaPath] does not exist / is not writable." "CRITICAL"
			exit 1
		fi
	fi

	if [ ! -w "$replicaPath" ]; then
		RemoteLogger "Remote replica path [$replicaPath] is not writable." "CRITICAL"
		exit 1
	fi

	RemoteLogger "Checking minimum disk space in remote replica [$replicaPath]." "NOTICE"
	diskSpace=$($DF_CMD "$replicaPath" | tail -1 | awk '{print $4}')
	retval=$?
	if [ $retval -ne 0 ]; then
		RemoteLogger "Cannot get free space." "ERROR" $retval
	else
		# Ugly fix for df in some busybox environments that can only show human formats
		if [ $(IsInteger $diskSpace) -eq 0 ]; then
			diskSpace=$(HumanToNumeric $diskSpace)
		fi

		if [ $diskSpace -lt $MINIMUM_SPACE ]; then
			RemoteLogger "There is not enough free space on remote replica [$replicaPath] ($diskSpace KB)." "WARN"
		fi
	fi
}
_CheckReplicasRemoteSub
exit $?
ENDSSH
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Failed to check remote replica." "CRITICAL" $retval
	fi
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
		(
		_LOGGER_PREFIX=""
		Logger "$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "NOTICE"
		)
	fi
	if [ $retval -ne 0 ]; then
		return $retval
	else
		return 0
	fi
}

function CheckReplicas {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local pids

	if [ "$REMOTE_OPERATION" != "yes" ]; then
		if [ "${INITIATOR[$__replicaDir]}" == "${TARGET[$__replicaDir]}" ]; then
			Logger "Initiator and target path [${INITIATOR[$__replicaDir]}] cannot be the same." "CRITICAL"
			exit 1
		fi
	fi

	_CheckReplicasLocal "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" &
	pids="$!"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CheckReplicasLocal "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" &
		pids="$pids;$!"
	else
		_CheckReplicasRemote "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" &
		pids="$pids;$!"
	fi
	WaitForTaskCompletion $pids 720 1800 $SLEEP_TIME $KEEP_LOGGING true true false
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Cancelling task." "CRITICAL" $retval
		exit 1
	fi
}

function _HandleLocksLocal {
	local replicaStateDir="${1}"
	local lockfile="${2}"
	local replicaType="${3}"
	local overwrite="${4:-false}"

	__CheckArguments 4 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local lockfileContent
	local lockPid
	local lockInstanceID
	local writeLocks=false

	if [ ! -d "$replicaStateDir" ]; then
		mkdir -p "$replicaStateDir" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot create state dir [$replicaStateDir]." "CRITICAL" $retval
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
			return 1
		fi
	fi

	# Skip the whole part if overwrite true
	if [ -s "$lockfile" ] && [ $overwrite != true ]; then
		lockfileContent=$(cat $lockfile)
		Logger "Master lock pid present: $lockfileContent" "DEBUG"
		lockPid="${lockfileContent%@*}"
		if [ $(IsInteger $lockPid) -ne 1 ]; then
			Logger "Invalid pid [$lockPid] in local replica." "CRITICAL"
			return 1
		fi
		lockInstanceID="${lockfileContent#*@}"
		if [ "$lockInstanceID" == "" ]; then
			Logger "Invalid instance id [$lockInstanceID] in local replica." "CRITICAL"
			return 1

		Logger "Local $replicaType  lock is: [$lockPid@$lockInstanceID]." "DEBUG"

		fi
		kill -0 $lockPid > /dev/null 2>&1
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "There is a local dead osync lock [$lockPid@$lockInstanceID] that is no longer running. Resuming." "NOTICE"
			writeLocks=true
		else
			Logger "There is already a local instance [$lockPid@$lockInstanceID] of osync running for this replica. Cannot start." "CRITICAL" $retval
			return 1
		fi
	else
		writeLocks=true
	fi

	if [ $writeLocks != true ]; then
		return 1
	else
		echo "$SCRIPT_PID@$INSTANCE_ID" > "$lockfile" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Could not create lock file on local $replicaType in [$lockfile]." "CRITICAL" $retval
			Logger "Command output\n$($RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
			return 1
		else
			Logger "Locked local $replicaType replica in [$lockfile]." "DEBUG"
		fi
	fi
}

function _HandleLocksRemote {
	local replicaStateDir="${1}"
	local lockfile="${2}"
	local replicaType="${3}"
	local overwrite="${4:-false}"

	__CheckArguments 4 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local initiatorRunningPids

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	# Create an array of all currently running pids
	read -a initiatorRunningPids <<< $(ps -A | tail -n +2 | awk '{print $1}')

# passing initiatorRunningPids as litteral string (has to be run through eval to be an array again)
$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" \
env replicaStateDir="'$replicaStateDir'" env initiatorRunningPidsFlat="\"(${initiatorRunningPids[@]})\"" env lockfile="'$lockfile'" env replicaType="'$replicaType'" env overwrite="'$overwrite'" \
env INSTANCE_ID="'$INSTANCE_ID'" env FORCE_STRANGER_LOCK_RESUME="'$FORCE_STRANGER_LOCK_RESUME'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
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
function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
	fi
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
function IsInteger {
	local value="${1}"

	if [[ $value =~ ^[0-9]+$ ]]; then
		echo 1
	else
		echo 0
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

function _HandleLocksRemoteSub {
	local writeLocks=false

	if [ ! -d "$replicaStateDir" ]; then
		mkdir -p "$replicaStateDir"
		retval=$?
		if [ $retval -ne 0 ]; then
			RemoteLogger "Cannot create state dir [$replicaStateDir]." "CRITICAL" $retval
			return 1
		fi
	fi

	# Skip the whole part if overwrite true
	if [ -s "$lockfile" ] && [ $overwrite != true ]; then
		lockfileContent=$(cat $lockfile)
		RemoteLogger "Master lock pid present: $lockfileContent" "DEBUG"
		lockPid="${lockfileContent%@*}"
		if [ $(IsInteger $lockPid) -ne 1 ]; then
			RemoteLogger "Invalid pid [$lockPid] in local replica." "CRITICAL"
			return 1
		fi
		lockInstanceID="${lockfileContent#*@}"
		if [ "$lockInstanceID" == "" ]; then
			RemoteLogger "Invalid instance id [$lockInstanceID] in local replica." "CRITICAL"
			return 1

		RemoteLogger "Local $replicaType  lock is: [$lockPid@$lockInstanceID]." "DEBUG"

		fi

		# Retransform litteral array string to array
		eval "initiatorRunningPids=$initiatorRunningPidsFlat"
		if [ $(ArrayContains "$lockPid" "${initiatorRunningPids[@]}") -eq 0 ]; then
			if [ "$lockInstanceID" == "$INSTANCE_ID" ]; then
				RemoteLogger "There is a remote dead osync lock [$lockPid@$lockInstanceID] on target replica that corresponds to this initiator INSTANCE_ID. Pid [$lockPid] no longer running. Resuming." "NOTICE"
				writeLocks=true
			else
				if [ "$FORCE_STRANGER_LOCK_RESUME" == "yes" ]; then
					RemoteLogger "There is a remote (maybe dead) osync lock [$lockPid@$lockInstanceID] on target replica that does not correspond to this initiator INSTANCE_ID. Forcing resume." "WARN"
					writeLocks=true
				else
					RemoteLogger "There is a remote (maybe dead) osync lock [$lockPid@$lockInstanceID] on target replica that does not correspond to this initiator INSTANCE_ID. Will not resume." "CRITICAL"
					return 1
				fi
			fi
		else
			RemoteLogger "There is already a local instance of osync that locks target replica [$lockPid@$lockInstanceID]. Cannot start." "CRITICAL"
			return 1
		fi
	else
		writeLocks=true
	fi

	if [ $writeLocks != true ]; then
		return 1
	else
		echo "$SCRIPT_PID@$INSTANCE_ID" > "$lockfile"
		retval=$?
		if [ $retval -ne 0 ]; then
			RemoteLogger "Could not create lock file on local $replicaType in [$lockfile]." "CRITICAL" $retval
			return 1
		else
			RemoteLogger "Locked local $replicaType replica in [$lockfile]." "DEBUG"
		fi
	fi
}

_HandleLocksRemoteSub
exit $?
ENDSSH
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Remote lock handling failed." "CRITICAL" $retval
	fi
	if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
		(
		_LOGGER_PREFIX=""
		Logger "$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "NOTICE"
		)
	fi
	if [ $retval -ne 0 ]; then
		return 1
	fi
}

function HandleLocks {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local pids
	local overwrite=false

	if [ $_NOLOCKS == true ]; then
		return 0
	fi

	# Do not bother checking for locks when FORCE_UNLOCK is set
	if [ $FORCE_UNLOCK == true ]; then
		overwrite=true
	else
		_HandleLocksLocal "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}" "${INITIATOR[$__lockFile]}" "${INITIATOR[$__type]}" $overwrite &
		pids="$!"
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_HandleLocksLocal "${TARGET[$__replicaDir]}${TARGET[$__stateDir]}" "${TARGET[$__lockFile]}" "${TARGET[$__type]}" $overwrite &
			pids="$pids;$!"
		else
			_HandleLocksRemote "${TARGET[$__replicaDir]}${TARGET[$__stateDir]}" "${TARGET[$__lockFile]}" "${TARGET[$__type]}" $overwrite &
			pids="$pids;$!"
		fi
		#Assume locks could be created unless pid returns with exit code
		INITIATOR_LOCK_FILE_EXISTS=true
		TARGET_LOCK_FILE_EXISTS=true
		WaitForTaskCompletion $pids 720 1800 $SLEEP_TIME $KEEP_LOGGING true true false
		retval=$?
		if [ $retval -ne 0 ]; then
			IFS=';' read -r -a pidArray <<< "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_${FUNCNAME[0]}\")"
			for pid in "${pidArray[@]}"; do
				pid=${pid%:*}
				if [ "$pid" == "$initiatorPid" ]; then
					INITIATOR_LOCK_FILE_EXISTS=false
				elif [ "$pid" == "$targetPid" ]; then
					TARGET_LOCK_FILE_EXISTS=false
				fi
			done

			Logger "Cancelling task." "CRITICAL" $retval
			exit 1
		fi
	fi
}

function _UnlockReplicasLocal {
	local lockfile="${1}"
	local replicaType="${2}"

	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ -f "$lockfile" ]; then
		rm -f "$lockfile"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Could not unlock local $replicaType replica." "ERROR" $retval
		else
			Logger "Removed local $replicaType replica lock." "DEBUG"
		fi
	fi
}

function _UnlockReplicasRemote {
	local lockfile="${1}"
	local replicaType="${2}"

	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local cmd

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" env lockfile="'$lockfile'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
if [ -f "$lockfile" ]; then
	rm -f "$lockfile"
fi
ENDSSH
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Could not unlock $replicaType remote replica." "ERROR" $retval
		Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
	else
		Logger "Removed remote $replicaType replica lock." "DEBUG"
	fi
}

function UnlockReplicas {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	local pids

	if [ $_NOLOCKS == true ]; then
		return 0
	fi

	if [ $INITIATOR_LOCK_FILE_EXISTS == true ]; then
		_UnlockReplicasLocal "${INITIATOR[$__lockFile]}" "${INITIATOR[$__type]}" &
		pids="$!"
	fi

	if [ $TARGET_LOCK_FILE_EXISTS == true ]; then
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_UnlockReplicasLocal "${TARGET[$__lockFile]}" "${TARGET[$__type]}" &
			pids="$pids;$!"
		else
			_UnlockReplicasRemote "${TARGET[$__lockFile]}" "${TARGET[$__type]}" &
			pids="$pids;$!"
		fi
	fi

	if [ "$pids" != "" ]; then
		WaitForTaskCompletion $pids 720 1800 $SLEEP_TIME $KEEP_LOGGING true true false
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

	__CheckArguments 3 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local escapedReplicaPath
	local rsyncCmd

	escapedReplicaPath=$(EscapeSpaces "$replicaPath")

	# operation explanation
	# (command || :) = Return code 0 regardless of command return code
	# (grep -E \"^-|^d|^l\" || :) = Be sure line begins with '-' or 'd' or 'l' (rsync semantics for file, directory or symlink)
	# (sed -r 's/^.{10} +[0-9,]+ [0-9/]{10} [0-9:]{8} //' || :) = Remove everything before timestamps
	# (awk 'BEGIN { FS=\" -> \" } ; { print \$1 }' || :) = Only show output before ' -> ' in order to remove symlink destinations
	# (grep -v \"^\.$\" || :) = Removes line containing current directory sign '.'

	Logger "Creating $replicaType replica file list [$replicaPath]." "NOTICE"
	if [ "$REMOTE_OPERATION" == "yes" ] && [ "$replicaType" == "${TARGET[$__type]}" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE -e \"$RSYNC_SSH_CMD\" --list-only $REMOTE_USER@$REMOTE_HOST:\"$escapedReplicaPath\" 2> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP\" | (grep -E \"^-|^d|^l\" || :) | (sed -r 's/^.{10} +[0-9,]+ [0-9/]{10} [0-9:]{8} //' || :) | (awk 'BEGIN { FS=\" -> \" } ; { print \$1 }' || :) | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP\""
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --list-only \"$replicaPath\" 2> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP\" | (grep -E \"^-|^d|^l\" || :) | (sed -r 's/^.{10} +[0-9,]+ [0-9/]{10} [0-9:]{8} //' || :) | (awk 'BEGIN { FS=\" -> \" } ; { print \$1 }' || :) | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP\""
	fi
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	retval=$?

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
		mv -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" "$treeFilename"
	fi

	## Retval 24 = some files vanished while creating list
	if ([ $retval -eq 0 ] || [ $retval -eq 24 ]) then
		return $?
	elif [ $retval -eq 23 ]; then
		Logger "Some files could not be listed in $replicaType replica [$replicaPath]. Check for failing symlinks." "ERROR" $retval
		Logger "Command output\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP)" "WARN"
		return 0
	else
		Logger "Cannot create replica file list in [$replicaPath]." "CRITICAL" $retval
		_LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		Logger "Command output\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP)" "WARN"
		return $retval
	fi
}

# deleteList(replicaType): Creates a list of files vanished from last run on replica $1 (initiator/target)
function deleteList {
	local replicaType="${1}" # replica type: initiator, target

	__CheckArguments 1 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local subretval
	local cmd

	local failedDeletionListFromReplica

	if [ "$replicaType" == "${INITIATOR[$__type]}" ]; then
		failedDeletionListFromReplica="${TARGET[$__type]}"
	elif [ "$replicaType" == "${TARGET[$__type]}" ]; then
		failedDeletionListFromReplica="${INITIATOR[$__type]}"
	else
		Logger "Bogus replicaType in [${FUNCNAME[0]}]." "CRITICAL"
		exit 1
	fi

	Logger "Creating $replicaType replica deleted file list." "NOTICE"
	if [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeAfterFileNoSuffix]}" ]; then
		## Same functionnality, comm is much faster than grep but is not available on every platform
		if type comm > /dev/null 2>&1 ; then
			cmd="comm -23 \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeAfterFileNoSuffix]}\" \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeCurrentFile]}\" > \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}\""
		else
			## The || : forces the command to have a good result
			cmd="(grep -F -x -v -f \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeCurrentFile]}\" \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__treeAfterFileNoSuffix]}\" || :) > \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}\""
		fi

		Logger "Launching command [$cmd]." "DEBUG"
		eval "$cmd" 2>> "$LOG_FILE"
		retval=$?

		if [ $retval -ne 0 ]; then
			Logger "Could not prepare $replicaType deletion list." "CRITICAL" $retval
			_LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
			return $retval
		fi

		# Add delete failed file list to current delete list and then empty it
		if [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$failedDeletionListFromReplica${INITIATOR[$__failedDeletedListFile]}" ]; then
			cat "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$failedDeletionListFromReplica${INITIATOR[$__failedDeletedListFile]}" >> "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}"
			subretval=$?
			if [ $subretval -eq 0 ]; then
				rm -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$failedDeletionListFromReplica${INITIATOR[$__failedDeletedListFile]}"
			else
				Logger "Cannot add failed deleted list to current deleted list for replica [$replicaType]." "ERROR" $subretval
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
	local timestampFile="${4}" # Where to store the timestamp file

	__CheckArguments 4 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	echo -n "" > "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP"
	while IFS='' read -r file; do $STAT_CTIME_MTIME_CMD "$replicaPath$file" >> "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP"; done < "$fileList"
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Getting file attributes failed [$retval] on $replicaType. Stopping execution." "CRITICAL" $retval
		if [ -f "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
		fi
		return $retval
	else
		cat "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP" | sort > "$timestampFile"
		retval=$?
		return $retval
	fi

}

function _getFileCtimeMtimeRemote {
	local replicaPath="${1}" # Contains replica path
	local replicaType="${2}"
	local fileList="${3}"
	local timestampFile="${4}"

	__CheckArguments 4 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local cmd

	cmd='cat "'$fileList'" | '$SSH_CMD' "env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN cat > \".$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP\""'
	Logger "Launching command [$cmd]." "DEBUG"
	eval "$cmd"
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Sending ctime required file list failed with [$retval] on $replicaType. Stopping execution." "CRITICAL" $retval
		_LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
		fi
		return $retval
	fi


$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" \
env replicaPath="'$replicaPath'" env replicaType="'$replicaType'" env REMOTE_STAT_CTIME_MTIME_CMD="'$REMOTE_STAT_CTIME_MTIME_CMD'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP"
	while IFS='' read -r file; do $REMOTE_STAT_CTIME_MTIME_CMD "$replicaPath$file"; done < ".$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP"
		if [ -f ".$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
			rm -f ".$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP"
		fi
ENDSSH
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Getting file attributes failed [$retval] on $replicaType. Stopping execution." "CRITICAL" $retval
		if [ -f "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
		fi
		return $retval
	else
		# Ugly fix for csh in FreeBSD 11 that adds leading and trailing '\"'
		sed -i.tmp -e 's/^\\"//' -e 's/\\"$//' "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot fix FreeBSD 11 remote csh syntax." "ERROR"
			return $retval
		fi
		cat "$RUN_DIR/$PROGRAM.ctime_mtime.$replicaType.$SCRIPT_PID.$TSTAMP" | sort > "$timestampFile"
		if [ $retval -ne 0 ]; then
			Logger "Cannot create timestamp file for $replicaType." "ERROR"
			return $retval
		fi
	fi
}

#WIP function that takes treeList files and gets ctime and mtime for each file, then compares those files to create the conflict file list
function timestampList {
	local replicaPath="${1}" # path to the replica for which a tree needs to be constructed
	local replicaType="${2}" # replica type: initiator, target
	local fileList="${3}" # List of files to get timestamps for
	local timestampFilename="${4}" # filename to output timestamp list (will be prefixed with $replicaType)

	__CheckArguments 4 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local escapedReplicaPath
	local rsyncCmd

	Logger "Getting file stats for $replicaType replica [$replicaPath]." "NOTICE"

	if [ "$REMOTE_OPERATION" == "yes" ] && [ "$replicaType" == "${TARGET[$__type]}" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		_getFileCtimeMtimeRemote "$replicaPath" "$replicaType" "$fileList" "$timestampFilename"
	else
		_getFileCtimeMtimeLocal "$replicaPath" "$replicaType" "$fileList" "$timestampFilename"
	fi
	retval=$?
	return $retval
}

function conflictList {
	local timestampCurrentFilename="${1}" # filename of current timestamp list (will be prefixed with $replicaType)
	local timestampAfterFilename="${2}" # filename of previous timestamp list (will be prefixed with $replicaType)
	local conflictFilename="{3}" # filename of conflicts

	__CheckArguments 3 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local escapedReplicaPath
	local rsyncCmd

	if [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}$timestampCurrentFilename" ] && [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}$timestampCurrentFilename" ]; then
		# Remove prepending replicaPaths
		sed -i'.replicaPath' "s;^${INITIATOR[$__replicaDir]};;g" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}$timestampCurrentFilename"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot remove prepending replicaPaths for current initiator timestamp file." "ERROR"
			return $retval
		fi
		sed -i'.replicaPath' "s;^${TARGET[$__replicaDir]};;g" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}$timestampCurrentFilename"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot remove prepending replicaPaths for current target timestamp file." "ERROR"
			return $retval
		fi
	fi

	if [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}$timestampAfterFilename" ] && [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}$timestampAfterFilename" ]; then
		# Remove prepending replicaPaths
		sed -i'.replicaPath' "s;^${INITIATOR[$__replicaDir]};;g" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}$timestampAfterFilename"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot remove prepending replicaPaths for after initiator timestamp file." "ERROR"
			return $retval
		fi
		sed -i'.replicaPath' "s;^${TARGET[$__replicaDir]};;g" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}$timestampAfterFilename"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot remove prepending replicaPaths for after target timestamp file." "ERROR"
			return $retval
		fi
	fi

	if [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}$timestampAfterFilename" ] && [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}$timestampAfterFilename" ]; then

		Logger "Creating conflictual file list." "NOTICE"

		comm -23 "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}$timestampCurrentFilename" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}$timestampAfterFilename" | sort -t ';' -k 1,1 > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.${INITIATOR[$__type]}.$SCRIPT_PID.$TSTAMP"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot extract conflict data for initiator replica." "ERROR"
			return $retval
		fi
		comm -23 "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}$timestampCurrentFilename" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}$timestampAfterFilename" | sort -t ';' -k 1,1 > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.${TARGET[$__type]}.$SCRIPT_PID.$TSTAMP"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot extract conflict data for target replica.." "ERROR"
			return $retval
		fi

		join -j 1 -t ';' -o 1.1,1.2,1.3,2.2,2.3 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.${INITIATOR[$__type]}.$SCRIPT_PID.$TSTAMP" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.${TARGET[$__type]}.$SCRIPT_PID.$TSTAMP" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.comapre.$SCRIPT_PID.$TSTAMP"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot create conflict list file." "ERROR"
			return $retval
		fi

	fi
}

# rsync does sync with mtime, but file attribute modifications only change ctime.
# Hence, detect newer ctime on the replica that gets updated first with CONFLICT_PREVALANCE and update all newer file attributes on this replica before real update
function syncAttrs {
	local initiatorReplica="${1}"
	local targetReplica="${2}"
	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG

	local rsyncCmd
	local retval

	local sourceDir
	local destDir
	local escSourceDir
	local escDestDir
	local destReplica

	if [ "$LOCAL_OS" == "BusyBox" ] || [ "$LOCAL_OS" == "Android" ] || [ "$REMOTE_OS" == "BusyBox" ] || [ "$REMOTE_OS" == "Android" ]; then
		Logger "Skipping acl synchronization. Busybox does not have join command." "NOTICE"
		return 0
	fi

	Logger "Getting list of files that need updates." "NOTICE"

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -i -n $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_PARTIAL_EXCLUDE -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE \"$initiatorReplica\" $REMOTE_USER@$REMOTE_HOST:\"$targetReplica\" >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2>&1 &"
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -i -n $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_PARTIAL_EXCLUDE --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE \"$initiatorReplica\" \"$targetReplica\" >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2>&1 &"
	fi
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
	retval=$?

	if [ $retval -ne 0 ] && [ $retval -ne 24 ]; then
		Logger "Getting list of files that need updates failed [$retval]. Stopping execution." "CRITICAL" $retval
		_LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Rsync output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "NOTICE"
		fi
		return $retval
	else
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "List:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP)" "VERBOSE"
		fi
		( grep -Ev "^[^ ]*(c|s|t)[^ ]* " "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" || :) | ( grep -E "^[^ ]*(p|o|g|a)[^ ]* " || :) | sed -e 's/^[^ ]* //' >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID.$TSTAMP"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot prepare file list for attribute sync." "CRITICAL" $retval
			exit 1
		fi
	fi

	Logger "Getting ctimes for pending files on initiator." "NOTICE"
	_getFileCtimeMtimeLocal "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID.$TSTAMP" "$RUN_DIR/$PROGRAM.ctime_mtime___.${INITIATOR[$__type]}.$SCRIPT_PID.$TSTAMP" &
	pids="$!"

	Logger "Getting ctimes for pending files on target." "NOTICE"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_getFileCtimeMtimeLocal "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID.$TSTAMP" "$RUN_DIR/$PROGRAM.ctime_mtime___.${TARGET[$__type]}.$SCRIPT_PID.$TSTAMP" &
		pids="$pids;$!"
	else
		_getFileCtimeMtimeRemote "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID.$TSTAMP" "$RUN_DIR/$PROGRAM.ctime_mtime___.${TARGET[$__type]}.$SCRIPT_PID.$TSTAMP" &
		pids="$pids;$!"
	fi
	WaitForTaskCompletion $pids $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Getting ctime attributes failed." "CRITICAL" $retval
		return 1
	fi

	# If target gets updated first, then sync_attr must update initiators attrs first
	# For join, remove leading replica paths

	sed -i'.tmp' "s;^${INITIATOR[$__replicaDir]};;g" "$RUN_DIR/$PROGRAM.ctime_mtime___.${INITIATOR[$__type]}.$SCRIPT_PID.$TSTAMP"
	sed -i'.tmp' "s;^${TARGET[$__replicaDir]};;g" "$RUN_DIR/$PROGRAM.ctime_mtime___.${TARGET[$__type]}.$SCRIPT_PID.$TSTAMP"

	if [ "$CONFLICT_PREVALANCE" == "${TARGET[$__type]}" ]; then
		sourceDir="${INITIATOR[$__replicaDir]}"
		escSourceDir=$(EscapeSpaces "${INITIATOR[$__replicaDir]}")
		destDir="${TARGET[$__replicaDir]}"
		escDestDir=$(EscapeSpaces "${TARGET[$__replicaDir]}")
		destReplica="${TARGET[$__type]}"
		join -j 1 -t ';' -o 1.1,1.2,2.2 "$RUN_DIR/$PROGRAM.ctime_mtime___.${INITIATOR[$__type]}.$SCRIPT_PID.$TSTAMP" "$RUN_DIR/$PROGRAM.ctime_mtime___.${TARGET[$__type]}.$SCRIPT_PID.$TSTAMP" | awk -F';' '{if ($2 > $3) print $1}' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID.$TSTAMP"
	else
		sourceDir="${TARGET[$__replicaDir]}"
		escSourceDir=$(EscapeSpaces "${TARGET[$__replicaDir]}")
		destDir="${INITIATOR[$__replicaDir]}"
		escDestDir=$(EscapeSpaces "${INITIATOR[$__replicaDir]}")
		destReplica="${INITIATOR[$__type]}"
		join -j 1 -t ';' -o 1.1,1.2,2.2 "$RUN_DIR/$PROGRAM.ctime_mtime___.${TARGET[$__type]}.$SCRIPT_PID.$TSTAMP" "$RUN_DIR/$PROGRAM.ctime_mtime___.${INITIATOR[$__type]}.$SCRIPT_PID.$TSTAMP" | awk -F';' '{if ($2 > $3) print $1}' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID.$TSTAMP"
	fi

	if [ $(wc -l < "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID.$TSTAMP") -eq 0 ]; then
		Logger "Updating file attributes on $destReplica not required" "NOTICE"
		return 0
	fi

	Logger "Updating file attributes on $destReplica." "NOTICE"

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost

		# No rsync args (hence no -r) because files are selected with --from-file
		if [ "$destReplica" == "${INITIATOR[$__type]}" ]; then
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID.$TSTAMP\" $REMOTE_USER@$REMOTE_HOST:\"$escSourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP 2>&1 &"
		else
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID.$TSTAMP\" \"$sourceDir\" $REMOTE_USER@$REMOTE_HOST:\"$escDestDir\" >> $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP 2>&1 &"
		fi
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID.$TSTAMP\" \"$sourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP 2>&1 &"

	fi

	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
	retval=$?

	if [ $retval -ne 0 ] && [ $retval -ne 24 ]; then
		Logger "Updating file attributes on $destReplica [$retval]. Stopping execution." "CRITICAL" $retval
		_LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Rsync output:\n$(cat $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP)" "NOTICE"
		fi
		return 1
	else
		if [ -f "$RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "List:\n$(cat $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP)" "VERBOSE"
		fi
		Logger "Successfully updated file attributes on $destReplica replica." "NOTICE"
	fi
}

# syncUpdate(source replica, destination replica, delete_list_filename)
function syncUpdate {
	local sourceReplica="${1}" # Contains replica type of source: initiator, target
	local destinationReplica="${2}" # Contains replica type of destination: initiator, target
	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG

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
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $backupArgs --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$sourceReplica${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$destinationReplica${INITIATOR[$__deletedListFile]}\" \"$sourceDir\" $REMOTE_USER@$REMOTE_HOST:\"$escDestDir\" >> $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP 2>&1"
		else
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $backupArgs --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$destinationReplica${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$sourceReplica${INITIATOR[$__deletedListFile]}\" $REMOTE_USER@$REMOTE_HOST:\"$escSourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP 2>&1"
		fi
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS $backupArgs --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$sourceReplica${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$destinationReplica${INITIATOR[$__deletedListFile]}\" \"$sourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP 2>&1"
	fi
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	retval=$?

	if [ $retval -ne 0 ] && [ $retval -ne 24 ]; then
		Logger "Updating $destinationReplica replica failed. Stopping execution." "CRITICAL" $retval
		_LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Rsync output:\n$(cat $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP)" "NOTICE"
		fi
		exit 1
	else
		if [ -f "$RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "List:\n$(cat $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP)" "VERBOSE"
		fi
		Logger "Updating $destinationReplica replica succeded." "NOTICE"
		return 0
	fi
}

function _deleteLocal {
	local replicaType="${1}" # Replica type
	local replicaDir="${2}" # Full path to replica
	local deletionDir="${3}" # deletion dir in format .[workdir]/deleted
	__CheckArguments 3 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local parentdir
	local previousFile=""

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
		mkdir -p "$replicaDir$deletionDir"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot create local replica deletion directory in [$replicaDir$deletionDir]." "ERROR" $retval
			exit 1
		fi
	fi

	while read -r files; do
		## On every run, check wheter the next item is already deleted because it is included in a directory already deleted
		if [[ "$files" != "$previousFile/"* ]] && [ "$files" != "" ]; then
			if [ "$SOFT_DELETE" != "no" ]; then
				if [ $_DRYRUN == false ]; then
					if [ -e "$replicaDir$deletionDir/$files" ] || [ -L "$replicaDir$deletionDir/$files" ]; then
						rm -rf "${replicaDir:?}$deletionDir/$files"
					fi

					if [ -e "$replicaDir$files" ] || [ -L "$replicaDir$files" ]; then
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
						retval=$?
						if [ $retval -ne 0 ]; then
							Logger "Cannot move [$replicaDir$files] to deletion directory." "ERROR" $retval
							echo "$files" >> "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__failedDeletedListFile]}"
						else
							echo "$files" >> "$RUN_DIR/$PROGRAM.delete.$replicaType.$SCRIPT_PID.$TSTAMP"
						fi
					fi
				fi
			else
				if [ $_DRYRUN == false ]; then
					if [ -e "$replicaDir$files" ] || [ -L "$replicaDir$files" ]; then
						rm -rf "$replicaDir$files"
						retval=$?
						Logger "Deleting [$replicaDir$files]." "VERBOSE"
						if [ $retval -ne 0 ]; then
							Logger "Cannot delete [$replicaDir$files]." "ERROR" $retval
							echo "$files" >> "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__failedDeletedListFile]}"
						else
							echo "$files" >> "$RUN_DIR/$PROGRAM.delete.$replicaType.$SCRIPT_PID.$TSTAMP"
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
	__CheckArguments 3 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
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
	rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$deletionListFromReplica${INITIATOR[$__deletedListFile]}\" $REMOTE_USER@$REMOTE_HOST:\"$escDestDir/\" >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID.$TSTAMP 2>&1"
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" 2>> "$LOG_FILE"
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Cannot copy the deletion list to remote replica." "ERROR" $retval
		_LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID.$TSTAMP)" "ERROR"
		fi
		exit 1
	fi

$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" \
env sync_on_changes=$sync_on_changes env _DRYRUN="'$_DRYRUN'" \
env FILE_LIST="'$(EscapeSpaces "${TARGET[$__replicaDir]}${TARGET[$__stateDir]}/$deletionListFromReplica${INITIATOR[$__deletedListFile]}")'" env REPLICA_DIR="'$(EscapeSpaces "$replicaDir")'" env SOFT_DELETE="'$SOFT_DELETE'" \
env DELETION_DIR="'$(EscapeSpaces "$deletionDir")'" env FAILED_DELETE_LIST="'$failedDeleteList'" env SUCCESS_DELETE_LIST="'$successDeleteList'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' >> "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID.$TSTAMP" 2>&1
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

	## Empty earlier failed delete list
	> "$FAILED_DELETE_LIST"
	> "$SUCCESS_DELETE_LIST"

	parentdir=
	previousFile=""

	if [ ! -d "$REPLICA_DIR$DELETION_DIR" ] && [ $_DRYRUN == false ]; then
		mkdir -p "$REPLICA_DIR$DELETION_DIR"
		retval=$?
		if [ $retval -ne 0 ]; then
			RemoteLogger "Cannot create remote replica deletion directory in [$REPLICA_DIR$DELETION_DIR]." "ERROR" $retval
			exit 1
		fi
	fi

	while read -r files; do
		## On every run, check wheter the next item is already deleted because it is included in a directory already deleted
		if [[ "$files" != "$previousFile/"* ]] && [ "$files" != "" ]; then

			if [ "$SOFT_DELETE" != "no" ]; then
				if [ $_DRYRUN == false ]; then
					if [ -e "$REPLICA_DIR$DELETION_DIR/$files" ] || [ -L "$REPLICA_DIR$DELETION_DIR/$files" ]; then
						rm -rf "$REPLICA_DIR$DELETION_DIR/$files"
					fi

					if [ -e "$REPLICA_DIR$files" ] || [ -L "$REPLICA_DIR$files" ]; then
						# In order to keep full path on soft deletion, create parent directories before move
						parentdir="$(dirname "$files")"
						if [ "$parentdir" != "." ]; then
							RemoteLogger "Moving deleted file [$REPLICA_DIR$files] to [$REPLICA_DIR$DELETION_DIR/$parentdir]." "VERBOSE"
							mkdir -p "$REPLICA_DIR$DELETION_DIR/$parentdir"
							mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$DELETION_DIR/$parentdir"
						else
							RemoteLogger "Moving deleted file [$REPLICA_DIR$files] to [$REPLICA_DIR$DELETION_DIR]." "VERBOSE"
							mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$DELETION_DIR"
						fi
						retval=$?
						if [ $retval -ne 0 ]; then
							RemoteLogger "Cannot move [$REPLICA_DIR$files] to deletion directory." "ERROR" $retval
							# Using $files instead of $REPLICA_DIR$files here so the list is ready for next run
							echo "$files" >> "$FAILED_DELETE_LIST"
						else
							echo "$files" >> "$SUCCESS_DELETE_LIST"
						fi
					fi
				fi
			else
				if [ $_DRYRUN == false ]; then
					if [ -e "$REPLICA_DIR$files" ] || [ -e "$REPLICA_DIR$files" ]; then
						RemoteLogger "Deleting [$REPLICA_DIR$files]." "VERBOSE"
						rm -rf "$REPLICA_DIR$files"
						retval=$?
						if [ $retval -ne 0 ]; then
							RemoteLogger "Cannot delete [$REPLICA_DIR$files]." "ERROR" $retval
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

	if [ -s "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID.$TSTAMP" ]; then
		(
		_LOGGER_PREFIX="RR"
		Logger "$(cat $RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID.$TSTAMP)" "ERROR"
		)
	fi

	## Copy back the deleted failed file list
	rsyncCmd="$(type -p $RSYNC_EXECUTABLE) -r --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" --include \"$(dirname ${TARGET[$__stateDir]})\" --include \"${TARGET[$__stateDir]}\" --include \"${TARGET[$__stateDir]}/$replicaType${TARGET[$__failedDeletedListFile]}\" --include \"${TARGET[$__stateDir]}/$replicaType${TARGET[$__successDeletedListFile]}\" --exclude='*' $REMOTE_USER@$REMOTE_HOST:\"$(EscapeSpaces ${TARGET[$__replicaDir]})\" \"${INITIATOR[$__replicaDir]}\" > \"$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID.$TSTAMP\""
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" 2>> "$LOG_FILE"
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Cannot copy back the failed deletion list to initiator replica." "CRITICAL" $retval
		_LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Comand output: $(cat $RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID.$TSTAMP)" "NOTICE"
		fi
		exit 1
	fi
	return 0
}

# delete_Propagation(replica type)
function deletionPropagation {
	local replicaType="${1}" # Contains replica type: initiator, target where to delete
	__CheckArguments 1 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local replicaDir
	local deleteDir

	Logger "Propagating deletions to $replicaType replica." "NOTICE"

	if [ "$replicaType" == "${INITIATOR[$__type]}" ]; then
		if [ $(ArrayContains "${INITIATOR[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ]; then
			replicaDir="${INITIATOR[$__replicaDir]}"
			deleteDir="${INITIATOR[$__deleteDir]}"

			_deleteLocal "${INITIATOR[$__type]}" "$replicaDir" "$deleteDir"
			retval=$?
			if [ $retval -ne 0 ]; then
				Logger "Deletion on $replicaType replica failed." "CRITICAL" $retval
				exit 1
			fi
		else
			Logger "Skipping deletion on replica $replicaType." "NOTICE"
		fi
	elif [ "$replicaType" == "${TARGET[$__type]}" ]; then
		if [ $(ArrayContains "${TARGET[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ]; then
			replicaDir="${TARGET[$__replicaDir]}"
			deleteDir="${TARGET[$__deleteDir]}"

			if [ "$REMOTE_OPERATION" == "yes" ]; then
				_deleteRemote "${TARGET[$__type]}" "$replicaDir" "$deleteDir"
			else
				_deleteLocal "${TARGET[$__type]}" "$replicaDir" "$deleteDir"
			fi
			retval=$?
			if [ $retval -eq 0 ]; then
				if [ -f "$RUN_DIR/$PROGRAM._delete_remote.$SCRIPT_PID.$TSTAMP" ]; then
					Logger "Remote:\n$(cat $RUN_DIR/$PROGRAM._delete_remote.$SCRIPT_PID.$TSTAMP)" "VERBOSE"
				fi
				return $retval
			else
				Logger "Deletion on $replicaType failed." "CRITICAL"
				if [ -f "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID.$TSTAMP" ]; then
					Logger "Remote:\n$(cat $RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID.$TSTAMP)" "CRITICAL" $retval
				fi
				exit 1
			fi
		else
			Logger "Skipping deletion on replica $replicaType." "NOTICE"
		fi
	fi
}

###### Sync function in 9 steps
######
###### Step 0a & 0b: Create current file list of replicas
###### Step 1a & 1b: Create deleted file list of replicas
###### Step 2a & 2b: Create ctime & mtime file list of replicas
###### Step 3a & 3b: Merge conflict file list
###### Step 4: Update file attributes
###### Step 5a & 5b: Update replicas
###### Step 6a & 6b: Propagate deletions on replicas
###### Step 7a & 7b: Create after run file list of replicas
###### Step 8a & 8b: Create ctime & mtime file lost of replicas

function Sync {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
				Logger "Trying to resume aborted execution on $($STAT_CMD "${INITIATOR[$__initiatorLastActionFile]}") at task [$resumeInitiator] for initiator. [$resumeCount] previous tries." "NOTICE"
				echo $(($resumeCount+1)) > "${INITIATOR[$__resumeCount]}"
			else
				resumeInitiator="none"
			fi

			if [ "$resumeTarget" != "synced" ]; then
				Logger "Trying to resume aborted execution on $($STAT_CMD "${INITIATOR[$__targetLastActionFile]}") as task [$resumeTarget] for target. [$resumeCount] previous tries." "NOTICE"
				echo $(($resumeCount+1)) > "${INITIATOR[$__resumeCount]}"
			else
				resumeTarget="none"
			fi
		else
			if [ $RESUME_TRY -ne 0 ]; then
				Logger "Will not resume aborted execution. Too many resume tries [$resumeCount]." "WARN"
			fi
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
			treeList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__treeCurrentFile]}" &
			initiatorPid="$!"
		fi

		if [ "$resumeTarget" == "none" ] || [ "$resumeTarget" == "${SYNC_ACTION[0]}" ]; then
			treeList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__treeCurrentFile]}" &
			targetPid="$!"
		fi

		WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
		if [ $? -ne 0 ]; then
			IFS=';' read -r -a pidArray <<< "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_${FUNCNAME[0]}\")"
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

		WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
		if [ $? -ne 0 ]; then
			IFS=';' read -r -a pidArray <<< "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_${FUNCNAME[0]}\")"
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

	## Step 2a & 2b
	if [ "$resumeInitiator" == "${SYNC_ACTION[2]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[2]}" ]; then
		#if [[ "$RSYNC_ATTR_ARGS" == *"-X"* ]] || [[ "$RSYNC_ATTR_ARGS" == *"-A"* ]] || [ "$LOG_CONFLICTS" == "yes" ]; then
		#TODO: refactor in v1.3 with syncattrs
		if [ "$LOG_CONFLICTS" == "yes" ]; then

			if [ "$resumeInitiator" == "${SYNC_ACTION[2]}" ]; then
				timestampList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__treeCurrentFile]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__timestampCurrentFile]}" &
				initiatorPid="$!"
			fi

			if [ "$resumeTarget" == "${SYNC_ACTION[2]}" ]; then
				timestampList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${TARGET[$__treeCurrentFile]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${TARGET[$__timestampCurrentFile]}" &
				targetPid="$!"
			fi

			WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
			if [ $? -ne 0 ]; then
				IFS=';' read -r -a pidArray <<< "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_${FUNCNAME[0]}\")"
				initiatorFail=false
				targetFail=false
				for pid in "${pidArray[@]}"; do
					pid=${pid%:*}
					if [ "$pid" == "$initiatorPid" ]; then
						echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__initiatorLastActionFile]}"
						initiatorFail=true
					elif [ "$pid" == "$targetPid" ]; then
						echo "${SYNC_ACTION[2]}" > "${INITIATOR[$__targetLastActionFile]}"
						targetFail=true
					fi
				done

				if [ $initiatorFail == false ]; then
					echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__initiatorLastActionFile]}"
				fi

				if [ $targetFail == false ]; then
					echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__targetLastActionFile]}"
				fi

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
		if [ "$LOG_CONFLICTS" == "yes" ]; then
			conflictList "${INITIATOR[$__timestampCurrentFile]}" "${INITIATOR[$__timestampAfterFileNoSuffix]}" "${INITIATOR[$__conflictListFile]}" &
			WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
			if [ $? -ne 0 ]; then
				echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__initiatorLastActionFile]}"
				echo "${SYNC_ACTION[3]}" > "${INITIATOR[$__targetLastActionFile]}"
				exit 1
			else
				echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__initiatorLastActionFile]}"
				echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__targetLastActionFile]}"
				resumeInitiator="${SYNC_ACTION[4]}"
				resumeTarget="${SYNC_ACTION[4]}"

			fi
		else
			echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[4]}"
			resumeTarget="${SYNC_ACTION[4]}"
		fi
	fi

	## Step 4
	if [ "$resumeInitiator" == "${SYNC_ACTION[4]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[4]}" ]; then
		if [[ "$RSYNC_ATTR_ARGS" == *"-X"* ]] || [[ "$RSYNC_ATTR_ARGS" == *"-A"* ]]; then
			syncAttrs "${INITIATOR[$__replicaDir]}" "$TARGET_SYNC_DIR" &
			WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
			if [ $? -ne 0 ]; then
				echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__initiatorLastActionFile]}"
				echo "${SYNC_ACTION[4]}" > "${INITIATOR[$__targetLastActionFile]}"
				exit 1
			else
				echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__initiatorLastActionFile]}"
				echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__targetLastActionFile]}"
				resumeInitiator="${SYNC_ACTION[5]}"
				resumeTarget="${SYNC_ACTION[5]}"

			fi
		else
			echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[5]}"
			resumeTarget="${SYNC_ACTION[5]}"
		fi
	fi

	## Step 5a & 5b
	if [ "$resumeInitiator" == "${SYNC_ACTION[5]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[5]}" ]; then
		if [ "$CONFLICT_PREVALANCE" == "${TARGET[$__type]}" ]; then
			if [ "$resumeTarget" == "${SYNC_ACTION[5]}" ]; then
				syncUpdate "${TARGET[$__type]}" "${INITIATOR[$__type]}" &
				WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
				if [ $? -ne 0 ]; then
					echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__targetLastActionFile]}"
					resumeTarget="${SYNC_ACTION[5]}"
					exit 1
				else
					echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__targetLastActionFile]}"
					resumeTarget="${SYNC_ACTION[6]}"
				fi
			fi
			if [ "$resumeInitiator" == "${SYNC_ACTION[5]}" ]; then
				syncUpdate "${INITIATOR[$__type]}" "${TARGET[$__type]}" &
				WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
				if [ $? -ne 0 ]; then
					echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					resumeInitiator="${SYNC_ACTION[5]}"
					exit 1
				else
					echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					resumeInitiator="${SYNC_ACTION[6]}"
				fi
			fi
		else
			if [ "$resumeInitiator" == "${SYNC_ACTION[5]}" ]; then
				syncUpdate "${INITIATOR[$__type]}" "${TARGET[$__type]}" &
				WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
				if [ $? -ne 0 ]; then
					echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					resumeInitiator="${SYNC_ACTION[5]}"
					exit 1
				else
					echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					resumeInitiator="${SYNC_ACTION[6]}"
				fi
			fi
			if [ "$resumeTarget" == "${SYNC_ACTION[5]}" ]; then
				syncUpdate "${TARGET[$__type]}" "${INITIATOR[$__type]}" &
				WaitForTaskCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
				if [ $? -ne 0 ]; then
					echo "${SYNC_ACTION[5]}" > "${INITIATOR[$__targetLastActionFile]}"
					resumeTarget="${SYNC_ACTION[5]}"
					exit 1
				else
					echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__targetLastActionFile]}"
					resumeTarget="${SYNC_ACTION[6]}"
				fi
			fi
		fi
	fi

	## Step 6a & 6b
	if [ "$resumeInitiator" == "${SYNC_ACTION[6]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[6]}" ]; then
		if [ "$resumeInitiator" == "${SYNC_ACTION[6]}" ]; then
			deletionPropagation "${INITIATOR[$__type]}" &
			initiatorPid="$!"
		fi

		if [ "$resumeTarget" == "${SYNC_ACTION[6]}" ]; then
			deletionPropagation "${TARGET[$__type]}" &
			targetPid="$!"
		fi

		WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
		if [ $? -ne 0 ]; then
			IFS=';' read -r -a pidArray <<< "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_${FUNCNAME[0]}\")"
			initiatorFail=false
			targetFail=false
			for pid in "${pidArray[@]}"; do
				pid=${pid%:*}
				if [ "$pid" == "$initiatorPid" ]; then
					echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					initiatorFail=true
				elif [ "$pid" == "$targetPid" ]; then
					echo "${SYNC_ACTION[6]}" > "${INITIATOR[$__targetLastActionFile]}"
					targetFail=true
				fi
			done

			if [ $initiatorFail == false ]; then
				echo "${SYNC_ACTION[7]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			fi

			if [ $targetFail == false ]; then
				echo "${SYNC_ACTION[7]}" > "${INITIATOR[$__targetLastActionFile]}"
			fi

			exit 1
		else
			echo "${SYNC_ACTION[7]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[7]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[7]}"
			resumeTarget="${SYNC_ACTION[7]}"

		fi
	fi

	## Step 7a & 7b
	if [ "$resumeInitiator" == "${SYNC_ACTION[7]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[7]}" ]; then
		if [ "$resumeInitiator" == "${SYNC_ACTION[7]}" ]; then
			treeList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__treeAfterFile]}" &
			initiatorPid="$!"
		fi

		if [ "$resumeTarget" == "${SYNC_ACTION[7]}" ]; then
			treeList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__treeAfterFile]}" &
			targetPid="$!"
		fi

		WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
		if [ $? -ne 0 ]; then
			IFS=';' read -r -a pidArray <<< "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_${FUNCNAME[0]}\")"
			initiatorFail=false
			targetFail=false
			for pid in "${pidArray[@]}"; do
				pid=${pid%:*}
				if [ "$pid" == "$initiatorPid" ]; then
					echo "${SYNC_ACTION[7]}" > "${INITIATOR[$__initiatorLastActionFile]}"
					initiatorFail=true
				elif [ "$pid" == "$targetPid" ]; then
					echo "${SYNC_ACTION[7]}" > "${INITIATOR[$__targetLastActionFile]}"
					targetFail=true
				fi
			done

			if [ $initiatorFail == false ]; then
				echo "${SYNC_ACTION[8]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			fi

			if [ $targetFail == false ]; then
				echo "${SYNC_ACTION[8]}" > "${INITIATOR[$__targetLastActionFile]}"
			fi

			exit 1
		else
			echo "${SYNC_ACTION[8]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[8]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[8]}"
			resumeTarget="${SYNC_ACTION[8]}"
		fi
	fi

	# Step 8a & 8b
	if [ "$resumeInitiator" == "${SYNC_ACTION[8]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[8]}" ]; then
		#if [[ "$RSYNC_ATTR_ARGS" == *"-X"* ]] || [[ "$RSYNC_ATTR_ARGS" == *"-A"* ]] || [ "$LOG_CONFLICTS" == "yes" ]; then
		#TODO: refactor in v1.3 with syncattrs
		if [ "$LOG_CONFLICTS" == "yes" ]; then

			if [ "$resumeInitiator" == "${SYNC_ACTION[8]}" ]; then
				timestampList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__treeAfterFile]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__timestampAfterFile]}" &
				initiatorPid="$!"
			fi

			if [ "$resumeTarget" == "${SYNC_ACTION[8]}" ]; then
				timestampList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${TARGET[$__treeAfterFile]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${TARGET[$__timestampAfterFile]}" &
				targetPid="$!"
			fi

			WaitForTaskCompletion "$initiatorPid;$targetPid" $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
			if [ $? -ne 0 ]; then
				IFS=';' read -r -a pidArray <<< "$(eval echo \"\$WAIT_FOR_TASK_COMPLETION_${FUNCNAME[0]}\")"
				initiatorFail=false
				targetFail=false
				for pid in "${pidArray[@]}"; do
					pid=${pid%:*}
					if [ "$pid" == "$initiatorPid" ]; then
						echo "${SYNC_ACTION[8]}" > "${INITIATOR[$__initiatorLastActionFile]}"
						initiatorFail=true
					elif [ "$pid" == "$targetPid" ]; then
						echo "${SYNC_ACTION[8]}" > "${INITIATOR[$__targetLastActionFile]}"
						targetFail=true
					fi
				done

				if [ $initiatorFail == false ]; then
					echo "${SYNC_ACTION[9]}" > "${INITIATOR[$__initiatorLastActionFile]}"
				fi

				if [ $targetFail == false ]; then
					echo "${SYNC_ACTION[9]}" > "${INITIATOR[$__targetLastActionFile]}"
				fi

				exit 1
			else
				echo "${SYNC_ACTION[9]}" > "${INITIATOR[$__initiatorLastActionFile]}"
				echo "${SYNC_ACTION[9]}" > "${INITIATOR[$__targetLastActionFile]}"
				resumeInitiator="${SYNC_ACTION[9]}"
				resumeTarget="${SYNC_ACTION[9]}"
			fi
		else
			echo "${SYNC_ACTION[9]}" > "${INITIATOR[$__initiatorLastActionFile]}"
			echo "${SYNC_ACTION[9]}" > "${INITIATOR[$__targetLastActionFile]}"
			resumeInitiator="${SYNC_ACTION[9]}"
			resumeTarget="${SYNC_ACTION[3]}"
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

	__CheckArguments 4 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ "$LOCAL_OS" == "Busybox" ] || [ "$LOCAL_OS" == "Android" ]; then
		Logger "Skipping $deletionType deletion on $replicaType. Busybox find -ctime not supported." "NOTICE"
		return 0
	fi

	if [ -d "$replicaDeletionPath" ]; then
		if [ $_DRYRUN == true ]; then
			Logger "Listing files older than $changeTime days on $replicaType replica for $deletionType deletion. Does not remove anything." "NOTICE"
		else
			Logger "Removing files older than $changeTime days on $replicaType replica for $deletionType deletion." "NOTICE"
		fi

		$FIND_CMD "$replicaDeletionPath" -type f -ctime +"$changeTime" -print0 | xargs -0 -I {} bash -c 'export file="{}"; if [ '$_LOGGER_VERBOSE' == true ]; then echo "On "'$replicaType'" will delete file {}"; fi; if [ '$_DRYRUN' == false ]; then rm -f "$file"; fi' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Error while executing file cleanup on $replicaType replica." "ERROR" $retval
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
		else
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "VERBOSE"
			Logger "File cleanup complete on $replicaType replica." "NOTICE"
		fi
		$FIND_CMD "$replicaDeletionPath" -type d -empty -ctime +"$changeTime" -print0 | xargs -0 -I {} bash -c 'export file="{}"; if [ '$_LOGGER_VERBOSE' == true ]; then echo "On "'$replicaType'" will delete directory {}"; fi; if [ '$_DRYRUN' == false ]; then rm -rf "{}"; fi' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Error while executing directory cleanup on $replicaType replica." "ERROR" $retval
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
		else
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "VERBOSE"
			Logger "Directory cleanup complete on $replicaType replica." "NOTICE"
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

	__CheckArguments 4 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ "$REMOTE_OS" == "BusyBox" ] || [ "$REMOTE_OS" == "Android" ]; then
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

$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" \
env _DRYRUN="'$_DRYRUN'" env replicaType="'$replicaType'" env replicaDeletionPath="'$replicaDeletionPath'" env changeTime="'$changeTime'" env REMOTE_FIND_CMD="'$REMOTE_FIND_CMD'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1

# Cannot launch log function from xargs, ugly hack
if [ -d "$replicaDeletionPath" ]; then
	$REMOTE_FIND_CMD "$replicaDeletionPath" -type f -ctime +"$changeTime" -print0 | xargs -0 -I {} bash -c 'export file="{}"; if [ '$_LOGGER_VERBOSE' == true ]; then echo "On "'$replicaType'" will delete file {}"; fi; if [ '$_DRYRUN' == false ]; then rm -f "$file"; fi'
	retval1=$?
	$REMOTE_FIND_CMD "$replicaDeletionPath" -type d -empty -ctime +"$changeTime" -print0 | xargs -0 -I {} bash -c 'export file="{}"; if [ '$_LOGGER_VERBOSE' == true ]; then echo "On "'$replicaType'" will delete directory {}"; fi; if [ '$_DRYRUN' == false ]; then rm -rf "{}"; fi'
	retval2=$?
else
	echo "The $replicaType replica dir [$replicaDeletionPath] does not exist. Skipping cleaning of old files"
fi
exit $((retval1 + retval2))
ENDSSH
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Error while executing cleanup on remote $replicaType replica." "ERROR" $retval
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
	else
		Logger "Cleanup complete on $replicaType replica." "NOTICE"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "VERBOSE"

	fi
}

function SoftDelete {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
		WaitForTaskCompletion $pids $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
		if [ $? -ne 0 ] && [ "$(eval echo \"\$HARD_MAX_EXEC_TIME_REACHED_${FUNCNAME[0]}\")" == true ]; then
			exit 1
		fi
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
		WaitForTaskCompletion $pids $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME $SLEEP_TIME $KEEP_LOGGING false true false
		if [ $? -ne 0 ] && [ "$(eval echo \"\$HARD_MAX_EXEC_TIME_REACHED_${FUNCNAME[0]}\")" == true ]; then
			exit 1
		fi
	fi
}

function _SummaryFromFile {
	local replicaPath="${1}"
	local summaryFile="${2}"
	local direction="${3}"

	__CheckArguments 3 $# "$@"	#__WITH_PARANOIA_DEBUG

	if [ -f "$summaryFile" ]; then
		while read -r file; do
			# grep -E "^<|^>|^\." = Remove all lines that do not begin with <, > or . to deal with a bizarre bug involving rsync 3.0.6 / CentOS 6 and --skip-compress showing 'adding zip' line for every skipped compressed extension
			if echo "$file" | grep -E "^<|^>|^\." > /dev/null 2>&1; then
				# awk removes first part of line until space, then show all others
				Logger "$direction $replicaPath$(echo $file | awk '{for (i=2; i<NF; i++) printf $i " "; print $NF}')" "ALWAYS"
			fi
		done < "$summaryFile"
	fi
}

function Summary {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	(
	_LOGGER_PREFIX=""

	Logger "Attrib updates: INITIATOR << >> TARGET" "ALWAYS"

	_SummaryFromFile "${TARGET[$__replicaDir]}" "$RUN_DIR/$PROGRAM.attr-update.target.$SCRIPT_PID.$TSTAMP" "~ >>"
	_SummaryFromFile "${INITIATOR[$__replicaDir]}" "$RUN_DIR/$PROGRAM.attr-update.initiator.$SCRIPT_PID.$TSTAMP" "~ <<"

	Logger "File transfers: INITIATOR << >> TARGET" "ALWAYS"
	_SummaryFromFile "${TARGET[$__replicaDir]}" "$RUN_DIR/$PROGRAM.update.target.$SCRIPT_PID.$TSTAMP" "+ >>"
	_SummaryFromFile "${INITIATOR[$__replicaDir]}" "$RUN_DIR/$PROGRAM.update.initiator.$SCRIPT_PID.$TSTAMP" "+ <<"

	Logger "File deletions: INITIATOR << >> TARGET" "ALWAYS"
	if [ "$REMOTE_OPERATION" == "yes" ]; then
		_SummaryFromFile "${TARGET[$__replicaDir]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/target${TARGET[$__successDeletedListFile]}" "- >>"
	else
		_SummaryFromFile "${TARGET[$__replicaDir]}" "$RUN_DIR/$PROGRAM.delete.target.$SCRIPT_PID.$TSTAMP" "- >>"
	fi
	_SummaryFromFile "${INITIATOR[$__replicaDir]}" "$RUN_DIR/$PROGRAM.delete.initiator.$SCRIPT_PID.$TSTAMP" "- <<"
	)
}

function LogConflicts {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	local subject
	local body

	(
	_LOGGER_PREFIX=""
	Logger "File conflicts: INITIATOR << >> TARGET" "ALWAYS"
	if [ -f "$RUN_DIR/$PROGRAM.conflictList.comapre.$SCRIPT_PID.$TSTAMP" ]; then
		echo "" > "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__conflictListFile]}"
		while read -r line; do
			echo "${INITIATOR[$__replicaDir]}$(echo $line | awk -F';' '{print $1}') -- ${TARGET[$__replicaDir]}$(echo $line | awk -F';' '{print $1}')" >> "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__conflictListFile]}"
		done < "$RUN_DIR/$PROGRAM.conflictList.comapre.$SCRIPT_PID.$TSTAMP"

		Logger "$(cat ${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__conflictListFile]})" "ALWAYS"

		if [ "$ALERT_CONFLICTS" == "yes" ] && [ -s "$RUN_DIR/$PROGRAM.conflictList.comapre.$SCRIPT_PID.$TSTAMP" ]; then
			subject="Conflictual files found in [$INSTANCE_ID]"
			body="List of conflictual files:"$'\n'"$(cat ${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__conflictListFile]})"

			SendEmail "$subject" "$body" "$DESTINATION_MAILS" "" "$SENDER_MAIL" "$SMTP_SERVER" "$SMTP_PORT" "$SMTP_ENCRYPTION" "$SMTP_USER" "$SMTP_PASSWORD"
		fi
	fi
	)
}

function Init {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
	INITIATOR[$__updateTriggerFile]="$INITIATOR_SYNC_DIR$OSYNC_DIR/.osync-update.push"

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

	PARTIAL_DIR="${INITIATOR[$__partialDir]}"

	## Set sync only function arguments for rsync
	SYNC_OPTS="-u"

	if [ $_LOGGER_VERBOSE == true ] || [ $_SUMMARY == true ]; then
		SYNC_OPTS=$SYNC_OPTS" -i"
	fi

	if [ $STATS == true ]; then
		SYNC_OPTS=$SYNC_OPTS" --stats"
	fi

	## Add Rsync include / exclude patterns
	RsyncPatterns

	## Conflict options
	if [ "$CONFLICT_BACKUP" != "no" ]; then
		INITIATOR_BACKUP="--backup --backup-dir=\"${INITIATOR[$__backupDir]}\""
		TARGET_BACKUP="--backup --backup-dir=\"${TARGET[$__backupDir]}\""
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
	'timestampList-list'
	'conflict-list'
	'sync_attrs'
	'update-replica'
	'delete-propagation'
	'replica-tree-after'
	'timestampList-after'
	'synced'
	)
}

function Main {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	HandleLocks
	Sync
}

function Usage {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$IS_STABLE" != "yes" ]; then
		echo -e "\e[93mThis is an unstable dev build. Please use with caution.\e[0m"
	fi

	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo "$AUTHOR"
	echo "$CONTACT"
	echo ""
	echo "You may use $PROGRAM with a full blown configuration file, or use its default options for quick command line sync."
	echo "Usage: $0 /path/to/config/file [OPTIONS]"
	echo "or     $0 --initiator=/path/to/initiator/replica --target=/path/to/target/replica [OPTIONS] [QUICKSYNC OPTIONS]"
	echo "or     $0 --initiator=/path/to/initiator/replica --target=ssh://[backupuser]@remotehost.com[:portnumber]//path/to/target/replica [OPTIONS] [QUICKSYNC OPTIONS]"
	echo ""
	echo "[OPTIONS]"
	echo "--dry                  Will run osync without actually doing anything; just testing"
	echo "--no-prefix            Will suppress time / date suffix from output"
	echo "--silent               Will run osync without any output to stdout, used for cron jobs"
	echo "--errors-only          Output only errors (can be combined with silent or verbose)"
	echo "--summary              Outputs a list of transferred / deleted files at the end of the run"
	echo "--log-conflicts        Outputs a list of conflicted files"
	echo "--alert-conflicts      Send an email if conflictual files found (implies --log-conflicts)"
	echo "--verbose              Increases output"
	echo "--stats                Adds rsync transfer statistics to verbose output"
	echo "--partial              Allows rsync to keep partial downloads that can be resumed later (experimental)"
	echo "--no-maxtime           Disables any soft and hard execution time checks"
	echo "--force-unlock         Will override any existing active or dead locks on initiator and target replica"
	echo "--on-changes           Will launch a sync task after a short wait period if there is some file activity on initiator replica. You should try daemon mode instead"
	echo "--no-resume            Do not try to resume a failed run. By default, execution is resumed once"

	echo ""
	echo "[QUICKSYNC OPTIONS]"
	echo "--initiator=\"\"		Master replica path. Will contain state and backup directory (is mandatory)"
	echo "--target=\"\" 		Local or remote target replica path. Can be a ssh uri like ssh://user@host.com:22//path/to/target/replica (is mandatory)"
	echo "--rsakey=\"\"		Alternative path to rsa private key for ssh connection to target replica"
	echo "--password-file=\"\"      If no rsa private key is used for ssh authentication, a password file can be used"
	echo "--remote-token=\"\"       When using ssh filter protection, you must specify the remote token set in ssh_filter.sh"
	echo "--instance-id=\"\"	Optional sync task name to identify this synchronization task when using multiple targets"
	echo "--skip-deletion=\"\"      You may skip deletion propagation on initiator or target. Valid values: initiator target initiator,target"
	echo "--destination-mails=\"\"  Double quoted list of space separated email addresses to send alerts to"
	echo ""
	echo "Additionaly, you may set most osync options at runtime. eg:"
	echo "SOFT_DELETE_DAYS=365 $0 --initiator=/path --target=/other/path"
	echo ""
	exit 128
}

function SyncOnChanges {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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

	if [ ! -d "$INITIATOR_SYNC_DIR" ]; then
		Logger "Initiator directory [$INITIATOR_SYNC_DIR] does not exist. Cannot monitor." "CRITICAL"
		exit 1
	fi

	Logger "#### Running $PROGRAM in file monitor mode." "NOTICE"

	while true; do
		if [ "$ConfigFile" != "" ]; then
			cmd='bash '$osync_cmd' "'$ConfigFile'" '$opts
		else
			cmd='bash '$osync_cmd' '$opts
		fi
		Logger "Daemon cmd: $cmd" "DEBUG"
		eval "$cmd"
		retval=$?
		if [ $retval -ne 0 ] && [ $retval != 2 ]; then
			Logger "osync child exited with error." "ERROR" $retval
		fi

		Logger "#### Monitoring now." "NOTICE"
		if [ "$LOCAL_OS" == "MacOSX" ]; then
			fswatch $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude "$OSYNC_DIR" -1 "$INITIATOR_SYNC_DIR" > /dev/null &
			# Mac fswatch doesn't have timeout switch, replacing wait $! with WaitForTaskCompletion without warning nor spinner and increased SLEEP_TIME to avoid cpu hogging. This sims wait $! with timeout
			WaitForTaskCompletion $! 0 $MAX_WAIT 1 0 true false true
		else
			inotifywait $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude "$OSYNC_DIR" -qq -r -e create -e modify -e delete -e move -e attrib --timeout "$MAX_WAIT" "$INITIATOR_SYNC_DIR" &
			wait $!
		fi
		retval=$?
		if [ $retval -eq 0 ]; then
			Logger "#### Changes detected, waiting $MIN_WAIT seconds before running next sync." "NOTICE"
			sleep $MIN_WAIT
		# inotifywait --timeout result is 2, WaitForTaskCompletion HardTimeout is 1
		elif [ "$LOCAL_OS" == "MacOSX" ]; then
			Logger "#### Changes or error detected, waiting $MIN_WAIT seconds before running next sync." "NOTICE"
		elif [ $retval -eq 2 ]; then
			Logger "#### $MAX_WAIT timeout reached, running sync." "NOTICE"
		elif [ $retval -eq 1 ]; then
			Logger "#### inotify error detected, waiting $MIN_WAIT seconds before running next sync." "ERROR" $retval
			sleep $MIN_WAIT
		fi
	done

}

#### SCRIPT ENTRY POINT

# quicksync mode settings, overriden by config file
STATS=false
PARTIAL=no
if [ "$CONFLICT_PREVALANCE" == "" ]; then
	CONFLICT_PREVALANCE=initiator
fi

DESTINATION_MAILS=""
INITIATOR_LOCK_FILE_EXISTS=false
TARGET_LOCK_FILE_EXISTS=false
FORCE_UNLOCK=false
LOG_CONFLICTS="no"
ALERT_CONFLICTS="no"
no_maxtime=false
opts=""
ERROR_ALERT=false
WARN_ALERT=false
# Number of CTRL+C needed to stop script
SOFT_STOP=2
# Number of given replicas in command line
_QUICK_SYNC=0
sync_on_changes=false
_NOLOCKS=false
osync_cmd=$0
_SUMMARY=false


function GetCommandlineArguments {
	local isFirstArgument=true

	if [ $# -eq 0 ]
	then
		Usage
	fi

	for i in "$@"; do
		case $i in
			--dry)
			_DRYRUN=true
			opts=$opts" --dry"
			;;
			--silent)
			_LOGGER_SILENT=true
			opts=$opts" --silent"
			;;
			--verbose)
			_LOGGER_VERBOSE=true
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
			;;
			--target=*)
			_QUICK_SYNC=$(($_QUICK_SYNC + 1))
			TARGET_SYNC_DIR=${i##*=}
			opts=$opts" --target=\"$TARGET_SYNC_DIR\""
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
			SKIP_DELETION=${i##*=}
			;;
			--on-changes)
			sync_on_changes=true
			_NOLOCKS=true
			_LOGGER_PREFIX="date"
			;;
			--no-resume)
			opts=$opts" --no-resume"
			RESUME_TRY=0
			;;
			--no-locks)
			_NOLOCKS=true
			;;
			--errors-only)
			opts=$opts" --errors-only"
			_LOGGER_ERR_ONLY=true
			;;
			--summary)
			opts=$opts" --summary"
			_SUMMARY=true
			;;
			--log-conflicts)
			LOG_CONFLICTS="yes"
			opts=$opts" --log-conflicts"
			;;
			--alert-conflicts)
			ALERT_CONFLICTS="yes"
			LOG_CONFLICTS="yes"
			opts=$opts" --alert-conflicts"
			;;
			--no-prefix)
			opts=$opts" --no-prefix"
			_LOGGER_PREFIX=""
			;;
			--destination-mails=*)
			DESTINATION_MAILS=${i##*=}
			;;
			--remote-token=*)
			_REMOTE_TOKEN=${i##*=}
			;;
			*)
			if [ $isFirstArgument == false ]; then
				Logger "Unknown option '$i'" "CRITICAL"
				Usage
			fi
			;;
		esac
		isFirstArgument=false
	done

	# Remove leading space if there is one
	opts="${opts# *}"
}

GetCommandlineArguments "$@"

## Here we set default options for quicksync tasks when no configuration file is provided.
if [ $_QUICK_SYNC -eq 2 ]; then
	if [ "$INSTANCE_ID" == "" ]; then
		INSTANCE_ID="quicksync_task"
	fi

	# Let the possibility to initialize those values directly via command line like SOFT_DELETE_DAYS=60 ./osync.sh
	if [ $(IsInteger $MINIMUM_SPACE) -ne 1 ]; then
		MINIMUM_SPACE=1024
	fi

	if [ $(IsInteger $CONFLICT_BACKUP_DAYS) -ne 1 ]; then
		CONFLICT_BACKUP_DAYS=30
	fi

	if [ $(IsInteger $SOFT_DELETE_DAYS) -ne 1 ]; then
		SOFT_DELETE_DAYS=30
	fi

	if [ $(IsInteger $RESUME_TRY) -ne 1 ]; then
		RESUME_TRY=1
	fi

	if [ $(IsInteger $SOFT_MAX_EXEC_TIME) -ne 1 ]; then
		SOFT_MAX_EXEC_TIME=0
	fi

	if [ $(IsInteger $HARD_MAX_EXEC_TIME) -ne 1 ]; then
		HARD_MAX_EXEC_TIME=0
	fi

	if [ "$PATH_SEPARATOR_CHAR" == "" ]; then
		PATH_SEPARATOR_CHAR=";"
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
InitLocalOSDependingSettings
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
	InitRemoteOSDependingSettings
	if [ $no_maxtime == true ]; then
		SOFT_MAX_EXEC_TIME=0
		HARD_MAX_EXEC_TIME=0
	fi
	CheckReplicas
	RunBeforeHook
	Main
	if [ $? -eq 0 ]; then
		SoftDelete
	fi
	if [ $_SUMMARY == true ]; then
		Summary
	fi
	if [ $LOG_CONFLICTS == "yes" ]; then
		LogConflicts
	fi
fi
