#!/usr/bin/env bash

# osync test suite 2016083001
# Add big fileset tests (eg: drupal 8 ?)


OSYNC_DIR="$(pwd)"
DEV_DIR="$OSYNC_DIR/dev"
TESTS_DIR="$DEV_DIR/tests"

OSYNC_EXECUTABLE="n_osync.sh"

INITIATOR_DIR="$TEST_DIR/opt/osync/initiator"
TARGET_DIR="$TEST_DIR/opt/osync/target"
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

	if grep "^IS_STABLE=YES" "$DEV_DIR/$OSYNC_EXECUTABLE" > /dev/null; then
		IS_STABLE=yes
	else
		IS_STABLE=no
		sed -i 's/^IS_STABLE=no/IS_STABLE=yes/' "$DEV_DIR/$OSYNC_EXECUTABLE"
	fi
}

function oneTimeTearDown () {
	if [ "$IS_STABLE" == "no" ]; then
		sed -i 's/^IS_STABLE=yes/IS_STABLE=no/' "$DEV_DIR/$OSYNC_EXECUTABLE"
	fi
}

function test_osync_quicksync_local () {
	CreateReplicas
	cd "$DEV_DIR"
	./n_osync.sh --initiator="$INITIATOR_DIR" --target="$TARGET_DIR" > /dev/null
	assertEquals "Return code" "0" $?

	[ -d "$INITIATOR_DIR/$OSYNC_STATE_DIR" ]
	assertEquals "Initiator state dir exists" "0" $?

	[ -d "$TARGET_DIR/$OSYNC_STATE_DIR" ]
	assertEquals "Target state dir exists" "0" $?
}


function test_osync_quicksync_remote () {
	CreateReplicas
	cd "$DEV_DIR"
	./n_osync.sh --initiator="$INITIATOR_DIR" --target="ssh://localhost:49999/$TARGET_DIR" --rsakey=/root/.ssh/id_rsa_local > /dev/null
	assertEquals "Return code" "0" $?

	[ -d "$INITIATOR_DIR/$OSYNC_STATE_DIR" ]
	assertEquals "Initiator state dir exists" "0" $?

	[ -d "$TARGET_DIR/$OSYNC_STATE_DIR" ]
	assertEquals "Target state dir exists" "0" $?
}

. "$TESTS_DIR/shunit2/shunit2"
