#!/usr/bin/env bash

## dev pre-processor bootstrap rev 2017061901
## Yeah !!! A really tech sounding name... In fact it's just include emulation in bash

function Usage {
	echo "$0 - Quick and dirty preprocessor for including ofunctions into programs"
	echo "Creates and executes $0.tmp.sh"
	echo "Usage:"
	echo ""
	echo "$0 --program=osync|osync_target_helper|obackup|pmocr [options to pass to program]"
}


if [ ! -f "./merge.sh" ]; then
	echo "Plrase run bootstrap.sh from osync/dev directory."
	exit 1
fi

bootstrapProgram=""
opts=""
outputFileName="$0"

for i in "$@"; do
        case $i in
                --program=*)
                bootstrapProgram="${i##*=}"
		;;
		*)
		opts=$opts" $i"
		;;
	esac
done

if [ "$bootstrapProgram" == "" ]; then
	Usage
	exit 128
fi

source "merge.sh"

__PREPROCESSOR_PROGRAM=$bootstrapProgram
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

"$outputFileName.tmp.sh" $opts
