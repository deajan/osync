#!/usr/bin/env bash

#SC2120 = only for debug version

shellcheck -e SC2086,SC2119,SC2120 $1
