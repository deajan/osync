# osync
[![License](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg)](https://opensource.org/licenses/BSD-3-Clause)
[![GitHub Release](https://img.shields.io/github/release/deajan/osync.svg?label=Latest)](https://github.com/deajan/osync/releases/latest)
[![Percentage of issues still open](http://isitmaintained.com/badge/open/deajan/osync.svg)](http://isitmaintained.com/project/deajan/osync "Percentage of issues still open")
[![Codacy Badge](https://api.codacy.com/project/badge/Grade/651acb2fd64642eb91078ba523b7f887)](https://www.codacy.com/app/ozy/osync?utm_source=github.com&amp;utm_medium=referral&amp;utm_content=deajan/osync&amp;utm_campaign=Badge_Grade)
[![linux tests](https://github.com/deajan/osync/actions/workflows/linux.yml/badge.svg)](https://github.com/deajan/osync/actions/workflows/linux.yml/badge.svg)
[![windows tests](https://github.com/deajan/osync/actions/workflows/windows.yml/badge.svg)](https://github.com/deajan/osync/actions/workflows/windows.yml/badge.svg)
[![macos tests](https://github.com/deajan/osync/actions/workflows/macos.yml/badge.svg)](https://github.com/deajan/osync/actions/workflows/macos.yml/badge.svg)


A two way filesync script running on bash Linux, BSD, Android, MacOSX, Cygwin, MSYS2, Win10 bash and virtually any system supporting bash.
File synchronization is bidirectional, and can be run manually, as scheduled task, or triggered on file changes in monitor mode.
It is a command line tool rsync wrapper with a lot of additional features baked in.

This is a quickstart guide, you can find the full documentation on the [author's site](http://www.netpower.fr/osync).

## About

osync provides the following capabilities:

-   Local-Local and Local-Remote sync
-   Fault tolerance with resume scenarios
-   POSIX ACL and extended attributes synchronization
-   Full script Time control
-   Soft deletions and multiple backups handling
-   Before/after run command execution
-   Email alerts
-   Logging facility
-   Directory monitoring
-   Running on schedule or as daemon
-   Batch runner for multiple sync tasks with rerun option for failed sync tasks

osync is a stateful synchronizer. This means it's agentless and doesn't have to monitor files for changes. Instead, it compares replica file lists between two runs.
A full run takes about 2 seconds on a local-local replication and about 7 seconds on a local-remote replication.
Disabling some features file like attributes preservation and disk space checks may speed up execution. 
osync uses a initiator/target sync schema. It can sync local to local or local to remote directories. By definition, initiator replica is always a local directory on the system osync runs on.
osync uses pidlocks to prevent multiple concurrent sync processes on/to the same initiator/target replica.
You may launch concurrent sync processes on the same system but as long as the replicas to synchronize are different.
Multiple osync tasks may be launched sequentially by osync osync-batch tool.

## Tested platforms

| Operating system | Version                |
|------------------|------------------------|
| AlmaLinux        | 9                      |
| Android\*        | Not known              |
| CentOS           | 5.x, 6.x, 7.x          |
| Fedora           | 22-25                  |
| FreeBSD          | 8.3-11                 |
| Debian           | 6-11                   |
| Linux Mint       | 14-18                  |
| macOS            | Not known              |
| pfSense          | 2.3.x                  |
| QTS (x86)        | 4.5.1                  |
| Ubuntu           | 12.04-22.04            |
| Windows\*\*      | 10                     |

\* via Termux.
\*\* via MSYS, Cygwin and WSL.

Some users also have successfully used osync on Gentoo and created an OpenRC init script for it.

## Installation

osync has been designed to not delete any data, but rather make backups of conflictual files or soft deletes.
Nevertheless, you should always have a neat backup of your data before trying a new sync tool.

Getting osync via GitHub (remove the -b "stable" if you want latest dev snapshot)

	$ git clone -b "stable" https://github.com/deajan/osync
	$ cd osync
	$ bash install.sh

Installer script accepts some parameters for automation. Launch install.sh --help for options.

There is also an RPM file that should fit RHEL/CentOS/Fedora and basically any RPM based distro, see the GitHub release.
Please note that RPM files will install osync to `/usr/bin` instead of `/usr/local/bin` in order to enforce good practices.

osync will install itself to `/usr/local/bin` and an example configuration file will be installed to `/etc/osync`.

osync needs to run with bash shell. Using any other shell will most probably result in errors.
If bash is not your default shell, you may invoke it using

	$ bash osync.sh [options]

On *BSD and BusyBox, be sure to have bash installed.

If you can't install osync, you may just copy osync.sh where you needed and run it from there.

Arch Linux packages are available at <https://aur.archlinux.org/packages/osync/> (thanks to Shadowigor, <https://github.com/shadowigor>).

## Upgrade from previous configuration files

Since osync v1.1 the config file format has changed in semantics and adds new config options.
Also, master is now called initiator and slave is now called target.
osync v1.3 also added multiple new configuration options.

You can upgrade all v1.0x-v1.3-dev config files by running the upgrade script

	$ ./upgrade-v1.0x-v1.3x.sh /etc/osync/your-config-file.conf

The script will backup your config file, update it's content and try to connect to initiator and target replicas to update the state dir.

## Usage

Osync can work in 4 modes:
1. [:rocket: Quick sync mode](#quick-sync-mode)
2. [:gear: Configuration file mode](#configuration-file-mode)
3. [:mag_right: Monitor mode](#monitor-mode)
4. [:repeat_one: Target monitoring](#target-monitoring)

> [!NOTE]
> Please use double quotes as path delimiters. Do not use escaped characters in path names.

### <a id="quick-sync-mode"></a>:rocket: Quick sync mode

Quick sync mode is convenient to do fast syncs between some directories. However, the [configuration file mode](#configuration-file-mode) gives much more functionality.

	# osync.sh --initiator="/path/to/dir1" --target="/path/to/remote dir2"
	# osync.sh --initiator="/path/to/another dir" --target="ssh://user@host.com:22//path/to/dir2" --rsakey=/home/user/.ssh/id_rsa_private_key_example.com

#### Quick sync with minimal options

In order to run osync the quickest (without transferring file attributes, without softdeletion, without prior space checks and without remote connectivity checks, you may use the following:

	# MINIMUM_SPACE=0 PRESERVE_ACL=no PRESERVE_XATTR=no SOFT_DELETE_DAYS=0 CONFLICT_BACKUP_DAYS=0 REMOTE_HOST_PING=no osync.sh --initiator="/path/to/another dir" --target="ssh://user@host.com:22//path/to/dir2" --rsakey=/home/user/.ssh/id_rsa_private_key_example.com

All the settings described here may also be configured in the conf file.

### Summary mode

osync will output only file changes and errors with the following:

	# osync.sh --initiator="/path/to/dir1" --target="/path/to/dir" --summary --errors-only --no-prefix

This also works in configuration file mode.

### <a id="configuration-file-mode"></a>:gear: Configuration file mode

You'll have to customize the `sync.conf` file according to your needs.

If you intend to sync a remote directory, osync will need a pair of private/public RSA keys to perform remote SSH connections. Also, running sync as superuser requires to configure the `/etc/sudoers` file.

> [!TIP]
> Read the [example configuration file](https://github.com/deajan/osync/blob/master/sync.conf.example) for documentation about remote sync setups.

Once you've customized a `sync.conf` file, you may run osync with the following test run:

	# osync.sh /path/to/your.conf --dry

If everything went well, you may run the actual configuration with:

	# osync.sh /path/to/your.conf

To display which files and attrs are actually synchronized and which files are to be soft deleted / are in conflict, use `--verbose` (you may mix it with `--silent` to output verbose input only in the log files):
 
	# osync.sh /path/to/your.conf --verbose

Use `--no-maxtime` to disable execution time checks, which is usefull for big initial sync tasks that might take long time. Next runs should then only propagate changes and take much less time:
 
 	# osync.sh /path/to/your.conf --no-maxtime

Once you're confident about your first runs, you may add osync as a cron task like the following in `/etc/crontab` which would run osync every 30 minutes:

	*/30 * * * * root /usr/local/bin/osync.sh /etc/osync/my_sync.conf --silent

Please note that this syntax is correct for the system crontab, i.e. `/etc/contab` and files in `/etc/cron.d`. For the user crontab (`crontab -e`) the user name field should be omitted.

### Batch mode

You may want to sequentially run multiple sync sets between the same servers. In that case, `osync-batch.sh` is a nice tool that will run every osync conf file, and, if a task fails,
run it again if there's still some time left.

To run all `.conf` files found in `/etc/osync`, allowing up to 3 re-runs per configuration on failure in a two hours timeframe, use:

	# osync-batch.sh --path=/etc/osync --max-runs=3 --max-exec-time=7200

Having multiple conf files can then be run in a single cron command like

	00 00 * * * root /usr/local/bin/osync-batch.sh --path=/etc/osync --silent

### <a id="monitor-mode"></a>:mag_right: Monitor mode

> [!NOTE]
> Monitoring changes requires inotifywait command (`inotify-tools`) package for most Linux distributions). BSD, macOS and Windows are not yet supported for this operation mode, unless you find an `inotify-tool` package on these OSes.

Monitor mode will perform a sync upon file operations on initiator replica. This can be a drawback on functionality versus scheduled mode because this mode only launches a sync task if there are file modifications on the initiator replica, without being able to monitor the target replica. Target replica changes are only synced when initiator replica changes occur, or when a given amount of time (600 seconds by default) passed without any changes on initiator replica.

This mode can also be launched as a daemon with an init script. Please read the documentation for more info.

To use this mode, use `--on-changes`:

	# osync.sh /etc/osync/my_sync.conf --on-changes

To run this mode as a system service with the `osync-srv` script, you can run the `install.sh` script (which should work in most cases) or copy the files by hand:
- `osync.sh` to `/usr/local/bin`
- `sync.conf` to `/etc/osync`
- For InitV, `osync-srv` to `/etc/init.d`
- For systemd, `osync-srv@.service` to `/usr/lib/systemd/system`
- For OpenRC, `osync-srv-openrc` to `/etc/init.d/osync-srv-openrc`

For InitV (any configuration file found in `/etc/osync` will create an osync daemon instance when service is launched on initV):

	$ service osync-srv start
	$ chkconfig osync-srv on

For systemd, launch service (one service per config file to launch) with:

	$ systemctl start osync-srv@configfile.conf
	$ systemctl enable osync-srv@configfile.conf

For OpenRC (user contrib), launch service (one service per config file to launch) with:

	$ rc-update add osync-srv.configfile default

### <a id="target-monitoring"></a>:repeat_one: Target monitoring

When the initiator replica operates in monitor mode a sync task is only launched when there are file modifications on the initiator replica. Changes on the target replica, for example by another initiator, remain unnoticed and hence unsynchronized. The solution is to run another instance of osync in a special target monitor mode on the target replica which detects changes and initiates a synchronization action.

>[!NOTE]
>The instance of osync is running on the target and detects and signals changes on the target, but does not perform an actual sync task. The target replica writes a special file `.osycnc_push` into the initiator replica directory. When the initiator replica is in monitor mode this change is detected and a synchronization is initiated. The synchronization is always initiated and executed by the initiator replica.

>[!NOTE]
>The target replica has to connect back to the initiator replica and does so using SSH and rsync. This means the initiator **must** be reachable from the target replica. When the initiator replica is behind a firewall, either some sort of port forwarding must be configured, or both hosts must be connected to the same VPN. The initiator replica does not not keep a connection open to enable the target to communicate back to the initiator.

To run the target monitor mode, first install osync on the target. Next, change the configuration file so it correctly reflects the target and initiator setting. In the comments of the [example configuration file](https://github.com/deajan/osync/blob/master/osync-target-helper-srv@.service.user) you'll find in the comments the most important changes to make to run osync on the target replica.

To run it from that command line, use this command:

	# osync /etc/osync/my_sync.conf --on-changes-target

Whenever a change happens which requires a synchronisation action to start, the target sends a notification to the initiator, and then returns back to a monitoring state.

In most cases you want to run this monitoring as a service on the target. Example files for starting this service on InitV and Systemd are available as `osync-target-helper-srv*`

## Running osync as root vs. running osync as user `Linux/systemd only`

If you yourself are the owner of all directories and files to be kept in sync, osync runs equally well with just user permissions. When osync is installed as a user service there are a few things to take into account.

>[!CAUTION]
>Do not run osync with the same configuration alternatingly as user or as root. Which could happen if you run osync from the command line as user but as a service as root. This will cause problems with permissions on the state files. Once these files are modified by root, they cannot be modified as user, and osync will abort with an error.

Let us assume you have no root permissions on the host osync is installed, and you want to run osync as a user. These are the important steps:

-	Create a config file in a directory you have access to, hence not `/etc/osync`
-	Choose a proper log file path and add this in the configuration file. The default `/var/log/` is not applicable here.
-	Place the systemd unit file in `$HOME/.config/systemd/user/`. 
-	Interact with systemctl in this way: `systemctl --user <command> <unit file>`

The specification for the systemd unit file in the systemctl command is slightly different when the full path to the configuration file has to be specified for the osync instance. Explanation and examples are in the [example user unit file](https://github.com/deajan/osync/blob/master/osync-target-helper-srv@.service.user) 

>[!NOTE} 
>When connecting with SSH to a host you have not previously connected to, default behaviour is that you receive a prompt to approve to connect to an unknown host. When running osync as a service, you won't see this prompt. The SSH or rsync connection then returns a general error, and osync fails without being able to provide error details. 
>This is especially relevant when running osync in target monitor mode where it is more likely to happen that you never before connected from the target replica back to the initiator.
>The solution is to make sure that you once make a connection to each host osync is configured to connect to before you start the osync service. The workaround to specify `StrictHostKeyChecking = no` is not recommend, certainly not if the host is visible from the public internet. 

## Security enhancements

Remote SSH connection security can be improved by limiting what hostnames may connect, disabling some SSH options and using ssh filter.
Please read full documentation in order to configure ssh filter.

## Contributions

All kind of contribs are welcome.

When submitting a PR, please be sure to modify files in dev directory (`dev/n_osync.sh`, `dev/ofunctions.sh`, `dev/common_install.sh etc`) as most of the main files are generated via merge.sh.
When testing your contribs, generate files via merge.sh or use bootstrap.sh which generates a temporary version of n_osync.sh with all includes.

Unit tests are run by travis on every PR, but you may also run them manually which adds some tests that travis can't do, via `dev/tests/run_tests.sh`.
SSH port can be changed on the fly via environment variable SSH_PORT, e.g.:

	# SSH_PORT=2222 dev/tests/run_tests.sh

Consider reading CODING_CONVENTIONS.TXT before submitting a patch.

## Troubleshooting

You may find osync's logs in `/var/log/osync.[INSTANCE_ID].log` (or current directory if `/var/log` is not writable).
Additionnaly, you can use the --verbose flag see to what actions are going on.

When opening an issue, please post the corresponding log files. Also, you may run osync with _DEBUG option in order to have more precise logs, e.g.:

	# _DEBUG=yes ./osync.sh /path/to/conf

## Uninstalling

The installer script also has an uninstall mode that will keep configuration files. Use it with

	$ ./install.sh --remove

## Author

Feel free to open an issue on GitHub or mail me for support in my spare time :)
Orsiris de Jong | ozy@netpower.fr
