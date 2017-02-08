#!/usr/bin/env bash

##### osync / obackup ssh command filter
##### This script should be located in /usr/local/bin in the remote system to sync / backup
##### It will filter the commands that can be run remotely via ssh.
##### Please chmod 755 and chown root:root this file

##### Any command that has env _REMOTE_TOKEN= with the corresponding token in it will be run
##### Also, commands that begin with rsync --server --sender are allowed
##### Any other command will return "syntax error"
##### For details, see ssh_filter.log

SCRIPT_BUILD=2017020801

## Allow sudo
SUDO_EXEC=yes

## Paranoia option. Don't change this unless you read the documentation and still feel concerned about security issues.
RSYNC_EXECUTABLE=rsync

## Set remote token in authorized_keys
if [ "$1" != "" ]; then
	_REMOTE_TOKEN="${1}"
fi

LOG_FILE="${HOME}/.ssh/ssh_filter.log"

function Log {
	DATE=$(date)
	echo "$DATE - $1" >> "$LOG_FILE"
}

function Go {
	eval "$SSH_ORIGINAL_COMMAND"
}

case "${SSH_ORIGINAL_COMMAND}" in
	"$RSYNC_EXECUTABLE --server"*)
	Go
	;;
	"sudo $RSYNC_EXECUTABLE --server"*)
		if [ "$SUDO_EXEC" != "yes" ]; then
			Log "Command [$SSH_ORIGINAL_COMMAND] contains sudo which is not allowed."
			echo "Syntax error unexpected end of file"
			exit 1
		fi
		Go
	;;
	*"env _REMOTE_TOKEN=$_REMOTE_TOKEN"*)
		if [ "$SUDO_EXEC" != "yes" ] && [[ $SSH_ORIGINAL_COMMAND == *"sudo "* ]]; then
			Log "Command [$SSH_ORIGINAL_COMMAND] contains sudo which is not allowed."
			echo "Syntax error unexpected end of file"
			exit 1
		fi
	Go
	;;
	*)
	Log "Command [$SSH_ORIGINAL_COMMAND] not allowed."
	echo "Syntax error near unexpected token"
	exit 1
	;;
esac
