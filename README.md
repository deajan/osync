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

Osync uses a master / slave sync schema. It can sync local and local or local and remote directories. By definition, master replica should always be a local directory on the system osync runs on.
Also, osync uses pidlocks to prevent multiple concurrent sync processes on/to the same master / slave replica. Be sure a sync process is finished before launching next one.
You may launch concurrent sync processes on the same system but only for different master replicas.

Currently, it has been tested on CentOS 5, CentOS 6, Debian 6.0.7, Linux Mint 14, Ubuntu 12.
Osync also runs on FreeBSD and Windows MSYS environment, altough it is not fully tested yet.

## Installation

Keep in mind that Osync has been designed to not delete any data, but rather make backups or soft deletes.
Nevertheless, still consider making backups of your data before trying a sync tool.

First, grab a fresh copy of osync and make it executable:

	$ git clone https://github.com/deajan/osync
	$ chmod +x ./osync.sh

Osync needs to run with bash shell. Using any other shell will most probably result in lots of errors.
There is no need to intialize anything. You can begin sync with two already filled directories.
You only have to customize the sync.conf file according to your needs.
Osync needs a pair of private / public RSA keys to perform remote SSH connections.
Also, running sync as superuser requires to configure /etc/sudoers file.
Please read the documentation on author's site.

## Usage

Once you've customized a sync.conf file, you may run osync with the following test run:

	$ ./osync.sh /path/to/your.conf --dry

If everything went well, you may run the actual configuration with one of the following:

	$ ./osync.sh /path/to/your.conf
	$ ./osync.sh /path/to/your.conf --verbose
	$ ./osync.sh /path/to/your.conf --no-maxtime

Verbose option will display which files and attrs are actually synchronized.
No-Maxtime option will disable execution time checks, which is usefull for big initial sync tasks that might take long time. Next runs should then only propagate changes and take much less time.

Once you're confident about your fist runs, you may add osync as cron task with:

	$ ./osync.sh /path/to/your.conf --silent

You may then find osync output in /var/log/osync-*.log (or current directory if /var/log is not writable).

## Author

Feel free to mail me for limited support in my free time :)
Orsiris "Ozy" de Jong | ozy@netpower.fr
