#!/bin/bash

PROGRAM="Osync instance upagrade script" # Rsync based two way sync engine with fault tolerance
AUTHOR="(L) 2015 by Orsiris \"Ozy\" de Jong"
CONTACT="http://www.netpower.fr/osync - ozy@netpower.fr"
PROGRAM_VERSION="1.0x to v1.1"
PROGRAM_BUILD=2015091801

TREE_CURRENT_FILENAME="-tree-current-$SYNC_ID"
TREE_AFTER_FILENAME="-tree-after-$SYNC_ID"
TREE_AFTER_FILENAME_NO_SUFFIX="-tree-after-$SYNC_ID"
DELETED_LIST_FILENAME="-deleted-list-$SYNC_ID$"
FAILED_DELETE_LIST_FILENAME="-failed-delete-$SYNC_ID"

function Usage {
	echo "DEV VERSION !!! DO NOT USE"

        echo "$PROGRAM $PROGRAM_VERSION $PROGRAM_BUILD"
        echo $AUTHOR
        echo $CONTACT
        echo ""
        echo "This script migrates osync v1.0x setups to v1.1 by updating config files and state directories"
	echo "Usage: migrate.sh /path/to/config/directory"     
	exit 1
}


if [ "$1" == "" ] || [ ! -d "$1" ] || [ ! -w "$1" ]; then
	Usage;
else
	CONF_DIR="$1"
	# Make sure there is no ending slash
	CONF_DIR="${CONF_DIR%/}"
fi

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

function ExtractInitiatorFromConfigFile {
	local config_file="${1}"

	#TODO: Extract initiator from config file
	echo "$initiator_path"
}

function ExtractTargetFromConfigFile {
	local config_file="${1}"

	#TODO: Extract target from config file
	echo "$target_path"
}

for i in "$CONF_DIR/*.conf"; do
	if [ "$i" != "$CONF_DIR/*.conf" ]; then
		echo "Updating config file $i"
		RewriteConfigFiles "$i"
		echo "Updating master state dir for config $i"
		RenameStateFilesLocal $(ExtractInitiatorFromConfigFile $i)
		RenameStateFilesRemote $(ExtractTargetFromConfigFile $i)
done
