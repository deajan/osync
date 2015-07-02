#!/usr/bin/env bash

SCRIPT_BUILD=2015070201

## Osync daemon install script
## Tested on RHEL / CentOS 6 & 7
## Please adapt this to fit your distro needs

if [ "$(whoami)" != "root" ]
then
  echo "Must be run as root."
  exit 1
fi

mkdir /etc/osync
cp ./sync.conf /etc/osync/sync.conf.example
cp ./exclude.list.example /etc/osync
cp ./osync.sh /usr/local/bin
cp ./osync-batch.sh /usr/local/bin
cp ./ssh_filter.sh /usr/local/bin
cp ./osync-srv /etc/init.d
chmod 755 /usr/local/bin/osync.sh
chmod 755 /usr/local/bin/osync-batch.sh
chmod 755 /usr/local/bin/ssh_filter.sh
chown root:root /usr/local/bin/ssh_filter.sh
chmod 755 /usr/local/bin/osync-srv


