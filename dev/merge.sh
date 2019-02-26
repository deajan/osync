#!/usr/bin/env bash

## MERGE 2019022601

## Merges ofunctions.sh and n_program.sh into program.sh
## Adds installer

PROGRAM=merge
INSTANCE_ID=dev

function Usage {
	echo "Merges ofunctions.sh and n_program.sh into debug_program.sh and ../program.sh"
	echo "Usage"
	echo "$0 osync|obackup|pmocr"
}

function __PREPROCESSOR_Merge {
	local nPROGRAM="$1"

	if [ -f "$nPROGRAM" ]; then
		Logger "$nPROGRAM is not found in local path." "CRITICAL"
		exit 1
	fi

	VERSION=$(grep "PROGRAM_VERSION=" n_$nPROGRAM.sh)
	VERSION=${VERSION#*=}
	__PREPROCESSOR_Constants

	__PREPROCESSOR_Unexpand "n_$nPROGRAM.sh" "debug_$nPROGRAM.sh"

	for subset in "${__PREPROCESSOR_SUBSETS[@]}"; do
		__PREPROCESSOR_MergeSubset "$subset" "${subset//SUBSET/SUBSET END}" "ofunctions.sh" "debug_$nPROGRAM.sh"
	done

	__PREPROCESSOR_CleanDebug "debug_$nPROGRAM.sh" "../$nPROGRAM.sh"
}

function __PREPROCESSOR_Constants {
	PARANOIA_DEBUG_LINE="#__WITH_PARANOIA_DEBUG"
	PARANOIA_DEBUG_BEGIN="#__BEGIN_WITH_PARANOIA_DEBUG"
	PARANOIA_DEBUG_END="#__END_WITH_PARANOIA_DEBUG"

	__PREPROCESSOR_SUBSETS=(
	'#### OFUNCTIONS FULL SUBSET ####'
	'#### OFUNCTIONS MINI SUBSET ####'
	'#### OFUNCTIONS MICRO SUBSET ####'
	'#### PoorMansRandomGenerator SUBSET ####'
	'#### _OFUNCTIONS_BOOTSTRAP SUBSET ####'
	'#### RUN_DIR SUBSET ####'
	'#### DEBUG SUBSET ####'
	'#### TrapError SUBSET ####'
	'#### RemoteLogger SUBSET ####'
	'#### Logger SUBSET ####'
	'#### GetLocalOS SUBSET ####'
	'#### IsInteger SUBSET ####'
	'#### UrlEncode SUBSET ####'
	'#### HumanToNumeric SUBSET ####'
	'#### ArrayContains SUBSET ####'
	'#### VerComp SUBSET ####'
	'#### GetConfFileValue SUBSET ####'
	'#### SetConfFileValue SUBSET ####'
	'#### CheckRFC822 SUBSET ####'
	'#### CleanUp SUBSET ####'
	)
}

function __PREPROCESSOR_Unexpand {
	local source="${1}"
	local destination="${2}"

	unexpand "$source" > "$destination"
	if [ $? != 0 ]; then
		Logger "Cannot unexpand [$source] to [$destination]." "CRITICAL"
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
		Logger "Cannot sed subset [$subsetBegin -- $subsetEnd] in [$subsetFile]." "CRTICIAL"
		exit 1
	fi
	sed "/include $subsetBegin/r $subsetFile.$subsetBegin" "$mergedFile" | grep -v -E "$subsetBegin\$|$subsetEnd\$" > "$mergedFile.tmp"
	if [ $? != 0 ]; then
		Logger "Cannot add subset [$subsetBegin] to [$mergedFile]." "CRITICAL"
		exit 1
	fi
	rm -f "$subsetFile.$subsetBegin"
	if [ $? != 0 ]; then
		Logger "Cannot remove temporary subset [$subsetFile.$subsetBegin]." "CRITICAL"
		exit 1
	fi

	rm -f "$mergedFile"
	if [ $? != 0 ]; then
		Logger "Cannot remove merged original file [$mergedFile]." "CRITICAL"
		exit 1
	fi

	mv "$mergedFile.tmp" "$mergedFile"
	if [ $? != 0 ]; then
		Logger "Cannot move merged tmp file to original [$mergedFile]." "CRITICAL"
		exit 1
	fi
}

function __PREPROCESSOR_CleanDebug {
	local source="${1}"
	local destination="${2:-$source}"

	sed '/'$PARANOIA_DEBUG_BEGIN'/,/'$PARANOIA_DEBUG_END'/d' "$source" | grep -v "$PARANOIA_DEBUG_LINE" > "$destination.tmp"
	if [ $? != 0 ]; then
		Logger "Cannot remove PARANOIA_DEBUG code from standard build." "CRITICAL"
		exit 1
	else
		mv -f "$destination.tmp" "$destination"
		if [ $? -ne 0 ]; then
			Logger "Cannot move [$destination.tmp] to [$destination]." "CRITICAL"
			exit 1
		fi
	fi

	chmod +x "$source"
	if [ $? != 0 ]; then
		Logger "Cannot chmod [$source]." "CRITICAL"
		exit 1
	else
		Logger "Prepared [$source]." "NOTICE"
	fi

	if [ "$source" != "$destination" ]; then

		chmod +x "$destination"
		if [ $? != 0 ]; then
			Logger "Cannot chmod [$destination]." "CRITICAL"
			exit 1
		else
			Logger "Prepared [$destination]." "NOTICE"
		fi
	fi
}

function __PREPROCESSOR_CopyCommons {
	local nPROGRAM="$1"

	sed "s/\[prgname\]/$nPROGRAM/g" common_install.sh > ../install.sh
	if [ $? != 0 ]; then
		Logger "Cannot assemble install." "CRITICAL"
		exit 1
	fi

	for subset in "${__PREPROCESSOR_SUBSETS[@]}"; do
		__PREPROCESSOR_MergeSubset "$subset" "${subset//SUBSET/SUBSET END}" "ofunctions.sh" "../install.sh"
	done

	__PREPROCESSOR_CleanDebug "../install.sh"

	if [ -f "common_batch.sh" ]; then
		sed "s/\[prgname\]/$nPROGRAM/g" common_batch.sh > ../$nPROGRAM-batch.sh
		if [ $? != 0 ]; then
			Logger "Cannot assemble batch runner." "CRITICAL"
			exit 1
		fi

		for subset in "${__PREPROCESSOR_SUBSETS[@]}"; do
			__PREPROCESSOR_MergeSubset "$subset" "${subset//SUBSET/SUBSET END}" "ofunctions.sh" "../$nPROGRAM-batch.sh"
		done

		__PREPROCESSOR_CleanDebug "../$nPROGRAM-batch.sh"
	fi
}

# If sourced don't do anything
if [ "$(basename $0)" == "merge.sh" ]; then
	source "./ofunctions.sh"
	if [ $? != 0 ]; then
		echo "Please run $0 in dev directory with ofunctions.sh"
		exit 1
	fi
	trap GenericTrapQuit TERM EXIT HUP QUIT

	if [ "$1" == "osync" ]; then
		__PREPROCESSOR_Merge osync
		__PREPROCESSOR_CopyCommons osync
	elif [ "$1" == "obackup" ]; then
		__PREPROCESSOR_Merge obackup
		__PREPROCESSOR_CopyCommons obackup
	elif [ "$1" == "pmocr" ]; then
		__PREPROCESSOR_Merge pmocr
		__PREPROCESSOR_CopyCommons pmocr
	else
		echo "No valid program given."
		Usage
		exit 1
	fi
fi
