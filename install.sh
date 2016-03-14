#!/usr/bin/env bash

PROGRAM=osync
PROGRAM_BINARY=$PROGRAM".sh"
PROGRAM_BATCH=$PROGRAM"-batch.sh"
SCRIPT_BUILD=2016031401

## osync / obackup daemon install script
## Tested on RHEL / CentOS 6 & 7, Fedora 23, Debian 7 & 8, Mint 17 and FreeBSD 8 & 10
## Please adapt this to fit your distro needs

CONF_DIR=/etc/$PROGRAM
BIN_DIR=/usr/local/bin
SERVICE_DIR=/etc/init.d

if [ "$(whoami)" != "root" ]; then
  echo "Must be run as root."
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

cp "./$PROGRAM_BINARY" "$BIN_DIR"
if [ $? != 0 ]; then
	echo "Cannot copy $PROGRAM_BINARY to [$BIN_DIR]."
else
	echo "Copied $PROGRAM_BINARY to [$BIN_DIR]."
fi
cp "./$PROGRAM_BATCH" "/usr/local/bin"
if [ $? != 0 ]; then
	echo "Cannot copy $PROGRAM_BATCH to [$BIN_DIR]."
else
	echo "Copied $PROGRAM_BATCH to [$BIN_DIR]."
fi
cp "./ssh_filter.sh" "/usr/local/bin"
if [ $? != 0 ]; then
	echo "Cannot copy ssh_filter.sh to [$BIN_DIR]."
else
	echo "Copied ssh_filter.sh to [$BIN_DIR]."
fi

if [ -f "./osync-srv" ]; then
	cp "./osync-srv" "$SERVICE_DIR"
	if [ $? != 0 ]; then
		echo "Cannot copy osync-srv to [$SERVICE_DIR]."
	else
		echo "Created osync-srv service in [$SERVICE_DIR]."
		chmod 755 "/etc/init.d/osync-srv"
	fi
fi

chmod 755 "/usr/local/bin/$PROGRAM_BINARY"
chmod 755 "/usr/local/bin/$PROGRAM_BATCH"
chmod 755 "/usr/local/bin/ssh_filter.sh"
chown root:root "/usr/local/bin/ssh_filter.sh"
