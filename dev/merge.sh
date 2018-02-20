#!/usr/bin/env bash

## MERGE 2018021901

## Merges ofunctions.sh and n_program.sh into program.sh
## Adds installer

function Usage {
	echo "Merges ofunctions.sh and n_program.sh into debug_program.sh and ../program.sh"
	echo "Usage"
	echo "$0 osync|obackup|pmocr"
}

function __PREPROCESSOR_Merge {
	local PROGRAM="$1"

	VERSION=$(grep "PROGRAM_VERSION=" n_$PROGRAM.sh)
	VERSION=${VERSION#*=}
	__PREPROCESSOR_Constants

	source "ofunctions.sh"
	if [ $? != 0 ]; then
		echo "Please run $0 in dev directory with ofunctions.sh"
		exit 1
	fi

	__PREPROCESSOR_Unexpand "n_$PROGRAM.sh" "debug_$PROGRAM.sh"

	for subset in "${__PREPROCESSOR_SUBSETS[@]}"; do
		__PREPROCESSOR_MergeSubset "$subset" "${subset//SUBSET/SUBSET END}" "ofunctions.sh" "debug_$PROGRAM.sh"
	done

	__PREPROCESSOR_CleanDebug "$PROGRAM"
	rm -f tmp_$PROGRAM.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot remove tmp_$PROGRAM.sh"
		exit 1
	fi
}

function __PREPROCESSOR_Constants {
	PARANOIA_DEBUG_LINE="#__WITH_PARANOIA_DEBUG"
	PARANOIA_DEBUG_BEGIN="#__BEGIN_WITH_PARANOIA_DEBUG"
	PARANOIA_DEBUG_END="#__END_WITH_PARANOIA_DEBUG"

	__PREPROCESSOR_SUBSETS=(
	'#### OFUNCTIONS FULL SUBSET ####'
	'#### OFUNCTIONS MINI SUBSET ####'
	'#### _OFUNCTIONS_BOOTSTRAP SUBSET ####'
	'#### DEBUG SUBSET ####'
	'#### TrapError SUBSET ####'
	'#### RemoteLogger SUBSET ####'
	'#### QuickLogger SUBSET ####'
	'#### GetLocalOS SUBSET ####'
	'#### IsInteger SUBSET ####'
	'#### UrlEncode SUBSET ####'
	'#### HumanToNumeric SUBSET ####'
	'#### ArrayContains SUBSET ####'
	'#### VerComp SUBSET ####'
	'#### GetConfFileValue SUBSET ####'
	'#### SetConfFileValue SUBSET ####'
	'#### CheckRFC822 SUBSET ####'
	)
}

function __PREPROCESSOR_Unexpand {
	local source="${1}"
	local destination="${2}"

	unexpand "$source" > "$destination"
	if [ $? != 0 ]; then
		QuickLogger "Cannot unexpand [$source] to [$destination]."
		exit 1
	fi
}

function __PREPROCESSOR_MergeSubset {
	local subsetBegin="${1}"
	local subsetEnd="${2}"
	local subsetFile="${3}"
	local mergedFile="${4}"

	sed -n "/$subsetBegin/,/$subsetEnd/p" "$subsetFile" > "$subsetFile.$subsetBegin"
	if [ $? != 0 ]; then
		QuickLogger "Cannot sed subset [$subsetBegin -- $subsetEnd] in [$subsetFile]."
		exit 1
	fi
	sed "/include $subsetBegin/r $subsetFile.$subsetBegin" "$mergedFile" | grep -v -E "$subsetBegin\$|$subsetEnd\$" > "$mergedFile.tmp"
	if [ $? != 0 ]; then
		QuickLogger "Cannot add subset [$subsetBegin] to [$mergedFile]."
		exit 1
	fi
	rm -f "$subsetFile.$subsetBegin"
	if [ $? != 0 ]; then
		QuickLogger "Cannot remove temporary subset [$subsetFile.$subsetBegin]."
		exit 1
	fi

	rm -f "$mergedFile"
	if [ $? != 0 ]; then
		QuickLogger "Cannot remove merged original file [$mergedFile]."
		exit 1
	fi

	mv "$mergedFile.tmp" "$mergedFile"
	if [ $? != 0 ]; then
		QuickLogger "Cannot move merged tmp file to original [$mergedFile]."
		exit 1
	fi
}

function __PREPROCESSOR_CleanDebug {
	local PROGRAM="$1"

	sed '/'$PARANOIA_DEBUG_BEGIN'/,/'$PARANOIA_DEBUG_END'/d' debug_$PROGRAM.sh | grep -v "$PARANOIA_DEBUG_LINE" > ../$PROGRAM.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot remove PARANOIA_DEBUG code from standard build."
		exit 1
	fi

	chmod +x "debug_$PROGRAM.sh"
	if [ $? != 0 ]; then
		QuickLogger "Cannot chmod debug_$PROGRAM.sh"
		exit 1
	else
		QuickLogger "Prepared ./debug_$PROGRAM.sh"
	fi
	chmod +x "../$PROGRAM.sh"
	if [ $? != 0 ]; then
		QuickLogger "Cannot chmod $PROGRAM.sh"
		exit 1
	else
		QuickLogger "Prepared ../$PROGRAM.sh"
	fi
}

function __PREPROCESSOR_CopyCommons {
	local PROGRAM="$1"

	sed "s/\[prgname\]/$PROGRAM/g" common_install.sh > ../install.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot assemble install."
		exit 1
	fi

	for subset in "${__PREPROCESSOR_SUBSETS[@]}"; do
		__PREPROCESSOR_MergeSubset "$subset" "${subset//SUBSET/SUBSET END}" "ofunctions.sh" "../install.sh"
	done

	#sed "s/\[version\]/$VERSION/g" ../tmp_install.sh > ../install.sh
	#if [ $? != 0 ]; then
	#	QuickLogger "Cannot change install version."
	#	exit 1
	#fi
	if [ -f "common_batch.sh" ]; then
		sed "s/\[prgname\]/$PROGRAM/g" common_batch.sh > ../$PROGRAM-batch.sh
		if [ $? != 0 ]; then
			QuickLogger "Cannot assemble batch runner."
			exit 1
		fi
		chmod +x ../$PROGRAM-batch.sh
		if [ $? != 0 ]; then
			QuickLogger "Cannot chmod $PROGRAM-batch.sh"
			exit 1
		else
			QuickLogger "Prepared ../$PROGRAM-batch.sh"
		fi
	fi
	chmod +x ../install.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot chmod install.sh"
		exit 1
	else
		QuickLogger "Prepared ../install.sh"
	fi
	rm -f ../tmp_install.sh
	if [ $? != 0 ]; then
		QuickLogger "Cannot chmod $PROGRAM.sh"
		exit 1
	fi
}

# If sourced don't do anything
if [ "$(basename $0)" == "merge.sh" ]; then
	if [ "$1" == "osync" ]; then

		__PREPROCESSOR_Merge osync
		__PREPROCESSOR_Merge osync_target_helper
		__PREPROCESSOR_CopyCommons osync
	elif [ "$1" == "obackup" ]; then
		__PREPROCESSOR_Merge obackup
		__PREPROCESSOR_CopyCommons obackup
	elif [ "$1" == "pmocr" ]; then
		__PREPROCESSOR_Merge pmocr
		__PREPROCESSOR_CopyCommons pmocr
	else
		echo "No valid program given."
		exit 1
	fi
fi
