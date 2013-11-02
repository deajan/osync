#!/bin/bash

###### Osync - Rsync based two way sync engine with fault tolerance
###### (L) 2013 by Orsiris "Ozy" de Jong (www.netpower.fr) 
OSYNC_VERSION=0.99RC2
OSYNC_BUILD=0211201302

DEBUG=no
SCRIPT_PID=$$

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

## Default log file until config file is loaded
if [ -w /var/log ]
then
	LOG_FILE=/var/log/osync.log
else
	LOG_FILE=./osync.log
fi

## Default directory where to store run files
if [ -w /dev/shm ]
then
	RUN_DIR=/dev/shm
elif [ -w /tmp ]
then
	RUN_DIR=/tmp
elif [ -w /var/tmp ]
then
	RUN_DIR=/var/tmp
else
	RUN_DIR=.
fi

## Working directory. Will keep current file states, backups and soft deleted files.
OSYNC_DIR=".osync_workdir"

## Log a state message every $KEEP_LOGGING seconds. Should not be equal to soft or hard execution time so your log won't be unnecessary big.
KEEP_LOGGING=1801

## Correct output of sort command (language agnostic sorting)
export LC_ALL=C

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
        if [ $silent -eq 0 ]
        then
                echo -e " /!\ ERROR in ${JOB}: Near line ${LINE}, exit code ${CODE}"
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
}

function TrapQuit
{
	## Stopping all running child processes
	if type -p pkill > /dev/null 2>&1
	then
		pkill -TERM -P $$
	elif [ "$LOCAL_OS" == "msys" ] || [ "$OSTYPE" == "msys" ]
	then
		## This is not really a clean way to get child process pids, especially the tail -n +2 which resolves a strange char apparition in msys bash
		for pid in $(ps -a | awk '{$1=$1}$1' | awk '{print $1" "$2}' | grep " $$$" | awk '{print $1}' | tail -n +2)
		do
			kill -9 $pid > /dev/null 2>&1
		done
	else
		for pid in $(ps -a --Group $$)
		do
			kill -9 $pid
		done
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
        echo $(echo "$1" | sed 's/ /\\ /g')
}

function CleanUp
{
	if [ "$DEBUG" != "yes" ]
	then
        	rm -f $RUN_DIR/osync_config_$SCRIPT_PID
		rm -f $RUN_DIR/osync_remote_os_$SCRIPT_PID
 		rm -f $RUN_DIR/osync_run_local_$SCRIPT_PID
		rm -f $RUN_DIR/osync_run_remote_$SCRIPT_PID
		rm -f $RUN_DIR/osync_master-tree-current_$SCRIPT_PID
		rm -f $RUN_DIR/osync_slave-tree-current_$SCRIPT_PID
		rm -f $RUN_DIR/osync_master-tree-after_$SCRIPT_PID
		rm -f $RUN_DIR/osync_slave-tree-after_$SCRIPT_PID
		rm -f $RUN_DIR/osync_update_master_replica_$SCRIPT_PID
		rm -f $RUN_DIR/osync_update_slave_replica_$SCRIPT_PID
		rm -f $RUN_DIR/osync_deletion_on_master_$SCRIPT_PID
		rm -f $RUN_DIR/osync_deletion_on_slave_$SCRIPT_PID
		rm -f $RUN_DIR/osync_remote_slave_lock_$SCRIPT_PID
		rm -f $RUN_DIR/osync_slave_space_$SCRIPT_PID
	fi
}

function SendAlert
{
        cat "$LOG_FILE" | gzip -9 > /tmp/osync_lastlog.gz
        if type -p mutt > /dev/null 2>&1
        then
                echo $MAIL_ALERT_MSG | $(type -p mutt) -x -s "Sync alert for $SYNC_ID" $DESTINATION_MAILS -a /tmp/osync_lastlog.gz
                if [ $? != 0 ]
                then
                        Log "WARNING: Cannot send alert email via $(type -p mutt) !!!"
                else
                        Log "Sent alert mail using mutt."
                fi
        elif type -p mail > /dev/null 2>&1
        then
                echo $MAIL_ALERT_MSG | $(type -p mail) -a /tmp/osync_lastlog.gz -s "Sync alert for $SYNC_ID" $DESTINATION_MAILS
                if [ $? != 0 ]
                then
                        Log "WARNING: Cannot send alert email via $(type -p mail) with attachments !!!"
                        echo $MAIL_ALERT_MSG | $(type -p mail) -s "Sync alert for $SYNC_ID" $DESTINATION_MAILS
                        if [ $? != 0 ]
                        then
                                Log "WARNING: Cannot send alert email via $(type -p mail) without attachments !!!"
                        else
                                Log "Sent alert mail using mail command without attachment."
                        fi
                else
                        Log "Sent alert mail using mail command."
                fi
	elif type -p sendemail > /dev/null 2>&1
	then
		$(type -p sendemail) -f $SENDER_MAIL -t $DESTINATION_MAILS -u "Backup alert for $BACKUP_ID" -m "$MAIL_ALERT_MSG" -s $SMTP_SERVER -o username $SMTP_USER -p password $SMTP_PASSWORD > /dev/null 2>&1
		if [ $? != 0 ]
		then
			Log "WARNING: Cannot send alert email via $(type -p sendemail) !!!"
		else
			Log "Sent alert mail using sendemail command without attachment."
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
        elif [[ "$1" != *".conf" ]]
        then
                LogError "Wrong configuration file supplied [$1]. Sync cannot start."
		return 1
        else
                egrep '^#|^[^ ]*=[^;&]*'  "$1" > "$RUN_DIR/osync_config_$SCRIPT_PID"
                source "$RUN_DIR/osync_config_$SCRIPT_PID"
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

function GetOperatingSystem
{
	LOCAL_OS_VAR=$(uname -spio)
	if [ "$REMOTE_SYNC" == "yes" ]
	then
		eval "$SSH_CMD \"uname -spio\" > $RUN_DIR/osync_remote_os_$SCRIPT_PID 2>&1"
		 if [ $? != 0 ]
                then
                        LogError "Cannot Get remote OS type."
                else
                        REMOTE_OS_VAR=$(cat $RUN_DIR/osync_remote_os_$SCRIPT_PID)
                fi
	fi

	case $LOCAL_OS_VAR in
		"Linux"*)
		LOCAL_OS="Linux"
		;;
		"FreeBSD"*)
		LOCAL_OS="FreeBSD"
		;;
		"MINGW32"*)
		LOCAL_OS="msys"
		;;
		*)
		LogError "Running on >> $LOCAL_OS_VAR << not supported. Please report to the author."
		exit 1
		;;
	esac

	case $REMOTE_OS_VAR in
		"Linux"*)
		REMOTE_OS="Linux"
		;;
		"FreeBSD"*)
		REMOTE_OS="FreeBSD"
		;;
		"MINGW32"*)
		REMOTE_OS="msys"
		;;
		"")
		;;
		*)
		LogError "Running on remote >> $REMOTE_OS_VAR << not supported. Please report to the author."
		exit 1
	esac

        if [ "$DEBUG" == "yes" ]
        then
                Log "Local OS: [$LOCAL_OS_VAR]."
                if [ "$REMOTE_BACKUP" == "yes" ]
                then
                        Log "Remote OS: [$REMOTE_OS_VAR]."
                fi
        fi
}

# Waits for pid $1 to complete. Will log an alert if $2 seconds passed since current task execution unless $2 equals 0.
# Will stop task and log alert if $3 seconds passed since current task execution unless $3 equals 0.
function WaitForTaskCompletion
{
        soft_alert=0
        SECONDS_BEGIN=$SECONDS
	if [ "$LOCAL_OS" == "msys" ]
	then
		PROCESS_TEST="ps -a | awk '{\$1=\$1}\$1' | awk '{print \$1}' | grep $1"
	else
		PROCESS_TEST="ps -p$1"
	fi
	while eval $PROCESS_TEST > /dev/null
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
	if [ "$LOCAL_OS" == "msys" ]
	then
		PROCESS_TEST="ps -a | awk '{\$1=\$1}\$1' | awk '{print \$1}' | grep $1"
	else
		PROCESS_TEST="ps -p$1"
	fi
	while eval $PROCESS_TEST > /dev/null
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
        if [ $dryrun -ne 0 ]
        then
                Log "Dryrun: Local command [$1] not run."
                return 1
        fi
	Log "Running command [$1] on local host."
        eval "$1" > $RUN_DIR/osync_run_local_$SCRIPT_PID 2>&1 &
        child_pid=$!
        WaitForTaskCompletion $child_pid 0 $2
        retval=$?
        if [ $retval -eq 0 ]
        then
                Log "Command succeded."
        else
                LogError "Command failed."
        fi

	if [ $verbose -eq 1 ]
	then
        	Log "Command output:\n$(cat $RUN_DIR/osync_run_local_$SCRIPT_PID)"
	fi
	
        if [ "$STOP_ON_CMD_ERROR" == "yes" ] && [ $retval -ne 0 ]
        then
                exit 1
        fi
}

## Runs remote command $1 and waits for completition in $2 seconds
function RunRemoteCommand
{
        CheckConnectivity3rdPartyHosts
        CheckConnectivityRemoteHost
        if [ $dryrun -ne 0 ]
        then
                Log "Dryrun: Local command [$1] not run."
                return 1
        fi
	Log "Running command [$1] on remote host."
        eval "$SSH_CMD \"$1\" > $RUN_DIR/osync_run_remote_$SCRIPT_PID 2>&1 &"
        child_pid=$!
        WaitForTaskCompletion $child_pid 0 $2
        retval=$?
        if [ $retval -eq 0 ]
        then
                Log "Command succeded."
        else
                LogError "Command failed."
        fi

        if [ -f $RUN_DIR/osync_run_remote_$SCRIPT_PID ] && [ $verbose -eq 1 ]
        then
                Log "Command output:\n$(cat $RUN_DIR/osync_run_remote_$SCRIPT_PID)"
        fi

        if [ "$STOP_ON_CMD_ERROR" == "yes" ] && [ $retval -ne 0 ]
        then
                exit 1
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
		if [ "$LOCAL_OS" == "msys" ]
		then
			ping -n 2 $REMOTE_HOST > /dev/null 2>&1
		else
			ping -c 2 $REMOTE_HOST > /dev/null 2>&1
		fi
                if [ $? != 0 ]
                then
                        LogError "Cannot ping $REMOTE_HOST"
                        exit 1
		fi
	fi
}

function CheckConnectivity3rdPartyHosts
{
        if [ "$REMOTE_3RD_PARTY_HOSTS" != "" ]
        then
                remote_3rd_party_success=0
                OLD_IFS=$IFS
                IFS=$' \t\n'
                for i in $REMOTE_3RD_PARTY_HOSTS
                do
			if [ "$LOCAL_OS" == "msys" ]
			then
				ping -n 2 $i > /dev/null 2>&1
			else
				ping -c 2 $i > /dev/null 2>&1
			fi
                        if [ $? != 0 ]
                        then
                                Log "Cannot ping 3rd party host $i"
                        else
                                remote_3rd_party_success=1
                        fi
                done
                IFS=$OLD_IFS
                if [ $remote_3rd_party_success -ne 1 ]
                then
                        LogError "No remote 3rd party host responded to ping. No internet ?"
                        exit 1
		fi
        fi
}

function CreateOsyncDirs
{
	if ! [ -d "$MASTER_STATE_DIR" ]
	then
		mkdir -p "$MASTER_STATE_DIR"
		if [ $? != 0 ]
		then
			LogError "Cannot create master replica state dir [$MASTER_STATE_DIR]."
			exit 1
		fi
	fi

	if [ "$REMOTE_SYNC" == "yes" ]
	then
		CheckConnectivity3rdPartyHosts
        	CheckConnectivityRemoteHost
		eval "$SSH_CMD \"if ! [ -d \\\"$SLAVE_STATE_DIR\\\" ]; then $COMMAND_SUDO mkdir -p \\\"$SLAVE_STATE_DIR\\\"; fi\"" &
		child_pid=$!
		WaitForTaskCompletion $child_pid 0 1800
	else
		if ! [ -d "$SLAVE_STATE_DIR" ]; then mkdir -p "$SLAVE_STATE_DIR"; fi
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
			mkdir -p "$MASTER_SYNC_DIR"
			if [ $? != 0 ]
			then
				LogError "Cannot create master directory [$MASTER_SYNC_DIR]."
				exit 1
			fi
		else 
			LogError "Master directory [$MASTER_SYNC_DIR] does not exist."
			exit 1
		fi
	fi

	if [ "$REMOTE_SYNC" == "yes" ]
	then
		CheckConnectivity3rdPartyHosts
        	CheckConnectivityRemoteHost
		if [ "$CREATE_DIRS" == "yes" ]
		then
			eval "$SSH_CMD \"if ! [ -d \\\"$SLAVE_SYNC_DIR\\\" ]; then $COMMAND_SUDO mkdir -p \\\"$SLAVE_SYNC_DIR\\\"; fi"\" &
			child_pid=$!
			WaitForTaskCompletion $child_pid 0 1800
			if [ $? != 0 ]
			then
				LogError "Cannot create slave directory [$SLAVE_SYNC_DIR]."
				exit 1
			fi
		else
			eval "$SSH_CMD \"if ! [ -d \\\"$SLAVE_SYNC_DIR\\\" ]; then exit 1; fi"\" &
			child_pid=$!
			WaitForTaskCompletion $child_pid 0 1800
			res=$?
			if [ $res != 0 ]
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
				mkdir -p "$SLAVE_SYNC_DIR"
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
	        CheckConnectivity3rdPartyHosts
	        CheckConnectivityRemoteHost		
		eval "$SSH_CMD \"$COMMAND_SUDO df -P \\\"$SLAVE_SYNC_DIR\\\"\"" > $RUN_DIR/osync_slave_space_$SCRIPT_PID &
		child_pid=$!
		WaitForTaskCompletion $child_pid 0 1800
		SLAVE_SPACE=$(cat $RUN_DIR/osync_slave_space_$SCRIPT_PID | tail -1 | awk '{print $4}')
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
	        CheckConnectivity3rdPartyHosts
	        CheckConnectivityRemoteHost
                eval "$SSH_CMD \"$COMMAND_SUDO echo $SCRIPT_PID@$SYNC_ID > \\\"$SLAVE_STATE_DIR/lock\\\"\"" &
                child_pid=$!
		WaitForTaskCompletion $child_pid 0 1800
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
		LogDebug "Master lock pid present: $master_lock_pid"
		ps -p$master_lock_pid > /dev/null 2>&1
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
	        CheckConnectivity3rdPartyHosts
	        CheckConnectivityRemoteHost
		eval "$SSH_CMD \"if [ -f \\\"$SLAVE_STATE_DIR/lock\\\" ]; then cat \\\"$SLAVE_STATE_DIR/lock\\\"; fi\" > $RUN_DIR/osync_remote_slave_lock_$SCRIPT_PID" &
		child_pid=$!
		WaitForTaskCompletion $child_pid 0 1800
		if [ -f $RUN_DIR/osync_remote_slave_lock_$SCRIPT_PID ]
		then
			slave_lock_pid=$(cat $RUN_DIR/osync_remote_slave_lock_$SCRIPT_PID | cut -d'@' -f1)
			slave_lock_id=$(cat $RUN_DIR/osync_remote_slave_lock_$SCRIPT_PID | cut -d'@' -f2)
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
		CheckConnectivity3rdPartyHosts
       		CheckConnectivityRemoteHost
		eval "$SSH_CMD \"if [ -f \\\"$SLAVE_STATE_DIR/lock\\\" ]; then $COMMAND_SUDO rm \\\"$SLAVE_STATE_DIR/lock\\\"; fi\"" &
		child_pid=$!
		WaitForTaskCompletion $child_pid 0 1800
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
	## Tree listing function: list | remove everything not file or directory | remove first 4 columns | remove empty leading spaces | remove "." dir (or return true if not exist)
	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -rlptgoDE8 $RSYNC_ARGS --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --list-only \"$MASTER_SYNC_DIR/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > $RUN_DIR/osync_master-tree-current_$SCRIPT_PID &"
	if [ "$DEBUG" == "yes" ]
	then
		Log "RSYNC_CMD: $rsync_cmd"	
	fi
	eval $rsync_cmd
	child_pid=$!
	WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
	if [ $? == 0 ] && [ -f $RUN_DIR/osync_master-tree-current_$SCRIPT_PID ]
	then
		mv $RUN_DIR/osync_master-tree-current_$SCRIPT_PID "$MASTER_STATE_DIR/master-tree-current"
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
        	CheckConnectivity3rdPartyHosts
	        CheckConnectivityRemoteHost
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -rlptgoDE8 $RSYNC_ARGS --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE -e \"$RSYNC_SSH_CMD\" --list-only $REMOTE_USER@$REMOTE_HOST:\"$ESC_SLAVE_SYNC_DIR/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > $RUN_DIR/osync_slave-tree-current_$SCRIPT_PID &"
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -rlptgoDE8 $RSYNC_ARGS --exclude \"$OSYNC_DIR\" $RSNYC_EXCLUDE --list-only \"$SLAVE_SYNC_DIR/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > $RUN_DIR/osync_slave-tree-current_$SCRIPT_PID &"
	fi
	if [ "$DEBUG" == "yes" ]
	then
		Log "RSYNC_CMD: $rsync_cmd"
	fi
	eval $rsync_cmd
	child_pid=$!
	WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
	retval=$?
	if [ $retval == 0 ] && [ -f $RUN_DIR/osync_slave-tree-current_$SCRIPT_PID ]
	then
		mv $RUN_DIR/osync_slave-tree-current_$SCRIPT_PID "$MASTER_STATE_DIR/slave-tree-current"
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
		comm -23 "$MASTER_STATE_DIR/master-tree-after" "$MASTER_STATE_DIR/master-tree-current" > "$MASTER_STATE_DIR/master-deleted-list"
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
		comm -23 "$MASTER_STATE_DIR/slave-tree-after" "$MASTER_STATE_DIR/slave-tree-current" > "$MASTER_STATE_DIR/slave-deleted-list"
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
	        CheckConnectivity3rdPartyHosts
	        CheckConnectivityRemoteHost
        	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgoDEui --stats -e \"$RSYNC_SSH_CMD\" $SLAVE_BACKUP --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from \"$MASTER_STATE_DIR/master-deleted-list\" --exclude-from \"$MASTER_STATE_DIR/slave-deleted-list\" \"$MASTER_SYNC_DIR/\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_SLAVE_SYNC_DIR/\" > $RUN_DIR/osync_update_slave_replica_$SCRIPT_PID 2>&1 &"
	else
        	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgoDEui --stats $SLAVE_BACKUP --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from \"$MASTER_STATE_DIR/master-deleted-list\" --exclude-from \"$MASTER_STATE_DIR/slave-deleted-list\" \"$MASTER_SYNC_DIR/\" \"$SLAVE_SYNC_DIR/\" > $RUN_DIR/osync_update_slave_replica_$SCRIPT_PID 2>&1 &"
	fi
	if [ "$DEBUG" == "yes" ]
	then
		Log "RSYNC_CMD: $rsync_cmd"
	fi
	eval "$rsync_cmd"
        child_pid=$!
        WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
        retval=$?
	if [ $verbose -eq 1 ] && [ -f $RUN_DIR/osync_update_slave_replica_$SCRIPT_PID ]
        then
                Log "List:\n$(cat $RUN_DIR/osync_update_slave_replica_$SCRIPT_PID)"
        fi

        if [ $retval != 0 ]
        then
                LogError "Updating slave replica failed. Stopping execution."
		if [ $verbose -eq 0 ] && [ -f $RUN_DIR/osync_update_slave_replica_$SCRIPT_PID ]
		then
			LogError "Rsync output:\n$(cat $RUN_DIR/osync_update_slave_replica_$SCRIPT_PID)"
		fi
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
	        CheckConnectivity3rdPartyHosts
	        CheckConnectivityRemoteHost        
        	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) $RSYNC_ARGS -rlptgoDEui --stats -e \"$RSYNC_SSH_CMD\" $MASTER_BACKUP --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from \"$MASTER_STATE_DIR/slave-deleted-list\" --exclude-from \"$MASTER_STATE_DIR/master-deleted-list\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_SLAVE_SYNC_DIR/\" \"$MASTER_SYNC_DIR\" > $RUN_DIR/osync_update_master_replica_$SCRIPT_PID 2>&1 &"
	else
	        rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgoDEui --stats $MASTER_BACKUP --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from \"$MASTER_STATE_DIR/slave-deleted-list\" --exclude-from \"$MASTER_STATE_DIR/master-deleted-list\" \"$SLAVE_SYNC_DIR/\" \"$MASTER_SYNC_DIR/\" > $RUN_DIR/osync_update_master_replica_$SCRIPT_PID 2>&1 &"
	fi
	if [ "$DEBUG" == "yes" ]
	then
		Log "RSYNC_CMD: $rsync_cmd"
	fi
	eval "$rsync_cmd"
        child_pid=$!
        WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
        retval=$?
        if [ $verbose -eq 1 ] && [ -f $RUN_DIR/osync_update_master_replica_$SCRIPT_PID ]
        then
                Log "List:\n$(cat $RUN_DIR/osync_update_master_replica_$SCRIPT_PID)"
        fi

        if [ $retval != 0 ]
        then
                if [ $verbose -eq 0 ] && [ -f $RUN_DIR/osync_update_slave_replica_$SCRIPT_PID ]
                then
                        LogError "Rsync output:\n$(cat $RUN_DIR/osync_update_slave_replica_$SCRIPT_PID)"
                fi
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
	Log "Propagating deletions to slave replica."
	if [ "$REMOTE_SYNC" == "yes" ]
	then
	        CheckConnectivity3rdPartyHosts
	        CheckConnectivityRemoteHost
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgoDEui --stats -e \"$RSYNC_SSH_CMD\" $SLAVE_DELETE --delete --exclude \"$OSYNC_DIR\" --include-from \"$MASTER_STATE_DIR/master-deleted-list\" --exclude=\"*\" \"$MASTER_SYNC_DIR/\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_SLAVE_SYNC_DIR/\" > $RUN_DIR/osync_deletion_on_slave_$SCRIPT_PID 2>&1 &"
	else
		#rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgoDEui --stats $SLAVE_DELETE --delete --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from \"$MASTER_STATE_DIR/slave-deleted-list\" --include-from \"$MASTER_STATE_DIR/master-deleted-list\" \"$MASTER_SYNC_DIR/\" \"$SLAVE_SYNC_DIR/\" > $RUN_DIR/osync_deletion_on_slave_$SCRIPT_PID 2>&1 &"
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgoDEui --stats $SLAVE_DELETE --delete --exclude \"$OSYNC_DIR\" --include-from \"$MASTER_STATE_DIR/master-deleted-list\" --exclude=\"*\" \"$MASTER_SYNC_DIR/\" \"$SLAVE_SYNC_DIR/\" > $RUN_DIR/osync_deletion_on_slave_$SCRIPT_PID 2>&1 &"
	fi
	if [ "$DEBUG" == "yes" ]
	then
		Log "RSYNC_CMD: $rsync_cmd"
	fi
	eval "$rsync_cmd"
	child_pid=$!
	WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
	retval=$?
        if [ $verbose -eq 1 ] && [ -f $RUN_DIR/osync_deletion_on_slave_$SCRIPT_PID ]
        then
                Log "List:\n$(cat $RUN_DIR/osync_deletion_on_slave_$SCRIPT_PID)"
        fi

	if [ $retval != 0 ]
	then
                if [ $verbose -eq 0 ] && [ -f $RUN_DIR/osync_deletion_on_slave_$SCRIPT_PID ]
                then
                        LogError "Rsync output:\n$(cat $RUN_DIR/osync_deletion_on_slave_$SCRIPT_PID)"
                fi 
		LogError "Deletion on slave failed."
		echo "delete-propagation-slave.fail" > "$MASTER_STATE_DIR/last-action"
		exit 1
	else
		echo "delete-propagation-slave.success" > "$MASTER_STATE_DIR/last-action"
	fi
}

function delete_on_master
{	
	Log "Propagating deletions to master replica."
	if [ "$REMOTE_SYNC" == "yes" ]
	then
	        CheckConnectivity3rdPartyHosts
        	CheckConnectivityRemoteHost
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgoDEui --stats -e \"$RSYNC_SSH_CMD\" $MASTER_DELETE --delete --exclude \"$OSYNC_DIR\" --include-from \"$MASTER_STATE_DIR/slave-deleted-list\" --exclude=\"*\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_SLAVE_SYNC_DIR/\" \"$MASTER_SYNC_DIR/\" > $RUN_DIR/osync_deletion_on_master_$SCRIPT_PID 2>&1 &"
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -rlptgoDEui --stats $MASTER_DELETE --delete --exclude \"$OSYNC_DIR\" --include-from \"$MASTER_STATE_DIR/slave-deleted-list\" --exclude=\"*\" \"$SLAVE_SYNC_DIR/\" \"$MASTER_SYNC_DIR/\" > $RUN_DIR/osync_deletion_on_master_$SCRIPT_PID 2>&1 &"
	fi
	if [ "$DEBUG" == "yes" ]
	then
		Log "RSYNC_CMD: $rsync_cmd"
	fi
	eval "$rsync_cmd"
	child_pid=$!
	WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
	retval=$?
        if [ $verbose -eq 1 ] && [ -f $RUN_DIR/osync_deletion_on_master_$SCRIPT_PID ]
        then
                Log "List:\n$(cat $RUN_DIR/osync_deletion_on_master_$SCRIPT_PID)"
        fi

	if [ $retval != 0 ]
	then
                if [ $verbose -eq 0 ] && [ -f $RUN_DIR/osync_deletion_on_master_$SCRIPT_PID ]
                then
                        LogError "Rsync output:\n$(cat $RUN_DIR/osync_deletion_on_master_$SCRIPT_PID)"
                fi
		LogError "Deletion on master failed."
		echo "delete-propagation-master.fail" > "$MASTER_STATE_DIR/last-action"
		exit 1
	else
		echo "delete-propagation-master.success" > "$MASTER_STATE_DIR/last-action"
	fi
}

function master_tree_after
{
	if [ $dryrun -eq 1 ]
	then
		Log "No need to create after run master replica file list, nothing should have changed."
		return 0
	fi
        Log "Creating after run master replica file list."
        rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -rlptgoDE8 $RSYNC_ARGS --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --list-only \"$MASTER_SYNC_DIR/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > $RUN_DIR/osync_master-tree-after_$SCRIPT_PID &"
	if [ "$DEBUG" == "yes" ]
	then
		Log "RSYNC_CMD: $rsync_cmd"
	fi
	eval $rsync_cmd
	child_pid=$!
        WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
        retval=$?
        if [ $retval == 0 ] && [ -f $RUN_DIR/osync_master-tree-after_$SCRIPT_PID ]
        then
                mv $RUN_DIR/osync_master-tree-after_$SCRIPT_PID "$MASTER_STATE_DIR/master-tree-after"
		echo "master-replica-tree-after.success" > "$MASTER_STATE_DIR/last-action"
        else
                LogError "Cannot create slave file list."
		echo "master-replica-tree-after.fail" > "$MASTER_STATE_DIR/last-action"
                exit 1
        fi
}

function slave_tree_after
{
	if [ $dryrun -eq 1 ]
	then
		Log "No need to create after frun slave replica file list, nothing should have changed."
		return 0
	fi
        Log "Creating after run slave replica file list."
	if [ "$REMOTE_SYNC" == "yes" ]
	then
	        CheckConnectivity3rdPartyHosts
	        CheckConnectivityRemoteHost
	        rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -rlptgoDE8 $RSYNC_ARGS -e \"$RSYNC_SSH_CMD\" --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --list-only $REMOTE_USER@$REMOTE_HOST:\"$ESC_SLAVE_SYNC_DIR/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > $RUN_DIR/osync_slave-tree-after_$SCRIPT_PID &"
	else
	        rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" -rlptgoDE8 $RSYNC_ARGS --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --list-only \"$SLAVE_SYNC_DIR/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > $RUN_DIR/osync_slave-tree-after_$SCRIPT_PID &"
	fi
	if [ "$DEBUG" == "yes" ]
	then
		Log "RSYNC_CMD: $rsync_cmd"
	fi
	eval $rsync_cmd
	child_pid=$!
        WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
        retval=$?
        if [ $retval == 0 ] && [ -f $RUN_DIR/osync_slave-tree-after_$SCRIPT_PID ]
        then
                mv $RUN_DIR/osync_slave-tree-after_$SCRIPT_PID "$MASTER_STATE_DIR/slave-tree-after"
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
        CheckConnectivity3rdPartyHosts
        CheckConnectivityRemoteHost

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
				Log "WARNING: Trying to resume aborted osync execution on $(stat --format %y "$MASTER_STATE_DIR/last-action") at task [$resume_sync]. [$resume_count] previous tries."
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


	################################################################################################################################################# Actual sync begins here

	## This replaces the case statement below because ;& operator is not supported in bash 3.2... Code is more messy than case :(
	if [ "$resume_sync" == "none" ] || [ "$resume_sync" == "noresume" ] || [ "$resume_sync" == "master-replica-tree.fail" ]
	then
		master_tree_current
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "master-replica-tree.success" ] || [ "$resume_sync" == "slave-replica-tree.fail" ]
	then
		slave_tree_current
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "slave-replica-tree.success" ] || [ "$resume_sync" == "master-replica-deleted-list.fail" ]
	then
		master_delete_list
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "master-replica-deleted-list.success" ] || [ "$resume_sync" == "slave-replica-deleted-list.fail" ]
	then
		slave_delete_list
		resume_sync="resumed"
 	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "slave-replica-deleted-list.success" ] || [ "$resume_sync" == "update-master-replica.fail" ] || [ "$resume_sync" == "update-slave-replica.fail" ]
	then
		if [ "$CONFLICT_PREVALANCE" != "master" ]
		then
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "slave-replica-deleted-list.success" ] || [ "$resume_sync" == "update-master-replica.fail" ]
			then
				sync_update_master
				resume_sync="resumed"
			fi
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "update-master-replica.success" ] || [ "$resume_sync" == "update-slave-replica.fail" ]
			then
				sync_update_slave
				resume_sync="resumed"
			fi
		else
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "slave-replica-deleted-list.success" ] || [ "$resume_sync" == "update-slave-replica.fail" ]
                        then
                                sync_update_slave
                                resume_sync="resumed"
                        fi
                        if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "update-slave-replica.success" ] || [ "$resume_sync" == "update-master-replica.fail" ]
                        then
                                sync_update_master
                                resume_sync="resumed"
                        fi
		fi
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "update-slave-replica.success" ] || [ "$resume_sync" == "update-master-replica.success" ] || [ "$resume_sync" == "delete-propagation-slave.fail" ]
	then
		delete_on_slave
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "delete-propagation-slave.success" ] || [ "$resume_sync" == "delete-propagation-master.fail" ]
	then
		delete_on_master
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "delete-propagation-master.success" ] || [ "$resume_sync" == "master-replica-tree-after.fail" ]
	then
		master_tree_after
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "master-replica-tree-after.success" ] || [ "$resume_sync" == "slave-replica-tree-after.fail" ]
	then
		slave_tree_after
		resume_sync="resumed"
	fi

#	## In this case statement, ;& means executing every command below regardless of conditions. Only works with bash v4
#	case $resume_sync in
#		none|noresume)
#		;&
#		master-replica-tree.fail)
#		master_tree_current
#		;&
#		master-replica-tree.success|slave-replica-tree.fail)
#		slave_tree_current
#		;&
#		slave-replica-tree.success|master-replica-deleted-list.fail)
#		master_delete_list
#		;&
#		master-replica-deleted-list.success|slave-replica-deleted-list.fail)
#		slave_delete_list
#		;&
#		slave-replica-deleted-list.success|update-master-replica.fail|update-slave-replica.fail)
#	        if [ "$CONFLICT_PREVALANCE" != "master" ]
#	        then
#       	        case $resume_sync in
#				none)
#				;&
#				slave-replica-deleted-list.success|update-master-replica.fail)
#				sync_update_master
#				;&
#				update-master-replica.success|update-slave-replica.fail)
#				sync_update_slave
#				;;
#			esac
#       	else
#	              	case $resume_sync in
#				none)
#				;&
#				slave-replica-deleted-list.success|update-slave-replica.fail)
#				sync_update_slave
#				;&
#				update-slave-replica.success|update-master-replica.fail)
#	                	sync_update_master
#				;;
#			esac
#       	fi
#		;&
#		update-slave-replica.success|update-master-replica.success|delete-propagation-slave.fail)
#		delete_on_slave
#		;&
#		delete-propagation-slave.success|delete-propagation-master.fail)
#		delete_on_master
#		;&
#		delete-propagation-master.success|master-replica-tree-after.fail)
#		master_tree_after
#		;&
#		master-replica-tree-after.success|slave-replica-tree-after.fail)
#		slave_tree_after
#		;;
#	esac

	Log "Finished synchronization task."
	echo "sync.success" > "$MASTER_STATE_DIR/last-action"
	echo "0" > "$MASTER_STATE_DIR/resume-count"
}

function SoftDelete
{
	if [ "$CONFLICT_BACKUP" != "no" ] && [ $CONFLICT_BACKUP_DAYS -ne 0 ]
	then
		if [ -d "$MASTER_BACKUP_DIR" ]
		then
			Log "Removing backups older than $CONFLICT_BACKUP_DAYS days on master replica."
			if [ $dryrun -eq 1 ]
			then
				$FIND_CMD "$MASTER_BACKUP_DIR/" -ctime +$CONFLICT_BACKUP_DAYS &
			else
				$FIND_CMD "$MASTER_BACKUP_DIR/" -ctime +$CONFLICT_BACKUP_DAYS | xargs rm -rf &
			fi
			child_pid=$!
        		WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
        		retval=$?
			if [ $retval -ne 0 ]
			then
				LogError "Error while executing conflict backup cleanup on master replica."
			else
				Log "Conflict backup cleanup complete on master replica."
			fi
		elif [ -d "$MASTER_BACKUP_DIR" ] && ! [ -w "$MASTER_BACKUP_DIR" ]
		then
			LogError "Warning: Master replica conflict backup dir [$MASTER_BACKUP_DIR] isn't writable. Cannot clean old files."
		fi
		
		if [ "$REMOTE_SYNC" == "yes" ]
		then
        		CheckConnectivity3rdPartyHosts
	        	CheckConnectivityRemoteHost
			Log "Removing backups older than $CONFLICT_BACKUP_DAYS days on remote slave replica."
			if [ $dryrun -eq 1 ]
			then
				eval "$SSH_CMD \"if [ -w \\\"$SLAVE_BACKUP_DIR\\\" ]; then $COMMAND_SUDO $REMOTE_FIND_CMD \\\"$SLAVE_BACKUP_DIR/\\\" -ctime +$CONFLICT_BACKUP_DAYS; fi\""
			else
				eval "$SSH_CMD \"if [ -w \\\"$SLAVE_BACKUP_DIR\\\" ]; then $COMMAND_SUDO $REMOTE_FIND_CMD \\\"$SLAVE_BACKUP_DIR/\\\" -ctime +$CONFLICT_BACKUP_DAYS | xargs rm -rf; fi\""
			fi
			child_pid=$!
                        WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
                        retval=$?
                        if [ $retval -ne 0 ]
                        then
                                LogError "Error while executing conflict backup cleanup on slave replica."
                        else
                                Log "Conflict backup cleanup complete on slave replica."
                        fi
		else
			if [ -w "$SLAVE_BACKUP_DIR" ]
			then
				Log "Removing backups older than $CONFLICT_BACKUP_DAYS days on slave replica."
				if [ $dryrun -eq 1 ]
				then
					$FIND_CMD "$SLAVE_BACKUP_DIR/" -ctime +$CONFLICT_BACKUP_DAYS
				else
					$FIND_CMD "$SLAVE_BACKUP_DIR/" -ctime +$CONFLICT_BACKUP_DAYS | xargs rm -rf
				fi
				child_pid=$!
	                        WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
        	                retval=$?
                	        if [ $retval -ne 0 ]
                        	then
                                	LogError "Error while executing conflict backup cleanup on slave replica."
                        	else
                                	Log "Conflict backup cleanup complete on slave replica."
                        	fi
			elif [ -d "$SLAVE_BACKUP_DIR" ] && ! [ -w "$SLAVE_BACKUP_DIR" ]
			then
				LogError "Warning: Slave replica conflict backup dir [$SLAVE_BACKUP_DIR] isn't writable. Cannot clean old files."
			fi
		fi
	fi

	if [ "$SOFT_DELETE" != "no" ] && [ $SOFT_DELETE_DAYS -ne 0 ]
	then
		if [ -w "$MASTER_DELETE_DIR" ]
		then
			Log "Removing soft deleted items older than $SOFT_DELETE_DAYS days on master replica."
			if [ $dryrun -eq 1 ]
			then
				$FIND_CMD "$MASTER_DELETE_DIR/" -ctime +$SOFT_DELETE_DAYS
			else
				$FIND_CMD "$MASTER_DELETE_DIR/" -ctime +$SOFT_DELETE_DAYS | xargs rm -rf
			fi
			child_pid=$!
                        WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
                        retval=$?
                        if [ $retval -ne 0 ]
                        then
                                LogError "Error while executing soft delete cleanup on master replica."
                        else
                                Log "Soft delete cleanup complete on master replica."
                        fi
		elif [ -d "$MASTER_DELETE_DIR" ] && ! [ -w $MASTER_DELETE_DIR ]
		then
			LogError "Warning: Master replica deletion backup dir [$MASTER_DELETE_DIR] isn't writable. Cannot clean old files."
		fi

		if [ "$REMOTE_SYNC" == "yes" ]
		then
			CheckConnectivity3rdPartyHosts
        		CheckConnectivityRemoteHost
			Log "Removing soft deleted items older than $SOFT_DELETE_DAYS days on remote slave replica."
			if [ $dryrun -eq 1 ]
			then
				eval "$SSH_CMD \"if [ -w \\\"$SLAVE_DELETE_DIR\\\" ]; then $COMMAND_SUDO $REMOTE_FIND_CMD \\\"$SLAVE_DELETE_DIR/\\\" -ctime +$SOFT_DELETE_DAYS; fi\""
			else
				eval "$SSH_CMD \"if [ -w \\\"$SLAVE_DELETE_DIR\\\" ]; then $COMMAND_SUDO $REMOTE_FIND_CMD \\\"$SLAVE_DELETE_DIR/\\\" -ctime +$SOFT_DELETE_DAYS | xargs rm -rf; fi\""
			fi
			child_pid=$!
                        WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
                        retval=$?
                        if [ $retval -ne 0 ]
                        then
                                LogError "Error while executing soft delete cleanup on slave replica."
                        else
                                Log "Soft delete cleanup complete on slave replica."
                        fi

		else
			if [ -w "$SLAVE_DELETE_DIR" ]
			then
				Log "Removing soft deleted items older than $SOFT_DELETE_DAYS days on slave replica."
				if [ $dryrun -eq 1 ]
				then
					$FIND_CMD "$SLAVE_DELETE_DIR/" -ctime +$SOFT_DELETE_DAYS
				else
					$FIND_CMD "$SLAVE_DELETE_DIR/" -ctime +$SOFT_DELETE_DAYS | xargs rm -rf
				fi
				child_pid=$!
                       		WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME 0
                        	retval=$?
                        	if [ $retval -ne 0 ]
                        	then
                               		LogError "Error while executing soft delete cleanup on slave replica."
                        	else
                                	Log "Soft delete cleanup complete on slave replica."
                        	fi
			elif [ -d "$SLAVE_DELETE_DIR" ] && ! [ -w "$SLAVE_DELETE_DIR" ]
			then
				LogError "Warning: Slave replica deletion backup dir [$SLAVE_DELETE_DIR] isn't writable. Cannot clean old files."
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
                trap 'TrapError ${LINENO} $?' ERR
        fi

        if [ "$LOGFILE" == "" ]
        then
                if [ -w /var/log ]
		then
			LOG_FILE=/var/log/osync_$OSYNC_VERSION-$SYNC_ID.log
		else
			LOG_FILE=./osync_$OSYNC_VERSION-$SYNC_ID.log
		fi
        else
                LOG_FILE="$LOGFILE"
        fi

        MAIL_ALERT_MSG="Warning: Execution of osync instance $OSYNC_ID (pid $SCRIPT_PID) as $LOCAL_USER@$LOCAL_HOST produced errors."

	## If running Msys, find command of windows is used instead of msys one
	if [ "$LOCAL_OS" == "msys" ]
	then
		FIND_CMD=$(dirname $BASH)/find
	else
		FIND_CMD=find
	fi
	
	if [ "$REMOTE_OS" == "msys" ]
	then
		REMOTE_FIND_CMD=$(dirname $BASH)/find
	else
		REMOTE_FIND_CMD=find
	fi

	## Rsync does not like spaces in directory names, considering it as two different directories. Handling this schema by escaping space
	## It seems this only happens when trying to execute an rsync command through eval $rsync_cmd... on a remote host. This is freaking unholy to find a workaround...
	## So actually use $MASTER_SYNC_DIR for local rsync calls and $ESC_MASTER_SYNC_DIR for remote rsync calls like user@host:$ESC_MASTER_SYNC_DIR
	## The same applies for slave sync dir..............................................T.H.I.S..I.S..A..P.R.O.G.R.A.M.M.I.N.G..N.I.G.H.T.M.A.R.E
	ESC_MASTER_SYNC_DIR=$(EscapeSpaces "$MASTER_SYNC_DIR")
	ESC_SLAVE_SYNC_DIR=$(EscapeSpaces "$SLAVE_SYNC_DIR")

	MASTER_STATE_DIR="$MASTER_SYNC_DIR/$OSYNC_DIR/state"
	SLAVE_STATE_DIR="$SLAVE_SYNC_DIR/$OSYNC_DIR/state"

	## Working directories to keep backups of updated / deleted files
	MASTER_BACKUP_DIR="$OSYNC_DIR/backups"
	MASTER_DELETE_DIR="$OSYNC_DIR/deleted"
	SLAVE_BACKUP_DIR="$OSYNC_DIR/backups"
	SLAVE_DELETE_DIR="$OSYNC_DIR/deleted"
	
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
		SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
		RSYNC_SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY -p $REMOTE_PORT"
	fi

	## Support for older config files without RSYNC_EXECUTABLE option
        if [ "$RSYNC_EXECUTABLE" == "" ]
        then
                RSYNC_EXECUTABLE=rsync
        fi

        ## Sudo execution option
        if [ "$SUDO_EXEC" == "yes" ]
        then
                if [ "$RSYNC_REMOTE_PATH" != "" ]
                then
                        RSYNC_PATH="sudo $(type -p $RSYNC_REMOTE_PATH)/$RSYNC_EXECUTABLE)"
                else
                        RSYNC_PATH="sudo $RSYNC_EXECUTABLE"
                fi
                COMMAND_SUDO="sudo"
        else
                if [ "$RSYNC_REMOTE_PATH" != "" ]
                        then
                                RSYNC_PATH="$(type -p $RSYNC_REMOTE_PATH)/$RSYNC_EXECUTABLE)"
                        else
                                RSYNC_PATH="$RSYNC_EXECUTABLE"
                        fi
                COMMAND_SUDO=""
        fi

	## Set rsync options
	RSYNC_ARGS="-"
        if [ "$PRESERVE_ACL" == "yes" ]
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

	if [ "$BANDWIDTH" != "" ] && [ "$BANDWIDTH" != "0" ]
	then
		RSYNC_ARGS=$RSYNC_ARGS" --bwlimit=$BANDWIDTH"
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
	echo "usage: osync /path/to/conf.file [--dry] [--silent] [--verbose] [--no-maxtime] [--force-unlock]"
	echo ""
	echo "--dry: will run osync without actuallyv doing anything; just testing"
	echo "--silent: will run osync without any output to stdout, usefull for cron jobs"
	echo "--verbose: adds command outputs"
	echo "--no-maxtime: disables any soft and hard execution time checks"
	echo "--force-unlock: will override any existing active or dead locks on master and slave replica"
	exit 128
}

# Comand line argument flags
dryrun=0
silent=0
force_unlock=0
no_maxtime=0
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
		--no-maxtime)
		no_maxtime=1
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
			GetOperatingSystem
			DATE=$(date)
			Log "-------------------------------------------------------------"
			Log "$DRY_WARNING $DATE - Osync v$OSYNC_VERSION script begin."
			Log "-------------------------------------------------------------"
			Log "Sync task [$SYNC_ID] launched as $LOCAL_USER@$LOCAL_HOST (PID $SCRIPT_PID)"
			if [ $no_maxtime -eq 1 ]
			then
				SOFT_MAX_EXEC_TIME=0
				HARD_MAX_EXEC_TIME=0
			fi
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
	exit 1
fi
