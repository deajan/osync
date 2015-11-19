#!/usr/bin/env bash

## Merges ofunctions.sh and $PROGRAM

PROGRAM=osync
FUNC_PATH=/home/git/common

PARANOIA_DEBUG_LINE="#__WITH_PARANOIA_DEBUG"
PARANOIA_DEBUG_BEGIN="#__BEGIN_WITH_PARANOIA_DEBUG"
PARANOIA_DEBUG_END="#__END_WITH_PARANOIA_DEBUG"

function Unexpand {
        unexpand n_$PROGRAM.sh > tmp_$PROGRAM.sh
}

function Merge {

	sed "/source \"\.\/ofunctions.sh\"/r /home/git/common/ofunctions.sh" tmp_$PROGRAM.sh | grep -v 'source "./ofunctions.sh"' > debug_$PROGRAM.sh
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

	sed -n '/'$PARANOIA_DEBUG_BEGIN'/{p; :a; N; /'$PARANOIA_DEBUG_END'/!ba; s/.*\n//}; p' debug_$PROGRAM.sh | grep -v "$PARANOIA_DEBUG_LINE" > ../$PROGRAM.sh
	chmod +x ../$PROGRAM.sh
}

function CopyCommons {
        sed "s/\[prgname\]/$PROGRAM/g" /home/git/common/common_install.sh > ../install.sh
        sed "s/\[prgname\]/$PROGRAM/g" /home/git/common/common_batch.sh > ../$PROGRAM-batch.sh
        chmod +x ../install.sh
        chmod +x ../$PROGRAM-batch.sh
}

Unexpand
Merge
CleanDebug
rm -f tmp_$PROGRAM.sh
CopyCommons
