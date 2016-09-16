#!/usr/bin/env bash

# osync test suite 2016091603
# TODO: Add big fileset tests (eg: drupal 8 ?), add soft deletion tests, add deletion propagation test, add file attrib test


# 4 tests:
# quicklocal
# quickremote
# conflocal
# confremote

# for each test:
# files with spaces, subdirs
# largefileset
# exclusions
# conflict resolution master, file attributes master
# conflict resolution slave, file attributes slave
# deletion propagation
# softdelete deleted
# softdelete backup
# lock checks

TEST_DISK=/dev/vda1
LARGE_FILESET_URL="http://ftp.drupal.org/files/projects/drupal-8.1.9.tar.gz"

OSYNC_DIR="$(pwd)"
OSYNC_DIR=${OSYNC_DIR%%/dev*}
DEV_DIR="$OSYNC_DIR/dev"
TESTS_DIR="$DEV_DIR/tests"

OSYNC_EXECUTABLE="osync.sh"
TMP_FILE="$DEV_DIR/tmp"


if [ "$TRAVIS_RUN" == true ]; then
	echo "Running with travis settings"
	CONF_DIR="$TESTS_DIR/conf-travis"
	SSH_PORT=22
else
	echo "Running with local settings"
	CONF_DIR="$TESTS_DIR/conf-local"
	SSH_PORT=49999
fi

INITIATOR_DIR="${HOME}/osync/initiator"
TARGET_DIR="${HOME}/osync/target"
OSYNC_WORKDIR=".osync_workdir"
OSYNC_STATE_DIR="$OSYNC_WORKDIR/state"

# Setup an array with all function modes
declare -Ag osyncParameters

osyncParameters[quicklocal]="--initiator=$INITIATOR_DIR --target=$TARGET_DIR"
osyncParameters[quickRemote]="--initiator=$INITIATOR_DIR --target=ssh://localhost:$SSH_PORT/$TARGET_DIR --rsakey=${HOME}/.ssh/id_rsa_local"
#osyncParameters[confLocal]="$CONF_DIR/local.conf"
#osyncParameters[confRemote]="$CONF_DIR/remote.conf"
#osyncParameters[daemonlocal]="$CONF_DIR/local.conf --on-changes"
#osyncParameters[daemonlocal]="$CONF_DIR/remote.conf --on-changes"

function SetStableToYes () {
	if grep "^IS_STABLE=YES" "$OSYNC_DIR/$OSYNC_EXECUTABLE" > /dev/null; then
		IS_STABLE=yes
	else
		IS_STABLE=no
		sed -i.tmp 's/^IS_STABLE=no/IS_STABLE=yes/' "$OSYNC_DIR/$OSYNC_EXECUTABLE"
		assertEquals "Set stable to yes" "0" $?
	fi
}

function SetStableToOrigin () {
	if [ "$IS_STABLE" == "no" ]; then
		sed -i.tmp 's/^IS_STABLE=yes/IS_STABLE=no/' "$OSYNC_DIR/$OSYNC_EXECUTABLE"
		assertEquals "Set stable to origin value" "0" $?
	fi
}

function SetupSSH {
	echo -e  'y\n'| ssh-keygen -t rsa -b 2048 -N "" -f "${HOME}/.ssh/id_rsa_local"
	cat "${HOME}/.ssh/id_rsa_local.pub" >> "${HOME}/.ssh/authorized_keys"
	chmod 600 "${HOME}/.ssh/authorized_keys"

	# Add localhost to known hosts so self connect works
	if [ -z $(ssh-keygen -F localhost) ]; then
		ssh-keyscan -H localhost >> ~/.ssh/known_hosts
	fi
}

function DownloadLargeFileSet() {
	local destinationPath="${1}"

	cd "$OSYNC_DIR"
	wget -q "$LARGE_FILESET_URL" > /dev/null
	assertEquals "Download [$LARGE_FILESET_URL]." "0" $?

	tar xvf $(basename "$LARGE_FILESET_URL") -C "$destinationPath" > /dev/null
	assertEquals "Extract $(basename $LARGE_FILESET_URL)" "0" $?
}

function CreateOldFile () {
	local filePath="${1}"

	debugfs -w -R 'set_inode_field "$filePath" ctime 201001010101' "$TEST_DISK"
	assertEquals "CreateOldFile [$filePath]" "0" $?

	echo > /proc/sys/vm/drop_caches
	assertEquals "Drop caches" "0" $?
}

function PrepareLocalDirs () {
	# Remote dirs are the same as local dirs, so no problem here
	if [ -d "$INITIATOR_DIR" ]; then
		rm -rf "$INITIATOR_DIR"
	fi
	mkdir -p "$INITIATOR_DIR"

	if [ -d "$TARGET_DIR" ]; then
		rm -rf "$TARGET_DIR"
	fi
	mkdir -p "$TARGET_DIR"
}

function oneTimeSetUp () {
	source "$DEV_DIR/ofunctions.sh"
	SetupSSH
}

function oneTimeTearDown () {
	SetStableToOrigin
}

function test_Merge () {
	cd "$DEV_DIR"
	./merge.sh
	assertEquals "Merging code" "0" $?
	SetStableToYes
}

function test_LargeFileSet () {
	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"

		PrepareLocalDirs
		DownloadLargeFileSet "$INITIATOR_DIR"

		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "LargeFileSet test with parameters [$i]." "0" $?
	done
}

function test_Exclusions () {
	local numberOfPHPFiles
	local numberOfExcludedFiles
	local numberOfInitiatorFiles
	local numberOfTargetFiles

	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"

		PrepareLocalDirs
		DownloadLargeFileSet "$INITIATOR_DIR"

		numberOfPHPFiles=$(find "$INITIATOR_DIR" ! -wholename "$INITIATOR_DIR/$OSYNC_WORKDIR*" -name "*.php" | wc -l)

		RSYNC_EXCLUDE_PATTERN="*.php" ./$OSYNC_EXECUTABLE $i
		assertEquals "Exclusions with parameters [$i]." "0" $?

		#WIP Add real exclusion tests here
		numberOfInitiatorFiles=$(find "$INITIATOR_DIR" ! -wholename "$INITIATOR_DIR/$OSYNC_WORKDIR*" | wc -l)
		numberOfTargetFiles=$(find "$TARGET_DIR" ! -wholename "$TARGET_DIR/$OSYNC_WORKDIR*" | wc -l)
		numberOfExcludedFiles=$((numberOfInitiatorFiles-numberOfTargetFiles))

		assertEquals "Number of php files: $numberOfPHPFiles - Number of excluded files: $numberOfExcludedFiles" $numberOfPHPFiles $numberOfExcludedFiles
	done
}

function test_osync_quicksync_local () {
	cd "$OSYNC_DIR"
	./$OSYNC_EXECUTABLE --initiator="$INITIATOR_DIR" --target="$TARGET_DIR"
	assertEquals "Return code" "0" $?

	[ -d "$INITIATOR_DIR/$OSYNC_STATE_DIR" ]
	assertEquals "Initiator state dir exists" "0" $?

	[ -d "$TARGET_DIR/$OSYNC_STATE_DIR" ]
	assertEquals "Target state dir exists" "0" $?
}


function test_osync_quicksync_remote () {
	cd "$OSYNC_DIR"
	# Disable remote host ping because Travis can't ping
	REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE --initiator="$INITIATOR_DIR" --target="ssh://localhost:$SSH_PORT/$TARGET_DIR" --rsakey="${HOME}/.ssh/id_rsa_local"
	assertEquals "Return code" "0" $?

	[ -d "$INITIATOR_DIR/$OSYNC_STATE_DIR" ]
	assertEquals "Initiator state dir exists" "0" $?

	[ -d "$TARGET_DIR/$OSYNC_STATE_DIR" ]
	assertEquals "Target state dir exists" "0" $?
}

function test_WaitForTaskCompletion () {
	local pids

	# Tests if wait for task completion works correctly

	# Standard wait
	sleep 1 &
	pids="$!"
	sleep 2 &
	pids="$pids;$!"
	WaitForTaskCompletion $pids 0 0 ${FUNCNAME[0]} true 0
	assertEquals "WaitForTaskCompletion test 1" "0" $?

	# Standard wait with warning
	sleep 2 &
	pids="$!"
	sleep 5 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 3 0 ${FUNCNAME[0]} true 0
	assertEquals "WaitForTaskCompletion test 2" "0" $?

	# Both pids are killed
	sleep 5 &
	pids="$!"
	sleep 5 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 0 2 ${FUNCNAME[0]} true 0
	assertEquals "WaitForTaskCompletion test 3" "2" $?

	# One of two pids are killed
	sleep 2 &
	pids="$!"
	sleep 10 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 0 3 ${FUNCNAME[0]} true 0
	assertEquals "WaitForTaskCompletion test 4" "1" $?

	# Count since script begin, the following should output two warnings and both pids should get killed
	sleep 20 &
	pids="$!"
	sleep 20 &
	pids="$pids;$!"

	WaitForTaskCompletion $pids 3 5 ${FUNCNAME[0]} false 0
	assertEquals "WaitForTaskCompletion test 5" "2" $?
}

function test_ParallelExec () {
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

}

. "$TESTS_DIR/shunit2/shunit2"
