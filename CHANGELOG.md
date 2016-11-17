KNOWN ISSUES
------------

- Cannot finish sync if one replica contains a directory and the other replica contains a file named the same way (Unix doesn't allow this)
- Soft deletion does not honor exclusion lists

RECENT CHANGES
--------------

17 Nov 2016: osync v1.1.5 released
- Backported unit tests from v1.2-beta allowing to fix the following
	- Allow quicksync mode to specify rsync include / exclude patterns as environment variables
	- Added default path separator char in quicksync mode for multiple includes / exclusions
	- Local runs should not check for remote connectivity
	- Fixed backups go into root of replica instead of .osync_wordir/backups
	- Fixed error alerts cannot be triggered from subprocesses
	- Fixed remote locked targets are unlocked in any case

10 Nov 2016: osync v1.1.4 released
- Fixed a corner case with sending alerts with logfile attachments when osync is used by multiple users

02 Sep 2016: osync v1.1.3 released
- Fixed directories containing spaces with bash >= 4.3
- Fixed installer for CYGWIN / MSYS environment

28 Aug 2016: osync v1.1.2 released
- Renamed sync.conf to sync.conf.example (thanks to https://github.com/hortimech)
- Fixed RunAfterHook may be executed twice
- Fixed soft deletion when SUDO_EXEC is enabled

06 Aug 2016: osync v1.1.1 released
- Fixed bogus rsync pattern additions
- Fixed soft deletion always enabled on target
- Fixed problem with attributes file list function
- Fixed deletion propagation code
- Fixed missing deletion / backup diretories message in verbose mode

27 Jul 2016: osync v1.1 released
- More msys and cygwin compatibility
- Logging begins now before any remote checks
- Improved process killing and process time control
- Redirected ERROR and WARN messages to stderr to systemd catches them into it's journal
- Added systemd unit files
- Added an option to ignore ssh known hosts (use with caution, can lead to security risks), also updated upgrade script accordingly
- Added optional installation statistics
- Fixed a nasty bug with log writing and tree_list function
- Improved mail fallback
- Improved more logging
- Fixed conflict prevalance is target in quicksync mode
- Fixed file attributes aren't updated in a right manner when file mtime is not altered (Big thanks to vstefanoxx)
- Better upgrade script (adding missing new config values)
- More fixes for GNU / non-GNU versions of mail command
- Added bogus config file checks & environment checks
- Added delta copies disable option
- Revamped rsync patterns to allow include and exclude patterns
- Fully merged codebase with obackup
- Passed shellCheck.net
	- Simplified EscapeSpaces to simple bash substitution
	- Corrected a lot of minor warnings in order to make code more bullet proof
- Added v1.0x to v1.1 upgrade script
- Added (much) more verbose debugging (and possibility to remove debug code to gain speed)
- Force tree function to overwrite earlier tree files
- Add Logger DEBUG to all eval statements
- Unlocking happens after TrapQuit has successfully killed any child processes
- Replace child_pid by $? directly, add a better sub process killer in TrapQuit
- Refactor [local master, local slave, remote slave] code to [local, remote][initiator, target]code
- Renamed a lot of code in order to prepare v2 code (master becomes initiator, slave becomes target, sync_id becomes instance_id)
- Added some automatic checks in code, for _DEBUG mode (and _PARANOIA_DEBUG now)
- Improved Logging
- Updated osync to be fully compliant with coding style
- Uploaded coding style manifest

v0-v1.0x - Jun 2013 - Sep 2015
- Added LSB info to init script for Debian based distros
22 Jul. 2015: Osync v1.00a released
- Small improvements in osync-batch.sh time management
- Improved various logging on error
- Work in progress: Unit tests (intial tests written by onovy, Thanks again!)
- Small Improvements on install and ssh_filter scripts
- Improved ssh uri recognition (thanks to onovy)
- Fixed #22 (missing full path in soft deletion)
- Fixed #21 by adding portable shell readlink / realpath from https://github.com/mkropat/sh-realpath
- Added detection of osync.sh script in osync-batch.sh to overcome mising path in crontab
- Fixed osync-batch.sh script when osync is in executable path like /usr/local/bin
- Fixed multiple keep logging messages since sleep time between commands has been lowered under a second
- Added optional checksum parameter for the paranoid :)
- Fixed typo in soft deletion code preventing logging slave deleted backup files
- Removed legacy lockfile code from init script
- Removed hardcoded program name from init script
01 Avr. 2015: Osync v1.00pre
- Improved and refactored the soft deletion routine by merging conflict backup and soft deletion
	- Reworked soft deletion code to handle a case where a top level directory gets deleted even if the files contained in it are not old enough (this obviously shouldn't happen on most FS)
	- Added more logging
- Merged various fixes from onovy (http://github.com/onovy) Thanks!
	- Lowered sleep time between commands
	- Check if master and slave directories are the same
	- Check script parameters in osync.sh and osync-batch.sh
	- Run sync after timeout in --on-changes mode when no changes are detected (helps propagate slave changes)
	- Fix for locking in --on-changes mode (child should lock/unlock, master process shouldn't unlock)
	- Remote user is now optional in quicksync mode
- Replaced default script execution storage from /dev/shm to /tmp because some rootkit detection software doesn't like this
- Fixed bogus error in DEBUG for quicksync mode where no max execution time is set
- Prevent debug mode to send alert emails
- Fixed an infamous bug introduced with exclude pattern globbing preventing multiple exludes to be processed
- Fixed an issue with empty RSYNC_EXCLUDE_FILES
- Lowered default compression level for email alerts (for low end systems)
- Prevent exclude pattern globbing before the pattern reaches the rsync cmd
- Fixed some missing child pids for time control to work
- Prevent creation of a sync-id less log file when DEBUG is set
- Added a sequential run batch script that can rerun failed batches
- Fixed an issue where a failed task never gets resumed after a successfull file replication phase
- Added experimental partial downloads support for rsync so big files can be resumed on slow links
- Added the ability to keep partial downloads that can be resumed on next run (usefull for big files on slow links that reach max execution time)
- Moved msys specific code to Init(Local|Remote)OSSettings
- Added a patch by igngvs to fix some issues with Rsync Exclude files
- Added a patch by Gary Clark to fix some issues with remote deletion
- Minor fixes from obackup codebase
- Added compression method fallback (xz, lzma, pigz and gzip)
- Removed unused code
- Fixed remote OS detection when a banner is used on SSH
- Added a routine that reinjects failed deletions for next run in order to prevent bringing back when deletion failed with permission issues
- Added treat dir symlink as dir parameter
27 May 2014: Osync 0.99 RC3
- Additionnal delete fix for *BSD and MSYS (deleted file list not created right)
- Fixed dry mode to use non dry after run treelists to create delete lists
- Added follow symlink parameter
- Minor fixes in parameter list when bandwidth parameter is used
- Added some additionnal checks for *BSD and MacOS environments
- Changed /bin/bash to /usr/bin/env bash for sanity on other systems, also check for bash presence before running
- Changed default behavior for quick sync tasks: Will try to resume failed sync tasks once
- Some code cleanup for state filenames and sync action names
- Fixed deletion propagation (again). Rsync is definitly not designed to delete a list of files / folders. Rsync replaced by rm function which downloads deletion list to remote system.
- Added path detection for exclude list file
- Added a simple init script and an install script
- Fixed an issue with MacOSX using rsync -E differently than other *nix (Thanks to Pierre Clement)
- Multislave asynchronous task support (Thanks to Ulrich Norbisrath)
	- This breaks compat with elder osync runs. Add the SYNC_ID suffix to elder state files to keep deleted file information.
- Added an easier debug setting i.e DEBUG=yes ./osync.sh (Again, thanks to Ulrich Norbisrath)
- Added hardlink preservation (Thanks to Ulrich Norbisrath)
- Added external exclusion file support (Thanks to Pierre Clement)
- Fixed some typos in doc and program itself (Thanks to Pierre Clement)
- More detailled verbose status messages
- More detailled status messages
- Fixed a bug preventing propagation of empty directory deletions
- Fixed a nasty bug preventing writing lock files on remote system as superuser
- Gzipped logs are now deleted once sent
- Fixed some typos (thanks to Pavel Kiryukhin)
- Fixed a bug with double trailing slashes in certain sceanrios
- Sync execution don't fails anymore if files vanish during execution, also vanished files get logged
- Add eventual "comm -23" replacement by "grep -F -x -v -f" to enhance compatibility with other platforms (comm is still much faster than grep, so we keep it)
- Replaced xargs rm with find -exec rm to better handle file names in soft deletion
- Fixed soft deletion not happening with relative paths
- Improved process termination behavior
- More code merging and cleanup
- Fixed a bug preventing deleted files in subdirectories propagation (Thanks to Richard Faasen for pointing that out)
- Some more function merge in sync process
- Dry mode won't create or modifiy state files anymore and will use dry-state files instead
- Improved file monitor mode
- Added possibility to daemonize osync in monitor mode
- Added monitor mode, which will launch a sync task upon file operations on master replica
- Changed conf file default format for ssh uri (old format is still compatible)
- Added ssh uri support for slave replicas
- Improved execution hooks logs
- Various bugfixes introduced with function merge
- Added basic MacOS X support (yet not fully tested)
- Merged tree list functions into one
- Added possibility to quick sync two local directories without any prior configuration
- Added time control on OS detection
02 Nov. 2013: Osync 0.99 RC2
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
18 Aug. 2013: Osync 0.99 RC1
- Added possibility to change default logfile
- Fixed a possible error upon master replica lock check
- Fixed exclude directorires with spaces in names generate errros on master replica tree functions
- Dryruns won't create after run tree lists and therefore not prevent building real run delete lists
- Softdelete and conflict backup functions are now time controlled
- Added bandwidth limit
- Update and delete functions now run rsync with --stats parameter
- Fixed LoadConfigFile function will not warn on wrong config file
- Added --no-maxtime parameter for sync big changes without enforcing execution time checks
03 Aug. 2013: beta 3 milestone
- Softdelete functions do now honor --dry switch
- Simplified sync delete functions
- Enhanced compatibility with different charsets in filenames
- Added CentOS 5 compatibility (comm v5.97 without --nocheck-order function replaced by sort)
- Tree functions now honor supplementary rsync arguments
- Tree functions now honor exclusion lists
01 Aug. 2013: beta 2 milestone
- Fixed an issue with spaces in directory trees
- Fixed an issue with recursive directory trees
- Revamped a bit code to add bash 3.2 compatibility
24 Jul. 2013: beta milestone
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

