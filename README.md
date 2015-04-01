osync 0.99RC4
=============

A two way filesync script with fault tolerance, resuming, deletion backup and conflict backups running on linux and virtually any system supporting bash.
File synchronization is bidirectional, based on rsync, and can be run manually, by cron, or triggered via inotifytools (whenever a file changes on master, a file sync is triggered).

## About

I searched for a nice tool to handle two (or more) way sync scenarios in a reliable way, easy to use and automate.
While unison does the job, it's not very pretty to configure, slow, won't handle ACLs and won't automatically resume if something bad happened.

Then i read about bitpocket, a nice script provided by Marcin Kulik (sickill) at https://github.com/sickill/bitpocket.git
Bitpocked inspired me to write my own implementation of a two way sync script, implementing features i wanted among:
	
- Fault tolerance with resume scenarios
- Email alerts
- Logging facility
- Soft deletition and multiple backups handling
- Before / after command execution
- Time control
- Directory monitoring
- Running on schedule or as daemon

Osync uses a master / slave sync schema. It can sync local to local or local to remote directories. By definition, master replica should always be a local directory on the system osync runs on.
Also, osync uses pidlocks to prevent multiple concurrent sync processes on/to the same master / slave replica. Be sure a sync process is finished before launching next one.
You may launch concurrent sync processes on the same system but only for different master replicas.

Currently, it has been tested on CentOS 5.x, 6.x, 7.x, Debian 6.0.7, Linux Mint 14, 15 and 16, Ubuntu 12.04 and 12.10, and FreeBSD 8.3.
Some users report MacOS X to work good, but some tests are still needed.
Microsoft Windows is supported via MSYS environment.

## Installation

Keep in mind that Osync has been designed to not delete any data, but rather make backups or soft deletes.
Nevertheless, you should always consider making backups of your data before trying a new sync tool.

You can download the latest stable release of Osync at www.netpower.fr/osync
You may also get the last development snapshot at https://github.com/deajan/osync with the following command

	$ git clone https://github.com/deajan/osync

You may copy the osync.sh file to /usr/local/bin if you intend to use it on a regular basis, or just run it from the directory you downloaded it to.
There is also a very basic installation script if you plan to use osync as a daemon too.

Osync needs to run with bash shell. Using any other shell will most probably result in errors.
If bash is not your default shell, you may invoke it using

	$ bash osync.sh [options]

## Usage

Osync can work with in three flavors: Quick sync mode, configuration file mode, and daemon mode.
While quick sync mode is convenient to do fast sync sceanrios, a configuration file gives much more functionnality.
Please use double as directoires delimiters. Do not use escaped characters in directory names.

QuickSync example
-----------------
	$ ./osync.sh --master="/path/to/dir1" --slave="/path/to/remote dir2"
	$ ./osync.sh --master="/path/to/another dir" --slave="ssh://user@host.com:22//path/to/dir2" --rsakey=/home/user/.ssh/id_rsa

Configuration files example
---------------------------
You'll have to customize the sync.conf file according to your needs.
If you intend to sync a remote directory, osync will need a pair of private / public RSA keys to perform remote SSH connections.
Also, running sync as superuser requires to configure /etc/sudoers file.
Please read the documentation about remote sync setups.
Once you've customized a sync.conf file, you may run osync with the following test run:

	$ ./osync.sh /path/to/your.conf --dry

If everything went well, you may run the actual configuration with one of the following:

	$ ./osync.sh /path/to/your.conf
	$ ./osync.sh /path/to/your.conf --verbose
	$ ./osync.sh /path/to/your.conf --no-maxtime

Verbose option will display which files and attrs are actually synchronized.
You may mix "--silent" and "--verbose" parameters to output verbose input only in the log files.
No-Maxtime option will disable execution time checks, which is usefull for big initial sync tasks that might take long time. Next runs should then only propagate changes and take much less time.

Once you're confident about your fist runs, you may add osync as cron task like the following in /etc/crontab which would run osync every 5 minutes:

	*/5 * * * * root /usr/local/bin/osync.sh /path/to/your.conf --silent

Batch mode
----------

You may want to sequentially run multiple sync sets between the same servers. In that case, osync-batch.sh is a nice tool that will run every osync conf file, and, if a task fails,
run it again if there's still some time left.
The following example will run all .conf files found in /etc/osync, and retry 3 times every configuration that fails, if the whole sequential run took less than 2 hours.

	$ ./osync-batch.sh --path=/etc/osync --max-retries=3 --max-exec-time=7200

Having multiple conf files can then be run in a single cron command like

	00 00 * * * root /usr/local/bin/osync-batch.sh --path=/etc/osync --silent

Daemon mode
-----------
Additionnaly, you may run osync in monitor mode, which means it will perform a sync upon file operations on master replica.
This can be a drawback on functionnality versus scheduled mode because this mode only launches a sync task if there are file modifications on the master replica, without being able to monitor the slave replica. Slave replica changes are then only synced when master replica changes occur.
File monitor mode can also be launched as a daemon with an init script. Please read the documentation for more info.
Note that monitoring changes requires inotifywait command (inotify-tools package for most Linux distributions).
BSD, MacOS X and Windows are not yet supported for this operation mode, unless you find a inotify-tools package on these OSes.

	$ ./osync.sh /path/to/your.conf --on-changes

Osync file monitor mode may be run as system service with the osync-srv init script. Any configuration file found in /etc/osync will then create a osync daemon instance.
You may run the install.sh script which should work in most cases or copy the files by hand (osync.sh to /usr/bin/local, osync-srv to /etc/init.d, sync.conf to /etc/osync).

	$ service osync-srv start

Troubleshooting
---------------
You may find osync's logs in /var/log/osync-*.log (or current directory if /var/log is not writable).
Additionnaly, you can use the --verbose flag see to what actions are going on.

## Author

Feel free to mail me for limited support in my free time :)
Orsiris "Ozy" de Jong | ozy@netpower.fr
