#!/usr/bin/env bash

## dev pre-processor bootstrap rev 2018100201
## Yeah !!! A really tech sounding name... In fact it's just include emulation in bash

function Usage {
	echo "$0 - Quick and dirty preprocessor for including ofunctions into programs"
	echo "Creates and executes $0.tmp.sh"
	echo "Usage:"
	echo ""
	echo "$0 --program=osync|obackup|pmocr [options to pass to program]"
	echo "Can also be run with BASHVERBOSE=yes environment variable in order  to prefix program with bash -x"
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
else
	source "merge.sh"

	__PREPROCESSOR_PROGRAM=$bootstrapProgram
	__PREPROCESSOR_PROGRAM_EXEC="n_$bootstrapProgram.sh"
	__PREPROCESSOR_Constants

	if [ ! -f "$__PREPROCESSOR_PROGRAM_EXEC" ]; then
		echo "Cannot find file $__PREPROCESSOR_PROGRAM executable [n_$bootstrapProgram.sh]."
		exit 1
	fi
fi

cp "$__PREPROCESSOR_PROGRAM_EXEC" "$outputFileName.tmp.sh"
if [ $? != 0 ]; then
	echo "Cannot copy original file [$__PREPROCESSOR_PROGRAM_EXEC] to [$outputFileName.tmp.sh]."
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

if [ "$BASHVERBOSE" == "yes" ]; then
	bash -x "$outputFileName.tmp.sh" $opts
else
	"$outputFileName.tmp.sh" $opts
fi
