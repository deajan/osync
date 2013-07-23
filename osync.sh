#!/bin/bash

###### Osync - Rsync based two way sync engine with fault tolerance
###### (L) 2013 by Orsiris "Ozy" de Jong (www.netpower.fr) 
OSYNC_VERSION=0.9
OSYNC_BUILD=2307201302

DEBUG=yes
SCRIPT_PID=$$

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

## Default log file until config file is loaded
LOG_FILE=/var/log/osync.log

## Working directory. Will keep current file states, backups and soft deleted files.
OSYNC_DIR=".osync_workdir"

## Log a state message every $KEEP_LOGGING seconds. Should not be equal to soft or hard execution time so your log won't be unnecessary big.
KEEP_LOGGING=1801

#set -o history -o histexpand

function Log
{
        echo -e "TIME: $SECONDS - $1" >> "$LOG_FILE"
        if [ $silent -eq 0 ]
        then
                echo -e "TIME: $SECONDS - $1"
        fi
}

function LogError
{
        Log "$1"
        error_alert=1
}

function LogDebug
{
	if [ "$DEBUG" == "yes" ]
	then
		Log "$1"
	fi
}

function TrapError {
        local JOB="$0"
        local LINE="$1"
        local CODE="${2:-1}"
	local CMD="$3"
        if [ $silent -eq 0 ]
        then
                echo -e " /!\ Error in ${JOB}: Near line ${LINE}, exit code ${CODE}\nCommand $CMD"
        fi
}

function TrapStop
{
	if [ $soft_stop -eq 0 ]
	then
		LogError " /!\ WARNING: Manual exit of osync is really not recommended. Sync will be in inconsistent state."
		LogError " /!\ WARNING: If you are sure, please hit CTRL+C another time to quit."
		soft_stop=1
		return 1
	fi

        if [ $soft_stop -eq 1 ]
        then
        	LogError " /!\ WARNING: CTRL+C hit twice. Quitting osync. Please wait..."
		soft_stop=2
		exit 1
        fi

	if [ $soft_stop -eq 2 ]
	then
		LogError " /!\ WARNING: CTRL+C hit three times. Quitting osync right now without any trap execution."
		soft_stop=3
		exit
	fi
}

function TrapQuit
{
	if [ $soft_stop -eq 3 ]
	then
		exit 1
	fi

	if [ $error_alert -ne 0 ]
	then
        	SendAlert
		UnlockDirectories
		CleanUp
        	LogError "Osync finished with errros."
        	exit 1
	else
		UnlockDirectories
		CleanUp
        	Log "Osync finished."
        	exit 0
	fi
}

function Spinner
{
        if [ $silent -eq 1 ]
        then
                return 1
        fi

        case $toggle
        in
        1)
        echo -n $1" \ "
        echo -ne "\r"
        toggle="2"
        ;;

        2)
        echo -n $1" | "
        echo -ne "\r"
        toggle="3"
        ;;

        3)
        echo -n $1" / "
        echo -ne "\r"
        toggle="4"
        ;;

        *)
        echo -n $1" - "
        echo -ne "\r"
        toggle="1"
        ;;
        esac
}

function EscapeSpaces
{
        echo $(echo $1 | sed 's/ /\\ /g')
}

function CleanUp
{
	if [ "$DEBUG" != "yes" ]
	then
        	rm -f /dev/shm/osync_config_$SCRIPT_PID
 		rm -f /dev/shm/osync_run_local_$SCRIPT_PID
		rm -f /dev/shm/osync_run_remote_$SCRIPT_PID
		rm -f /dev/shm/osync_master-tree-current_$SCRIPT_PID
		rm -f /dev/shm/osync_slave-tree-current_$SCRIPT_PID
		rm -f /dev/shm/osync_master-tree-after_$SCRIPT_PID
		rm -f /dev/shm/osync_slave-tree-after_$SCRIPT_PID
		rm -f /dev/shm/osync_update_master_replica_$SCRIPT_PID
		rm -f /dev/shm/osync_update_slave_replica_$SCRIPT_PID
		rm -f /dev/shm/osync_deletition_on_master_$SCRIPT_PID
		rm -f /dev/shm/osync_deletition_on_slave_$SCRIPT_PID
		rm -f /dev/shm/osync_remote_slave_lock_$SCRIPT_PID
		rm -f /dev/shm/osync_slave_space_$SCRIPT_PIDx
	fi
}

function SendAlert
{
        CheckConnectivityRemoteHost
        CheckConnectivity3rdPartyHosts
        cat "$LOG_FILE" | gzip -9 > /tmp/osync_lastlog.gz
        if type -p mutt > /dev/null 2>&1
        then
                echo $MAIL_ALERT_MSG | $(which mutt) -x -s "Sync alert for $SYNC_ID" $DESTINATION_MAILS -a /tmp/osync_lastlog.gz
                if [ $? != 0 ]
                then
                        Log "WARNING: Cannot send alert email via $(which mutt) !!!"
                else
                        Log "Sent alert mail using mutt."
                fi
        elif type -p mail > /dev/null 2>&1
        then
                echo $MAIL_ALERT_MSG | $(which mail) -a /tmp/osync_lastlog.gz -s "Sync alert for $SYNC_ID" $DESTINATION_MAILS
                if [ $? != 0 ]
                then
                        Log "WARNING: Cannot send alert email via $(which mail) with attachments !!!"
                        echo $MAIL_ALERT_MSG | $(which mail) -s "Sync alert for $SYNC_ID" $DESTINATION_MAILS
                        if [ $? != 0 ]
                        then
                                Log "WARNING: Cannot send alert email via $(which mail) without attachments !!!"
                        else
                                Log "Sent alert mail using mail command without attachment."
                        fi
                else
                        Log "Sent alert mail using mail command."
                fi
        else
                Log "WARNING: Cannot send alert email (no mutt / mail present) !!!"
                return 1
        fi
}

function LoadConfigFile
{
        if [ ! -f "$1" ]
        then
                LogError "Cannot load configuration file [$1]. Sync cannot start."
                return 1
        elif [[ $1 != *.conf ]]
        then
                LogError "Wrong configuration file supplied [$1]. Sync cannot start."
        else
                egrep '^#|^[^ ]*=[^;&]*'  "$1" > "/dev/shm/osync_config_$SCRIPT_PID"
                source "/dev/shm/osync_config_$SCRIPT_PID"
        fi
}

function CheckEnvironment
{
        if [ "$REMOTE_SYNC" == "yes" ]
        then
                if ! type -p ssh > /dev/null 2>&1
                then
                        LogError "ssh not present. Cannot start sync."
                        return 1
                fi
        fi
        if ! type -p rsync > /dev/null 2>&1
        then
                LogError "rsync not present. Sync cannot start."
                return 1
        fi
}

# Waits for pid $1 to complete. Will log an alert if $2 seconds passed since current task execution unless $2 equals 0.
# Will stop task and log alert if $3 seconds passed since current task execution unless $3 equals 0.
function WaitForTaskCompletion
{
        soft_alert=0
        SECONDS_BEGIN=$SECONDS
        while ps -p$1 > /dev/null
        do
                Spinner
                sleep 1
                EXEC_TIME=$(($SECONDS - $SECONDS_BEGIN))
                if [ $(($EXEC_TIME % $KEEP_LOGGING)) -eq 0 ]
                then
                        Log "Current task still running."
                fi
                if [ $EXEC_TIME -gt $2 ]
                then
                        if [ $soft_alert -eq 0 ] && [ $2 != 0 ]
                        then
                                LogError "Max soft execution time exceeded for task."
                                soft_alert=1
                        fi
                        if [ $EXEC_TIME -gt $3 ] && [ $3 != 0 ]
                        then
                                LogError "Max hard execution time exceeded for task. Stopping task execution."
				kill -s SIGTERM $1
				if [ $? == 0 ]
				then
					LogError "Task stopped succesfully"
				else
					LogError "Sending SIGTERM to proces failed. Trying the hard way."
					kill -9 $1
					if [ $? != 0 ]
					then
						LogError "Could not stop task."
					fi
				fi
                                return 1
                        fi
		fi
        done
	wait $child_pid
	return $?
}

# Waits for pid $1 to complete. Will log an alert if $2 seconds passed since script start unless $2 equals 0. 
# Will stop task and log alert if $3 seconds passed since script start unless $3 equals 0.
function WaitForCompletion
{
        soft_alert=0
        while ps -p$1 > /dev/null
        do
                Spinner
                sleep 1
                if [ $(($SECONDS % $KEEP_LOGGING)) -eq 0 ]
                then
                        Log "Current task still running."
                fi
                if [ $SECONDS -gt $2 ]
                then
                        if [ $soft_alert -eq 0 ] && [ $2 != 0 ]
                        then
                                LogError "Max soft execution time exceeded for script."
                                soft_alert=1
                        fi
                        if [ $SECONDS -gt $3 ] && [ $3 != 0 ]
                        then
                                LogError "Max hard execution time exceeded for script. Stopping current task execution."
                                kill -s SIGTERM $1
                                if [ $? == 0 ]
                                then
                                        LogError "Task stopped succesfully"
                                else
					LogError "Sending SIGTERM to proces failed. Trying the hard way."
                                        kill -9 $1
                                        if [ $? != 0 ]
                                        then
                                                LogError "Could not stop task."
                                        fi
                                fi
                                return 1
                        fi
                fi
	done
	wait $child_pid
	return $?
}

## Runs local command $1 and waits for completition in $2 seconds
function RunLocalCommand
{
        CheckConnectivity3rdPartyHosts
        $1 > /dev/shm/osync_run_local_$SCRIPT_PID 2>&1 &
        child_pid=$!
        WaitForTaskCompletion $child_pid 0 $2
        retval=$?
        if [ $retval -eq 0 ]
        then
                Log "Running command [$1] on local host succeded."
        else
                Log "Running command [$1] on local host failed."
        fi

	if [ $verbose -eq 1 ]
	then
        	Log "Command output:\n$(cat /dev/shm/osync_run_local_$SCRIPT_PID)"
	fi
}

## Runs remote command $1 and waits for completition in $2 seconds
function RunRemoteCommand
{
        CheckConnectivity3rdPartyHosts
        if [ "$REMOTE_SYNC" == "yes" ]
        then
                CheckConnectivityRemoteHost
                if [ $? != 0 ]
                then
                        LogError "Connectivity test failed. Cannot run remote command."
                        return 1
                else
                        eval "$SSH_CMD \"$1\" > /dev/shm/osync_run_remote_$SCRIPT_PID 2>&1 &"
                fi
                child_pid=$!
                WaitForTaskCompletion $child_pid 0 $2
                retval=$?
                if [ $retval -eq 0 ]
                then
                        Log "Running command [$1] succeded."
                else
                        LogError "Running command [$1] failed."
                fi

                if [ -f /dev/shm/osync_run_remote_$SCRIPT_PID ] && [ $verbose -eq 1 ]
                then
                        Log "Command output:\n$(cat /dev/shm/osync_run_remote_$SCRIPT_PID)"
                fi
        fi
}

function RunBeforeHook
{
        if [ "$LOCAL_RUN_BEFORE_CMD" != "" ]
        then
                RunLocalCommand "$LOCAL_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE
        fi

        if [ "$REMOTE_RUN_BEFORE_CMD" != "" ]
        then
                RunRemoteCommand "$REMOTE_RUN_BEFORE_CMD" $MAX_EXEC_TIME_PER_CMD_BEFORE
        fi
}

function RunAfterHook
{
        if [ "$LOCAL_RUN_AFTER_CMD" != "" ]
        then
                RunLocalCommand "$LOCAL_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER
        fi

        if [ "$REMOTE_RUN_AFTER_CMD" != "" ]
        then
                RunRemoteCommand "$REMOTE_RUN_AFTER_CMD" $MAX_EXEC_TIME_PER_CMD_AFTER
        fi
}

function CheckConnectivityRemoteHost
{
        if [ "$REMOTE_HOST_PING" != "no" ] && [ "$REMOTE_SYNC" != "no" ]
        then
                ping $REMOTE_HOST -c 2 > /dev/null 2>&1
                if [ $? != 0 ]
                then
                        LogError "Cannot ping $REMOTE_HOST"
                        return 1
                fi
        fi
}

function CheckConnectivity3rdPartyHosts
{
        if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]
        then
                remote_3rd_party_success=0
                for $i in $REMOTE_3RD_PARTY_HOSTS
                do
                        ping $i -c 2 > /dev/null 2>&1
                        if [ $? != 0 ]
                        then
                                LogError "Cannot ping 3rd party host $i"
                        else
                                remote_3rd_party_success=1
                        fi
                done
                if [ $remote_3rd_party_success -ne 1 ]
                then
                        LogError "No remote 3rd party host responded to ping. No internet ?"
                        return 1
                fi
        fi
}

function CreateOsyncDirs
{
	if ! [ -d "$MASTER_STATE_DIR" ]
	then
		mkdir --parents "$MASTER_STATE_DIR"
		if [ $? != 0 ]
		then
			LogError "Cannot create master replica state dir [$MASTER_STATE_DIR]."
			exit 1
		fi
	fi

	if [ "$REMOTE_SYNC" == "yes" ]
	then
		eval "$SSH_CMD \"if ! [ -d \\\"$SLAVE_STATE_DIR\\\" ]; then $COMMAND_SUDO mkdir --parents \\\"$SLAVE_STATE_DIR\\\"; fi\"" &
		WaitForTaskCompletion $! 0 1800
	else
		if ! [ -d "$SLAVE_STATE_DIR" ]; then mkdir --parents "$SLAVE_STATE_DIR"; fi
	fi

	if [ $? != 0 ]
	then
		LogError "Cannot create slave replica state dir [$SLAVE_STATE_DIR]."
		exit 1
	fi
}

function CheckMasterSlaveDirs
{
	if ! [ -d "$MASTER_SYNC_DIR" ]
	then
		if [ "$CREATE_DIRS" == "yes" ]
		then
			mkdir --parents "$MASTER_SYNC_DIR"
			if [ $? != 0 ]
			then
				LogError "Cannot create master directory [$MASTER_SYNC_DIR]."
				exit 1
			else
				Log "Created master directory [$MASTER_SYNC_DIR]."
			fi
		else 
			LogError "Master directory [$MASTER_SYNC_DIR] does not exist."
			exit 1
		fi
	fi

	if [ "$REMOTE_SYNC" == "yes" ]
	then
		if [ "$CREATE_DIRS" == "yes" ]
		then
			eval "$SSH_CMD \"if ! [ -d \\\"$SLAVE_SYNC_DIR\\\" ]; then $COMMAND_SUDO mkdir --parents \\\"$SLAVE_SYNC_DIR\\\"; fi"\" &
			WaitForTaskCompletion $! 0 1800
			if [ $? != 0 ]
			then
				LogError "Cannot create slave directory [$SLAVE_SYNC_DIR]."
				exit 1
			fi
		else
			eval "$SSH_CMD \"if ! [ -d \\\"$SLAVE_SYNC_DIR\\\" ]; then exit 1; fi"\" &	
			WaitForTaskCompletion $! 0 1800
			if [ $? != 0 ]
			then
				LogError "Slave directory [$SLAVE_SYNC_DIR] does not exist."
				exit 1
			fi
		fi
	else
		if [ ! -d "$SLAVE_SYNC_DIR" ]
		then
			if [ "$CREATE_DIRS" == "yes" ]
			then
				mkdir --parents "$SLAVE_SYNC_DIR"
				if [ $? != 0 ]
				then
					LogError "Cannot create slave directory [$SLAVE_SYNC_DIR]."
					exit 1
				else
					Log "Created slave directory [$SLAVE_SYNC_DIR]."
				fi
			else
				LogError "Slave directory [$SLAVE_SYNC_DIR] does not exist."
				exit 1
			fi
		fi
	fi
}

function CheckMinimumSpace
{
	Log "Checking minimum disk space on master and slave."

	MASTER_SPACE=$(df -P "$MASTER_SYNC_DIR" | tail -1 | awk '{print $4}')
        if [ $MASTER_SPACE -lt $MINIMUM_SPACE ]
        then
                LogError "There is not enough free space on master [$MASTER_SPACE KB]."
        fi
	
	if [ "$REMOTE_SYNC" == "yes" ]
	then
		eval "$SSH_CMD \"$COMMAND_SUDO df -P \\\"$SLAVE_SYNC_DIR\\\"\"" > /dev/shm/osync_slave_space_$SCRIPT_PID &
		WaitForTaskCompletion $! 0 1800
		SLAVE_SPACE=$(cat /dev/shm/osync_slave_space_$SCRIPT_PID | tail -1 | awk '{print $4}')
	else
		SLAVE_SPACE=$(df -P "$SLAVE_SYNC_DIR" | tail -1 | awk '{print $4}')
	fi
	
	if [ $SLAVE_SPACE -lt $MINIMUM_SPACE ]
	then
		LogError "There is not enough free space on slave [$SLAVE_SPACE KB]."
	fi
}

function RsyncExcludePattern
{
        OLD_IFS=$IFS
        IFS=$PATH_SEPARATOR_CHAR
        for excludedir in $RSYNC_EXCLUDE_PATTERN
        do
                if [ "$RSYNC_EXCLUDE" == "" ]
                then
                        RSYNC_EXCLUDE="--exclude=\"$excludedir\""
                else
                        RSYNC_EXCLUDE="$RSYNC_EXCLUDE --exclude=\"$excludedir\""
                fi
        done
        IFS=$OLD_IFS
}

function WriteLockFiles
{
        echo $SCRIPT_PID > "$MASTER_STATE_DIR/lock"
        if [ $? != 0 ]
        then
                LogError "Could not set lock on master replica."
                exit 1
	else
		Log "Locked master replica."
        fi

        if [ "$REMOTE_SYNC" == "yes" ]
        then
                eval "$SSH_CMD \"$COMMAND_SUDO echo $SCRIPT_PID@$SYNC_ID > \\\"$SLAVE_STATE_DIR/lock\\\"\"" &
                WaitForTaskCompletion $! 0 1800
                if [ $? != 0 ]
                then
                        LogError "Could not set lock on remote slave replica."
                        exit 1
                else
                        Log "Locked remote slave replica."
                fi
        else
                echo "$SCRIPT_PID@$SYNC_ID" > "$SLAVE_STATE_DIR/lock"
                if [ $? != 0 ]
                then
                        LogError "Couuld not set lock on local slave replica."
                        exit 1
                else
                        Log "Locked local slave replica."
                fi
        fi
}

function LockDirectories
{
	if [ $force_unlock -eq 1 ]
	then
		WriteLockFiles
		if [ $? != 0 ]
		then
			exit 1
		fi
	fi

	Log "Checking for replica locks."

	if [ -f "$MASTER_STATE_DIR/lock" ]
	then
		master_lock_pid=$(cat $MASTER_STATE_DIR/lock)
		LogDebug "Master lock pid: $master_lock_pid"
		ps -p$master_lock_pid > /dev/null
		if [ $? != 0 ]
		then
			Log "There is a dead osync lock on master. Instance $master_lock_pid no longer running. Resuming."
		else
			LogError "There is already a local instance of osync that locks master replica. Cannot start. If your are sure this is an error, plaese kill instance $master_lock_pid of osync."
			exit 1
		fi
	fi
	
	if [ "$REMOTE_SYNC" == "yes" ]
	then
		eval "$SSH_CMD \"if [ -f \\\"$SLAVE_STATE_DIR/lock\\\" ]; then cat \\\"$SLAVE_STATE_DIR/lock\\\"; fi\" > /dev/shm/osync_remote_slave_lock_$SCRIPT_PID" &
		WaitForTaskCompletion $! 0 1800
		if [ -d /dev/shm/osync_remote_slave_lock_$SCRIPT_PID ]
		then
			slave_lock_pid=$(cat /dev/shm/osync_remote_slave_lock_$SCRIPT_PID | cut -d'@' -f1)
			slave_lock_id=$(cat /dev/shm/osync_remote_slave_lock_$SCRIPT_PID | cut -d'@' -f2)
		fi
	else
		if [ -f "$SLAVE_STATE_DIR/lock" ]
		then
			slave_lock_pid=$(cat "$SLAVE_STATE_DIR/lock" | cut -d'@' -f1)
			slave_lock_id=$(cat "$SLAVE_STATE_DIR/lock" | cut -d'@' -f2)
		fi
	fi

	if [ "$slave_lock_pid" != "" ] && [ "$slave_lock_id" != "" ]
	then
		LogDebug "Slave lock pid: $slave_lock_pid"
		LogDebug "Slave lock id: $slave_lock_pid"

		ps -p$slave_lock_pid > /dev/null
		if [ $? != 0 ]
		then
       	        	if [ "$slave_lock_id" == "$SYNC_ID" ]
                	then
                        	Log "There is a dead osync lock on slave replica that corresponds to this master sync-id. Instance $slave_lock_pid no longer running. Resuming."
                	else
                        	if [ "$FORCE_STRANGER_LOCK_RESUME" == "yes" ]
				then
					LogError "WARNING: There is a dead osync lock on slave replica that does not correspond to this master sync-id. Forcing resume."
				else
					LogError "There is a dead osync lock on slave replica that does not correspond to this master sync-id. Will not resume."
                        		exit 1
				fi
                	fi
		else
			LogError "There is already a local instance of osync that locks slave replica. Cannot start. If you are sure this is an error, please kill instance $slave_lock_pid of osync."
			exit 1
		fi
	fi

	WriteLockFiles
}

function UnlockDirectories
{
	if [ "$REMOTE_SYNC" == "yes" ]
	then
		eval "$SSH_CMD \"if [ -f \\\"$SLAVE_STATE_DIR/lock\\\" ]; then $COMMAND_SUDO rm \\\"$SLAVE_STATE_DIR/lock\\\"; fi\"" &
		WaitForTaskCompletion $! 0 1800
	else
		if [ -f "$SLAVE_STATE_DIR/lock" ];then rm "$SLAVE_STATE_DIR/lock"; fi
	fi

	if [ $? != 0 ]
	then
		LogError "Could not unlock slave replica."
	else
		Log "Removed slave replica lock."
	fi

	if [ -f "$MASTER_STATE_DIR/lock" ]
	then
		rm "$MASTER_STATE_DIR/lock"
		if [ $? != 0 ]
		then
			LogError "Could not unlock master replica."
		else
			Log "Removed master replica lock."
		fi
	fi
}

###### Sync core functions

function master_tree_current
{
	Log "Creating master replica file list."
	$(which $RSYNC_EXECUTABLE) --rsync-path="$RSYNC_PATH" -rlptgodE --exclude "$OSYNC_DIR" --list-only "$MASTER_SYNC_DIR/" | grep "^-\|^d" | awk '{print $5}' | (grep -v "^\.$" || :) > /dev/shm/osync_master-tree-current_$SCRIPT_PID &
	child_pid=$!
	WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
	if [ $? == 0 ] && [ -f /dev/shm/osync_master-tree-current_$SCRIPT_PID ]
	then
		mv /dev/shm/osync_master-tree-current_$SCRIPT_PID "$MASTER_STATE_DIR/master-tree-current"
		echo "master-replica-tree.success" > "$MASTER_STATE_DIR/last-action"
	else
		LogError "Cannot create master file list."
		echo "master-replica-tree.fail" > "$MASTER_STATE_DIR/last-action"
		exit 1
	fi
}

function slave_tree_current
{
	Log "Creating slave replica file list."
	if [ "$REMOTE_SYNC" == "yes" ]
	then
		$(which $RSYNC_EXECUTABLE) --rsync-path="$RSYNC_PATH" -rlptgodE --exclude "$OSYNC_DIR" -e "$RSYNC_SSH_CMD" --list-only $REMOTE_USER@$REMOTE_HOST:"$SLAVE_SYNC_DIR/" | grep "^-\|^d" | awk '{print $5}' | (grep -v "^\.$" || :) > /dev/shm/osync_slave-tree-current_$SCRIPT_PID &
	else
		$(which $RSYNC_EXECUTABLE) --rsync-path="$RSYNC_PATH" -rlptgodE --exclude "$OSYNC_DIR" --list-only "$SLAVE_SYNC_DIR/" | grep "^-\|^d" | awk '{print $5}' | (grep -v "^\.$" || :) > /dev/shm/osync_slave-tree-current_$SCRIPT_PID &
	fi
	child_pid=$!
	WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
	retval=$?
	if [ $retval == 0 ] && [ -f /dev/shm/osync_slave-tree-current_$SCRIPT_PID ]
	then
		mv /dev/shm/osync_slave-tree-current_$SCRIPT_PID "$MASTER_STATE_DIR/slave-tree-current"
		echo "slave-replica-tree.-success" > "$MASTER_STATE_DIR/last-action"
	else
		LogError "Cannot create slave file list."
		echo "slave-replica-tree.fail" > "$MASTER_STATE_DIR/last-action"
		exit 1
	fi
}

function master_delete_list
{
	Log "Creating master replica deleted file list."
	if [ -f "$MASTER_STATE_DIR/master-tree-after" ]
	then
		comm --nocheck-order -23 "$MASTER_STATE_DIR/master-tree-after" "$MASTER_STATE_DIR/master-tree-current" > "$MASTER_STATE_DIR/master-deleted-list"
		echo "master-replica-deleted-list.success" > "$MASTER_STATE_DIR/last-action"
	else
		touch "$MASTER_STATE_DIR/master-deleted-list"
		echo "master-replica-deleted-list.empty" > "$MASTER_STATE_DIR/last-action"
	fi
}

function slave_delete_list
{
	Log "Creating slave replica deleted file list."
	if [ -f "$MASTER_STATE_DIR/slave-tree-after" ]
	then
		comm --nocheck-order -23 "$MASTER_STATE_DIR/slave-tree-after" "$MASTER_STATE_DIR/slave-tree-current" > "$MASTER_STATE_DIR/slave-deleted-list"
		echo "slave-replica-deleted-list.success" > "$MASTER_STATE_DIR/last-action"
	else
		touch "$MASTER_STATE_DIR/slave-deleted-list"
		echo "slave-replica-deleted-list.empty" > "$MASTER_STATE_DIR/last-action"
	fi
}

function sync_update_slave
{
        Log "Updating slave replica."
	if [ "$REMOTE_SYNC" == "yes" ]
	then
        	rsync_cmd="$(which $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgodEui -e \"$RSYNC_SSH_CMD\" $SLAVE_BACKUP --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from \"$MASTER_STATE_DIR/master-deleted-list\" --exclude-from \"$MASTER_STATE_DIR/slave-deleted-list\" \"$MASTER_SYNC_DIR/\" $REMOTE_USER@$REMOTE_HOST:\"$SLAVE_SYNC_DIR/\" > /dev/shm/osync_update_slave_replica_$SCRIPT_PID 2>&1 &"
	else
        	rsync_cmd="$(which $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -rlptgodEui $SLAVE_BACKUP --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from \"$MASTER_STATE_DIR/master-deleted-list\" --exclude-from \"$MASTER_STATE_DIR/slave-deleted-list\" \"$MASTER_SYNC_DIR/\" \"$SLAVE_SYNC_DIR/\" > /dev/shm/osync_update_slave_replica_$SCRIPT_PID 2>&1 &"
	fi
	if [ "$DEBUG" == "yes" ]
	then
		Log "RSYNC_CMD: $rsync_cmd"
	fi
	eval $rsync_cmd
        child_pid=$!
        WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
        retval=$?
	if [ $verbose -eq 1 ]
        then
                Log "List:\n$(cat /dev/shm/osync_update_slave_replica_$SCRIPT_PID)"
        fi

        if [ $retval != 0 ]
        then
                LogError "Updating slave replica failed. Stopping execution."
                echo "update-slave-replica.fail" > "$MASTER_STATE_DIR/last-action"
		exit 1
        else
                Log "Updating slave replica succeded."
                echo "update-slave-replica.success" > "$MASTER_STATE_DIR/last-action"
        fi
}

function sync_update_master
{
        Log "Updating master replica."
	if [ "$REMOTE_SYNC" == "yes" ]
	then
        	rsync_cmd="$(which $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgodEui -e \"$RSYNC_SSH_CMD\" $MASTER_BACKUP --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from \"$MASTER_STATE_DIR/slave-deleted-list\" --exclude-from \"$MASTER_STATE_DIR/master-deleted-list\" \"$REMOTE_USER@$REMOTE_HOST:$SLAVE_SYNC_DIR/\" \"$MASTER_SYNC_DIR/\" > /dev/shm/osync_update_master_replica_$SCRIPT_PID 2>&1 &"
	else
	        rsync_cmd="$(which $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgodEui $MASTER_BACKUP --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from \"$MASTER_STATE_DIR/slave-deleted-list\" --exclude-from \"$MASTER_STATE_DIR/master-deleted-list\" \"$SLAVE_SYNC_DIR/\" \"$MASTER_SYNC_DIR/\" > /dev/shm/osync_update_master_replica_$SCRIPT_PID 2>&1 &"
	fi
	if [ "$DEBUG" == "yes" ]
	then
		Log "RSYNC_CMD: $rsync_cmd"
	fi
	eval $rsync_cmd
        child_pid=$!
        WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
        retval=$?
        if [ $verbose -eq 1 ]
        then
                Log "List:\n$(cat /dev/shm/osync_update_master_replica_$SCRIPT_PID)"
        fi

        if [ $retval != 0 ]
        then
                LogError "Updating master replica failed. Stopping execution."
                echo "update-master-replica.fail" > "$MASTER_STATE_DIR/last-action"
		exit 1
        else
                Log "Updating master replica succeded."
                echo "update-master-replica.success" > "$MASTER_STATE_DIR/last-action"
        fi
}

function delete_on_slave
{
	Log "Propagating deletitions to slave replica."
	if [ "$REMOTE_SYNC" == "yes" ]
	then
		rsync_cmd="$(which $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgodEui -e \"$RSYNC_SSH_CMD\" $SLAVE_DELETE --delete --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from \"$MASTER_STATE_DIR/slave-deleted-list\" --include-from \"$MASTER_STATE_DIR/master-deleted-list\" \"$MASTER_SYNC_DIR/\" $REMOTE_USER@$REMOTE_HOST:\"$SLAVE_SYNC_DIR/\" > /dev/shm/osync_deletition_on_slave_$SCRIPT_PID 2>&1 &"
	else
		rsync_cmd="$(which $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgodEui $SLAVE_DELETE --delete --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from \"$MASTER_STATE_DIR/slave-deleted-list\" --include-from \"$MASTER_STATE_DIR/master-deleted-list\" \"$MASTER_SYNC_DIR/\" \"$SLAVE_SYNC_DIR/\" > /dev/shm/osync_deletition_on_slave_$SCRIPT_PID 2>&1 &"
	fi
	if [ "$DEBUG" == "yes" ]
	then
		Log "RSYNC_CMD: $rsync_cmd"
	fi
	eval $rsync_cmd
	child_pid=$!
	WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
	retval=$?
        if [ $verbose -eq 1 ]
        then
                Log "List:\n$(cat /dev/shm/osync_deletition_on_slave_$SCRIPT_PID)"
        fi

	if [ $retval != 0 ]
	then
		LogError "Deletition on slave failed."
		echo "delete-propagation-slave.fail" > "$MASTER_STATE_DIR/last-action"
		exit 1
	else
		echo "delete-propagation-slave.success" > "$MASTER_STATE_DIR/last-action"
	fi
}

function delete_on_master
{	
	Log "Propagating deletitions to master replica."
	if [ "$REMOTE_SYNC" == "yes" ]
	then
		rsync_cmd="$(which $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgodEui -e \"$RSYNC_SSH_CMD\" $MASTER_DELETE --delete --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from \"$MASTER_STATE_DIR/master-deleted-list\" --include-from \"$MASTER_STATE_DIR/slave-deleted-list\" $REMOTE_USER@$REMOTE_HOST:\"$SLAVE_SYNC_DIR/\" \"$MASTER_SYNC_DIR/\" > /dev/shm/osync_deletition_on_master_$SCRIPT_PID 2>&1 &"
	else
		rsync_cmd="$(which $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgodEui $MASTER_DELETE --delete --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from \"$MASTER_STATE_DIR/master-deleted-list\" --include-from \"$MASTER_STATE_DIR/slave-deleted-list\" \"$SLAVE_SYNC_DIR/\" \"$MASTER_SYNC_DIR/\" > /dev/shm/osync_deletition_on_master_$SCRIPT_PID 2>&1 &"
	fi
	if [ "$DEBUG" == "yes" ]
	then
		Log "RSYNC_CMD: $rsync_cmd"
	fi
	eval $rsync_cmd
	child_pid=$!
	WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
	retval=$?
        if [ $verbose -eq 1 ]
        then
                Log "List:\n$(cat /dev/shm/osync_deletition_on_master_$SCRIPT_PID)"
        fi

	if [ $retval != 0 ]
	then
		LogError "Deletition on master failed."
		echo "delete-propagation-master.fail" > "$MASTER_STATE_DIR/last-action"
		exit 1
	else
		echo "delete-propagation-master.success" > "$MASTER_STATE_DIR/last-action"
	fi
}

function master_tree_after
{
        Log "Creating after run master replica file list."
        $(which $RSYNC_EXECUTABLE) --rsync-path="$RSYNC_PATH" -rlptgodE --exclude "$OSYNC_DIR" --list-only "$MASTER_SYNC_DIR/" | grep "^-\|^d" | awk '{print $5}' | (grep -v "^\.$" || :)> /dev/shm/osync_master-tree-after_$SCRIPT_PID &
	child_pid=$!
        WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
        retval=$?
        if [ $retval == 0 ] && [ -f /dev/shm/osync_master-tree-after_$SCRIPT_PID ]
        then
                mv /dev/shm/osync_master-tree-after_$SCRIPT_PID "$MASTER_STATE_DIR/master-tree-after"
		echo "master-replica-tree-after.success" > "$MASTER_STATE_DIR/last-action"
        else
                LogError "Cannot create slave file list."
		echo "master-replica-tree-after.fail" > "$MASTER_STATE_DIR/last-action"
                exit 1
        fi
}

function slave_tree_after
{
        Log "Creating after run slave replica file list."
	if [ "$REMOTE_SYNC" == "yes" ]
	then
	        $(which $RSYNC_EXECUTABLE) --rsync-path="$RSYNC_PATH" -rlptgodE -e "$RSYNC_SSH_CMD" --exclude "$OSYNC_DIR" --list-only "$REMOTE_USER@$REMOTE_HOST:$SLAVE_SYNC_DIR/" | grep "^-\|^d" | awk '{print $5}' | (grep -v "^\.$" || :) > /dev/shm/osync_slave-tree-after_$SCRIPT_PID &
	else
	        $(which $RSYNC_EXECUTABLE) --rsync-path="$RSYNC_PATH" -rlptgodE --exclude "$OSYNC_DIR" --list-only "$SLAVE_SYNC_DIR/" | grep "^-\|^d" | awk '{print $5}' | (grep -v "^\.$" || :) > /dev/shm/osync_slave-tree-after_$SCRIPT_PID &
	fi
	child_pid=$!
        WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
        retval=$?
        if [ $retval == 0 ] && [ -f /dev/shm/osync_slave-tree-after_$SCRIPT_PID ]
        then
                mv /dev/shm/osync_slave-tree-after_$SCRIPT_PID "$MASTER_STATE_DIR/slave-tree-after"
		echo "slave-replica-tree-after.success" > "$MASTER_STATE_DIR/last-action"
        else
                LogError "Cannot create slave file list."
		echo "slave-replica-tree-after.fail" > "$MASTER_STATE_DIR/last-action"
                exit 1
        fi
}

###### Sync function in 10 steps (functions above)
function Sync
{
        Log "Starting synchronization task."

	if [ -f "$MASTER_STATE_DIR/last-action" ] && [ "$RESUME_SYNC" == "yes" ]
	then
		resume_sync=$(cat "$MASTER_STATE_DIR/last-action")
		if [ -f "$MASTER_STATE_DIR/resume-count" ]
		then
			resume_count=$(cat "$MASTER_STATE_DIR/resume-count")
		else
			resume_count=0
		fi

		if [ $resume_count -lt $RESUME_TRY ]
		then
			if [ "$resume_sync" != "sync.success" ]
			then
				Log "WARNING: Trying to resume aborted osync execution on $(stat --format %y "$MASTER_STATE_DIR/last-action") at task [$resume_sync]. Try=$resume_count"
				echo $(($resume_count+1)) > "$MASTER_STATE_DIR/resume-count"
			else
				resume_sync=none
			fi
		else
			Log "Will not resume aborted osync execution. Too much resume tries [$resume_count]."
			echo "noresume" > "$MASTER_STATE_DIR/last-action"
			echo "0" > "$MASTER_STATE_DIR/resume-count"
			resume_sync=none
		fi
	else
		resume_sync=none
	fi

	## In this case statement, ;& means executing every command below regardless of conditions
	case $resume_sync in
		none|noresume)
		;&
		master-replica-tree.fail)
		master_tree_current
		;&
		master-replica-tree.success|slave-replica-tree.fail)
		slave_tree_current
		;&
		slave-replica-tree.success|master-replica-deleted-list.fail)
		master_delete_list
		;&
		master-replica-deleted-list.success|slave-replica-deleted-list.fail)
		slave_delete_list
		;&
		slave-replica-deleted-list.success|update-master-replica.fail|update-slave-replica.fail)
	        if [ "$CONFLICT_PREVALANCE" != "master" ]
	        then
        	        case $resume_sync in
				none)
				;&
				slave-replica-deleted-list.success|update-master-replica.fail)
				sync_update_master
				;&
				update-master-replica.success|update-slave-replica.fail)
				sync_update_master
				;;
			esac
        	else
                	case $resume_sync in
				none)
				;&
				slave-replica-deleted-list.success|update-slave-replica.fail)
				sync_update_slave
				;&
				update-slave-replica.success|update-master-replica.fail)
	                	sync_update_master
				;;
			esac
        	fi
		;&
		update-slave-replica.success|update-master-replica.success|delete-propagation-slave.fail)
		delete_on_slave
		;&
		delete-propagation-slave.success|delete-propagation-master.fail)
		delete_on_master
		;&
		delete-propagation-master.success|master-replica-tree-after.fail)
		master_tree_after
		;&
		master-replica-tree-after.success|slave-replica-tree-after.fail)
		slave_tree_after
		;;
	esac

	Log "Finished synchronization task."
	echo "sync.success" > "$MASTER_STATE_DIR/last-action"
	echo "0" > "$MASTER_STATE_DIR/resume-count"
}

function SoftDelete
{
	if [ "$CONFLICT_BACKUP" != "no" ]
	then
		if [ -d "$MASTER_BACKUP_DIR" ]
		then
			Log "Removing backups older than $CONFLICT_BACKUP_DAYS days on master replica."
			find "$MASTER_BACKUP_DIR/" -ctime +$CONFLICT_BACKUP_DAYS | xargs rm -rf
		fi
		
		if [ "$REMOTE_SYNC" == "yes" ]
		then
			Log "Removing backups older than $CONFLICT_BACKUP_DAYS days on remote slave replica."
			eval "$SSH_CMD \"if [ -d \\\"$SLAVE_BACKUP_DIR\\\" ]; then $COMMAND_SUDO find \\\"$SLAVE_BACKUP_DIR/\\\" -ctime +$CONFLICT_BACKUP_DAYS | xargs rm -rf; fi\""
		else
			if [ -d "$SLAVE_BACKUP_DIR" ]
			then
				Log "Removing backups older than $CONFLICT_BACKUP_DAYS days on slave replica."
				find "$SLAVE_BACKUP_DIR/" -ctime +$CONFLICT_BACKUP_DAYS | xargs rm -rf	
			fi
		fi
	fi

	if [ "$SOFT_DELETE" != "no" ]
	then
		if [ -d "$MASTER_DELETE_DIR" ]
		then
			Log "Removing soft deleted items older than $SOFT_DELETE_DAYS days on master replica."
			find "$MASTER_DELETE_DIR/" -ctime +$SOFT_DELETE_DAYS | xargs rm -rf
		fi

		if [ "$REMOTE_SYNC" == "yes" ]
		then
			Log "Removing soft deleted items older than $SOFT_DELETE_DAYS days on remote slave replica."
			eval "$SSH_CMD \"if [ -d \\\"$SLAVE_DELETE_DIR\\\" ]; then $COMMAND_SUDO find \\\"$SLAVE_DELETE_DIR/\\\" -ctime +$SOFT_DELETE_DAYS | xargs rm -rf; fi\""
		else
			if [ -d "$SLAVE_DELETE_DIR" ]
			then
				Log "Removing soft deleted items older than $SOFT_DELETE_DAYS days on slave replica."
				find "$SLAVE_DELETE_DIR/" -ctime +$SOFT_DELETE_DAYS | xargs rm -rf
			fi
		fi
	fi
}

function Init
{
        # Set error exit code if a piped command fails
        set -o pipefail
        set -o errtrace

        trap TrapStop SIGINT SIGKILL SIGHUP SIGTERM SIGQUIT
	trap TrapQuit EXIT
        if [ "$DEBUG" == "yes" ]
        then
		set -o history -o histexpand
                trap 'TrapError ${LINENO} $? !!' ERR
        fi

        LOG_FILE=/var/log/osync_$OSYNC_VERSION-$SYNC_ID.log
        MAIL_ALERT_MSG="Warning: Execution of osync instance $OSYNC_ID (pid $SCRIPT_PID) as $LOCAL_USER@$LOCAL_HOST produced errors."

	MASTER_STATE_DIR="$MASTER_SYNC_DIR/$OSYNC_DIR/state"
	SLAVE_STATE_DIR="$SLAVE_SYNC_DIR/$OSYNC_DIR/state"

	## Working directories to keep backups of updated / deleted files
	MASTER_BACKUP_DIR="$MASTER_SYNC_DIR/$OSYNC_DIR/backups"
	MASTER_DELETE_DIR="$MASTER_SYNC_DIR/$OSYNC_DIR/deleted"
	SLAVE_BACKUP_DIR="$SLAVE_SYNC_DIR/$OSYNC_DIR/backups"
	SLAVE_DELETE_DIR="$SLAVE_SYNC_DIR/$OSYNC_DIR/deleted"
	
	## SSH compression
	if [ "$SSH_COMPRESSION" == "yes" ]
	then
		SSH_COMP=-C
	else
		SSH_COMP=
	fi

	## Define which runner (local bash or distant ssh) to use for standard commands and rsync commands
	if [ "$REMOTE_SYNC" == "yes" ]
	then
		SSH_CMD="$(which ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
		RSYNC_SSH_CMD="$(which ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY -p $REMOTE_PORT"
	fi

        ## Set rsync executable and rsync path (for remote sudo rsync)
        if [ "$RSYNC_EXECUTABLE" == "" ]
        then
                RSYNC_EXECUTABLE=rsync
        fi

        if [ "$SUDO_EXEC" == "yes" ]
        then
                RSYNC_PATH="sudo $(which $RSYNC_EXECUTABLE)"
                COMMAND_SUDO="sudo"
        else
                RSYNC_PATH="$(which $RSYNC_EXECUTABLE)"
                COMMAND_SUDO=""
        fi


	## Set rsync options
	RSYNC_ARGS="-"
        if [ "$PRESERVE_ACLS" == "yes" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS"A"
        fi
        if [ "$PRESERVE_XATTR" == "yes" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS"X"
        fi
        if [ "$RSYNC_COMPRESS" == "yes" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS"z"
        fi
	if [ $dryrun -eq 1 ]
	then
		RSYNC_ARGS=$RSYNC_ARGS"n"
		DRY_WARNING="/!\ DRY RUN"
	fi
	if [ "$RSYNC_ARGS" == "-" ]
	then
		RSYNC_ARGS=""
	fi

	## Conflict options
	if [ "$CONFLICT_BACKUP" != "no" ]
	then
		MASTER_BACKUP="--backup --backup-dir=\"$MASTER_BACKUP_DIR\""
		SLAVE_BACKUP="--backup --backup-dir=\"$SLAVE_BACKUP_DIR\""
       		if [ "$CONFLICT_BACKUP_MULTIPLE" == "yes" ]
        	then
                	MASTER_BACKUP="$MASTER_BACKUP --suffix .$(date +%Y.%m.%d-%H.%M.%S)"
                	SLAVE_BACKUP="$SLAVE_BACKUP --suffix .$(date +%Y.%m.%d-%H.%M.%S)"
        	fi
	else
		MASTER_BACKUP=
		SLAVE_BACKUP=
	fi

	## Soft delete options
	if [ "$SOFT_DELETE" != "no" ]
	then
		MASTER_DELETE="--backup --backup-dir=\"$MASTER_DELETE_DIR\""
		SLAVE_DELETE="--backup --backup-dir=\"$SLAVE_DELETE_DIR\""
	else
		MASTER_DELETE=
		SLAVE_DELETE=
	fi

	## Add Rsync exclude patterns
	RsyncExcludePattern
}

function Main
{
	CreateOsyncDirs
	LockDirectories
	Sync
}

function Usage
{
	echo "Osync $OSYNC_VERSION $OSYNC_BUILD"
	echo ""
	echo "usage: osync /path/to/conf.file [--dry] [--silent] [--verbose] [--force-unlock]"
	echo ""
	echo "--dry: will run osync without actuallyv doing anything; just testing"
	echo "--silent: will run osync without any output to stdout, usefull for cron jobs"
	echo "--verbose: adds command outputs"
	ecoh "--force-unlock: will override any existing active or dead locks on master and slave replica"
	exit 128
}

# Comand line argument flags
dryrun=0
silent=0
force_unlock=0
if [ "$DEBUG" == "yes" ]
then
	verbose=1
else
	verbose=0
fi
# Alert flags
soft_alert_total=0
error_alert=0
soft_stop=0

if [ $# -eq 0 ]
then
	Usage
	exit
fi

for i in "$@"
do
	case $i in
		--dry)
		dryrun=1
		;;
		--silent)
		silent=1
		;;
		--verbose)
		verbose=1
		;;
		--force-unlock)
		force_unlock=1
		;;
		--help|-h|--version|-v)
		Usage
		;;
	esac
done

CheckEnvironment
if [ $? == 0 ]
then
	if [ "$1" != "" ]
	then
		LoadConfigFile $1
		if [ $? == 0 ]
		then
			Init
			DATE=$(date)
			Log "-------------------------------------------------------------"
			Log " $DRY_WARNING $DATE - Osync v$OSYNC_VERSION script begin."
			Log "-------------------------------------------------------------"
			CheckMasterSlaveDirs
			CheckMinimumSpace
			if [ $? == 0 ]
			then
				RunBeforeHook
				Main
				if [ $? == 0 ]
				then
					SoftDelete
				fi
				RunAfterHook
			fi
		else
			LogError "Configuration file could not be loaded."
			exit 1
		fi
	else
		LogError "No configuration file provided."
		exit 1
	fi
else
	LogError "Environment not suitable to run osync."
fi
