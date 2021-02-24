#!/usr/bin/env bash

#TODO treeList, deleteList, _getFileCtimeMtime, conflictList should be called without having statedir informed. Just give the full path ?
#Check dryruns with nosuffix mode for timestampList

PROGRAM="osync" # Rsync based two way sync engine with fault tolerance
AUTHOR="(C) 2013-2021 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION=1.3.0-dev-rc2
PROGRAM_BUILD=2021022401
IS_STABLE=false

CONFIG_FILE_REVISION_REQUIRED=1.3.0

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

include #### OFUNCTIONS FULL SUBSET ####
# If using "include" statements, make sure the script does not get executed unless it's loaded by bootstrap.sh which will replace includes with actual code
include #### _OFUNCTIONS_BOOTSTRAP SUBSET ####
[ "$_OFUNCTIONS_BOOTSTRAP" != true ] && echo "Please use bootstrap.sh to load this dev version of $(basename $0) or build it with merge.sh" && exit 1

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
	__CheckArguments 0 $# "$@"    #__WITH_PARANOIA_DEBUG

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

	__CheckArguments 1 $# "$@"    #__WITH_PARANOIA_DEBUG

	# Full check is for initiator driven runs
	if [ $fullCheck == true ]; then
		declare -a booleans=(CREATE_DIRS SUDO_EXEC SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING PRESERVE_PERMISSIONS PRESERVE_OWNER PRESERVE_GROUP PRESERVE_EXECUTABILITY PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS CHECKSUM RSYNC_COMPRESS CONFLICT_BACKUP CONFLICT_BACKUP_MULTIPLE SOFT_DELETE RESUME_SYNC FORCE_STRANGER_LOCK_RESUME PARTIAL DELTA_COPIES STOP_ON_CMD_ERROR RUN_AFTER_CMD_ON_ERROR SSH_CONTROLMASTER)
		declare -a num_vars=(MINIMUM_SPACE BANDWIDTH SOFT_MAX_EXEC_TIME HARD_MAX_EXEC_TIME KEEP_LOGGING MIN_WAIT MAX_WAIT CONFLICT_BACKUP_DAYS SOFT_DELETE_DAYS RESUME_TRY MAX_EXEC_TIME_PER_CMD_BEFORE MAX_EXEC_TIME_PER_CMD_AFTER)
	# target-helper runs need less configuration
	else
		declare -a booleans=(SUDO_EXEC SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING SSH_CONTROLMASTER)
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

	declare -a booleans=(CREATE_DIRS SUDO_EXEC SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING PRESERVE_PERMISSIONS PRESERVE_OWNER PRESERVE_GROUP PRESERVE_EXECUTABILITY PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS CHECKSUM RSYNC_COMPRESS CONFLICT_BACKUP CONFLICT_BACKUP_MULTIPLE SOFT_DELETE RESUME_SYNC FORCE_STRANGER_LOCK_RESUME PARTIAL DELTA_COPIES STOP_ON_CMD_ERROR RUN_AFTER_CMD_ON_ERROR SSH_CONTROLMASTER)

	for i in "${booleans[@]}"; do
		update="if [ \"\$$i\" == \"yes\" ]; then $i=true; fi; if [ \"\$$i\" == \"no\" ]; then $i=false; fi"
		eval "$update"
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
	local stateDir="${3}"

	__CheckArguments 3 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local diskSpace

	if [ ! -d "$replicaPath" ]; then
		if [ "$CREATE_DIRS" == true ]; then
			mkdir -p "$replicaPath" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
			retval=$?
			if [ $retval -ne 0 ]; then
				Logger "Cannot create local replica path [$replicaPath]." "CRITICAL" $retval
				Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "WARN"
				return 1
			else
				Logger "Created local replica path [$replicaPath]." "NOTICE"
			fi
		else
			Logger "Local replica path [$replicaPath] does not exist or is not writable and CREATE_DIRS is not allowed." "CRITICAL"
			return 1
		fi
	fi

	if [ ! -d "$replicaPath/$OSYNC_DIR" ]; then
		mkdir -p "$replicaPath/$OSYNC_DIR" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot create local replica osync path [$replicaPath/$OSYNC_DIR]." "CRITICAL" $retval
			Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "WARN"
			return 1
		else
			Logger "Created local replica osync path [$replicaPath/$OSYNC_DIR]." "NOTICE"
		fi
	fi

	if [ ! -d "$stateDir" ]; then
		mkdir -p "$stateDir" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot create local replica state dir [$stateDir]." "CRITICAL" $retval
			Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "WARN"
			return 1
		fi
	fi

	if [ ! -w "$replicaPath" ]; then
		Logger "Local replica path [$replicaPath] is not writable." "CRITICAL"
		return 1
	fi

	if [ $MINIMUM_SPACE -ne 0 ]; then
		Logger "Checking minimum disk space in local replica [$replicaPath]." "NOTICE"
		diskSpace=$($DF_CMD "$replicaPath" | tail -1 | awk '{print $4}')
		if [[ $diskSpace == *"%"* ]]; then
	  		diskSpace=$($DF_CMD "$replicaPath" | tail -1 | awk '{print $3}')
		fi
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot get free space." "ERROR" $retval
		else
			# Ugly fix for df in some busybox environments that can only show human formats
			if [ $(IsInteger "$diskSpace") -eq 0 ]; then
				diskSpace=$(HumanToNumeric "$diskSpace")
			fi

			if [ $diskSpace -lt $MINIMUM_SPACE ]; then
				Logger "There is not enough free space on local replica [$replicaPath] ($diskSpace KB)." "WARN"
			fi
		fi
	fi
	return $retval
}

function _CheckReplicasRemote {
	local replicaPath="${1}"
	local replicaType="${2}"
	local stateDir="${3}"

	__CheckArguments 3 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local cmd

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env replicaPath="'$replicaPath'" env stateDir="'$stateDir'" env isCustomStateDir="'$isCustomStateDir'" env CREATE_DIRS="'$CREATE_DIRS'" env DF_CMD="'$DF_CMD'" env MINIMUM_SPACE="'$MINIMUM_SPACE'" \
env OSYNC_DIR="'$OSYNC_DIR'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
_REMOTE_TOKEN="(o_0)"
include #### RUN_DIR SUBSET ####
include #### DEBUG SUBSET ####
include #### TrapError SUBSET ####
include #### IsInteger SUBSET ####
include #### HumanToNumeric SUBSET ####
include #### RemoteLogger SUBSET ####
include #### CleanUp SUBSET ####

function _CheckReplicasRemoteSub {
	if [ ! -d "$replicaPath" ]; then
		if [ "$CREATE_DIRS" == true ]; then
			mkdir -p "$replicaPath/$OSYNC_DIR"
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

	if [ ! -d "$replicaPath/$OSYNC_DIR" ]; then
		mkdir -p "$replicaPath/$OSYNC_DIR" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot create local replica osync path [$replicaPath/$OSYNC_DIR]." "CRITICAL" $retval
			Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "WARN"
			return 1
		else
			Logger "Created local replica osync path [$replicaPath/$OSYNC_DIR]." "NOTICE"
		fi
	fi

	if [ ! -d "$stateDir" ]; then
		mkdir -p "$stateDir" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot create remote replica state dir [$stateDir]." "CRITICAL" $retval
			Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "WARN"
			return 1
		fi
	fi


	if [ ! -w "$replicaPath" ]; then
		RemoteLogger "Remote replica path [$replicaPath] is not writable." "CRITICAL"
		exit 1
	fi

	if [ $MINIMUM_SPACE -ne 0 ]; then
		RemoteLogger "Checking minimum disk space in remote replica [$replicaPath]." "NOTICE"
		diskSpace=$($DF_CMD "$replicaPath" | tail -1 | awk '{print $4}')
		if [[ $diskSpace == *"%"* ]]; then
	  		diskSpace=$($DF_CMD "$replicaPath" | tail -1 | awk '{print $3}')
		fi
		retval=$?
		if [ $retval -ne 0 ]; then
			RemoteLogger "Cannot get free space." "ERROR" $retval
		else
			# Ugly fix for df in some busybox environments that can only show human formats
			if [ $(IsInteger "$diskSpace") -eq 0 ]; then
				diskSpace=$(HumanToNumeric "$diskSpace")
			fi

			if [ $diskSpace -lt $MINIMUM_SPACE ]; then
				RemoteLogger "There is not enough free space on remote replica [$replicaPath] ($diskSpace KB)." "WARN"
			fi
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
		Logger "$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "NOTICE"
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

	local initiatorPid
	local targetPid
	local retval

	if [ "$REMOTE_OPERATION" != true ]; then
		if [ "${INITIATOR[$__replicaDir]}" == "${TARGET[$__replicaDir]}" ]; then
			Logger "Initiator and target path [${INITIATOR[$__replicaDir]}] cannot be the same." "CRITICAL"
			exit 1
		fi
	fi

	# stateDir is relative whereas custom state_dir should be absolute
	if [ "$INITIATOR_CUSTOM_STATE_DIR" != "" ]; then
		initiator_state_dir="$INITIATOR_CUSTOM_STATE_DIR"
	else
		initiator_state_dir="${INITIATOR[$__stateDirAbsolute]}"
	fi

	if [ "$TARGET_CUSTOM_STATE_DIR" != "" ]; then
		target_state_dir="$TARGET_CUSTOM_STATE_DIR"
	else
		target_state_dir="${TARGET[$__stateDirAbsolute]}"
	fi

	_CheckReplicasLocal "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "$initiator_state_dir" &
	initiatorPid=$!
	if [ "$REMOTE_OPERATION" != true ]; then
		_CheckReplicasLocal "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "$target_state_dir" &
		targetPid=$!
	else
		_CheckReplicasRemote "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "$target_state_dir" &
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
			Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "WARN"
			return 1
		fi
	fi

	# Skip the whole part if overwrite true
	if [ -s "$lockfile" ] && [ $overwrite != true ]; then
		lockfileContent="$(head -c16384 "$lockfile")"
		Logger "Master lock pid present: $lockfileContent" "DEBUG"
		lockPid="${lockfileContent%@*}"
		if [ $(IsInteger "$lockPid") -ne 1 ]; then
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
			Logger "Truncated output\n$(head -c 16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "WARN"
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

	# Check if -A exists on target
	ps -A > /dev/null 2>&1
	psNotExistsOptA=$?

	# Create an array of all currently running pids
	if [ "$psNotExistaOptA" == "0" ]; then
		read -a initiatorRunningPids <<< $(ps -A | tail -n +2 | awk '{print $1}')
	else
		read -a initiatorRunningPids <<< $(ps -e | tail -n +2 | awk '{print $1}')
	fi

# passing initiatorRunningPids as litteral string (has to be run through eval to be an array again)
$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env replicaStateDir="'$replicaStateDir'" env initiatorRunningPidsFlat="\"(${initiatorRunningPids[@]})\"" env lockfile="'$lockfile'" env replicaType="'$replicaType'" env overwrite="'$overwrite'" \
env INSTANCE_ID="'$INSTANCE_ID'" env FORCE_STRANGER_LOCK_RESUME="'$FORCE_STRANGER_LOCK_RESUME'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
_REMOTE_TOKEN="(o_0)"
include #### RUN_DIR SUBSET ####
include #### DEBUG SUBSET ####
include #### TrapError SUBSET ####
include #### ArrayContains SUBSET ####
include #### IsInteger SUBSET ####
include #### RemoteLogger SUBSET ####
include #### CleanUp SUBSET ####

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
		lockfileContent="$(head -c16384 "$lockfile")"
		RemoteLogger "Master lock pid present: $lockfileContent" "DEBUG"
		lockPid="${lockfileContent%@*}"
		if [ $(IsInteger "$lockPid") -ne 1 ]; then
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
		Logger "$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "NOTICE"
		)
	fi
	if [ $retval -ne 0 ]; then
		return 1
	fi
}

function HandleLocks {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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

	_HandleLocksLocal "${INITIATOR[$__stateDirAbsolute]}" "${INITIATOR[$__lockFile]}" "${INITIATOR[$__type]}" $overwrite &
	initiatorPid=$!
	if [ "$REMOTE_OPERATION" != true ]; then
		_HandleLocksLocal "${TARGET[$__stateDirAbsolute]}" "${TARGET[$__lockFile]}" "${TARGET[$__type]}" $overwrite &
		targetPid=$!
	else
		_HandleLocksRemote "${TARGET[$__stateDirAbsolute]}" "${TARGET[$__lockFile]}" "${TARGET[$__type]}" $overwrite &
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
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" env lockfile="'$lockfile'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2>&1
_REMOTE_TOKEN="(o_0)"
if [ -f "$lockfile" ]; then
	rm -f "$lockfile"
fi
ENDSSH
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Could not unlock $replicaType remote replica." "ERROR" $retval
		Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "WARN"
	else
		Logger "Removed remote $replicaType replica lock." "DEBUG"
	fi
}

function UnlockReplicas {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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

function treeList {
	local replicaPath="${1}" # path to the replica for which a tree needs to be constructed
	local replicaType="${2}" # replica type: initiator, target
	local treeFilename="${3}" # filename to output tree (will be prefixed with $replicaType)

	__CheckArguments 3 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
	local rsyncCmd

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
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DEFAULT_ARGS $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE -e \"$RSYNC_SSH_CMD\" --list-only $REMOTE_USER@$REMOTE_HOST:\"'$replicaPath'\" 2> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP\" | (grep -E \"^-|^d|^l\" || :) | (sed $SED_REGEX_ARG 's/^.{10} +[0-9,]+ [0-9/]{10} [0-9:]{8} //' || :) | (awk 'BEGIN { FS=\" -> \" } ; { print \$1 }' || :) | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP\""
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DEFAULT_ARGS $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE --list-only \"$replicaPath\" 2> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP\" | (grep -E \"^-|^d|^l\" || :) | (sed $SED_REGEX_ARG 's/^.{10} +[0-9,]+ [0-9/]{10} [0-9:]{8} //' || :) | (awk 'BEGIN { FS=\" -> \" } ; { print \$1 }' || :) | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP\""
	fi
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	retval=$?

	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
		# Cannot use standard mv function because of some Apple BS... see #175
		FileMove "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" "$treeFilename"
		if [ $? -ne 0 ]; then
			Logger "Cannot move treeList files \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP\" => \"$treeFilename\"". "ERROR"
			return $retval
		fi
	fi

	## Retval 24 = some files vanished while creating list
	if ([ $retval -eq 0 ] || [ $retval -eq 24 ]) then
		return $?
	elif [ $retval -eq 23 ]; then
		Logger "Some files could not be listed in $replicaType replica [$replicaPath]. Check for failing symlinks." "ERROR" $retval
		Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP")" "WARN"
		return 0
	else
		Logger "Cannot create replica file list in [$replicaPath]." "CRITICAL" $retval
		_LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP")" "WARN"
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
	if [ -f "${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__treeAfterFileNoSuffix]}" ]; then
		## Same functionnality, comm is much faster than grep but is not available on every platform

		## Let's add awk in order to filter results based on sub directories already deleted because parent directory is dleeted
		## awk ' BEGIN {prev="^dummy/"} $0 !~ prev { print $0; prev="^"$0"/" }'
		## See https://stackoverflow.com/q/62652954/2635443
		if type comm > /dev/null 2>&1 ; then
			cmd="comm -23 \"${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__treeAfterFileNoSuffix]}\" \"${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__treeCurrentFile]}\" | awk ' BEGIN {prev=\"^dummyfirstlinefileshouldnotexist1234/\"} \$0 !~ prev { print \$0; prev=\"^\"\$0\"/\" }' > \"${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__deletedListFile]}\""
		else
			## The || : forces the command to have a good result
			cmd="(grep -F -x -v -f \"${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__treeCurrentFile]}\" \"${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__treeAfterFileNoSuffix]}\" || :) | awk ' BEGIN {prev=\"^dummyfirstlinefileshouldnotexist1234/\"} \$0 !~ prev { print \$0; prev=\"^\"\$0\"/\" }' > \"${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__deletedListFile]}\""
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
		if [ -f "${INITIATOR[$__stateDirAbsolute]}/$failedDeletionListFromReplica${INITIATOR[$__failedDeletedListFile]}" ]; then
			cat "${INITIATOR[$__stateDirAbsolute]}/$failedDeletionListFromReplica${INITIATOR[$__failedDeletedListFile]}" >> "${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__deletedListFile]}"
			subretval=$?
			if [ $subretval -eq 0 ]; then
				rm -f "${INITIATOR[$__stateDirAbsolute]}/$failedDeletionListFromReplica${INITIATOR[$__failedDeletedListFile]}"
			else
				Logger "Cannot add failed deleted list to current deleted list for replica [$replicaType]." "ERROR" $subretval
			fi
		fi
	else
		touch "${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__deletedListFile]}"
	fi

	# Make sure deletion list does not contain duplicates from faledDeleteListFile
	uniq "${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__deletedListFile]}" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP"
	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
		FileMove "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" "${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__deletedListFile]}"
		if [ $? -ne 0 ]; then
			Logger "Cannot move \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP\" => \"${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__deletedListFile]}\"" "ERROR"
		fi
	fi

	return $retval
}

function _getFileCtimeMtimeLocal {
	local replicaPath="${1}" # Contains replica path
	local replicaType="${2}" # Initiator / Target
	local fileList="${3}" # Contains list of files to get time attrs
	local timestampFile="${4}" # Where to store the timestamp file

	__CheckArguments 4 $# "$@"	#__WITH_PARANOIA_DEBUG

	echo -n "" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP"

	while IFS='' read -r file; do
		if [ -f "$replicaPath$file" ]; then
			$STAT_CTIME_MTIME_CMD "$replicaPath$file" >> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP"
			if [ $? -ne 0 ]; then
				Logger "Could not get file attributes for [$replicaPath$file]." "ERROR"
				echo "1" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$replicaType.$SCRIPT_PID.$TSTAMP"
			fi
		fi
	done < "$fileList"
	if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
		Logger "Getting file time attributes failed on $replicaType. Stopping execution." "CRITICAL"
		if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.error.$SCRIPT_PID.$TSTAMP")" "WARN"
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

	__CheckArguments 4 $# "$@"	#__WITH_PARANOIA_DEBUG

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
			Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "WARN"
		fi
		return $retval
	fi

#WIP: do we need separate error and non error files ?
$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env replicaPath="'$replicaPath'" env replicaType="'$replicaType'" env REMOTE_STAT_CTIME_MTIME_CMD="'$REMOTE_STAT_CTIME_MTIME_CMD'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP"
_REMOTE_TOKEN="(o_0)"
include #### RUN_DIR SUBSET ####
include #### DEBUG SUBSET ####
include #### TrapError SUBSET ####
include #### IsInteger SUBSET ####
include #### HumanToNumeric SUBSET ####
include #### RemoteLogger SUBSET ####
include #### CleanUp SUBSET ####

function _getFileCtimeMtimeRemoteSub {

	while IFS='' read -r file; do
		if [ -f "$replicaPath$file" ]; then
			$REMOTE_STAT_CTIME_MTIME_CMD "$replicaPath$file"
			if [ $? -ne 0 ]; then
				RemoteLogger "Could not get file attributes for [$replicaPath$file]." "ERROR"
				echo 1 > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$replicaType.$SCRIPT_PID.$TSTAMP"
			fi
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
		Logger "Getting file attributes failed with code [$retval] on $replicaType. Stopping execution." "CRITICAL" $retval
		if [ -s "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "WARN"
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

	__CheckArguments 4 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
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

	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ -f "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}$timestampCurrentFilename" ] && [ -f "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}$timestampCurrentFilename" ]; then
		# Remove prepending replicaPaths
		sed -i'.withReplicaPath' "s;^${INITIATOR[$__replicaDir]};;g" "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}$timestampCurrentFilename"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot remove prepending replicaPaths for current initiator timestamp file." "ERROR"
			return $retval
		fi
		sed -i'.withReplicaPath' "s;^${TARGET[$__replicaDir]};;g" "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}$timestampCurrentFilename"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot remove prepending replicaPaths for current target timestamp file." "ERROR"
			return $retval
		fi
	fi

	if [ -f "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}$timestampAfterFilename" ] && [ -f "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}$timestampAfterFilename" ]; then
		# Remove prepending replicaPaths
		sed -i'.withReplicaPath' "s;^${INITIATOR[$__replicaDir]};;g" "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}$timestampAfterFilename"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot remove prepending replicaPaths for after initiator timestamp file." "ERROR"
			return $retval
		fi
		sed -i'.withReplicaPath' "s;^${TARGET[$__replicaDir]};;g" "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}$timestampAfterFilename"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot remove prepending replicaPaths for after target timestamp file." "ERROR"
			return $retval
		fi
	fi

	if [ -f "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}$timestampAfterFilename" ] && [ -f "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}$timestampAfterFilename" ]; then

		Logger "Creating conflictual file list." "NOTICE"

		comm -23 "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}$timestampCurrentFilename" "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}$timestampAfterFilename" | sort -t ';' -k 1,1 > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.${INITIATOR[$__type]}.$SCRIPT_PID.$TSTAMP"
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Cannot extract conflict data for initiator replica." "ERROR"
			return $retval
		fi
		comm -23 "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}$timestampCurrentFilename" "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}$timestampAfterFilename" | sort -t ';' -k 1,1 > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.${TARGET[$__type]}.$SCRIPT_PID.$TSTAMP"
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

	__CheckArguments 2 $# "$@"	#__WITH_PARANOIA_DEBUG

	local initiatorPid
	local targetPid

	local rsyncCmd
	local retval

	local sourceDir
	local destDir
	local destReplica

	if [ "$LOCAL_OS" == "BusyBox" ] || [ "$LOCAL_OS" == "Android" ] || [ "$REMOTE_OS" == "BusyBox" ] || [ "$REMOTE_OS" == "Android" ]; then
		Logger "Skipping acl synchronization. Busybox does not have join command." "NOTICE"
		return 0
	fi

	Logger "Getting list of files that need updates." "NOTICE"

	if [ "$REMOTE_OPERATION" == true ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -i -n $RSYNC_DEFAULT_ARGS $RSYNC_ATTR_ARGS $RSYNC_PARTIAL_EXCLUDE -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE \"$initiatorReplica\" $REMOTE_USER@$REMOTE_HOST:\"'$targetReplica'\" >> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1"
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -i -n $RSYNC_DEFAULT_ARGS $RSYNC_ATTR_ARGS $RSYNC_PARTIAL_EXCLUDE --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE \"$initiatorReplica\" \"$targetReplica\" >> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP\" 2>&1"
	fi
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" &
	ExecTasks $! "${FUNCNAME[0]}_1" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
	retval=$?

	if [ $retval -ne 0 ] && [ $retval -ne 24 ]; then
		Logger "Getting list of files that need updates failed [$retval]. Stopping execution." "CRITICAL" $retval
		_LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated rsync output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")" "NOTICE"
		fi
		return $retval
	else
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated list:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP")" "VERBOSE"
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
		destDir="${TARGET[$__replicaDir]}"
		destReplica="${TARGET[$__type]}"
		join -j 1 -t ';' -o 1.1,1.2,2.2 "$RUN_DIR/$PROGRAM.ctime_mtime___.${INITIATOR[$__type]}.$SCRIPT_PID.$TSTAMP" "$RUN_DIR/$PROGRAM.ctime_mtime___.${TARGET[$__type]}.$SCRIPT_PID.$TSTAMP" | awk -F';' '{if ($2 > $3) print $1}' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID.$TSTAMP"
	else
		sourceDir="${TARGET[$__replicaDir]}"
		destDir="${INITIATOR[$__replicaDir]}"
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
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID.$TSTAMP\" $REMOTE_USER@$REMOTE_HOST:\"'$sourceDir'\" \"$destDir\" >> \"$RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP\" 2>&1"
		else
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID.$TSTAMP\" \"$sourceDir\" $REMOTE_USER@$REMOTE_HOST:\"'$destDir'\" >> \"$RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP\" 2>&1"
		fi
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}${INITIATOR[$__deletedListFile]}\" --exclude-from=\"${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}${INITIATOR[$__deletedListFile]}\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID.$TSTAMP\" \"$sourceDir\" \"$destDir\" >> \"$RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP\" 2>&1"

	fi

	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" &
	ExecTasks $! "${FUNCNAME[0]}_3" false 0 0 $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME false $SLEEP_TIME $KEEP_LOGGING
	retval=$?

	if [ $retval -ne 0 ] && [ $retval -ne 24 ]; then
		Logger "Updating file attributes on $destReplica [$retval]. Stopping execution." "CRITICAL" $retval
		_LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated rsync output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP")" "NOTICE"
		fi
		return 1
	else
		if [ -f "$RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated list:\n$(head -c16384 "$RUN_DIR/$PROGRAM.attr-update.$destReplica.$SCRIPT_PID.$TSTAMP")" "VERBOSE"
		fi
		Logger "Successfully updated file attributes on $destReplica replica." "NOTICE"
	fi
}

# syncUpdate(source replica, destination replica, delete_list_filename)
function syncUpdate {
	local sourceReplica="${1}" # Contains replica type of source: initiator, target
	local destinationReplica="${2}" # Contains replica type of destination: initiator, target
	local remoteDelete="${3:-false}" # Use rsnyc to delete remote files if not existent in source
	__CheckArguments 2-3 $# "$@"	#__WITH_PARANOIA_DEBUG

	local rsyncCmd
	local retval

	local sourceDir
	local destDir

	local backupArgs
	local deleteArgs
	local exclude_list_initiator
	local exclude_list_target

	Logger "Updating $destinationReplica replica." "NOTICE"
	if [ "$sourceReplica" == "${INITIATOR[$__type]}" ]; then
		sourceDir="${INITIATOR[$__replicaDir]}"
		destDir="${TARGET[$__replicaDir]}"
		backupArgs="$TARGET_BACKUP"
	else
		sourceDir="${TARGET[$__replicaDir]}"
		destDir="${INITIATOR[$__replicaDir]}"
		backupArgs="$INITIATOR_BACKUP"
	fi

	if [ "$remoteDelete" == true ]; then
		deleteArgs="--delete-after"
	fi

	if [ -f "${INITIATOR[$__stateDirAbsolute]}/$sourceReplica${INITIATOR[$__deletedListFile]}" ]; then
		exclude_list_initiator="--exclude-from=\"${INITIATOR[$__stateDirAbsolute]}/$sourceReplica${INITIATOR[$__deletedListFile]}\""
	fi
	if [ -f "${INITIATOR[$__stateDirAbsolute]}/$destinationReplica${INITIATOR[$__deletedListFile]}" ]; then
		exclude_list_target="--exclude-from=\"${INITIATOR[$__stateDirAbsolute]}/$destinationReplica${INITIATOR[$__deletedListFile]}\""
	fi

	if [ "$REMOTE_OPERATION" == true ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		if [ "$sourceReplica" == "${INITIATOR[$__type]}" ]; then
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DEFAULT_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $backupArgs $deleteArgs --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE $exclude_list_initiator $exclude_list_target \"$sourceDir\" $REMOTE_USER@$REMOTE_HOST:\"'$destDir'\" >> \"$RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP\" 2>&1"
		else
			rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DEFAULT_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $backupArgs $deleteArgs --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE $exclude_list_initiator $exclude_list_target $REMOTE_USER@$REMOTE_HOST:\"'$sourceDir'\" \"$destDir\" >> \"$RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP\" 2>&1"
		fi
	else
		rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" $RSYNC_DEFAULT_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS $backupArgs $deleteArgs --exclude \"$OSYNC_DIR\" $RSYNC_FULL_PATTERNS $RSYNC_PARTIAL_EXCLUDE $exclude_list_initiator $exclude_list_target \"$sourceDir\" \"$destDir\" >> \"$RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP\" 2>&1"
	fi
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd"
	retval=$?

	if [ $retval -ne 0 ] && [ $retval -ne 24 ]; then
		Logger "Updating $destinationReplica replica failed. Stopping execution." "CRITICAL" $retval
		_LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated rsync output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP")" "NOTICE"
		fi
		exit 1
	else
		if [ -f "$RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated list:\n$(head -c16384 "$RUN_DIR/$PROGRAM.update.$destinationReplica.$SCRIPT_PID.$TSTAMP")" "VERBOSE"
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
						retval=0
						if [ "$parentdir" != "." ]; then
							mkdir -p "$replicaDir$deletionDir/$parentdir"
							Logger "Moving deleted file [$replicaDir$files] to [$replicaDir$deletionDir/$parentdir] on $replicaType." "VERBOSE"
							FileMove "$replicaDir$files" "$replicaDir$deletionDir/$parentdir"
							retval=$?
						else
							FileMove "$replicaDir$files" "$replicaDir$deletionDir"
							retval=$?
						fi
						if [ $retval -ne 0 ]; then
							Logger "Cannot move [$replicaDir$files] to deletion directory [$replicaDir$deletionDir] on $replicaType." "ERROR" $retval
							echo "1" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.subshellError.$replicaType.$SCRIPT_PID.$TSTAMP"
							echo "$files" >> "${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__failedDeletedListFile]}"
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
							echo "$files" >> "${INITIATOR[$__stateDirAbsolute]}/$replicaType${INITIATOR[$__failedDeletedListFile]}"
						else
							echo "$files" >> "$RUN_DIR/$PROGRAM.delete.$replicaType.$SCRIPT_PID.$TSTAMP"
						fi
					fi
				fi
			fi
			previousFile="$files"
		fi
	done < "${INITIATOR[$__stateDirAbsolute]}/$deletionListFromReplica${INITIATOR[$__deletedListFile]}"
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
	__CheckArguments 3 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval
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

	failedDeleteList="${TARGET[$__stateDirAbsolute]}/$replicaType${TARGET[$__failedDeletedListFile]}"
	successDeleteList="${TARGET[$__stateDirAbsolute]}/$replicaType${TARGET[$__successDeletedListFile]}"

	## This is a special coded function. Need to redelcare local functions on remote host, passing all needed variables as escaped arguments to ssh command.
	## Anything beetween << ENDSSH and ENDSSH will be executed remotely

	# Additionnaly, we need to copy the deletetion list to the remote state folder
	rsyncCmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"${INITIATOR[$__stateDirAbsolute]}/$deletionListFromReplica${INITIATOR[$__deletedListFile]}\" $REMOTE_USER@$REMOTE_HOST:\"'${TARGET[$__stateDirAbsolute]}'/\" >> \"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID.$TSTAMP\" 2>&1"
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" 2>> "$LOG_FILE"
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Cannot copy the deletion list to remote replica." "ERROR" $retval
		_LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID.$TSTAMP")" "ERROR"
		fi
		exit 1
	fi

#TODO: change $REPLICA_TYPE to $replicaType as in other remote functions, also applies to all other not standard env variables here
$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env _DRYRUN="'$_DRYRUN'" \
env LOCAL_OS="$REMOTE_OS" \
env FILE_LIST="'${TARGET[$__stateDirAbsolute]}/$deletionListFromReplica${INITIATOR[$__deletedListFile]}'" env REPLICA_DIR="'$replicaDir'" env SOFT_DELETE="'$SOFT_DELETE'" \
env DELETION_DIR="'$deletionDir'" env FAILED_DELETE_LIST="'$failedDeleteList'" env SUCCESS_DELETE_LIST="'$successDeleteList'" env REPLICA_TYPE="'$replicaType'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' >> "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID.$TSTAMP" 2>&1
_REMOTE_TOKEN="(o_0)"
include #### RUN_DIR SUBSET ####
include #### DEBUG SUBSET ####
include #### TrapError SUBSET ####
include #### RemoteLogger SUBSET ####
include #### CleanUp SUBSET ####
include #### FileMove SUBSET ####

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
						retval=0
						if [ "$parentdir" != "." ]; then
							RemoteLogger "Moving deleted file [$REPLICA_DIR$files] to [$REPLICA_DIR$DELETION_DIR/$parentdir] on $REPLICA_TYPE." "VERBOSE"
							mkdir -p "$REPLICA_DIR$DELETION_DIR/$parentdir"
							FileMove "$REPLICA_DIR$files" "$REPLICA_DIR$DELETION_DIR/$parentdir"
							retval=$?
						else
							RemoteLogger "Moving deleted file [$REPLICA_DIR$files] to [$REPLICA_DIR$DELETION_DIR] on $REPLICA_TYPE." "VERBOSE"
							FileMove "$REPLICA_DIR$files" "$REPLICA_DIR$DELETION_DIR"
							retval=$?
						fi
						if [ $retval -ne 0 ]; then
							RemoteLogger "Cannot move [$REPLICA_DIR$files] to deletion directory [$REPLICA_DIR$DELETION_DIR] on $REPLICA_TYPE." "ERROR" $retval
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
		_LOGGER_PREFIX=""
		Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID.$TSTAMP")" "ERROR"
		)
	fi

	## Copy back the deleted failed file list
	rsyncCmd="$(type -p $RSYNC_EXECUTABLE) -r --rsync-path=\"env LC_ALL=C env _REMOTE_TOKEN=$_REMOTE_TOKEN $RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" --include \"$(dirname "${TARGET[$__stateDirAbsolute]}")\" --include \"${TARGET[$__stateDirAbsolute]}\" --include \"${TARGET[$__stateDirAbsolute]}/$replicaType${TARGET[$__failedDeletedListFile]}\" --include \"${TARGET[$__stateDirAbsolute]}/$replicaType${TARGET[$__successDeletedListFile]}\" --exclude='*' $REMOTE_USER@$REMOTE_HOST:\"'${TARGET[$__replicaDir]}'\" \"${INITIATOR[$__replicaDir]}\" > \"$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID.$TSTAMP\""
	Logger "RSYNC_CMD: $rsyncCmd" "DEBUG"
	eval "$rsyncCmd" 2>> "$LOG_FILE"
	if [ $? -ne 0 ]; then
		Logger "Cannot copy back the failed deletion list to initiator replica." "CRITICAL" $retval
		_LOGGER_SILENT=true Logger "Command was [$rsyncCmd]." "WARN"
		if [ -f "$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID.$TSTAMP" ]; then
			Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID.$TSTAMP")" "NOTICE"
		fi
		return 1
	fi
	return $retval
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
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	Logger "Initializing initiator and target file lists." "NOTICE"

	treeList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}${INITIATOR[$__treeAfterFile]}" &
	initiatorPid=$!

	treeList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}${INITIATOR[$__treeAfterFile]}" &
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

	timestampList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}${INITIATOR[$__treeAfterFile]}" "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}${INITIATOR[$__timestampAfterFile]}" &
	initiatorPid=$!

	timestampList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}${TARGET[$__treeAfterFile]}" "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}${INITIATOR[$__timestampAfterFile]}" &
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
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
			resumeCount="$(head -c16384 "${INITIATOR[$__resumeCount]}")"
		else
			resumeCount=0
		fi

		if [ $resumeCount -lt $RESUME_TRY ]; then
			if [ -f "${INITIATOR[$__initiatorLastActionFile]}" ]; then
				resumeInitiator="$(head -c16384 "${INITIATOR[$__initiatorLastActionFile]}")"
			else
				resumeInitiator="${SYNC_ACTION[9]}"
			fi

			if [ -f "${INITIATOR[$__targetLastActionFile]}" ]; then
				resumeTarget="$(head -c16384 "${INITIATOR[$__targetLastActionFile]}")"
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
			treeList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}${INITIATOR[$__treeCurrentFile]}" &
			initiatorPid=$!
		fi

		if [ "$resumeTarget" == "none" ] || [ "$resumeTarget" == "${SYNC_ACTION[0]}" ]; then
			treeList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}${INITIATOR[$__treeCurrentFile]}" &
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
				timestampList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}${INITIATOR[$__treeCurrentFile]}" "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}${INITIATOR[$__timestampCurrentFile]}" &
				initiatorPid=$!
			fi

			if [ "$resumeTarget" == "${SYNC_ACTION[2]}" ]; then
				timestampList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}${TARGET[$__treeCurrentFile]}" "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}${TARGET[$__timestampCurrentFile]}" &
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
			treeList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}${INITIATOR[$__treeAfterFile]}" &
			initiatorPid=$!
		fi

		if [ "$resumeTarget" == "${SYNC_ACTION[7]}" ]; then
			treeList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}${INITIATOR[$__treeAfterFile]}" &
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
				timestampList "${INITIATOR[$__replicaDir]}" "${INITIATOR[$__type]}" "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}${INITIATOR[$__treeAfterFile]}" "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__type]}${INITIATOR[$__timestampAfterFile]}" &
				initiatorPid=$!
			fi

			if [ "$resumeTarget" == "${SYNC_ACTION[8]}" ]; then
				timestampList "${TARGET[$__replicaDir]}" "${TARGET[$__type]}" "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}${TARGET[$__treeAfterFile]}" "${INITIATOR[$__stateDirAbsolute]}/${TARGET[$__type]}${TARGET[$__timestampAfterFile]}" &
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

	__CheckArguments 4 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ "$LOCAL_OS" == "Busybox" ] || [ "$LOCAL_OS" == "Android" ] || [ "$LOCAL_OS" == "Qnap" ]; then
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
			Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP")" "WARN"
		else
			Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP")" "VERBOSE"
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

	__CheckArguments 4 $# "$@"	#__WITH_PARANOIA_DEBUG

	local retval

	if [ "$REMOTE_OS" == "BusyBox" ] || [ "$REMOTE_OS" == "Android" ] || [ "$REMOTE_OS" == "Qnap" ]; then
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
_REMOTE_TOKEN="(o_0)"
include #### RUN_DIR SUBSET ####
include #### DEBUG SUBSET ####
include #### TrapError SUBSET ####
include #### IsInteger SUBSET ####
include #### HumanToNumeric SUBSET ####
include #### RemoteLogger SUBSET ####
include #### CleanUp SUBSET ####

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
			RemoteLogger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP")" "WARN"
			exit 1
		else
			RemoteLogger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.deleteErrors.$replicaType.$SCRIPT_PID.$TSTAMP")" "VERBOSE"
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
		Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "WARN"
		)
	else
		Logger "Cleanup complete on $replicaType replica." "NOTICE"
		(
		_LOGGER_PREFIX=""
		Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$replicaType.$SCRIPT_PID.$TSTAMP")" "VERBOSE"
		)
	fi
}

function SoftDelete {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	local PUSH_FILE

	PUSH_FILE="${INITIATOR[$__replicaDir]}${INITIATOR[$__updateTriggerFile]}"

	if [ -d $(dirname "$PUSH_FILE") ]; then
		echo "$INSTANCE_ID#$(date '+%Y%m%dT%H%M%S.%N')" >> "$PUSH_FILE" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
		if [ $? -ne 0 ]; then
			Logger "Could not notify local initiator of file changes." "ERROR"
			Logger "Truncated output:\n$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP")" "ERROR"
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
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

$SSH_CMD env _REMOTE_TOKEN="$_REMOTE_TOKEN" \
env _DEBUG="'$_DEBUG'" env _PARANOIA_DEBUG="'$_PARANOIA_DEBUG'" env _LOGGER_SILENT="'$_LOGGER_SILENT'" env _LOGGER_VERBOSE="'$_LOGGER_VERBOSE'" env _LOGGER_PREFIX="'$_LOGGER_PREFIX'" env _LOGGER_ERR_ONLY="'$_LOGGER_ERR_ONLY'" \
env _REMOTE_EXECUTION="true" env PROGRAM="'$PROGRAM'" env SCRIPT_PID="'$SCRIPT_PID'" env TSTAMP="'$TSTAMP'" \
env INSTANCE_ID="'$INSTANCE_ID'" env PUSH_FILE="'${INITIATOR[$__replicaDir]}${INITIATOR[$__updateTriggerFile]}'" \
env LC_ALL=C $COMMAND_SUDO' bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID.$TSTAMP" 2> "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP"
_REMOTE_TOKEN="(o_0)"
include #### RUN_DIR SUBSET ####
include #### DEBUG SUBSET ####
include #### TrapError SUBSET ####
include #### RemoteLogger SUBSET ####
include #### CleanUp SUBSET ####

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
		_LOGGER_PREFIX=""
		Logger "$(head -c16384 "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.error.$SCRIPT_PID.$TSTAMP")" "ERROR"
		)
		return 1
	else
		Logger "Initiator of instance [$INSTANCE_ID] should be notified of file changes now." "NOTICE"
	fi
	return 0
}

function TriggerInitiatorRun {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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

	__CheckArguments 3 $# "$@"	#__WITH_PARANOIA_DEBUG

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

	__CheckArguments 3 $# "$@"	#__WITH_PARANOIA_DEBUG

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
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
		_SummaryFromDeleteFile "${TARGET[$__replicaDir]}" "${INITIATOR[$__stateDirAbsolute]}/target${TARGET[$__successDeletedListFile]}" "- >>"
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
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	local subject
	local body

	local conflicts=0

	if [ -s "$RUN_DIR/$PROGRAM.conflictList.compare.$SCRIPT_PID.$TSTAMP" ]; then
		Logger "File conflicts: INITIATOR << >> TARGET" "ALWAYS"
		> "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__conflictListFile]}"
		while read -r line; do
			echo "${INITIATOR[$__replicaDir]}$(echo "$line" | awk -F';' '{print $1}') << >> ${TARGET[$__replicaDir]}$(echo "$line" | awk -F';' '{print $1}')" >> "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__conflictListFile]}"
			conflicts=$((conflicts+1))
		done < "$RUN_DIR/$PROGRAM.conflictList.compare.$SCRIPT_PID.$TSTAMP"

		if [ -s "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__conflictListFile]}" ]; then
			(
			_LOGGER_PREFIX=""
			Logger "Truncated output:\n$(head -c16384 "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__conflictListFile]}")" "ALWAYS"
			)
		fi

		Logger "There are $conflicts conflictual files." "ALWAYS"
	else
		Logger "No are no conflicatual files." "ALWAYS"
	fi

	if [ "$ALERT_CONFLICTS" == true ] && [ -s "$RUN_DIR/$PROGRAM.conflictList.compare.$SCRIPT_PID.$TSTAMP" ]; then
		subject="Conflictual files found in [$INSTANCE_ID]"
		body="Truncated list of conflictual files:"$'\n'"$(head -c16384 "${INITIATOR[$__stateDirAbsolute]}/${INITIATOR[$__conflictListFile]}")"

		SendEmail "$subject" "$body" "$DESTINATION_MAILS" "" "$SENDER_MAIL" "$SMTP_SERVER" "$SMTP_PORT" "$SMTP_ENCRYPTION" "$SMTP_USER" "$SMTP_PASSWORD"
	fi
}

function Init {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
	readonly __stateDirAbsolute=3
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
	if [ "$INITIATOR_CUSTOM_STATE_DIR" != "" ]; then
		INITIATOR[$__stateDirAbsolute]="$INITIATOR_CUSTOM_STATE_DIR"
	else
		INITIATOR[$__stateDirAbsolute]="$INITIATOR_SYNC_DIR$OSYNC_DIR/$stateDir"
	fi
	INITIATOR[$__backupDir]="$OSYNC_DIR/$backupDir"
	INITIATOR[$__deleteDir]="$OSYNC_DIR/$deleteDir"
	INITIATOR[$__partialDir]="$OSYNC_DIR/$partialDir"
	INITIATOR[$__initiatorLastActionFile]="${INITIATOR[$__stateDirAbsolute]}/initiator-$lastAction-$INSTANCE_ID$drySuffix"
	INITIATOR[$__targetLastActionFile]="${INITIATOR[$__stateDirAbsolute]}/target-$lastAction-$INSTANCE_ID$drySuffix"
	INITIATOR[$__resumeCount]="${INITIATOR[$__stateDirAbsolute]}/$resumeCount-$INSTANCE_ID$drySuffix"
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
	if [ "$TARGET_CUSTOM_STATE_DIR" != "" ]; then
		TARGET[$__stateDirAbsolute]="$TARGET_CUSTOM_STATE_DIR"
	else
		TARGET[$__stateDirAbsolute]="$TARGET_SYNC_DIR$OSYNC_DIR/$stateDir"
	fi
	TARGET[$__backupDir]="$OSYNC_DIR/$backupDir"
	TARGET[$__deleteDir]="$OSYNC_DIR/$deleteDir"
	TARGET[$__partialDir]="$OSYNC_DIR/$partialDir"											# unused
	TARGET[$__initiatorLastActionFile]="${TARGET[$__stateDirAbsolute]}/initiator-$lastAction-$INSTANCE_ID$drySuffix"		# unused
	TARGET[$__targetLastActionFile]="${TARGET[$__stateDirAbsolute]}/target-$lastAction-$INSTANCE_ID$drySuffix"		# unused
	TARGET[$__resumeCount]="${TARGET[$__stateDirAbsolute]}/$resumeCount-$INSTANCE_ID$drySuffix"				# unused
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
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

	HandleLocks
	Sync
}

function Usage {
	__CheckArguments 0 $# "$@"	#__WITH_PARANOIA_DEBUG

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
	echo "--initiator=\"\"		 Master replica path. Will contain state and backup directory (is mandatory)"
	echo "--target=\"\" 		 Local or remote target replica path. Can be a ssh uri like ssh://user@host.com:22//path/to/target/replica (is mandatory)"
	echo "--rsakey=\"\"		 Alternative path to rsa private key for ssh connection to target replica"
	echo "--ssh-controlmaster      Allow using a single TCP connection for all ssh calls. Will make remote sync faster, but may fail easier on lossy links"
	echo "--password-file=\"\"       If no rsa private key is used for ssh authentication, a password file can be used"
	echo "--remote-token=\"\"        When using ssh filter protection, you must specify the remote token set in ssh_filter.sh"
	echo "--instance-id=\"\"	 Optional sync task name to identify this synchronization task when using multiple targets"
	echo "--skip-deletion=\"\"       You may skip deletion propagation on initiator or target. Valid values: initiator target initiator,target"
	echo "--sync-type=\"\"           Allows osync to run in unidirectional sync mode. Valid values: initiator2target, target2initiator"
	echo "--destination-mails=\"\"   Double quoted list of space separated email addresses to send alerts to"
	echo "--initiator-state-dir=\"\" Path to initiator osync state dir, defaults to initiator_replica/.osync_workdir/state"
	echo "--target-state-dir=\"\"    Path to target osync state dir, defaults to target_replica/.osync_workdir/state"
	echo ""
	echo "Additionaly, you may set most osync options at runtime. eg:"
	echo "SOFT_DELETE_DAYS=365 $0 --initiator=/path --target=/other/path"
	echo ""
	exit 128
}

function SyncOnChanges {
	local isTargetHelper="${1:-false}"		# Is this service supposed to be run as target helper ?

	__CheckArguments 1 $# "$@"	#__WITH_PARANOIA_DEBUG

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
INITIATOR_CUSTOM_STATE_DIR=""
TARGET_CUSTOM_STATE_DIR=""
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
			--ssh-controlmaster)
			SSH_CONTROLMASTER=true
			opts=$opts" --ssh-controlmaster"
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
			--initiator-state-dir=*)
			INITIATOR_CUSTOM_STATE_DIR="${i##*=}"
			;;
			--target-state-dir=*)
			TARGET_CUSTOM_STATE_DIR="${i##*=}"
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
	if [ $(IsInteger "$MINIMUM_SPACE") -ne 1 ]; then
		MINIMUM_SPACE=1024
	fi

	if [ $(IsInteger "$CONFLICT_BACKUP_DAYS") -ne 1 ]; then
		CONFLICT_BACKUP_DAYS=30
	fi

	if [ $(IsInteger "$SOFT_DELETE_DAYS") -ne 1 ]; then
		SOFT_DELETE_DAYS=30
	fi

	if [ $(IsInteger "$RESUME_TRY") -ne 1 ]; then
		RESUME_TRY=1
	fi

	if [ $(IsInteger "$SOFT_MAX_EXEC_TIME") -ne 1 ]; then
		SOFT_MAX_EXEC_TIME=0
	fi

	if [ $(IsInteger "$HARD_MAX_EXEC_TIME") -ne 1 ]; then
		HARD_MAX_EXEC_TIME=0
	fi

	if [ $(IsInteger "$MAX_EXEC_TIME_PER_CMD_BEFORE") -ne 1 ]; then
		MAX_EXEC_TIME_PER_CMD_BEFORE=0
	fi

	if [ $(IsInteger "$MAX_EXEC_TIME_PER_CMD_AFTER") -ne 1 ]; then
		MAX_EXEC_TIME_PER_CMD_AFTER=0
	fi

	if [ "$RSYNC_COMPRESS" == "" ]; then
		RSYNC_COMPRESS=true
	fi

	if [ "$PATH_SEPARATOR_CHAR" == "" ]; then
		PATH_SEPARATOR_CHAR=";"
	fi

	if [ $(IsInteger "$MIN_WAIT") -ne 1 ]; then
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
if [ ! -w "$(dirname "$LOG_FILE")" ]; then
	echo "Cannot write to log [$(dirname "$LOG_FILE")]."
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
