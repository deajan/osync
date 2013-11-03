SHORT FUTURE IMPROVEMENTS (post v1.0)
-------------------------------------

- Sync and delete propagation function merge (master and slave functions are the same, reduces code size and maintain effort)
- Tree function merge (current and after tree functions are the same except for output filename and logging, reduces code size and maintain effort)
- Tree functions execute piped commands (grep, awk) on master when launched on remote slave which can cause more bandwith usage
- Fast sync mode should also work with remote systems

FAR FUTURE IMPROVEMENTS
-----------------------

- Rethink of .osync_workdir/state/* files with PIDs, Host and Task Names to better identify multiple instances on the same fileset
- Improve Master / Slave schema to Multimaster schema

KNOWN ISSUES
------------

- None yet, need more testing on MSYS environment

RECENT CHANGES
--------------

- Added possibility to quick sync two local directories without any prior configuration
- Added time control on OS detection
- 02 Nov. 2013: Osync 0.99 RC2
- Minor improvement on operating system detection
- Improved RunLocalCommand execution hook
- Minor improvements on permission checks
- Made more portability improvements (mostly for FreeBSD, must be run with bash shell)
- Added local and remote operating system detection
	- Added forced usage of MSYS find on remote MSYS hosts
	- Updated MSYS handling
- Merged MSYS (MinGW minimal system) bash compatibility under Windows from Obackup
	- Added check for /var/log directory
	- Added check for shared memory directory
	- Added alternative way to kill child processes for other OSes and especially for MSYS (which is a very odd way)
	- Added Sendemail.exe support for windows Alerting
	- Replaced which commend by type -p, as it is more portable
	- Added support for ping.exe from windows
	- Forced usage of MSYS find instead of Windows' find.exe on master
       - Added an optionnal remote rsync executable path parameter
- Fixed an issue with CheckConnectivity3rdPartyHosts
- Added an option to stop execution if a local / remote command fails
- Improved forced quit command by killing all child processes
- Before / after commands are now ignored on dryruns
- Improved verbose output
- Fixed various typos
- Enforced CheckConnectivityRemoteHost and CheckConnectivity3rdPartyHosts checks (if one of these fails, osync is stopped)
- 18 Aug. 2013: Osync 0.99 RC1
- Added possibility to change default logfile
- Fixed a possible error upon master replica lock check
- Fixed exclude directorires with spaces in names generate errros on master replica tree functions
- Dryruns won't create after run tree lists and therefore not prevent building real run delete lists
- Softdelete and conflict backup functions are now time controlled
- Added bandwidth limit
- Update and delete functions now run rsync with --stats parameter
- Fixed LoadConfigFile function will not warn on wrong config file
- Added --no-maxtime parameter for sync big changes without enforcing execution time checks
- 03 Aug. 2013: beta 3 milestone
- Softdelete functions do now honor --dry switch
- Simplified sync delete functions
- Enhanced compatibility with different charsets in filenames
- Added CentOS 5 compatibility (comm v5.97 without --nocheck-order function replaced by sort)
- Tree functions now honor supplementary rsync arguments
- Tree functions now honor exclusion lists
- 01 Aug. 2013: beta 2 milestone
- Fixed an issue with spaces in directory trees
- Fixed an issue with recursive directory trees
- Revamped a bit code to add bash 3.2 compatibility
- 24 Jul. 2013: beta milestone
- Fixed some bad error handling in CheckMasterSlaveDirs and LockDirectories
- Added support for spaces in sync dirs and exclude lists
- Fixed false exit code if no remote slave lock present
- Added minimum disk space checks
- Added osync support in ssh_filter.sh
- Added support for sudo exec on remote slave
- Added support for alternative rsync executable
- Added support for spaces in sync directories names
- Added support for ACL and xattr
- Added --force-unlock parameter to bypass any existing locks on replicas
- Added full remote support for slave replica
- Improved error detection
- Made some changes in execution hook output
- Fixed an issue with task execution handling exit codes
- Added master and slave replicas lock functionnality
- Added rsync exclude patterns support
- Improved backup items, can now have multiple backups of the same file
- Added maximum number of resume tries before trying a fresh stateless execution
- Added possibility to resume a sync after an error
- Improved task execution time handling
- Improved SendAlert handling
- Fixed cleanup launched even if DEBUG=yes
- Added verbose rsync output
- Added --dry and --silent parameters
- Added time control
- Added master/slave conflict prevalance option
- Added soft-deleted items
- Added backup items in case of conflict

19 Jun. 2013: Project begin as Obackup fork

