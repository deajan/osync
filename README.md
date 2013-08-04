osync
=====

A two way sync script based that adds script fault tolerance from obackup project along with multiple usefull options.

## About

Having created obackup script in order to make reliable quick backups, i searched for a nice tool to handle two (or more) way sync scenarios in a reliable way.

While unison handles these scenarios, it's pretty messy to configure, slow, won't handle ACLs and won't resume if something bad happened.

Then i read about bitpocket, a nice script provided by Marcin Kulik (sickill) at https://github.com/sickill/bitpocket.git
Bitpocked inspired me to write my own implementation of a two way sync script, implementing features i wanted among:
	
- Fault tolerance with resume scenarios	
- Email alerts	
- Logging facility
- Soft deletition and multiple backups handling
- Before / after command execution
- Time control

Osync uses a master / slave sync schema. It can sync local or remote directories. By definition, master replica should always be a local directory on the system osync runs on.
Also, osync uses pidlocks to prevent multiple concurrent sync processes on/to the same master / slave replica. Be sure a sync process is finished before launching next one.
You may launch concurrent sync processes on the same system but only for different master replicas.

## Installation

Osync developpment is still not finished. It's currently at beta stage. Please read CHANGELOG.md for a list of known bugs.
Keep in mind that Osync has been designed to not delete any data, but rather make backups or soft deletes.
Nevertheless, as we're still in beta stage, please make a backup of your data before using Osync.

First, grab a fresh copy of osync and make it executable:

	$ git clone https://github.com/deajan/osync
	$ chmod +x ./osync.sh

There is no need to intialize anything. You can begin sync with two already filled directories.
You only have to copy the sync.conf file to let's say your.conf and then edit it according to your needs.
Osync needs a pair of private / public RSA keys to perform remote SSH connections.
Also, using SUDO_EXEC option requires to configure /etc/sudoers file.
Documentation is being written, meanwhile you can check Obackup documentation at http://netpower.fr/projects/obackup/documentation.html for the two configurations points above.

## Usage

Once you've setup a personalized sync.conf file, you may run osync with the following test run:

	$ ./osync.sh /path/to/your.conf --dry

If everything went well, you may run the actual configuration with one of the following:

	$ ./osync.sh /path/to/your.conf
	$ ./osync.sh /path/to/your.conf --verbose
	$ ./osync.sh /path/to/your.conf --no-maxtime

Verbose option will display which files and attrs are actually synchronized.
No-Maxtime option will disable execution time checks, which is usefull for big initial sync tasks that might take long time. Next runs should then only propagate changes and take much less time.

Once you're confident about your fist runs, you may add osync as cron task with:

	$ ./osync.sh /path/to/your.conf --silent

You may then find osync output in /var/log/osync-*.log
Also, you may always find detailed rsync command results at /tmp/osync_* if verbose switch wasn't specified.

## Author

Feel free to mail me for limited support in my free time :)
Orsiris "Ozy" de Jong | ozy@netpower.fr
