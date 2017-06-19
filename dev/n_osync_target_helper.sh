#!/usr/bin/env bash

PROGRAM="osync-target-helper" # Rsync based two way sync engine with fault tolerance
AUTHOR="(C) 2013-2017 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION=1.2.2-dev
PROGRAM_BUILD=2017061901
IS_STABLE=no

include #### OFUNCTIONS FULL SUBSET ####
# If using "include" statements, make sure the script does not get executed unless it's loaded by bootstrap
include #### _OFUNCTIONS_BOOTSTRAP SUBSET ####
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
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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

	if ([ ! -f "$SSH_RSA_PRIVATE_KEY" ] && [ ! -f "$SSH_PASSWORD_FILE" ]); then
		Logger "Cannot find rsa private key [$SSH_RSA_PRIVATE_KEY] nor password file [$SSH_PASSWORD_FILE]. No authentication method provided." "CRITICAL"
		exit 1
	fi
}

function TriggerInitiatorUpdate {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" TSTAMP="'$TSTAMP'" env INSTANCE_ID="'$INSTANCE_ID'" \
env PUSH_FILE="'$(EscapeSpaces "${INITIATOR[$__updateTriggerFIle]}")'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2>&1
include #### DEBUG SUBSET ####
include #### TrapError SUBSET ####
include #### RemoteLogger SUBSET ####

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
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
