#!/usr/bin/env bash

#SC1090 = not following non constants source
#SC1091 = not following source
#SC2086 = quoting errors (shellcheck is way too picky about quoting)
#SC2120 = only for debug version

shellcheck -e SC1090,SC1091,SC2086,SC2119,SC2120 $1
