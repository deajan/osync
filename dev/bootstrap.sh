#!/usr/bin/env bash

## dev pre-processor bootstrap rev 2017061801
## Yeah !!! A really tech sounding name... In fact it's just include emulation in bash

if [ ! -f "./merge.sh" ]; then
	echo "Plrase run bootstrap.sh from osync/dev directory."
	exit 1
fi

outputFileName="$0"
if [ "$1" == "" ]; then
	PRG=osync
else
	PRG="$1"
fi

source "merge.sh"

__PREPROCESSOR_PROGRAM=$PRG
__PREPROCESSOR_Constants

cp "n_$__PREPROCESSOR_PROGRAM.sh" "$outputFileName.tmp.sh"
if [ $? != 0 ]; then
	echo "Cannot copy original file [n_$__PREPROCESSOR_PROGRAM.sh] to [$outputFileName.tmp.sh]."
	exit 1
fi
for subset in "${__PREPROCESSOR_SUBSETS[@]}"; do
	__PREPROCESSOR_MergeSubset "$subset" "${subset//SUBSET/SUBSET END}" "ofunctions.sh" "$outputFileName.tmp.sh"
done
chmod +x "$outputFileName.tmp.sh"
if [ $? != 0 ]; then
	echo "Cannot make [$outputFileName] executable."
	exit 1
fi

# Termux fix
if type termux-fix-shebang > /dev/null 2>&1; then
	termux-fix-shebang "$outputFileName.tmp.sh"
fi

"$outputFileName.tmp.sh" "$@"
