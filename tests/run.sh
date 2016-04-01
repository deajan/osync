#!/usr/bin/env bash

# Test dir
TMP="/tmp/osync_tests"
# SSH port used for remote tests
SSH_PORT=49999

# Get dir the tests are stored in
TEST_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
cd "$TEST_DIR"

OSYNC_EXECUTABLE="$(dirname $TEST_DIR)//osync.sh"
declare -A sandbox_osync
#sandbox_osync[quickLocal]="--master=master --slave=slave"
#sandbox_osync[quickRemote]="--master=master --slave=ssh://localhost//tmp/osync_tests/quickRemote/slave"
#sandbox_osync[local]="conf/local.conf"
#sandbox_osync[remote]="conf/remote.conf"

oneTimeSetUp()
{
    for i in "${!sandbox_osync[@]}"
    do
        prepareSandbox "$i"
    done
}

oneTimeTearDown()
{
    rm -rf "$TMP"
}

prepareSandbox()
{
    rm -rf "$TMP/$1"
    mkdir -p "$TMP/$1"
    pushd "$TMP/$1" >/dev/null
    mkdir master
    mkdir slave
    mkdir expected
    popd >/dev/null
}

compareSandbox()
{
    diff -aurx .osync_workdir master slave
    assertEquals 0 $?

    diff -aurx .osync_workdir master expected
    assertEquals 0 $?

    diff -aurx .osync_workdir slave expected
    assertEquals 0 $?
}

syncSandbox()
{
    $OSYNC_EXECUTABLE ${sandbox_osync[$1]} >/dev/null
    assertEquals 0 $?
}

runSandbox()
{
    syncSandbox "$1"
    compareSandbox
}

joinSandbox()
{
    cd "$TMP/$1"
}

### Tests ###
# One empty file
_testOneEmptyFile()
{
    joinSandbox "$1"

    # Add one empty file
    touch "$2/testOneEmpty"
    touch expected/testOneEmpty
    runSandbox "$1"

    # Change one empty file
    echo "Test" > "$2/testOneEmpty"
    cp "$2/testOneEmpty" expected/testOneEmpty
    runSandbox "$1"

    # Empty one file
    echo -n "" > "$2/testOneEmpty"
    cp "$2/testOneEmpty" expected/testOneEmpty
    runSandbox "$1"

    # Delete one empty file
    cp "$2/testOneEmpty" testOneEmpty
    rm "$2/testOneEmpty"
    rm expected/testOneEmpty
    runSandbox "$1"
    # Backup check
    if [ "$2" == "master" ]
    then
        diff -aur slave/.osync_workdir/deleted/testOneEmpty testOneEmpty
    else
        diff -aur master/.osync_workdir/deleted/testOneEmpty testOneEmpty
    fi
    assertEquals 0 $?
}

testQuickLocalMasterOneEmptyFile()
{
    _testOneEmptyFile quickLocal master
}

testQuickLocalSlaveOneEmptyFile()
{
    _testOneEmptyFile quickLocal slave
}

testQuickRemoteMasterOneEmptyFile()
{
    _testOneEmptyFile quickRemote master
}

testQuickRemoteSlaveOneEmptyFile()
{
    _testOneEmptyFile quickRemote slave
}

testLocalMasterOneEmptyFile()
{
    _testOneEmptyFile local master
}

testLocalSlaveOneEmptyFile()
{
    _testOneEmptyFile local slave
}

testRemoteMasterOneEmptyFile()
{
    _testOneEmptyFile remote master
}

testRemoteSlaveOneEmptyFile()
{
    _testOneEmptyFile remote slave
}

# One file
_testOneFile()
{
    joinSandbox "$1"

    # Add one file
    echo "Test" > "$2/testOne"
    cp "$2/testOne" expected/testOne
    runSandbox "$1"

    # Change one file
    echo "Test2" > "$2/testOne"
    cp "$2/testOne" expected/testOne
    runSandbox "$1"

    # Delete one file
    cp "$2/testOne" testOne
    rm "$2/testOne"
    rm expected/testOne
    runSandbox "$1"
    # Backup check
    if [ "$2" == "master" ]
    then
        diff -aur slave/.osync_workdir/deleted/testOne testOne
    else
        diff -aur master/.osync_workdir/deleted/testOne testOne
    fi
    assertEquals 0 $?
}

testQuickLocalMasterOneFile()
{
    _testOneFile quickLocal master
}

testQuickLocalSlaveOneFile()
{
    _testOneFile quickLocal slave
}

testQuickRemoteMasterOneFile()
{
    _testOneFile quickRemote master
}

testQuickRemoteSlaveOneFile()
{
    _testOneFile quickRemote slave
}

testLocalMasterOneFile()
{
    _testOneFile local master
}

testLocalSlaveOneFile()
{
    _testOneFile local slave
}

testRemoteMasterOneFile()
{
    _testOneFile remote master
}

testRemoteSlaveOneFile()
{
    _testOneFile remote slave
}

# Distinct
_testDistinct()
{
    joinSandbox "$1"

    # Generate files in master
    for i in testDistinctM1 testDistinctM2 testDistinctM3
    do
        mkdir "master/$i"
        mkdir "expected/$i"
        for j in m1 m2 m3 ; do
            echo "$i/$j" > "master/$i/$j"
            cp "master/$i/$j" "expected/$i/$j"
        done
    done

    # Generate files in slave
    for i in testDistinctS1 testDistinctS2 testDistinctS3
    do
        mkdir "slave/$i"
        mkdir "expected/$i"
        for j in s1 s2 s3 ; do
            echo "$i/$j" > "slave/$i/$j"
            cp "slave/$i/$j" "expected/$i/$j"
        done
    done

    # Generate files in same directories for master and slave
    for i in testDistinctMS1 testDistinctMS2 testDistinctMS3
    do
        mkdir "master/$i"
        mkdir "slave/$i"
        mkdir "expected/$i"
        for j in ms1 ms2 ms3 ; do
            echo "$i/$j" > "master/$i/m-$j"
            cp "master/$i/m-$j" "expected/$i/m-$j"
            echo "$i/$j" > "slave/$i/s-$j"
            cp "slave/$i/s-$j" "expected/$i/s-$j"
        done
    done

    runSandbox "$1"
}

testQuickLocalDistinct()
{
    _testDistinct quickLocal
}

testQuickRemoteDistinct()
{
    _testDistinct quickRemote
}

testLocalDistinct()
{
    _testDistinct local
}

testRemoteDistinct()
{
    _testDistinct remote
}

# Collision
_testCollision()
{
    joinSandbox "$1"

    # Slave precedence
    echo "Test1" > master/testCollision1
    echo "Test2" > slave/testCollision1
    touch -d "2004-02-29 16:21:41" master/testCollision1
    touch -d "2004-02-29 16:21:42" slave/testCollision1
    cp slave/testCollision1 expected/testCollision1
    cp master/testCollision1 testCollision1
    runSandbox "$1"
    # Backup check
    diff -aur master/.osync_workdir/backups/testCollision1 testCollision1
    assertEquals 0 $?

    # Master precedence
    echo "Test1" > master/testCollision2
    echo "Test2" > slave/testCollision2
    touch -d "2004-02-29 16:21:42" master/testCollision2
    touch -d "2004-02-29 16:21:41" slave/testCollision2
    cp master/testCollision2 expected/testCollision2
    cp slave/testCollision2 testCollision2
    runSandbox "$1"
    # Backup check
    diff -aur slave/.osync_workdir/backups/testCollision2 testCollision2
    assertEquals 0 $?

    # ??
#    echo "Test1" > master/testCollision3
#    echo "Test2" > slave/testCollision3
#    touch -d "2004-02-29 16:21:42" master/testCollision3
#    touch -d "2004-02-29 16:21:42" slave/testCollision3
#    cp slave/testCollision3 expected/testCollision3
#    runSandbox "$1"
}

testQuickLocalCollision()
{
    _testCollision quickLocal
}

testQuickRemoteCollision()
{
    _testCollision quickRemote
}

testLocalCollision()
{
    _testCollision local
}

testRemoteCollision()
{
    _testCollision remote
}

#suite()
#{
#    suite_addTest "testQuickRemoteMasterOneEmptyFile"
#}

. shunit2/shunit2
