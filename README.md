osync
=====

A two way sync script with fault tolerance, resuming and delete / conflict backups.

## About

I searched for a nice tool to handle two (or more) way sync scenarios in a reliable way, easy to use and automate.
While unison handles these scenarios, it's pretty messy to configure, slow, won't handle ACLs and won't automatically resume if something bad happened.

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

Currently, it has been tested on CentOS 5, CentOS 6, Debian 6.0.7, Linux Mint 14, 15 and 16, Ubuntu 12.04 and Ubuntu 12.10.
Windows is supported via MSYS environment. FreeBSD has also been tested.
Basic MacOS X tests have also been done, but a lot of tests are still needed.

## Installation

Keep in mind that Osync has been designed to not delete any data, but rather make backups or soft deletes.
Nevertheless, still consider making backups of your data before trying a sync tool.

First, grab a fresh copy of osync and make it executable:

	$ git clone https://github.com/deajan/osync
	$ cd osync
	$ chmod +x ./osync.sh

Osync needs to run with bash shell. Using any other shell will most probably result in lots of errors.
If bash is not your default shell, invoke it using

	$ bash osync.sh [options]

## Usage

Osync can work with in two flavors: Quick sync mode and configuration file mode.
While quick sync mode is convenient to do fast sync sceanrios, a configuration file gives much more functionnality.
Please use double quotes if directoires contain spaces. Do not use escaped spaces.

QuickSync example:

	$ ./osync.sh --master="/path/to/dir1" --slave="/path/to/remote dir2"
	$ ./osync.sh --master="/path/to/another dir" --slave="ssh://user@host.com:22//path/to/dir2" --rsakey=/home/user/.ssh/id_rsa

Configuration files example:

You'll have to customize the sync.conf file according to your needs.
Osync needs a pair of private / public RSA keys to perform remote SSH connections.
Also, running sync as superuser requires to configure /etc/sudoers file.
Please read the documentation on author's site.
Once you've customized a sync.conf file, you may run osync with the following test run:

	$ ./osync.sh /path/to/your.conf --dry

If everything went well, you may run the actual configuration with one of the following:

	$ ./osync.sh /path/to/your.conf
	$ ./osync.sh /path/to/your.conf --verbose
	$ ./osync.sh /path/to/your.conf --no-maxtime

Verbose option will display which files and attrs are actually synchronized.
No-Maxtime option will disable execution time checks, which is usefull for big initial sync tasks that might take long time. Next runs should then only propagate changes and take much less time.

Once you're confident about your fist runs, you may add osync as cron task like the following in /etc/crontab which would run osync every 5 minutes:

	*/5 * * * * root /usr/local/bin/osync.sh /path/to/your.conf --silent

Additionnaly, you may run osync in monitor mode, which means it will perform a sync upon file operations on master replica.
This can be a drawback on functionnality versus scheduled mode because it won't launch a sync task if there are only file modifications on slave replica.
File monitor mode can also be launched in daemon mode.
Note that monitoring changes requires inotifywait command (inotify-tools package for most Linux distributions).
BSD, MacOS X and Windows are not yet supported for this operation mode.

	$ ./osync.sh /path/to/your.conf --on-changes
	$ ./osync.sh /path/to/your.conf --on-changes --daemon


You may then find osync output in /var/log/osync-*.log (or current directory if /var/log is not writable).

## Author

Feel free to mail me for limited support in my free time :)
Orsiris "Ozy" de Jong | ozy@netpower.fr
