#!/usr/bin/env bash

PROGRAM=[prgname]
PROGRAM_VERSION=[version]
PROGRAM_BINARY=$PROGRAM".sh"
PROGRAM_BATCH=$PROGRAM"-batch.sh"
SCRIPT_BUILD=2016052601

## osync / obackup / pmocr / zsnap install script
## Tested on RHEL / CentOS 6 & 7, Fedora 23, Debian 7 & 8, Mint 17 and FreeBSD 8 & 10
## Please adapt this to fit your distro needs

#TODO: silent mode and no stats mode

CONF_DIR=/etc/$PROGRAM
BIN_DIR=/usr/local/bin
SERVICE_DIR_INIT=/etc/init.d
# Should be /usr/lib/systemd/system, but /lib/systemd/system exists on debian & rhel / fedora
SERVICE_DIR_SYSTEMD_SYSTEM=/lib/systemd/system
SERVICE_DIR_SYSTEMD_USER=/etc/systemd/user

## osync specific code
OSYNC_SERVICE_FILE_INIT="osync-srv"
OSYNC_SERVICE_FILE_SYSTEMD_SYSTEM="osync-srv@.service"
OSYNC_SERVICE_FILE_SYSTEMD_USER="osync-srv@.service.user"

## pmocr specfic code
PMOCR_SERVICE_FILE_INIT="pmocr-srv"
PMOCR_SERVICE_FILE_SYSTEMD_SYSTEM="pmocr-srv.service"

## Generic code

## Default log file
if [ -w /var/log ]; then
        LOG_FILE="/var/log/$PROGRAM-install.log"
elif ([ "$HOME" != "" ] && [ -w "$HOME" ]); then
        LOG_FILE="$HOME/$PROGRAM-install.log"
else
    	LOG_FILE="./$PROGRAM-install.log"
fi

# Generic quick logging function
function _QuickLogger {
        local value="${1}"
       	local destination="${2}" # Destination: stdout, log, both

        if ([ "$destination" == "log" ] || [ "$destination" == "both" ]); then
                echo -e "$(date) - $value" >> "$LOG_FILE"
        elif ([ "$destination" == "stdout" ] || [ "$destination" == "both" ]); then
                echo -e "$value"
       	fi
}

function QuickLogger {
	local value="${1}"

	if [ "$_SILENT" -eq 1 ]; then
		_QuickLogger "$value" "log"
	else
		_QuickLogger "$value" "stdout"
	fi
}

function urlencode() {
    # urlencode <string>

    local LANG=C
    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf "$c" ;;
            *) printf '%%%02X' "'$c" ;; 
        esac
    done
}

function SetOSSettings {
	USER=root

	local local_os_var

	local_os_var="$(uname -spio 2>&1)"
	if [ $? != 0 ]; then
		local_os_var="$(uname -v 2>&1)"
		if [ $? != 0 ]; then
			local_os_var="$(uname)"
		fi
	fi

	case $local_os_var in
		*"BSD"*)
		GROUP=wheel
		;;
		*"Darwin"*)
		GROUP=admin
		;;
		*)
		GROUP=root
		;;
		*"MINGW32"*|*"CYGWIN"*)
		USER=""
		GROUP=""
		;;
	esac

	if ([ "$USER" != "" ] && [ "$(whoami)" != "$USER" ]); then
	  	QuickLogger "Must be run as $USER."
		exit 1
	fi

	OS=$(urlencode "$local_os_var")
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
	if [ -f "./sync.conf.example" ]; then
		cp "./sync.conf.example" "/etc/$PROGRAM/sync.conf.example"
	fi

	if [ -f "./host_backup.conf.example" ]; then
		cp "./host_backup.conf.example" "/etc/$PROGRAM/host_backup.conf.example"
	fi

	if [ -f "./exlude.list.example" ]; then
		cp "./exclude.list.example" "/etc/$PROGRAM"
	fi

	if [ -f "./snapshot.conf.example" ]; then
		cp "./snapshot.conf.example" "/etc/$PROGRAM/snapshot.conf.example"
	fi
}

function CopyProgram {
	cp "./$PROGRAM_BINARY" "$BIN_DIR"
	if [ $? != 0 ]; then
		QuickLogger "Cannot copy $PROGRAM_BINARY to [$BIN_DIR]. Make sure to run install script in the directory containing all other files."
		QuickLogger "Also make sure you have permissions to write to [$BIN_DIR]."
		exit 1
	else
		chmod 755 "$BIN_DIR/$PROGRAM_BINARY"
		QuickLogger "Copied $PROGRAM_BINARY to [$BIN_DIR]."
	fi

	if [ -f "./$PROGRAM_BATCH" ]; then
		cp "./$PROGRAM_BATCH" "$BIN_DIR"
		if [ $? != 0 ]; then
			QuickLogger "Cannot copy $PROGRAM_BATCH to [$BIN_DIR]."
		else
			chmod 755 "$BIN_DIR/$PROGRAM_BATCH"
			QuickLogger "Copied $PROGRAM_BATCH to [$BIN_DIR]."
		fi
	fi

	if [  -f "./ssh_filter.sh" ]; then
		cp "./ssh_filter.sh" "$BIN_DIR"
		if [ $? != 0 ]; then
			QuickLogger "Cannot copy ssh_filter.sh to [$BIN_DIR]."
		else
			chmod 755 "$BIN_DIR/ssh_filter.sh"
			if ([ "$USER" != "" ] && [ "$GROUP" != "" ]); then
				chown $USER:$GROUP "$BIN_DIR/ssh_filter.sh"
			fi
			QuickLogger "Copied ssh_filter.sh to [$BIN_DIR]."
		fi
	fi
}

function CopyServiceFiles {
	# OSYNC SPECIFIC
	if ([ "$init" == "systemd" ] && [ -f "./$OSYNC_SERVICE_FILE_SYSTEMD_SYSTEM" ]); then
		cp "./$OSYNC_SERVICE_FILE_SYSTEMD_SYSTEM" "$SERVICE_DIR_SYSTEMD_SYSTEM" && cp "./$OSYNC_SERVICE_FILE_SYSTEMD_USER" "$SERVICE_DIR_SYSTEMD_USER/$SERVICE_FILE_SYSTEMD_SYSTEM"
		if [ $? != 0 ]; then
			QuickLogger "Cannot copy the systemd file to [$SERVICE_DIR_SYSTEMD_SYSTEM] or [$SERVICE_DIR_SYSTEMD_USER]."
		else
			QuickLogger "Created osync-srv service in [$SERVICE_DIR_SYSTEMD_SYSTEM] and [$SERVICE_DIR_SYSTEMD_USER]."
			QuickLogger "Can be activated with [systemctl start osync-srv@instance.conf] where instance.conf is the name of the config file in /etc/osync."
			QuickLogger "Can be enabled on boot with [systemctl enable osync-srv@instance.conf]."
			QuickLogger "In userland, active with [systemctl --user start osync-srv@instance.conf]."
		fi
	elif ([ "$init" == "initV" ] && [ -f "./$OSYNC_SERVICE_FILE_INIT" ]); then
		cp "./$OSYNC_SERVICE_FILE_INIT" "$SERVICE_DIR_INIT"
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
	if ([ "$init" == "systemd" ] && [ -f "./$PMOCR_SERVICE_FILE_SYSTEMD_SYSTEM" ]); then
		cp "./$PMOCR_SERVICE_FILE_SYSTEMD_SYSTEM" "$SERVICE_DIR_SYSTEMD_SYSTEM"
		if [ $? != 0 ]; then
			QuickLogger "Cannot copy the systemd file to [$SERVICE_DIR_SYSTEMD_SYSTEM] or [$SERVICE_DIR_SYSTEMD_USER]."
		else
			QuickLogger "Created pmocr-srv service in [$SERVICE_DIR_SYSTEMD_SYSTEM] and [$SERVICE_DIR_SYSTEMD_USER]."
			QuickLogger "Can be activated with [systemctl start pmocr-srv] after configuring file options in [$BIN_DIR/$PROGRAM]."
			QuickLogger "Can be enabled on boot with [systemctl enable pmocr-srv]."
		fi
	elif ([ "$init" == "initV" ] && [ -f "./$PMOCR_SERVICE_FILE_INIT" ]); then
		cp "./$PMOCR_SERVICE_FILE_INIT" "$SERVICE_DIR_INIT"
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

_SILENT=0
_STATS=1
for i in "$@"
do
	case $i in
		--silent)
		_SILENT=1
		;;
		--no-stats)
		_STATS=0
		;;
		--help|-h|-?)
		Usage
	esac
done

SetOSSettings
CreateConfDir
CopyExampleFiles
CopyProgram
GetInit
CopyServiceFiles

STATS_LINK="http://instcount.netpower.fr?program=$PROGRAM&version=$PROGRAM_VERSION&os=$OS"

QuickLogger "$PROGRAM installed. Use with $BIN_DIR/$PROGRAM"
if [ $_STATS -eq 1 ]; then
	if [ $_SILENT -eq 1 ]; then
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
