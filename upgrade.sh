#!/bin/bash

PROGRAM="Osync instance upagrade script" # Rsync based two way sync engine with fault tolerance
AUTHOR="(L) 2015 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION="1.0x to v1.1"
PROGRAM_BUILD=2015091801

function Init {
	TREE_CURRENT_FILENAME="-tree-current-$SYNC_ID"
	TREE_AFTER_FILENAME="-tree-after-$SYNC_ID"
	TREE_AFTER_FILENAME_NO_SUFFIX="-tree-after-$SYNC_ID"
	DELETED_LIST_FILENAME="-deleted-list-$SYNC_ID$"
	FAILED_DELETE_LIST_FILENAME="-failed-delete-$SYNC_ID"
}

function Usage {
	echo "DEV VERSION !!! DO NOT USE"

        echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
        echo $AUTHOR
        echo $CONTACT
        echo ""
        echo "This script migrates osync v1.0x setups to v1.1 by updating state filenames and config files."
	echo ""
	echo "Usage: migrate.sh /path/to/config_file.conf"
	echo "Usage: migrate.sh --replica=/path/to/replica --sync-id=someid"
	echo ""
	echo "This script must be run manually on all replicas. If slave replica is remote, must be run locally on slave system."
	echo "If sync-id is not specified, it will assume handling a quicksync task."
	echo "Config files must also be updated if they exist."

	exit 1
}

function RenameStateFiles {
	local state_dir="${1}" # Absolute path to statedir

	# Make sure there is no ending slash
	state_dir="${state_dir%/}/"

	mv -f "$state_dir""master"$TREE_CURRENT_FILENAME "$state_dir""initiator"$TREE_CURRENT_FILENAME
	mv -f "$state_dir""master"$TREE_AFTER_FILENAME "$state_dir""initiator"$TREE_AFTER_FILENAME
	mv -f "$state_dir""master"$DELETED_LIST_FILENAME "$state_dir""initiator"$DELETED_LIST_FILENAME
	mv -f "$state_dir""master"$FAILED_DELETE_LIST_FILENAME "$state_dir""initiator"$FAILED_DELETE_LIST_FILENAME

	mv -f "$state_dir""master"$TREE_CURRENT_FILENAME"-dry" "$state_dir""initiator"$TREE_CURRENT_FILENAME"-dry"
	mv -f "$state_dir""master"$TREE_AFTER_FILENAME"-dry" "$state_dir""initiator"$TREE_AFTER_FILENAME"-dry"
	mv -f "$state_dir""master"$DELETED_LIST_FILENAME"-dry" "$state_dir""initiator"$DELETED_LIST_FILENAME"-dry"
	mv -f "$state_dir""master"$FAILED_DELETE_LIST_FILENAME"-dry" "$state_dir""initiator"$FAILED_DELETE_LIST_FILENAME"-dry"

	mv -f "$state_dir""target"$TREE_CURRENT_FILENAME "$state_dir""target"$TREE_CURRENT_FILENAME
	mv -f "$state_dir""target"$TREE_AFTER_FILENAME "$state_dir""target"$TREE_AFTER_FILENAME
	mv -f "$state_dir""target"$DELETED_LIST_FILENAME "$state_dir""target"$DELETED_LIST_FILENAME
	mv -f "$state_dir""target"$FAILED_DELETE_LIST_FILENAME "$state_dir""target"$FAILED_DELETE_LIST_FILENAME

	mv -f "$state_dir""target"$TREE_CURRENT_FILENAME"-dry" "$state_dir""target"$TREE_CURRENT_FILENAME"-dry"
	mv -f "$state_dir""target"$TREE_AFTER_FILENAME"-dry" "$state_dir""target"$TREE_AFTER_FILENAME"-dry"
	mv -f "$state_dir""target"$DELETED_LIST_FILENAME"-dry" "$state_dir""target"$DELETED_LIST_FILENAME"-dry"
	mv -f "$state_dir""target"$FAILED_DELETE_LIST_FILENAME"-dry" "$state_dir""target"$FAILED_DELETE_LIST_FILENAME"-dry"
	}

function RewriteConfigFiles {
	local config_file="${1}"

	#TODO: exclude occurences between doublequotes

	sed -i 's/master/initiator/g' "$config_file"
	sed -i 's/MASTER/INITIATOR/g' "$config_file"
	sed -i 's/slave/target/g' "$config_file"
	sed -i 's/SLAVE/TARGET/g' "$config_file"
}

parameter="$1"
second_param="$2"

if [ "${parameter:0,10}" == "--replica=" ]; then
	if [ "${second_param:0,10}" == "--sync-id=" ]; then
		$SYNC_ID=${second_param##*=}
	else
		$SYNC_ID="quicksync task"
	fi
	Init
	REPLICA_DIR=${i##*=}
	RenameStateFiles "$REPLICA_DIR"

elif [ "$parameter" != "" ] && [ -d "$parameter" ] && [ -w "$parameter" ]; then
	CONF_DIR="$parameter"
	# Make sure there is no ending slash
	CONF_DIR="${CONF_DIR%/}"
	RewriteConfigFiles "$CONF_DIR"
else
	Usage
fi
