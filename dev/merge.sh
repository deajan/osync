#!/usr/bin/env bash

## MERGE 2016112001

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

source "ofunctions.sh"
if [ $? != 0 ]; then
	echo "Please run $0 in dev directory with ofunctions.sh"
	exit 1
fi

function Unexpand {
	unexpand n_$PROGRAM.sh > tmp_$PROGRAM.sh
}

function MergeAll {

	sed "/source \"\.\/ofunctions.sh\"/r ofunctions.sh" tmp_$PROGRAM.sh | grep -v 'source "./ofunctions.sh"' > debug_$PROGRAM.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot sed ofunctions" "stdout"
		exit 1
	fi
	chmod +x debug_$PROGRAM.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot chmod $PROGRAM.sh" "stdout"
		exit 1
	fi
}

function MergeMinimum {
        sed -n "/$MINIMUM_FUNCTION_BEGIN/,/$MINIMUM_FUNCTION_END/p" ofunctions.sh > tmp_minimal.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot sed minimum functions." "stdout"
		exit 1
	fi
        sed "/source \"\.\/ofunctions.sh\"/r tmp_minimal.sh" tmp_$PROGRAM.sh | grep -v 'source "./ofunctions.sh"' | grep -v "$PARANOIA_DEBUG_LINE" > debug_$PROGRAM.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot remove PARANOIA_DEBUG code from tmp_minimum.." "stdout"
		exit 1
	fi
	rm -f tmp_minimal.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot remove tmp_minimal.sh" "stdout"
		exit 1
	fi

        chmod +x debug_$PROGRAM.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot chmod debug_$PROGRAM.sh" "stdout"
		exit 1
	fi

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
#	sed -n '/'$PARANOIA_DEBUG_BEGIN'/{p; :a; N; /'$PARANOIA_DEBUG_END'/!ba; s/.*\n//}; p' debug_$PROGRAM.sh | grep -v "$PARANOIA_DEBUG_LINE" > ../$PROGRAM.sh

	# Way simpler version of the above, compatible with BSD
	sed '/'$PARANOIA_DEBUG_BEGIN'/,/'$PARANOIA_DEBUG_END'/d' debug_$PROGRAM.sh | grep -v "$PARANOIA_DEBUG_LINE" > ../$PROGRAM.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot remove PARANOIA_DEBUG code from standard build." "stdout"
		exit 1
	fi

	chmod +x ../$PROGRAM.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot chmod $PROGRAM.sh" "stdout"
		exit 1
	fi
}

function CopyCommons {
	sed "s/\[prgname\]/$PROGRAM/g" common_install.sh > ../tmp_install.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot assemble install." "stdout"
		exit 1
	fi
	sed "s/\[version\]/$VERSION/g" ../tmp_install.sh > ../install.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot change install version." "stdout"
		exit 1
	fi
	if [ -f "common_batch.sh" ]; then
		sed "s/\[prgname\]/$PROGRAM/g" common_batch.sh > ../$PROGRAM-batch.sh
		if [ $? != 0 ]; then
			QuickLogger "Cannot assemble batch runner." "stdout"
			exit 1
		fi
		chmod +x ../$PROGRAM-batch.sh
		if [ $? != 0 ]; then
			QuickLogger "Cannot chmod $PROGRAM-batch.sh" "stdout"
			exit 1
		fi
	fi
	chmod +x ../install.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot chmod install.sh" "stdout"
		exit 1
	fi
	rm -f ../tmp_install.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot chmod $PROGRAM.sh" "stdout"
		exit 1
	fi
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
if [ $? != 0 ]; then
	QuickLogger "Cannot remove tmp_$PROGRAM.sh" "stdout"
	exit 1
fi
