#!/bin/bash

###### Osync - Rsync based two way sync engine.
###### (L) 2013 by Orsiris "Ozy" de Jong (www.netpower.fr) 


## todo:
# add dryrun
# add logging
# add resume on error
# add master/slave prevalance
# thread sync function
# remote functionnality

OSYNC_VERSION=0.4
OSYNC_BUILD=1607201302

DEBUG=no
SCRIPT_PID=$$

LOCAL_USER=$(whoami)
LOCAL_HOST=$(hostname)

## Default log file until config file is loaded
LOG_FILE=/var/log/osync.log

## Working directory. Will keep current file states, backups and soft deleted files.
OSYNC_DIR=".osync_workdir"

## Log a state message every $KEEP_LOGGING seconds. Should not be equal to soft or hard execution time so your log won't be unnecessary big.
KEEP_LOGGING=1801

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

function CleanUp
{
        rm -f /dev/shm/osync_config_$SCRIPT_PID
 	rm -f /dev/shm/osync_run_local_$SCRIPT_PID
	rm -f /dev/shm/osync_run_remote_$SCRIPT_PID
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

                if [ -f /dev/shm/osync_run_remote_$SCRIPT_PID ]
                then
                        Log "Command output: $(cat /dev/shm/osync_run_remote_$SCRIPT_PID)"
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

function SetCompressionOptions
{
        if [ "$SSH_COMPRESSION" == "yes" ]
        then
                SSH_COMP=-C
        else
                SSH_COMP=
        fi
}

function SetSudoOptions
{
        ## Add this to support prior config files without RSYNC_EXECUTABLE option
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


function CreateDirs
{
	if ! [ -d $MASTER_SYNC_DIR/$OSYNC_DIR ]
	then
		mkdir $MASTER_SYNC_DIR/$OSYNC_DIR
	fi
	if ! [ -d $STATE_DIR ]
	then
		mkdir $STATE_DIR
	fi
	
}

function CheckMasterSlaveDirs
{
	if ! [ -d $MASTER_SYNC_DIR ]
	then
		LogError "Master directory [$MASTER_SYNC_DIR] does not exist."
		return 1
	fi

	if ! [ -d $SLAVE_SYNC_DIR ]
	then
		LogError "Slave directory [$SLAVE_SYNC_DIR] does not exist."
		return 1
	fi
}

function LockMaster
{
	echo "Not implemented yet"
}

function LockSlave
{
	echo "Not implemented yet"
}

# Subfunction of Sync
function sync_update_master
{
	Log "Updating slave replica."
	rsync -rlptgodEui --backup --backup-dir "$MASTER_BACKUP_DIR" --exclude "$OSYNC_DIR" --exclude-from "$STATE_DIR/master-deleted-list" --exclude-from "$STATE_DIR/slave-deleted-list" $MASTER_SYNC_DIR/ $SLAVE_SYNC_DIR/
}

# Subfunction of Sync
function sync_update_slave
{
	Log "Updating master replica."
	rsync -rlptgodEui --backup --backup-dir "$SLAVE_BACKUP_DIR" --exclude "$OSYNC_DIR" --exclude-from "$STATE_DIR/slave-deleted-list" --exclude-from "$STATE_DIR/master-deleted-list" $SLAVE_SYNC_DIR/ $MASTER_SYNC_DIR/
}

function Sync
{
	## Lock master dir
	## Lock slave dir

	Log "Starting synchronization task."

	## Create local file list
	Log "Creating master replica file list."
	rsync -rlptgodE --exclude "$OSYNC_DIR" --list-only $MASTER_SYNC_DIR/ | grep "^-\|^d" | awk '{print $5}' | grep -v "^\.$" > $STATE_DIR/master-tree-current
	Log "Creating slave replica file list."
	## Create distant file list
	rsync -rlptgodE --exclude "$OSYNC_DIR" --list-only $SLAVE_SYNC_DIR/ | grep "^-\|^d" | awk '{print $5}' | grep -v "^\.$" > $STATE_DIR/slave-tree-current

	## diff local file list and before file list except if before file list is empty >> deleted
	Log "Creating master replica deleted file list."
	if [ -f $STATE_DIR/master-tree-before ]
	then
		comm --nocheck-order -23 $STATE_DIR/master-tree-before $STATE_DIR/master-tree-current > $STATE_DIR/master-deleted-list
	else
		touch $STATE_DIR/master-deleted-list
	fi

	## diff local file list and before file list except if before file list is empty >> deleted
	Log "Creating slave replica deleted file list."
	if [ -f $STATE_DIR/slave-tree-before ]
	then
		comm --nocheck-order -23 $STATE_DIR/slave-tree-before $STATE_DIR/slave-tree-current > $STATE_DIR/slave-deleted-list
	else
		touch $STATE_DIR/slave-deleted-list
	fi

	if [ "$CONFLICT_PREVALANCE" != "master" ]
	then
		sync_update_slave
		sync_update_master
	else
		sync_update_master
		sync_update_slave
	fi

	Log "Propagating deletitions to slave replica."
	rsync -rlptgodEui --backup --backup-dir "$MASTER_DELETE_DIR" --delete --exclude "$OSYNC_DIR" --include-from "$STATE_DIR/master-deleted-list" --exclude-from "$STATE_DIR/slave-deleted-list" $MASTER_SYNC_DIR/ $SLAVE_SYNC_DIR/ 
	Log "Propagating deletitions to master replica."
	rsync -rlptgodEui --backup --backup-dir "$SLAVE_DELETE_DIR" --delete --exclude "$OSYNC_DIR" --include-from "$STATE_DIR/slave-deleted-list" --exclude-from "$STATE_DIR/master-deleted-list" $SLAVE_SYNC_DIR/ $MASTER_SYNC_DIR/ 

        ## Create local file list
        Log "Creating new master replica file list."
        rsync -rlptgodE --exclude "$OSYNC_DIR" --list-only $MASTER_SYNC_DIR/ | grep "^-\|^d" | awk '{print $5}' | grep -v "^\.$" > $STATE_DIR/master-tree-before
        Log "Creating new slave replica file list."
        ## Create distant file list
        rsync -rlptgodE --exclude "$OSYNC_DIR" --list-only $SLAVE_SYNC_DIR/ | grep "^-\|^d" | awk '{print $5}' | grep -v "^\.$" > $STATE_DIR/slave-tree-before

	Log "Finished synchronization task."

}

function SoftDelete
{
	if [ "$CONFLICT_BACKUP" != "no" ]
	then
		if [ -d $MASTER_BACKUP_DIR ]
		then
			Log "Removing backups older than $CONFLICT_BACKUP_DAYS days on master replica."
			find $MASTER_BACKUP_DIR/ -ctime +$CONFLICT_BACKUP_DAYS | xargs rm -rf
		fi
		
		if [ -d $SLAVE_BACKUP_DIR ]
		then
			Log "Removing backups older than $CONFLICT_BACKUP_DAYS days on slave replica."
			find $SLAVE_BACKUP_DIR/ -ctime +$CONFLICT_BACKUP_DAYS | xargs rm -rf	
		fi
	fi

	if [ "$SOFT_DELETE" != "no" ]
	then
		if [ -d $MASTER_DELETE_DIR ]
		then
			Log "Removing soft deleted items older than $SOFT_DELETE_DAYS days on master replica."
			find $MASTER_DELETE_DIR/ -ctime +$SOFT_DELETE_DAYS | xargs rm -rf
		fi

		if [ -d $SLAVE_DELETE_DIR ]
		then
			Log "Removing soft deleted items older than $SOFT_DELETE_DAYS days on slave replica."
			find $SLAVE_DELETE_DIR/ -ctime +$SOFT_DELETE_DAYS | xargs rm -rf
		fi
	fi
}

function Init
{
        # Set error exit code if a piped command fails
        set -o pipefail
        set -o errtrace

        trap TrapStop SIGINT SIGQUIT
        if [ "$DEBUG" == "yes" ]
        then
                trap 'TrapError ${LINENO} $?' ERR
        fi

        LOG_FILE=/var/log/osync_$OSYNC_VERSION-$SYNC_ID.log
        MAIL_ALERT_MSG="Warning: Execution of osync instance $OSYNC_ID (pid $SCRIPT_PID) as $LOCAL_USER@$LOCAL_HOST produced errors."

	STATE_DIR="$MASTER_SYNC_DIR/$OSYNC_DIR/state"

	## Working directories to keep backups of updated / deleted files
	MASTER_BACKUP_DIR="$MASTER_SYNC_DIR/$OSYNC_DIR/backups"
	MASTER_DELETE_DIR="$MASTER_SYNC_DIR/$OSYNC_DIR/deleted"
	SLAVE_BACKUP_DIR="$SLAVE_SYNC_DIR/$OSYNC_DIR/backups"
	SLAVE_DELETE_DIR="$SLAVE_SYNC_DIR/$OSYNC_DIR/deleted"
	
	## Runner definition
	if [ "$REMOTE_SYNC" == "yes" ]
	then
		RUNNER="$(which ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
	else
		RUNNER=""
	fi
}

function Main
{
	CreateDirs
	Sync
}

function Usage
{
	echo "Osync $OSYNC_VERSION $OSYNC_BUILD"
	echo ""
	echo "usage: osync /path/to/conf.file [--dry] [--silent]"
	echo ""
	echo "--dry: will run osync without actuallyv doing anything; just testing"
	echo "--silent: will run osync without any output to stdout, usefull for cron jobs"
	exit 128
}

# Comand line argument flags
dryrun=0
silent=0
# Alert flags
soft_alert_total=0
error_alert=0

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
		--help|-h)
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
			Log "-----------------------------------------------------------"
			Log "$DATE - Osync v$OSYNC_VERSION script begin."
			Log "-----------------------------------------------------------"
			CheckMasterSlaveDirs
			if [ $? == 0 ]
			then
				RunBeforeHook
				Main
				SoftDelete
				RunAfterHook
				CleanUp
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

if [ $error_alert -ne 0 ]
then
	SendAlert
	LogError "Osync finished with errros."
	exit 1
else
	Log "Osync script finished."
	exit 0
fi
