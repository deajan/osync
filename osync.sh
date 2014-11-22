#!/usr/bin/env bash

PROGRAM="Osync" # Rsync based two way sync engine with fault tolerance
AUTHOR="(L) 2013-2014 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION=0.99RC3+
PROGRAM_BUILD=2209201401

## type doesn't work on platforms other than linux (bash). If if doesn't work, always assume output is not a zero exitcode
if ! type -p "$BASH" > /dev/null
then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

## allow debugging from command line with preceding ocsync with DEBUG=yes
if [ ! "$DEBUG" == "yes" ]
then
	DEBUG=no
	SLEEP_TIME=1
else
	SLEEP_TIME=10
fi

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

## Default directory where to store temporary run files
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

ALERT_LOG_FILE=$RUN_DIR/osync_lastlog

function Log
{
	if [ $sync_on_changes -eq 1 ]
	then
		prefix="$(date) - "
	else
		prefix="TIME: $SECONDS - "
	fi

	echo -e "$prefix$1" >> "$LOG_FILE"

	if [ $silent -eq 0 ]
	then
		echo -e "$prefix$1"
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

function TrapError
{
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
	if [ $error_alert -ne 0 ]
	then
        	SendAlert
		UnlockDirectories
		CleanUp
        	LogError "Osync finished with errros."
		exitcode=1
	else
		UnlockDirectories
		CleanUp
        	Log "Osync finished."
		exitcode=0
	fi

	if ps -p $child_pid > /dev/null 2>&1
	then
		kill -9 $child_pid
	fi

	if ps -p $sub_pid > /dev/null 2>&1
	then
		kill -9 $sub_pid
	fi

	exit $exitcode
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
        	rm -f $RUN_DIR/osync_*_$SCRIPT_PID
	fi
}

function SendAlert
{
	if [ "$quick_sync" == "2" ]
	then
		Log "Current task is a quicksync task. Will not send any alert."
		return 0
	fi
        eval "cat $LOG_FILE $COMPRESSION_PROGRAM > $ALERT_LOG_FILE"
        MAIL_ALERT_MSG=$MAIL_ALERT_MSG$'\n\n'$(tail -n 25 "$LOG_FILE")
	if type -p mutt > /dev/null 2>&1
        then
                echo $MAIL_ALERT_MSG | $(type -p mutt) -x -s "Sync alert for $SYNC_ID" $DESTINATION_MAILS -a "$ALERT_LOG_FILE"
                if [ $? != 0 ]
                then
                        Log "WARNING: Cannot send alert email via $(type -p mutt) !!!"
                else
                        Log "Sent alert mail using mutt."
                fi
        elif type -p mail > /dev/null 2>&1
        then
                echo $MAIL_ALERT_MSG | $(type -p mail) -a "$ALERT_LOG_FILE" -s "Sync alert for $SYNC_ID" $DESTINATION_MAILS
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
		if [ "$SMTP_USER" != "" ] && "$SMTP_PASSWORD" != "" ]
		then
			$SMTP_OPTIONS="-xu $SMTP_USER -xp $SMTP_PASSWORD"
		else
			$SMTP_OPTIONS=""
		fi
		$(type -p sendemail) -f $SENDER_MAIL -t $DESTINATION_MAILS -u "Backup alert for $BACKUP_ID" -m "$MAIL_ALERT_MSG" -s $SMTP_SERVER $SMTP_OPTIONS > /dev/null 2>&1
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

	if [ -f "$ALERT_LOG_FILE" ]
	then
		rm "$ALERT_LOG_FILE"
	fi
}

function LoadConfigFile
{
        if [ ! -f "$1" ]
        then
                LogError "Cannot load configuration file [$1]. Sync cannot start."
                exit 1
        elif [[ "$1" != *".conf" ]]
        then
                LogError "Wrong configuration file supplied [$1]. Sync cannot start."
		exit 1
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

function GetLocalOS
{
	LOCAL_OS_VAR=$(uname -spio 2>&1)
	if [ $? != 0 ]
	then
		LOCAL_OS_VAR=$(uname -v 2>&1)
		if [ $? != 0 ]
		then
			LOCAL_OS_VAR=($uname)
		fi
	fi

	case $LOCAL_OS_VAR in
                *"Linux"*)
                LOCAL_OS="Linux"
                ;;
                *"BSD"*)
                LOCAL_OS="BSD"
                ;;
                *"MINGW32"*)
                LOCAL_OS="msys"
                ;;
                *"Darwin"*)
                LOCAL_OS="MacOSX"
                ;;
                *)
                LogError "Running on >> $LOCAL_OS_VAR << not supported. Please report to the author."
                exit 1
                ;;
        esac
        LogDebug "Local OS: [$LOCAL_OS_VAR]."
}

function GetRemoteOS
{
	if [ "$REMOTE_SYNC" == "yes" ]
	then
        	CheckConnectivity3rdPartyHosts
        	CheckConnectivityRemoteHost
		eval "$SSH_CMD \"uname -spio\" > $RUN_DIR/osync_remote_os_$SCRIPT_PID 2>&1"
		child_pid=$!
        	WaitForTaskCompletion $child_pid 120 240
        	retval=$?
		if [ $retval != 0 ]
                then
                	eval "$SSH_CMD \"uname -v\" > $RUN_DIR/osync_remote_os_$SCRIPT_PID 2>&1"
			child_pid=$!
        		WaitForTaskCompletion $child_pid 120 240
        		retval=$?
			if [ $retval != 0 ]
                	then
                		eval "$SSH_CMD \"uname\" > $RUN_DIR/osync_remote_os_$SCRIPT_PID 2>&1"
				child_pid=$!
        			WaitForTaskCompletion $child_pid 120 240
        			retval=$?
				if [ $retval != 0 ]
                		then
                			LogError "Cannot Get remote OS type."
                		fi
                	fi
                fi

		REMOTE_OS_VAR=$(cat $RUN_DIR/osync_remote_os_$SCRIPT_PID)

		case $REMOTE_OS_VAR in
			*"Linux"*)
			REMOTE_OS="Linux"
			;;
			*"BSD"*)
			REMOTE_OS="BSD"
			;;
			*"MINGW32"*)
			REMOTE_OS="msys"
			;;
			*"Darwin"*)
			REMOTE_OS="MacOSX"
			;;
			*"ssh"*|*"SSH"*)
			LogError "Cannot connect to remote system."
			exit 1
			;;
			*)
			LogError "Running on remote OS failed. Please report to the author if the OS is not supported."
			LogError "Remote OS said:\n$REMOTE_OS_VAR"
			exit 1
		esac

		LogDebug "Remote OS: [$REMOTE_OS_VAR]."
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
		PROCESS_TEST_CMD="ps -a | awk '{\$1=\$1}\$1' | awk '{print \$1}' | grep $1"
	else
		PROCESS_TEST_CMD="ps -p$1"
	fi
	while eval $PROCESS_TEST_CMD > /dev/null
        do
                Spinner
                EXEC_TIME=$(($SECONDS - $SECONDS_BEGIN))
                if [ $((($EXEC_TIME + 1) % $KEEP_LOGGING)) -eq 0 ]
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
                sleep $SLEEP_TIME
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
                if [ $((($SECONDS + 1) % $KEEP_LOGGING)) -eq 0 ]
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
                sleep $SLEEP_TIME
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

	if [ $verbose -eq 1 ] || [ $retval -ne 0 ]
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

        if [ -f $RUN_DIR/osync_run_remote_$SCRIPT_PID ] && ([ $verbose -eq 1 ] || [ $retval -ne 0 ])
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
		$PING_CMD $REMOTE_HOST > /dev/null 2>&1
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
			$PING_CMD $i > /dev/null 2>&1
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

function RsyncExcludeFrom
{
	if [ ! $RSYNC_EXCLUDE_FROM == "" ]
	then
		## Check if the exclude list has a full path, and if not, add the config file path if there is one
		if [ "$(basename $RSYNC_EXCLUDE_FROM)" == "$RSYNC_EXCLUDE_FROM" ]
		then
			RSYNC_EXCLUDE_FROM=$(dirname $ConfigFile)/$RSYNC_EXCLUDE_FROM
		fi

		if [ -e $RSYNC_EXCLUDE_FROM ]
		then
			RSYNC_EXCLUDE="$RSYNC_EXCLUDE --exclude-from=\"$RSYNC_EXCLUDE_FROM\""
		fi
	fi
}

function WriteLockFiles
{
        echo $SCRIPT_PID > "$MASTER_LOCK"
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
                eval "$SSH_CMD \"echo $SCRIPT_PID@$SYNC_ID | $COMMAND_SUDO tee \\\"$SLAVE_LOCK\\\" > /dev/null \"" &
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
                echo "$SCRIPT_PID@$SYNC_ID" > "$SLAVE_LOCK"
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
	if [ $nolocks -eq 1 ]
	then
		return 0
	fi

	if [ $force_unlock -eq 1 ]
	then
		WriteLockFiles
		if [ $? != 0 ]
		then
			exit 1
		fi
	fi

	Log "Checking for replica locks."

	if [ -f "$MASTER_LOCK" ]
	then
		master_lock_pid=$(cat $MASTER_LOCK)
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
		eval "$SSH_CMD \"if [ -f \\\"$SLAVE_LOCK\\\" ]; then cat \\\"$SLAVE_LOCK\\\"; fi\" > $RUN_DIR/osync_remote_slave_lock_$SCRIPT_PID" &
		child_pid=$!
		WaitForTaskCompletion $child_pid 0 1800
		if [ -f $RUN_DIR/osync_remote_slave_lock_$SCRIPT_PID ]
		then
			slave_lock_pid=$(cat $RUN_DIR/osync_remote_slave_lock_$SCRIPT_PID | cut -d'@' -f1)
			slave_lock_id=$(cat $RUN_DIR/osync_remote_slave_lock_$SCRIPT_PID | cut -d'@' -f2)
		fi
	else
		if [ -f "$SLAVE_LOCK" ]
		then
			slave_lock_pid=$(cat "$SLAVE_LOCK" | cut -d'@' -f1)
			slave_lock_id=$(cat "$SLAVE_LOCK" | cut -d'@' -f2)
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
	if [ $nolocks -eq 1 ]
	then
		return 0
	fi

	if [ "$REMOTE_SYNC" == "yes" ]
	then
		CheckConnectivity3rdPartyHosts
       		CheckConnectivityRemoteHost
		eval "$SSH_CMD \"if [ -f \\\"$SLAVE_LOCK\\\" ]; then $COMMAND_SUDO rm \\\"$SLAVE_LOCK\\\"; fi\"" &
		child_pid=$!
		WaitForTaskCompletion $child_pid 0 1800
	else
		if [ -f "$SLAVE_LOCK" ];then rm "$SLAVE_LOCK"; fi
	fi

	if [ $? != 0 ]
	then
		LogError "Could not unlock slave replica."
	else
		Log "Removed slave replica lock."
	fi

	if [ -f "$MASTER_LOCK" ]
	then
		rm "$MASTER_LOCK"
		if [ $? != 0 ]
		then
			LogError "Could not unlock master replica."
		else
			Log "Removed master replica lock."
		fi
	fi
}

###### Sync core functions

	## Rsync does not like spaces in directory names, considering it as two different directories. Handling this schema by escaping space.
	## It seems this only happens when trying to execute an rsync command through eval $rsync_cmd on a remote host.
	## So i'm using unescaped $MASTER_SYNC_DIR for local rsync calls and escaped $ESC_MASTER_SYNC_DIR for remote rsync calls like user@host:$ESC_MASTER_SYNC_DIR
	## The same applies for slave sync dir..............................................T.H.I.S..I.S..A..P.R.O.G.R.A.M.M.I.N.G..N.I.G.H.T.M.A.R.E


## tree_list(replica_path, replica type, tree_filename) Creates a list of files in replica_path for replica type (master/slave) in filename $3
function tree_list
{
	Log "Creating $2 replica file list [$1]."
	if [ "$REMOTE_SYNC" == "yes" ] && [ "$2" == "slave" ]
	then
        	CheckConnectivity3rdPartyHosts
	        CheckConnectivityRemoteHost
		ESC=$(EscapeSpaces "$1")
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -8 --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE -e \"$RSYNC_SSH_CMD\" --list-only $REMOTE_USER@$REMOTE_HOST:\"$ESC/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/osync_$2_$SCRIPT_PID\" &"
	else
		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS -8 --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --list-only \"$1/\" | grep \"^-\|^d\" | awk '{\$1=\$2=\$3=\$4=\"\" ;print}' | awk '{\$1=\$1 ;print}' | (grep -v \"^\.$\" || :) | sort > \"$RUN_DIR/osync_$2_$SCRIPT_PID\" &"
	fi
	LogDebug "RSYNC_CMD: $rsync_cmd"
	## Redirect commands stderr here to get rsync stderr output in logfile
	eval $rsync_cmd 2>> "$LOG_FILE"
	child_pid=$!
	WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
	retval=$?
	## Retval 24 = some files vanished while creating list
	if ([ $retval == 0 ] || [ $retval == 24 ]) && [ -f $RUN_DIR/osync_$2_$SCRIPT_PID ]
	then
		mv $RUN_DIR/osync_$2_$SCRIPT_PID "$MASTER_STATE_DIR/$2$3"
		return $?
	else
		LogError "Cannot create replica file list."
		exit $retval
	fi
}

# delete_list(replica, tree-file-after, tree-file-current, deleted-list-file, deleted-failed-list-file): Creates a list of files vanished from last run on replica $1 (master/slave)
function delete_list
{
        Log "Creating $1 replica deleted file list."
        if [ -f "$MASTER_STATE_DIR/$1$TREE_AFTER_FILENAME_NO_SUFFIX" ]
        then
		## Same functionnality, comm is much faster than grep but is not available on every platform
		if type -p comm > /dev/null 2>&1
		then
			cmd="comm -23 \"$MASTER_STATE_DIR/$1$TREE_AFTER_FILENAME_NO_SUFFIX\" \"$MASTER_STATE_DIR/$1$3\" > \"$MASTER_STATE_DIR/$1$4\""
		else
			## The || : forces the command to have a good result
			cmd="(grep -F -x -v -f \"$MASTER_STATE_DIR/$1$3\" \"$MASTER_STATE_DIR/$1$TREE_AFTER_FILENAME_NO_SUFFIX\" || :) > \"$MASTER_STATE_DIR/$1$4\""
		fi

		LogDebug "CMD: $cmd"
		eval $cmd
		retval=$?

		# Add delete failed file list to current delete list and then empty it
		if [ -f "$MASTER_STATE_DIR/$1$5" ]
		then
			cat "$MASTER_STATE_DIR/$1$5" >> "$MASTER_STATE_DIR/$1$4"
			rm -f "$MASTER_STATE_DIR/$1$5"
		fi

		return $retval
        else
		touch "$MASTER_STATE_DIR/$1$4"
		return $retval
        fi
}

# sync_update(source replica, destination replica, delete_list_filename)
function sync_update
{
        Log "Updating $2 replica."
	if [ "$1" == "master" ]
        then
                SOURCE_DIR="$MASTER_SYNC_DIR"
		ESC_SOURCE_DIR=$(EscapeSpaces "$MASTER_SYNC_DIR")
                DEST_DIR="$SLAVE_SYNC_DIR"
                ESC_DEST_DIR=$(EscapeSpaces "$SLAVE_SYNC_DIR")
                BACKUP_DIR="$SLAVE_BACKUP"
        else
                SOURCE_DIR="$SLAVE_SYNC_DIR"
		ESC_SOURCE_DIR=$(EscapeSpaces "$SLAVE_SYNC_DIR")
                DEST_DIR="$MASTER_SYNC_DIR"
		ESC_DEST_DIR=$(EscapeSpaces "$MASTER_SYNC_DIR")
                BACKUP_DIR="$MASTER_BACKUP"
        fi

	if [ "$REMOTE_SYNC" == "yes" ]
	then
	        CheckConnectivity3rdPartyHosts
	        CheckConnectivityRemoteHost
		if [ "$1" == "master" ]
		then
        		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $BACKUP_DIR --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from=\"$MASTER_STATE_DIR/$1$3\" --exclude-from=\"$MASTER_STATE_DIR/$2$3\" \"$SOURCE_DIR/\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_DEST_DIR/\" > $RUN_DIR/osync_update_$2_replica_$SCRIPT_PID 2>&1 &"
		else
        		rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $BACKUP_DIR --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from=\"$MASTER_STATE_DIR/$2$3\" --exclude-from=\"$MASTER_STATE_DIR/$1$3\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_SOURCE_DIR/\" \"$DEST_DIR/\" > $RUN_DIR/osync_update_$2_replica_$SCRIPT_PID 2>&1 &"
		fi
	else
        	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $RSYNC_ARGS $SYNC_OPTS $BACKUP_DIR --exclude \"$OSYNC_DIR\" $RSYNC_EXCLUDE --exclude-from=\"$MASTER_STATE_DIR/$1$3\" --exclude-from=\"$MASTER_STATE_DIR/$2$3\" \"$SOURCE_DIR/\" \"$DEST_DIR/\" > $RUN_DIR/osync_update_$2_replica_$SCRIPT_PID 2>&1 &"
	fi
	LogDebug "RSYNC_CMD: $rsync_cmd"
	eval "$rsync_cmd"
        child_pid=$!
        WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
        retval=$?
	if [ $verbose -eq 1 ] && [ -f $RUN_DIR/osync_update_$2_replica_$SCRIPT_PID ]
        then
                Log "List:\n$(cat $RUN_DIR/osync_update_$2_replica_$SCRIPT_PID)"
        fi

        if [ $retval != 0 ] && [ $retval != 24 ]
        then
                LogError "Updating $2 replica failed. Stopping execution."
		if [ $verbose -eq 0 ] && [ -f $RUN_DIR/osync_update_$2_replica_$SCRIPT_PID ]
		then
			LogError "Rsync output:\n$(cat $RUN_DIR/osync_update_$2_replica_$SCRIPT_PID)"
		fi
		exit $retval
	else
                Log "Updating $2 replica succeded."
		return 0
        fi
}

# delete_local(replica dir, delete file list, delete dir, delete failed file)
function _delete_local
{
	## On every run, check wheter the next item is already deleted because it's included in a directory already deleted
	previous_file=""
	OLD_IFS=$IFS
	IFS=$'\r\n'
        for files in $(cat "$MASTER_STATE_DIR/$2")
        do
                if [[ "$files" != "$previous_file/"* ]] && [ "$files" != "" ]
		then
                        if [ "$SOFT_DELETE" != "no" ]
                        then
                        	if [ ! -d "$REPLICA_DIR$3" ]
                        	then
                                	mkdir -p "$REPLICA_DIR$3"
					if [ $? != 0 ]
					then
						LogError "Cannot create replica deletion directory."
					fi
                        	fi

                               	if [ $verbose -eq 1 ]
				then
					Log "Soft deleting $REPLICA_DIR$files"
				fi

				if [ $dryrun -ne 1 ]
				then
					mv "$REPLICA_DIR$files" "$REPLICA_DIR$3"
					if [ $? != 0 ]
					then
						LogError "Cannot move $REPLICA_DIR$files to deletion directory."
						echo "$files" >> "$MASTER_STATE_DIR/$4"
					fi
				fi
                        else
                                if [ $verbose -eq 1 ]
				then
					Log "Deleting $REPLICA_DIR$files"
				fi

				if [ $dryrun -ne 1 ]
				then
                                	rm -rf "$REPLICA_DIR$files"
					if [ $? != 0 ]
					then
						LogError "Cannot delete $REPLICA_DIR$files"
						echo "$files" >> "$MASTER_STATE_DIR/$4"
					fi
                        	fi
			fi
			previous_file="$files"
		fi
        done
	IFS=$OLD_IFS
}

# delete_remote(replica dir, delete file list, delete dir, delete fail file list)
function _delete_remote
{
	## This is a special coded function. Need to redelcare local functions on remote host, passing all needed variables as escaped arguments to ssh command.
	## Anything beetween << ENDSSH and ENDSSH will be executed remotely

	# Additionnaly, we need to copy the deletetion list to the remote state folder
	ESC_DEST_DIR="$(EscapeSpaces "$SLAVE_STATE_DIR")"
       	rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" \"$MASTER_STATE_DIR/$2\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_DEST_DIR/\" > $RUN_DIR/osync_remote_deletion_list_copy_$SCRIPT_PID 2>&1"
	LogDebug "RSYNC_CMD: $rsync_cmd"
	eval $rsync_cmd 2>> "$LOG_FILE"
	if [ $? != 0 ]
	then
		LogError "Cannot copy the deletion list to remote replica."
		if [ -f $RUN_DIR/osync_remote_deletion_list_copy_$SCRIPT_PID ]
		then
			LogError "$(cat $RUN_DIR/osync_remote_deletion_list_copy_$SCRIPT_PID)"
		fi
		exit 1
	fi

$SSH_CMD error_alert=0 sync_on_changes=$sync_on_changes silent=$silent DEBUG=$DEBUG dryrun=$dryrun verbose=$verbose COMMAND_SUDO=$COMMAND_SUDO FILE_LIST="$(EscapeSpaces "$SLAVE_STATE_DIR/$2")" REPLICA_DIR="$(EscapeSpaces "$REPLICA_DIR")" DELETE_DIR="$(EscapeSpaces "$DELETE_DIR")" FAILED_DELETE_LIST="$(EscapeSpaces "$SLAVE_STATE_DIR/$4")" 'bash -s' << 'ENDSSH' > $RUN_DIR/osync_remote_deletion_$SCRIPT_PID 2>&1 &

	## The following lines are executed remotely
	function Log
	{
        	if [ $sync_on_changes -eq 1 ]
        	then
                	prefix="$(date) - "
        	else
                	prefix="R-TIME: $SECONDS - "
        	fi

        	if [ $silent -eq 0 ]
        	then
                	echo -e "$prefix$1"
        	fi
	}

	function LogError
	{
        	Log "$1"
        	error_alert=1
	}

	## Empty earlier failed delete list
	> "$FAILED_DELETE_LIST"

        ## On every run, check wheter the next item is already deleted because it's included in a directory already deleted
        previous_file=""
	OLD_IFS=$IFS
	IFS=$'\r\n'
        for files in $(cat "$FILE_LIST")
        do
                if [[ "$files" != "$previous_file/"* ]] && [ "$files" != "" ]
                then
                        if [ ! -d "$REPLICA_DIR$DELETE_DIR" ]
                                then
                                        $COMMAND_SUDO mkdir -p "$REPLICA_DIR$DELETE_DIR"
                                        if [ $? != 0 ]
                                        then
                                                LogError "Cannot create replica deletion directory."
                                        fi
                                fi

                        if [ "$SOFT_DELETE" != "no" ]
                        then
                                if [ $verbose -eq 1 ]
                                then
                                        Log "Soft deleting $REPLICA_DIR$files"
                                fi

                                if [ $dryrun -ne 1 ]
                                then
                                        $COMMAND_SUDO mv "$REPLICA_DIR$files" "$REPLICA_DIR$DELETE_DIR"
					if [ $? != 0 ]
					then
						LogError "Cannot move $REPLICA_DIR$files to deletion directory."
						echo "$files" >> "$FAILED_DELETE_LIST"
					fi
                                fi
                        else
                                if [ $verbose -eq 1 ]
                                then
                                        Log "Deleting $REPLICA_DIR$files"
                                fi

                                if [ $dryrun -ne 1 ]
                                then
                                        $COMMAND_SUDO rm -rf "$REPLICA_DIR$files"
					if [ $? != 0 ]
					then
						LogError "Cannot delete $REPLICA_DIR$files"
						echo "$files" >> "$SLAVE_STATE_DIR/$FAILED_DELETE_LIST"
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
        ESC_SOURCE_FILE="$(EscapeSpaces "$SLAVE_STATE_DIR/$4")"
        rsync_cmd="$(type -p $RSYNC_EXECUTABLE) --rsync-path=\"$RSYNC_PATH\" $SYNC_OPTS -e \"$RSYNC_SSH_CMD\" $REMOTE_USER@$REMOTE_HOST:\"$ESC_SOURCE_FILE\" \"$MASTER_STATE_DIR\" > $RUN_DIR/osync_remote_failed_deletion_list_copy_$SCRIPT_PID"
	LogDebug "RSYNC_CMD: $rsync_cmd"
        eval $rsync_cmd 2>> "$LOG_FILE"
        if [ $? != 0 ]
        then
                LogError "Cannot copy back the failed deletion list to master replica."
                if [ -f $RUN_DIR/osync_remote_failed_deletion_list_copy_$SCRIPT_PID ]
                then
                        LogError "$(cat $RUN_DIR/osync_remote_failed_deletion_list_copy_$SCRIPT_PID)"
                fi
                exit 1
        fi



	exit $?
}


# delete_propagation(replica name, deleted_list_filename, deleted_failed_file_list)
# replica name = "master" / "slave"
function deletion_propagation
{
	Log "Propagating deletions to $1 replica."

	if [ "$1" == "master" ]
	then
		REPLICA_DIR="$MASTER_SYNC_DIR"
		DELETE_DIR="$MASTER_DELETE_DIR"

		_delete_local "$REPLICA_DIR" "slave$2" "$DELETE_DIR" "slave$3" &
		child_pid=$!
		WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
		retval=$?
		if [ $retval != 0 ]
		then
			LogError "Deletion on replica $1 failed."
                	exit 1
        	fi
	else
		REPLICA_DIR="$SLAVE_SYNC_DIR"
		DELETE_DIR="$SLAVE_DELETE_DIR"

		if [ "$REMOTE_SYNC" == "yes" ]
		then
			_delete_remote "$REPLICA_DIR" "master$2" "$DELETE_DIR" "master$3" &
		else
			_delete_local "$REPLICA_DIR" "master$2" "$DELETE_DIR" "master$3" &
		fi
		child_pid=$!
		WaitForCompletion $child_pid $SOFT_MAX_EXEC_TIME $HARD_MAX_EXEC_TIME
		retval=$?
                if [ $retval == 0 ]
                then
			if [ -f $RUN_DIR/osync_remote_deletion_$SCRIPT_PID ] && [ $verbose -eq 1 ]
			then
				Log "Remote:\n$(cat $RUN_DIR/osync_remote_deletion_$SCRIPT_PID)"
			fi
			return $retval
		else
			LogError "Deletion on remote system failed."
			if [ -f $RUN_DIR/osync_remote_deletion_$SCRIPT_PID ]
			then
				LogError "Remote:\n$(cat $RUN_DIR/osync_remote_deletion_$SCRIPT_PID)"
			fi
			exit 1
                fi
	fi
}

###### Sync function in 5 steps of each 2 runs (functions above)
######
###### Step 1: Create current tree list for master and slave replicas (Steps 1M and 1S)
###### Step 2: Create deleted file list for master and slave replicas (Steps 2M and 2S)
###### Step 3: Update master and slave replicas (Steps 3M and 3S, order depending on conflict prevalence)
###### Step 4: Deleted file propagation to master and slave replicas (Steps 4M and 4S)
###### Step 5: Create after run tree list for master and slave replicas (Steps 5M and 5S)

function Sync
{
        Log "Starting synchronization task."
        CheckConnectivity3rdPartyHosts
        CheckConnectivityRemoteHost

	if [ -f "$MASTER_LAST_ACTION" ] && [ "$RESUME_SYNC" != "no" ]
	then
		resume_sync=$(cat "$MASTER_LAST_ACTION")
		if [ -f "$MASTER_RESUME_COUNT" ]
		then
			resume_count=$(cat "$MASTER_RESUME_COUNT")
		else
			resume_count=0
		fi

		if [ $resume_count -lt $RESUME_TRY ]
		then
			if [ "$resume_sync" != "sync.success" ]
			then
				Log "WARNING: Trying to resume aborted osync execution on $($STAT_CMD "$MASTER_LAST_ACTION") at task [$resume_sync]. [$resume_count] previous tries."
				echo $(($resume_count+1)) > "$MASTER_RESUME_COUNT"
			else
				resume_sync=none
			fi
		else
			Log "Will not resume aborted osync execution. Too much resume tries [$resume_count]."
			echo "noresume" > "$MASTER_LAST_ACTION"
			echo "0" > "$MASTER_RESUME_COUNT"
			resume_sync=none
		fi
	else
		resume_sync=none
	fi


	################################################################################################################################################# Actual sync begins here

	## This replaces the case statement because ;& operator is not supported in bash 3.2... Code is more messy than case :(
	if [ "$resume_sync" == "none" ] || [ "$resume_sync" == "noresume" ] || [ "$resume_sync" == "master-replica-tree.fail" ]
	then
		#master_tree_current
		tree_list "$MASTER_SYNC_DIR" master "$TREE_CURRENT_FILENAME"
		if [ $? == 0 ]
		then
			echo "${SYNC_ACTION[0]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[0]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[0]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[1]}.fail" ]
	then
		#slave_tree_current
		tree_list "$SLAVE_SYNC_DIR" slave "$TREE_CURRENT_FILENAME"
		if [ $? == 0 ]
		then
			echo "${SYNC_ACTION[1]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[1]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[1]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[2]}.fail" ]
	then
		delete_list master "$TREE_AFTER_FILENAME" "$TREE_CURRENT_FILENAME" "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]
		then
			echo "${SYNC_ACTION[2]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNc_ACTION[2]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[2]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.fail" ]
	then
		delete_list slave "$TREE_AFTER_FILENAME" "$TREE_CURRENT_FILENAME" "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]
		then
			echo "${SYNC_ACTION[3]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[3]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
 	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.fail" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.fail" ]
	then
		if [ "$CONFLICT_PREVALANCE" != "master" ]
		then
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.fail" ]
			then
				sync_update slave master "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]
				then
					echo "${SYNC_ACTION[4]}.success" > "$MASTER_LAST_ACTION"
				else
					echo "${SYNC_ACTION[4]}.fail" > "$MASTER_LAST_ACTION"
				fi
				resume_sync="resumed"
			fi
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.fail" ]
			then
				sync_update master slave "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]
				then
					echo "${SYNC_ACTION[5]}.success" > "$MASTER_LAST_ACTION"
				else
					echo "${SYNC_ACTION[5]}.fail" > "$MASTER_LAST_ACTION"
				fi
				resume_sync="resumed"
			fi
		else
			if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[3]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.fail" ]
                        then
                                sync_update master slave "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]
				then
					echo "${SYNC_ACTION[5]}.success" > "$MASTER_LAST_ACTION"
				else
					echo "${SYNC_ACTION[5]}.fail" > "$MASTER_LAST_ACTION"
				fi
                                resume_sync="resumed"
                        fi
                        if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.fail" ]
                        then
                                sync_update slave master "$DELETED_LIST_FILENAME"
				if [ $? == 0 ]
				then
					echo "${SYNC_ACTION[4]}.success" > "$MASTER_LAST_ACTION"
				else
					echo "${SYNC_ACTION[4]}.fail" > "$MASTER_LAST_ACTION"
				fi
                                resume_sync="resumed"
                        fi
		fi
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[5]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[4]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[6]}.fail" ]
	then
		deletion_propagation slave "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]
		then
			echo "${SYNC_ACTION[6]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[6]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[6]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[7]}.fail" ]
	then
		deletion_propagation master "$DELETED_LIST_FILENAME" "$FAILED_DELETE_LIST_FILENAME"
		if [ $? == 0 ]
		then
			echo "${SYNC_ACTION[7]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[7]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[7]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[8]}.fail" ]
	then
		#master_tree_after
		tree_list "$MASTER_SYNC_DIR" master "$TREE_AFTER_FILENAME"
		if [ $? == 0 ]
		then
			echo "${SYNC_ACTION[8]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[8]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi
	if [ "$resume_sync" == "resumed" ] || [ "$resume_sync" == "${SYNC_ACTION[8]}.success" ] || [ "$resume_sync" == "${SYNC_ACTION[9]}.fail" ]
	then
		#slave_tree_after
		tree_list "$SLAVE_SYNC_DIR" slave "$TREE_AFTER_FILENAME"
		if [ $? == 0 ]
		then
			echo "${SYNC_ACTION[9]}.success" > "$MASTER_LAST_ACTION"
		else
			echo "${SYNC_ACTION[9]}.fail" > "$MASTER_LAST_ACTION"
		fi
		resume_sync="resumed"
	fi

	Log "Finished synchronization task."
	echo "${SYNC_ACTION[10]}" > "$MASTER_LAST_ACTION"

	echo "0" > "$MASTER_RESUME_COUNT"
}

function SoftDelete
{
	if [ "$CONFLICT_BACKUP" != "no" ] && [ $CONFLICT_BACKUP_DAYS -ne 0 ]
	then
		if [ -d "$MASTER_SYNC_DIR$MASTER_BACKUP_DIR" ]
		then
			if [ $dryrun -eq 1 ]
			then
				Log "Listing backups older than $CONFLICT_BACKUP_DAYS days on master replica. Won't remove anything."
				if [ $verbose -eq 1 ]
				then
					$FIND_CMD "$MASTER_SYNC_DIR$MASTER_BACKUP_DIR/" -ctime +$CONFLICT_BACKUP_DAYS &
				else
					$FIND_CMD "$MASTER_SYNC_DIR$MASTER_BACKUP_DIR/" -ctime +$CONFLICT_BACKUP_DAYS > /dev/null &
				fi
			else
				Log "Removing backups older than $CONFLICT_BACKUP_DAYS days on master replica."
				$FIND_CMD "$MASTER_SYNC_DIR$MASTER_BACKUP_DIR/" -ctime +$CONFLICT_BACKUP_DAYS -exec rm -rf '{}' \; &
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
		elif [ -d "$MASTER_SYNC_DIR$MASTER_BACKUP_DIR" ] && ! [ -w "$MASTER_SYNC_DIR$MASTER_BACKUP_DIR" ]
		then
			LogError "Warning: Master replica conflict backup dir [$MASTER_SYNC_DIR$MASTER_BACKUP_DIR] isn't writable. Cannot clean old files."
		fi

		if [ "$REMOTE_SYNC" == "yes" ]
		then
        		CheckConnectivity3rdPartyHosts
	        	CheckConnectivityRemoteHost
			if [ $dryrun -eq 1 ]
			then
				Log "Listing backups older than $CONFLICT_BACKUP_DAYS days on slave replica. Won't remove anything."
				eval "$SSH_CMD \"if [ -w \\\"$SLAVE_SYNC_DIR$SLAVE_BACKUP_DIR\\\" ]; then $COMMAND_SUDO $REMOTE_FIND_CMD \\\"$SLAVE_SYNC_DIR$SLAVE_BACKUP_DIR/\\\" -ctime +$CONFLICT_BACKUP_DAYS; fi\""
			else
				Log "Removing backups older than $CONFLICT_BACKUP_DAYS days on remote slave replica."
				eval "$SSH_CMD \"if [ -w \\\"$SLAVE_SYNC_DIR$SLAVE_BACKUP_DIR\\\" ]; then $COMMAND_SUDO $REMOTE_FIND_CMD \\\"$SLAVE_SYNC_DIR$SLAVE_BACKUP_DIR/\\\" -ctime +$CONFLICT_BACKUP_DAYS -exec rm -rf '{}' \;; fi\""
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
			if [ -w "$SLAVE_SYNC_DIR$SLAVE_BACKUP_DIR" ]
			then
				if [ $dryrun -eq 1 ]
				then
					Log "Listing backups older than $CONFLICT_BACKUP_DAYS days on slave replica. Won't remove anything."
					$FIND_CMD "$SLAVE_SYNC_DIR$SLAVE_BACKUP_DIR/" -ctime +$CONFLICT_BACKUP_DAYS
				else
					Log "Removing backups older than $CONFLICT_BACKUP_DAYS days on slave replica."
					$FIND_CMD "$SLAVE_SYNC_DIR$SLAVE_BACKUP_DIR/" -ctime +$CONFLICT_BACKUP_DAYS -exec rm -rf '{}' \;
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
			elif [ -d "$SLAVE_SYNC_DIR$SLAVE_BACKUP_DIR" ] && ! [ -w "$SLAVE_SYNC_DIR$SLAVE_BACKUP_DIR" ]
			then
				LogError "Warning: Slave replica conflict backup dir [$SLAVE_SYNC_DIR$SLAVE_BACKUP_DIR] isn't writable. Cannot clean old files."
			fi
		fi
	fi

	if [ "$SOFT_DELETE" != "no" ] && [ $SOFT_DELETE_DAYS -ne 0 ]
	then
		if [ -d "$MASTER_SYNC_DIR$MASTER_DELETE_DIR" ]
		then
			if [ $dryrun -eq 1 ]
			then
				Log "Listing soft deleted items older than $SOFT_DELETE_DAYS days on master replica. Won't remove anything."
				$FIND_CMD "$MASTER_SYNC_DIR$MASTER_DELETE_DIR/" -ctime +$SOFT_DELETE_DAYS
			else
				Log "Removing soft deleted items older than $SOFT_DELETE_DAYS days on master replica."
				$FIND_CMD "$MASTER_SYNC_DIR$MASTER_DELETE_DIR/" -ctime +$SOFT_DELETE_DAYS -exec rm -rf '{}' \;
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
		elif [ -d "$MASTER_SYNC_DIR$MASTER_DELETE_DIR" ] && ! [ -w "$MASTER_SYNC_DIR$MASTER_DELETE_DIR" ]
		then
			LogError "Warning: Master replica deletion backup dir [$MASTER_SYNC_DIR$MASTER_DELETE_DIR] isn't writable. Cannot clean old files."
		fi

		if [ "$REMOTE_SYNC" == "yes" ]
		then
			CheckConnectivity3rdPartyHosts
        		CheckConnectivityRemoteHost
			if [ $dryrun -eq 1 ]
			then
				Log "Listing soft deleted items older than $SOFT_DELETE_DAYS days on slave replica. Won't remove anything."
				eval "$SSH_CMD \"if [ -w \\\"$SLAVE_SYNC_DIR$SLAVE_DELETE_DIR\\\" ]; then $COMMAND_SUDO $REMOTE_FIND_CMD \\\"$SLAVE_SYNC_DIR$SLAVE_DELETE_DIR/\\\" -ctime +$SOFT_DELETE_DAYS; fi\""
			else
				Log "Removing soft deleted items older than $SOFT_DELETE_DAYS days on remote slave replica."
				eval "$SSH_CMD \"if [ -w \\\"$SLAVE_SYNC_DIR$SLAVE_DELETE_DIR\\\" ]; then $COMMAND_SUDO $REMOTE_FIND_CMD \\\"$SLAVE_SYNC_DIR$SLAVE_DELETE_DIR/\\\" -ctime +$SOFT_DELETE_DAYS -exec rm -rf '{}' \;; fi\""
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
			if [ -w "$SLAVE_SYNC_DIR$SLAVE_DELETE_DIR" ]
			then
				if [ $dryrun -eq 1 ]
				then
					Log "Listing soft deleted items older than $SOFT_DELETE_DAYS days on slave replica. Won't remove anything."
					$FIND_CMD "$SLAVE_SYNC_DIR$SLAVE_DELETE_DIR/" -ctime +$SOFT_DELETE_DAYS
				else
					Log "Removing soft deleted items older than $SOFT_DELETE_DAYS days on slave replica."
					$FIND_CMD "$SLAVE_SYNC_DIR$SLAVE_DELETE_DIR/" -ctime +$SOFT_DELETE_DAYS -exec rm -rf '{}' \;
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
			elif [ -d "$SLAVE_SYNC_DIR$SLAVE_DELETE_DIR" ] && ! [ -w "$SLAVE_SYNC_DIR$SLAVE_DELETE_DIR" ]
			then
				LogError "Warning: Slave replica deletion backup dir [$SLAVE_SYNC_DIR$SLAVE_DELETE_DIR] isn't writable. Cannot clean old files."
			fi
		fi
	fi
}

function Init
{
        # Set error exit code if a piped command fails
        set -o pipefail
        set -o errtrace

	# Do not use exit and quit traps if osync runs in monitor mode
	if [ $sync_on_changes -eq 0 ]
	then
	        trap TrapStop SIGINT SIGKILL SIGHUP SIGTERM SIGQUIT
		trap TrapQuit SIGKILL EXIT
	else
		trap TrapQuit SIGTERM EXIT SIGKILL SIGHUP SIGQUIT
	fi

        if [ "$DEBUG" == "yes" ]
        then
                trap 'TrapError ${LINENO} $?' ERR
        fi

        if [ "$LOGFILE" == "" ]
        then
                if [ -w /var/log ]
		then
			LOG_FILE=/var/log/osync_$SYNC_ID.log
		else
			LOG_FILE=./osync_$SYNC_ID.log
		fi
        else
                LOG_FILE="$LOGFILE"
        fi

        MAIL_ALERT_MSG="Warning: Execution of osync instance $OSYNC_ID (pid $SCRIPT_PID) as $LOCAL_USER@$LOCAL_HOST produced errors on $(date)."

	## Test if slave dir is a ssh uri, and if yes, break it down it its values
        if [ "${SLAVE_SYNC_DIR:0:6}" == "ssh://" ]
        then
                REMOTE_SYNC="yes"

                # remove leadng 'ssh://'
                uri=${SLAVE_SYNC_DIR#ssh://*}
                # remove everything after '@'
                _first_part=${uri%@*}
                REMOTE_USER=${_first_part%;*}
                #fingerprint=${_first_part#*fingerprint=}
		if [ "$SSH_RSA_PRIVATE_KEY" == "" ]
		then
			SSH_RSA_PRIVATE_KEY=~/.ssh/id_rsa
		fi
                # remove everything before '@'
                _last_part=${uri#*@}
                _last_part2=${_last_part%%/*}
		# remove last part if no port defined
		REMOTE_HOST=${_last_part2%%:*}
		if [[ "$_last_part2" == *":"* ]]
		then
			REMOTE_PORT=${_last_part2##*:}
		else
			REMOTE_PORT=22
		fi
		SLAVE_SYNC_DIR=${_last_part#*/}
        fi

	## Make sure there is only one trailing slash on path
	MASTER_SYNC_DIR="${MASTER_SYNC_DIR%/}/"
	SLAVE_SYNC_DIR="${SLAVE_SYNC_DIR%/}/"

	MASTER_STATE_DIR="$MASTER_SYNC_DIR$OSYNC_DIR/state"
	SLAVE_STATE_DIR="$SLAVE_SYNC_DIR$OSYNC_DIR/state"
	STATE_DIR="$OSYNC_DIR/state"
	MASTER_LOCK="$MASTER_STATE_DIR/lock"
	SLAVE_LOCK="$SLAVE_STATE_DIR/lock"

	## Working directories to keep backups of updated / deleted files
	MASTER_BACKUP_DIR="$OSYNC_DIR/backups"
	MASTER_DELETE_DIR="$OSYNC_DIR/deleted"
	SLAVE_BACKUP_DIR="$OSYNC_DIR/backups"
	SLAVE_DELETE_DIR="$OSYNC_DIR/deleted"

	## SSH compression
	if [ "$SSH_COMPRESSION" != "no" ]
	then
		SSH_COMP=-C
	else
		SSH_COMP=
	fi

	## Define which runner (local bash or distant ssh) to use for standard commands and rsync commands
	if [ "$REMOTE_SYNC" == "yes" ]
	then
		SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
		SCP_CMD="$(type -p scp) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY -P $REMOTE_PORT"
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
                        RSYNC_PATH="sudo $RSYNC_REMOTE_PATH/$RSYNC_EXECUTABLE"
                else
                        RSYNC_PATH="sudo $RSYNC_EXECUTABLE"
                fi
                COMMAND_SUDO="sudo"
        else
                if [ "$RSYNC_REMOTE_PATH" != "" ]
                then
                        RSYNC_PATH="$RSYNC_REMOTE_PATH/$RSYNC_EXECUTABLE"
                else
                        RSYNC_PATH="$RSYNC_EXECUTABLE"
                fi
                COMMAND_SUDO=""
        fi

	## Set rsync default arguments
	RSYNC_ARGS="-rlptgoD"

        if [ "$PRESERVE_ACL" == "yes" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS" -A"
        fi
        if [ "$PRESERVE_XATTR" == "yes" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS" -X"
        fi
        if [ "$RSYNC_COMPRESS" == "yes" ]
        then
                RSYNC_ARGS=$RSYNC_ARGS" -z"
        fi
	if [ "$COPY_SYMLINKS" == "yes" ]
	then
		RSYNC_ARGS=$RSYNC_ARGS" -L"
	fi
	if [ "$KEEP_DIRLINKS" == "yes" ]
	then
		RSYNC_ARGS=$RSYNC_ARGS" -K"
	fi
	if [ "$PRESERVE_HARDLINKS" == "yes" ]
	then
		RSYNC_ARGS=$RSYNC_ARGS" -H"
	fi
	if [ $dryrun -eq 1 ]
	then
		RSYNC_ARGS=$RSYNC_ARGS" -n"
		DRY_WARNING="/!\ DRY RUN"
	fi

	if [ "$BANDWIDTH" != "" ] && [ "$BANDWIDTH" != "0" ]
	then
		RSYNC_ARGS=$RSYNC_ARGS" --bwlimit=$BANDWIDTH"
	fi

	## Set sync only function arguments for rsync
	SYNC_OPTS="-u"

	if [ $verbose -eq 1 ]
	then
		SYNC_OPTS=$SYNC_OPTS"i"
	fi

	if [ $stats -eq 1 ]
	then
		SYNC_OPTS=$SYNC_OPTS" --stats"
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

	## Add Rsync exclude patterns
	RsyncExcludePattern
	## Add Rsync exclude from file
	RsyncExcludeFrom

	## Filenames for state files
	if [ $dryrun -eq 1 ]
	then
		dry_suffix="-dry"
	fi

	TREE_CURRENT_FILENAME="-tree-current-$SYNC_ID$dry_suffix"
	TREE_AFTER_FILENAME="-tree-after-$SYNC_ID$dry_suffix"
	TREE_AFTER_FILENAME_NO_SUFFIX="-tree-after-$SYNC_ID"
	DELETED_LIST_FILENAME="-deleted-list-$SYNC_ID$dry_suffix"
	FAILED_DELETE_LIST_FILENAME="-failed-delete-$SYNC_ID$dry_suffix"
	MASTER_LAST_ACTION="$MASTER_STATE_DIR/last-action-$SYNC_ID$dry_suffix"
	MASTER_RESUME_COUNT="$MASTER_STATE_DIR/resume-count-$SYNC_ID$dry_suffix"

	## Sync function actions (0-9)
	SYNC_ACTION=(
	'master-replica-tree'
	'slave-replica-tree'
	'master-deleted-list'
	'slave-deleted-list'
	'update-master-replica'
	'update-slave-replica'
	'delete-propagation-slave'
	'delete-propagation-master'
	'master-replica-tree-after'
	'slave-replica-tree-after'
	'sync.success'
	)

        ## Set compression executable and extension
	COMPRESSION_LEVEL=9
        if type -p xz > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| xz -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.xz
        elif type -p lzma > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| lzma -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.lzma
        elif type -p pigz > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| pigz -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.gz
                COMPRESSION_OPTIONS=--rsyncable
        elif type -p gzip > /dev/null 2>&1
        then
                COMPRESSION_PROGRAM="| gzip -$COMPRESSION_LEVEL"
                COMPRESSION_EXTENSION=.gz
                COMPRESSION_OPTIONS=--rsyncable
        else
		COMPRESSION_PROGRAM=
                COMPRESSION_EXTENSION=
        fi
	ALERT_LOG_FILE="$ALERT_LOG_FILE$COMPRESSION_EXTENSION"
}

function InitLocalOSSettings
{
	## If running Msys, find command of windows is used instead of msys one
	if [ "$LOCAL_OS" == "msys" ]
	then
		FIND_CMD=$(dirname $BASH)/find
	else
		FIND_CMD=find
	fi

	## Stat command has different syntax on Linux and FreeBSD/MacOSX
	if [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "BSD" ]
	then
		STAT_CMD="stat -f \"%Sm\""
	else
		STAT_CMD="stat --format %y"
	fi

	## Ping command has different syntax on Msys and others
	if [ "$LOCAL_OS" == "msys" ]
	then
		PING_CMD="ping -n 2"
	else
		PING_CMD="ping -c 2 -i .2"
	fi
}

function InitRemoteOSSettings
{
	## MacOSX does not use the -E parameter like Linux or BSD does (-E is mapped to extended attrs instead of preserve executability)
	if [ "$LOCAL_OS" != "MacOSX" ] && [ "$REMOTE_OS" != "MacOSX" ]
	then
		RSYNC_ARGS=$RSYNC_ARGS" -E"
	fi

	if [ "$REMOTE_OS" == "msys" ]
	then
		REMOTE_FIND_CMD=$(dirname $BASH)/find
	else
		REMOTE_FIND_CMD=find
	fi
}

function Main
{
	CreateOsyncDirs
	LockDirectories
	Sync
}

function Usage
{
	echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
	echo $AUTHOR
	echo $CONTACT
	echo ""
	echo "You may use Osync with a full blown configuration file, or use its default options for quick command line sync."
	echo "Usage: osync /path/to/config/file [OPTIONS]"
	echo "or     osync --master=/path/to/master/replica --slave=/path/to/slave/replica [OPTIONS] [QUICKSYNC OPTIONS]"
	echo "or     osync --master=/path/to/master/replica --slave=ssh://backupuser@remotehost.com[:portnumber]//path/to/slave/replica [OPTIONS] [QUICKSYNC OPTIONS]"
	echo ""
	echo "[OPTIONS]"
	echo "--dry             Will run osync without actually doing anything; just testing"
	echo "--silent          Will run osync without any output to stdout, used for cron jobs"
	echo "--verbose         Increases output"
	echo "--stats           Adds rsync transfer statistics to verbose output"
	echo "--no-maxtime      Disables any soft and hard execution time checks"
	echo "--force-unlock    Will override any existing active or dead locks on master and slave replica"
	echo "--on-changes      Will launch a sync task after a short wait period if there is some file activity on master replica. You should try daemon mode instead"
	echo ""
	echo "[QUICKSYNC OPTIONS]"
	echo "--master=\"\"	Master replica path. Will contain state and backup directory (is mandatory)"
	echo "--slave=\"\" 	Local or remote slave replica path. Can be a ssh uri like ssh://user@host.com:22//path/to/slave/replica (is mandatory)"
	echo "--rsakey=\"\"	Alternative path to rsa private key for ssh connection to slave replica"
	echo "--sync-id=\"\"	Optional sync task name to identify this synchronization task when using multiple slaves"
	exit 128
}

function SyncOnChanges
{
	if ! type -p inotifywait > /dev/null 2>&1
	then
        	LogError "No inotifywait command found. Cannot monitor changes."
        	exit 1
	fi

	Log "#### Running Osync in file monitor mode."

	while true
	do
		if [ "$ConfigFile" != "" ]
		then
        		cmd="bash $osync_cmd \"$ConfigFile\" $opts --no-locks"
		else
			cmd="bash $osync_cmd $opts --no-locks"
		fi
		eval $cmd
		retval=$?
		if [ $retval != 0 ]
		then
			LogError "osync child exited with error."
			exit $retval
		fi

		Log "#### Monitoring now."
        	inotifywait --exclude $OSYNC_DIR $RSYNC_EXCLUDE -qq -r -e create -e modify -e delete -e move -e attrib "$MASTER_SYNC_DIR" &
		sub_pid=$!
		wait $sub_pid
		Log "#### Changes detected, waiting $MIN_WAIT seconds before running next sync."
		sleep $MIN_WAIT
	done

}

# Comand line argument flags
dryrun=0
silent=0
verbose=0
stats=0
force_unlock=0
no_maxtime=0
# Alert flags
opts=""
soft_alert_total=0
error_alert=0
soft_stop=0
quick_sync=0
sync_on_changes=0
nolocks=0
osync_cmd=$0

if [ $# -eq 0 ]
then
	Usage
fi

for i in "$@"
do
	case $i in
		--dry)
		dryrun=1
		opts=$opts" --dry"
		;;
		--silent)
		silent=1
		opts=$opts" --silent"
		;;
		--verbose)
		verbose=1
		opts=$opts" --verbose"
		;;
		--stats)
		stats=1
		opts=$opts" --stats"
		;;
		--force-unlock)
		force_unlock=1
		opts=$opts" --force-unlock"
		;;
		--no-maxtime)
		no_maxtime=1
		opts=$opts" --no-maxtime"
		;;
		--help|-h|--version|-v)
		Usage
		;;
		--master=*)
		quick_sync=$(($quick_sync + 1))
		no_maxtime=1
		MASTER_SYNC_DIR=${i##*=}
		opts=$opts" --master=\"$MASTER_SYNC_DIR\""
		;;
		--slave=*)
		quick_sync=$(($quick_sync + 1))
		SLAVE_SYNC_DIR=${i##*=}
		opts=$opts" --slave=\"$SLAVE_SYNC_DIR\""
		no_maxtime=1
		;;
		--rsakey=*)
		SSH_RSA_PRIVATE_KEY=${i##*=}
		opts=$opts" --rsakey=\"$SSH_RSA_PRIVATE_KEY\""
		;;
		--sync-id=*)
		SYNC_ID=${i##*=}
		opts=$opts" --sync-id=\"$SYNC_ID\""
		;;
		--on-changes)
		sync_on_changes=1
		;;
		--no-locks)
		nolocks=1
		;;
	esac
done

# Remove leading space if there is one
opts="${opts# *}"

GetLocalOS
InitLocalOSSettings
CheckEnvironment
if [ $? == 0 ]
then

	## Here we set default options for quicksync tasks when no configuration file is provided.

	if [ $quick_sync -eq 2 ]
	then
		if [ "$SYNC_ID" == "" ]
		then
			SYNC_ID="quicksync task"
		fi
		MINIMUM_SPACE=1024
		REMOTE_SYNC=no
		CONFLICT_BACKUP_DAYS=30
		SOFT_DELETE_DAYS=30
		RESUME_TRY=1
		MIN_WAIT=30
	else
		ConfigFile="$1"
		LoadConfigFile "$ConfigFile"
	fi
	Init
	GetRemoteOS
	InitRemoteOSSettings
	if [ $sync_on_changes -eq 1 ]
	then
		SyncOnChanges
	else
		DATE=$(date)
		Log "-------------------------------------------------------------"
		Log "$DRY_WARNING $DATE - $PROGRAM $PROGRAM_VERSION script begin."
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
	fi
else
	LogError "Environment not suitable to run osync."
	exit 1
fi
