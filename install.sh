#!/usr/bin/env bash

SCRIPT_BUILD=2605201401

## Osync daemon install script
## Tested on RHEL / CentOS 6
## Please adapt this to fit your distro needs

mkdir /etc/osync
cp ./sync.conf /etc/osync/sync.conf.example
cp ./exclude.list.example /etc/osync
cp ./osync.sh /usr/local/bin
cp ./osync-srv /etc/init.d

