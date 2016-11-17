#!/usr/bin/env bash

PROGRAM="osync" # Rsync based two way sync engine with fault tolerance
AUTHOR="(C) 2013-2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION=1.1.5
PROGRAM_BUILD=2016111701
IS_STABLE=yes

source "./ofunctions.sh"

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
		exit 1
	fi
}

function TrapQuit {
	local exitcode=

	# Get ERROR / WARN alert flags from subprocesses that call Logger
	if [ -f "$RUN_DIR/$PROGRAM.Logger.warn.$SCRIPT_PID" ]; then
		WARN_ALERT=1
	fi
	if [ -f "$RUN_DIR/$PROGRAM.Logger.error.$SCRIPT_PID" ]; then
		ERROR_ALERT=1
	fi

	if [ $ERROR_ALERT -ne 0 ]; then
		UnlockReplicas
		if [ "$_DEBUG" != "yes" ]
		then
			SendAlert
		else
			Logger "Debug mode, no alert mail will be sent." "NOTICE"
		fi
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
		CleanUp
		Logger "$PROGRAM finished with errors." "ERROR"
		exitcode=1
	elif [ $WARN_ALERT -ne 0 ]; then
		UnlockReplicas
		if [ "$_DEBUG" != "yes" ]
		then
			SendAlert
		else
			Logger "Debug mode, no alert mail will be sent." "NOTICE"
		fi
		if [ "$RUN_AFTER_CMD_ON_ERROR" == "yes" ]; then
			RunAfterHook
		fi
		CleanUp
		Logger "$PROGRAM finished with warnings." "WARN"
		exitcode=240	# Special exit code for daemon mode not stopping on warnings
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
        __CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

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
        __CheckArguments 0 $# ${FUNCNAME[0]} "$@"    #__WITH_PARANOIA_DEBUG

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
        declare -a yes_no_vars=(CREATE_DIRS SUDO_EXEC SSH_COMPRESSION SSH_IGNORE_KNOWN_HOSTS REMOTE_HOST_PING PRESERVE_ACL PRESERVE_XATTR COPY_SYMLINKS KEEP_DIRLINKS PRESERVE_HARDLINKS CHECKSUM RSYNC_COMPRESS CONFLICT_BACKUP CONFLICT_BACKUP_MULTIPLE SOFT_DELETE RESUME_SYNC FORCE_STRANGER_LOCK_RESUME PARTIAL DELTA_COPIES STOP_ON_CMD_ERROR RUN_AFTER_CMD_ON_ERROR)
        for i in "${yes_no_vars[@]}"; do
                test="if [ \"\$$i\" != \"yes\" ] && [ \"\$$i\" != \"no\" ]; then Logger \"Bogus $i value defined in config file. Correct your config file or update it using the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
                eval "$test"
        done

        # Check all variables that should contain a numerical value >= 0
        declare -a num_vars=(MINIMUM_SPACE BANDWIDTH SOFT_MAX_EXEC_TIME HARD_MAX_EXEC_TIME MIN_WAIT MAX_WAIT CONFLICT_BACKUP_DAYS SOFT_DELETE_DAYS RESUME_TRY MAX_EXEC_TIME_PER_CMD_BEFORE MAX_EXEC_TIME_PER_CMD_AFTER)
        for i in "${num_vars[@]}"; do
		test="if [ $(IsNumeric \"\$$i\") -eq 0 ]; then Logger \"Bogus $i value defined in config file. Correct your config file or update it using the update script if using and old version.\" \"CRITICAL\"; exit 1; fi"
                eval "$test"
        done

        #TODO-v2.1: Add runtime variable tests (RSYNC_ARGS etc)
}

###### Osync specific functions (non shared)

function _CreateStateDirsLocal {
	local replica_state_dir="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if ! [ -d "$replica_state_dir" ]; then
		$COMMAND_SUDO mkdir -p "$replica_state_dir" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1
		if [ $? != 0 ]; then
			Logger "Cannot create state dir [$replica_state_dir]." "CRITICAL"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
			exit 1
		fi
	fi
}

function _CreateStateDirsRemote {
	local replica_state_dir="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local cmd=

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if ! [ -d \"'$replica_state_dir'\" ]; then '$COMMAND_SUDO' mkdir -p \"'$replica_state_dir'\"; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 ${FUNCNAME[0]}
	if [ $? != 0 ]; then
		Logger "Cannot create remote state dir [$replica_state_dir]." "CRITICAL"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		exit 1
	fi
}

#TODO: also create deleted and backup dirs
function CreateStateDirs {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	_CreateStateDirsLocal "${INITIATOR[1]}${INITIATOR[3]}"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CreateStateDirsLocal "${TARGET[1]}${TARGET[3]}"
	else
		_CreateStateDirsRemote "${TARGET[1]}${TARGET[3]}"
	fi
}

function _CheckReplicaPathsLocal {
	local replica_path="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ ! -d "$replica_path" ]; then
		if [ "$CREATE_DIRS" == "yes" ]; then
			$COMMAND_SUDO mkdir -p "$replica_path" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1
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

	if [ ! -w "$replica_path" ]; then
		Logger "Local replica path [$replica_path] is not writable." "CRITICAL"
		exit 1
	fi
}

function _CheckReplicaPathsRemote {
	local replica_path="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local cmd=

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost
	cmd=$SSH_CMD' "if ! [ -d \"'$replica_path'\" ]; then if [ \"'$CREATE_DIRS'\" == \"yes\" ]; then '$COMMAND_SUDO' mkdir -p \"'$replica_path'\"; fi; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 ${FUNCNAME[0]}
	if [ $? != 0 ]; then
		Logger "Cannot create remote replica path [$replica_path]." "CRITICAL"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "ERROR"
		exit 1
	fi

	cmd=$SSH_CMD' "if [ ! -w \"'$replica_path'\" ];then exit 1; fi" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 ${FUNCNAME[0]}
	if [ $? != 0 ]; then
		Logger "Remote replica path [$replica_path] is not writable." "CRITICAL"
		exit 1
	fi
}

function CheckReplicaPaths {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	#INITIATOR_SYNC_DIR_CANN=$(realpath "${INITIATOR[1]}")	#TODO: investigate realpath & readlink issues on MSYS and busybox here
	#TARGET_SYNC_DIR_CANN=$(realpath "${TARGET[1]})

	#if [ "$REMOTE_OPERATION" != "yes" ]; then
	#	if [ "$INITIATOR_SYNC_DIR_CANN" == "$TARGET_SYNC_DIR_CANN" ]; then
	#		Logger "Master directory [${INITIATOR[1]}] cannot be the same as target directory." "CRITICAL"
	#		exit 1
	#	fi
	#fi

	_CheckReplicaPathsLocal "${INITIATOR[1]}"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CheckReplicaPathsLocal "${TARGET[1]}"
	else
		_CheckReplicaPathsRemote "${TARGET[1]}"
	fi
}

function _CheckDiskSpaceLocal {
	local replica_path="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local disk_space=

	Logger "Checking minimum disk space in [$replica_path]." "NOTICE"

	disk_space=$(df -P "$replica_path" | tail -1 | awk '{print $4}')
	if [ $disk_space -lt $MINIMUM_SPACE ]; then
		Logger "There is not enough free space on replica [$replica_path] ($disk_space KB)." "WARN"
	fi
}

function _CheckDiskSpaceRemote {
	local replica_path="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	Logger "Checking minimum disk space on target [$replica_path]." "NOTICE"

	local cmd=
	local disk_space=

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "'$COMMAND_SUDO' df -P \"'$replica_path'\"" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 ${FUNCNAME[0]}
	if [ $? != 0 ]; then
		Logger "Cannot get free space on target [$replica_path]." "ERROR"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	else
		disk_space=$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID | tail -1 | awk '{print $4}')
		if [ $disk_space -lt $MINIMUM_SPACE ]; then
			Logger "There is not enough free space on replica [$replica_path] ($disk_space KB)." "WARN"
		fi
	fi
}

function CheckDiskSpace {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	_CheckDiskSpaceLocal "${INITIATOR[1]}"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CheckDiskSpaceLocal "${TARGET[1]}"
	else
		_CheckDiskSpaceRemote "${TARGET[1]}"
	fi
}

function _WriteLockFilesLocal {
	local lockfile="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	$COMMAND_SUDO echo "$SCRIPT_PID@$INSTANCE_ID" > "$lockfile"
	if [ $?	!= 0 ]; then
		Logger "Could not create lock file [$lockfile]." "CRITICAL"
		exit 1
	else
		Logger "Locked replica on [$lockfile]." "DEBUG"
	fi
}

function _WriteLockFilesRemote {
	local lockfile="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local cmd=

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "echo '$SCRIPT_PID@$INSTANCE_ID' | '$COMMAND_SUDO' tee \"'$lockfile'\"" > /dev/null 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 ${FUNCNAME[0]}
	if [ $? != 0 ]; then
		Logger "Could not set lock on remote target replica." "CRITICAL"
		exit 1
	else
		Logger "Locked remote target replica." "DEBUG"
	fi
}

function WriteLockFiles {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	_WriteLockFilesLocal "${INITIATOR[2]}"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_WriteLockFilesLocal "${TARGET[2]}"
	else
		_WriteLockFilesRemote "${TARGET[2]}"
	fi
}

function _CheckLocksLocal {
	local lockfile="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local lockfile_content=
	local lock_pid=
	local lock_instance_id=

	if [ -f "$lockfile" ]; then
		lockfile_content=$(cat $lockfile)
		Logger "Master lock pid present: $lockfile_content" "DEBUG"
		lock_pid=${lockfile_content%@*}
		lock_instance_id=${lockfile_content#*@}
		ps -p$lock_pid > /dev/null 2>&1
		if [ $? != 0 ]; then
			Logger "There is a dead osync lock in [$lockfile]. Instance [$lock_pid] no longer running. Resuming." "NOTICE"
		else
			Logger "There is already a local instance of osync running [$lock_pid]. Cannot start." "CRITICAL"
			exit 1
		fi
	fi
}

function _CheckLocksRemote {
	local lockfile="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local cmd=
	local lock_pid=
	local lock_instance_id=
	local lockfile_content=

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if [ -f \"'$lockfile'\" ]; then cat \"'$lockfile'\"; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'"'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 ${FUNCNAME[0]}
	if [ $? == 0 ]; then
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
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

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
	_CheckLocksLocal "${INITIATOR[2]}"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_CheckLocksLocal "${TARGET[2]}"
	else
		_CheckLocksRemote "${TARGET[2]}"
	fi

	WriteLockFiles
}

function _UnlockReplicasLocal {
	local lockfile="${1}"
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

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
	__CheckArguments 1 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local cmd=

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	cmd=$SSH_CMD' "if [ -f \"'$lockfile'\" ]; then '$COMMAND_SUDO' rm -f \"'$lockfile'\"; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
	Logger "cmd: $cmd" "DEBUG"
	eval "$cmd" &
	WaitForTaskCompletion $! 720 1800 ${FUNCNAME[0]}
	if [ $? != 0 ]; then
		Logger "Could not unlock remote replica." "ERROR"
		Logger "Command Output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	else
		Logger "Removed remote replica lock." "DEBUG"
	fi
}

function UnlockReplicas {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ $_NOLOCKS -eq 1 ]; then
		return 0
	fi

	_UnlockReplicasLocal "${INITIATOR[2]}"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_UnlockReplicasLocal "${TARGET[2]}"
	else
		_UnlockReplicasRemote "${TARGET[2]}"
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

	local escaped_replica_path=
	local rsync_cmd=

	__CheckArguments 3 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	escaped_replica_path=$(EscapeSpaces "$replica_path")

	Logger "Creating $replica_type replica file list [$replica_path]." "NOTICE"
	if [ "$REMOTE_OPERATION" == "yes" ] && [ "$replica_type" == "${TARGET[0]}" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS -8 --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE -e \"$RSYNC_SSH_CMD\" --list-only $REMOTE_USER@$REMOTE_HOST:\"$escaped_replica_path/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.$replica_type.$SCRIPT_PID\" &"
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS -8 --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --list-only \"$replica_path/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/$PROGRAM.$replica_type.$SCRIPT_PID\" &"
	fi
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	## Redirect commands stderr here to get rsync stderr output in logfile with eval "$rsync_cmd" 2>> "$LOG_FILE"
	## When log writing fails, $! is empty and WaitForCompletion fails.  Removing the 2>> log
	eval "$rsync_cmd"
	WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]}
	retval=$?
	## Retval 24 = some files vanished while creating list
	if ([ $retval == 0 ] || [ $retval == 24 ]) && [ -f "$RUN_DIR/$PROGRAM.$replica_type.$SCRIPT_PID" ]; then
		mv -f "$RUN_DIR/$PROGRAM.$replica_type.$SCRIPT_PID" "${INITIATOR[1]}${INITIATOR[3]}/$replica_type$tree_filename"
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
	__CheckArguments 5 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local cmd=

	Logger "Creating $replica_type replica deleted file list." "NOTICE"
	if [ -f "${INITIATOR[1]}${INITIATOR[3]}/$replica_type$TREE_AFTER_FILENAME_NO_SUFFIX" ]; then
		## Same functionnality, comm is much faster than grep but is not available on every platform
		if type comm > /dev/null 2>&1 ; then
			cmd="comm -23 \"${INITIATOR[1]}${INITIATOR[3]}/$replica_type$TREE_AFTER_FILENAME_NO_SUFFIX\" \"${INITIATOR[1]}${INITIATOR[3]}/$replica_type$tree_file_current\" > \"${INITIATOR[1]}${INITIATOR[3]}/$replica_type$deleted_list_file\""
		else
			## The || : forces the command to have a good result
			cmd="(grep -F -x -v -f \"${INITIATOR[1]}${INITIATOR[3]}/$replica_type$tree_file_current\" \"${INITIATOR[1]}${INITIATOR[3]}/$replica_type$TREE_AFTER_FILENAME_NO_SUFFIX\" || :) > \"${INITIATOR[1]}${INITIATOR[3]}/$replica_type$deleted_list_file\""
		fi

		Logger "CMD: $cmd" "DEBUG"
		eval "$cmd" 2>> "$LOG_FILE"
		retval=$?

		# Add delete failed file list to current delete list and then empty it
		if [ -f "${INITIATOR[1]}${INITIATOR[3]}/$replica_type$deleted_failed_list_file" ]; then
			cat "${INITIATOR[1]}${INITIATOR[3]}/$replica_type$deleted_failed_list_file" >> "${INITIATOR[1]}${INITIATOR[3]}/$replica_type$deleted_list_file"
			rm -f "${INITIATOR[1]}${INITIATOR[3]}/$replica_type$deleted_failed_list_file"
		fi

		return $retval
	else
		touch "${INITIATOR[1]}${INITIATOR[3]}/$replica_type$deleted_list_file"
		return $retval
	fi
}

function _get_file_ctime_mtime_local {
	local replica_path="${1}" # Contains replica path
	local replica_type="${2}" # Initiator / Target
	local file_list="${3}" # Contains list of files to get time attrs
	__CheckArguments 3 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	echo -n "" > "$RUN_DIR/$PROGRAM.ctime_mtime.$replica_type.$SCRIPT_PID"
	while read file; do $STAT_CTIME_MTIME_CMD "$replica_path$file" | sort >> "$RUN_DIR/$PROGRAM.ctime_mtime.$replica_type.$SCRIPT_PID"; done < "$file_list"
}

function _get_file_ctime_mtime_remote {
	local replica_path="${1}" # Contains replica path
	local replica_type="${2}"
	local file_list="${3}"
	__CheckArguments 3 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local cmd

	cmd='cat "'$file_list'" | '$SSH_CMD' "while read file; do '$REMOTE_STAT_CTIME_MTIME_CMD' \"'$replica_path'\$file\"; done | sort" > "'$RUN_DIR/$PROGRAM.ctime_mtime.$replica_type.$SCRIPT_PID'"'
	Logger "CMD: $cmd" "DEBUG"
	eval $cmd
	WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]}
	if [ $? != 0 ]; then
		Logger "Getting file attributes failed [$retval] on $replica_type. Stopping execution." "CRITICAL"
		if [ $_VERBOSE -eq 0 ] && [ -f "$RUN_DIR/$PROGRAM.ctime_mtime.$replica_type.$SCRIPT_PID" ]; then
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.ctime_mtime.$replica_type.$SCRIPT_PID)" "NOTICE"
		fi
		exit 1
	fi
}

# rsync does sync with mtime, but file attribute modifications only change ctime.
# Hence, detect newer ctime on the replica that gets updated first with CONFLICT_PREVALANCE and update all newer file attributes on this replica before real update
function sync_attrs {
	local initiator_replica="${1}"
	local target_replica="${2}"
	local delete_list_filename="$DELETED_LIST_FILENAME" # Contains deleted list filename, will be prefixed with replica type
	__CheckArguments 2 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local rsync_cmd=
	local retval=

	Logger "Getting list of files that need updates." "NOTICE"

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -i -n -8 $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_PARTIAL_EXCLUDE -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE \"$initiator_replica\" $REMOTE_USER@$REMOTE_HOST:\"$target_replica\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1 &"
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -i -n -8 $RSYNC_ARGS $RSYNC_ATTR_ARGS $RSYNC_PARTIAL_EXCLUDE --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE \"$initiator_replica\" \"$target_replica\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID 2>&1 &"
	fi
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	eval "$rsync_cmd"
	WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]}
	retval=$?
	if [ $_VERBOSE -eq 1 ] && [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
		Logger "List:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	fi

	if [ $retval != 0 ] && [ $retval != 24 ]; then
		Logger "Getting list of files that need updates failed [$retval]. Stopping execution." "CRITICAL"
		if [ $_VERBOSE -eq 0 ] && [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" ]; then
			Logger "Rsync output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
		fi
		exit $retval
	else
		cat "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" | ( grep -Ev "^[^ ]*(c|s|t)[^ ]* " || :) | ( grep -E "^[^ ]*(p|o|g|a)[^ ]* " || :) | sed -e 's/^[^ ]* //' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID"
		if [ $? != 0 ]; then
			Logger "Cannot prepare file list for attribute sync." "CRITICAL"
			exit 1
		fi
	fi

	Logger "Getting ctimes for pending files on initiator." "NOTICE"
	_get_file_ctime_mtime_local "${INITIATOR[1]}" "${INITIATOR[0]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID"

	Logger "Getting ctimes for pending files on target." "NOTICE"
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_get_file_ctime_mtime_local "${TARGET[1]}" "${TARGET[0]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID"
	else
		_get_file_ctime_mtime_remote "${TARGET[1]}" "${TARGET[0]}" "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-cleaned.$SCRIPT_PID"
	fi


	# If target gets updated first, then sync_attr must update initiator's attrs first
	# For join, remove leading replica paths

	sed -i'.tmp' "s;^${INITIATOR[1]};;g" "$RUN_DIR/$PROGRAM.ctime_mtime.${INITIATOR[0]}.$SCRIPT_PID"
	sed -i'.tmp' "s;^${TARGET[1]};;g" "$RUN_DIR/$PROGRAM.ctime_mtime.${TARGET[0]}.$SCRIPT_PID"

	if [ "$CONFLICT_PREVALANCE" == "${TARGET[0]}" ]; then
		local source_dir="${INITIATOR[1]}"
		local esc_source_dir=$(EscapeSpaces "${INITIATOR[1]}")
		local dest_dir="${TARGET[1]}"
		local esc_dest_dir=$(EscapeSpaces "${TARGET[1]}")
		local dest_replica="${TARGET[0]}"
		join -j 1 -t ';' -o 1.1,1.2,2.2 "$RUN_DIR/$PROGRAM.ctime_mtime.${INITIATOR[0]}.$SCRIPT_PID" "$RUN_DIR/$PROGRAM.ctime_mtime.${TARGET[0]}.$SCRIPT_PID" | awk -F';' '{if ($2 > $3) print $1}' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID"
	else
		local source_dir="${TARGET[1]}"
		local esc_source_dir=$(EscapeSpaces "${TARGET[1]}")
		local dest_dir="${INITIATOR[1]}"
		local esc_dest_dir=$(EscapeSpaces "${INITIATOR[1]}")
		local dest_replica="${INITIATOR[0]}"
		join -j 1 -t ';' -o 1.1,1.2,2.2 "$RUN_DIR/$PROGRAM.ctime_mtime.${TARGET[0]}.$SCRIPT_PID" "$RUN_DIR/$PROGRAM.ctime_mtime.${INITIATOR[0]}.$SCRIPT_PID" | awk -F';' '{if ($2 > $3) print $1}' > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID"
	fi

	if [ $(wc -l < "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID") -eq 0 ]; then
		Logger "Updating file attributes on $dest_replica not required" "NOTICE"
		return 0
	fi

	Logger "Updating file attributes on $dest_replica." "NOTICE"

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost

		# No rsync args (hence no -r) because files are selected with --from-file
		if [ "$dest_replica" == "${INITIATOR[0]}" ]; then
			rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[1]}${INITIATOR[3]}/${INITIATOR[0]}$delete_list_filename\" --exclude-from=\"${INITIATOR[1]}${INITIATOR[3]}/${TARGET[0]}$delete_list_filename\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID\" $REMOTE_USER@$REMOTE_HOST:\"$esc_source_dir\" \"$dest_dir\" > $RUN_DIR/$PROGRAM.attr-update.$dest_replica.$SCRIPT_PID 2>&1 &"
		else
			rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[1]}${INITIATOR[3]}/${INITIATOR[0]}$delete_list_filename\" --exclude-from=\"${INITIATOR[1]}${INITIATOR[3]}/${TARGET[0]}$delete_list_filename\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID\" \"$source_dir\" $REMOTE_USER@$REMOTE_HOST:\"$esc_dest_dir\" > $RUN_DIR/$PROGRAM.attr-update.$dest_replica.$SCRIPT_PID 2>&1 &"
		fi
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $SYNC_OPTS --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[1]}${INITIATOR[3]}/${INITIATOR[0]}$delete_list_filename\" --exclude-from=\"${INITIATOR[1]}${INITIATOR[3]}/${TARGET[0]}$delete_list_filename\" --files-from=\"$RUN_DIR/$PROGRAM.${FUNCNAME[0]}-ctime_files.$SCRIPT_PID\" \"$source_dir\" \"$dest_dir\" > $RUN_DIR/$PROGRAM.attr-update.$dest_replica.$SCRIPT_PID 2>&1 &"

	fi

	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	eval "$rsync_cmd"
	WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]}
	retval=$?
	if [ $_VERBOSE -eq 1 ] && [ -f "$RUN_DIR/$PROGRAM.attr-update.$dest_replica.$SCRIPT_PID" ]; then
		Logger "List:\n$(cat $RUN_DIR/$PROGRAM.attr-update.$dest_replica.$SCRIPT_PID)" "NOTICE"
	fi

	if [ $retval != 0 ] && [ $retval != 24 ]; then
		Logger "Updating file attributes on $dest_replica [$retval]. Stopping execution." "CRITICAL"
		if [ $_VERBOSE -eq 0 ] && [ -f "$RUN_DIR/$PROGRAM.attr-update.$dest_replica.$SCRIPT_PID" ]; then
			Logger "Rsync output:\n$(cat $RUN_DIR/$PROGRAM.attr-update.$dest_replica.$SCRIPT_PID)" "NOTICE"
		fi
		exit $retval
	else
		Logger "Successfully updated file attributes on $dest_replica replica." "NOTICE"
	fi
}

# sync_update(source replica, destination replica, delete_list_filename)
function sync_update {
	local source_replica="${1}" # Contains replica type of source: initiator, target
	local destination_replica="${2}" # Contains replica type of destination: initiator, target
	local delete_list_filename="${3}" # Contains deleted list filename, will be prefixed with replica type
	__CheckArguments 3 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local rsync_cmd=
	local retval=

	Logger "Updating $destination_replica replica." "NOTICE"
	if [ "$source_replica" == "${INITIATOR[0]}" ]; then
		local source_dir="${INITIATOR[1]}"
		local esc_source_dir=$(EscapeSpaces "${INITIATOR[1]}")
		local dest_dir="${TARGET[1]}"
		local esc_dest_dir=$(EscapeSpaces "${TARGET[1]}")
		local backup_args="$TARGET_BACKUP"
	else
		local source_dir="${TARGET[1]}"
		local esc_source_dir=$(EscapeSpaces "${TARGET[1]}")
		local dest_dir="${INITIATOR[1]}"
		local esc_dest_dir=$(EscapeSpaces "${INITIATOR[1]}")
		local backup_args="$INITIATOR_BACKUP"
	fi

	if [ "$REMOTE_OPERATION" == "yes" ]; then
		CheckConnectivity3rdPartyHosts
		CheckConnectivityRemoteHost
		if [ "$source_replica" == "${INITIATOR[0]}" ]; then
			rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $backup_args --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[1]}${INITIATOR[3]}/$source_replica$delete_list_filename\" --exclude-from=\"${INITIATOR[1]}${INITIATOR[3]}/$destination_replica$delete_list_filename\" \"$source_dir\" $REMOTE_USER@$REMOTE_HOST:\"$esc_dest_dir\" > $RUN_DIR/$PROGRAM.update.$destination_replica.$SCRIPT_PID 2>&1 &"
		else
			rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $backup_args --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[1]}${INITIATOR[3]}/$destination_replica$delete_list_filename\" --exclude-from=\"${INITIATOR[1]}${INITIATOR[3]}/$source_replica$delete_list_filename\" $REMOTE_USER@$REMOTE_HOST:\"$esc_source_dir\" \"$dest_dir\" > $RUN_DIR/$PROGRAM.update.$destination_replica.$SCRIPT_PID 2>&1 &"
		fi
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $RSYNC_DRY_ARG $RSYNC_ATTR_ARGS $RSYNC_TYPE_ARGS $SYNC_OPTS $backup_args --exclude \"$OSYNC_DIR\" $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE --exclude-from=\"${INITIATOR[1]}${INITIATOR[3]}/$source_replica$delete_list_filename\" --exclude-from=\"${INITIATOR[1]}${INITIATOR[3]}/$destination_replica$delete_list_filename\" \"$source_dir\" \"$dest_dir\" > $RUN_DIR/$PROGRAM.update.$destination_replica.$SCRIPT_PID 2>&1 &"
	fi
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	eval "$rsync_cmd"
	WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]}
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
	__CheckArguments 4 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local parentdir=

	## On every run, check wheter the next item is already deleted because it is included in a directory already deleted
	local previous_file=""
	OLD_IFS=$IFS
	IFS=$'\r\n'
	for files in $(cat "${INITIATOR[1]}${INITIATOR[3]}/$deleted_list_file")
	do
		if [[ "$files" != "$previous_file/"* ]] && [ "$files" != "" ]; then
			if [ "$SOFT_DELETE" != "no" ]; then

				if [ $_VERBOSE -eq 1 ]; then
					Logger "Soft deleting $replica_dir$files" "NOTICE"
				fi

				if [ $_DRYRUN -ne 1 ]; then
					if [ ! -d "$replica_dir$deletion_dir" ]; then
						mkdir -p "$replica_dir$deletion_dir"
						if [ $? != 0 ]; then
							Logger "Cannot create replica deletion directory." "ERROR"
						fi
					fi

					if [ -e "$replica_dir$deletion_dir/$files" ]; then
						rm -rf "${replica_dir:?}$deletion_dir/$files"
					fi

					if [ -e "$replica_dir$files" ]; then
						# In order to keep full path on soft deletion, create parent directories before move
						parentdir="$(dirname "$files")"
						if [ "$parentdir" != "." ]; then
							mkdir -p "$replica_dir$deletion_dir/$parentdir"
							mv -f "$replica_dir$files" "$replica_dir$deletion_dir/$parentdir"
						else
							mv -f "$replica_dir$files" "$replica_dir$deletion_dir"
						fi
						if [ $? != 0 ]; then
							Logger "Cannot move $replica_dir$files to deletion directory." "ERROR"
							echo "$files" >> "${INITIATOR[1]}${INITIATOR[3]}/$deleted_failed_list_file"
						fi
					fi
				fi
			else
				if [ $_VERBOSE -eq 1 ]; then
					Logger "Deleting $replica_dir$files" "NOTICE"
				fi

				if [ $_DRYRUN -ne 1 ]; then
					if [ -e "$replica_dir$files" ]; then
						rm -rf "$replica_dir$files"
						if [ $? != 0 ]; then
							Logger "Cannot delete $replica_dir$files" "ERROR"
							echo "$files" >> "${INITIATOR[1]}${INITIATOR[3]}/$deleted_failed_list_file"
						fi
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
	__CheckArguments 4 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local esc_dest_dir=
	local rsync_cmd=

	## This is a special coded function. Need to redelcare local functions on remote host, passing all needed variables as escaped arguments to ssh command.
	## Anything beetween << ENDSSH and ENDSSH will be executed remotely

	# Additionnaly, we need to copy the deletetion list to the remote state folder
	esc_dest_dir="$(EscapeSpaces "${TARGET[1]}${TARGET[3]}")"
	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" \"${INITIATOR[1]}${INITIATOR[3]}/$deleted_list_file\" $REMOTE_USER@$REMOTE_HOST:\"$esc_dest_dir/\" > $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID 2>&1"
	Logger "RSYNC_CMD: $rsync_cmd" "DEBUG"
	eval "$rsync_cmd" 2>> "$LOG_FILE"
	if [ $? != 0 ]; then
		Logger "Cannot copy the deletion list to remote replica." "ERROR"
		if [ -f "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID" ]; then
			Logger "$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.precopy.$SCRIPT_PID)" "ERROR"
		fi
		exit 1
	fi

$SSH_CMD ERROR_ALERT=0 sync_on_changes=$sync_on_changes _SILENT=$_SILENT _DEBUG=$_DEBUG _DRYRUN=$_DRYRUN _VERBOSE=$_VERBOSE COMMAND_SUDO=$COMMAND_SUDO FILE_LIST="$(EscapeSpaces "${TARGET[1]}${TARGET[3]}/$deleted_list_file")" REPLICA_DIR="$(EscapeSpaces "$replica_dir")" SOFT_DELETE=$SOFT_DELETE DELETE_DIR="$(EscapeSpaces "$deletion_dir")" FAILED_DELETE_LIST="$(EscapeSpaces "${TARGET[1]}${TARGET[3]}/$deleted_failed_list_file")" 'bash -s' << 'ENDSSH' > "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID" 2>&1 &

	## The following lines are executed remotely
	function _logger {
		local value="${1}" # What to log
		echo -e "$value" >&2 # Log to STDERR

		if [ $_SILENT -eq 0 ]; then
		echo -e "$value"
		fi
	}

	function Logger {
		local value="${1}" # What to log
		local level="${2}" # Log level: DEBUG, NOTICE, WARN, ERROR, CRITIAL

		local prefix="RTIME: $SECONDS - "

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

	parentdir=

	## On every run, check wheter the next item is already deleted because it is included in a directory already deleted
	previous_file=""
	OLD_IFS=$IFS
	IFS=$'\r\n'
	for files in $(cat "$FILE_LIST")
	do
		Logger "Processing file [$file]." "DEBUG"
		if [[ "$files" != "$previous_file/"* ]] && [ "$files" != "" ]; then

			if [ "$SOFT_DELETE" != "no" ]; then
				if [ $_VERBOSE -eq 1 ]; then
					Logger "Soft deleting $REPLICA_DIR$files" "NOTICE"
				fi

				Logger "Full path for deletion is [$REPLICA_DIR$DELETE_DIR/$files]." "DEBUG"

				if [ ! -d "$REPLICA_DIR$DELETE_DIR" ]; then
					$COMMAND_SUDO mkdir -p "$REPLICA_DIR$DELETE_DIR"
					if [ $? != 0 ]; then
						Logger "Cannot create replica deletion directory." "ERROR"
					fi
				fi

				if [ $_DRYRUN -ne 1 ]; then
					if [ -e "$REPLICA_DIR$DELETE_DIR/$files" ]; then
						$COMMAND_SUDO rm -rf "$REPLICA_DIR$DELETE_DIR/$files"
					fi

					if [ -e "$REPLICA_DIR$files" ]; then
						# In order to keep full path on soft deletion, create parent directories before move
						parentdir="$(dirname "$files")"
						if [ "$parentdir" != "." ]; then
							$COMMAND_SUDO mkdir -p "$REPLICA_DIR$DELETE_DIR/$parentdir"
							$COMMAND_SUDO mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$DELETE_DIR/$parentdir"
						else
							$COMMAND_SUDO mv -f "$REPLICA_DIR$files" "$REPLICA_DIR$DELETE_DIR"
						fi
						if [ $? != 0 ]; then
							Logger "Cannot move $REPLICA_DIR$files to deletion directory." "ERROR"
							echo "$files" >> "$FAILED_DELETE_LIST"
						fi
					fi
				fi
			else
				if [ $_VERBOSE -eq 1 ]; then
					Logger "Deleting $REPLICA_DIR$files" "NOTICE"
				fi

				if [ $_DRYRUN -ne 1 ]; then
					if [ -e "$REPLICA_DIR$files" ]; then
						$COMMAND_SUDO rm -rf "$REPLICA_DIR$files"
						if [ $? != 0 ]; then
							Logger "Cannot delete $REPLICA_DIR$files" "ERROR"
							echo "$files" >> "$FAILED_DELETE_LIST"
						fi
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
	esc_source_file="$(EscapeSpaces "${TARGET[1]}${TARGET[3]}/$deleted_failed_list_file")"
	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -e \"$RSYNC_SSH_CMD\" $REMOTE_USER@$REMOTE_HOST:\"$esc_source_file\" \"${INITIATOR[1]}${INITIATOR[3]}\" > \"$RUN_DIR/$PROGRAM.remote_failed_deletion_list_copy.$SCRIPT_PID\""
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
	__CheckArguments 3 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local replica_dir=
	local delete_dir=

	Logger "Propagating deletions to $replica_type replica." "NOTICE"

	if [ "$replica_type" == "${INITIATOR[0]}" ]; then
		replica_dir="${INITIATOR[1]}"
		delete_dir="${INITIATOR[5]}"

		_delete_local "$replica_dir" "${TARGET[0]}$deleted_list_file" "$delete_dir" "${TARGET[0]}$deleted_failed_list_file" &
		WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]}
		retval=$?
		if [ $retval != 0 ]; then
			Logger "Deletion on replica $replica_type failed." "CRITICAL"
			exit 1
		fi
	else
		replica_dir="${TARGET[1]}"
		delete_dir="${TARGET[5]}"

		if [ "$REMOTE_OPERATION" == "yes" ]; then
			_delete_remote "$replica_dir" "${INITIATOR[0]}$deleted_list_file" "$delete_dir" "${INITIATOR[0]}$deleted_failed_list_file" &
		else
			_delete_local "$replica_dir" "${INITIATOR[0]}$deleted_list_file" "$delete_dir" "${INITIATOR[0]}$deleted_failed_list_file" &
		fi
		WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]}
		retval=$?
		if [ $retval == 0 ]; then
			if [ -f "$RUN_DIR/$PROGRAM._delete_remote.$SCRIPT_PID" ] && [ $_VERBOSE -eq 1 ]; then
				Logger "Remote:\n$(cat $RUN_DIR/$PROGRAM._delete_remote.$SCRIPT_PID)" "DEBUG"
			fi
			return $retval
		else
			Logger "Deletion on remote system failed." "CRITICAL"
			if [ -f "$RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID" ]; then
				Logger "Remote:\n$(cat $RUN_DIR/$PROGRAM.remote_deletion.$SCRIPT_PID)" "CRITICAL"
			fi
			exit 1
		fi
	fi
}

###### Sync function in 6 steps (functions above)
######
###### Step 1: Create current tree list for initiator and target replicas (Steps 1M and 1S)
###### Step 2: Create deleted file list for initiator and target replicas (Steps 2M and 2S)
###### Step 3a: Update initiator and target file attributes only
###### Step 3b: Update initiator and target replicas (Steps 3M and 3S, order depending on conflict prevalence)
###### Step 4: Deleted file propagation to initiator and target replicas (Steps 4M and 4S)
###### Step 5: Create after run tree list for initiator and target replicas (Steps 5M and 5S)

function Sync {
	local resume_count=
	local resume_sync=
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	Logger "Starting synchronization task." "NOTICE"

	if [ -f "${INITIATOR[7]}" ] && [ "$RESUME_SYNC" != "no" ]; then
		resume_sync=$(cat "${INITIATOR[7]}")
		if [ -f "${INITIATOR[8]}" ]; then
			resume_count=$(cat "${INITIATOR[8]}")
		else
			resume_count=0
		fi

		if [ $resume_count -lt $RESUME_TRY ]; then
			if [ "$resume_sync" != "sync.success" ]; then
				Logger "WARNING: Trying to resume aborted osync execution on $($STAT_CMD "${INITIATOR[7]}") at task [$resume_sync]. [$resume_count] previous tries." "WARN"
				echo $(($resume_count+1)) > "${INITIATOR[8]}"
			else
				resume_sync=none
			fi
		else
			Logger "Will not resume aborted osync execution. Too many resume tries [$resume_count]." "WARN"
			echo "noresume" > "${INITIATOR[7]}"
			echo "0" > "${INITIATOR[8]}"
			resume_sync=none
		fi
	else
		resume_sync=none
	fi


	################################################################################################################################################# Actual sync begins here

	## This replaces the case statement because ;& operator is not supported in bash 3.2... Code is more messy than case :(
	if [ "$resume_sync" == "none" ] || [ "$resume_sync" == "noresume" ] || [ "$resume_sync" == "${SYNC_ACTION[0]}.fail" ]; then
		#initiator_tree_current
		tree_list "${INITIATOR[1]}" "${INITIATOR[0]}" "$TREE_CURRENT_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[0]}.success" > "${INITIATOR[7]}"
		else
			echo "${SYNC_ACTION[0]}.fail" > "${INITIATOR[7]}"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[0]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[1]}.fail" ]; then
		#target_tree_current
		tree_list "${TARGET[1]}" "${TARGET[0]}" "$TREE_CURRENT_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[1]}.success" > "${INITIATOR[7]}"
		else
			echo "${SYNC_ACTION[1]}.fail" > "${INITIATOR[7]}"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[1]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[2]}.fail" ]; then
		delete_list "${INITIATOR[0]}" "$TREE_AFTER_FILENAME" "$TREE_CURRENT_FILENAME" "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[2]}.success" > "${INITIATOR[7]}"
		else
			echo "${SYNC_ACTION[2]}.fail" > "${INITIATOR[7]}"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[2]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.fail" ]; then
		delete_list "${TARGET[0]}" "$TREE_AFTER_FILENAME" "$TREE_CURRENT_FILENAME" "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[3]}.success" > "${INITIATOR[7]}"
		else
			echo "${SYNC_ACTION[3]}.fail" > "${INITIATOR[7]}"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.fail" ]; then
		sync_attrs "${INITIATOR[1]}" "$TARGET_SYNC_DIR"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[4]}.success" > "${INITIATOR[7]}"
		else
			echo "${SYNC_ACTION[4]}.fail" > "${INITIATOR[7]}"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.fail" ] || [ "$resume_sync" == "${SYNC_ACTION[6]}.fail" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[6]}.success" ]; then
		if [ "$CONFLICT_PREVALANCE" == "${TARGET[0]}" ]; then
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.fail" ]; then
				sync_update "${TARGET[0]}" "${INITIATOR[0]}" "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[5]}.success" > "${INITIATOR[7]}"
				else
					echo "${SYNC_ACTION[5]}.fail" > "${INITIATOR[7]}"
				fi
				resume_sync="resumed"
			fi
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[6]}.fail" ]; then
				sync_update "${INITIATOR[0]}" "${TARGET[0]}" "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[6]}.success" > "${INITIATOR[7]}"
				else
					echo "${SYNC_ACTION[6]}.fail" > "${INITIATOR[7]}"
				fi
				resume_sync="resumed"
			fi
		else
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[6]}.fail" ]; then
				sync_update "${INITIATOR[0]}" "${TARGET[0]}" "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[6]}.success" > "${INITIATOR[7]}"
				else
					echo "${SYNC_ACTION[6]}.fail" > "${INITIATOR[7]}"
				fi
				resume_sync="resumed"
			fi
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[6]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.fail" ]; then
				sync_update "${TARGET[0]}" "${INITIATOR[0]}" "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]; then
					echo "${SYNC_ACTION[5]}.success" > "${INITIATOR[7]}"
				else
					echo "${SYNC_ACTION[5]}.fail" > "${INITIATOR[7]}"
				fi
				resume_sync="resumed"
			fi
		fi
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[6]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[7]}.fail" ]; then
		deletion_propagation "${TARGET[0]}" "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[7]}.success" > "${INITIATOR[7]}"
		else
			echo "${SYNC_ACTION[7]}.fail" > "${INITIATOR[7]}"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[7]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[8]}.fail" ]; then
		deletion_propagation "${INITIATOR[0]}" "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[8]}.success" > "${INITIATOR[7]}"
		else
			echo "${SYNC_ACTION[8]}.fail" > "${INITIATOR[7]}"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[8]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[9]}.fail" ]; then
		#initiator_tree_after
		tree_list "${INITIATOR[1]}" "${INITIATOR[0]}" "$TREE_AFTER_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[9]}.success" > "${INITIATOR[7]}"
		else
			echo "${SYNC_ACTION[9]}.fail" > "${INITIATOR[7]}"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[9]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[10]}.fail" ]; then
		#target_tree_after
		tree_list "${TARGET[1]}" "${TARGET[0]}" "$TREE_AFTER_FILENAME"
		if [ $? == 0 ]; then
			echo "${SYNC_ACTION[10]}.success" > "${INITIATOR[7]}"
		else
			echo "${SYNC_ACTION[10]}.fail" > "${INITIATOR[7]}"
		fi
		resume_sync="resumed"
	fi

	Logger "Finished synchronization task." "NOTICE"
	echo "${SYNC_ACTION[11]}" > "${INITIATOR[7]}"

	echo "0" > "${INITIATOR[8]}"
}

function _SoftDeleteLocal {
	local replica_type="${1}" # replica type (initiator, target)
	local replica_deletion_path="${2}" # Contains the full path to softdelete / backup directory without ending slash
	local change_time="${3}"
	__CheckArguments 3 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local retval=

	if [ -d "$replica_deletion_path" ]; then
		if [ $_DRYRUN -eq 1 ]; then
			Logger "Listing files older than $change_time days on $replica_type replica. Does not remove anything." "NOTICE"
		else
			Logger "Removing files older than $change_time days on $replica_type replica." "NOTICE"
		fi
			if [ $_VERBOSE -eq 1 ]; then
			# Cannot launch log function from xargs, ugly hack
			$COMMAND_SUDO $FIND_CMD "$replica_deletion_path/" -type f -ctime +$change_time -print0 | xargs -0 -I {} echo "Will delete file {}" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
			$COMMAND_SUDO $FIND_CMD "$replica_deletion_path/" -type d -empty -ctime +$change_time -print0 | xargs -0 -I {} echo "Will delete directory {}" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
		fi
			if [ $_DRYRUN -ne 1 ]; then
			$COMMAND_SUDO $FIND_CMD "$replica_deletion_path/" -type f -ctime +$change_time -print0 | xargs -0 -I {} $COMMAND_SUDO rm -f "{}" && $COMMAND_SUDO $FIND_CMD "$replica_deletion_path/" -type d -empty -ctime +$change_time -print0 | xargs -0 -I {} $COMMAND_SUDO rm -rf "{}" > "$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID" 2>&1 &
		else
			Dummy &
		fi
		WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]}
		retval=$?
		if [ $retval -ne 0 ]; then
			Logger "Error while executing cleanup on $replica_type replica." "ERROR"
			Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
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
	__CheckArguments 3 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local retval=

	CheckConnectivity3rdPartyHosts
	CheckConnectivityRemoteHost

	if [ $_DRYRUN -eq 1 ]; then
		Logger "Listing files older than $change_time days on $replica_type replica. Does not remove anything." "NOTICE"
	else
		Logger "Removing files older than $change_time days on $replica_type replica." "NOTICE"
	fi

	if [ $_VERBOSE -eq 1 ]; then
		# Cannot launch log function from xargs, ugly hack
		cmd=$SSH_CMD' "if [ -d \"'$replica_deletion_path'\" ]; then '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replica_deletion_path'/\" -type f -ctime +'$change_time' -print0 | xargs -0 -I {} echo Will delete file {} && '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replica_deletion_path'/\" -type d -empty -ctime '$change_time' -print0 | xargs -0 -I {} echo Will delete directory {}; else echo \"No remote backup/deletion directory.\"; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'
		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd" &
		WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]}
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	fi

	if [ $_DRYRUN -ne 1 ]; then
		cmd=$SSH_CMD' "if [ -d \"'$replica_deletion_path'\" ]; then '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replica_deletion_path'/\" -type f -ctime +'$change_time' -print0 | xargs -0 -I {} '$COMMAND_SUDO' rm -f \"{}\" && '$COMMAND_SUDO' '$REMOTE_FIND_CMD' \"'$replica_deletion_path'/\" -type d -empty -ctime '$change_time' -print0 | xargs -0 -I {} '$COMMAND_SUDO' rm -rf \"{}\"; else echo \"No remote backup/deletion directory.\"; fi" > "'$RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID'" 2>&1'

		Logger "cmd: $cmd" "DEBUG"
		eval "$cmd" &
	else
		Dummy &
	fi
	WaitForCompletion $! $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME ${FUNCNAME[0]}
	retval=$?
	if [ $retval -ne 0 ]; then
		Logger "Error while executing cleanup on remote $replica_type replica." "ERROR"
		Logger "Command output:\n$(cat $RUN_DIR/$PROGRAM.${FUNCNAME[0]}.$SCRIPT_PID)" "NOTICE"
	else
		Logger "Cleanup complete on $replica_type replica." "NOTICE"
	fi
}

function SoftDelete {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	if [ "$CONFLICT_BACKUP" != "no" ] && [ $CONFLICT_BACKUP_DAYS -ne 0 ]; then
		Logger "Running conflict backup cleanup." "NOTICE"

		_SoftDeleteLocal "${INITIATOR[0]}" "${INITIATOR[1]}${INITIATOR[4]}" $CONFLICT_BACKUP_DAYS
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_SoftDeleteLocal "${TARGET[0]}" "${TARGET[1]}${TARGET[4]}" $CONFLICT_BACKUP_DAYS
		else
			_SoftDeleteRemote "${TARGET[0]}" "${TARGET[1]}${TARGET[4]}" $CONFLICT_BACKUP_DAYS
		fi
	fi

	if [ "$SOFT_DELETE" != "no" ] && [ $SOFT_DELETE_DAYS -ne 0 ]; then
		Logger "Running soft deletion cleanup." "NOTICE"

		_SoftDeleteLocal "${INITIATOR[0]}" "${INITIATOR[1]}${INITIATOR[5]}" $SOFT_DELETE_DAYS
		if [ "$REMOTE_OPERATION" != "yes" ]; then
			_SoftDeleteLocal "${TARGET[0]}" "${TARGET[1]}${TARGET[5]}" $SOFT_DELETE_DAYS
		else
			_SoftDeleteRemote "${TARGET[0]}" "${TARGET[1]}${TARGET[5]}" $SOFT_DELETE_DAYS
		fi
	fi
}

function Init {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	# Set error exit code if a piped command fails
	set -o pipefail
	set -o errtrace

	# Do not use exit and quit traps if osync runs in monitor mode
	if [ $sync_on_changes -eq 0 ]; then
		trap TrapStop SIGINT SIGHUP SIGTERM SIGQUIT
		trap TrapQuit EXIT
	else
		trap TrapQuit SIGTERM EXIT SIGHUP SIGQUIT
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
			SSH_RSA_PRIVATE_KEY=~/.ssh/id_rsa
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
	fi

	## Make sure there is only one trailing slash on path
	INITIATOR_SYNC_DIR="${INITIATOR_SYNC_DIR%/}/"
	TARGET_SYNC_DIR="${TARGET_SYNC_DIR%/}/"

	## Replica format
	## Why the f*** does bash not have simple objects ?

	#${REPLICA[0]}	contains replica type (initiator / target)
	#${REPLICA[1]}	contains full replica path (can be absolute or relative) with ending slash
	#${REPLICA[2]}	contains full lock file path
	#${REPLICA[3]}	contains state dir path, relative to replica path
	#${REPLICA[4]}	contains backup dir path, relative to replica path
	#${REPLICA[5]}	contains deletion dir path, relative to replica path
	#${REPLICA[6]}	contains partial dir path, relative to replica path
	#${REPLICA[7]}  contains full last action file path
	#${REPLICA[8]}  contains full resume count file path

	# Local variables used for state filenames
	local lock_filename="lock"
	local state_dir="state"
	local backup_dir="backup"
	local delete_dir="deleted"
	local partial_dir="_partial"
	local last_action="last-action"
       	local resume_count="resume-count"
	if [ "$_DRYRUN" -eq 1 ]; then
       		local dry_suffix="-dry"
	else
		local dry_suffix=
	fi

	#TODO: integrate this into ${REPLICA[x]}
	TREE_CURRENT_FILENAME="-tree-current-$INSTANCE_ID$dry_suffix"
	TREE_AFTER_FILENAME="-tree-after-$INSTANCE_ID$dry_suffix"
	TREE_AFTER_FILENAME_NO_SUFFIX="-tree-after-$INSTANCE_ID"
	DELETED_LIST_FILENAME="-deleted-list-$INSTANCE_ID$dry_suffix"
	FAILED_DELETE_LIST_FILENAME="-failed-delete-$INSTANCE_ID$dry_suffix"


	INITIATOR=(
	'initiator'
	"$INITIATOR_SYNC_DIR"
	"$INITIATOR_SYNC_DIR$OSYNC_DIR/$lock_filename"
	"$OSYNC_DIR/$state_dir"
	"$OSYNC_DIR/$backup_dir"
	"$OSYNC_DIR/$delete_dir"
	"$OSYNC_DIR/$partial_dir"
	"$INITIATOR_SYNC_DIR$OSYNC_DIR/$state_dir/$last_action-$INSTANCE_ID$dry_suffix"
	"$INITIATOR_SYNC_DIR$OSYNC_DIR/$state_dir/$resume_count-$INSTANCE_ID$dry_suffix"
	)

	TARGET=(
	'target'
	"$TARGET_SYNC_DIR"
	"$TARGET_SYNC_DIR$OSYNC_DIR/$lock_filename"
	"$OSYNC_DIR/$state_dir"
	"$OSYNC_DIR/$backup_dir"
	"$OSYNC_DIR/$delete_dir"
	"$OSYNC_DIR/$partial_dir"
	"$TARGET_SYNC_DIR$OSYNC_DIR/$state_dir/$last_action-$INSTANCE_ID$dry_suffix"
	"$TARGET_SYNC_DIR$OSYNC_DIR/$state_dir/$resume_count-$INSTANCE_ID$dry_suffix"
	)

	PARTIAL_DIR=$OSYNC_DIR"_partial"

	## Set sync only function arguments for rsync
	SYNC_OPTS="-u"

	if [ $_VERBOSE -eq 1 ]; then
		SYNC_OPTS=$SYNC_OPTS" -i"
	fi

	if [ $STATS -eq 1 ]; then
		SYNC_OPTS=$SYNC_OPTS" --stats"
	fi

	## Add Rsync include / exclude patterns
	RsyncPatterns

	## Conflict options
	if [ "$CONFLICT_BACKUP" != "no" ]; then
		INITIATOR_BACKUP="--backup --backup-dir=\"${INITIATOR[4]}\""
		TARGET_BACKUP="--backup --backup-dir=\"${TARGET[4]}\""
		if [ "$CONFLICT_BACKUP_MULTIPLE" == "yes" ]; then
			INITIATOR_BACKUP="$INITIATOR_BACKUP --suffix .$(date +%Y.%m.%d-%H.%M.%S)"
			TARGET_BACKUP="$TARGET_BACKUP --suffix .$(date +%Y.%m.%d-%H.%M.%S)"
		fi
	else
		INITIATOR_BACKUP=""
		TARGET_BACKUP=""
	fi

	## Sync function actions (0-10)
	SYNC_ACTION=(
	'initiator-replica-tree'
	'target-replica-tree'
	'initiator-deleted-list'
	'target-deleted-list'
	'sync-attrs'
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
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	CreateStateDirs
	CheckLocks
	Sync
}

function Usage {
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

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
	__CheckArguments 0 $# ${FUNCNAME[0]} "$@"	#__WITH_PARANOIA_DEBUG

	local cmd=
	local retval=

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
		if [ $retval != 0 ] && [ $retval != 240 ]; then
			Logger "osync child exited with error." "ERROR"
		fi

		Logger "#### Monitoring now." "NOTICE"
		inotifywait --exclude $OSYNC_DIR $RSYNC_PATTERNS $RSYNC_PARTIAL_EXCLUDE -qq -r -e create -e modify -e delete -e move -e attrib --timeout "$MAX_WAIT" "$INITIATOR_SYNC_DIR" &
		#OSYNC_SUB_PID=$! Not used anymore with killchilds func
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
STATS=0
PARTIAL=0
if [ "$CONFLICT_PREVALANCE" == "" ]; then
	CONFLICT_PREVALANCE=initiator
fi
FORCE_UNLOCK=0
no_maxtime=0
opts=""
ERROR_ALERT=0
SOFT_STOP=0
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
		--silent)
		_SILENT=1
		opts=$opts" --silent"
		;;
		--verbose)
		_VERBOSE=1
		opts=$opts" --verbose"
		;;
		--stats)
		STATS=1
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

		if [ "$PATH_SEPARATOR_CHAR" == "" ]; then
			PATH_SEPARATOR_CHAR=";"
		fi

		MIN_WAIT=30
		REMOTE_OPERATION=no
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

	if [ "$IS_STABLE" != "yes" ]; then
                Logger "This is an unstable dev build. Please use with caution." "WARN"
        fi

	GetLocalOS
	InitLocalOSSettings
	CheckEnvironment
	PreInit
	Init
	PostInit
	if [ $_QUICK_SYNC -lt 2 ]; then
		CheckCurrentConfig
	fi

	DATE=$(date)
	Logger "-------------------------------------------------------------" "NOTICE"
	Logger "$DRY_WARNING $DATE - $PROGRAM $PROGRAM_VERSION script begin." "NOTICE"
	Logger "-------------------------------------------------------------" "NOTICE"
	Logger "Sync task [$INSTANCE_ID] launched as $LOCAL_USER@$LOCAL_HOST (PID $SCRIPT_PID)" "NOTICE"

	if [ $sync_on_changes -eq 1 ]; then
		SyncOnChanges
	else
		GetRemoteOS
		InitRemoteOSSettings

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
	fi
