#!/usr/bin/env bash

# osync test suite 2016111701

# 4 tests:
# quicklocal
# quickremote
# conflocal
# confremote

# for each test:
# 	files with spaces, subdirs
# 	largefileset (...large ?)
# 	exclusions
# 	conflict resolution initiator with backups / multiple backups
# 	conflict resolution target with backups / multiple backups
# 	deletion propagation, failed deletion repropagation, skip deletion
# 	replica lock checks
#	file attribute tests
# 	local / remote locking resume tests

# function test
# WaitForTaskCompletion
# ParallelExec

# daemon mode tests
#TODO: daemon mode tests

#TODO: enable teardown after tests

LARGE_FILESET_URL="http://ftp.drupal.org/files/projects/drupal-8.1.9.tar.gz"

OSYNC_DIR="$(pwd)"
OSYNC_DIR=${OSYNC_DIR%%/dev*}
DEV_DIR="$OSYNC_DIR/dev"
TESTS_DIR="$DEV_DIR/tests"

LOCAL_CONF="local.conf"
REMOTE_CONF="remote.conf"
OLD_CONF="old.conf"
TMP_OLD_CONF="tmp.old.conf"

OSYNC_EXECUTABLE="osync.sh"
OSYNC_DEV_EXECUTABLE="dev/n_osync.sh"
OSYNC_UPGRADE="upgrade-v1.0x-v1.2x.sh"
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

# Setup an array with all function modes
declare -Ag osyncParameters

osyncParameters[quickLocal]="--initiator=$INITIATOR_DIR --target=$TARGET_DIR --instance-id=quicklocal"
osyncParameters[quickRemote]="--initiator=$INITIATOR_DIR --target=ssh://localhost:$SSH_PORT/$TARGET_DIR --rsakey=${HOME}/.ssh/id_rsa_local --instance-id=quickremote"
osyncParameters[confLocal]="$CONF_DIR/$LOCAL_CONF"
osyncParameters[confRemote]="$CONF_DIR/$REMOTE_CONF"
#osyncParameters[daemonlocal]="$CONF_DIR/$LOCAL_CONF --on-changes"
#osyncParameters[daemonlocal]="$CONF_DIR/$REMOTE_CONF --on-changes"

function GetConfFileValue () {
	local file="${1}"
	local name="${2}"
	local value

	value=$(grep "^$name=" "$file")
	if [ $? == 0 ]; then
		value="${value##*=}"
		echo "$value"
	else
		assertEquals "$name does not exist in [$file." "1" "0"
	fi
}

function SetConfFileValue () {
	local file="${1}"
	local name="${2}"
	local value="${3}"

	if grep "^$name=" "$file" > /dev/null; then
		sed -i.tmp "s/^$name=.*/$name=$value/" "$file"
		assertEquals "Set $name to [$value]." "0" $?
	else
		assertEquals "$name does not exist in [$file]." "1" "0"
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

	tar xvf "$(basename $LARGE_FILESET_URL)" -C "$destinationPath" > /dev/null
	assertEquals "Extract $(basename $LARGE_FILESET_URL)" "0" $?

	rm -f "$(basename $LARGE_FILESET_URL)"
}

function CreateOldFile () {
	local drive
	local filePath="${1}"

	touch "$filePath"
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

	# Get osync version
	OSYNC_VERSION=$(GetConfFileValue "$OSYNC_DIR/$OSYNC_DEV_EXECUTABLE" "PROGRAM_VERSION")
	OSYNC_VERSION="${OSYNC_VERSION##*=}"
	OSYNC_MIN_VERSION="${OSYNC_VERSION:2:1}"

	OSYNC_IS_STABLE=$(GetConfFileValue "$OSYNC_DIR/$OSYNC_DEV_EXECUTABLE" "IS_STABLE")

	echo "Running with $OSYNC_VERSION ($OSYNC_MIN_VERSION) STABLE=$OSYNC_IS_STABLE"
}

function oneTimeTearDown () {
	# Set osync version stable flag back to origin
	SetConfFileValue "$OSYNC_DIR/$OSYNC_EXECUTABLE" "IS_STABLE" "$OSYNC_IS_STABLE"

	#TODO: uncomment this when dev is done
	#rm -rf "$OSYNC_TESTS_DIR"
}

function setUp () {
        rm -rf "$INITIATOR_DIR"
        rm -rf "$TARGET_DIR"
}

# This test has to be done everytime in order for osync executable to be fresh
function test_Merge () {
	cd "$DEV_DIR"
	./merge.sh
	assertEquals "Merging code" "0" $?

	# Set osync version to stable while testing to avoid warning message
	SetConfFileValue "$OSYNC_DIR/$OSYNC_EXECUTABLE" "IS_STABLE" "yes"
}

function test_LargeFileSet () {
	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"

		PrepareLocalDirs
		DownloadLargeFileSet "$INITIATOR_DIR"

		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "LargeFileSet test with parameters [$i]." "0" $?

		[ -d "$INITIATOR_DIR/$OSYNC_STATE_DIR" ]
		assertEquals "Initiator state dir exists" "0" $?

		[ -d "$TARGET_DIR/$OSYNC_STATE_DIR" ]
		assertEquals "Target state dir exists" "0" $?
	done
}

function test_Exclusions () {
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

		REMOTE_HOST_PING=no RSYNC_EXCLUDE_PATTERN="*.php" ./$OSYNC_EXECUTABLE $i
		assertEquals "Exclusions with parameters [$i]." "0" $?

		#WIP Add exclusion from file tests here
		numberOfInitiatorFiles=$(find "$INITIATOR_DIR" ! -wholename "$INITIATOR_DIR/$OSYNC_WORKDIR*" | wc -l)
		numberOfTargetFiles=$(find "$TARGET_DIR" ! -wholename "$TARGET_DIR/$OSYNC_WORKDIR*" | wc -l)
		numberOfExcludedFiles=$((numberOfInitiatorFiles-numberOfTargetFiles))

		assertEquals "Number of php files: $numberOfPHPFiles - Number of excluded files: $numberOfExcludedFiles" $numberOfPHPFiles $numberOfExcludedFiles
	done
}

function test_Deletetion () {
	local iFile1="$INITIATOR_DIR/ific"
	local iFile2="$INITIATOR_DIR/ifoc"
	local tFile1="$TARGET_DIR/tfic"
	local tFile2="$TARGET_DIR/tfoc"


	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"

		PrepareLocalDirs
		touch "$iFile1"
		touch "$iFile2"
		touch "$tFile1"
		touch "$tFile2"

		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "First deletion run with parameters [$i]." "0" $?

		rm -f "$iFile1"
		rm -f "$tFile1"

		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
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

function test_deletion_failure () {

	if [ "$TRAVIS_RUN" == true ]; then
		echo "Skipping deletionFailure tests as travis does not support chattr."
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

		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "First deletion run with parameters [$i]." "0" $?

		rm -f "$INITIATOR_DIR/$FileA"
		rm -f "$TARGET_DIR/$FileB"

		# Prevent files from being deleted
		chattr +i "$TARGET_DIR/$FileA"
		chattr +i "$INITIATOR_DIR/$FileB"

		# This shuold fail with exitcode 1
		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "Second deletion run with parameters [$i]." "1" $?

		[ -f "$TARGET_DIR/$FileA" ]
		assertEquals "File [$TARGET_DIR/$FileA] is still present in deletion dir." "0" $?
		[ ! -f "$TARGET_DIR/$OSYNC_DELETE_DIR/$FileA" ]
		assertEquals "File [$TARGET_DIR/$OSYNC_DELETE_DIR/$FileA] is not present in deletion dir." "0" $?

		[ -f "$INITIATOR_DIR/$FileB" ]
		assertEquals "File [$INITIATOR_DIR/$FileB] is still present in deletion dir." "0" $?
		[ ! -f "$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileB" ]
		assertEquals "File [$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileB] is not present in deletion dir." "0" $?

		# Allow files from being deleted
		chattr -i "$TARGET_DIR/$FileA"
		chattr -i "$INITIATOR_DIR/$FileB"

		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "Third deletion run with parameters [$i]." "0" $?

		[ ! -f "$TARGET_DIR/$FileA" ]
		assertEquals "File [$TARGET_DIR/$FileA] is still present in deletion dir." "0" $?
		[ -f "$TARGET_DIR/$OSYNC_DELETE_DIR/$FileA" ]
		assertEquals "File [$TARGET_DIR/$OSYNC_DELETE_DIR/$FileA] is not present in deletion dir." "0" $?

		[ ! -f "$INITIATOR_DIR/$FileB" ]
		assertEquals "File [$INITIATOR_DIR/$FileB] is still present in deletion dir." "0" $?
		[ -f "$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileB" ]
		assertEquals "File [$INITIATOR_DIR/$OSYNC_DELETE_DIR/$FileB] is not present in deletion dir." "0" $?
	done
}

function test_skip_deletion () {
	local skipDeletionLocal
	local skipDeletionRemote
	local modes

	if [ "$OSYNC_MIN_VERSION" == "1" ]; then
		echo "Skipping SkipDeletion test because it wasn't implemented in osync v1.1."
		return 0
	fi

	# Keep original values
	skipDeletionLocal=$(GetConfFileValue "$CONF_DIR/$LOCAL_CONF" "SKIP_DELETION")
	skipDeletionRemote=$(GetConfFileValue "$CONF_DIR/$REMOTE_CONF" "SKIP_DELETION")

	modes=('initiator' 'target' 'initiator,target')

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
			REMOTE_HOST_PING=no SKIP_DELETION="$mode" ./$OSYNC_EXECUTABLE $i
			assertEquals "First deletion run with parameters [$i]." "0" $?

			rm -f "$INITIATOR_DIR/$FileA"
			rm -f "$TARGET_DIR/$FileB"

			# Second run
			REMOTE_HOST_PING=no SKIP_DELETION="$mode" ./$OSYNC_EXECUTABLE $i
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
	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "SKIP_DELETION" "$skipDeletionLocal"
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "SKIP_DELETION" "$skipDeletionRemote"
}

function test_softdeletion_cleanup () {
	declare -A files

	files[deletedFileInitiator]="$INITIATOR_DIR/$OSYNC_DELETE_DIR/someDeletedFileInitiator"
	files[deletedFileTarget]="$TARGET_DIR/$OSYNC_DELETE_DIR/someDeletedFileTarget"
	files[backedUpFileInitiator]="$INITIATOR_DIR/$OSYNC_BACKUP_DIR/someBackedUpFileInitiator"
	files[backedUpFileTarget]="$TARGET_DIR/$OSYNC_BACKUP_DIR/someBackedUpFileTarget"

	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"
		PrepareLocalDirs

		# First run
		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "First deletion run with parameters [$i]." "0" $?

		# Get current drive
		drive=$(df "$OSYNC_DIR" | tail -1 | awk '{print $1}')

		# Create some deleted & backed up files, some new and some old
		for file in "${files[@]}"; do
			# Create directories first if they do not exist (deletion dir is created by osync, backup dir is created by rsync only when needed)
			if [ ! -d "$(dirname $file)" ]; then
				mkdir --parents "$(dirname $file)"
			fi

			touch "$file.new"

			if [ "$TRAVIS_RUN" != true ]; then
				CreateOldFile "$file.old"
			else
				echo "Skipping changing ctime on file because travis does not support debugfs"
			fi
		done

		# Second run
		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i

		# Check file presence
		for file in "${files[@]}"; do
			[ -f "$file.new" ]
			assertEquals "New softdeleted / backed up file [$file.new] exists." "0" $?

			if [ "$TRAVIS_RUN" != true ]; then
				[ ! -f "$file.old" ]
				assertEquals "Old softdeleted / backed up file [$file.old] is deleted permanently." "1" $?
			else
				[ ! -f "$file.old" ]
				assertEquals "Old softdeleted / backed up file [$file.old] is deleted permanently." "0" $?
			fi
		done
	done

}

function test_FileAttributePropagation () {

	if [ "$TRAVIS_RUN" == true ]; then
		echo "Skipping FileAttributePropagation tests as travis does not support getfacl / setfacl."
		return 0
	fi

	for i in "${osyncParameters[@]}"; do
		cd "$OSYNC_DIR"
		PrepareLocalDirs

		DirA="dir a"
		DirB="dir b"

		mkdir "$INITIATOR_DIR/$DirA"
		mkdir "$TARGET_DIR/$DirB"

		FileA="$DirA/FileA"
		FileB="$DirB/FileB"

		touch "$INITIATOR_DIR/$FileA"
		touch "$TARGET_DIR/$FileB"

		# First run
		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "First deletion run with parameters [$i]." "0" $?

		sleep 1

		getfacl -p "$INITIATOR_DIR/$FileA" | grep "other::r--" > /dev/null
		assertEquals "Check getting ACL on initiator." "0" $?

		getfacl -p "$TARGET_DIR/$FileB" | grep "other::r--" > /dev/null
		assertEquals "Check getting ACL on target." "0" $?

		setfacl -m o:r-x "$INITIATOR_DIR/$FileA"
		assertEquals "Set ACL on initiator" "0" $?
		setfacl -m o:-w- "$TARGET_DIR/$FileB"
		assertEquals "Set ACL on target" "0" $?

		# Second run
		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "First deletion run with parameters [$i]." "0" $?

		getfacl -p "$TARGET_DIR/$FileA" | grep "other::r-x" > /dev/null
		assertEquals "ACLs matched original value on target." "0" $?

		getfacl -p "$INITIATOR_DIR/$FileB" | grep "other::-w-" > /dev/null
		assertEquals "ACLs matched original value on initiator." "0" $?

		getfacl -p "$TARGET_DIR/$FileA"
		getfacl -p "$INITIATOR_DIR/$FileB"
	done
}

function test_ConflictBackups () {
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
		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "First deletion run with parameters [$i]." "0" $?

		echo "$FileA+" > "$TARGET_DIR/$FileA"
		echo "$FileB+" > "$INITIATOR_DIR/$FileB"

		# Second run
		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "First deletion run with parameters [$i]." "0" $?

		[ -f "$INITIATOR_DIR/$OSYNC_BACKUP_DIR/$FileA" ]
		assertEquals "Backup file is present in [$INITIATOR_DIR/$OSYNC_BACKUP_DIR/$FileA]." "0" $?

		[ -f "$TARGET_DIR/$OSYNC_BACKUP_DIR/$FileB" ]
		assertEquals "Backup file is present in [$TARGET_DIR/$OSYNC_BACKUP_DIR/$FileB]." "0" $?
	done
}

function test_MultipleConflictBackups () {
	local conflictBackupMultipleLocal
	local conflictBackupMultipleRemote

	local additionalParameters

	# modify config files
	conflictBackupMultipleLocal=$(GetConfFileValue "$CONF_DIR/$LOCAL_CONF" "CONFLICT_BACKUP_MULTIPLE")
	conflictBackupMultipleRemote=$(GetConfFileValue "$CONF_DIR/$REMOTE_CONF" "CONFLICT_BACKUP_MULTIPLE")

	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "CONFLICT_BACKUP_MULTIPLE" "yes"
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "CONFLICT_BACKUP_MULTIPLE" "yes"

	if [ "$OSYNC_MIN_VERSION" != "1" ]; then
		additionalParameters="--errors-only --summary --no-prefix"
	fi

	for i in "${osyncParameters[@]}"; do

		cd "$OSYNC_DIR"
		PrepareLocalDirs

		FileA="FileA"
		FileB="FileB"

		echo "$FileA" > "$INITIATOR_DIR/$FileA"
		echo "$FileB" > "$TARGET_DIR/$FileB"

		# First run
		CONFLICT_BACKUP_MULTIPLE=yes REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i $additionalParameters
		assertEquals "First deletion run with parameters [$i]." "0" $?

		echo "$FileA+" > "$TARGET_DIR/$FileA"
		echo "$FileB+" > "$INITIATOR_DIR/$FileB"

		# Second run
		CONFLICT_BACKUP_MULTIPLE=yes REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i $additionalParameters
		assertEquals "First deletion run with parameters [$i]." "0" $?

		echo "$FileA-" > "$TARGET_DIR/$FileA"
		echo "$FileB-" > "$INITIATOR_DIR/$FileB"

		# Third run
		CONFLICT_BACKUP_MULTIPLE=yes REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i $additionalParameters
		assertEquals "First deletion run with parameters [$i]." "0" $?

		echo "$FileA*" > "$TARGET_DIR/$FileA"
		echo "$FileB*" > "$INITIATOR_DIR/$FileB"

		# Fouth run
		CONFLICT_BACKUP_MULTIPLE=yes REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i $additionalParameters
		assertEquals "First deletion run with parameters [$i]." "0" $?

		# This test may fail only on 31th December at 23:59 :)
		[ $(find "$INITIATOR_DIR/$OSYNC_BACKUP_DIR/" -type f -name "FileA.$(date '+%Y')*" | wc -l) -eq 3 ]
		assertEquals "3 Backup files are present in [$INITIATOR_DIR/$OSYNC_BACKUP_DIR/]." "0" $?

		[ $(find "$TARGET_DIR/$OSYNC_BACKUP_DIR/" -type f -name "FileB.$(date '+%Y')*" | wc -l) -eq 3 ]
		assertEquals "3 Backup files are present in [$TARGET_DIR/$OSYNC_BACKUP_DIR/]." "0" $?
	done

	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "CONFLICT_BACKUP_MULTIPLE" "$conflictBackupMultipleLocal"
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "CONFLICT_BACKUP_MULTIPLE" "$conflictBackupMultipleRemote"

}

function test_Locking () {
	local forceStrangerUnlockLocal
	local forceStrangerUnlockRemote

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

		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "Should be able to resume when initiator has lock without running pid." "0" $?

		echo $$ > "$INITIATOR_DIR/$OSYNC_WORKDIR/lock"

		REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "Should never be able to resume when initiator has lock with running pid." "1" $?
	done

	# Target lock present should be resumed if instance ID is the same as current one
	PrepareLocalDirs
	mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
	echo 65536@quicklocal > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

	REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE ${osyncParameters[quickLocal]}
	assertEquals "Should be able to resume locked target with same instance_id in quickLocal mode." "0" $?

	PrepareLocalDirs
	mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
	echo 65536@local > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

	REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE ${osyncParameters[confLocal]}
	assertEquals "Should be able to resume locked target with same instance_id in confLocal mode." "0" $?

	PrepareLocalDirs
	mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
	echo 65536@quickremote > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

	REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE ${osyncParameters[quickRemote]}
	assertEquals "Should be able to resume locked target with same instance_id in quickRemote mode." "0" $?

	PrepareLocalDirs
	mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
	echo 65536@remote > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

	REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE ${osyncParameters[confRemote]}
	assertEquals "Should be able to resume locked target with same instance_id in confRemote mode." "0" $?

	# Remote Target lock present should not be resumed if instance ID is NOT the same as current one, local target lock is resumed
	PrepareLocalDirs
	mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
	echo 65536@bogusinstance > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

	REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE ${osyncParameters[quickLocal]}
	assertEquals "Should be able to resume locked local target with bogus instance id in quickLocal mode." "0" $?

	PrepareLocalDirs
	mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
	echo 65536@bogusinstance > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

	REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE ${osyncParameters[confLocal]}
	assertEquals "Should be able to resume locked local target with bogus instance_id in confLocal mode." "0" $?

	PrepareLocalDirs
	mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
	echo 65536@bogusinstance > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

	REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE ${osyncParameters[quickRemote]}
	assertEquals "Should not be able to resume remote locked target with bogus instance_id in quickRemote mode." "1" $?

	PrepareLocalDirs
	mkdir -p "$TARGET_DIR/$OSYNC_WORKDIR"
	echo 65536@bogusinstance > "$TARGET_DIR/$OSYNC_WORKDIR/lock"

	REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE ${osyncParameters[confRemote]}
	assertEquals "Should not be able to resume remote locked target with bgous instance_id in confRemote mode." "1" $?

	# Target lock present should be resumed if instance ID is NOT the same as current one but FORCE_STRANGER_UNLOCK=yes

	forceStrangerUnlockLocal=$(GetConfFileValue "$CONF_DIR/$LOCAL_CONF" "FORCE_STRANGER_LOCK_RESUME")
	forceStrangerUnlockRemote=$(GetConfFileValue "$CONF_DIR/$REMOTE_CONF" "FORCE_STRANGER_LOCK_RESUME")

	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "FORCE_STRANGER_LOCK_RESUME" "yes"
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "FORCE_STRANGER_LOCK_RESUME" "yes"

	for i in "${osyncParameters[@]}"; do

		cd "$OSYNC_DIR"
		PrepareLocalDirs

		mkdir -p "$INITIATOR_DIR/$OSYNC_WORKDIR"
		echo 65536@bogusinstance > "$INITIATOR_DIR/$OSYNC_WORKDIR/lock"

		FORCE_STRANGER_UNLOCK=yes REMOTE_HOST_PING=no ./$OSYNC_EXECUTABLE $i
		assertEquals "Should be able to resume when target has lock with different instance id but FORCE_STRANGER_UNLOCK=yes." "0" $?
	done

	SetConfFileValue "$CONF_DIR/$LOCAL_CONF" "FORCE_STRANGER_LOCK_RESUME" "$forceStrangerUnlockLocal"
	SetConfFileValue "$CONF_DIR/$REMOTE_CONF" "FORCE_STRANGER_LOCK_RESUME" "$forceStrangerUnlockRemote"
}

function test_WaitForTaskCompletion () {
	if [ "$OSYNC_MIN_VERSION" == "1" ]; then
		echo "Skipping WaitForTaskCompletion test because osync v1.1 does not support multiple pid monitoring"
		return 0
	fi

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
	if [ "$OSYNC_MIN_VERSION" == "1" ]; then
		echo "Skipping ParallelExec test because osync v1.1 didn't have this"
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

}

function test_UpgradeConfRun () {
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
        ./$OSYNC_EXECUTABLE "$CONF_DIR/$TMP_OLD_CONF"
        assertEquals "Upgraded conf file execution test" "0" $?

        rm -f "$CONF_DIR/$TMP_OLD_CONF"
        rm -f "$CONF_DIR/$TMP_OLD_CONF.save"
}


. "$TESTS_DIR/shunit2/shunit2"
