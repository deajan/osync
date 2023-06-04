#!/usr/bin/env bash

# osync test suite 2022070702


# Allows the following environment variables
# RUNNING_ON_GITHUB_ACTIONS=[true|false]
# SSH_PORT=22
# SKIP_REMOTE=[true|false]

## On Mac OSX, this needs to be run as root in order to use sudo without password
## From current terminal run sudo -s in order to get a new terminal as root

## On CYGWIN / MSYS, ACL and extended attributes aren't supported

# 4 tests:
# quicklocal
# quickremote (with ssh_filter.sh)
# conflocal
# confremote (with ssh_filter.sh)

# for each test
# 	files with spaces, subdirs
# 	largefileset (...large ?)
#	quickremote test with controlmaster enabled
# 	exclusions
# 	conflict resolution initiator with backups / multiple backups
# 	conflict resolution target with backups / multiple backups
# 	deletion propagation, failed deletion repropagation, skip deletion
#	symlink and broken symlink propagation and deletion
# 	replica lock checks
#	file attribute tests
# 	local / remote locking resume tests
#	conflict detection
#	timed execution tests

# function test
# WaitForTaskCompletion
# ParallelExec
# daemon mode tests for both config files

# on BSD, remount UFS with ACL support using mount -o acls /
# setfacl needs double ':' to be compatible with both linux and BSD
# setfacl -m o::rwx file

# On Windows 10 bash, we need to create host SSH keys first with ssh-keygen -A
# Then start ssh with service ssh start

# TODO, use copies of config file on each test function

if [ "$SKIP_REMOTE" = "" ]; then
	SKIP_REMOTE=false
fi

# drupal servers are often unreachable for whetever reason or give 0 bytes files
#LARGE_FILESET_URL="http://ftp.drupal.org/files/projects/drupal-8.2.2.tar.gz"
LARGE_FILESET_URL="http://www.netpower.fr/sites/default/files/osync-test-files.tar.gz"

# Fakeroot for install / uninstall and test of executables
FAKEROOT="${HOME}/osync_test_install"

OSYNC_DIR="$(pwd)"
OSYNC_DIR=${OSYNC_DIR%%/dev*}
DEV_DIR="$OSYNC_DIR/dev"
TESTS_DIR="$DEV_DIR/tests"

CONF_DIR="$TESTS_DIR/conf"
LOCAL_CONF="local.conf"
REMOTE_CONF="remote.conf"
OLD_CONF="old.conf"
TMP_OLD_CONF="tmp.old.conf"

OSYNC_EXECUTABLE="$FAKEROOT/usr/local/bin/osync.sh"
OSYNC_DEV_EXECUTABLE="dev/n_osync.sh"
OSYNC_UPGRADE="upgrade-v1.0x-v1.3x.sh"
TMP_FILE="$DEV_DIR/tmp"


OSYNC_TESTS_DIR="${HOME}/osync-tests"
INITIATOR_DIR="$OSYNC_TESTS_DIR/initiator"
TARGET_DIR="$OSYNC_TESTS_DIR/target"
OSYNC_WORKDIR=".osync_workdir"
OSYNC_STATE_DIR="$OSYNC_WORKDIR/state"
OSYNC_DELETE_DIR="$OSYNC_WORKDIR/deleted"
OSYNC_BACKUP_DIR="$OSYNC_WORKDIR/backup"

# Later populated variables
OSYNC_VERSION=1.x.y
OSYNC_MIN_VERSION=x
OSYNC_IS_STABLE=maybe

PRIVKEY_NAME="id_rsa_local_osync_tests"
PUBKEY_NAME="${PRIVKEY_NAME}.pub"

function SetupSSH {
	echo "Setting up an ssh key to ${HOME}/.ssh/${PRIVKEY_NAME}"
	echo -e  'y\n'| ssh-keygen -t rsa -b 2048 -N "" -f "${HOME}/.ssh/${PRIVKEY_NAME}"

	SSH_AUTH_LINE="from=\"*\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,command=\"$FAKEROOT/usr/local/bin/ssh_filter.sh SomeAlphaNumericToken9\" $(cat ${HOME}/.ssh/${PUBKEY_NAME})"
	echo "ls -alh ${HOME}"
	ls -alh "${HOME}"
	echo "ls -alh ${HOME}/.ssh"
	ls -alh "${HOME}/.ssh"

	if [ -f "${HOME}/.ssh/authorized_keys" ]; then
		if ! grep "$(cat ${HOME}/.ssh/${PUBKEY_NAME})" "${HOME}/.ssh/authorized_keys"; then
			echo "$SSH_AUTH_LINE" >> "${HOME}/.ssh/authorized_keys"
		fi
	else
		echo "$SSH_AUTH_LINE" >> "${HOME}/.ssh/authorized_keys"
	fi
	chmod 600 "${HOME}/.ssh/authorized_keys"

	# Add localhost to known hosts so self connect works
	if [ -z "$(ssh-keygen -F localhost)" ]; then
		ssh-keyscan -H localhost >> "${HOME}/.ssh/known_hosts"
	fi

	# Update remote conf files with SSH port
	sed -i.tmp 's#ssh://.*@localhost:[0-9]*/${HOME}/osync-tests/target#ssh://'$REMOTE_USER'@localhost:'$SSH_PORT'/${HOME}/osync-tests/target#' "$CONF_DIR/$REMOTE_CONF"

	echo "ls -alh ${HOME}/.ssh"
	ls -alh "${HOME}/.ssh"
	echo "cat ${HOME}/.ssh.authorized_keys" 
	cat "${HOME}/.ssh/authorized_keys"
	
	echo "###"
	echo "END SETUP SSH"
}

function RemoveSSH {
	echo "Now removing SSH keys"
	if [ -f "${HOME}/.ssh/id_rsa_local_osync_tests" ]; then
		echo "Restoring SSH authorized_keys file"
		sed -i.bak "s|.*$(cat "${HOME}/.ssh/id_rsa_local_osync_tests.pub")||g" "${HOME}/.ssh/authorized_keys"
		rm -f "${HOME}/.ssh/{id_rsa_local_osync_tests.pub,id_rsa_local_osync_tests}"
	fi
}

function DownloadLargeFileSet() {
	local destinationPath="${1}"

	cd "$OSYNC_DIR"
	if type wget > /dev/null 2>&1; then
		wget -q --no-check-certificate "$LARGE_FILESET_URL" > /dev/null
		assertEquals "Download [$LARGE_FILESET_URL] with wget." "0" $?
	elif type curl > /dev/null 2>&1; then
		curl -O -L "$LARGE_FILESET_URL" > /dev/null 2>&1
		assertEquals "Download [$LARGE_FILESET_URL] with curl." "0" $?
	fi

	tar xf "$(basename $LARGE_FILESET_URL)" -C "$destinationPath"
	assertEquals "Extract $(basename $LARGE_FILESET_URL)" "0" $?

	rm -f "$(basename $LARGE_FILESET_URL)"
}

function CreateOldFile () {
	local drive
	local filePath="${1}"
	local type="${2:-false}"

	if [ $type == true ]; then
		mkdir -p "$filePath"
	else
		mkdir -p "$(dirname $filePath)"
		touch "$filePath"
	fi

	assertEquals "touch [$filePath]" "0" $?

	# Get current drive
	drive=$(df "$OSYNC_DIR" | tail -1 | awk '{print $1}')

	# modify ctime on ext4 so osync thinks it has to delete the old files
	debugfs -w -R 'set_inode_field "'$filePath'" ctime 201001010101' $drive
	assertEquals "CreateOldFile [$filePath]" "0" $?

	# force update of inodes (ctimes)
	echo 3 > /proc/sys/vm/drop_caches
	assertEquals "Drop caches" "0" $?
}

function PrepareLocalDirs () {
	if [ -d "$OSYNC_TESTS_DIR" ]; then
		rm -rf "$OSYNC_TESTS_DIR"
	fi
	mkdir "$OSYNC_TESTS_DIR"
	mkdir "$INITIATOR_DIR"
	mkdir "$TARGET_DIR"
}

function oneTimeSetUp () {
	START_TIME=$SECONDS

	mkdir -p "$FAKEROOT"

	source "$DEV_DIR/ofunctions.sh"

	# Fix default umask because of ACL test that expects 0022 when creating test files
	umask 0022

	GetLocalOS

	echo "Detected OS: $LOCAL_OS"

	# Set some travis related changes
	if [ "$RUNNING_ON_GITHUB_ACTIONS" == true ]; then
	echo "Running with GITHUB ACTIONS settings"
		REMOTE_USER="runner"
		RHOST_PING=false
		SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "REMOTE_3RD_PARTY_HOSTS" ""
		SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "REMOTE_HOST_PING" false

		SetConfFileValue "$CONF_DIR/$OLD_CONF" "REMOTE_3RD_PARTY_HOSTS" ""
		SetConfFileValue "$CONF_DIR/$OLD_CONF" "REMOTE_HOST_PING" false
	else
		echo "Running with local settings"
		REMOTE_USER="root"
		RHOST_PING=true
		SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "REMOTE_3RD_PARTY_HOSTS" "\"www.kernel.org www.google.com\""
		SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "REMOTE_HOST_PING" true

		SetConfFileValue "$CONF_DIR/$OLD_CONF" "REMOTE_3RD_PARTY_HOSTS" "\"www.kernel.org www.google.com\""
		SetConfFileValue "$CONF_DIR/$OLD_CONF" "REMOTE_HOST_PING" true
	fi

	# Get default ssh port from env
	if [ "$SSH_PORT" == "" ]; then
		SSH_PORT=22
	fi

	# Setup modes per test
	readonly __quickLocal=0
	readonly __quickRemote=1
	readonly __confLocal=2
	readonly __confRemote=3

	osyncParameters=()
	osyncParameters[$__quickLocal]="--initiator=$INITIATOR_DIR --target=$TARGET_DIR --instance-id=quicklocal"
	osyncParameters[$__confLocal]="$CONF_DIR/$LOCAL_CONF"

	osyncDaemonParameters=()

	readonly __local
	readonly __remote

	osyncDaemonParameters[$__local]="$CONF_DIR/$LOCAL_CONF --on-changes"

  # Do not check remote config on msys or cygwin since we don't have a local SSH server
	if [ "$LOCAL_OS" != "msys" ] && [ "$LOCAL_OS" != "Cygwin" ] && [ $SKIP_REMOTE != true ]; then
		osyncParameters[$__quickRemote]="--initiator=$INITIATOR_DIR --target=ssh://localhost:$SSH_PORT/$TARGET_DIR --rsakey=${HOME}/.ssh/id_rsa_local_osync_tests --instance-id=quickremote --remote-token=SomeAlphaNumericToken9"
		osyncParameters[$__confRemote]="$CONF_DIR/$REMOTE_CONF"

		osyncDaemonParameters[$__remote]="$CONF_DIR/$REMOTE_CONF --on-changes"

		SetupSSH
	fi

	#TODO: Assuming that macos has the same syntax than bsd here
	if [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
		SUDO_CMD=""
	elif [ "$LOCAL_OS" == "BSD" ] || [ "$LOCAL_OS" == "MacOSX" ]; then
		SUDO_CMD=""
		IMMUTABLE_ON_CMD="chflags schg"
		IMMUTABLE_OFF_CMD="chflags noschg"
	else
		IMMUTABLE_ON_CMD="chattr +i"
		IMMUTABLE_OFF_CMD="chattr -i"
		SUDO_CMD="sudo"
	fi

	# Get osync version
	OSYNC_VERSION=$(GetConfFileValue "$OSYNC_DIR/$OSYNC_DEV_EXECUTABLE" "PROGRAM_VERSION")
	OSYNC_VERSION="${OSYNC_VERSION##*=}"
	OSYNC_MIN_VERSION="${OSYNC_VERSION:2:1}"

	OSYNC_IS_STABLE=$(GetConfFileValue "$OSYNC_DIR/$OSYNC_DEV_EXECUTABLE" "IS_STABLE")

	echo "Running with $OSYNC_VERSION ($OSYNC_MIN_VERSION) STABLE=$OSYNC_IS_STABLE"

	# Be sure to set default values for config files which can be incoherent if tests gets aborted
	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "SKIP_DELETION" ""
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "SKIP_DELETION" ""

	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "COPY_SYMLINKS" false
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "COPY_SYMLINKS" false

	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "CONFLICT_BACKUP_MULTIPLE" false
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "CONFLICT_BACKUP_MULTIPLE" false

	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "FORCE_STRANGER_LOCK_RESUME" false
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "FORCE_STRANGER_LOCK_RESUME" false

	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "SOFT_MAX_EXEC_TIME" "7200"
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "HARD_MAX_EXEC_TIME" "10600"

}

function oneTimeTearDown () {

	# Set osync version stable flag back to origin
	#SetConfFileValue "$OSYNC_DIR/osync.sh" "IS_STABLE" "$OSYNC_IS_STABLE"

	if [ "$SKIP_REMOTE" != true ]; then
		RemoveSSH
	fi

	#TODO: uncomment this when dev is done
	#rm -rf "$OSYNC_TESTS_DIR"
	rm -f "$TMP_FILE"

	cd "$OSYNC_DIR"
	echo ""
	echo "Uninstalling osync from $FAKEROOT"
	$SUDO_CMD ./install.sh --remove --no-stats --prefix="$FAKEROOT"
	assertEquals "Uninstall failed" "0" $?

	ELAPSED_TIME=$((SECONDS-START_TIME))
	echo "It took $ELAPSED_TIME seconds to run these tests."
}

function setUp () {
	rm -rf "$INITIATOR_DIR"
	rm -rf "$TARGET_DIR"
}

function test_SSH {
	# Make sure we have SSH on your test server
	# This has become kind of tricky on github actions servers
	echo "Testing SSH"

	failure=false
	
	echo "ls -alh ${HOME}/.ssh"
	ls -alh "${HOME}/.ssh"

	echo "Running SSH test as ${REMOTE_USER}"
	# SSH_PORT and SSH_USER are set by oneTimeSetup
	$SUDO_CMD ssh -i "${REMOTE_USER}/.ssh/${PRIVKEY_NAME}" -p $SSH_PORT ${REMOTE_USER}@localhost "echo \"Remotely:\"; whoami; echo \"TEST OK\""
	if [ $? -ne 0 ]; then
		echo "SSH test failed"
		failure=true
	fi
	
	echo "Running SSH test as $(whoami)"
	$SUDO_CMD ssh -i "$(whoami)/.ssh/${PRIVKEY_NAME}" -p $SSH_PORT $(whoami)@localhost "echo \"Remotely:\"; whoami; echo \"TEST OK\""
	if [ $? -ne 0 ]; then
		echo "SSH test failed"
		failure=true
	fi
	
	if [ $failure == true ]; then
		exit 1 # Try to see if we can abort all tests
		assertEquals "Test SSH failed" false $failure
	fi
}

# This test has to be done everytime in order for osync executable to be fresh
function test_Merge () {
	cd "$DEV_DIR"
	./merge.sh osync
	assertEquals "Merging code" "0" $?

	#WIP use debug code
	alias cp=cp
	cp "$DEV_DIR/debug_osync.sh" "$OSYNC_DIR/osync.sh"

	cd "$OSYNC_DIR"

	echo ""
	echo "Installing osync to $FAKEROOT"
	$SUDO_CMD ./install.sh --no-stats --prefix="$FAKEROOT"

	# Set osync version to stable while testing to avoid warning message
	# Don't use SetConfFileValue here since for whatever reason Travis does not like creating a sed temporary file in $FAKEROOT

	if [ "$RUNNING_ON_GITHUB_ACTIONS" == true ]; then
		$SUDO_CMD sed -i.tmp 's/^IS_STABLE=.*/IS_STABLE=true/' "$OSYNC_EXECUTABLE"
	else
		sed -i.tmp 's/^IS_STABLE=.*/IS_STABLE=true/' "$OSYNC_EXECUTABLE"
	fi
	#SetConfFileValue "$OSYNC_EXECUTABLE" "IS_STABLE" true


	assertEquals "Install failed" "0" $?
}

function xtest_LargeFileSet () {
	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"

		PrepareLocalDirs
		DownloadLargeFileSet "$INITIATOR_DIR"

		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "LargeFileSet test with parameters [$i]." "0" $?

		[ -d "$INITIATOR_DIR/$OSYNC_STATE_DIR" ]
		assertEquals "Initiator state dir exists" "0" $?

		[ -d "$TARGET_DIR/$OSYNC_STATE_DIR" ]
		assertEquals "Target state dir exists" "0" $?
	done
}

function xtest_controlMaster () {
	cd "$OSYNC_DIR"

	PrepareLocalDirs
	echo "Running with parameters ${osyncParameters[$__quickRemote]} --ssh-controlmaster"
	REMOTE_HOST_PING=$REMOTE_PING $OSYNC_EXECUTABLE ${osyncParameters[$__quickRemote]} --ssh-controlmaster
	assertEquals "Running quick remote test with controlmaster enabled." "0" $?
}

function xtest_Exclusions () {
	# Will sync except php files
	# RSYNC_EXCLUDE_PATTERN="*.php" is set at runtime for quicksync and in config files for other runs

	local numberOfPHPFiles
	local numberOfExcludedFiles
	local numberOfInitiatorFiles
	local numberOfTargetFiles

	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"

		PrepareLocalDirs
		DownloadLargeFileSet "$INITIATOR_DIR"

		numberOfPHPFiles=$(find "$INITIATOR_DIR" ! -wholename "$INITIATOR_DIR/$OSYNC_WORKDIR*" -name "*.php" | wc -l)

		REMOTE_HOST_PING=$RHOST_PING RSYNC_EXCLUDE_PATTERN="*.php" $OSYNC_EXECUTABLE $i
		assertEquals "Exclusions with parameters [$i]." "0" $?

		numberOfInitiatorFiles=$(find "$INITIATOR_DIR" ! -wholename "$INITIATOR_DIR/$OSYNC_WORKDIR*" | wc -l)
		numberOfTargetFiles=$(find "$TARGET_DIR" ! -wholename "$TARGET_DIR/$OSYNC_WORKDIR*" | wc -l)
		numberOfExcludedFiles=$((numberOfInitiatorFiles-numberOfTargetFiles))

		assertEquals "Number of php files: $numberOfPHPFiles - Number of excluded files: $numberOfExcludedFiles" $numberOfPHPFiles $numberOfExcludedFiles
	done
}

function xtest_Deletetion () {
	local iFile1="$INITIATOR_DIR/i fic"
	local iFile2="$INITIATOR_DIR/i foc (something)"
	local tFile1="$TARGET_DIR/t fic"
	local tFile2="$TARGET_DIR/t foc [nothing]"


	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"

		PrepareLocalDirs
		touch "$iFile1"
		touch "$iFile2"
		touch "$tFile1"
		touch "$tFile2"

		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "First deletion run with parameters [$i]." "0" $?

		rm -f "$iFile1"
		rm -f "$tFile1"

		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "Second deletion run with parameters [$i]." "0" $?

		[ -f "$TARGET_DIR/$OSYNC_DELETE_DIR/$(basename $iFile1)" ]
		assertEquals "File [$TARGET_DIR/$OSYNC_DELETE_DIR/$(basename $iFile1)] has been soft deleted on target" "0" $?
		[ -f "$iFile1" ]
		assertEquals "File [$iFile1] is still in initiator" "1" $?

		# The variable substitution is not the best comprehensible code
		[ -f "${iFile1/$INITIATOR_DIR/TARGET_DIR}" ]
		assertEquals "File [${iFile1/$INITIATOR_DIR/TARGET_DIR}] is still in target" "1" $?

		[ -f "$INITIATOR_DIR/$OSYNC_DELETE_DIR/$(basename $tFile1)" ]
		assertEquals "File [$INITIATOR_DIR/$OSYNC_DELETE_DIR/$(basename $tFile1)] has been soft deleted on initiator" "0" $?
		[ -f "$tFile1" ]
		assertEquals "File [$tFile1] is still in target" "1" $?

		[ -f "${tFile1/$TARGET_DIR/INITIATOR_DIR}" ]
		assertEquals "File [${tFile1/$TARGET_DIR/INITIATOR_DIR}] is still in initiator" "1" $?
	done
}

function xtest_deletion_failure () {
	if [ "$LOCAL_OS" == "WinNT10" ] || [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
		echo "Skipping deletion failure test as Win10 does not have chattr  support."
		return 0
	fi

	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"

		PrepareLocalDirs

		DirA="some directory with spaces"
		DirB="another directoy/and sub directory"

		mkdir -p "$INITIATOR_DIR/$DirA"
		mkdir -p "$TARGET_DIR/$DirB"

		FileA="$DirA/File A"
		FileB="$DirB/File B"

		touch "$INITIATOR_DIR/$FileA"
		touch "$TARGET_DIR/$FileB"

		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "First deletion run with parameters [$i]." "0" $?

		rm -f "$INITIATOR_DIR/$FileA"
		rm -f "$TARGET_DIR/$FileB"

		# Prevent files from being deleted
		$SUDO_CMD $IMMUTABLE_ON_CMD "$TARGET_DIR/$FileA"
		$SUDO_CMD $IMMUTABLE_ON_CMD "$INITIATOR_DIR/$FileB"

		# This shuold fail with exitcode 1
		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "Second deletion run with parameters [$i]." "1" $?

		# standard file tests
		[ -f "$TARGET_DIR/$FileA" ]
		assertEquals "File [$TARGET_DIR/$FileA] is still present in replica dir." "0" $?
		[ ! -f "$TARGET_DIR/$OSYNC_DELETE_DIR/$FileA" ]
		assertEquals "File [$TARGET_DIR/$OSYNC_DELETE_DIR/$FileA] is not present in deletion dir." "0" $?

		[ -f "$INITIATOR_DIR/$FileB" ]
		assertEquals "File [$INITIATOR_DIR/$FileB] is still present in replica dir." "0" $?
		[ ! -f "$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileB" ]
		assertEquals "File [$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileB] is not present in deletion dir." "0" $?

		# Allow files from being deleted
		$SUDO_CMD $IMMUTABLE_OFF_CMD "$TARGET_DIR/$FileA"
		$SUDO_CMD $IMMUTABLE_OFF_CMD "$INITIATOR_DIR/$FileB"

		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i --verbose
		assertEquals "Third deletion run with parameters [$i]." "0" $?

		[ ! -f "$TARGET_DIR/$FileA" ]
		assertEquals "File [$TARGET_DIR/$FileA] is still present in replica dir." "0" $?
		[ -f "$TARGET_DIR/$OSYNC_DELETE_DIR/$FileA" ]
		assertEquals "File [$TARGET_DIR/$OSYNC_DELETE_DIR/$FileA] is not present in deletion dir." "0" $?

		[ ! -f "$INITIATOR_DIR/$FileB" ]
		assertEquals "File [$INITIATOR_DIR/$FileB] is still present in replica dir." "0" $?
		[ -f "$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileB" ]
		assertEquals "File [$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileB] is not present in deletion dir." "0" $?
	done
}

function xtest_skip_deletion () {
	local modes

	if [ "$OSYNC_MIN_VERSION" == "1" ]; then
		echo "Skipping SkipDeletion test because it wasn't implemented in osync v1.1."
		return 0
	fi

	# TRAVIS SPECIFIC - time limitation
	if [ "$RUNNING_ON_GITHUB_ACTIONS" != true ]; then
		modes=('initiator' 'target' 'initiator,target')
	else
		modes=('target')
	fi

	for mode in "${modes[@]}"; do

		SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "SKIP_DELETION" "$mode"
		SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "SKIP_DELETION" "$mode"

		for i in "${osyncParameters[@]}"; do
			cd "$OSYNC_DIR"
			PrepareLocalDirs

			DirA="another/one/bites/ de_dust"
			DirB="phantom of /the opera"

			mkdir -p "$INITIATOR_DIR/$DirA"
			mkdir -p "$TARGET_DIR/$DirB"

			FileA="$DirA/Iron Rhapsody"
			FileB="$DirB/Bohemian Maiden"

			touch "$INITIATOR_DIR/$FileA"
			touch "$TARGET_DIR/$FileB"

			# First run
			REMOTE_HOST_PING=$RHOST_PING SKIP_DELETION="$mode" $OSYNC_EXECUTABLE $i
			assertEquals "First deletion run with parameters [$i]." "0" $?

			rm -f "$INITIATOR_DIR/$FileA"
			rm -f "$TARGET_DIR/$FileB"

			# Second run
			REMOTE_HOST_PING=$RHOST_PING SKIP_DELETION="$mode" $OSYNC_EXECUTABLE $i
			assertEquals "First deletion run with parameters [$i]." "0" $?

			if [ "$mode" == "initiator" ]; then
				[ -f "$TARGET_DIR/$FileA" ]
				assertEquals "File [$TARGET_DIR/$FileA] still exists in mode $mode." "1" $?
				[ -f "$INITIATOR_DIR/$FileB" ]
				assertEquals "File [$INITIATOR_DIR/$FileB still exists in mode $mode." "0" $?

			elif [ "$mode" == "target" ]; then
				[ -f "$TARGET_DIR/$FileA" ]
				assertEquals "File [$TARGET_DIR/$FileA] still exists in mode $mode." "0" $?
				[ -f "$INITIATOR_DIR/$FileB" ]
				assertEquals "File [$INITIATOR_DIR/$FileB still exists in mode $mode." "1" $?


			elif [ "$mode" == "initiator,target" ]; then
				[ -f "$TARGET_DIR/$FileA" ]
				assertEquals "File [$TARGET_DIR/$FileA] still exists in mode $mode." "0" $?
				[ -f "$INITIATOR_DIR/$FileB" ]
				assertEquals "File [$INITIATOR_DIR/$FileB still exists in mode $mode." "0" $?
			else
				assertEquals "Bogus skip deletion mode" "0" "1"
			fi
		done
	done

	# Set original values back
	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "SKIP_DELETION" ""
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "SKIP_DELETION" ""
}

function xtest_handle_symlinks () {
	if [ "$OSYNC_MIN_VERSION" == "1" ]; then
		echo "Skipping symlink tests as osync v1.1x didn't handle this."
		return 0
	fi

	if [ "$LOCAL_OS" == "msys" ]; then
		echo "Skipping symlink tests because msys handles them strangely or not at all."
		return 0
	fi

	# Check with and without copySymlinks
	copySymlinks=false

	echo "Running with COPY_SYMLINKS=$copySymlinks"

	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "COPY_SYMLINKS" "$copySymlinks"
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "COPY_SYMLINKS" "$copySymlinks"

	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"

		PrepareLocalDirs

		DirA="some directory with spaces"
		DirB="another directoy/and sub directory"

		mkdir -p "$INITIATOR_DIR/$DirA"
		mkdir -p "$TARGET_DIR/$DirB"

		FileA="$DirA/File A"
		FileB="$DirB/File B"
		FileAL="$DirA/File A symlink"
		FileBL="$DirB/File B symlink"

		# Create symlinks
		touch "$INITIATOR_DIR/$FileA"
		touch "$TARGET_DIR/$FileB"
		ln -s "$INITIATOR_DIR/$FileA" "$INITIATOR_DIR/$FileAL"
		ln -s "$TARGET_DIR/$FileB" "$TARGET_DIR/$FileBL"

		COPY_SYMLINKS=$copySymlinks REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "First symlink run with parameters [$i]." "0" $?

		# Delete symlinks
		rm -f "$INITIATOR_DIR/$FileAL"
		rm -f "$TARGET_DIR/$FileBL"

		COPY_SYMLINKS=$copySymlinks REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "Second symlink deletion run with parameters [$i]." "0" $?

		# symlink deletion propagation
		[ ! -L "$TARGET_DIR/$FileAL" ]
		assertEquals "File [$TARGET_DIR/$FileAL] is still present in replica dir." "0" $?
		[ -L "$TARGET_DIR/$OSYNC_DELETE_DIR/$FileAL" ]
		assertEquals "File [$TARGET_DIR/$OSYNC_DELETE_DIR/$FileAL] is not present in deletion dir." "0" $?
		[ ! -L "$INITIATOR_DIR/$FileBL" ]
		assertEquals "File [$INITIATOR_DIR/$FileBL] is still present in replica dir." "0" $?
		[ -L "$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileBL" ]
		assertEquals "File [$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileBL] is not present in deletion dir." "0" $?

		# Create broken symlinks and propagate them
		ln -s "$INITIATOR_DIR/$FileA" "$INITIATOR_DIR/$FileAL"
		ln -s "$TARGET_DIR/$FileB" "$TARGET_DIR/$FileBL"
		rm -f "$INITIATOR_DIR/$FileA"
		rm -f "$TARGET_DIR/$FileB"

		COPY_SYMLINKS=$copySymlinks REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "Third broken symlink run with parameters [$i]." "0" $?

		[ -L "$TARGET_DIR/$FileAL" ]
		assertEquals "File [$TARGET_DIR/$FileAL] is present in replica dir." "0" $?

		[ -L "$INITIATOR_DIR/$FileBL" ]
		assertEquals "File [$INITIATOR_DIR/$FileBL] is present in replica dir." "0" $?

		# Check broken symlink deletion propagation
		rm -f "$INITIATOR_DIR/$FileAL"
		rm -f "$TARGET_DIR/$FileBL"

		COPY_SYMLINKS=$copySymlinks REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "Fourth symlink deletion run with parameters [$i]." "0" $?

		[ ! -L "$TARGET_DIR/$FileAL" ]
		assertEquals "File [$TARGET_DIR/$FileAL] is still present in replica dir." "0" $?
		[ -L "$TARGET_DIR/$OSYNC_DELETE_DIR/$FileAL" ]
		assertEquals "File [$TARGET_DIR/$OSYNC_DELETE_DIR/$FileAL] is not present in deletion dir." "0" $?
		[ ! -L "$INITIATOR_DIR/$FileBL" ]
		assertEquals "File [$INITIATOR_DIR/$FileBL] is still present in replica dir." "0" $?
		[ -L "$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileBL" ]
		assertEquals "File [$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileBL] is not present in deletion dir." "0" $?
	done

	# TRAVIS SPECIFIC - time limitation
	if [ "$RUNNING_ON_GITHUB_ACTIONS" != true ]; then
		return 0
	fi

	# Check with and without copySymlinks
	copySymlinks=true

	echo "Running with COPY_SYMLINKS=$copySymlinks"

	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "COPY_SYMLINKS" "$copySymlinks"
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "COPY_SYMLINKS" "$copySymlinks"

	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"

		PrepareLocalDirs

		DirA="some directory with spaces"
		DirB="another directoy/and sub directory"

		mkdir -p "$INITIATOR_DIR/$DirA"
		mkdir -p "$TARGET_DIR/$DirB"

		FileA="$DirA/File A"
		FileB="$DirB/File B"
		FileAL="$DirA/File A symlink"
		FileBL="$DirB/File B symlink"

		# Create symlinks
		touch "$INITIATOR_DIR/$FileA"
		touch "$TARGET_DIR/$FileB"
		ln -s "$INITIATOR_DIR/$FileA" "$INITIATOR_DIR/$FileAL"
		ln -s "$TARGET_DIR/$FileB" "$TARGET_DIR/$FileBL"

		COPY_SYMLINKS=$copySymlinks REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "First symlink run with parameters [$i]." "0" $?

		# Delete symlinks
		rm -f "$INITIATOR_DIR/$FileAL"
		rm -f "$TARGET_DIR/$FileBL"

		COPY_SYMLINKS=$copySymlinks REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "Second symlink deletion run with parameters [$i]." "0" $?

		# symlink deletion propagation
		[ ! -f "$TARGET_DIR/$FileAL" ]
		assertEquals "File [$TARGET_DIR/$FileAL] is still present in replica dir." "0" $?
		[ -f "$TARGET_DIR/$OSYNC_DELETE_DIR/$FileAL" ]
		assertEquals "File [$TARGET_DIR/$OSYNC_DELETE_DIR/$FileAL] is not present in deletion dir." "0" $?
		[ ! -f "$INITIATOR_DIR/$FileBL" ]
		assertEquals "File [$INITIATOR_DIR/$FileBL] is still present in replica dir." "0" $?
		[ -f "$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileBL" ]
		assertEquals "File [$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileBL] is not present in deletion dir." "0" $?

		# Create broken symlinks and propagate them
		ln -s "$INITIATOR_DIR/$FileA" "$INITIATOR_DIR/$FileAL"
		ln -s "$TARGET_DIR/$FileB" "$TARGET_DIR/$FileBL"
		rm -f "$INITIATOR_DIR/$FileA"
		rm -f "$TARGET_DIR/$FileB"

		COPY_SYMLINKS=$copySymlinks REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "Third broken symlink run with parameters should fail [$i]." "1" $?

		[ ! -f "$TARGET_DIR/$FileAL" ]
		assertEquals "File [$TARGET_DIR/$FileAL] is present in replica dir." "0" $?

		[ ! -f "$INITIATOR_DIR/$FileBL" ]
		assertEquals "File [$INITIATOR_DIR/$FileBL] is present in replica dir." "0" $?

		# Check broken symlink deletion propagation
		rm -f "$INITIATOR_DIR/$FileAL"
		rm -f "$TARGET_DIR/$FileBL"

		COPY_SYMLINKS=$copySymlinks REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "Fourth symlink deletion run should resume with parameters [$i]." "0" $?

		[ ! -f "$TARGET_DIR/$FileAL" ]
		assertEquals "File [$TARGET_DIR/$FileAL] is still present in replica dir." "0" $?
		[ -f "$TARGET_DIR/$OSYNC_DELETE_DIR/$FileAL" ]
		assertEquals "File [$TARGET_DIR/$OSYNC_DELETE_DIR/$FileAL] is not present in deletion dir." "0" $?
		[ ! -f "$INITIATOR_DIR/$FileBL" ]
		assertEquals "File [$INITIATOR_DIR/$FileBL] is still present in replica dir." "0" $?
		[ -f "$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileBL" ]
		assertEquals "File [$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileBL] is not present in deletion dir." "0" $?
	done
}

function xtest_softdeletion_cleanup () {
	#declare -A files

	files=()
	files[0]="$INITIATOR_DIR/$OSYNC_DELETE_DIR/someDeletedFileInitiator"
	files[1]="$TARGET_DIR/$OSYNC_DELETE_DIR/someDeletedFileTarget"
	files[2]="$INITIATOR_DIR/$OSYNC_BACKUP_DIR/someBackedUpFileInitiator"
	files[3]="$TARGET_DIR/$OSYNC_BACKUP_DIR/someBackedUpFileTarget"

	DirA="$INITIATOR_DIR/$OSYNC_DELETE_DIR/somedir"
	DirB="$TARGET_DIR/$OSYNC_DELETE_DIR/someotherdir"

	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"
		PrepareLocalDirs

		# First run
		#REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		#assertEquals "First deletion run with parameters [$i]." "0" $?

		# Get current drive
		drive=$(df "$OSYNC_DIR" | tail -1 | awk '{print $1}')

		# Create some deleted & backed up files, some new and some old
		for file in "${files[@]}"; do
			# Create directories first if they do not exist (deletion dir is created by osync, backup dir is created by rsync only when needed)
			if [ ! -d "$(dirname $file)" ]; then
				mkdir -p "$(dirname $file)"
			fi

			touch "$file.new"

			if [ "$RUNNING_ON_GITHUB_ACTIONS" == true ] || [ "$LOCAL_OS" == "BSD" ] || [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "WinNT10" ] || [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
				echo "Skipping changing ctime on file because travis / bsd / macos / Win10 / msys / cygwin does not support debugfs"
			else
				CreateOldFile "$file.old"
			fi
		done
		if [ "$RUNNING_ON_GITHUB_ACTIONS" == true ] || [ "$LOCAL_OS" == "BSD" ] || [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "WinNT10" ] || [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
			echo "Skipping changing ctime on dir too"
		else
			CreateOldFile "$DirA" true
			CreateOldFile "$DirB" true
		fi

		# Second run
		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i

		# Check file presence
		for file in "${files[@]}"; do
			[ -f "$file.new" ]
			assertEquals "New softdeleted / backed up file [$file.new] exists." "0" $?

			if [ "$RUNNING_ON_GITHUB_ACTIONS" == true ] || [ "$LOCAL_OS" == "BSD" ] || [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "WinNT10" ] || [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
				[ ! -f "$file.old" ]
				assertEquals "Old softdeleted / backed up file [$file.old] is deleted permanently." "0" $?
			else
				[ ! -f "$file.old" ]
				assertEquals "Old softdeleted / backed up file [$file.old] is deleted permanently." "1" $?
			fi
		done

		if [ "$RUNNING_ON_GITHUB_ACTIONS" == true ] || [ "$LOCAL_OS" == "BSD" ] || [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "WinNT10" ] || [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
			[ ! -d "$DirA" ]
			assertEquals "Old softdeleted / backed up directory [$dirA] is deleted permanently." "0" $?
			[ ! -d "$DirB" ]
			assertEquals "Old softdeleted / backed up directory [$dirB] is deleted permanently." "0" $?
		else
			[ ! -d "$DirA" ]
			assertEquals "Old softdeleted / backed up directory [$DirA] is deleted permanently." "1" $?
			[ ! -d "$DirB" ]
			assertEquals "Old softdeleted / backed up directory [$DirB] is deleted permanently." "1" $?
		fi
	done

}

function xtest_FileAttributePropagation () {

	if [ "$RUNNING_ON_GITHUB_ACTIONS" == true ]; then
		echo "Skipping FileAttributePropagation tests as travis does not support getfacl / setfacl."
		return 0
	fi

	if [ "$LOCAL_OS" == "MacOSX" ] || [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
		echo "Skipping FileAttributePropagation tests because [$LOCAL_OS]  does not support ACL."
		return 0
	fi

        SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "PRESERVE_ACL" true
        SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "PRESERVE_XATTR" true
        SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "PRESERVE_ACL" true
        SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "PRESERVE_XATTR" true

	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"
		PrepareLocalDirs

		DirA="dir a"
		DirB="dir b"
		DirC="dir c"
		DirD="dir d"

		mkdir "$INITIATOR_DIR/$DirA"
		mkdir "$TARGET_DIR/$DirB"
		mkdir "$INITIATOR_DIR/$DirC"
		mkdir "$TARGET_DIR/$DirD"

		FileA="$DirA/FileA"
		FileB="$DirB/FileB"

		touch "$INITIATOR_DIR/$FileA"
		touch "$TARGET_DIR/$FileB"

		# First run
		PRESERVE_ACL=yes PRESERVE_XATTR=yes REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "First deletion run with parameters [$i]." "0" $?

		sleep 1

		getfacl "$INITIATOR_DIR/$FileA" | grep "other::r--" > /dev/null
		assertEquals "Check getting ACL on initiator." "0" $?

		getfacl "$TARGET_DIR/$FileB" | grep "other::r--" > /dev/null
		assertEquals "Check getting ACL on target." "0" $?

		getfacl "$INITIATOR_DIR/$DirC" | grep "other::r-x" > /dev/null
		assertEquals "Check getting ACL on initiator subdirectory." "0" $?

		getfacl "$TARGET_DIR/$DirD" | grep "other::r-x" > /dev/null
		assertEquals "Check getting ACL on target subdirectory." "0" $?

		setfacl -m o::r-x "$INITIATOR_DIR/$FileA"
		assertEquals "Set ACL on initiator" "0" $?
		setfacl -m o::-w- "$TARGET_DIR/$FileB"
		assertEquals "Set ACL on target" "0" $?

		setfacl -m o::rwx "$INITIATOR_DIR/$DirC"
		assertEquals "Set ACL on initiator directory" "0" $?
		setfacl -m o::-wx "$TARGET_DIR/$DirD"
		assertEquals "Set ACL on target directory" "0" $?

		# Second run
		PRESERVE_ACL=yes PRESERVE_XATTR=yes REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "First deletion run with parameters [$i]." "0" $?

		getfacl "$TARGET_DIR/$FileA" | grep "other::r-x" > /dev/null
		assertEquals "ACLs matched original value on target." "0" $?

		getfacl "$INITIATOR_DIR/$FileB" | grep "other::-w-" > /dev/null
		assertEquals "ACLs matched original value on initiator." "0" $?

		getfacl "$TARGET_DIR/$DirC" | grep "other::rwx" > /dev/null
		assertEquals "ACLs matched original value on target subdirectory." "0" $?

		getfacl "$INITIATOR_DIR/$DirD" | grep "other::-wx" > /dev/null
		assertEquals "ACLs matched original value on initiator subdirectory." "0" $?
	done

        SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "PRESERVE_ACL" false
        SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "PRESERVE_XATTR" false
        SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "PRESERVE_ACL" false
        SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "PRESERVE_XATTR" false
}

function xtest_ConflictBackups () {
	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"
		PrepareLocalDirs

		DirA="some dir"
		DirB="some other dir"

		mkdir -p "$INITIATOR_DIR/$DirA"
		mkdir -p "$TARGET_DIR/$DirB"

		FileA="$DirA/FileA"
		FileB="$DirB/File B"

		echo "$FileA" > "$INITIATOR_DIR/$FileA"
		echo "$FileB" > "$TARGET_DIR/$FileB"

		# First run
		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "First deletion run with parameters [$i]." "0" $?

		echo "$FileA+" > "$TARGET_DIR/$FileA"
		echo "$FileB+" > "$INITIATOR_DIR/$FileB"

		# Second run
		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "First deletion run with parameters [$i]." "0" $?

		[ -f "$INITIATOR_DIR/$OSYNC_BACKUP_DIR/$FileA" ]
		assertEquals "Backup file is present in [$INITIATOR_DIR/$OSYNC_BACKUP_DIR/$FileA]." "0" $?

		[ -f "$TARGET_DIR/$OSYNC_BACKUP_DIR/$FileB" ]
		assertEquals "Backup file is present in [$TARGET_DIR/$OSYNC_BACKUP_DIR/$FileB]." "0" $?
	done
}

function xtest_MultipleConflictBackups () {

	local additionalParameters

	# modify config files
	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "CONFLICT_BACKUP_MULTIPLE" true
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "CONFLICT_BACKUP_MULTIPLE" true

	if [ "$OSYNC_MIN_VERSION" != "1" ]; then
		additionalParameters="--errors-only --summary --no-prefix"
	fi

	for i in "${osyncParameters[@]}"; do

		echo "Running with parameters [$i]."

		cd "$OSYNC_DIR"
		PrepareLocalDirs

		FileA="FileA"
		FileB="FileB"

		echo "$FileA" > "$INITIATOR_DIR/$FileA"
		echo "$FileB" > "$TARGET_DIR/$FileB"

		# First run
		CONFLICT_BACKUP_MULTIPLE=true REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i $additionalParameters
		assertEquals "First deletion run with parameters [$i]." "0" $?

		echo "$FileA+" > "$TARGET_DIR/$FileA"
		echo "$FileB+" > "$INITIATOR_DIR/$FileB"

		# Second run
		CONFLICT_BACKUP_MULTIPLE=true REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i $additionalParameters
		assertEquals "First deletion run with parameters [$i]." "0" $?

		echo "$FileA-" > "$TARGET_DIR/$FileA"
		echo "$FileB-" > "$INITIATOR_DIR/$FileB"

		# Third run
		CONFLICT_BACKUP_MULTIPLE=true REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i $additionalParameters
		assertEquals "First deletion run with parameters [$i]." "0" $?

		echo "$FileA*" > "$TARGET_DIR/$FileA"
		echo "$FileB*" > "$INITIATOR_DIR/$FileB"

		# Fouth run
		CONFLICT_BACKUP_MULTIPLE=true REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i $additionalParameters
		assertEquals "First deletion run with parameters [$i]." "0" $?

		# This test may fail only on 31th December at 23:59 :)
		[ $(find "$INITIATOR_DIR/$OSYNC_BACKUP_DIR/" -type f -name "FileA.$(date '+%Y')*" | wc -l) -eq 3 ]
		assertEquals "3 Backup files are present in [$INITIATOR_DIR/$OSYNC_BACKUP_DIR/]." "0" $?

		[ $(find "$TARGET_DIR/$OSYNC_BACKUP_DIR/" -type f -name "FileB.$(date '+%Y')*" | wc -l) -eq 3 ]
		assertEquals "3 Backup files are present in [$TARGET_DIR/$OSYNC_BACKUP_DIR/]." "0" $?
	done

	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "CONFLICT_BACKUP_MULTIPLE" false
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "CONFLICT_BACKUP_MULTIPLE" false
}

function xtest_Locking () {
# local not running = resume
# remote same instance_id = resume
# remote different instance_id = stop
# remote dfiffent instance_id + FORCE_STRANGER_LOCK_RESUME = resume

	# Initiator lock present should always be resumed if pid does not run
	for i in "${osyncParameters[@]}"; do

		cd "$OSYNC_DIR"
		PrepareLocalDirs

		mkdir -p "$INITIATOR_DIR/$OSYNC_WORKDIR"
		echo 65536 > "$INITIATOR_DIR/$OSYNC_WORKDIR/lock"

		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "Should be able to resume when initiator has lock without running pid." "0" $?

		echo $$ > "$INITIATOR_DIR/$OSYNC_WORKDIR/lock"

		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "Should never be able to resume when initiator has lock with running pid." "1" $?
	done

	# Target lock present should be resumed if instance ID is the same as current one
	PrepareLocalDirs
	mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
	echo 65536@quicklocal > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

	REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE ${osyncParameters[$__quickLocal]}
	assertEquals "Should be able to resume locked target with same instance_id in quickLocal mode." "0" $?

	PrepareLocalDirs
	mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
	echo 65536@local > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

	REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE ${osyncParameters[$__confLocal]}
	assertEquals "Should be able to resume locked target with same instance_id in confLocal mode." "0" $?

	if [ "$LOCAL_OS" != "msys" ] && [ "$LOCAL_OS" != "Cygwin" ]; then
		PrepareLocalDirs
		mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
		echo 65536@quickremote > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE ${osyncParameters[$__quickRemote]}
		assertEquals "Should be able to resume locked target with same instance_id in quickRemote mode." "0" $?

		PrepareLocalDirs
		mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
		echo 65536@remote > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE ${osyncParameters[$__confRemote]}
		assertEquals "Should be able to resume locked target with same instance_id in confRemote mode." "0" $?
	fi

	# Remote Target lock present should not be resumed if instance ID is NOT the same as current one, local target lock is resumed
	PrepareLocalDirs
	mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
	echo 65536@bogusinstance > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

	REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE ${osyncParameters[$__quickLocal]}
	assertEquals "Should be able to resume locked local target with bogus instance id in quickLocal mode." "0" $?

	PrepareLocalDirs
	mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
	echo 65536@bogusinstance > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

	REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE ${osyncParameters[$__confLocal]}
	assertEquals "Should be able to resume locked local target with bogus instance_id in confLocal mode." "0" $?

	if [ "$LOCAL_OS" != "msys" ] && [ "$LOCAL_OS" != "Cygwin" ]; then
		PrepareLocalDirs
		mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
		echo 65536@bogusinstance > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE ${osyncParameters[$__quickRemote]}
		assertEquals "Should not be able to resume remote locked target with bogus instance_id in quickRemote mode." "1" $?

		PrepareLocalDirs
		mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
		echo 65536@bogusinstance > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE ${osyncParameters[$__confRemote]}
		assertEquals "Should not be able to resume remote locked target with bogus instance_id in confRemote mode." "1" $?
	fi

	# Target lock present should be resumed if instance ID is NOT the same as current one but FORCE_STRANGER_UNLOCK=yes

	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "FORCE_STRANGER_LOCK_RESUME" true
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "FORCE_STRANGER_LOCK_RESUME" true

	for i in "${osyncParameters[@]}"; do

		cd "$OSYNC_DIR"
		PrepareLocalDirs

		mkdir -p "$INITIATOR_DIR/$OSYNC_WORKDIR"
		echo 65536@bogusinstance > "$INITIATOR_DIR/$OSYNC_WORKDIR/lock"

		FORCE_STRANGER_UNLOCK=yes REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i
		assertEquals "Should be able to resume when target has lock with different instance id but FORCE_STRANGER_UNLOCK=yes." "0" $?
	done

	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "FORCE_STRANGER_LOCK_RESUME" false
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "FORCE_STRANGER_LOCK_RESUME" false
}

function xtest_ConflictDetetion () {
	# Tests compatible with v1.4+

	if [ $OSYNC_MIN_VERSION -lt 4 ]; then
		echo "Skipping conflict detection test because osync min version is $OSYNC_MIN_VERSION (must be 4 at least)."
		return 0
	fi

	for i in "${osyncParameters[@]}"; do

		cd "$OSYNC_DIR"
		PrepareLocalDirs

		FileA="some file"
		FileB="some other file"

		touch "$INITIATOR_DIR/$FileA"
		touch "$TARGET_DIR/$FileB"
		touch "$INITIATOR_DIR/$FileB"
		touch "$TARGET_DIR/$FileA"

		# Initializing treeList
		REMOTE_HOST_PING=$RHOST_PING _PARANOIA_DEBUG=no $OSYNC_EXECUTABLE $i --initialize
		assertEquals "Initialization run with parameters [$i]." "0" $?

		# Now modifying files on both sides

		echo "A" > "$INITIATOR_DIR/$FileA"
		echo "B" > "$TARGET_DIR/$FileB"
		echo "BB" > "$INITIATOR_DIR/$FileB"
		echo "AA" > "$TARGET_DIR/$FileA"

		# Now run should return conflicts

		REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE $i --log-conflicts > "$FAKEROOT/output2.log" 2>&1
		assertEquals "Second run that should detect conflicts with parameters [$i]." "0" $?

		cat "$FAKEROOT/output2.log"

		#WIP TODO change output.log from output2.log for debug reasons
		grep "$INITIATOR_DIR/$FileA << >> $TARGET_DIR/$FileA" "$FAKEROOT/output2.log" 
		assertEquals "FileA conflict detect with parameters [$i]." "0" $?

		grep "$INITIATOR_DIR/$FileB << >> $TARGET_DIR/$FileB" "$FAKEROOT/output2.log"
		assertEquals "FileB conflict detect with parameters [$i]." "0" $?

		#TODO: Missing test for conflict prevalance (once we have FORCE_CONFLICT_PREVALANCE
	done
	return 0
}

function xtest_WaitForTaskCompletion () {
	local pids

	# Tests compatible with v1.1 syntax

	# These tests aren't really effective because in any case, output from WaitFor functions is always 0, which was a bad behavior in v1.1

	if [ "$OSYNC_MIN_VERSION" == "1" ]; then
		echo "Using v1.1 WaitForTaskCompletion test"

		# Needed in order to get PROCESS_test_CMD value
		InitLocalOSSettings

		# Standard wait
		sleep 2 &
		pid=$!
		WaitForTaskCompletion $pid 0 0 ${FUNCNAME[0]}
		assertEquals "WaitForTaskCompletion v1.1 test 1" "0" $?

		# Standard wait with warning
		sleep 5 &
		WaitForTaskCompletion $! 3 0 ${FUNCNAME[0]}
		assertEquals "WaitForTaskCompletion v1.1 test 2" "0" $?

		# Pid is killed
		sleep 5 &
		WaitForTaskCompletion $! 0 2 ${FUNCNAME[0]}
		assertEquals "WaitForTaskCompletion v1.1 test 3" "1" $?

		# Standard wait
		sleep 2 &
		WaitForCompletion $! 0 0 ${FUNCNAME[0]}
		assertEquals "WaitForCompletion test 1" "0" $?

		# Standard wait with warning
		sleep 5 &
		WaitForCompletion $! 3 0 ${FUNCNAME[0]}
		assertEquals "WaitForCompletion test 2" "0" $?

		# Pid is killed
		sleep 5 &
		WaitForCompletion $! 0 2 ${FUNCNAME[0]}
		assertEquals "WaitForCompletion test 3" "1" $?

		return 0
	fi

	# Tests if wait for task completion works correctly with v1.2+

	# Standard wait
	sleep 1 &
	pids="$!"
	sleep 2 &
	pids="$pids;$!"
	WaitForTaskCompletion $pids 0 0 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 1" "0" $?

	# Standard wait with warning
	sleep 2 &
	pids="$!"
	sleep 5 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 3 0 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 2" "0" $?

	# Both pids are killed
	sleep 5 &
	pids="$!"
	sleep 5 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 0 2 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 3" "2" $?

	# One of two pids are killed
	sleep 2 &
	pids="$!"
	sleep 10 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 0 3 $SLEEP_TIME $KEEP_LOGGING true true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 4" "1" $?

	# Count since script begin, the following should output two warnings and both pids should get killed
	sleep 20 &
	pids="$!"
	sleep 20 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 3 5 $SLEEP_TIME $KEEP_LOGGING false true false ${FUNCNAME[0]}
	assertEquals "WaitForTaskCompletion test 5" "2" $?
}

function xtest_ParallelExec () {
	if [ "$OSYNC_MIN_VERSION" == "1" ]; then
		echo "Skipping ParallelExec test because osync v1.1 ofunctions don't have this function."
		return 0
	fi

	local cmd

	# Test if parallelExec works correctly in array mode

	cmd="sleep 2;sleep 2;sleep 2;sleep 2"
	ParallelExec 4 "$cmd"
	assertEquals "ParallelExec test 1" "0" $?

	cmd="sleep 2;du /none;sleep 2"
	ParallelExec 2 "$cmd"
	assertEquals "ParallelExec test 2" "1" $?

	cmd="sleep 4;du /none;sleep 3;du /none;sleep 2"
	ParallelExec 3 "$cmd"
	assertEquals "ParallelExec test 3" "2" $?

	# Test if parallelExec works correctly in file mode

	echo "sleep 2" > "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	ParallelExec 4 "$TMP_FILE" true
	assertEquals "ParallelExec test 4" "0" $?

	echo "sleep 2" > "$TMP_FILE"
	echo "du /nome" >> "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	ParallelExec 2 "$TMP_FILE" true
	assertEquals "ParallelExec test 5" "1" $?

	echo "sleep 4" > "$TMP_FILE"
	echo "du /none" >> "$TMP_FILE"
	echo "sleep 3" >> "$TMP_FILE"
	echo "du /none" >> "$TMP_FILE"
	echo "sleep 2" >> "$TMP_FILE"
	ParallelExec 3 "$TMP_FILE" true
	assertEquals "ParallelExec test 6" "2" $?

	#function ParallelExec $numberOfProcesses $commandsArg $readFromFile $softTime $HardTime $sleepTime $keepLogging $counting $Spinner $noError $callerName
	# Test if parallelExec works correctly in array mode with full  time control

	cmd="sleep 5;sleep 5;sleep 5;sleep 5;sleep 5"
	ParallelExec 4 "$cmd" false 1 0 .05 3600 true true false ${FUNCNAME[0]}
	assertEquals "ParallelExec full test 1" "0" $?

	cmd="sleep 2;du /none;sleep 2;sleep 2;sleep 4"
	ParallelExec 2 "$cmd" false 0 0 .1 2 true false false ${FUNCNAME[0]}
	assertEquals "ParallelExec full test 2" "1" $?

	cmd="sleep 4;du /none;sleep 3;du /none;sleep 2"
	ParallelExec 3 "$cmd" false 1 2 .05 7000 true true false ${FUNCNAME[0]}
	assertNotEquals "ParallelExec full test 3" "0" $?
}

function xtest_timedExecution () {
	local arguments

	# Clever usage of indexes and exit codes
	# osync exits with 0 when no problem detected
	# exits with 1 when error detected (triggered by reaching HARD_MAX_EXEC_TIME)
	# exits with 2 when warning only detected (triggered by reaching SOFT_MAX_EXEC_TIME)

	softTimes=()
	softTimes[0]=7200 	# original values (to be executed at last in order to leave config file in original state)
	hardTimes[0]=10600
	softTimes[1]=0
	hardTimes[1]=3
	softTimes[2]=2
	hardTimes[2]=10600

	for x in 2 1 0; do

		SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "SOFT_MAX_EXEC_TIME" ${softTimes[$x]}
		SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "HARD_MAX_EXEC_TIME" ${hardTimes[$x]}
		SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "SOFT_MAX_EXEC_TIME" ${softTimes[$x]}
		SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "HARD_MAX_EXEC_TIME" ${hardTimes[$x]}

		for i in "${osyncParameters[@]}"; do
			cd "$OSYNC_DIR"
			PrepareLocalDirs

			echo "Test with args [$i $arguments]."
			SLEEP_TIME=1 SOFT_MAX_EXEC_TIME=${softTimes[$x]} HARD_MAX_EXEC_TIME=${hardTimes[$x]} $OSYNC_EXECUTABLE $i
			retval=$?
			if [ "$OSYNC_MIN_VERSION" -gt 1 ]; then
				assertEquals "Timed Execution test with timed SOFT_MAX_EXEC_TIME=${softTimes[$x]} and HARD_MAX_EXEC_TIME=${hardTimes[$x]}." $x $retval
			else
				# osync v1.1 had different exit codes, 240 was warning, anything else than 0 was error
				if [ $x -eq 2 ]; then
					assertEquals "Timed Execution test with timed SOFT_MAX_EXEC_TIME=${softTimes[$x]} and HARD_MAX_EXEC_TIME=${hardTimes[$x]}." 240 $retval
				elif [ $x -eq 1 ]; then
					assertNotEquals "Timed Execution test with timed SOFT_MAX_EXEC_TIME=${softTimes[$x]} and HARD_MAX_EXEC_TIME=${hardTimes[$x]}." 0 $retval
				else
					assertEquals "Timed Execution test with timed SOFT_MAX_EXEC_TIME=${softTimes[$x]} and HARD_MAX_EXEC_TIME=${hardTimes[$x]}." 0 $retval
				fi
			fi
		done
	done
}

function xtest_UpgradeConfRun () {
	if [ "$OSYNC_MIN_VERSION" == "1" ]; then
		echo "Skipping Upgrade script test because no further dev will happen on this for v1.1"
		return 0
	fi

	# Basic return code tests. Need to go deep into file presence testing
	cd "$OSYNC_DIR"
	PrepareLocalDirs

	# Make a security copy of the old config file
	cp "$CONF_DIR/$OLD_CONF" "$CONF_DIR/$TMP_OLD_CONF"

	./$OSYNC_UPGRADE "$CONF_DIR/$TMP_OLD_CONF"
	assertEquals "Conf file upgrade" "0" $?

	# Update remote conf files with SSH port
	sed -i.tmp 's#ssh://.*@localhost:[0-9]*/${HOME}/osync-tests/target#ssh://'$REMOTE_USER'@localhost:'$SSH_PORT'/${HOME}/osync-tests/target#' "$CONF_DIR/$TMP_OLD_CONF"

	$OSYNC_EXECUTABLE "$CONF_DIR/$TMP_OLD_CONF"
	assertEquals "Upgraded conf file execution test" "0" $?

	rm -f "$CONF_DIR/$TMP_OLD_CONF"
	rm -f "$CONF_DIR/$TMP_OLD_CONF.save"
}

function xtest_DaemonMode () {
	if [ "$LOCAL_OS" == "WinNT10" ] || [ "$LOCAL_OS" == "msys" ] || [ "$LOCAL_OS" == "Cygwin" ]; then
		echo "Skipping daemon mode test as [$LOCAL_OS] does not have inotifywait support."
		return 0
	fi

	for i in "${osyncDaemonParameters[@]}"; do

		cd "$OSYNC_DIR"
		PrepareLocalDirs

		FileA="FileA"
		FileB="FileB"
		FileC="FileC"

		touch "$INITIATOR_DIR/$FileA"
		touch "$TARGET_DIR/$FileB"

		$OSYNC_EXECUTABLE "$CONF_DIR/$LOCAL_CONF" --on-changes &
		pid=$!

		#TODO: Lower that value when dispatecher is written
		# Trivial value of 2xMIN_WAIT from config files
		echo "Sleeping for 120s"
		sleep 120

		[ -f "$TARGET_DIR/$FileB" ]
		assertEquals "File [$TARGET_DIR/$FileB] should be synced." "0" $?
		[ -f "$INITIATOR_DIR/$FileA" ]
		assertEquals "File [$INITIATOR_DIR/$FileB] should be synced." "0" $?

		touch "$INITIATOR_DIR/$FileC"
		rm -f "$INITIATOR_DIR/$FileA"
		rm -f "$TARGET_DIR/$FileB"

		echo "Sleeping for 120s"
		sleep 120

		[ ! -f "$TARGET_DIR/$FileB" ]
		assertEquals "File [$TARGET_DIR/$FileB] should be deleted." "0" $?
		[ ! -f "$INITIATOR_DIR/$FileA" ]
		assertEquals "File [$INITIATOR_DIR/$FileA] should be deleted." "0" $?

		[ -f "$TARGET_DIR/$OSYNC_DELETE_DIR/$FileA" ]
		assertEquals "File [$TARGET_DIR/$OSYNC_DELETE_DIR/$FileA] should be in soft deletion dir." "0" $?
		[ -f "$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileB" ]
		assertEquals "File [$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileB] should be in soft deletion dir." "0" $?

		[ -f "$TARGET_DIR/$FileC" ]
		assertEquals "File [$TARGET_DIR/$FileC] should be synced." "0" $?

		kill $pid
	done

}

function xtest_NoRemoteAccessTest () {
	RemoveSSH

	cd "$OSYNC_DIR"
	PrepareLocalDirs

	REMOTE_HOST_PING=$RHOST_PING $OSYNC_EXECUTABLE ${osyncParameters[$__confLocal]}
	assertEquals "Basic local test without remote access." "0" $?
}

. "$TESTS_DIR/shunit2/shunit2"
