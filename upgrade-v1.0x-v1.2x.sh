#!/usr/bin/env bash

PROGRAM="osync instance upgrade script"
SUBPROGRAM="osync"
AUTHOR="(C) 2016 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
OLD_PROGRAM_VERSION="v1.0x-v1.1x"
NEW_PROGRAM_VERSION="v1.2x"
PROGRAM_BUILD=2016081902 # Will go into config file rev

## type -p does not work on platforms other than linux (bash). If if does not work, always assume output is not a zero exitcode
if ! type "$BASH" > /dev/null; then
        echo "Please run this script only with bash shell. Tested on bash >= 3.2"
        exit 127
fi

function Init {
	OSYNC_DIR=".osync_workdir"
	STATE_DIR="state"

	TREE_CURRENT_FILENAME="-tree-current-$SYNC_ID"
	TREE_AFTER_FILENAME="-tree-after-$SYNC_ID"
	TREE_AFTER_FILENAME_NO_SUFFIX="-tree-after-$SYNC_ID"
	DELETED_LIST_FILENAME="-deleted-list-$SYNC_ID"
	FAILED_DELETE_LIST_FILENAME="-failed-delete-$SYNC_ID"

	if [ "${SLAVE_SYNC_DIR:0:6}" == "ssh://" ]; then
		REMOTE_SYNC="yes"

		# remove leadng 'ssh://'
		uri=${SLAVE_SYNC_DIR#ssh://*}
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
		_hosturiandpath=${uri#*@}
		# remove everything after first '/'
		_hosturi=${_hosturiandpath%%/*}
		if [[ "$_hosturi" == *":"* ]]; then
			REMOTE_PORT=${_hosturi##*:}
		else
			REMOTE_PORT=22
		fi
		REMOTE_HOST=${_hosturi%%:*}

		# remove everything before first '/'
		SLAVE_SYNC_DIR=${_hosturiandpath#*/}
	fi

	SSH_CMD="$(type -p ssh) $SSH_COMP -i $SSH_RSA_PRIVATE_KEY $REMOTE_USER@$REMOTE_HOST -p $REMOTE_PORT"
}

function Usage {
	echo "$PROGRAM $PROGRAM_BUILD"
	echo $AUTHOR
	echo $CONTACT
	echo ""
	echo "This script migrates osync $OLD_PROGRAM_VERSION setups to $NEW_PROGRAM_VERSION by updating state filenames and config files."
	echo ""
	echo "Usage: $0 /path/to/config_file.conf"
	echo "Usage: $0 --master=/path/to/master/replica --slave=/path/to/local/slave/replica --sync-id=existing_id"
	echo "Usage: $0 --master=/path/to/master/replica --slave=ssh://[backupuser]@remotehost.com[:portnumber]//path/to/slave/replica --sync-id=existing_id --rsakey=/path/to/rsa/key"
	echo ""
	echo "If config file is provided, the config file itself and both replicas from config file will be updated. Please make sure the config file is writable."
	echo "If no config file provided, assume you run the update script just like any other quicksync task."
	echo "If sync-id is not specified, it will assume handling a quicksync task."
	exit 128
}

function CheckEnvironment {
	if [ "$REMOTE_SYNC" == "yes" ]; then
		if ! type -p ssh > /dev/null 2>&1
		then
			Logger "ssh not present. Cannot start sync." "CRITICAL"
			return 1
		fi
	fi

	if ! type -p rsync > /dev/null 2>&1
	then
		Logger "rsync not present. Sync cannot start." "CRITICAL"
		return 1
	fi
}

function LoadConfigFile {
	local config_file="${1}"

	if [ ! -f "$config_file" ]; then
		echo "Cannot load configuration file [$config_file]. Sync cannot start."
		exit 1
	elif [[ "$1" != *".conf" ]]; then
		echo "Wrong configuration file supplied [$config_file]. Sync cannot start."
		exit 1
	else
		egrep '^#|^[^ ]*=[^;&]*'  "$config_file" > "./$SUBPROGRAM.$FUNCNAME.$$"
		# Shellcheck source=./sync.conf
		source "./$SUBPROGRAM.$FUNCNAME.$$"
		rm -f "./$SUBPROGRAM.$FUNCNAME.$$"
	fi
}

function _RenameStateFilesLocal {
	local state_dir="${1}" # Absolute path to statedir
	local rewrite=false

	echo "Rewriting state files in [$state_dir]."

	# Make sure there is no ending slash
	state_dir="${state_dir%/}/"

	if [ -f "$state_dir""master"$TREE_CURRENT_FILENAME ]; then
		mv -f "$state_dir""master"$TREE_CURRENT_FILENAME "$state_dir""initiator"$TREE_CURRENT_FILENAME
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"master"$TREE_CURRENT_FILENAME
		else
			rewrite=true
		fi
	fi
	if [ -f "$state_dir""master"$TREE_AFTER_FILENAME ]; then
		mv -f "$state_dir""master"$TREE_AFTER_FILENAME "$state_dir""initiator"$TREE_AFTER_FILENAME
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"master"$TREE_AFTER_FILENAME
		else
			rewrite=true
		fi
	fi
	if [ -f "$state_dir""master"$DELETED_LIST_FILENAME ]; then
		mv -f "$state_dir""master"$DELETED_LIST_FILENAME "$state_dir""initiator"$DELETED_LIST_FILENAME
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"master"$DELETED_LIST_FILENAME
		else
			rewrite=true
		fi
		rewrite=true
	fi
	if [ -f "$state_dir""master"$FAILED_DELETE_LIST_FILENAME ]; then
		mv -f "$state_dir""master"$FAILED_DELETE_LIST_FILENAME "$state_dir""initiator"$FAILED_DELETE_LIST_FILENAME
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"master"$FAILED_DELETE_LIST_FILENAME
		else
			rewrite=true
		fi
	fi

	if [ -f "$state_dir""master"$TREE_CURRENT_FILENAME"-dry" ]; then
		mv -f "$state_dir""master"$TREE_CURRENT_FILENAME"-dry" "$state_dir""initiator"$TREE_CURRENT_FILENAME"-dry"
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"master"$TREE_CURRENT_FILENAME"-dry"
		else
			rewrite=true
		fi
	fi
	if [ -f "$state_dir""master"$TREE_AFTER_FILENAME"-dry" ]; then
		mv -f "$state_dir""master"$TREE_AFTER_FILENAME"-dry" "$state_dir""initiator"$TREE_AFTER_FILENAME"-dry"
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir""master"$TREE_AFTER_FILENAME"
		else
			rewrite=true
		fi
	fi
	if [ -f "$state_dir""master"$DELETED_LIST_FILENAME"-dry" ]; then
		mv -f "$state_dir""master"$DELETED_LIST_FILENAME"-dry" "$state_dir""initiator"$DELETED_LIST_FILENAME"-dry"
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"master"$DELETED_LIST_FILENAME"-dry"
		else
			rewrite=true
		fi
	fi
	if [ -f "$state_dir""master"$FAILED_DELETE_LIST_FILENAME"-dry" ]; then
		mv -f "$state_dir""master"$FAILED_DELETE_LIST_FILENAME"-dry" "$state_dir""initiator"$FAILED_DELETE_LIST_FILENAME"-dry"
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"master"$FAILED_DELETE_LIST_FILENAME"-dry"
		else
			rewrite=true
		fi
	fi

	if [ -f "$state_dir""slave"$TREE_CURRENT_FILENAME ]; then
		mv -f "$state_dir""slave"$TREE_CURRENT_FILENAME "$state_dir""target"$TREE_CURRENT_FILENAME
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"slave"$TREE_CURRENT_FILENAME
		else
			rewrite=true
		fi
	fi
	if [ -f "$state_dir""slave"$TREE_AFTER_FILENAME ]; then
		mv -f "$state_dir""slave"$TREE_AFTER_FILENAME "$state_dir""target"$TREE_AFTER_FILENAME
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"slave"$TREE_AFTER_FILENAME
		else
			rewrite=true
		fi
	fi
	if [ -f "$state_dir""slave"$DELETED_LIST_FILENAME ]; then
		mv -f "$state_dir""slave"$DELETED_LIST_FILENAME "$state_dir""target"$DELETED_LIST_FILENAME
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"slave"$DELETED_LIST_FILENAME
		else
			rewrite=true
		fi
	fi
	if [ -f "$state_dir""slave"$FAILED_DELETE_LIST_FILENAME ]; then
		mv -f "$state_dir""slave"$FAILED_DELETE_LIST_FILENAME "$state_dir""target"$FAILED_DELETE_LIST_FILENAME
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"slave"$FAILED_DELETE_LIST_FILENAME
		else
			rewrite=true
		fi
	fi

	if [ -f "$state_dir""slave"$TREE_CURRENT_FILENAME"-dry" ]; then
		mv -f "$state_dir""slave"$TREE_CURRENT_FILENAME"-dry" "$state_dir""target"$TREE_CURRENT_FILENAME"-dry"
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"slave"$TREE_CURRENT_FILENAME"-dry"
		else
			rewrite=true
		fi
	fi
	if [ -f "$state_dir""slave"$TREE_AFTER_FILENAME"-dry" ]; then
		mv -f "$state_dir""slave"$TREE_AFTER_FILENAME"-dry" "$state_dir""target"$TREE_AFTER_FILENAME"-dry"
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"slave"$TREE_AFTER_FILENAME"-dry"
		else
			rewrite=true
		fi
	fi
	if [ -f "$state_dir""slave"$DELETED_LIST_FILENAME"-dry" ]; then
		mv -f "$state_dir""slave"$DELETED_LIST_FILENAME"-dry" "$state_dir""target"$DELETED_LIST_FILENAME"-dry"
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"slave"$DELETED_LIST_FILENAME"-dry"
		else
			rewrite=true
		fi
	fi
	if [ -f "$state_dir""slave"$FAILED_DELETE_LIST_FILENAME"-dry" ]; then
		mv -f "$state_dir""slave"$FAILED_DELETE_LIST_FILENAME"-dry" "$state_dir""target"$FAILED_DELETE_LIST_FILENAME"-dry"
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"slave"$FAILED_DELETE_LIST_FILENAME"-dry"
		else
			rewrite=true
		fi
	fi

	if [ $rewrite == true ]; then
		echo "State dir rewritten."
	else
		echo "Nothing rewritten in state dir."
	fi
	}

function _RenameStateFilesRemote {

	echo "Connecting remotely to rewrite state files in [$1]."

$SSH_CMD state_dir="${1}" DELETED_LIST_FILENAME="$DELETED_LIST_FILENAME" FAILED_DELETE_LIST_FILENAME="$FAILED_DELETE_LIST_FILENAME" 'bash -s' << 'ENDSSH'

	# Make sure there is no ending slash
	state_dir="${state_dir%/}/"
	rewrite=false

	if [ -f "$state_dir""master"$DELETED_LIST_FILENAME ]; then
		mv -f "$state_dir""master"$DELETED_LIST_FILENAME "$state_dir""initiator"$DELETED_LIST_FILENAME
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"master"$DELETED_LIST_FILENAME
		else
			rewrite=true
		fi
	fi
	if [ -f "$state_dir""master"$FAILED_DELETE_LIST_FILENAME ]; then
		mv -f "$state_dir""master"$FAILED_DELETE_LIST_FILENAME "$state_dir""initiator"$FAILED_DELETE_LIST_FILENAME
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"master"$FAILED_DELETE_LIST_FILENAME
		else
			rewrite=true
		fi
	fi
	if [ -f "$state_dir""master"$FAILED_DELETE_LIST_FILENAME"-dry" ]; then
		mv -f "$state_dir""master"$FAILED_DELETE_LIST_FILENAME"-dry" "$state_dir""initiator"$FAILED_DELETE_LIST_FILENAME"-dry"
		if [ $? != 0 ]; then
			echo "Error while rewriting "$state_dir"master"$FAILED_DELETE_LIST_FILENAME"-dry"
		else
			rewrite=true
		fi
	fi

	if [ $rewrite == true ]; then
		echo "State dir rewritten."
	else
		echo "Nothing rewritten in state dir."
	fi
ENDSSH
	}

function RenameStateFiles {
	_RenameStateFilesLocal "$MASTER_SYNC_DIR/$OSYNC_DIR/$STATE_DIR"
	if [ "$REMOTE_SYNC" != "yes" ]; then
		_RenameStateFilesLocal "$SLAVE_SYNC_DIR/$OSYNC_DIR/$STATE_DIR"
	else
		_RenameStateFilesRemote "$SLAVE_SYNC_DIR/$OSYNC_DIR/$STATE_DIR"
	fi
}

function RewriteConfigFiles {
	local config_file="${1}"

	if ((! grep "MASTER_SYNC_DIR=" "$config_file" > /dev/null) && (! grep "INITIATOR_SYNC_DIR=" "$config_file" > /dev/null)); then
		echo "Config file [$config_file] does not seem to be an osync v1.0x or v1.1x file."
		exit 1
	fi

        echo "Backing up [$config_file] as [$config_file.save]"
        cp -p "$config_file" "$config_file.save"
        if [ $? != 0 ]; then
                echo "Cannot backup config file."
                exit 1
        fi

	echo "Rewriting config file $config_file"

	#TODO: exclude occurences between doublequotes

	sed -i'.tmp' 's/^MASTER_SYNC_DIR/INITIATOR_SYNC_DIR/g' "$config_file"
	sed -i'.tmp' 's/^SLAVE_SYNC_DIR/TARGET_SYNC_DIR/g' "$config_file"
	sed -i'.tmp' 's/^CONFLICT_PREVALANCE=master/CONFLICT_PREVALANCE=initiator/g' "$config_file"
	sed -i'.tmp' 's/^CONFLICT_PREVALANCE=slave/CONFLICT_PREVALANCE=target/g' "$config_file"
	sed -i'.tmp' 's/^SYNC_ID=/INSTANCE_ID=/g' "$config_file"

	# Add new config file values from v1.1x
	if ! grep "^RSYNC_PATTERN_FIRST=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^LOGFILE=*/a\'$'\n''RSYNC_PATTERN_FIRST=include\'$'\n''' "$config_file"
	fi

       	if ! grep "^SSH_IGNORE_KNOWN_HOSTS=" "$config_file" > /dev/null; then
                sed -i'.tmp' '/^SSH_COMPRESSION=*/a\'$'\n''SSH_IGNORE_KNOWN_HOSTS=no\'$'\n''' "$config_file"
	fi

	if ! grep "^RSYNC_INCLUDE_PATTERN=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^RSYNC_EXCLUDE_PATTERN=*/a\'$'\n''RSYNC_INCLUDE_PATTERN=""\'$'\n''' "$config_file"
	fi

	if ! grep "^RSYNC_INCLUDE_FROM=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^RSYNC_EXCLUDE_FROM=*/a\'$'\n''RSYNC_INCLUDE_FROM=""\'$'\n''' "$config_file"
	fi

	if ! grep "^PRESERVE_PERMISSIONS=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^REMOTE_3RD_PARTY_HOSTS=*/a\'$'\n''PRESERVE_PERMISSIONS=yes\'$'\n''' "$config_file"
	fi

	if ! grep "^PRESERVE_OWNER=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^PRESERVE_PERMISSIONS=*/a\'$'\n''PRESERVE_OWNER=yes\'$'\n''' "$config_file"
	fi

	if ! grep "^PRESERVE_GROUP=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^PRESERVE_OWNER=*/a\'$'\n''PRESERVE_GROUP=yes\'$'\n''' "$config_file"
	fi

	if ! grep "^PRESERVE_EXECUTABILITY=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^PRESERVE_GROUP=*/a\'$'\n''PRESERVE_EXECUTABILITY=yes\'$'\n''' "$config_file"
	fi

	if ! grep "^CHECKSUM=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^PRESERVE_HARDLINKS=*/a\'$'\n''CHECKSUM=no\'$'\n''' "$config_file"
	fi

	if ! grep "^KEEP_LOGGING=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^HARD_MAX_EXEC_TIME=*/a\'$'\n''KEEP_LOGGING=1801\'$'\n''' "$config_file"
	fi

	if ! grep "^MAX_WAIT=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^MIN_WAIT=*/a\'$'\n''MAX_WAIT=300\'$'\n''' "$config_file"
	fi

	if ! grep "^PARTIAL=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^FORCE_STRANGER_LOCK_RESUME=*/a\'$'\n''PARTIAL=no\'$'\n''' "$config_file"
	fi

	if ! grep "^DELTA_COPIES=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^PARTIAL=*/a\'$'\n''DELTA_COPIES=yes\'$'\n''' "$config_file"
	fi

	if ! grep "^RUN_AFTER_CMD_ON_ERROR=" "$config_file" > /dev/null; then
		sed -i'.tmp' '/^STOP_ON_CMD_ERROR=*/a\'$'\n''RUN_AFTER_CMD_ON_ERROR=no\'$'\n''' "$config_file"
	fi

	# "onfig file rev" to deal with earlier variants of the file
	sed -i'.tmp' '/onfig file rev/c\###### osync config file rev '$PROGRAM_BUILD "$config_file"

	rm -f "$config_file.tmp"
}

_QUICKSYNC=0

for i in "$@"
do
	case $i in
		--master=*)
		no_maxtime=1
		MASTER_SYNC_DIR=${i##*=}
		QUICK_SYNC=$(($_QUICKSYNC + 1))
		;;
		--slave=*)
		SLAVE_SYNC_DIR=${i##*=}
		QUICK_SYNC=$(($_QUICKSYNC + 1))
		;;
		--rsakey=*)
		SSH_RSA_PRIVATE_KEY=${i##*=}
		;;
		--sync-id=*)
		SYNC_ID=${i##*=}
		;;
	esac
done

if [ $_QUICKSYNC -eq 2 ]; then
	Init
	REPLICA_DIR=${i##*=}
	RenameStateFiles

elif [ "$1" != "" ] && [ -f "$1" ] && [ -w "$1" ]; then
	CONF_FILE="$1"
	# Make sure there is no ending slash
	CONF_FILE="${CONF_FILE%/}"
	LoadConfigFile "$CONF_FILE"
	Init
	RewriteConfigFiles "$CONF_FILE"
	RenameStateFiles
else
	Usage
fi
