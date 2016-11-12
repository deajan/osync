#!/bin/bash

git clone git+ssh://aur@aur.archlinux.org/osync.git osync.aur &&
cd "osync.aur" &&
srcdir="." &&
source "PKGBUILD" &&

url=$(echo -n ${source[0]} | sed 's/git+//g' | sed 's/#.*//g') &&
branch=$(echo -n ${source[0]} | sed 's/.*#branch=//g') &&
git clone -b $branch $url &&

# Get pkgver from current osync
pkgver=$(grep PROGRAM_VERSION= ./osync/osync.sh)
pkgver=${pkgver##*=}
echo $pkgver

sed -i "s/pkgver=.*/pkgver=$(pkgver)/g" "PKGBUILD" &&
../mksrcinfo &&
rm -rf "osync" &&
git add . &&
git commit -m "Updated version" &&
git push origin master &&
cd .. &&
rm -rf "osync.aur" &&
echo "Package updated successfully"
