#!/bin/bash

## Osync daemon install script
## Tested on RHEL / CentOS 6
## Please adapt this to fit your distro needs

mkdir /etc/osync
cp ./sync.conf /etc/osync
cp ./osync.sh /usr/local/bin
cp ./osync-srv /etc/init.d

