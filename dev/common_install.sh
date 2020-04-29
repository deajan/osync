#!/usr/bin/env bash

## Installer script suitable for osync / obackup / pmocr

PROGRAM=[prgname]

PROGRAM_VERSION=$(grep "PROGRAM_VERSION=" $PROGRAM.sh)
PROGRAM_VERSION=${PROGRAM_VERSION#*=}
PROGRAM_BINARY=$PROGRAM".sh"
PROGRAM_BATCH=$PROGRAM"-batch.sh"
SSH_FILTER="ssh_filter.sh"

SCRIPT_BUILD=2020042901
INSTANCE_ID="installer-$SCRIPT_BUILD"

## osync / obackup / pmocr / zsnap install script
## Tested on RHEL / CentOS 6 & 7, Fedora 23, Debian 7 & 8, Mint 17 and FreeBSD 8, 10 and 11
## Please adapt this to fit your distro needs

include #### OFUNCTIONS MICRO SUBSET ####

# Get current install.sh path from http://stackoverflow.com/a/246128/2635443
SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

_LOGGER_SILENT=false
_STATS=1
ACTION="install"
FAKEROOT=""

## Default log file
if [ -w "$FAKEROOT/var/log" ]; then
	LOG_FILE="$FAKEROOT/var/log/$PROGRAM-install.log"
elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
	LOG_FILE="$HOME/$PROGRAM-install.log"
else
	LOG_FILE="./$PROGRAM-install.log"
fi

include #### UrlEncode SUBSET ####
include #### GetLocalOS SUBSET ####
include #### GetConfFileValue SUBSET ####
include #### CleanUp SUBSET ####
include #### GenericTrapQuit SUBSET ####

function SetLocalOSSettings {
	USER=root
	DO_INIT=true

	# LOCAL_OS and LOCAL_OS_FULL are global variables set at GetLocalOS

	case $LOCAL_OS in
		*"BSD"*)
		GROUP=wheel
		;;
		*"MacOSX"*)
		GROUP=admin
		DO_INIT=false
		;;
		*"Cygwin"*|*"Android"*|*"msys"*|*"BusyBox"*)
		USER=""
		GROUP=""
		DO_INIT=false
		;;
		*)
		GROUP=root
		;;
	esac

	if [ "$LOCAL_OS" == "Android" ] || [ "$LOCAL_OS" == "BusyBox" ]; then
		Logger "Cannot be installed on [$LOCAL_OS]. Please use $PROGRAM.sh directly." "CRITICAL"
		exit 1
	fi

	if ([ "$USER" != "" ] && [ "$(whoami)" != "$USER" ] && [ "$FAKEROOT" == "" ]); then
		Logger "Must be run as $USER." "CRITICAL"
		exit 1
	fi

	OS=$(UrlEncode "$LOCAL_OS_FULL")
}

function GetInit {
	if [ -f /sbin/openrc-run ]; then
		init="openrc"
		Logger "Detected openrc." "NOTICE"
	elif [ -f /sbin/init ]; then
		if file /sbin/init | grep systemd > /dev/null; then
			init="systemd"
			Logger "Detected systemd." "NOTICE"
		else
			init="initV"
			Logger "Detected initV." "NOTICE"
		fi
	else
		Logger "Can't detect initV, systemd or openRC. Service files won't be installed. You can still run $PROGRAM manually or via cron." "WARN"
		init="none"
	fi
}

function CreateDir {
	local dir="${1}"
	local dirMask="${2}"
	local dirUser="${3}"
	local dirGroup="${4}"

	if [ ! -d "$dir" ]; then
		(
		if [ $(IsInteger $dirMask) -eq 1 ]; then
			umask $dirMask
		fi
		mkdir -p "$dir"
		)
		if [ $? == 0 ]; then
			Logger "Created directory [$dir]." "NOTICE"
		else
			Logger "Cannot create directory [$dir]." "CRITICAL"
			exit 1
		fi
	fi

	if [ "$dirUser" != "" ]; then
		userGroup="$dirUser"
		if [ "$dirGroup" != "" ]; then
			userGroup="$userGroup"":$dirGroup"
		fi
		chown "$userGroup" "$dir"
		if [ $? != 0 ]; then
			Logger "Could not set directory ownership on [$dir] to [$userGroup]." "CRITICAL"
			exit 1
		else
			Logger "Set file ownership on [$dir] to [$userGroup]." "NOTICE"
		fi
	fi
}

function CopyFile {
	local sourcePath="${1}"
	local destPath="${2}"
	local sourceFileName="${3}"
	local destFileName="${4}"
	local fileMod="${5}"
	local fileUser="${6}"
	local fileGroup="${7}"
	local overwrite="${8:-false}"

	local userGroup=""

	if [ "$destFileName" == "" ]; then
		destFileName="$sourceFileName"
	fi

	if [ -f "$destPath/$destFileName" ] && [ $overwrite == false ]; then
		destFileName="$sourceFileName.new"
		Logger "Copying [$sourceFileName] to [$destPath/$destFileName]." "NOTICE"
	fi

	cp "$sourcePath/$sourceFileName" "$destPath/$destFileName"
	if [ $? != 0 ]; then
		Logger "Cannot copy [$sourcePath/$sourceFileName] to [$destPath/$destFileName]. Make sure to run install script in the directory containing all other files." "CRITICAL"
		Logger "Also make sure you have permissions to write to [$BIN_DIR]." "ERROR"
		exit 1
	else
		Logger "Copied [$sourcePath/$sourceFileName] to [$destPath/$destFileName]." "NOTICE"
		if [ "$(IsInteger $fileMod)" -eq 1 ]; then
			chmod "$fileMod" "$destPath/$destFileName"
			if [ $? != 0 ]; then
				Logger "Cannot set file permissions of [$destPath/$destFileName] to [$fileMod]." "CRITICAL"
				exit 1
			else
				Logger "Set file permissions to [$fileMod] on [$destPath/$destFileName]." "NOTICE"
			fi
		elif [ "$fileMod" != "" ]; then
			Logger "Bogus filemod [$fileMod] for [$destPath] given." "WARN"
		fi

		if [ "$fileUser" != "" ]; then
			userGroup="$fileUser"

			if [ "$fileGroup" != "" ]; then
				userGroup="$userGroup"":$fileGroup"
			fi

			chown "$userGroup" "$destPath/$destFileName"
			if [ $? != 0 ]; then
				Logger "Could not set file ownership on [$destPath/$destFileName] to [$userGroup]." "CRITICAL"
				exit 1
			else
				Logger "Set file ownership on [$destPath/$destFileName] to [$userGroup]." "NOTICE"
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
			CopyFile "$SCRIPT_PATH" "$CONF_DIR" "$file" "$file" "" "" "" false
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
		CopyFile "$SCRIPT_PATH" "$BIN_DIR" "$file" "$file" 755 "$user" "$group" true
	done
}

function CopyServiceFiles {
	if ([ "$init" == "systemd" ] && [ -f "$SCRIPT_PATH/$SERVICE_FILE_SYSTEMD_SYSTEM" ]); then
		CreateDir "$SERVICE_DIR_SYSTEMD_SYSTEM"
		CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_SYSTEMD_SYSTEM" "$SERVICE_FILE_SYSTEMD_SYSTEM" "$SERVICE_FILE_SYSTEMD_SYSTEM" "" "" "" true
		if [ -f "$SCRIPT_PATH/$SERVICE_FILE_SYSTEMD_USER" ]; then
			CreateDir "$SERVICE_DIR_SYSTEMD_USER"
			CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_SYSTEMD_USER" "$SERVICE_FILE_SYSTEMD_USER" "$SERVICE_FILE_SYSTEMD_USER" "" "" "" true
		fi

		if [ -f "$SCRIPT_PATH/$TARGET_HELPER_SERVICE_FILE_SYSTEMD_SYSTEM" ]; then
			CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_SYSTEMD_SYSTEM" "$TARGET_HELPER_SERVICE_FILE_SYSTEMD_SYSTEM" "$TARGET_HELPER_SERVICE_FILE_SYSTEMD_SYSTEM" "" "" "" true
			Logger "Created optional service [$TARGET_HELPER_SERVICE_NAME] with same specifications as below." "NOTICE"
		fi
		if [ -f "$SCRIPT_PATH/$TARGET_HELPER_SERVICE_FILE_SYSTEMD_USER" ]; then
			CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_SYSTEMD_USER" "$TARGET_HELPER_SERVICE_FILE_SYSTEMD_USER" "$TARGET_HELPER_SERVICE_FILE_SYSTEMD_USER" "" "" "" true
		fi


		Logger "Created [$SERVICE_NAME] service in [$SERVICE_DIR_SYSTEMD_SYSTEM] and [$SERVICE_DIR_SYSTEMD_USER]." "NOTICE"
		Logger "Can be activated with [systemctl start SERVICE_NAME@instance.conf] where instance.conf is the name of the config file in $CONF_DIR." "NOTICE"
		Logger "Can be enabled on boot with [systemctl enable $SERVICE_NAME@instance.conf]." "NOTICE"
		Logger "In userland, active with [systemctl --user start $SERVICE_NAME@instance.conf]." "NOTICE"
	elif ([ "$init" == "initV" ] && [ -f "$SCRIPT_PATH/$SERVICE_FILE_INIT" ] && [ -d "$SERVICE_DIR_INIT" ]); then
		#CreateDir "$SERVICE_DIR_INIT"
		CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_INIT" "$SERVICE_FILE_INIT" "$SERVICE_FILE_INIT" "755" "" "" true
		if [ -f "$SCRIPT_PATH/$TARGET_HELPER_SERVICE_FILE_INIT" ]; then
			CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_INIT" "$TARGET_HELPER_SERVICE_FILE_INIT" "$TARGET_HELPER_SERVICE_FILE_INIT" "755" "" "" true
			Logger "Created optional service [$TARGET_HELPER_SERVICE_NAME] with same specifications as below." "NOTICE"
		fi
		Logger "Created [$SERVICE_NAME] service in [$SERVICE_DIR_INIT]." "NOTICE"
		Logger "Can be activated with [service $SERVICE_FILE_INIT start]." "NOTICE"
		Logger "Can be enabled on boot with [chkconfig $SERVICE_FILE_INIT on]." "NOTICE"
	elif ([ "$init" == "openrc" ] && [ -f "$SCRIPT_PATH/$SERVICE_FILE_OPENRC" ] && [ -d "$SERVICE_DIR_OPENRC" ]); then
		# Rename service to usual service file
		CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_OPENRC" "$SERVICE_FILE_OPENRC" "$SERVICE_FILE_INIT" "755" "" "" true
		if [ -f "$SCRPT_PATH/$TARGET_HELPER_SERVICE_FILE_OPENRC" ]; then
			CopyFile "$SCRIPT_PATH" "$SERVICE_DIR_OPENRC" "$TARGET_HELPER_SERVICE_FILE_OPENRC" "$TARGET_HELPER_SERVICE_FILE_OPENRC" "755" "" "" true
			Logger "Created optional service [$TARGET_HELPER_SERVICE_NAME] with same specifications as below." "NOTICE"
		fi
		Logger "Created [$SERVICE_NAME] service in [$SERVICE_DIR_OPENRC]." "NOTICE"
		Logger "Can be activated with [rc-update add $SERVICE_NAME.instance] where instance is a configuration file found in /etc/osync." "NOTICE"
	else
		Logger "Cannot properly find how to deal with init on this system. Skipping service file installation." "NOTICE"
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

	Logger "Neiter wget nor curl could be used for. Cannot run statistics. Use the provided link please." "WARN"
	return 1
}

function RemoveFile {
	local file="${1}"

	if [ -f "$file" ]; then
		rm -f "$file"
		if [ $? != 0 ]; then
			Logger "Could not remove file [$file]." "ERROR"
		else
			Logger "Removed file [$file]." "NOTICE"
		fi
	else
		Logger "File [$file] not found. Skipping." "NOTICE"
	fi
}

function RemoveAll {
	RemoveFile "$BIN_DIR/$PROGRAM_BINARY"

	if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "obackup" ]; then
		RemoveFile "$BIN_DIR/$PROGRAM_BATCH"
	fi

	if [ ! -f "$BIN_DIR/osync.sh" ] && [ ! -f "$BIN_DIR/obackup.sh" ]; then		# Check if any other program requiring ssh filter is present before removal
		RemoveFile "$BIN_DIR/$SSH_FILTER"
	else
		Logger "Skipping removal of [$BIN_DIR/$SSH_FILTER] because other programs present that need it." "NOTICE"
	fi
	RemoveFile "$SERVICE_DIR_SYSTEMD_SYSTEM/$SERVICE_FILE_SYSTEMD_SYSTEM"
	RemoveFile "$SERVICE_DIR_SYSTEMD_USER/$SERVICE_FILE_SYSTEMD_USER"
	RemoveFile "$SERVICE_DIR_INIT/$SERVICE_FILE_INIT"

	RemoveFile "$TARGET_HELPER_SERVICE_DIR_SYSTEMD_SYSTEM/$SERVICE_FILE_SYSTEMD_SYSTEM"
	RemoveFile "$TARGET_HELPER_SERVICE_DIR_SYSTEMD_USER/$SERVICE_FILE_SYSTEMD_USER"
	RemoveFile "$TARGET_HELPER_SERVICE_DIR_INIT/$SERVICE_FILE_INIT"

	Logger "Skipping configuration files in [$CONF_DIR]. You may remove this directory manually." "NOTICE"
}

function Usage {
	echo "Installs $PROGRAM into $BIN_DIR"
	echo "options:"
	echo "--silent		Will log and bypass user interaction."
	echo "--no-stats	Used with --silent in order to refuse sending anonymous install stats."
	echo "--remove          Remove the program."
	echo "--prefix=/path    Use prefix to install path."
	exit 127
}

############################## Script entry point

function GetCommandlineArguments {
        for i in "$@"; do
                case $i in
			--prefix=*)
                        FAKEROOT="${i##*=}"
                        ;;
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
			;;
                        *)
			Logger "Unknown option '$i'" "ERROR"
			Usage
			exit
                        ;;
                esac
	done
}

GetCommandlineArguments "$@"

CONF_DIR=$FAKEROOT/etc/$PROGRAM
BIN_DIR="$FAKEROOT/usr/local/bin"
SERVICE_DIR_INIT=$FAKEROOT/etc/init.d
# Should be /usr/lib/systemd/system, but /lib/systemd/system exists on debian & rhel / fedora
SERVICE_DIR_SYSTEMD_SYSTEM=$FAKEROOT/lib/systemd/system
SERVICE_DIR_SYSTEMD_USER=$FAKEROOT/etc/systemd/user
SERVICE_DIR_OPENRC=$FAKEROOT/etc/init.d

if [ "$PROGRAM" == "osync" ]; then
	SERVICE_NAME="osync-srv"
	TARGET_HELPER_SERVICE_NAME="osync-target-helper-srv"

	TARGET_HELPER_SERVICE_FILE_INIT="$TARGET_HELPER_SERVICE_NAME"
	TARGET_HELPER_SERVICE_FILE_SYSTEMD_SYSTEM="$TARGET_HELPER_SERVICE_NAME@.service"
	TARGET_HELPER_SERVICE_FILE_SYSTEMD_USER="$TARGET_HELPER_SERVICE_NAME@.service.user"
	TARGET_HELPER_SERVICE_FILE_OPENRC="$TARGET_HELPER_SERVICE_NAME-openrc"
elif [ "$PROGRAM" == "pmocr" ]; then
	SERVICE_NAME="pmocr-srv"
fi

SERVICE_FILE_INIT="$SERVICE_NAME"
SERVICE_FILE_SYSTEMD_SYSTEM="$SERVICE_NAME@.service"
SERVICE_FILE_SYSTEMD_USER="$SERVICE_NAME@.service.user"
SERVICE_FILE_OPENRC="$SERVICE_NAME-openrc"

## Generic code

trap GenericTrapQuit TERM EXIT HUP QUIT

if [ ! -w "$(dirname $LOG_FILE)" ]; then
        echo "Cannot write to log [$(dirname $LOG_FILE)]."
else
        Logger "Script begin, logging to [$LOG_FILE]." "DEBUG"
fi

# Set default umask
umask 0022

GetLocalOS
SetLocalOSSettings
# On Mac OS this always produces a warning which causes the installer to fail with exit code 2
# Since we know it won't work anyway, and that's fine, just skip this step
if $DO_INIT; then
	GetInit
fi

STATS_LINK="http://instcount.netpower.fr?program=$PROGRAM&version=$PROGRAM_VERSION&os=$OS&action=$ACTION"

if [ "$ACTION" == "uninstall" ]; then
	RemoveAll
	Logger "$PROGRAM uninstalled." "NOTICE"
else
	CreateDir "$CONF_DIR"
	CreateDir "$BIN_DIR"
	CopyExampleFiles
	CopyProgram
	if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "pmocr" ]; then
		CopyServiceFiles
	fi
	Logger "$PROGRAM installed. Use with $BIN_DIR/$PROGRAM_BINARY" "NOTICE"
	if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "obackup" ]; then
		echo ""
		Logger "If connecting remotely, consider setup ssh filter to enhance security." "NOTICE"
		echo ""
	fi
fi

if [ $_STATS -eq 1 ]; then
	if [ $_LOGGER_SILENT == true ]; then
		Statistics
	else
		Logger "In order to make usage statistics, the script would like to connect to $STATS_LINK" "NOTICE"
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
