#!/usr/bin/env bash

PROGRAM="osync instance upgrade script"
SUBPROGRAM="osync"
AUTHOR="(C) 2016-2019 by Orsiris de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
OLD_PROGRAM_VERSION="v1.0x-v1.2x"
NEW_PROGRAM_VERSION="v1.3x"
CONFIG_FILE_REVISION=1.3.0
PROGRAM_BUILD=2019052104

## type -p does not work on platforms other than linux (bash). If if does not work, always assume output is not a zero exitcode
if ! type "$BASH" > /dev/null; then
	echo "Please run this script only with bash shell. Tested on bash >= 3.2"
	exit 127
fi

# Defines all keywords / value sets in osync configuration files
# bash does not support two dimensional arrays, so we declare two arrays:
# ${KEYWORDS[index]}=${VALUES[index]}

KEYWORDS=(
INSTANCE_ID
INITIATOR_SYNC_DIR
TARGET_SYNC_DIR
SSH_RSA_PRIVATE_KEY
SSH_PASSWORD_FILE
_REMOTE_TOKEN
CREATE_DIRS
LOGFILE
MINIMUM_SPACE
BANDWIDTH
SUDO_EXEC
RSYNC_EXECUTABLE
RSYNC_REMOTE_PATH
RSYNC_PATTERN_FIRST
RSYNC_INCLUDE_PATTERN
RSYNC_EXCLUDE_PATTERN
RSYNC_INCLUDE_FROM
RSYNC_EXCLUDE_FROM
PATH_SEPARATOR_CHAR
SSH_COMPRESSION
SSH_IGNORE_KNOWN_HOSTS
REMOTE_HOST_PING
REMOTE_3RD_PARTY_HOSTS
RSYNC_OPTIONAL_ARGS
PRESERVE_PERMISSIONS
PRESERVE_OWNER
PRESERVE_GROUP
PRESERVE_EXECUTABILITY
PRESERVE_ACL
PRESERVE_XATTR
COPY_SYMLINKS
KEEP_DIRLINKS
PRESERVE_HARDLINKS
CHECKSUM
RSYNC_COMPRESS
SOFT_MAX_EXEC_TIME
HARD_MAX_EXEC_TIME
KEEP_LOGGING
MIN_WAIT
MAX_WAIT
LOG_CONFLICTS
ALERT_CONFLICTS
CONFLICT_BACKUP
CONFLICT_BACKUP_MULTIPLE
CONFLICT_BACKUP_DAYS
CONFLICT_PREVALANCE
SOFT_DELETE
SOFT_DELETE_DAYS
SKIP_DELETION
RESUME_SYNC
RESUME_TRY
FORCE_STRANGER_LOCK_RESUME
PARTIAL
DELTA_COPIES
DESTINATION_MAILS
MAIL_BODY_CHARSET
SENDER_MAIL
SMTP_SERVER
SMTP_PORT
SMTP_ENCRYPTION
SMTP_USER
SMTP_PASSWORD
LOCAL_RUN_BEFORE_CMD
LOCAL_RUN_AFTER_CMD
REMOTE_RUN_BEFORE_CMD
REMOTE_RUN_AFTER_CMD
MAX_EXEC_TIME_PER_CMD_BEFORE
MAX_EXEC_TIME_PER_CMD_AFTER
STOP_ON_CMD_ERROR
RUN_AFTER_CMD_ON_ERROR
)

VALUES=(
sync-test
''
''
${HOME}/backupuser/.ssh/id_rsa
''
SomeAlphaNumericToken9
false
''
10240
0
false
rsync
''
include
''
''
''
''
\;
true
false
false
'www.kernel.org www.google.com'
''
true
true
true
true
false
false
false
false
false
false
true
7200
10600
1801
60
7200
true
false
true
false
30
initiator
true
30
''
true
2
false
false
true
''
''
alert@your.system.tld
smtp.your.isp.tld
25
none
''
''
''
''
''
''
0
0
true
false
)

function Init {
	OSYNC_DIR=".osync_workdir"
	STATE_DIR="state"

	TREE_CURRENT_FILENAME="-tree-current-$SYNC_ID"
	TREE_AFTER_FILENAME="-tree-after-$SYNC_ID"
	DELETED_LIST_FILENAME="-deleted-list-$SYNC_ID"
	FAILED_DELETE_LIST_FILENAME="-failed-delete-$SYNC_ID"

	if [ "${SLAVE_SYNC_DIR:0:6}" == "ssh://" ]; then
		REMOTE_OPERATION="yes"

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
	if [ "$REMOTE_OPERATION" == "yes" ]; then
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
		egrep '^#|^[^ ]*=[^;&]*'  "$config_file" > "./$SUBPROGRAM.${FUNCNAME[0]}.$$"
		# Shellcheck source=./sync.conf
		source "./$SUBPROGRAM.${FUNCNAME[0]}.$$"
		rm -f "./$SUBPROGRAM.${FUNCNAME[0]}.$$"
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
			echo "Error while rewriting "$state_dir"master"$TREE_AFTER_FILENAME"-dry"
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
	if [ "$REMOTE_OPERATION" != "yes" ]; then
		_RenameStateFilesLocal "$SLAVE_SYNC_DIR/$OSYNC_DIR/$STATE_DIR"
	else
		_RenameStateFilesRemote "$SLAVE_SYNC_DIR/$OSYNC_DIR/$STATE_DIR"
	fi
}

function CheckAndBackup {
	local config_file="${1}"

	if ! grep "MASTER_SYNC_DIR=" "$config_file" > /dev/null && ! grep "INITIATOR_SYNC_DIR=" "$config_file" > /dev/null; then
		echo "Config file [$config_file] does not seem to be an osync v1.0x or v1.1x file."
		exit 1
	fi

	echo "Backing up [$config_file] as [$config_file.save]"
	cp -p "$config_file" "$config_file.save"
	if [ $? != 0 ]; then
		echo "Cannot backup config file."
		exit 1
	fi
}

function RewriteOldConfigFiles {
	local config_file="${1}"

	echo "Rewriting config file $config_file"

	#TODO: exclude occurences between doublequotes

	sed -i'.tmp' 's/^MASTER_SYNC_DIR/INITIATOR_SYNC_DIR/g' "$config_file"
	sed -i'.tmp' 's/^SLAVE_SYNC_DIR/TARGET_SYNC_DIR/g' "$config_file"
	sed -i'.tmp' 's/^CONFLICT_PREVALANCE=master/CONFLICT_PREVALANCE=initiator/g' "$config_file"
	sed -i'.tmp' 's/^CONFLICT_PREVALANCE=slave/CONFLICT_PREVALANCE=target/g' "$config_file"
	sed -i'.tmp' 's/^SYNC_ID=/INSTANCE_ID=/g' "$config_file"
	sed -i'.tmp' 's/^REMOTE_SYNC=.*//g' "$config_file"

	rm -f "$config_file.tmp"
}

function AddMissingConfigOptionsAndFixBooleans {
	local config_file="${1}"
	local counter=0

	while [ $counter -lt ${#KEYWORDS[@]} ]; do
		if ! grep "^${KEYWORDS[$counter]}=" > /dev/null "$config_file"; then
			echo "${KEYWORDS[$counter]} not found"
			if [ $counter -gt 0 ]; then
				if [ "{$VALUES[$counter]}" == true ] || [ "${VALUES[$counter]}" == false ]; then
					sed -i'.tmp' '/^'${KEYWORDS[$((counter-1))]}'=*/a\'$'\n'${KEYWORDS[$counter]}'='"${VALUES[$counter]}"'\'$'\n''' "$config_file"
				else
					sed -i'.tmp' '/^'${KEYWORDS[$((counter-1))]}'=*/a\'$'\n'${KEYWORDS[$counter]}'="'"${VALUES[$counter]}"'"\'$'\n''' "$config_file"
				fi
				if [ $? -ne 0 ]; then
					echo "Cannot add missing ${[KEYWORDS[$counter]}."
					exit 1
				fi
			else
				if [ "{$VALUES[$counter]}" == true ] || [ "${VALUES[$counter]}" == false ]; then
					sed -i'.tmp' '/[GENERAL\]$//a\'$'\n'${KEYWORDS[$counter]}'='"${VALUES[$counter]}"'\'$'\n''' "$config_file"
				else
					sed -i'.tmp' '/[GENERAL\]$//a\'$'\n'${KEYWORDS[$counter]}'="'"${VALUES[$counter]}"'"\'$'\n''' "$config_file"
				fi
			fi
			echo "Added missing ${KEYWORDS[$counter]} config option with default option [${VALUES[$counter]}]"
		else
			# Not the most elegant but the quickest way :)
			if grep "^{$KEYWORDS[$counter]}=yes" > /dev/null "$config_file"; then
				sed -i'.tmp' 's/^'${KEYWORDS[$counter]}'=.*/'${KEYWORDS[$counter]}'=true/g' "$config_file"
				if [ $? -ne 0 ]; then
					echo "Cannot rewrite ${[KEYWORDS[$counter]} boolean to true."
					exit 1
				fi
			elif grep "^{$KEYWORDS[$counter]}=no" > /dev/null "$config_file"; then
				sed -i'.tmp' 's/^'${KEYWORDS[$counter]}'=.*/'${KEYWORDS[$counter]}'=false/g' "$config_file"
				if [ $? -ne 0 ]; then
					echo "Cannot rewrite ${[KEYWORDS[$counter]} boolean to false."
					exit 1
				fi
			fi
		fi
		counter=$((counter+1))
	done
}

function RewriteSections {
	local config_file="${1}"

	sed -i'.tmp' 's/## ---------- GENERAL OPTIONS/[GENERAL]/g' "$config_file"
	sed -i'.tmp' 's/## ---------- REMOTE OPTIONS/[REMOTE_OPTIONS]/g' "$config_file"
	sed -i'.tmp' 's/## ---------- REMOTE SYNC OPTIONS/[REMOTE_OPTIONS]/g' "$config_file"
	sed -i'.tmp' 's/## ---------- MISC OPTIONS/[MISC_OPTIONS]/g' "$config_file"
	sed -i'.tmp' 's/## ---------- BACKUP AND DELETION OPTIONS/[BACKUP_DELETE_OPTIONS]/g' "$config_file"
	sed -i'.tmp' 's/## ---------- BACKUP AND TRASH OPTIONS/[BACKUP_DELETE_OPTIONS]/g' "$config_file"
	sed -i'.tmp' 's/## ---------- RESUME OPTIONS/[RESUME_OPTIONS]/g' "$config_file"
	sed -i'.tmp' 's/## ---------- ALERT OPTIONS/[ALERT_OPTIONS]/g' "$config_file"
	sed -i'.tmp' 's/## ---------- EXECUTION HOOKS/[EXECUTION_HOOKS]/g' "$config_file"
}

function UpdateConfigHeader {
	local config_file="${1}"

	if ! grep "^CONFIG_FILE_REVISION=" > /dev/null "$config_file"; then
		if grep "\[GENERAL\]" > /dev/null "$config_file"; then
			sed -i'.tmp' '/^\[GENERAL\]$/a\'$'\n'CONFIG_FILE_REVISION=$CONFIG_FILE_REVISION$'\n''' "$config_file"
		else
			sed -i'.tmp' '/.*onfig file rev.*/a\'$'\n'CONFIG_FILE_REVISION=$CONFIG_FILE_REVISION$'\n''' "$config_file"
		fi
		# "onfig file rev" to deal with earlier variants of the file where c was lower or uppercase
		sed -i'.tmp' 's/.*onfig file rev.*//' "$config_file"
		rm -f "$config_file.tmp"
	fi
}

_QUICK_SYNC=0

for i in "$@"
do
	case $i in
		--master=*)
		MASTER_SYNC_DIR=${i##*=}
		_QUICK_SYNC=$((_QUICK_SYNC + 1))
		;;
		--slave=*)
		SLAVE_SYNC_DIR=${i##*=}
		_QUICK_SYNC=$((_QUICK_SYNC + 1))
		;;
		--rsakey=*)
		SSH_RSA_PRIVATE_KEY=${i##*=}
		;;
		--sync-id=*)
		SYNC_ID=${i##*=}
		;;
	esac
done

if [ $_QUICK_SYNC -eq 2 ]; then
	Init
	RenameStateFiles "$MASTER_SYNC_DIR"
	RenameStateFiles "$SLAVE_SYNC_DIR"

elif [ "$1" != "" ] && [ -f "$1" ] && [ -w "$1" ]; then
	CONF_FILE="$1"
	# Make sure there is no ending slash
	CONF_FILE="${CONF_FILE%/}"
	LoadConfigFile "$CONF_FILE"
	Init
	CheckAndBackup "$CONF_FILE"
	RewriteSections "$CONF_FILE"
	RewriteOldConfigFiles "$CONF_FILE"
	AddMissingConfigOptionsAndFixBooleans "$CONF_FILE"
	UpdateConfigHeader "$CONF_FILE"
	RenameStateFiles "$MASTER_SYNC_DIR"
	RenameStateFiles "$SLAVE_SYNC_DIR"
else
	Usage
fi
