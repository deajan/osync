osync
=====

A two way sync script based that adds script fault tolerance from obackup project.

## About

Having created obackup script in order to make reliable quick backups, i searched for a nice tool to handle two (or more) way sync scenarios in a reliable way.
While unison handles these scenarios, it's pretty messy to configure, slow, won't handle ACLs and won't resume if something bad happened.
Then i read about bitpocket, a nice script provided by sickill https://github.com/sickill/bitpocket.git
Bitpocked inspired me to write my own implementation of a two way sync script, implementing features i wanted among:
	- Fault tolerance with resume scenarios
	- Email alerts
	- Logging facility
	- Soft deletition and multiple backups handling

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

Then, edit the sync.conf file according to your needs.

## Usage

Once you've setup a personalized sync.conf file, you may run osync with the following test run:

	$ ./osync.sh /path/to/your.conf --dry

If everything went well, you may run the actual configuration with one of the following:

	$ ./osync.sh /path/to/your.conf
	$ ./osync.sh /path/to/your.conf --verbose

Verbose option will display which files and attrs are actually synchronized.
Once you're confident about your fist runs, you may add osync as cron task with:

	$ ./osync.sh /path/to/your.conf --silent

You may then find osync output in /var/log/osync-*.log

## Author

Feel free to mail me for limited support in my free time :)
Orsiris "Ozy" de Jong | ozy@netpower.fr
