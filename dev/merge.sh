#!/usr/bin/env bash

## MERGE 2016080601-b

## Merges ofunctions.sh and n_program.sh into program.sh
## Adds installer

PROGRAM=osync
VERSION=$(grep "PROGRAM_VERSION=" n_$PROGRAM.sh)
VERSION=${VERSION#*=}

PARANOIA_DEBUG_LINE="__WITH_PARANOIA_DEBUG"
PARANOIA_DEBUG_BEGIN="#__BEGIN_WITH_PARANOIA_DEBUG"
PARANOIA_DEBUG_END="#__END_WITH_PARANOIA_DEBUG"
MINIMUM_FUNCTION_BEGIN="#### MINIMAL-FUNCTION-SET BEGIN ####"
MINIMUM_FUNCTION_END="#### MINIMAL-FUNCTION-SET END ####"

function Unexpand {
	unexpand n_$PROGRAM.sh > tmp_$PROGRAM.sh
}

function MergeAll {

	sed "/source \"\.\/ofunctions.sh\"/r ofunctions.sh" tmp_$PROGRAM.sh | grep -v 'source "./ofunctions.sh"' > debug_$PROGRAM.sh
	chmod +x debug_$PROGRAM.sh
}

function MergeMinimum {
        sed -n "/$MINIMUM_FUNCTION_BEGIN/,/$MINIMUM_FUNCTION_END/p" ofunctions.sh > tmp_minimal.sh
        sed "/source \"\.\/ofunctions.sh\"/r tmp_minimal.sh" tmp_$PROGRAM.sh | grep -v 'source "./ofunctions.sh"' | grep -v "$PARANOIA_DEBUG_LINE" > debug_$PROGRAM.sh
	rm -f tmp_minimal.sh
        chmod +x debug_$PROGRAM.sh
}


function CleanDebug {

# sed explanation
#/pattern1/{         # if pattern1 is found
#    p               # print it
#    :a              # loop
#        N           # and accumulate lines
#    /pattern2/!ba   # until pattern2 is found
#    s/.*\n//        # delete the part before pattern2
#}
#p

	sed '/'$PARANOIA_DEBUG_BEGIN'/,/'$PARANOIA_DEBUG_END'/d' debug_$PROGRAM.sh | grep -v "$PARANOIA_DEBUG_LINE" > ../$PROGRAM.sh
	chmod +x ../$PROGRAM.sh
}

function CopyCommons {
	sed "s/\[prgname\]/$PROGRAM/g" common_install.sh > ../tmp_install.sh
	sed "s/\[version\]/$VERSION/g" ../tmp_install.sh > ../install.sh
	if [ -f "common_batch.sh" ]; then
		sed "s/\[prgname\]/$PROGRAM/g" common_batch.sh > ../$PROGRAM-batch.sh
	fi
	chmod +x ../install.sh
	chmod +x ../$PROGRAM-batch.sh
	rm -f ../tmp_install.sh
}

Unexpand
if [ "$PROGRAM" == "osync" ] || [ "$PROGRAM" == "obackup" ]; then
	MergeAll
else
	MergeMinimum
fi
CleanDebug
CopyCommons
rm -f tmp_$PROGRAM.sh
