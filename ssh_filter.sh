#!/bin/bash

##### Osync ssh command filter build 2015090801
##### This script should be located in /usr/local/bin in the remote system to sync / backup
##### It will filter the commands that can be run remotely via ssh.
##### Please chmod 755 and chown root:root this file

##### Obackup needed commands: rsync find du mysql mysqldump (sudo)
##### Osync needed commands: rsync find du echo mkdir rm if df (sudo)

## If enabled, execution of "sudo" command will be allowed.
SUDO_EXEC=yes
## Paranoia option. Don't change this unless you read the documentation and still feel concerned about security issues.
RSYNC_EXECUTABLE=rsync
## Enable other commands, useful for remote execution hooks like remotely creating snapshots.
CMD1=
CMD2=
CMD3=

LOG_FILE=~/.ssh/ssh_filter.log

function Log {
	DATE=$(date)
	echo "$DATE - $1" >> $LOG_FILE
}

function Go {
	eval $SSH_ORIGINAL_COMMAND
}

case ${SSH_ORIGINAL_COMMAND%% *} in
	"$RSYNC_EXECUTABLE")
	Go ;;
	"echo")
	Go ;;
	"find")
	Go ;;
	"du")
	Go ;;
	"mkdir")
	Go ;;
	"rm")
	Go ;;
	"df")
	Go ;;
	"mv")
	Go ;;
	"$CMD1")
	if [ "$CMD1" != "" ]; then
		Go ;;
	fi
	"$CMD2")
	if [ "$CMD2" != "" ]; then
		Go ;;
	fi
	"$CMD3")
	if [ "$CMD3" != "" ]; then
		Go ;;
	fi
	"sudo")
	if [ "$SUDO_EXEC" == "yes" ]; then
		if [[ "$SSH_ORIGINAL_COMMAND" == "sudo $RSYNC_EXECUTABLE"* ]]; then
			Go
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo du"* ]]; then
			Go
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo find"* ]]; then
			Go
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo mkdir"* ]]
		then
			Go
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo rm"* ]]
		then
			Go
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo echo"* ]]
		then
			Go
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo df"* ]]
		then
			Go
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo mv"* ]]
		then
			Go
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo $CMD1"* ]]; then
			if [ "$CMD1" != "" ]; then
			Go
			fi
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo $CMD2"* ]]; then
			if [ "$CMD2" != "" ]; then
			Go
			fi
		elif [[ "$SSH_ORIGINAL_COMMAND" == "sudo $CMD3"* ]]; then
			if [ "$CMD3" != "" ]; then
			Go
			fi
		else
			Log "Command [$SSH_ORIGINAL_COMMAND] not allowed."
			exit 1
		fi
	else
		Log "Command [$SSH_ORIGINAL_COMMAND] not allowed. sudo not enabled."
		exit 1
	fi
	;;
	*)
	Log "Command [$SSH_ORIGINAL_COMMAND] not allowed."
	exit 1
esac
