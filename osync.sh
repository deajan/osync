#!/usr/bin/env bash

#TODO treeList, deleteList, _getFileCtimeMtime, conflictList should be called without having statedir informed. Just give the full path ?
#Check dryruns with nosuffix mode for timestampList

PROGRAM="osync" # Rsync based two way sync engine with fault tolerance
AUTHOR="(C) 2013-2019 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION=1.3.0-beta2
PROGRAM_BUILD=2019052101
IS_STABLE=false

CONFIG_FILE_REVISION_REQUIRED=1.3.0


_OFUNCTIONS_VERSION=2.3.0-RC2
_OFUNCTIONS_BUILD=2019031502
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
if [ "$_REMOTE_EXECUTION" == true ]; then
	mkdir -p "$RUN_DIR/$PROGRAM.remote"
	RUN_DIR="$RUN_DIR/$PROGRAM.remote"
fi

# Get a random number on Windows BusyBox alike, also works on most Unixes that have dd, if dd is not found, then return $RANDOM
function PoorMansRandomGenerator {
	local digits="${1}" # The number of digits to generate
	local number
	local isFirst=true

	if type dd >/dev/null 2>&1; then

		# Some read bytes can't be used, se we read twice the number of required bytes
		dd if=/dev/urandom bs=$digits count=2 2> /dev/null | while read -r -n1 char; do
			if [ $isFirst == false ] || [ $(printf "%d" "'$char") != "0" ]; then
				number=$number$(printf "%d" "'$char")
				isFirst=false
			fi
			if [ ${#number} -ge $digits ]; then
				echo ${number:0:$digits}
				break;
			fi
		done
	elif [ "$RANDOM" -ne 0 ]; then
		 echo $RANDOM
	else
		Logger "Cannot generate random number." "ERROR"
	fi
}
function PoorMansRandomGenerator {
        local digits="${1}" # The number of digits to generate
        local number

        # Some read bytes can't be used, se we read twice the number of required bytes
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
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP.log"
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

function CleanUp {
	if [ "$_DEBUG" != true ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
	fi
}

function GenericTrapQuit {
	local exitcode=0

	# Get ERROR / WARN alert flags from subprocesses that call Logger
	if [ -f "$RUN_DIR/$PROGRAM.Logger.warn.$SCRIPT_PID.$TSTAMP" ]; then
		WARN_ALERT=true
		exitcode=2
	fi
	if [ -f "$RUN_DIR/$PROGRAM.Logger.error.$SCRIPT_PID.$TSTAMP" ]; then
		ERROR_ALERT=true
		exitcode=1
	fi

	CleanUp
	exit $exitcode
}



# osync/obackup/pmocr script specific mail alert function, use SendEmail function for generic mail sending
function SendAlert {
	local runAlert="${1:-false}" # Specifies if current message is sent while running or at the end of a run
	local attachment="${2:-true}" # Should we send the log file as attachment


	local attachmentFile
	local subject
	local body

	if [ "$DESTINATION_MAILS" == "" ]; then
		return 0
	fi

	if [ "$_DEBUG" == true ]; then
		Logger "Debug mode, no warning mail will be sent." "NOTICE"
		return 0
	fi

        if [ $attachment == true ]; then
                attachmentFile="$LOG_FILE"
                if type "$COMPRESSION_PROGRAM" > /dev/null 2>&1; then
                        eval "cat \"$LOG_FILE\" \"$COMPRESSION_PROGRAM\" > \"$ALERT_LOG_FILE\""
                        if [ $? -eq 0 ]; then
                                attachmentFile="$ALERT_LOG_FILE"
                        fi
                fi
        fi

	body="$MAIL_ALERT_MSG"$'\n\n'"Last 1000 lines of current log"$'\n\n'"$(tail -n 1000 "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP.log")"

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

# If text is received as attachment ATT00001.bin or noname, consider adding the following to /etc/mail.rc
#set ttycharset=iso-8859-1
#set sendcharsets=iso-8859-1
#set encoding=8bit

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

	local i

	if [ "${destinationMails}" != "" ]; then
		for i in "${destinationMails[@]}"; do
			if [ $(CheckRFC822 "$i") -ne 1 ]; then
				Logger "Given email [$i] does not seem to be valid." "WARN"
			fi
		done
	else
		Logger "No valid email adresses given." "WARN"
		return 1
	fi

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

			if [ $? -ne 0 ]; then
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
		if [ $? -ne 0 ]; then
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
		if [ $? -ne 0 ]; then
			Logger "Cannot send mail via $(type -p mail) with attachments !!!" "WARN"
			echo "$message" | $(type -p mail) -s "$subject" "$destinationMails"
			if [ $? -ne 0 ]; then
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
		if [ $? -ne 0 ]; then
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
		if [ $? -ne 0 ]; then
			Logger "Cannot send mail via $(type mailsend.exe) !!!" "WARN"
		else
			Logger "Sent mail using mailsend.exe command with attachment." "NOTICE"
			return 0
		fi
	fi

	# pfSense specific
	if [ -f /usr/local/bin/mail.php ]; then
		echo "$message" | /usr/local/bin/mail.php -s="$subject"
		if [ $? -ne 0 ]; then
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
	local revisionRequired="${2}"


	local revisionPresent

	if [ ! -f "$configFile" ]; then
		Logger "Cannot load configuration file [$configFile]. Cannot start." "CRITICAL"
		exit 1
	elif [[ "$configFile" != *".conf" ]]; then
		Logger "Wrong configuration file supplied [$configFile]. Cannot start." "CRITICAL"
		exit 1
	else
		revisionPresent="$(GetConfFileValue "$configFile" "CONFIG_FILE_REVISION" true)"
		if [ "$(IsNumeric "${revisionPresent%%.*}")" -eq 0 ]; then
			Logger "Missing CONFIG_FILE_REVISION. Please provide a valid config file, or run the config update script." "WARN"
			Logger "CONFIG_FILE_REVISION does not seem numeric [$revisionPresent]." "DEBUG"
		elif [ "$revisionRequired" != "" ]; then
			if [ $(VerComp "$revisionPresent" "$revisionRequired") -eq 2 ]; then
				Logger "Configuration file seems out of date. Required version [$revisionRequired]. Actual version [$revisionPresent]." "CRITICAL"
				exit 1
			fi
		fi
		# Remove everything that is not a variable assignation
		grep '^[^ ]*=[^;&]*' "$configFile" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
		source "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP"
	fi

	CONFIG_FILE="$configFile"
}

# Quick and dirty performance logger only used for debugging

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
	local mainInput="${1}"				# Contains list of pids / commands separated by semicolons or filepath to list of pids / commands

	# Optional arguments
	local id="${2:-base}"				# Optional ID in order to identify global variables from this run (only bash variable names, no '-'). Global variables are WAIT_FOR_TASK_COMPLETION_$id and HARD_MAX_EXEC_TIME_REACHED_$id
	local readFromFile="${3:-false}"		# Is mainInput / auxInput a semicolon separated list (true) or a filepath (false)
	local softPerProcessTime="${4:-0}"		# Max time (in seconds) a pid or command can run before a warning is logged, unless set to 0
	local hardPerProcessTime="${5:-0}"		# Max time (in seconds) a pid or command can run before the given command / pid is stopped, unless set to 0
	local softMaxTime="${6:-0}"			# Max time (in seconds) for the whole function to run before a warning is logged, unless set to 0
	local hardMaxTime="${7:-0}"			# Max time (in seconds) for the whole function to run before all pids / commands given are stopped, unless set to 0
	local counting="${8:-true}"			# Should softMaxTime and hardMaxTime be accounted since function begin (true) or since script begin (false)
	local sleepTime="${9:-.5}"			# Seconds between each state check. The shorter the value, the snappier ExecTasks will be, but as a tradeoff, more cpu power will be used (good values are between .05 and 1)
	local keepLogging="${10:-1800}"			# Every keepLogging seconds, an alive message is logged. Setting this value to zero disables any alive logging
	local spinner="${11:-true}"			# Show spinner (true) or do not show anything (false) while running
	local noTimeErrorLog="${12:-false}"		# Log errors when reaching soft / hard execution times (false) or do not log errors on those triggers (true)
	local noErrorLogsAtAll="${13:-false}"		# Do not log any errros at all (useful for recursive ExecTasks checks)

	# Parallelism specific arguments
	local numberOfProcesses="${14:-0}"		# Number of simulanteous commands to run, given as mainInput. Set to 0 by default (WaitForTaskCompletion mode). Setting this value enables ParallelExec mode.
	local auxInput="${15}"				# Contains list of commands separated by semicolons or filepath fo list of commands. Exit code of those commands decide whether main commands will be executed or not
	local maxPostponeRetries="${16:-3}"		# If a conditional command fails, how many times shall we try to postpone the associated main command. Set this to 0 to disable postponing
	local minTimeBetweenRetries="${17:-300}"	# Time (in seconds) between postponed command retries
	local validExitCodes="${18:-0}"			# Semi colon separated list of valid main command exit codes which will not trigger errors


	local i


	# Since ExecTasks takes up to 17 arguments, do a quick preflight check in DEBUG mode
	if [ "$_DEBUG" == true ]; then
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

	# Expand validExitCodes into array
	IFS=';' read -r -a validExitCodes <<< "$validExitCodes"

	# ParallelExec specific variables
	local auxItemCount=0		# Number of conditional commands
	local commandsArray=()		# Array containing commands
	local commandsConditionArray=() # Array containing conditional commands
	local currentCommand		# Variable containing currently processed command
	local currentCommandCondition	# Variable containing currently processed conditional command
	local commandsArrayPid=()	# Array containing commands indexed by pids
	local commandsArrayOutput=()	# Array contining command results indexed by pids
	local postponedRetryCount=0	# Number of current postponed commands retries
	local postponedItemCount=0	# Number of commands that have been postponed (keep at least one in order to check once)
	local postponedCounter=0
	local isPostponedCommand=false	# Is the current command from a postponed file ?
	local postponedExecTime=0	# How much time has passed since last postponed condition was checked
	local needsPostponing		# Does currentCommand need to be postponed
	local temp

	# Common variables
	local pid			# Current pid working on
	local pidState			# State of the process
	local mainItemCount=0		# number of given items (pids or commands)
	local readFromFile		# Should we read pids / commands from a file (true)
	local counter=0
	local log_ttime=0		# local time instance for comparaison

	local seconds_begin=$SECONDS	# Seconds since the beginning of the script
	local exec_time=0		# Seconds since the beginning of this function

	local retval=0			# return value of monitored pid process
	local subRetval=0		# return value of condition commands
	local errorcount=0		# Number of pids that finished with errors
	local pidsArray			# Array of currently running pids
	local newPidsArray		# New array of currently running pids for next iteration
	local pidsTimeArray		# Array containing execution begin time of pids
	local executeCommand		# Boolean to check if currentCommand can be executed given a condition
	local functionMode
	local softAlert=false		# Does a soft alert need to be triggered, if yes, send an alert once
	local failedPidsList		# List containing failed pids with exit code separated by semicolons (eg : 2355:1;4534:2;2354:3)
	local randomOutputName		# Random filename for command outputs

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
			# This log solely exists for readability purposes before having next set of logs
			if [ ${#pidsArray[@]} -eq $numberOfProcesses ] && [ $log_ttime -eq 0 ]; then
				log_ttime=$exec_time
				Logger "There are $((mainItemCount-counter+postponedItemCount)) / $mainItemCount tasks in the queue of which $postponedItemCount are postponed. Currently, ${#pidsArray[@]} tasks running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
			fi
			if [ $(((exec_time + 1) % keepLogging)) -eq 0 ]; then
				if [ $log_ttime -ne $exec_time ]; then # Fix when sleep time lower than 1 second
					log_ttime=$exec_time
					if [ $functionMode == "WaitForTaskCompletion" ]; then
						Logger "Current tasks still running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
					elif [ $functionMode == "ParallelExec" ]; then
						Logger "There are $((mainItemCount-counter+postponedItemCount)) / $mainItemCount tasks in the queue of which $postponedItemCount are postponed. Currently, ${#pidsArray[@]} tasks running with pids [$(joinString , ${pidsArray[@]})]." "NOTICE"
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
				if [ $? -eq 0 ]; then
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
							if [ $? -eq 0 ]; then
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
							if [ -f "${commandsArrayOutput[$pid]}" ]; then
								Logger "Command output was [$(cat ${commandsArrayOutput[$pid]})\n]." "ERROR"
							fi
						fi
						errorcount=$((errorcount+1))
						# Welcome to variable variable bash hell
						if [ "$failedPidsList" == "" ]; then
							failedPidsList="$pid:$retval"
						else
							failedPidsList="$failedPidsList;$pid:$retval"
						fi
					else
						Logger "${FUNCNAME[0]} called by [$id] finished monitoring pid [$pid] with exitcode [$retval]." "DEBUG"
					fi
				fi
			fi
		done

		# hasPids can be false on last iteration in ParallelExec mode
		pidsArray=("${newPidsArray[@]}")

		# Trivial wait time for bash to not eat up all CPU
		sleep $sleepTime


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
					randomOutputName=$(date '+%Y%m%dT%H%M%S').$(PoorMansRandomGenerator 5)
					eval "$currentCommand" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$id.$pid.$randomOutputName.$SCRIPT_PID.$TSTAMP" 2>&1 &
					pid=$!
					pidsArray+=($pid)
					commandsArrayPid[$pid]="$currentCommand"
					commandsArrayOutput[$pid]="$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$id.$pid.$randomOutputName.$SCRIPT_PID.$TSTAMP"
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


	# Return exit code if only one process was monitored, else return number of errors
	# As we cannot return multiple values, a global variable WAIT_FOR_TASK_COMPLETION contains all pids with their return value

	eval "WAIT_FOR_TASK_COMPLETION_$id=\"$failedPidsList\""

	if [ $mainItemCount -eq 1 ]; then
		return $retval
	else
		return $errorcount
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

# Usage var=$(EscapeDoubleQuotes "$var") or var="$(EscapeDoubleQuotes "$var")"
function EscapeDoubleQuotes {
	local value="${1}"

	echo "${value//\"/\\\"}"
}

# Usage [ $(IsNumeric $var) -eq 1 ]
function IsNumeric {
	local value="${1}"

	if type expr > /dev/null 2>&1; then
		expr "$value" : '^[-+]\{0,1\}[0-9]*\.\{0,1\}[0-9]\{1,\}$' > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			echo 1
		else
			echo 0
		fi
	else
		if [[ $value =~ ^[-+]?[0-9]+([.][0-9]+)?$ ]]; then
			echo 1
		else
			echo 0
		fi
	fi
}

function IsNumericExpand {
	eval "local value=\"${1}\"" # Needed eval so variable variables can be processed

	echo $(IsNumeric "$value")
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
		localOsName=$(GetConfFileValue "/etc/os-release" "NAME" true)
		localOsVer=$(GetConfFileValue "/etc/os-release" "VERSION" true)
	elif [ "$LOCAL_OS" == "BusyBox" ]; then
		localOsVer=$(ls --help 2>&1 | head -1 | cut -f2 -d' ')
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



function GetRemoteOS {

	if [ "$REMOTE_OPERATION" != true ]; then
		return 0
	fi

	local remoteOsVar

$SSH_CMD env LC_ALL=C env _REMOTE_TOKEN="$_REMOTE_TOKEN" bash -s << 'ENDSSH' >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1


function GetOs {
	local localOsVar
	local localOsName
	local localOsVer
	local localOsBitness
	local localOsFamily

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
			if [ $? -ne 0 ]; then
				localOsVar="$(uname -v 2>&1)"
				if [ $? -ne 0 ]; then
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
	elif [ "$localOsVar" == "BusyBox" ]; then
		localOsVer=`ls --help 2>&1 | head -1 | cut -f2 -d' '`
		localOsName="BusyBox"
	fi

	# Get Host info for Windows
	case $localOsVar in
		*"MINGW32"*|*"MINGW64"*|*"MSYS"*|*"CYGWIN*"|*"Microsoft"*|*"WinNT10*")
		if [ "$PROGRAMW6432" != "" ]; then
			localOsBitness=64
			localOsFamily="Windows"
		elif [ "$PROGRAMFILES" != "" ]; then
			localOsBitness=32
			localOsFamily="Windows"
		# Case where running on BusyBox but no program files defined
		elif [ "$localOsVar" == "BusyBox" ]; then
			localOsFamily="Unix"
		fi
		;;
		*)
		localOsFamily="Unix"
		if uname -m | grep '64' > /dev/null 2>&1; then
			localOsBitness=64
		else
			localOsBitness=32
		fi
		;;
	esac

	echo "$localOsVar ($localOsName $localOsVer) $localOsBitness-bit $localOsFamily"
}

GetOs

ENDSSH
	if [ $? -ne 0 ]; then
		Logger "Cannot connect to remote system [$REMOTE_HOST] port [$REMOTE_PORT]." "CRITICAL"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "$(cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")" "ERROR"
		fi
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
			if [ "$IGNORE_OS_TYPE" == true ]; then		#DOC: Undocumented debug only setting
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

	if [ "$STOP_ON_CMD_ERROR" == true ] && [ $retval -ne 0 ]; then
		Logger "Stopping on command execution error." "CRITICAL"
		exit 1
	fi
}

## Runs remote command $1 and waits for completition in $2 seconds
function RunRemoteCommand {
	local command="${1}" # Command to run
	local hardMaxTime="${2}" # Max time to wait for command to compleet


	if [ "$REMOTE_OPERATION" != true ]; then
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

	if [ "$STOP_ON_CMD_ERROR" == true ] && [ $retval -ne 0 ]; then
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
		ExecTasks $pids "${FUNCNAME[0]}" false 0 0 0 0 true $SLEEP_TIME $KEEP_LOGGING
		#ExecTasks "${FUNCNAME[0]}" 0 0 0 0 true true false false 1 $pids
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
		ExecTasks $pids "${FUNCNAME[0]}" false 0 0 0 0 true $SLEEP_TIME $KEEP_LOGGING
		#ExecTasks "${FUNCNAME[0]}" 0 0 0 0 true true false false 1 $pids
	fi
}

function CheckConnectivityRemoteHost {

	local retval


		if [ "$REMOTE_HOST_PING" != false ] && [ "$REMOTE_OPERATION" != false ]; then
			eval "$PING_CMD $REMOTE_HOST > /dev/null 2>&1" &
			ExecTasks $! "${FUNCNAME[0]}" false 0 0 60 180 true $SLEEP_TIME $KEEP_LOGGING
			#ExecTasks "${FUNCNAME[0]}" 0 0 60 180 $SLEEP_TIME $KEEP_LOGGING true true false false 1 $!
			retval=$?
			if [ $retval -ne 0 ]; then
				Logger "Cannot ping [$REMOTE_HOST]. Return code [$retval]." "WARN"
				return $retval
			fi
		fi
}

function CheckConnectivity3rdPartyHosts {

	local remote3rdPartySuccess
	local retval
	local i


		if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]; then
			remote3rdPartySuccess=false
			for i in $REMOTE_3RD_PARTY_HOSTS
			do
				eval "$PING_CMD $i > /dev/null 2>&1" &
				ExecTasks $! "${FUNCNAME[0]}" false 0 0 60 180 true $SLEEP_TIME $KEEP_LOGGING
				#ExecTasks "${FUNCNAME[0]}" 0 0 180 360 $SLEEP_TIME $KEEP_LOGGING true true false false 1 $!
				retval=$?
				if [ $retval -ne 0 ]; then
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
			RSYNC_PATTERNS="--$patternType=\"$str\""
		else
			RSYNC_PATTERNS="$RSYNC_PATTERNS --$patternType=\"$str\""
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
		RSYNC_PATTERNS="$RSYNC_PATTERNS --$patternType-from=\"$patternFrom\""
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

	local compressionString

	## SSH compression
	if [ "$SSH_COMPRESSION" != false ]; then
		SSH_COMP=-C
	else
		SSH_COMP=
	fi

	## Ignore SSH known host verification
	if [ "$SSH_IGNORE_KNOWN_HOSTS" == true ]; then
		SSH_OPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
	fi

	## Support for older config files without RSYNC_EXECUTABLE option
	if [ "$RSYNC_EXECUTABLE" == "" ]; then
		RSYNC_EXECUTABLE=rsync
	fi

	## Sudo execution option
	if [ "$SUDO_EXEC" == true ]; then
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

	## If running under Msys, some commands do not run the same way
	## Using mingw version of find instead of windows one
	## Getting running processes is quite different
	## Ping command is not the same
	if [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ] || [ "$LOCAL_OS" == "Microsoft" ] || [ "$LOCAL_OS" == "WinNT10" ]; then
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

	if [ "$REMOTE_OS" == "msys" ] || [ "$REMOTE_OS" == "Cygwin" ]; then
		REMOTE_FIND_CMD=$(dirname $BASH)/find
	else
		REMOTE_FIND_CMD=find
	fi

	## Stat command has different syntax on Linux and FreeBSD/MacOSX
	if [ "$REMOTE_OS" == "MacOSX" ] || [ "$REMOTE_OS" == "BSD" ]; then
		REMOTE_STAT_CMD="stat -f \"%Sm\""
		REMOTE_STAT_CTIME_MTIME_CMD="stat -f \\\"%N;%c;%m\\\""
	else
		REMOTE_STAT_CMD="stat --format %y"
		REMOTE_STAT_CTIME_MTIME_CMD="stat -c \\\"%n;%Z;%Y\\\""
	fi

	## Set rsync default arguments (complete with -r or -d depending on recursivity later)
	RSYNC_DEFAULT_ARGS="-ltD -8"
	if [ "$_DRYRUN" == true ]; then
		RSYNC_DRY_ARG="-n"
		DRY_WARNING="/!\ DRY RUN "
	else
		RSYNC_DRY_ARG=""
	fi

	RSYNC_ATTR_ARGS=""
	if [ "$PRESERVE_PERMISSIONS" != false ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -p"
	fi
	if [ "$PRESERVE_OWNER" != false ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -o"
	fi
	if [ "$PRESERVE_GROUP" != false ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -g"
	fi
	if [ "$PRESERVE_EXECUTABILITY" != false ]; then
		RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" --executability"
	fi
	if [ "$PRESERVE_ACL" == true ]; then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ] && [ "$LOCAL_OS" != "msys" ] && [ "$REMOTE_OS" != "msys" ] && [ "$LOCAL_OS" != "Cygwin" ] && [ "$REMOTE_OS" != "Cygwin" ] && [ "$LOCAL_OS" != "BusyBox" ] && [ "$REMOTE_OS" != "BusyBox" ] && [ "$LOCAL_OS" != "Android" ] && [ "$REMOTE_OS" != "Android" ]; then
			RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -A"
		else
			Logger "Disabling ACL synchronization on [$LOCAL_OS] due to lack of support." "NOTICE"

		fi
	fi
	if [ "$PRESERVE_XATTR" == true ]; then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ] && [ "$LOCAL_OS" != "msys" ] && [ "$REMOTE_OS" != "msys" ] && [ "$LOCAL_OS" != "Cygwin" ] && [ "$REMOTE_OS" != "Cygwin" ] && [ "$LOCAL_OS" != "BusyBox" ] && [ "$REMOTE_OS" != "BusyBox" ]; then
			RSYNC_ATTR_ARGS=$RSYNC_ATTR_ARGS" -X"
		else
			Logger "Disabling extended attributes synchronization on [$LOCAL_OS] due to lack of support." "NOTICE"
		fi
	fi
	if [ "$RSYNC_COMPRESS" == true ]; then
		if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ]; then
			RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" -zz --skip-compress=gz/xz/lz/lzma/lzo/rz/jpg/mp3/mp4/7z/bz2/rar/zip/sfark/s7z/ace/apk/arc/cab/dmg/jar/kgb/lzh/lha/lzx/pak/sfx"
		else
			Logger "Disabling compression skips on synchronization on [$LOCAL_OS] due to lack of support." "NOTICE"
		fi
	fi
	if [ "$COPY_SYMLINKS" == true ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" -L"
	fi
	if [ "$KEEP_DIRLINKS" == true ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" -K"
	fi
	if [ "$RSYNC_OPTIONAL_ARGS" != "" ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" "$RSYNC_OPTIONAL_ARGS
	fi
	if [ "$PRESERVE_HARDLINKS" == true ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" -H"
	fi
	if [ "$CHECKSUM" == true ]; then
		RSYNC_TYPE_ARGS=$RSYNC_TYPE_ARGS" --checksum"
	fi
	if [ "$BANDWIDTH" != "" ] && [ "$BANDWIDTH" != "0" ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" --bwlimit=$BANDWIDTH"
	fi

	if [ "$PARTIAL" == true ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" --partial --partial-dir=\"$PARTIAL_DIR\""
		RSYNC_PARTIAL_EXCLUDE="--exclude=\"$PARTIAL_DIR\""
	fi

	if [ "$DELTA_COPIES" != false ]; then
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" --no-whole-file"
	else
		RSYNC_DEFAULT_ARGS=$RSYNC_DEFAULT_ARGS" --whole-file"
	fi

	# Set compression options again after we know what remote OS we are dealing with
	SetCompression

	# Set recursive options
	RSYNC_DEFAULT_NONRECURSIVE_ARGS="-d $RSYNC_DEFAULT_ARGS"
	RSYNC_DEFAULT_ARGS="-r $RSYNC_DEFAULT_ARGS"
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

	if [[ "$1" == "$2" ]]
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
	local noError="${3:-false}"

	local value

	value=$(grep "^$name=" "$file")
	if [ $? -eq 0 ]; then
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


function SetConfFileValue () {
	local file="${1}"
	local name="${2}"
	local value="${3}"
	local separator="${4:-#}"

	if [ -f "$file" ]; then
		if grep "^$name=" "$file" > /dev/null 2>&1; then
			# Using -i.tmp for BSD compat
			sed -i.tmp "s$separator^$name=.*$separator$name=$value$separator" "$file"
			if [ $? -ne 0 ]; then
				Logger "Cannot update value [$name] to [$value] in config file [$file]." "ERROR"
			fi
			rm -f "$file.tmp"
			Logger "Set [$name] to [$value] in config file [$file]." "DEBUG"
		else
			echo "$name=$value" >> "$file"
			if [ $? -ne 0 ]; then
				Logger "Cannot create value [$name] to [$value] in config file [$file]." "ERROR"
			fi
		fi
	else
		echo "$name=$value" > "$file"
		if [ $? -ne 0 ]; then
			Logger "Config file [$file] does not exist. Failed to create it witn value [$name]." "ERROR"
		fi
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

# If using "include" statements, make sure the script does not get executed unless it's loaded by bootstrap.sh which will replace includes with actual code
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
		if [ "$RUN_AFTER_CMD_ON_ERROR" == true ]; then
			RunAfterHook
		fi
		Logger "$PROGRAM finished with errors." "ERROR"
		if [ "$_DEBUG" != true ]
		then
			SendAlert
		else
			Logger "Debug mode, no alert mail will be sent." "NOTICE"
		fi
		exitcode=1
	elif [ $WARN_ALERT == true ]; then
		UnlockReplicas
		if [ "$RUN_AFTER_CMD_ON_ERROR" == true ]; then
			RunAfterHook
		fi
		Logger "$PROGRAM finished with warnings." "WARN"
		if [ "$_DEBUG" != true ]
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

	if [ "$REMOTE_OPERATION" == true ]; then
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

	if ! type sort > /dev/null 2>&1 ; then
		Logger "sort not present. Sync cannot start." "CRITICAL"
		exit 1
	fi

	if ! type uniq > /dev/null 2>&1 ; then
		Logger "uniq not present. Sync cannot start." "CRITICAL"
		exit 1
	fi

	if [ "$SUDO_EXEC" == true ]; then
		if ! type sudo > /dev/null 2>&1 ; then
			Logger "sudo not present. Sync cannot start." "CRITICAL"
			exit 1
		fi
	fi
}

# Only gets checked in config file mode where all values should be present
function CheckCurrentConfig {
	local fullCheck="${1:-true}"

	local test
	local booleans
	local num_vars


	# Full check is for initiator driven runs
	if [ $fullCheck == true ]; then
		declare -a booleans=(CREATE_DIRS SUDO_EXEC SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING PRESERVE_PERMISSIONS PRESERVE_OWNER PRESERVE_GROUP PRESERVE_EXECUTABILITY PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS CHECKSUM RSYNC_COMPRESS CONFLICT_BACKUP CONFLICT_BACKUP_MULTIPLE SOFT_DELETE RESUME_SYNC FORCE_STRANGER_LOCK_RESUME PARTIAL DELTA_COPIES STOP_ON_CMD_ERROR RUN_AFTER_CMD_ON_ERROR)
		declare -a num_vars=(MINIMUM_SPACE BANDWIDTH SOFT_MAX_EXEC_TIME HARD_MAX_EXEC_TIME KEEP_LOGGING MIN_WAIT MAX_WAIT CONFLICT_BACKUP_DAYS SOFT_DELETE_DAYS RESUME_TRY MAX_EXEC_TIME_PER_CMD_BEFORE MAX_EXEC_TIME_PER_CMD_AFTER)
	# target-helper runs need less configuration
	else
		declare -a booleans=(SUDO_EXEC SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING STOP_ON_CMD_ERROR RUN_AFTER_CMD_ON_ERROR)
		declare -a num_vars=(KEEP_LOGGING MIN_WAIT MAX_WAIT)
	fi

	# v2 config will use true / false instead of yes / no
	# Check all variables that should contain "yes" or "no", true or false
	for i in "${booleans[@]}"; do
		test="if [ \"\$$i\" != true ] && [ \"\$$i\" != false ]; then Logger \"Bogus $i value [\$$i] defined in config file. Correct your config file or update it using the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
		# Fix for upcomming v2 where yes and no do not exist anymore
	done

	# Check all variables that should contain a numerical value >= 0
	for i in "${num_vars[@]}"; do
		test="if [ $(IsNumericExpand \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value [\$$i] defined in config file. Correct your config file or update it using the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
		eval "$test"
	done
}

# Change all booleans with "yes" or "no" to true / false for v2 config syntax compatibility
function UpdateBooleans {
	local update
	local booleans

	declare -a booleans=(CREATE_DIRS SUDO_EXEC SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING PRESERVE_PERMISSIONS PRESERVE_OWNER PRESERVE_GROUP PRESERVE_EXECUTABILITY PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS CHECKSUM RSYNC_COMPRESS CONFLICT_BACKUP CONFLICT_BACKUP_MULTIPLE SOFT_DELETE RESUME_SYNC FORCE_STRANGER_LOCK_RESUME PARTIAL DELTA_COPIES STOP_ON_CMD_ERROR RUN_AFTER_CMD_ON_ERROR)

	for i in "${booleans[@]}"; do
		update="if [ \"\$$i\" == \"yes\" ]; then $i=true; fi; if [ \"\$$i\" == \"no\" ]; then $i=false; fi"
		eval "$update"
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

	if [ "$REMOTE_OPERATION" == true ] && ([ ! -f "$SSH_RSA_PRIVATE_KEY" ] && [ ! -f "$SSH_PASSWORD_FILE" ]); then
		Logger "Cannot find rsa private key [$SSH_RSA_PRIVATE_KEY] nor password file [$SSH_PASSWORD_FILE]. No authentication method provided." "CRITICAL"
		exit 1
	fi

	if [ "$SKIP_DELETION" != "" ]; then
		tmp="$SKIP_DELETION"
		IFS=',' read -r -a SKIP_DELETION <<< "$tmp"
		if [ $(ArrayContains "${INITIATOR[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ] && [ $(ArrayContains "${TARGET[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ]; then
			Logger "Bogus skip deletion parameter [${SKIP_DELETION[@]}]." "CRITICAL"
			exit 1
		fi
	fi

	if [ "$SYNC_TYPE" != "" ]; then
		if [ "$SYNC_TYPE" != "initiator2target" ] && [ "$SYNC_TYPE" != "target2initiator" ]; then
			Logger "Bogus sync type parameter [$SYNC_TYPE]." "CRITICAL"
			exit 1
		fi
	fi
}

###### Osync specific functions (non shared)

function _CheckReplicasLocal {
	local replicaPath="${1}"
	local replicaType="${2}"


	local retval
	local diskSpace

	if [ ! -d "$replicaPath" ]; then
		if [ "$CREATE_DIRS" == true ]; then
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


	local retval
	local cmd

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env replicaPath="'$replicaPath'" env CREATE_DIRS="'$CREATE_DIRS'" env DF_CMD="'$DF_CMD'" env MINIMUM_SPACE="'$MINIMUM_SPACE'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
## Default directory where to store temporary run files

if [ -w /tmp ]; then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]; then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi

## Special note when remote target is on the same host as initiator (happens for unit tests): we'll have to differentiate RUN_DIR so remote CleanUp won't affect initiator.
if [ "$_REMOTE_EXECUTION" == true ]; then
	mkdir -p "$RUN_DIR/$PROGRAM.remote"
	RUN_DIR="$RUN_DIR/$PROGRAM.remote"
fi

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
function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
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

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP.log"
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
function CleanUp {
	if [ "$_DEBUG" != true ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
	fi
}

function _CheckReplicasRemoteSub {
	if [ ! -d "$replicaPath" ]; then
		if [ "$CREATE_DIRS" == true ]; then
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
	return $retval
}
_CheckReplicasRemoteSub
retval=$?
CleanUp
exit $retval
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

	local initiatorPid
	local targetPid
	local retval

	if [ "$REMOTE_OPERATION" != true ]; then
		if [ "${INITIATOR[$__replicaDir]}" == "${TARGET[$__replicaDir]}" ]; then
			Logger "Initiator and target path [${INITIATOR[$__replicaDir]}] cannot be the same." "CRITICAL"
			exit 1
		fi
	fi

	_CheckReplicasLocal "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" &
	initiatorPid=$!
	if [ "$REMOTE_OPERATION" != true ]; then
		_CheckReplicasLocal "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" &
		targetPid=$!
	else
		_CheckReplicasRemote "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" &
		targetPid=$!
	fi
	ExecTasks "$initiatorPid;$targetPid" "${FUNCNAME[0]}" false 0 0 720 1800 true $SLEEP_TIME $KEEP_LOGGING
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


	local retval
	local initiatorRunningPids

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	# Create an array of all currently running pids
	read -a initiatorRunningPids <<< $(ps -A | tail -n +2 | awk '{print $1}')

# passing initiatorRunningPids as litteral string (has to be run through eval to be an array again)
$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env replicaStateDir="'$replicaStateDir'" env initiatorRunningPidsFlat="\"(${initiatorRunningPids[@]})\"" env lockfile="'$lockfile'" env replicaType="'$replicaType'" env overwrite="'$overwrite'" \
env INSTANCE_ID="'$INSTANCE_ID'" env FORCE_STRANGER_LOCK_RESUME="'$FORCE_STRANGER_LOCK_RESUME'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
## Default directory where to store temporary run files

if [ -w /tmp ]; then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]; then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi

## Special note when remote target is on the same host as initiator (happens for unit tests): we'll have to differentiate RUN_DIR so remote CleanUp won't affect initiator.
if [ "$_REMOTE_EXECUTION" == true ]; then
	mkdir -p "$RUN_DIR/$PROGRAM.remote"
	RUN_DIR="$RUN_DIR/$PROGRAM.remote"
fi

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
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP.log"
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
function CleanUp {
	if [ "$_DEBUG" != true ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
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
		lockfileContent=$(cat "$lockfile")
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
				if [ "$FORCE_STRANGER_LOCK_RESUME" == true ]; then
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
			return 0
		fi
	fi
}

_HandleLocksRemoteSub
retval=$?
CleanUp
exit $retval
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

	local retval
	local initiatorPid
	local targetPid
	local overwrite=false

	# Assume lock files are created successfully unless stated otherwise
	local initiatorLockSuccess=true
	local targetLockSuccess=true

	if [ $_NOLOCKS == true ]; then
		return 0
	fi

	# Do not bother checking for locks when FORCE_UNLOCK is set
	if [ $FORCE_UNLOCK == true ]; then
		overwrite=true
	fi

	_HandleLocksLocal "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}" "${INITIATOR[$__lockFile]}" "${INITIATOR[$__type]}" $overwrite &
	initiatorPid=$!
	if [ "$REMOTE_OPERATION" != true ]; then
		_HandleLocksLocal "${TARGET[$__replicaDir]}${TARGET[$__stateDir]}" "${TARGET[$__lockFile]}" "${TARGET[$__type]}" $overwrite &
		targetPid=$!
	else
		_HandleLocksRemote "${TARGET[$__replicaDir]}${TARGET[$__stateDir]}" "${TARGET[$__lockFile]}" "${TARGET[$__type]}" $overwrite &
		targetPid=$!
	fi
	ExecTasks "$initiatorPid;$targetPid" "HandleLocks" false 0 0 720 1800 true $SLEEP_TIME $KEEP_LOGGING
	retval=$?
	if [ $retval -ne 0 ]; then
		IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION_HandleLocks"
		for pid in "${pidArray[@]}"; do
			pid=${pid%:*}
			if [ "$pid" == "$initiatorPid" ]; then
				initiatorLockSuccess=false
			elif [ "$pid" == "$targetPid" ]; then
				targetLockSuccess=false
			fi
		done
	fi


	if [ $initiatorLockSuccess  == true ]; then
		INITIATOR_LOCK_FILE_EXISTS=true
	fi
	if [ $targetLockSuccess == true ]; then
		TARGET_LOCK_FILE_EXISTS=true
	fi

	if [ $retval -ne 0 ]; then
		Logger "Cancelling task." "CRITICAL" $retval
		exit 1
	fi
}

function _UnlockReplicasLocal {
	local lockfile="${1}"
	local replicaType="${2}"


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


	local retval
	local cmd

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" env lockfile="'$lockfile'" \
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

	local initiatorPid=0
	local targetPid=0
	local unlockPids=0

	if [ $_NOLOCKS == true ]; then
		return 0
	fi

	if [ $INITIATOR_LOCK_FILE_EXISTS == true ]; then
		_UnlockReplicasLocal "${INITIATOR[$__lockFile]}" "${INITIATOR[$__type]}" &
		initiatorPid=$!
	fi

	if [ $TARGET_LOCK_FILE_EXISTS == true ]; then
		if [ "$REMOTE_OPERATION" != true ]; then
			_UnlockReplicasLocal "${TARGET[$__lockFile]}" "${TARGET[$__type]}" &
			targetPid=$!
		else
			_UnlockReplicasRemote "${TARGET[$__lockFile]}" "${TARGET[$__type]}" &
			targetPid=$!
		fi
	fi

	if [ "$initiatorPid" -ne 0 ]; then
		unlockPids=$initiatorPid
	fi
	if [ "$targetPid" -ne 0 ]; then
		if [ "$unlockPids" -ne 0 ]; then
			unlockPids="$unlockPids;$targetPid"
		else
			unlockPids="$targetPid"
		fi
	fi

	if [ "$unlockPids" != "0" ]; then
		ExecTasks "$unlockPids" "${FUNCNAME[0]}" false 0 0 720 1800 true $SLEEP_TIME $KEEP_LOGGING
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
	if [ "$REMOTE_OPERATION" == true ] && [ "$replicaType" == "${TARGET[$__type]}" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DEFAULT_ARGS $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE -e \"$RSYNC_SSH_CMD\" --list-only $REMOTE_USER@$REMOTE_HOST:\"$escapedReplicaPath\" 2> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP\" | (grep -E \"^-|^d|^l\" || :) | (sed $SED_REGEX_ARG 's/^.{10} +[0-9,]+ [0-9/]{10} [0-9:]{8} //' || :) | (awk 'BEGIN { FS=\" -> \" } ; { print \$1 }' || :) | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP\""
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DEFAULT_ARGS $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE --list-only \"$replicaPath\" 2> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP\" | (grep -E \"^-|^d|^l\" || :) | (sed $SED_REGEX_ARG 's/^.{10} +[0-9,]+ [0-9/]{10} [0-9:]{8} //' || :) | (awk 'BEGIN { FS=\" -> \" } ; { print \$1 }' || :) | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP\""
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
	else
		touch "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}"
	fi

	# Make sure deletion list does not contain duplicates from faledDeleteListFile
	uniq "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP"
	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
		mv "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$replicaType${INITIATOR[$__deletedListFile]}"
	fi

	return $retval
}

function _getFileCtimeMtimeLocal {
	local replicaPath="${1}" # Contains replica path
	local replicaType="${2}" # Initiator / Target
	local fileList="${3}" # Contains list of files to get time attrs
	local timestampFile="${4}" # Where to store the timestamp file


	echo -n "" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP"

	while IFS='' read -r file; do
		$STAT_CTIME_MTIME_CMD "$replicaPath$file" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP"
		if [ $? -ne 0 ]; then
			Logger "Could not get file attributes for [$replicaPath$file]." "ERROR"
			echo "1" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$replicaType.$SCRIPT_PID.$TSTAMP"
		fi
	done < "$fileList"
	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
		Logger "Getting file time attributes failed [$retval] on $replicaType. Stopping execution." "CRITICAL" $retval
		if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Command output:\n$(cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP")" "WARN"
		fi
		return 1
	else
		cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" | sort > "$timestampFile"
		return $?
	fi

}

function _getFileCtimeMtimeRemote {
	local replicaPath="${1}" # Contains replica path
	local replicaType="${2}"
	local fileList="${3}"
	local timestampFile="${4}"


	local retval
	local cmd

	cmd='cat "'$fileList'" | '$SSH_CMD' "env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN cat > \"./$PROGRAM._getFileCtimeMtimeRemote.Sent.$replicaType.$SCRIPT_PID.$TSTAMP\""'
	Logger "Launching command [$cmd]." "DEBUG"
	eval "$cmd"
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Sending ctime required file list failed with [$retval] on $replicaType. Stopping execution." "CRITICAL" $retval
		_LOGGER_SILENT=true Logger "Command was [$cmd]." "WARN"
		if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
		fi
		return $retval
	fi

#WIP: do we need separate error and non error files ?
$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env replicaPath="'$replicaPath'" env replicaType="'$replicaType'" env REMOTE_STAT_CTIME_MTIME_CMD="'$REMOTE_STAT_CTIME_MTIME_CMD'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP"
## Default directory where to store temporary run files

if [ -w /tmp ]; then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]; then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi

## Special note when remote target is on the same host as initiator (happens for unit tests): we'll have to differentiate RUN_DIR so remote CleanUp won't affect initiator.
if [ "$_REMOTE_EXECUTION" == true ]; then
	mkdir -p "$RUN_DIR/$PROGRAM.remote"
	RUN_DIR="$RUN_DIR/$PROGRAM.remote"
fi

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
function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
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

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP.log"
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
function CleanUp {
	if [ "$_DEBUG" != true ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
	fi
}

function _getFileCtimeMtimeRemoteSub {

	while IFS='' read -r file; do
		$REMOTE_STAT_CTIME_MTIME_CMD "$replicaPath$file"
		if [ $? -ne 0 ]; then
			RemoteLogger "Could not get file attributes for [$replicaPath$file]." "ERROR"
			echo 1 > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$replicaType.$SCRIPT_PID.$TSTAMP"
		fi
	done < "./$PROGRAM._getFileCtimeMtimeRemote.Sent.$replicaType.$SCRIPT_PID.$TSTAMP"

	if [ -f "./$PROGRAM._getFileCtimeMtimeRemote.Sent.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
		rm -f "./$PROGRAM._getFileCtimeMtimeRemote.Sent.$replicaType.$SCRIPT_PID.$TSTAMP"
	fi

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
		return 1
	else
		return 0
	fi
}

	_getFileCtimeMtimeRemoteSub
	retval=$?
	CleanUp
	exit $retval
ENDSSH
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Getting file attributes failed [$retval] on $replicaType. Stopping execution." "CRITICAL" $retval
		if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
		fi
		return $retval
	else
		# Ugly fix for csh in FreeBSD 11 that adds leading and trailing '\"'
		sed -i'.tmp' -e 's/^\\"//' -e 's/\\"$//' "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot fix FreeBSD 11 remote csh syntax." "ERROR"
			return $retval
		fi
		cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" | sort > "$timestampFile"
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


	local retval
	local escapedReplicaPath
	local rsyncCmd

	Logger "Getting file stats for $replicaType replica [$replicaPath]." "NOTICE"

	if [ "$REMOTE_OPERATION" == true ] && [ "$replicaType" == "${TARGET[$__type]}" ]; then
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


	local retval
	local escapedReplicaPath

	if [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}$timestampCurrentFilename" ] && [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}$timestampCurrentFilename" ]; then
		# Remove prepending replicaPaths
		sed -i'.withReplicaPath' "s;^${INITIATOR[$__replicaDir]};;g" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}$timestampCurrentFilename"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot remove prepending replicaPaths for current initiator timestamp file." "ERROR"
			return $retval
		fi
		sed -i'.withReplicaPath' "s;^${TARGET[$__replicaDir]};;g" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}$timestampCurrentFilename"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot remove prepending replicaPaths for current target timestamp file." "ERROR"
			return $retval
		fi
	fi

	if [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}$timestampAfterFilename" ] && [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}$timestampAfterFilename" ]; then
		# Remove prepending replicaPaths
		sed -i'.withReplicaPath' "s;^${INITIATOR[$__replicaDir]};;g" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}$timestampAfterFilename"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot remove prepending replicaPaths for after initiator timestamp file." "ERROR"
			return $retval
		fi
		sed -i'.withReplicaPath' "s;^${TARGET[$__replicaDir]};;g" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}$timestampAfterFilename"
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

		join -j 1 -t ';' -o 1.1,1.2,1.3,2.2,2.3 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.${INITIATOR[$__type]}.$SCRIPT_PID.$TSTAMP" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.${TARGET[$__type]}.$SCRIPT_PID.$TSTAMP" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.compare.$SCRIPT_PID.$TSTAMP"
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


	local initiatorPid
	local targetPid

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

	if [ "$REMOTE_OPERATION" == true ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -i -n $RSYNC_DEFAULT_ARGS $RSYNC_ATTR_ARGS $RSYNC_PARTIAL_EXCLUDE -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE \"$initiatorReplica\" $REMOTE_USER@$REMOTE_HOST:\"$targetReplica\" >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2>&1"
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -i -n $RSYNC_DEFAULT_ARGS $RSYNC_ATTR_ARGS $RSYNC_PARTIAL_EXCLUDE --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE \"$initiatorReplica\" \"$targetReplica\" >> $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP 2>&1"
	fi
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" &
	ExecTasks $! "${FUNCNAME[0]}_1" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
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
	initiatorPid=$!

	Logger "Getting ctimes for pending files on target." "NOTICE"
	if [ "$REMOTE_OPERATION" != true ]; then
		_getFileCtimeMtimeLocal "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID.$TSTAMP" "$RUN_DIR/$PROGRAM.ctime_mtime___.${TARGET[$__type]}.$SCRIPT_PID.$TSTAMP" &
		targetPid=$!
	else
		_getFileCtimeMtimeRemote "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID.$TSTAMP" "$RUN_DIR/$PROGRAM.ctime_mtime___.${TARGET[$__type]}.$SCRIPT_PID.$TSTAMP" &
		targetPid=$!
	fi
	ExecTasks "$initiatorPid;$targetPid" "${FUNCNAME[0]}_2" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
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

	if [ "$REMOTE_OPERATION" == true ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost

		# No rsync args (hence no -r) because files are selected with --from-file
		if [ "$destReplica" == "${INITIATOR[$__type]}" ]; then
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID.$TSTAMP\" $REMOTE_USER@$REMOTE_HOST:\"$escSourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP 2>&1"
		else
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID.$TSTAMP\" \"$sourceDir\" $REMOTE_USER@$REMOTE_HOST:\"$escDestDir\" >> $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP 2>&1"
		fi
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID.$TSTAMP\" \"$sourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP 2>&1"

	fi

	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" &
	ExecTasks $! "${FUNCNAME[0]}_3" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
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
	local remoteDelete="${3:-false}" # Use rsnyc to delete remote files if not existent in source

	local rsyncCmd
	local retval

	local sourceDir
	local escSourceDir
	local destDir
	local escDestDir

	local backupArgs
	local deleteArgs
	local exclude_list_initiator
	local exclude_list_target

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

	if [ "$remoteDelete" == true ]; then
		deleteArgs="--delete-after"
	fi

	if [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$sourceReplica${INITIATOR[$__deletedListFile]}" ]; then
		exclude_list_initiator="--exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$sourceReplica${INITIATOR[$__deletedListFile]}\""
	fi
	if [ -f "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$destinationReplica${INITIATOR[$__deletedListFile]}" ]; then
		exclude_list_target="--exclude-from=\"${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/$destinationReplica${INITIATOR[$__deletedListFile]}\""
	fi

	if [ "$REMOTE_OPERATION" == true ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		if [ "$sourceReplica" == "${INITIATOR[$__type]}" ]; then
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DEFAULT_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $backupArgs $deleteArgs --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE $exclude_list_initiator $exclude_list_target \"$sourceDir\" $REMOTE_USER@$REMOTE_HOST:\"$escDestDir\" >> $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP 2>&1"
		else
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DEFAULT_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $backupArgs $deleteArgs --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE $exclude_list_initiator $exclude_list_target $REMOTE_USER@$REMOTE_HOST:\"$escSourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP 2>&1"
		fi
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DEFAULT_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS $backupArgs $deleteArgs --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE $exclude_list_initiator $exclude_list_target \"$sourceDir\" \"$destDir\" >> $RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP 2>&1"
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

	local retval=0
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
			return $retval
		fi
	fi

	while read -r files; do
		## On every run, check wheter the next item is already deleted because it is included in a directory already deleted
		if [[ "$files" != "$previousFile/"* ]] && [ "$files" != "" ]; then
			if [ "$SOFT_DELETE" != false ]; then
				if [ $_DRYRUN == false ]; then
					if [ -e "$replicaDir$deletionDir/$files" ] || [ -L "$replicaDir$deletionDir/$files" ]; then
						rm -rf "${replicaDir:?}$deletionDir/$files"
						if [ $? -ne 0 ]; then
							Logger "Cannot remove [${replicaDir:?}$deletionDir/$files] on $replicaType." "ERROR"
							echo "1" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$replicaType.$SCRIPT_PID.$TSTAMP"
						fi
					fi

					if [ -e "$replicaDir$files" ] || [ -L "$replicaDir$files" ]; then
						# In order to keep full path on soft deletion, create parent directories before move
						parentdir="$(dirname "$files")"
						if [ "$parentdir" != "." ]; then
							mkdir -p "$replicaDir$deletionDir/$parentdir"
							Logger "Moving deleted file [$replicaDir$files] to [$replicaDir$deletionDir/$parentdir] on $replicaType." "VERBOSE"
							mv -f "$replicaDir$files" "$replicaDir$deletionDir/$parentdir"
						else
							Logger "Moving deleted file [$replicaDir$files] to [$replicaDir$deletionDir] on $replicaType." "VERBOSE"
							mv -f "$replicaDir$files" "$replicaDir$deletionDir"
						fi
						retval=$?
						if [ $retval -ne 0 ]; then
							Logger "Cannot move [$replicaDir$files] to deletion directory on $replicaType." "ERROR" $retval
							echo "1" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$replicaType.$SCRIPT_PID.$TSTAMP"
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
							Logger "Cannot delete [$replicaDir$files] on $replicaType." "ERROR" $retval
							echo "1" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$replicaType.$SCRIPT_PID.$TSTAMP"
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
	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
		return 1
	else
		return 0
	fi
}

function _deleteRemote {
	local replicaType="${1}" # Replica type
	local replicaDir="${2}" # Full path to replica
	local deletionDir="${3}" # deletion dir in format .[workdir]/deleted

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

	failedDeleteList="${TARGET[$__replicaDir]}${TARGET[$__stateDir]}/$replicaType${TARGET[$__failedDeletedListFile]}"
	successDeleteList="${TARGET[$__replicaDir]}${TARGET[$__stateDir]}/$replicaType${TARGET[$__successDeletedListFile]}"

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

#TODO: change $REPLICA_TYPE to $replicaType as in other remote functions, also applies to all other not standard env variables here
$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env _DRYRUN="'$_DRYRUN'" \
env FILE_LIST="'${TARGET[$__replicaDir]}${TARGET[$__stateDir]}/$deletionListFromReplica${INITIATOR[$__deletedListFile]}'" env REPLICA_DIR="'$replicaDir'" env SOFT_DELETE="'$SOFT_DELETE'" \
env DELETION_DIR="'$(EscapeSpaces "$deletionDir")'" env FAILED_DELETE_LIST="'$failedDeleteList'" env SUCCESS_DELETE_LIST="'$successDeleteList'" env REPLICA_TYPE="'$replicaType'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' >> "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID.$TSTAMP" 2>&1
## Default directory where to store temporary run files

if [ -w /tmp ]; then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]; then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi

## Special note when remote target is on the same host as initiator (happens for unit tests): we'll have to differentiate RUN_DIR so remote CleanUp won't affect initiator.
if [ "$_REMOTE_EXECUTION" == true ]; then
	mkdir -p "$RUN_DIR/$PROGRAM.remote"
	RUN_DIR="$RUN_DIR/$PROGRAM.remote"
fi

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

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP.log"
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
function CleanUp {
	if [ "$_DEBUG" != true ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
	fi
}

function _deleteRemoteSub {
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

			if [ "$SOFT_DELETE" != false ]; then
				if [ $_DRYRUN == false ]; then
					if [ -e "$REPLICA_DIR$DELETION_DIR/$files" ] || [ -L "$REPLICA_DIR$DELETION_DIR/$files" ]; then
						rm -rf "$REPLICA_DIR$DELETION_DIR/$files"
						if [ $? -ne 0 ]; then
							RemoteLogger "Cannot remove [$REPLICA_DIR$DELETION_DIR/$files] on $REPLICA_TYPE." "ERROR"
							echo "1" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$REPLICA_TYPE.$SCRIPT_PID.$TSTAMP"
						fi
					fi

					if [ -e "$REPLICA_DIR$files" ] || [ -L "$REPLICA_DIR$files" ]; then
						# In order to keep full path on soft deletion, create parent directories before move
						parentdir="$(dirname "$files")"
						if [ "$parentdir" != "." ]; then
							RemoteLogger "Moving deleted file [$REPLICA_DIR$files] to [$REPLICA_DIR$DELETION_DIR/$parentdir] on $REPLICA_TYPE." "VERBOSE"
							mkdir -p "$REPLICA_DIR$DELETION_DIR/$parentdir"
							mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$DELETION_DIR/$parentdir"
						else
							RemoteLogger "Moving deleted file [$REPLICA_DIR$files] to [$REPLICA_DIR$DELETION_DIR] on $REPLICA_TYPE." "VERBOSE"
							mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$DELETION_DIR"
						fi
						retval=$?
						if [ $retval -ne 0 ]; then
							RemoteLogger "Cannot move [$REPLICA_DIR$files] to deletion directory on $REPLICA_TYPE." "ERROR" $retval
							echo "1" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$REPLICA_TYPE.$SCRIPT_PID.$TSTAMP"
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
							RemoteLogger "Cannot delete [$REPLICA_DIR$files] on $REPLICA_TYPE." "ERROR" $retval
							echo "1" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$REPLICA_TYPE.$SCRIPT_PID.$TSTAMP"
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
	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$REPLICA_TYPE.$SCRIPT_PID.$TSTAMP" ]; then
		return 1
	else
		return 0
	fi
}
	_deleteRemoteSub
	CleanUp
	exit $retval
ENDSSH
	retval=$?
	if [ -s "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID.$TSTAMP" ] && ([ $retval -ne 0 ] || [ "$_LOGGER_VERBOSE" == true ]); then
		(
		_LOGGER_PREFIX="RR"
		Logger "$(cat $RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID.$TSTAMP)" "ERROR"
		)
	fi

	## Copy back the deleted failed file list
	rsyncCmd="$(type -p $RSYNC_EXECUTABLE) -r --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" --include \"$(dirname ${TARGET[$__stateDir]})\" --include \"${TARGET[$__stateDir]}\" --include \"${TARGET[$__stateDir]}/$replicaType${TARGET[$__failedDeletedListFile]}\" --include \"${TARGET[$__stateDir]}/$replicaType${TARGET[$__successDeletedListFile]}\" --exclude='*' $REMOTE_USER@$REMOTE_HOST:\"$(EscapeSpaces "${TARGET[$__replicaDir]}")\" \"${INITIATOR[$__replicaDir]}\" > \"$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID.$TSTAMP\""
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" 2>> "$LOG_FILE"
	if [ $? -ne 0 ]; then
		Logger "Cannot copy back the failed deletion list to initiator replica." "CRITICAL" $retval
		_LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Comand output: $(cat $RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID.$TSTAMP)" "NOTICE"
		fi
		return 1
	fi
	return $retval
}

# delete_Propagation(replica type)
function deletionPropagation {
	local replicaType="${1}" # Contains replica type: initiator, target where to delete

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
				return 1
			fi
		else
			Logger "Skipping deletion on replica $replicaType." "NOTICE"
		fi
	elif [ "$replicaType" == "${TARGET[$__type]}" ]; then
		if [ $(ArrayContains "${TARGET[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ]; then
			replicaDir="${TARGET[$__replicaDir]}"
			deleteDir="${TARGET[$__deleteDir]}"

			if [ "$REMOTE_OPERATION" == true ]; then
				_deleteRemote "${TARGET[$__type]}" "$replicaDir" "$deleteDir"
			else
				_deleteLocal "${TARGET[$__type]}" "$replicaDir" "$deleteDir"
			fi
			retval=$?
			if [ $retval -ne 0 ]; then
				Logger "Deletion on $replicaType replica failed." "CRITICAL" $retval
				return 1
			fi
		else
			Logger "Skipping deletion on replica $replicaType." "NOTICE"
		fi
	fi
}

function Initialize {

	Logger "Initializing initiator and target file lists." "NOTICE"

	treeList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__treeAfterFile]}" &
	initiatorPid=$!

	treeList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__treeAfterFile]}" &
	targetPid=$!

	ExecTasks "$initiatorPid;$targetPid" "Initialize_1" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
	if [ $? -ne 0 ]; then
		IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION_Initialize_1"
		initiatorFail=false
		targetFail=false
		for pid in "${pidArray[@]}"; do
			pid=${pid%:*}
			if [ "$pid" == "$initiatorPid" ]; then
				Logger "Failed to create initialization treeList files for initiator." "ERROR"
			elif [ "$pid" == "$targetPid" ]; then
				Logger "Failed to create initialization treeList files for target." "ERROR"
			fi
		done
		exit 1
	fi

	timestampList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__treeAfterFile]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__timestampAfterFile]}" &
	initiatorPid=$!

	timestampList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${TARGET[$__treeAfterFile]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__timestampAfterFile]}" &
	targetPid=$!

	ExecTasks "$initiatorPid;$targetPid" "Initialize_2" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
	if [ $? -ne 0 ]; then
		IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION_Initialize_2"
		initiatorFail=false
		targetFail=false
		for pid in "${pidArray[@]}"; do
			pid=${pid%:*}
			if [ "$pid" == "$initiatorPid" ]; then
				Logger "Failed to create initialization timestamp files for initiator." "ERROR"
			elif [ "$pid" == "$targetPid" ]; then
				Logger "Failed to create initialization timestamp files for target." "ERROR"
			fi
		done
		exit 1
	fi

}

###### Sync function in 9 steps
######
###### Step 0a & 0b: Create current file list of replicas
###### Step 1a & 1b: Create deleted file list of replicas
###### Step 2a & 2b: Create current ctime & mtime file list of replicas
###### Step 3a & 3b: Merge conflict file list
###### Step 4: Update file attributes
###### Step 5a & 5b: Update replicas
###### Step 6a & 6b: Propagate deletions on replicas
###### Step 7a & 7b: Create after run file list of replicas
###### Step 8a & 8b: Create after run ctime & mtime file list of replicas

function Sync {
	local syncType="${1}"		# Optional sync type. By default, sync is bidirectional.


	local resumeCount
	local resumeInitiator
	local resumeTarget
	local rsyncRemoteDelete=false

	local initiatorPid
	local targetPid

	local initiatorFail
	local targetFail

	local pid

	Logger "Starting synchronization task." "NOTICE"

	if [ "$RESUME_SYNC" != false ]; then
		if [ -f "${INITIATOR[$__resumeCount]}" ]; then
			resumeCount=$(cat "${INITIATOR[$__resumeCount]}")
		else
			resumeCount=0
		fi

		if [ $resumeCount -lt $RESUME_TRY ]; then
			if [ -f "${INITIATOR[$__initiatorLastActionFile]}" ]; then
				resumeInitiator=$(cat "${INITIATOR[$__initiatorLastActionFile]}")
			else
				resumeInitiator="${SYNC_ACTION[9]}"
			fi

			if [ -f "${INITIATOR[$__targetLastActionFile]}" ]; then
				resumeTarget=$(cat "${INITIATOR[$__targetLastActionFile]}")
			else
				resumeTarget="${SYNC_ACTION[9]}"
			fi

			if [ "$resumeInitiator" != "${SYNC_ACTION[9]}" ]; then
				Logger "Trying to resume aborted execution on $($STAT_CMD "${INITIATOR[$__initiatorLastActionFile]}") at task [$resumeInitiator] for initiator. [$resumeCount] previous tries." "NOTICE"
				echo $((resumeCount+1)) > "${INITIATOR[$__resumeCount]}"
			else
				resumeInitiator="none"
			fi

			if [ "$resumeTarget" != "${SYNC_ACTION[9]}" ]; then
				Logger "Trying to resume aborted execution on $($STAT_CMD "${INITIATOR[$__targetLastActionFile]}") as task [$resumeTarget] for target. [$resumeCount] previous tries." "NOTICE"
				echo $((resumeCount+1)) > "${INITIATOR[$__resumeCount]}"
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

	# If using unidirectional sync, let's point resumes at step 5 directly
	if [ "$SYNC_TYPE" == "initiator2target" ]; then
		resumeInitiator="${SYNC_ACTION[5]}"
		resumeTarget="${SYNC_ACTION[6]}"
		if [ $(ArrayContains "${TARGET[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ]; then
			rsyncRemoteDelete=true
		fi
	elif [ "$SYNC_TYPE" == "target2initiator" ]; then
		resumeInitiator="${SYNC_ACTION[6]}"
		resumeTarget="${SYNC_ACTION[5]}"
		if [ $(ArrayContains "${INITIATOR[$__type]}" "${SKIP_DELETION[@]}") -eq 0 ]; then
			rsyncRemoteDelete=true
		fi
	fi

	################################################################################################################################################# Actual sync begins here

	## Step 0a & 0b
	if [ "$resumeInitiator" == "none" ] || [ "$resumeTarget" == "none" ] || [ "$resumeInitiator" == "${SYNC_ACTION[0]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[0]}" ]; then
		if [ "$resumeInitiator" == "none" ] || [ "$resumeInitiator" == "${SYNC_ACTION[0]}" ]; then
			treeList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__treeCurrentFile]}" &
			initiatorPid=$!
		fi

		if [ "$resumeTarget" == "none" ] || [ "$resumeTarget" == "${SYNC_ACTION[0]}" ]; then
			treeList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__treeCurrentFile]}" &
			targetPid=$!
		fi

		ExecTasks "$initiatorPid;$targetPid" "Sync_treeListBefore" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
		if [ $? -ne 0 ]; then
			IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION_Sync_treeListBefore"
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
			initiatorPid=$!
		fi

		if [ "$resumeTarget" == "${SYNC_ACTION[1]}" ]; then
			deleteList "${TARGET[$__type]}" &
			targetPid=$!
		fi

		ExecTasks "$initiatorPid;$targetPid" "Sync_deleteList" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
		if [ $? -ne 0 ]; then
			IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION_Sync_deleteList"
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
		#if [[ "$RSYNC_ATTR_ARGS" == *"-X"* ]] || [[ "$RSYNC_ATTR_ARGS" == *"-A"* ]] || [ "$LOG_CONFLICTS" == true ]; then
		#TODO: refactor in v1.4 with syncattrs
		if [ "$LOG_CONFLICTS" == true ]; then

			if [ "$resumeInitiator" == "${SYNC_ACTION[2]}" ]; then
				timestampList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__treeCurrentFile]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__timestampCurrentFile]}" &
				initiatorPid=$!
			fi

			if [ "$resumeTarget" == "${SYNC_ACTION[2]}" ]; then
				timestampList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${TARGET[$__treeCurrentFile]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${TARGET[$__timestampCurrentFile]}" &
				targetPid=$!
			fi

			ExecTasks "$initiatorPid;$targetPid" "Sync_timestampListBefore" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
			if [ $? -ne 0 ]; then
				IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION_Sync_timestampListBefore"
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
		if [ "$LOG_CONFLICTS" == true ]; then
			conflictList "${INITIATOR[$__timestampCurrentFile]}" "${INITIATOR[$__timestampAfterFileNoSuffix]}" &
			ExecTasks $! "${FUNCNAME[0]}_conflictList" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
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
			syncAttrs "${INITIATOR[$__replicaDir]}" "${TARGET[$__replicaDir]}" &
			ExecTasks $! "${FUNCNAME[0]}_syncAttrs" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
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
				syncUpdate "${TARGET[$__type]}" "${INITIATOR[$__type]}" $rsyncRemoteDelete &
				ExecTasks $! "${FUNCNAME[0]}_syncUpdate_initiator" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
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
				syncUpdate "${INITIATOR[$__type]}" "${TARGET[$__type]}" $rsyncRemoteDelete &
				ExecTasks $! "${FUNCNAME[0]}_syncUpdate_target" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
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
				syncUpdate "${INITIATOR[$__type]}" "${TARGET[$__type]}" $rsyncRemoteDelete &
				ExecTasks $! "${FUNCNAME[0]}_syncUpdate_target" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
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
				syncUpdate "${TARGET[$__type]}" "${INITIATOR[$__type]}" $rsyncRemoteDelete &
				ExecTasks $! "${FUNCNAME[0]}_syncUpdate_initiator" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
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

	# If SYNC_TYPE is not bidirectional, skip all other steps
	if [ "$SYNC_TYPE" == "initiator2target" ] || [ "$SYNC_TYPE" == "target2initiator" ]; then
		echo "${SYNC_ACTION[9]}" > "${INITIATOR[$__initiatorLastActionFile]}"
		echo "${SYNC_ACTION[9]}" > "${INITIATOR[$__targetLastActionFile]}"
		resumeInitiator="${SYNC_ACTION[9]}"
		resumeTarget="${SYNC_ACTION[9]}"
	fi

	## Step 6a & 6b
	if [ "$resumeInitiator" == "${SYNC_ACTION[6]}" ] || [ "$resumeTarget" == "${SYNC_ACTION[6]}" ]; then
		if [ "$resumeInitiator" == "${SYNC_ACTION[6]}" ]; then
			deletionPropagation "${INITIATOR[$__type]}" &
			initiatorPid=$!
		fi

		if [ "$resumeTarget" == "${SYNC_ACTION[6]}" ]; then
			deletionPropagation "${TARGET[$__type]}" &
			targetPid=$!
		fi

		ExecTasks "$initiatorPid;$targetPid" "Sync_deletionPropagation" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
		if [ $? -ne 0 ]; then
			IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION_Sync_deletionPropagation"
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
			initiatorPid=$!
		fi

		if [ "$resumeTarget" == "${SYNC_ACTION[7]}" ]; then
			treeList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${INITIATOR[$__treeAfterFile]}" &
			targetPid=$!
		fi

		ExecTasks "$initiatorPid;$targetPid" "Sync_treeListAfter" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
		if [ $? -ne 0 ]; then
			IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION_Sync_treeListAfter"
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
		#if [[ "$RSYNC_ATTR_ARGS" == *"-X"* ]] || [[ "$RSYNC_ATTR_ARGS" == *"-A"* ]] || [ "$LOG_CONFLICTS" == true ]; then
		#TODO: refactor in v1.4 with syncattrs
		if [ "$LOG_CONFLICTS" == true ]; then

			if [ "$resumeInitiator" == "${SYNC_ACTION[8]}" ]; then
				timestampList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__treeAfterFile]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__type]}${INITIATOR[$__timestampAfterFile]}" &
				initiatorPid=$!
			fi

			if [ "$resumeTarget" == "${SYNC_ACTION[8]}" ]; then
				timestampList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${TARGET[$__treeAfterFile]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${TARGET[$__type]}${TARGET[$__timestampAfterFile]}" &
				targetPid=$!
			fi

			ExecTasks "$initiatorPid;$targetPid" "Sync_timestampListAfter" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
			if [ $? -ne 0 ]; then
				IFS=';' read -r -a pidArray <<< "$WAIT_FOR_TASK_COMPLETION_Sync_timeStampListAfter"
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
			resumeTarget="${SYNC_ACTION[9]}"
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

		$FIND_CMD "$replicaDeletionPath" -type f -ctime +"$changeTime" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteList.$replicaType.$SCRIPT_PID.$TSTAMP" 2>> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP"
		while IFS='' read -r file; do
			Logger "On $replicaType will delete file [$file]" "VERBOSE"
			if [ $_DRYRUN == false ]; then
				rm -f "$file" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
			fi
		done < "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteList.$replicaType.$SCRIPT_PID.$TSTAMP"

		$FIND_CMD "$replicaDeletionPath" -type d -empty -ctime +"$changeTime" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteList.$replicaType.$SCRIPT_PID.$TSTAMP" 2>> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP"
		while IFS='' read -r directory; do
			Logger "On $replicaType will delete empty directory [$file]" "VERBOSE"
			if [ $_DRYRUN == false ]; then
				rm -df "$directory" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
			fi
		done < "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteList.$replicaType.$SCRIPT_PID.$TSTAMP"

		if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Error while executing cleanup on $replicaType replica." "ERROR" $retval
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
		else
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP)" "VERBOSE"
			Logger "File cleanup complete on $replicaType replica." "NOTICE"
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
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env _DRYRUN="'$_DRYRUN'" env replicaType="'$replicaType'" env replicaDeletionPath="'$replicaDeletionPath'" env changeTime="'$changeTime'" env REMOTE_FIND_CMD="'$REMOTE_FIND_CMD'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
## Default directory where to store temporary run files

if [ -w /tmp ]; then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]; then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi

## Special note when remote target is on the same host as initiator (happens for unit tests): we'll have to differentiate RUN_DIR so remote CleanUp won't affect initiator.
if [ "$_REMOTE_EXECUTION" == true ]; then
	mkdir -p "$RUN_DIR/$PROGRAM.remote"
	RUN_DIR="$RUN_DIR/$PROGRAM.remote"
fi

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
function TrapError {
	local job="$0"
	local line="$1"
	local code="${2:-1}"

	if [ $_LOGGER_SILENT == false ]; then
		(>&2 echo -e "\e[45m/!\ ERROR in ${job}: Near line ${line}, exit code ${code}\e[0m")
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

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP.log"
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
function CleanUp {
	if [ "$_DEBUG" != true ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
	fi
}

function _SoftDeleteRemoteSub {
	if [ -d "$replicaDeletionPath" ]; then
		$REMOTE_FIND_CMD "$replicaDeletionPath" -type f -ctime +"$changeTime" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteList.$replicaType.$SCRIPT_PID.$TSTAMP" 2>> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP"
		while IFS='' read -r file; do
			RemoteLogger "On $replicaType will delete file [$file]" "VERBOSE"
			if [ $_DRYRUN == false ]; then
				rm -f "$file" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
			fi
		done < "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteList.$replicaType.$SCRIPT_PID.$TSTAMP"

		$REMOTE_FIND_CMD "$replicaDeletionPath" -type d -empty -ctime +"$changeTime" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteList.$replicaType.$SCRIPT_PID.$TSTAMP" 2>> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP"
		while IFS='' read -r directory; do
			RemoteLogger "On $replicaType will delete empty directory [$file]" "VERBOSE"
			if [ $_DRYRUN == false ]; then
				rm -df "$directory" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
			fi
		done < "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteList.$replicaType.$SCRIPT_PID.$TSTAMP"

		if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
			RemoteLogger "Error while executing cleanup on $replicaType replica." "ERROR" $retval
			RemoteLogger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
			exit 1
		else
			RemoteLogger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP)" "VERBOSE"
			RemoteLogger "File cleanup complete on $replicaType replica." "NOTICE"
			exit 0
		fi
	elif [ -d "$replicaDeletionPath" ] && ! [ -w "$replicaDeletionPath" ]; then
		RemoteLogger "The $replicaType replica dir [$replicaDeletionPath] is not writable. Cannot clean old files." "ERROR"
		exit 1
	else
		RemoteLogger "The $replicaType replica dir [$replicaDeletionPath] does not exist. Skipping cleaning of old files." "VERBOSE"
		exit 0
	fi
}
_SoftDeleteRemoteSub
retval=$?
CleanUp
exit $retval
ENDSSH
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Error while executing cleanup on remote $replicaType replica." "ERROR" $retval
		(
		_LOGGER_PREFIX=""
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "WARN"
		)
	else
		Logger "Cleanup complete on $replicaType replica." "NOTICE"
		(
		_LOGGER_PREFIX=""
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP)" "VERBOSE"
		)
	fi
}

function SoftDelete {

	local initiatorPid
	local targetPid

	if [ "$CONFLICT_BACKUP" != false ] && [ $CONFLICT_BACKUP_DAYS -ne 0 ]; then
		Logger "Running conflict backup cleanup." "NOTICE"

		_SoftDeleteLocal "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__backupDir]}" $CONFLICT_BACKUP_DAYS "conflict backup" &
		initiatorPid=$!
		if [ "$REMOTE_OPERATION" != true ]; then
			_SoftDeleteLocal "${TARGET[$__type]}" "${TARGET[$__replicaDir]}${TARGET[$__backupDir]}" $CONFLICT_BACKUP_DAYS "conflict backup" &
			targetPid=$!
		else
			_SoftDeleteRemote "${TARGET[$__type]}" "${TARGET[$__replicaDir]}${TARGET[$__backupDir]}" $CONFLICT_BACKUP_DAYS "conflict backup" &
			targetPid=$!
		fi
		ExecTasks "$initiatorPid;$targetPid" "${FUNCNAME[0]}_conflictBackup" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
		if [ $? -ne 0 ] && [ "$(eval echo \"\$HARD_MAX_EXEC_TIME_REACHED_${FUNCNAME[0]}\")" == true ]; then
			exit 1
		fi
	fi

	if [ "$SOFT_DELETE" != false ] && [ $SOFT_DELETE_DAYS -ne 0 ]; then
		Logger "Running soft deletion cleanup." "NOTICE"

		_SoftDeleteLocal "${INITIATOR[$__type]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__deleteDir]}" $SOFT_DELETE_DAYS "softdelete" &
		initiatorPid=$!
		if [ "$REMOTE_OPERATION" != true ]; then
			_SoftDeleteLocal "${TARGET[$__type]}" "${TARGET[$__replicaDir]}${TARGET[$__deleteDir]}" $SOFT_DELETE_DAYS "softdelete" &
			targetPid=$!
		else
			_SoftDeleteRemote "${TARGET[$__type]}" "${TARGET[$__replicaDir]}${TARGET[$__deleteDir]}" $SOFT_DELETE_DAYS "softdelete" &
			targetPid=$!
		fi
		ExecTasks "$initiatorPid;$targetPid" "${FUNCNAME[0]}_softDelete" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
		if [ $? -ne 0 ] && [ "$(eval echo \"\$HARD_MAX_EXEC_TIME_REACHED_${FUNCNAME[0]}\")" == true ]; then
			exit 1
		fi
	fi
}

function _TriggerInitiatorRunLocal {

	local PUSH_FILE

	PUSH_FILE="${INITIATOR[$__replicaDir]}${INITIATOR[$__updateTriggerFile]}"

	if [ -d $(dirname "$PUSH_FILE") ]; then
		echo "$INSTANCE_ID#$(date '+%Y%m%dT%H%M%S.%N')" >> "$PUSH_FILE" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
		if [ $? -ne 0 ]; then
			Logger "Could not notify local initiator of file changes." "ERROR"
			Logger "$(cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP")" "ERROR"
			return 1
		else
			Logger "Initiator of instance [$INSTANCE_ID] should be notified of file changes now." "NOTICE"
		fi
		return 0
	else
		Logger "Cannot fin initiator replica dir [$dirname ("$PUSH_FILE")]." "ERROR"
		return 1
	fi
}

function _TriggerInitiatorRunRemote {

$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env INSTANCE_ID="'$INSTANCE_ID'" env PUSH_FILE="'$(EscapeSpaces "${INITIATOR[$__replicaDir]}${INITIATOR[$__updateTriggerFile]}")'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
## Default directory where to store temporary run files

if [ -w /tmp ]; then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]; then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi

## Special note when remote target is on the same host as initiator (happens for unit tests): we'll have to differentiate RUN_DIR so remote CleanUp won't affect initiator.
if [ "$_REMOTE_EXECUTION" == true ]; then
	mkdir -p "$RUN_DIR/$PROGRAM.remote"
	RUN_DIR="$RUN_DIR/$PROGRAM.remote"
fi

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

		# Build current log file for alerts if we have a sufficient environment
		if [ "$RUN_DIR/$PROGRAM" != "/" ]; then
			echo -e "$logValue" >> "$RUN_DIR/$PROGRAM._Logger.$SCRIPT_PID.$TSTAMP.log"
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
function CleanUp {
	if [ "$_DEBUG" != true ]; then
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP"
		# Fix for sed -i requiring backup extension for BSD & Mac (see all sed -i statements)
		rm -f "$RUN_DIR/$PROGRAM."*".$SCRIPT_PID.$TSTAMP.tmp"
	fi
}

	if [ -d $(dirname "$PUSH_FILE") ]; then
		#WIP no %N on BSD (also in local)
		echo "$INSTANCE_ID#$(date '+%Y%m%dT%H%M%S.%N')" >> "$PUSH_FILE"
		retval=$?
	else
		RemoteLogger "Cannot find initiator replica dir [$(dirname "$PUSH_FILE")]." "ERROR"
		retval=1
	fi
	exit $retval
ENDSSH
	if [ $? -ne 0 ]; then
		Logger "Could not notifiy remote initiator of file changes." "ERROR"
		Logger "SSH_CMD [$SSH_CMD]" "DEBUG"
		(
		_LOGGER_PREFIX="RR"
		Logger "$(cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP")" "ERROR"
		)
		return 1
	else
		Logger "Initiator of instance [$INSTANCE_ID] should be notified of file changes now." "NOTICE"
	fi
	return 0
}

function TriggerInitiatorRun {

	if [ "$REMOTE_OPERATION" != false ]; then
		_TriggerInitiatorRunRemote
	else
		_TriggerInitiatorRunLocal
	fi
}

function _SummaryFromRsyncFile {
	local replicaPath="${1}"
	local summaryFile="${2}"
	local direction="${3}"


	if [ -f "$summaryFile" ]; then
		while read -r file; do
			# grep -E "^<|^>|^\." = Remove all lines that do not begin with '<', '>' or '.' to deal with a bizarre bug involving rsync 3.0.6 / CentOS 6 and --skip-compress showing 'adding zip' l$
			if echo "$file" | grep -E "^<|^>|^\.|^\*" > /dev/null 2>&1; then
				# Check for time attribute changes only (eg rsync output '.d..t......'
				if echo "$file" | grep -E "\..\.\.t\.\.\.\.\.\." > /dev/null 2>&1; then
					verb="TIMESTAMP"
				elif echo "$file" | grep -E "\*deleting" > /dev/null 2>&1; then
					verb="DELETE"
					if [ "$direction" == ">>" ]; then
						TARGET_DELETES_COUNT=$((TARGET_DELETES_COUNT+1))
					elif [ "$direction" == "<<" ]; then
						INITIATOR_DELETES_COUNT=$((INITIATOR_DELETES_COUNT+1))
					fi
				else
					verb="UPDATE"
					if [ "$direction" == ">>" ]; then
						TARGET_UPDATES_COUNT=$((TARGET_UPDATES_COUNT+1))
					elif [ "$direction" == "<<" ]; then
						INITIATOR_UPDATES_COUNT=$((INITIATOR_UPDATES_COUNT+1))
					fi
				fi
				# awk removes first part of line until space, then show all others
				# We don't use awk '$1="";print $0' since it would keep a space as first character
				Logger "$verb $direction $replicaPath$(echo "$file" | awk '{for (i=2; i<NF; i++) printf $i " "; print $NF}')" "ALWAYS"
			fi
		done < "$summaryFile"
	fi
}

function _SummaryFromDeleteFile {
	local replicaPath="${1}"
	local summaryFile="${2}"
	local direction="${3}"


	if [ -f "$summaryFile" ]; then
		while read -r file; do
			Logger "DELETE $direction $replicaPath$file" "ALWAYS"
			if [ "$direction" == ">>" ]; then
				TARGET_DELETES_COUNT=$((TARGET_DELETES_COUNT+1))
			elif [ "$direction" == "<<" ]; then
				INITIATOR_DELETES_COUNT=$((INITIATOR_DELETES_COUNT+1))
			fi
		done < "$summaryFile"
	fi
}

function Summary {

	(
	_LOGGER_PREFIX=""

	Logger "Attributes only updates: INITIATOR << >> TARGET" "ALWAYS"

	_SummaryFromRsyncFile "${TARGET[$__replicaDir]}" "$RUN_DIR/$PROGRAM.attr-update.target.$SCRIPT_PID.$TSTAMP" ">>"
	_SummaryFromRsyncFile "${INITIATOR[$__replicaDir]}" "$RUN_DIR/$PROGRAM.attr-update.initiator.$SCRIPT_PID.$TSTAMP" "<<"

	Logger "File transfers and simple deletions: INITIATOR << >> TARGET (may include file ownership and timestamp attributes)" "ALWAYS"
	_SummaryFromRsyncFile "${TARGET[$__replicaDir]}" "$RUN_DIR/$PROGRAM.update.target.$SCRIPT_PID.$TSTAMP" ">>"
	_SummaryFromRsyncFile "${INITIATOR[$__replicaDir]}" "$RUN_DIR/$PROGRAM.update.initiator.$SCRIPT_PID.$TSTAMP" "<<"

	Logger "File deletions: INITIATOR << >> TARGET" "ALWAYS"
	if [ "$REMOTE_OPERATION" == true ]; then
		_SummaryFromDeleteFile "${TARGET[$__replicaDir]}" "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/target${TARGET[$__successDeletedListFile]}" "- >>"
	else
		_SummaryFromDeleteFile "${TARGET[$__replicaDir]}" "$RUN_DIR/$PROGRAM.delete.target.$SCRIPT_PID.$TSTAMP" ">>"
	fi
	_SummaryFromDeleteFile "${INITIATOR[$__replicaDir]}" "$RUN_DIR/$PROGRAM.delete.initiator.$SCRIPT_PID.$TSTAMP" "<<"

	Logger "Initiator has $INITIATOR_UPDATES_COUNT updates." "ALWAYS"
	Logger "Target has $TARGET_UPDATES_COUNT updates." "ALWAYS"
	Logger "Initiator has $INITIATOR_DELETES_COUNT deletions." "ALWAYS"
	Logger "Target has $TARGET_DELETES_COUNT deletions." "ALWAYS"
	)
}

function LogConflicts {

	local subject
	local body

	local conflicts=0

	if [ -f "$RUN_DIR/$PROGRAM.conflictList.compare.$SCRIPT_PID.$TSTAMP" ]; then
		Logger "File conflicts: INITIATOR << >> TARGET" "ALWAYS"
		> "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__conflictListFile]}"
		while read -r line; do
			echo "${INITIATOR[$__replicaDir]}$(echo $line | awk -F';' '{print $1}') << >> ${TARGET[$__replicaDir]}$(echo $line | awk -F';' '{print $1}')" >> "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__conflictListFile]}"
			conflicts=$((conflicts+1))
		done < "$RUN_DIR/$PROGRAM.conflictList.compare.$SCRIPT_PID.$TSTAMP"

		(
		_LOGGER_PREFIX=""
		Logger "$(cat "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__conflictListFile]}")" "ALWAYS"
		)

		Logger "There are $conflicts conflictual files." "ALWAYS"
	else
		Logger "No are no conflicatual files." "ALWAYS"
	fi

	if [ "$ALERT_CONFLICTS" == true ] && [ -s "$RUN_DIR/$PROGRAM.conflictList.compare.$SCRIPT_PID.$TSTAMP" ]; then
		subject="Conflictual files found in [$INSTANCE_ID]"
		body="List of conflictual files:"$'\n'"$(cat "${INITIATOR[$__replicaDir]}${INITIATOR[$__stateDir]}/${INITIATOR[$__conflictListFile]}")"

		SendEmail "$subject" "$body" "$DESTINATION_MAILS" "" "$SENDER_MAIL" "$SMTP_SERVER" "$SMTP_PORT" "$SMTP_ENCRYPTION" "$SMTP_USER" "$SMTP_PASSWORD"
	fi
}

function Init {

	# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace

	# Do not use exit and quit traps if osync runs in monitor mode
	if [ $_SYNC_ON_CHANGES == false ]; then
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
		REMOTE_OPERATION=true

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
	elif [ "${INITIATOR_SYNC_DIR:0:6}" == "ssh://" ]; then
		REMOTE_OPERATION=true

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
		INITIATOR_SYNC_DIR=${hosturiandpath#*/}
	else
		REMOTE_OPERATION=false
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
	local pushFile=".osync-update.push"

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
	INITIATOR[$__updateTriggerFile]="$pushFile"

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
	TARGET[$__updateTriggerFile]="$pushFile"

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
	if [ "$_SYNC_ON_CHANGES" != "target" ]; then
		RsyncPatterns
	fi

	## Conflict options
	if [ "$CONFLICT_BACKUP" != false ]; then
		INITIATOR_BACKUP="--backup --backup-dir=\"${INITIATOR[$__backupDir]}\""
		TARGET_BACKUP="--backup --backup-dir=\"${TARGET[$__backupDir]}\""
		if [ "$CONFLICT_BACKUP_MULTIPLE" == true ]; then
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

	HandleLocks
	Sync
}

function Usage {

	if [ "$IS_STABLE" != true ]; then
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
	echo "--log-conflicts        [EXPERIMENTAL] Outputs a list of conflicted files"
	echo "--alert-conflicts      Send an email if conflictual files found (implies --log-conflicts)"
	echo "--verbose              Increases output"
	echo "--stats                Adds rsync transfer statistics to verbose output"
	echo "--partial              Allows rsync to keep partial downloads that can be resumed later (experimental)"
	echo "--no-maxtime           Disables any soft and hard execution time checks"
	echo "--force-unlock         Will override any existing active or dead locks on initiator and target replica"
	echo "--on-changes           Will launch a sync task after a short wait period if there is some file activity on initiator replica. You should try daemon mode instead"
	echo "--on-changes-target    Will trigger ansync task on initiator if initiator runs daemon mode. You should call this with the osync-target-helper service"
	echo "--no-resume            Do not try to resume a failed run. By default, execution is resumed once"
	echo "--initialize           Create file lists without actually synchronizing anything, this will help setup deletion detections before the first run"

	echo ""
	echo "[QUICKSYNC OPTIONS]"
	echo "--initiator=\"\"		Master replica path. Will contain state and backup directory (is mandatory)"
	echo "--target=\"\" 		Local or remote target replica path. Can be a ssh uri like ssh://user@host.com:22//path/to/target/replica (is mandatory)"
	echo "--rsakey=\"\"		Alternative path to rsa private key for ssh connection to target replica"
	echo "--password-file=\"\"      If no rsa private key is used for ssh authentication, a password file can be used"
	echo "--remote-token=\"\"       When using ssh filter protection, you must specify the remote token set in ssh_filter.sh"
	echo "--instance-id=\"\"	Optional sync task name to identify this synchronization task when using multiple targets"
	echo "--skip-deletion=\"\"      You may skip deletion propagation on initiator or target. Valid values: initiator target initiator,target"
	echo "--sync-type=\"\"          Allows osync to run in unidirectional sync mode. Valid values: initiator2target, target2initiator"
	echo "--destination-mails=\"\"  Double quoted list of space separated email addresses to send alerts to"
	echo ""
	echo "Additionaly, you may set most osync options at runtime. eg:"
	echo "SOFT_DELETE_DAYS=365 $0 --initiator=/path --target=/other/path"
	echo ""
	exit 128
}

function SyncOnChanges {
	local isTargetHelper="${1:-false}"		# Is this service supposed to be run as target helper ?


	local watchDirectory
	local watchCmd
	local osyncSubcmd
	local retval

	if [ "$LOCAL_OS" == "MacOSX" ]; then
		if ! type fswatch > /dev/null 2>&1 ; then
			Logger "No fswatch command found. Cannot monitor changes." "CRITICAL"
			exit 1
		fi
	else
		if ! type inotifywait > /dev/null 2>&1 ; then
			Logger "No inotifywait command found. Cannot monitor changes." "CRITICAL"
			exit 1
		fi
	fi

	if [ $isTargetHelper == false ]; then
		if [ ! -d "$INITIATOR_SYNC_DIR" ]; then
			Logger "Initiator directory [$INITIATOR_SYNC_DIR] does not exist. Cannot monitor." "CRITICAL"
			exit 1
		fi
		watchDirectory="$INITIATOR_SYNC_DIR"
		if [ "$ConfigFile" != "" ]; then
			osyncSubcmd='bash '$osync_cmd' "'$ConfigFile'" '$opts
		else
			osyncSubcmd='bash '$osync_cmd' '$opts
		fi
		Logger "#### Running $PROGRAM in initiator file monitor mode." "NOTICE"
	else
		if [ ! -d "$TARGET_SYNC_DIR" ]; then
			Logger "Target directory [$TARGET_SYNC_DIR] does not exist. Cannot monitor." "CRITICAL"
			exit 1
		fi
		watchDirectory="$TARGET_SYNC_DIR"
	Logger "#### Running $PROGRAM in target helper file monitor mode." "NOTICE"
	fi

	while true; do
		if [ $isTargetHelper == false ]; then
			Logger "Daemon cmd: [$osyncSubcmd]" "DEBUG"
			eval "$osyncSubcmd"
			retval=$?
			if [ $retval -ne 0 ] && [ $retval != 2 ]; then
				Logger "$PROGRAM child exited with error." "ERROR" $retval
			fi

		else
			# Notify initiator about target changes
			TriggerInitiatorRun
		fi


		Logger "#### Monitoring now." "NOTICE"

		# inotifywait < 3.20 can't handle multiple --exclude statements. For compat issues, we'll watch everything except .osync_workdir

		if [ "$LOCAL_OS" == "MacOSX" ]; then
			watchCmd="fswatch --exclude \"$OSYNC_DIR\" -1 \"$watchDirectory\" > /dev/null"
			# Mac fswatch doesn't have timeout switch, replacing wait $! with WaitForTaskCompletion without warning nor spinner and increased SLEEP_TIME to avoid cpu hogging. This simulates wait $! with timeout
			Logger "Watch cmd M: [$watchCmd]."  "DEBUG"
			eval "$watchCmd" &
			ExecTasks $! "MonitorMacOSXWait" false 0 0 0 $MAX_WAIT true 1 0
		elif [ "$LOCAL_OS" == "BSD" ]; then
			# BSD version of inotifywait does not support multiple --exclude statements
			watchCmd="inotifywait --exclude \"$OSYNC_DIR\" -qq -r -e create -e modify -e delete -e move -e attrib --timeout \"$MAX_WAIT\" \"$watchDirectory\""
			Logger "Watch cmd B: [$watchCmd]."  "DEBUG"
			eval "$watchCmd" &
			wait $!
		else
			watchCmd="inotifywait --exclude \"$OSYNC_DIR\" -qq -r -e create -e modify -e delete -e move -e attrib --timeout \"$MAX_WAIT\" \"$watchDirectory\""
			Logger "Watch cmd L: [$watchCmd]."  "DEBUG"
			eval "$watchCmd" &
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
		elif [ $retval -eq 127 ]; then
			Logger "inotifywait could not load succesfully. Please check if all necessary libraries for inotifywait are present." "CRITICAL"
			exit 1
		fi
	done

}

#### SCRIPT ENTRY POINT

# First TrapQuit declaration before knowing if we run as daemon or not
trap TrapQuit TERM EXIT HUP QUIT

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
LOG_CONFLICTS=false
ALERT_CONFLICTS=false
no_maxtime=false
opts=""
ERROR_ALERT=false
WARN_ALERT=false
# Number of CTRL+C needed to stop script
SOFT_STOP=2
# Number of given replicas in command line
_QUICK_SYNC=0
_SYNC_ON_CHANGES=false
_NOLOCKS=false
osync_cmd=$0
_SUMMARY=false
INITIALIZE=false
if [ "$MIN_WAIT" == "" ]; then
	MIN_WAIT=60
fi
if [ "$MAX_WAIT" == "" ]; then
	MAX_WAIT=7200
fi

# Global counters for --summary
INITIATOR_UPDATES_COUNT=0
TARGET_UPDATES_COUNT=0
INITIATOR_DELETES_COUNT=0
TARGET_DELETES_COUNT=0

function GetCommandlineArguments {
	local isFirstArgument=true

	if [ $# -eq 0 ]
	then
		Usage
	fi

	for i in "${@}"; do
		case "$i" in
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
			PARTIAL=true
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
			_QUICK_SYNC=$((_QUICK_SYNC + 1))
			INITIATOR_SYNC_DIR="${i##*=}"
			opts=$opts" --initiator=\"$INITIATOR_SYNC_DIR\""
			;;
			--target=*)
			_QUICK_SYNC=$((_QUICK_SYNC + 1))
			TARGET_SYNC_DIR="${i##*=}"
			opts=$opts" --target=\"$TARGET_SYNC_DIR\""
			;;
			--rsakey=*)
			SSH_RSA_PRIVATE_KEY="${i##*=}"
			opts=$opts" --rsakey=\"$SSH_RSA_PRIVATE_KEY\""
			;;
			--password-file=*)
			SSH_PASSWORD_FILE="${i##*=}"
			opts=$opts" --password-file=\"$SSH_PASSWORD_FILE\""
			;;
			--instance-id=*)
			INSTANCE_ID="${i##*=}"
			opts=$opts" --instance-id=\"$INSTANCE_ID\""
			;;
			--skip-deletion=*)
			opts=$opts" --skip-deletion=\"${i##*=}\""
			SKIP_DELETION="${i##*=}"
			;;
			--sync-type=*)
			opts=$opts" --sync-type=\"${i##*=}\""
			SYNC_TYPE="${i##*=}"
			;;
			--on-changes)
			_SYNC_ON_CHANGES="initiator"
			_NOLOCKS=true
			_LOGGER_PREFIX="date"
			;;
			--on-changes-target)
			_SYNC_ON_CHANGES="target"
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
			LOG_CONFLICTS=true
			opts=$opts" --log-conflicts"
			;;
			--alert-conflicts)
			ALERT_CONFLICTS=true
			LOG_CONFLICTS=true
			opts=$opts" --alert-conflicts"
			;;
			--initialize)
			INITIALIZE=true
			opts=$opts" --initialize"
			;;
			--no-prefix)
			opts=$opts" --no-prefix"
			_LOGGER_PREFIX=""
			;;
			--destination-mails=*)
			DESTINATION_MAILS="${i##*=}"
			;;
			--remote-token=*)
			_REMOTE_TOKEN="${i##*=}"
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

	# Fix when reloading GetCommandlineArguments
	if [ $_QUICK_SYNC -gt 2 ]; then
		_QUICK_SYNC=2
	fi
}

GetCommandlineArguments "${@}"

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

	if [ $(IsInteger $MAX_EXEC_TIME_PER_CMD_BEFORE) -ne 1 ]; then
		MAX_EXEC_TIME_PER_CMD_BEFORE=0
	fi

	if [ $(IsInteger $MAX_EXEC_TIME_PER_CMD_AFTER) -ne 1 ]; then
		MAX_EXEC_TIME_PER_CMD_AFTER=0
	fi

	if [ "$PATH_SEPARATOR_CHAR" == "" ]; then
		PATH_SEPARATOR_CHAR=";"
	fi

	if [ $(IsInteger $MIN_WAIT) -ne 1 ]; then
		MIN_WAIT=30
	fi
# First character shouldn't be '-' when config file given
elif [ "${1:0:1}" != "-" ]; then
	ConfigFile="${1}"
	LoadConfigFile "$ConfigFile" $CONFIG_FILE_REVISION_REQUIRED
else
	Logger "Wrong arguments given. Expecting a config file or initiator and target arguments." "CRITICAL"
	exit 1
fi

# Reload GetCommandlineArguments so we can override config file with run time arguments
GetCommandlineArguments "${@}"

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

if [ "$IS_STABLE" != true ]; then
	Logger "This is an unstable dev build [$PROGRAM_BUILD]. Please use with caution." "WARN"
	fi

# v2 config syntax compatibility
UpdateBooleans
GetLocalOS
InitLocalOSDependingSettings
PreInit
Init
CheckEnvironment
PostInit

# Add exclusion of $INITIATOR[$__updateTriggerFile] to rsync patterns used by sync functions, but not by daemon
RSYNC_FULL_PATTERNS="$RSYNC_PATTERNS --exclude=${INITIATOR[$__updateTriggerFile]}"

if [ $_QUICK_SYNC -lt 2 ]; then
	if [ "$_SYNC_ON_CHANGES" == false ]; then
		CheckCurrentConfig true
	else
		CheckCurrentConfig false
	fi
fi

CheckCurrentConfigAll
DATE=$(date)
Logger "-------------------------------------------------------------" "NOTICE"
Logger "$DRY_WARNING$DATE - $PROGRAM $PROGRAM_VERSION script begin." "ALWAYS"
Logger "-------------------------------------------------------------" "NOTICE"
Logger "Sync task [$INSTANCE_ID] launched as $LOCAL_USER@$LOCAL_HOST (PID $SCRIPT_PID)" "NOTICE"
if [ "$_SYNC_ON_CHANGES" == "initiator" ]; then
	SyncOnChanges false
elif [ "$_SYNC_ON_CHANGES" == "target" ]; then
	SyncOnChanges true
else
	GetRemoteOS
	InitRemoteOSDependingSettings
	if [ $no_maxtime == true ]; then
		SOFT_MAX_EXEC_TIME=0
		HARD_MAX_EXEC_TIME=0
	fi
	CheckReplicas
	RunBeforeHook

	if [ "$INITIALIZE" == true ]; then
		HandleLocks
		Initialize
	else
		Main
		if [ $? -eq 0 ]; then
			SoftDelete
		fi
		if [ $_SUMMARY == true ]; then
			Summary
		fi
		if [ $LOG_CONFLICTS == true ]; then
			LogConflicts
		fi
	fi
fi
