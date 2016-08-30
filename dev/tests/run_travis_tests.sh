#!/usr/bin/env bash

# osync test suite 2016083002
# Add big fileset tests (eg: drupal 8 ?)


OSYNC_DIR="$(pwd)"
OSYNC_DIR=${OSYNC_DIR%%/dev*}
DEV_DIR="$OSYNC_DIR/dev"
TESTS_DIR="$DEV_DIR/tests"

OSYNC_EXECUTABLE="osync.sh"

INITIATOR_DIR="${HOME}/osync/initiator"
TARGET_DIR="${HOME}/osync/target"
OSYNC_STATE_DIR=".osync_workdir/state"

function CreateReplicas () {
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
}

function oneTimeTearDown () {
	if [ "$IS_STABLE" == "no" ]; then
		sed -i.tmp 's/^IS_STABLE=yes/IS_STABLE=no/' "$OSYNC_DIR/$OSYNC_EXECUTABLE"
	fi
}

function test_Merge () {
        cd "$DEV_DIR"
        ./merge.sh
        assertEquals "Merging code" "0" $?
}

function test_SetStable () {
	if grep "^IS_STABLE=YES" "$OSYNC_DIR/$OSYNC_EXECUTABLE" > /dev/null; then
		IS_STABLE=yes
		echo "Is already set as stable"
	else
		IS_STABLE=no
		sed -i.tmp 's/^IS_STABLE=no/IS_STABLE=yes/' "$OSYNC_DIR/$OSYNC_EXECUTABLE"
		assertEquals "Set as stable" "0" $?
	fi
}

function test_osync_quicksync_local () {
	CreateReplicas
	cd "$OSYNC_DIR"
	./$OSYNC_EXECUTABLE --initiator="$INITIATOR_DIR" --target="$TARGET_DIR"
	assertEquals "Return code" "0" $?

	[ -d "$INITIATOR_DIR/$OSYNC_STATE_DIR" ]
	assertEquals "Initiator state dir exists" "0" $?

	[ -d "$TARGET_DIR/$OSYNC_STATE_DIR" ]
	assertEquals "Target state dir exists" "0" $?
}

. "$TESTS_DIR/shunit2/shunit2"
