#!/usr/bin/env bash

# Basic run test to make travis happy

mkdir t1
mkdir t2

./osync.sh --initiator=t1 --target=t2
