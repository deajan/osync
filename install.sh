#!/usr/bin/env bash

SCRIPT_BUILD=2015092801

## Osync daemon install script
## Tested on RHEL / CentOS 6 & 7 and Mint 17
## Please adapt this to fit your distro needs

OSYNC_CONF_DIR=/etc/osync
BIN_DIR=/usr/local/bin
SERVICE_DIR=/etc/init.d

if [ "$(whoami)" != "root" ]; then
  echo "Must be run as root."
  exit 1
fi

if [ ! -d "$OSYNC_CONF_DIR" ]; then
	mkdir "$OSYNC_CONF_DIR"
	if [ $? == 0 ]; then
		echo "Created directory [$OSYNC_CONF_DIR]."
	fi
else
	echo "Config directory [$OSYNC_CONF_DIR] exists."
fi

cp ./sync.conf /etc/osync/sync.conf.example
cp ./exclude.list.example /etc/osync
cp ./osync.sh "$BIN_DIR"
if [ $? != 0 ]; then
	echo "Cannot copy osync.sh to [$BIN_DIR]."
else
	echo "Copied osync.sh to [$BIN_DIR]."
fi
cp ./osync-batch.sh /usr/local/bin
if [ $? != 0 ]; then
	echo "Cannot copy osync-batch.sh to [$BIN_DIR]."
else
	echo "Copied osync-batch.sh to [$BIN_DIR]."
fi
cp ./ssh_filter.sh /usr/local/bin
if [ $? != 0 ]; then
	echo "Cannot copy ssh_filter.sh to [$BIN_DIR]."
else
	echo "Copied ssh_filter.sh to [$BIN_DIR]."
fi
cp ./osync-srv "$SERVICE_DIR"
if [ $? != 0 ]; then
	echo "Cannot copy osync-srv to [$SERVICE_DIR]."
else
	echo "Created osync-srv service in [$SERVICE_DIR]."
fi
chmod 755 /usr/local/bin/osync.sh
chmod 755 /usr/local/bin/osync-batch.sh
chmod 755 /usr/local/bin/ssh_filter.sh
chown root:root /usr/local/bin/ssh_filter.sh
chmod 755 /etc/init.d/osync-srv


