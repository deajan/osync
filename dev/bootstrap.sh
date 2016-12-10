#!/usr/bin/env bash

## dev pre-processor bootstrap rev 2016120701
## Yeah !!! A really tech sounding name... In fact it's just include emulation in bash

outputFileName="$0"

source "merge.sh"
__PREPROCESSOR_PROGRAM=osync
__PREPROCESSOR_Constants

cp "n_$__PREPROCESSOR_PROGRAM.sh" "$outputFileName.tmp.sh"
if [ $? != 0 ]; then
	QuickLogger "Cannot copy original file [n_$__PREPROCESSOR_PROGRAM.sh] to [$outputFileName.tmp.sh]." "stderr"
	exit 1
fi
for subset in "${__PREPROCESSOR_SUBSETS[@]}"; do
	__PREPROCESSOR_MergeSubset "$subset" "${subset//SUBSET/SUBSET END}" "ofunctions.sh" "$outputFileName.tmp.sh"
done
chmod +x "$0.tmp.sh"
if [ $? != 0 ]; then
	QuickLogger "Cannot make [$outputFileName] executable.." "stderr"
	exit 1
fi

# Termux fix
if type termux-fix-shebang > /dev/null 2>&1; then
	termux-fix-shebang "$outputFileName.tmp.sh"
fi

"$outputFileName.tmp.sh" "$@"

