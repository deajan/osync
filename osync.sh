#!/bin/bash

##### Two way sync script
##### (C) 2013 by Orsiris "Ozy" de Jong | ozy@badministrateur.com
OSYNC_VERSION=0.0 #### Build 1806201301

DEBUG=yes
SCRIPT_PID=$$

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

## Flags
error_alert=0
dryrun=0
silent=0

function Log
{
	echo "TIME: $SECONDS - $1" >> "$LOG_FILE"
	if [ $silent -eq 0 ]
	then
		echo "TIME: $SECONDS - $1"
	fi
}

function LogError
{
	Log "$1"
	error_alert=1
}

function TrapError
{
	local JOB="$0"
	local LINE="$1"
	local CODE="${2:-1}"
	if [ $silent -eq 0 ]
	then
		echo " /!\ Error in ${JOB}: Near line ${LINE}, exit code ${CODE}"
	fi
}

function TrapStop
{
	LogError " /!\ WARNING: Manual exit of sync script. Synchronization may be in inconsistent state."
	if [ "$DEBUG" == "no" ]
	then
		CleanUp
	fi
	exit 1
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

function Dummy
{
	exit 1;
}

function StripQuotes
{
	echo $(echo $1 | sed "s/^\([\"']\)\(.*\)\1\$/\2/g")
}

function EscapeSpaces
{
	echo $(echo $1 | sed 's/ /\\ /g')
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
		LogError "Cannot load sync configuration file [$1]. Synchronization cannot start."
		return 1
	elif [[ $1 != *.conf ]]
	then
		LogError "Wrong configuration file supplied [$1]. Synchronization cannot start."
	else 
		egrep '^#|^[^ ]*=[^;&]*'  "$1" > "/dev/shm/osync_config_$SCRIPT_PID"
		source "/dev/shm/osync_config_$SCRIPT_PID"
	fi
} 

function CheckEnvironment
{
	sed --version > /dev/null 2>&1
        if [ $? != 0 ]
        then
                LogError "GNU coreutils not found (tested for sed --version). Synchronization cannot start."
        	return 1
	fi
	

	if [ "$REMOTE_SYNC" == "yes" ]
	then
		if ! type -p ssh > /dev/null 2>&1
		then
			LogError "ssh not present. Cannot start backup."
			return 1
		fi
	fi

	if [ "$BACKUP_FILES" != "no" ]
	then
		if ! type -p rsync > /dev/null 2>&1 
		then
			LogError "rsync not present. Backup cannot start."
			return 1
		fi
	fi
}

# Waits for pid $1 to complete. Will log an alert if $2 seconds exec time exceeded unless $2 equals 0. Will stop task and log alert if $3 seconds exec time exceeded.
function WaitForTaskCompletition
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
                                return 1
                        fi
                fi
        done
}


## Runs local command $1 and waits for completition in $2 seconds
function RunLocalCommand
{
	CheckConnectivity3rdPartyHosts
	$1 > /dev/shm/osync_run_local_$SCRIPT_PID &
	child_pid=$!
	WaitForTaskCompletition $child_pid 0 $2
	wait $child_pid
	retval=$?
	if [ $retval -eq 0 ]
	then
		Log "Running command [$1] on local host succeded."
	else
		Log "Running command [$1] on local host failed."
	fi

	Log "Command output:"
	Log "$(cat /dev/shm/osync_run_local_$SCRIPT_PID)"
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
			$(which ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT "$1" > /dev/shm/osync_run_remote_$SCRIPT_PID &
		fi
		child_pid=$!
		WaitForTaskCompletition $child_pid 0 $2
		wait $child_pid
		retval=$?
		if [ $retval -eq 0 ]
		then
			Log "Running command [$1] succeded."
		else
			LogError "Running command [$1] failed."
		fi
		
		Log "Command output:"
		Log "$(cat /dev/shm/osync_run_remote_$SCRIPT_PID)"
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

function SetCompressionOptions
{
	if [ "$COMPRESSION_PROGRAM" == "xz" ] && type -p xz > /dev/null 2>&1
	then
		COMPRESSION_EXTENSION=.xz
	elif [ "$COMPRESSION_PROGRAM" == "lzma" ] && type -p lzma > /dev/null 2>&1
	then
		COMPRESSION_EXTENSION=.lzma
	elif [ "$COMPRESSION_PROGRAM" == "gzip" ] && type -p gzip > /dev/null 2>&1
	then	
		COMPRESSION_EXTENSION=.gz
		COMPRESSION_OPTIONS=--rsyncable
	else
		COMPRESSION_EXTENSION=
	fi

	if [ "$SSH_COMPRESSION" == "yes" ]
	then
        	SSH_COMP=-C
	else
        	SSH_COMP=
	fi
}

function SetSudoOptions
{
	if [ "$SUDO_EXEC" == "yes" ]
	then
		RSYNC_PATH="sudo $(which rsync)"
		COMMAND_SUDO="sudo"
	else
		RSYNC_PATH="$(which rsync)"
		COMMAND_SUDO=""
	fi
}

function CreateLocalStorageDirectories
{
	if [ ! -d $LOCAL_FILE_STORAGE ] && [ "$BACKUP_FILES" != "no" ]
	then
		mkdir -p $LOCAL_FILE_STORAGE
	fi
}

function CheckLocalSpace
{
	# Not elegant solution to make df silent on errors
	df -P $LOCAL_FILE_STORAGE > /dev/shm/osync_local_space_$SCRIPT_PID 2>&1
	if [ $? != 0 ]
	then
		LOCAL_SPACE=0
	else
		LOCAL_SPACE=$(cat /dev/shm/osync_local_space_$SCRIPT_PID | tail -1 | awk '{print $4}')
	fi

	if [ $LOCAL_SPACE -eq 0 ]
	then
		LogError "Local disk space reported to be 0 Ko. This may also happen if local storage path doesn't exist."
	elif [ $SYNC_SIZE_MINIMUM -gt $(($TOTAL_DATABASES_SIZE+$TOTAL_FILES_SIZE)) ]
	then
		LogError "Backup size is smaller then expected."
	elif [ $LOCAL_STORAGE_WARN_MIN_SPACE -gt $LOCAL_SPACE ]
	then
		LogError "Local disk space is lower than warning value ($LOCAL_SPACE free Ko)."
	elif [ $LOCAL_SPACE -lt $(($TOTAL_DATABASES_SIZE+$TOTAL_FILES_SIZE)) ]
	then
		LogError "Local disk space may be insufficient (depending on rsync delta and DB compression ratio)."
	fi
	Log "Local Space: $LOCAL_SPACE Ko - Databases size: $TOTAL_DATABASES_SIZE Ko - Files size: $TOTAL_FILES_SIZE Ko"
}
      
function CheckTotalExecutionTime
{
	 #### Check if max execution time of whole script as been reached
	if [ $SECONDS -gt $SOFT_MAX_EXEC_TIME_TOTAL ]
        then
		if [ $soft_alert_total -eq 0 ]
                then
                	LogError "Max soft execution time of the whole sync exceeded while backing up $BACKUP_TASK."
                        soft_alert_total=1
                fi
                if [ $SECONDS -gt $HARD_MAX_EXEC_TIME_TOTAL ]
                then
                        LogError "Max hard execution time of the whole backup exceeded while backing up $BACKUP_TASK, stopping backup process."
                        exit 1
                fi
        fi
}

function CheckConnectivityRemoteHost
{
	if [ "$REMOTE_HOST_PING" != "no" ]
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