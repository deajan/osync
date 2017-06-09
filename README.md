# osync  [![Build Status](https://travis-ci.org/deajan/osync.svg?branch=v1.1-maint)](https://travis-ci.org/deajan/osync) [![GitHub Release](https://img.shields.io/github/release/deajan/osync.svg?label=Latest)](https://github.com/deajan/osync/releases/latest)

A two way filesync script with fault tolerance, resume, soft deletion, conflictual file backups running on bash (linux, BSD and virtually any system supporting bash).
File synchronization is bidirectional, based on rsync, can be run manually, as scheduled task, or triggered on file changes.

## About

Osync provides the following capabilities
	
- Fault tolerance with resume scenarios
- Email alerts
- Logging facility
- Soft deletition and multiple backups handling
- Before / after command execution
- Time control
- Directory monitoring
- Running on schedule or as daemon
- Batch runner for multiple sync tasks with rerun option for failed sync tasks
- ACL synchronization

osync uses a initiator / target sync schema. It can sync local to local or local to remote directories. By definition, initiator replica is always a local directory on the system osync runs on.
osync uses pidlocks to prevent multiple concurrent sync processes on/to the same initiator / target replica.
You may launch concurrent sync processes on the same system but only for different initiator replicas.
osync tasks may be launched sequentially by osync osync-batch tool.

Currently, it has been tested on CentOS 5.x, 6.x, 7.x, Debian 6, Debian 7, Linux Mint 14-17, Ubuntu 12.04, 12.10, FreeBSD 8.3, 10.1, 10.3, Mac OS X and pfSense.
Microsoft Windows is supported via MSYS or Cygwin.
Note that FreeBSD 11 is only supported in versions v1.2+.


## Installation

Osync has been designed to not delete any data, but rather make backups of conflictual files or soft deletes.
Nevertheless, you should always have a neat backup of your data before trying a new sync tool.

You can download the latest stable release of osync at https://github.com/deajan/osync/archive/stable.tar.gz

You may also get the last development version at https://github.com/deajan/osync with the following command

	$ git clone https://github.com/deajan/osync
	$ cd osync
	$ sh install.sh

Osync will install itself to /usr/local/bin and an example configuration file will be installed to /etc/osync

Osync needs to run with bash shell. Using any other shell will most probably result in errors.
If bash is not your default shell, you may invoke it using

	$ bash osync.sh [options]

On *BSD, be sure to have bash installed.
On MSYS, On top of your basic install, you need msys-rsync and msys-coreutils-ext packages.

## Upgrade from v1.0x

Since osync v1.1 the config file format has changed in semantics and adds new config options.
Also, master is now called initiator and slave is now called target.

You can upgrade all v1.0x-v1.1-dev config files by running the upgrade script

	$ ./upgrade-v1.0x-v1.1x.sh /etc/osync/your-config-file.conf

The script will backup your config file, update it's content and try to connect to initiator and target replicas to update the state dir.

## Usage

Osync can work with in three flavors: Quick sync mode, configuration file mode, and daemon mode.
While quick sync mode is convenient to do fast syncs between some directories, a configuration file gives much more functionnality.
Please use double quotes as path delimiters. Do not use escaped characters in path names.

QuickSync example
-----------------
	# osync.sh --initiator="/path/to/dir1" --target="/path/to/remote dir2"
	# osync.sh --initiator="/path/to/another dir" --target="ssh://user@host.com:22//path/to/dir2" --rsakey=/home/user/.ssh/id_rsa_private_key_example.com

Running osync with a Configuration file
---------------------------------------
You'll have to customize the sync.conf file according to your needs.
If you intend to sync a remote directory, osync will need a pair of private / public RSA keys to perform remote SSH connections.
Also, running sync as superuser requires to configure /etc/sudoers file.
Please read the documentation about remote sync setups.
Once you've customized a sync.conf file, you may run osync with the following test run:

	# osync.sh /path/to/your.conf --dry

If everything went well, you may run the actual configuration with one of the following:

	# osync.sh /path/to/your.conf
	# osync.sh /path/to/your.conf --verbose
	# osync.sh /path/to/your.conf --no-maxtime

Verbose option will display which files and attrs are actually synchronized and which files are to be soft deleted / are in conflict.
You may mix "--silent" and "--verbose" parameters to output verbose input only in the log files.
No-Maxtime option will disable execution time checks, which is usefull for big initial sync tasks that might take long time. Next runs should then only propagate changes and take much less time.

Once you're confident about your fist runs, you may add osync as cron task like the following in /etc/crontab which would run osync every 30 minutes:

	*/30 * * * * root /usr/local/bin/osync.sh /etc/osync/my_sync.conf --silent

Batch mode
----------

You may want to sequentially run multiple sync sets between the same servers. In that case, osync-batch.sh is a nice tool that will run every osync conf file, and, if a task fails,
run it again if there's still some time left.
The following example will run all .conf files found in /etc/osync, and retry 3 times every configuration that fails, if the whole sequential run took less than 2 hours.

	# osync-batch.sh --path=/etc/osync --max-retries=3 --max-exec-time=7200

Having multiple conf files can then be run in a single cron command like

	00 00 * * * root /usr/local/bin/osync-batch.sh --path=/etc/osync --silent

Daemon mode
-----------
Additionnaly, you may run osync in monitor mode, which means it will perform a sync upon file operations on initiator replica.
This can be a drawback on functionnality versus scheduled mode because this mode only launches a sync task if there are file modifications on the initiator replica, without being able to monitor the target replica.
Target replica changes are only synced when initiator replica changes occur, or when a given amount of time (default 600 seconds) passed without any changes on initiator replica.
File monitor mode can also be launched as a daemon with an init script. Please read the documentation for more info.
Note that monitoring changes requires inotifywait command (inotify-tools package for most Linux distributions).
BSD, MacOS X and Windows are not yet supported for this operation mode, unless you find a inotify-tools package on these OSes.

	# osync.sh /etc/osync/my_sync.conf --on-changes

Osync file monitor mode may be run as system service with the osync-srv init script. Any configuration file found in /etc/osync will then create a osync daemon instance.
You may run the install.sh script which should work in most cases or copy the files by hand (osync.sh to /usr/bin/local, osync-srv to /etc/init.d, sync.conf to /etc/osync).

	$ service osync-srv start
	$ chkconfig osync-srv on

Systemd specific (one service per config file)

	$ systemctl start osync-srv@configfile.conf
	$ systemctl enable osync-srv@configfile.conf

Troubleshooting
---------------
You may find osync's logs in /var/log/osync.*.log (or current directory if /var/log is not writable).
Additionnaly, you can use the --verbose flag see to what actions are going on.

## Author

Feel free to mail me for limited support in my free time :)
Orsiris de Jong | ozy@netpower.fr
