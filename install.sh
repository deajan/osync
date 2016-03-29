#!/usr/bin/env bash

PROGRAM=osync
PROGRAM_VERSION=1.1-dev
PROGRAM_BINARY=$PROGRAM".sh"
PROGRAM_BATCH=$PROGRAM"-batch.sh"
SCRIPT_BUILD=2016032903

## osync / obackup daemon install script
## Tested on RHEL / CentOS 6 & 7, Fedora 23, Debian 7 & 8, Mint 17 and FreeBSD 8 & 10
## Please adapt this to fit your distro needs

CONF_DIR=/etc/$PROGRAM
BIN_DIR=/usr/local/bin
SERVICE_DIR_INIT=/etc/init.d
SERVICE_FILE_INIT="osync-srv"
SERVICE_DIR_SYSTEMD=/usr/lib/systemd/system
SERVICE_FILE_SYSTEMD="osync-srv@.service"

USER=root

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
	*)
	GROUP=root
	;;
esac

if [ "$(whoami)" != "$USER" ]; then
  echo "Must be run as $USER."
  exit 1
fi

if [ -f /sbin/init ]; then
	if file /sbin/init | grep systemd > /dev/null; then
		init=systemd
	else
		init=init
	fi
else
	echo "Can't detect init system."
	exit 1
fi

if [ ! -d "$CONF_DIR" ]; then
	mkdir "$CONF_DIR"
	if [ $? == 0 ]; then
		echo "Created directory [$CONF_DIR]."
	else
		echo "Cannot create directory [$CONF_DIR]."
		exit 1
	fi
else
	echo "Config directory [$CONF_DIR] exists."
fi

if [ -f "./sync.conf" ]; then
	cp "./sync.conf" "/etc/$PROGRAM/sync.conf.example"
fi

if [ -f "./host_backup.conf" ]; then
	cp "./host_backup.conf" "/etc/$PROGRAM/host_backup.conf.example"
fi

if [ -f "./exlude.list.example" ]; then
	cp "./exclude.list.example" "/etc/$PROGRAM"
fi

if [ -f "./snapshot.conf" ]; then
	cp "./snapshot.conf" "/etc/$PROGRAM/snapshot.conf.example"
fi

cp "./$PROGRAM_BINARY" "$BIN_DIR"
if [ $? != 0 ]; then
	echo "Cannot copy $PROGRAM_BINARY to [$BIN_DIR]."
else
	chmod 755 "$BIN_DIR/$PROGRAM_BINARY"
	echo "Copied $PROGRAM_BINARY to [$BIN_DIR]."
fi

if [ -f "./$PROGRAM_BATCH" ]; then
	cp "./$PROGRAM_BATCH" "$BIN_DIR"
	if [ $? != 0 ]; then
		echo "Cannot copy $PROGRAM_BATCH to [$BIN_DIR]."
	else
		chmod 755 "$BIN_DIR/$PROGRAM_BATCH"
		echo "Copied $PROGRAM_BATCH to [$BIN_DIR]."
	fi
fi

if [  -f "./ssh_filter.sh" ]; then
	cp "./ssh_filter.sh" "$BIN_DIR"
	if [ $? != 0 ]; then
		echo "Cannot copy ssh_filter.sh to [$BIN_DIR]."
	else
		chmod 755 "$BIN_DIR/ssh_filter.sh"
		chown $USER:$GROUP "$BIN_DIR/ssh_filter.sh"
		echo "Copied ssh_filter.sh to [$BIN_DIR]."
	fi
fi

if ([ -f "./$SERVICE_FILE_INIT" ] || [ -f "./$SERVICE_FILE_SYSTEMD" ] ); then
	if [ "$init" == "systemd" ]; then
		cp "./$SERVICE_FILE_SYSTEMD" "$SERVICE_DIR_SYSTEMD"
		if [ $? != 0 ]; then
			echo "Cannot copy the systemd file to [$SERVICE_DIR_SYSTEMD]."
		else
			echo "Created osync-srv service in [$SERVICE_DIR_SYSTEMD]."
			echo "Activate with [systemctl start osync-srv@instance.conf] where instance.conf is the name of the config file in /etc/osync."
			echo "Enable on boot with [systemctl enable osync-srv@instance.conf]."
		fi
	elif [ "$init" == "init" ]; then
		cp "./$SERVICE_FILE_INIT" "$SERVICE_DIR_INIT"
		if [ $? != 0 ]; then
			echo "Cannot copy osync-srv to [$SERVICE_DIR_INIT]."
		else
			chmod 755 "$SERVICE_DIR_INIT/$SERVICE_FILE_INIT"
			echo "Created osync-srv service in [$SERVICE_DIR_INIT]."
			echo "Activate with [service $SERVICE_FILE_INIT start]."
			echo "Enable on boot with [chkconfig $SERVICE_FILE_INIT on]."
		fi
	fi
fi

function Statistics {

        local link="http://instcount.netpower.fr?program=$PROGRAM&version=$PROGRAM_VERSION"
        if type wget > /dev/null; then
                wget $link > /dev/null 2>&1
                if [ $? == 0 ]; then
                        exit 0
                fi
	fi

        if type curl > /dev/null; then
                curl $link > /dev/null 2>&1
                if [ $? == 0 ]; then
                        exit 0
                fi
	fi

       	echo "Neiter wget nor curl could be used for. Cannot run statistics. Use the provided link please."
        exit
}

echo "$PROGRAM installed. Use with $BIN_DIR/$PROGRAM"
echo ""
echo "In order to make install statistics, the script would like to connect to http://instcount.netpower.fr?program=$PROGRAM&version=$PROGRAM_VERSION"
read -r -p "No data except those in the url will be send. Allow [Y/n]" response
case $response in
	[nN])
	exit
	;;
	*)
        Statistics
        ;;
esac
