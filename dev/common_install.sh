#!/usr/bin/env bash

include #### _OFUNCTIONS_BOOTSTRAP SUBSET ####

PROGRAM=[prgname]
PROGRAM_VERSION=[version]
PROGRAM_BINARY=$PROGRAM".sh"
PROGRAM_BATCH=$PROGRAM"-batch.sh"
SCRIPT_BUILD=2016121301

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

## osync specific code
OSYNC_SERVICE_FILE_INIT="osync-srv"
OSYNC_SERVICE_FILE_SYSTEMD_SYSTEM="osync-srv@.service"
OSYNC_SERVICE_FILE_SYSTEMD_USER="osync-srv@.service.user"

## pmocr specfic code
PMOCR_SERVICE_FILE_INIT="pmocr-srv"
PMOCR_SERVICE_FILE_SYSTEMD_SYSTEM="pmocr-srv@.service"

## Generic code

## Default log file
if [ -w $FAKEROOT/var/log ]; then
	LOG_FILE="$FAKEROOT/var/log/$PROGRAM-install.log"
elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
	LOG_FILE="$HOME/$PROGRAM-install.log"
else
	LOG_FILE="./$PROGRAM-install.log"
fi

include #### QuickLogger SUBSET ####
include #### UrlEncode SUBSET ####
include #### GetLocalOS SUBSET ####
function SetLocalOSSettings {
	USER=root

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

	if [ "$LOCAL_OS" == "Android" ] || [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "BusyBox" ]; then
		QuickLogger "Cannot be installed on [$LOCAL_OS]. Please use $PROGRAM.sh directly."
		exit 1
	fi

	if ([ "$USER" != "" ] && [ "$(whoami)" != "$USER" ] && [ "$FAKEROOT" == "" ]); then
		QuickLogger "Must be run as $USER."
		exit 1
	fi

	OS=$(UrlEncode "$localOsVar")
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

function CreateConfDir {
	if [ ! -d "$CONF_DIR" ]; then
		mkdir "$CONF_DIR"
		if [ $? == 0 ]; then
			QuickLogger "Created directory [$CONF_DIR]."
		else
			QuickLogger "Cannot create directory [$CONF_DIR]."
			exit 1
		fi
	else
		QuickLogger "Config directory [$CONF_DIR] exists."
	fi
}

function CopyExampleFiles {
	if [ -f "$SCRIPT_PATH/sync.conf.example" ]; then
		cp "$SCRIPT_PATH/sync.conf.example" "$CONF_DIR/sync.conf.example"
	fi

	if [ -f "$SCRIPT_PATH/host_backup.conf.example" ]; then
		cp "$SCRIPT_PATH/host_backup.conf.example" "$CONF_DIR/host_backup.conf.example"
	fi

	if [ -f "$SCRIPT_PATH/exlude.list.example" ]; then
		cp "$SCRIPT_PATH/exclude.list.example" "$CONF_DIR/exclude.list.example"
	fi

	if [ -f "$SCRIPT_PATH/snapshot.conf.example" ]; then
		cp "$SCRIPT_PATH/snapshot.conf.example" "$CONF_DIR/snapshot.conf.example"
	fi

	if [ -f "$SCRIPT_PATH/default.conf" ]; then
		if [ -f "$CONF_DIR/default.conf" ]; then
			cp "$SCRIPT_PATH/default.conf" "$CONF_DIR/default.conf.new"
			QuickLogger "Copied default.conf to [$CONF_DIR/default.conf.new]."
		else
			cp "$SCRIPT_PATH/default.conf" "$CONF_DIR/default.conf"
		fi
	fi
}

function CopyProgram {
	cp "$SCRIPT_PATH/$PROGRAM_BINARY" "$BIN_DIR"
	if [ $? != 0 ]; then
		QuickLogger "Cannot copy $PROGRAM_BINARY to [$BIN_DIR]. Make sure to run install script in the directory containing all other files."
		QuickLogger "Also make sure you have permissions to write to [$BIN_DIR]."
		exit 1
	else
		chmod 755 "$BIN_DIR/$PROGRAM_BINARY"
		QuickLogger "Copied $PROGRAM_BINARY to [$BIN_DIR]."
	fi

	if [ -f "$SCRIPT_PATH/$PROGRAM_BATCH" ]; then
		cp "$SCRIPT_PATH/$PROGRAM_BATCH" "$BIN_DIR"
		if [ $? != 0 ]; then
			QuickLogger "Cannot copy $PROGRAM_BATCH to [$BIN_DIR]."
		else
			chmod 755 "$BIN_DIR/$PROGRAM_BATCH"
			QuickLogger "Copied $PROGRAM_BATCH to [$BIN_DIR]."
		fi
	fi

	if [  -f "$SCRIPT_PATH/ssh_filter.sh" ]; then
		cp "$SCRIPT_PATH/ssh_filter.sh" "$BIN_DIR"
		if [ $? != 0 ]; then
			QuickLogger "Cannot copy ssh_filter.sh to [$BIN_DIR]."
		else
			chmod 755 "$BIN_DIR/ssh_filter.sh"
			if ([ "$USER" != "" ] && [ "$GROUP" != "" ] && [ "$FAKEROOT" == "" ]); then
				chown $USER:$GROUP "$BIN_DIR/ssh_filter.sh"
			fi
			QuickLogger "Copied ssh_filter.sh to [$BIN_DIR]."
		fi
	fi
}

function CopyServiceFiles {
	# OSYNC SPECIFIC
	if ([ "$init" == "systemd" ] && [ -f "$SCRIPT_PATH/$OSYNC_SERVICE_FILE_SYSTEMD_SYSTEM" ]); then
		cp "$SCRIPT_PATH/$OSYNC_SERVICE_FILE_SYSTEMD_SYSTEM" "$SERVICE_DIR_SYSTEMD_SYSTEM" && cp "$SCRIPT_PATH/$OSYNC_SERVICE_FILE_SYSTEMD_USER" "$SERVICE_DIR_SYSTEMD_USER/$SERVICE_FILE_SYSTEMD_SYSTEM"
		if [ $? != 0 ]; then
			QuickLogger "Cannot copy the systemd file to [$SERVICE_DIR_SYSTEMD_SYSTEM] or [$SERVICE_DIR_SYSTEMD_USER]."
		else
			QuickLogger "Created osync-srv service in [$SERVICE_DIR_SYSTEMD_SYSTEM] and [$SERVICE_DIR_SYSTEMD_USER]."
			QuickLogger "Can be activated with [systemctl start osync-srv@instance.conf] where instance.conf is the name of the config file in $CONF_DIR."
			QuickLogger "Can be enabled on boot with [systemctl enable osync-srv@instance.conf]."
			QuickLogger "In userland, active with [systemctl --user start osync-srv@instance.conf]."
		fi
	elif ([ "$init" == "initV" ] && [ -f "$SCRIPT_PATH/$OSYNC_SERVICE_FILE_INIT" ]); then
		cp "$SCRIPT_PATH/$OSYNC_SERVICE_FILE_INIT" "$SERVICE_DIR_INIT"
		if [ $? != 0 ]; then
			QuickLogger "Cannot copy osync-srv to [$SERVICE_DIR_INIT]."
		else
			chmod 755 "$SERVICE_DIR_INIT/$OSYNC_SERVICE_FILE_INIT"
			QuickLogger "Created osync-srv service in [$SERVICE_DIR_INIT]."
			QuickLogger "Can be activated with [service $OSYNC_SERVICE_FILE_INIT start]."
			QuickLogger "Can be enabled on boot with [chkconfig $OSYNC_SERVICE_FILE_INIT on]."
		fi
	fi

	# PMOCR SPECIFIC
	if ([ "$init" == "systemd" ] && [ -f "$SCRIPT_PATH/$PMOCR_SERVICE_FILE_SYSTEMD_SYSTEM" ]); then
		cp "$SCRIPT_PATH/$PMOCR_SERVICE_FILE_SYSTEMD_SYSTEM" "$SERVICE_DIR_SYSTEMD_SYSTEM"
		if [ $? != 0 ]; then
			QuickLogger "Cannot copy the systemd file to [$SERVICE_DIR_SYSTEMD_SYSTEM] or [$SERVICE_DIR_SYSTEMD_USER]."
		else
			QuickLogger "Created pmocr-srv service in [$SERVICE_DIR_SYSTEMD_SYSTEM] and [$SERVICE_DIR_SYSTEMD_USER]."
			QuickLogger "Can be activated with [systemctl start pmocr-srv@default.conf] where default.conf is the name of the config file in $CONF_DIR."
			QuickLogger "Can be enabled on boot with [systemctl enable pmocr-srv@default.conf]."
		fi
	elif ([ "$init" == "initV" ] && [ -f "$SCRIPT_PATH/$PMOCR_SERVICE_FILE_INIT" ]); then
		cp "$SCRIPT_PATH/$PMOCR_SERVICE_FILE_INIT" "$SERVICE_DIR_INIT"
		if [ $? != 0 ]; then
			QuickLogger "Cannot copy pmoct-srv to [$SERVICE_DIR_INIT]."
		else
			chmod 755 "$SERVICE_DIR_INIT/$PMOCR_SERVICE_FILE_INIT"
			QuickLogger "Created osync-srv service in [$SERVICE_DIR_INIT]."
			QuickLogger "Can be activated with [service $PMOCR_SERVICE_FILE_INIT start]."
			QuickLogger "Can be enabled on boot with [chkconfig $PMOCR_SERVICE_FILE_INIT on]."
		fi
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

function Usage {
	echo "Installs $PROGRAM into $BIN_DIR"
	echo "options:"
	echo "--silent		Will log and bypass user interaction."
	echo "--no-stats	Used with --silent in order to refuse sending anonymous install stats."
	exit 127
}

_LOGGER_SILENT=false
_STATS=1
for i in "$@"
do
	case $i in
		--silent)
		_LOGGER_SILENT=true
		;;
		--no-stats)
		_STATS=0
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
CreateConfDir
CopyExampleFiles
CopyProgram
GetInit
CopyServiceFiles

STATS_LINK="http://instcount.netpower.fr?program=$PROGRAM&version=$PROGRAM_VERSION&os=$OS"

QuickLogger "$PROGRAM installed. Use with $BIN_DIR/$PROGRAM"
if [ $_STATS -eq 1 ]; then
	if [ $_LOGGER_SILENT == true ]; then
		Statistics
	else
		QuickLogger "In order to make install statistics, the script would like to connect to $STATS_LINK"
		read -r -p "No data except those in the url will be send. Allow [Y/n]" response
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
