#!/bin/bash

git clone git+ssh://aur@aur.archlinux.org/osync.git osync.aur
cd "osync.aur" &&
../makepkg -c &&
rm -rf osync* &&
../mksrcinfo &&
git push origin master &&
cd .. &&
rm -rf "osync.aur" &&
echo "Package updated successfully"
