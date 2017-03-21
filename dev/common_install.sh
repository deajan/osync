#!/usr/bin/env bash

## Installer script suitable for osync / obackup / pmocr

include #### _OFUNCTIONS_BOOTSTRAP SUBSET ####

PROGRAM=[prgname]

PROGRAM_VERSION=$(grep "PROGRAM_VERSION=" $PROGRAM.sh)
PROGRAM_VERSION=${PROGRAM_VERSION#*=}
PROGRAM_BINARY=$PROGRAM".sh"
PROGRAM_BATCH=$PROGRAM"-batch.sh"
SSH_FILTER="ssh_filter.sh"

SCRIPT_BUILD=2017032101

## osync / obackup / pmocr / zsnap install script
## Tested on RHEL / CentOS 6 & 7, Fedora 23, Debian 7 & 8, Mint 17 and FreeBSD 8, 10 and 11
## Please adapt this to fit your distro needs

# Get current install.sh path from http://stackoverflow.com/a/246128/2635443
SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

CONF_DIR=$FAKEROOT/etc/$PROGRAM
BIN_DIR="$FAKEROOT/usr/local/bin"
SERVICE_DIR_INIT=$FAKEROOT/etc/init.d
# Should be /usr/lib/systemd/system, but /lib/systemd/system exists on debian & rhel / fedora
SERVICE_DIR_SYSTEMD_SYSTEM=$FAKEROOT/lib/systemd/system
SERVICE_DIR_SYSTEMD_USER=$FAKEROOT/etc/systemd/user

if [ "$PROGRAM" == "osync" ]; then
	SERVICE_NAME="osync-srv"
elif [ "$PROGRAM" == "pmocr" ]; then
	SERVICE_NAME="pmocr-srv"
fi

SERVICE_FILE_INIT="$SERVICE_NAME"
SERVICE_FILE_SYSTEMD_SYSTEM="$SERVICE_NAME@.service"
SERVICE_FILE_SYSTEMD_USER="$SERVICE_NAME@.service.user"

## Generic code

## Default log file
if [ -w "$FAKEROOT/var/log" ]; then
	LOG_FILE="$FAKEROOT/var/log/$PROGRAM-install.log"
elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
	LOG_FILE="$HOME/$PROGRAM-install.log"
else
	LOG_FILE="./$PROGRAM-install.log"
fi

include #### QuickLogger SUBSET ####
include #### UrlEncode SUBSET ####
include #### GetLocalOS SUBSET ####
include #### GetConfFileValue SUBSET ####

function SetLocalOSSettings {
	USER=root

	# LOCAL_OS and LOCAL_OS_FULL are global variables set at GetLocalOS

	case $LOCAL_OS in
		*"BSD"*)
		GROUP=wheel
		;;
		*"MacOSX"*)
		GROUP=admin
		;;
		*"msys"*|*"Cygwin"*)
		USER=""
		GROUP=""
		;;
		*)
		GROUP=root
		;;
	esac

	if [ "$LOCAL_OS" == "Android" ] || [ "$LOCAL_OS" == "BusyBox" ]; then
		QuickLogger "Cannot be installed on [$LOCAL_OS]. Please use $PROGRAM.sh directly."
		exit 1
	fi

	if ([ "$USER" != "" ] && [ "$(whoami)" != "$USER" ] && [ "$FAKEROOT" == "" ]); then
		QuickLogger "Must be run as $USER."
		exit 1
	fi

	OS=$(UrlEncode "$LOCAL_OS_FULL")
}

function GetInit {
	if [ -f /sbin/init ]; then
		if file /sbin/init | grep systemd > /dev/null; then
			init="systemd"
		else
			init="initV"
		fi
	else
		QuickLogger "Can't detect initV or systemd. Service files won't be installed. You can still run $PROGRAM manually or via cron."
		init="none"
	fi
}

function CreateDir {
	local dir="${1}"

	if [ ! -d "$dir" ]; then
		mkdir "$dir"
		if [ $? == 0 ]; then
			QuickLogger "Created directory [$dir]."
		else
			QuickLogger "Cannot create directory [$dir]."
			exit 1
		fi
	fi
}

function CopyFile {
	local sourcePath="${1}"
	local destPath="${2}"
	local fileName="${3}"
	local fileMod="${4}"
	local fileUser="${5}"
	local fileGroup="${6}"
	local overwrite="${7:-false}"

	local userGroup=""
	local oldFileName

	if [ -f "$destPath/$fileName" ] && [ $overwrite == false ]; then
		oldFileName="$fileName"
		fileName="$oldFileName.new"
		cp "$sourcePath/$oldFileName" "$destPath/$fileName"
	else
		cp "$sourcePath/$fileName" "$destPath"
	fi

	if [ $? != 0 ]; then
		QuickLogger "Cannot copy [$fileName] to [$destPath]. Make sure to run install script in the directory containing all other files."
		QuickLogger "Also make sure you have permissions to write to [$BIN_DIR]."
		exit 1
	else
		QuickLogger "Copied [$fileName] to [$destPath]."
		if [ "$fileMod" != "" ]; then
			chmod "$fileMod" "$destPath/$fileName"
			if [ $? != 0 ]; then
				QuickLogger "Cannot set file permissions of [$destPath/$fileName] to [$fileMod]."
				exit 1
			else
				QuickLogger "Set file permissions to [$fileMod] on [$destPath/$fileName]."
			fi
		fi

		if [ "$fileUser" != "" ]; then
			userGroup="$fileUser"

			if [ "$fileGroup" != "" ]; then
				userGroup="$userGroup"":$fileGroup"
			fi

			chown "$userGroup" "$destPath/$fileName"
			if [ $? != 0 ]; then
				QuickLogger "Could not set file ownership on [$destPath/$fileName] to [$userGroup]."
				exit 1
			else
				QuickLogger "Set file ownership on [$destPath/$fileName] to [$userGroup]."
			fi
		fi
	fi
}

function CopyExampleFiles {
	exampleFiles=()
	exampleFiles[0]="sync.conf.example"		# osync
	exampleFiles[1]="host_backup.conf.example"	# obackup
	exampleFiles[2]="exclude.list.example"		# osync & obackup
	exampleFiles[3]="snapshot.conf.example"		# zsnap
	exampleFiles[4]="default.conf"			# pmocr

	for file in "${exampleFiles[@]}"; do
		if [ -f "$SCRIPT_PATH/$file" ]; then
			CopyFile "$SCRIPT_PATH" "$CONF_DIR" "$file" "" "" "" false
		fi
	done
}

function CopyProgram {
	binFiles=()
	binFiles[0]="$PROGRAM_BINARY"
	if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "obackup" ]; then
		binFiles[1]="$PROGRAM_BATCH"
		binFiles[2]="$SSH_FILTER"
	fi

	local user=""
	local group=""

	if ([ "$USER" != "" ] && [ "$FAKEROOT" == "" ]); then
		user="$USER"
	fi
	if ([ "$GROUP" != "" ] && [ "$FAKEROOT" == "" ]); then
		group="$GROUP"
	fi

	for file in "${binFiles[@]}"; do
		CopyFile "$SCRIPT_PATH" "$BIN_DIR" "$file" 755 "$user" "$group" true
	done
}

function CopyServiceFiles {
	if ([ "$init" == "systemd" ] && [ -f "$SCRIPT_PATH/$SERVICE_FILE_SYSTEMD_SYSTEM" ]); then
		CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_SYSTEMD_SYSTEM" "$SERVICE_FILE_SYSTEMD_SYSTEM" "" "" "" true
		if [ -f "$SCRIPT_PATH/$SERVICE_FILE_SYSTEMD_SYSTEM_USER" ]; then
			CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_SYSTEMD_USER" "$SERVICE_FILE_SYSTEMD_USER" "" "" "" true
		fi

		QuickLogger "Created [$SERVICE_NAME] service in [$SERVICE_DIR_SYSTEMD_SYSTEM] and [$SERVICE_DIR_SYSTEMD_USER]."
		QuickLogger "Can be activated with [systemctl start SERVICE_NAME@instance.conf] where instance.conf is the name of the config file in $CONF_DIR."
		QuickLogger "Can be enabled on boot with [systemctl enable $SERVICE_NAME@instance.conf]."
		QuickLogger "In userland, active with [systemctl --user start $SERVICE_NAME@instance.conf]."
	elif ([ "$init" == "initV" ] && [ -f "$SCRIPT_PATH/$SERVICE_FILE_INIT" ] && [ -d "$SERVICE_DIR_INIT" ]); then
		CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_INIT" "$SERVICE_FILE_INIT" "755" "" "" true

		QuickLogger "Created osync-srv service in [$SERVICE_DIR_INIT]."
		QuickLogger "Can be activated with [service $OSYNC_SERVICE_FILE_INIT start]."
		QuickLogger "Can be enabled on boot with [chkconfig $OSYNC_SERVICE_FILE_INIT on]."
	else
		QuickLogger "Cannot define what init style is in use on this system. Skipping service file installation."
	fi
}

function Statistics {
	if type wget > /dev/null; then
		wget -qO- "$STATS_LINK" > /dev/null 2>&1
		if [ $? == 0 ]; then
			return 0
		fi
	fi

	if type curl > /dev/null; then
		curl "$STATS_LINK" -o /dev/null > /dev/null 2>&1
		if [ $? == 0 ]; then
			return 0
		fi
	fi

	QuickLogger "Neiter wget nor curl could be used for. Cannot run statistics. Use the provided link please."
	return 1
}

function RemoveFile {
	local file="${1}"

	if [ -f "$file" ]; then
		rm -f "$file"
		if [ $? != 0 ]; then
			QuickLogger "Could not remove file [$file]."
		else
			QuickLogger "Removed file [$file]."
		fi
	else
		QuickLogger "File [$file] not found. Skipping."
	fi
}

function RemoveAll {
	RemoveFile "$BIN_DIR/$PROGRAM_BINARY"
	RemoveFile "$BIN_DIR/$PROGRAM_BATCH"
	if [ ! -f "$BIN_DIR/osync.sh" ] && [ ! -f "$BIN_DIR/obackup.sh" ]; then		# Check if any other program requiring ssh filter is present before removal
		RemoveFile "$BIN_DIR/$SSH_FILTER"
	else
		QuickLogger "Skipping removal of [$BIN_DIR/$SSH_FILTER] because other programs present that need it."
	fi
	RemoveFile "$SERVICE_DIR_SYSTEMD_SYSTEM/$SERVICE_FILE_SYSTEMD_SYSTEM"
	RemoveFile "$SERVICE_DIR_SYSTEMD_USER/$SERVICE_FILE_SYSTEMD_SYSTEM"
	RemoveFile "$SERVICE_DIR_INIT/$SERVICE_FILE_INIT"

	QuickLogger "Skipping configuration files in [$CONF_DIR]. You may remove this directory manually."
}

function Usage {
	echo "Installs $PROGRAM into $BIN_DIR"
	echo "options:"
	echo "--silent		Will log and bypass user interaction."
	echo "--no-stats	Used with --silent in order to refuse sending anonymous install stats."
	echo "--remove          Remove the program."
	exit 127
}

_LOGGER_SILENT=false
_STATS=1
ACTION="install"

for i in "$@"
do
	case $i in
		--silent)
		_LOGGER_SILENT=true
		;;
		--no-stats)
		_STATS=0
		;;
		--remove)
		ACTION="uninstall"
		;;
		--help|-h|-?)
		Usage
	esac
done

if [ "$FAKEROOT" != "" ]; then
	mkdir -p "$SERVICE_DIR_SYSTEMD_SYSTEM" "$SERVICE_DIR_SYSTEMD_USER" "$BIN_DIR"
fi

GetLocalOS
SetLocalOSSettings
GetInit

STATS_LINK="http://instcount.netpower.fr?program=$PROGRAM&version=$PROGRAM_VERSION&os=$OS&action=$ACTION"

if [ "$ACTION" == "uninstall" ]; then
	RemoveAll
	QuickLogger "$PROGRAM uninstalled."
else
	CreateDir "$CONF_DIR"
	CreateDir "$BIN_DIR"
	CopyExampleFiles
	CopyProgram
	CopyServiceFiles
	QuickLogger "$PROGRAM installed. Use with $BIN_DIR/$PROGRAM"
	if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "obackup" ]; then
		QuickLogger ""
		QuickLogger "If connecting remotely, consider setup ssh filter to enhance security."
		QuickLogger ""
	fi
fi

if [ $_STATS -eq 1 ]; then
	if [ $_LOGGER_SILENT == true ]; then
		Statistics
	else
		QuickLogger "In order to make usage statistics, the script would like to connect to $STATS_LINK"
		read -r -p "No data except those in the url will be send. Allow [Y/n] " response
		case $response in
			[nN])
			exit
			;;
			*)
			Statistics
			exit $?
			;;
		esac
	fi
fi
