#!/bin/bash

HELPTEXT=\
"Usage: $0 [OPTIONS]\n"\
"Automatically updates the osync version in the AUR.\n"\
"\n"\
"-y, --yes            Do not prompt before committing\n"\
"-n, --name=USERNAME  Username to use with git in case no global username is set\n"\
"-e, --email=EMAIL    Email address to use with git in case no global email is set"

function cleanup {
    echo "Cleanup..."
    cd ..
    rm -rf osync.aur
}

# Check getopt compatibility
getopt --test > /dev/null
if [[ $? -ne 4 ]]; then
    echo "You don't seem to have the GNU-enhanced getopt available. That shouldn't happen on a modern system with bash installed."
    exit 38
fi

# Parse command line arguments
OPTIONS=hyn:e:
LONGOPTIONS=help,yes,name:,email:

PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
if [[ $? -ne 0 ]]; then
    exit 22
fi
eval set -- "$PARSED"

while true; do
    case "$1" in
        -h|--help)
            echo -e "$HELPTEXT"
            exit 0
            ;;
        -y|--yes)
            yes="y"
            shift
            ;;
        -n|--name)
            name="$2"
            shift 2
            ;;
        -e|--email)
            email="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Programming error" > /dev/stderr
            exit 131
            ;;
    esac
done

if [[ -z $name ]];then
    name=$(git config --global user.name)
    if [[ -z $name ]]; then
        echo "Please specify a username for the git commit with the -n|--name option or set it globally with 'git config --global user.name USERNAME"
        exit 22
    fi
fi

if [[ -z $email ]];then
    email=$(git config --global user.email)
    if [[ -z $email ]]; then
        echo "Please specify an e-mail for the git commit with the -e|--email option or set it globally with 'git config --global user.email EMAIL"
        exit 22
    fi
fi

### Main ###

echo "Cloning AUR package..."
if ! git clone -q git+ssh://aur@aur.archlinux.org/osync.git osync.aur || ! cd osync.aur; then
    exit 1
fi

git config user.name "$name"
git config user.email "$email"

echo "Cloning most recent stable version of osync..." &&
git clone -qb stable https://github.com/deajan/osync.git > /dev/null &&

echo "Fetching version..." &&
cd osync &&
pkgversion="$(git describe --tags --long | sed 's/\([^-]*-\)g/r\1/;s/-/./g')" &&
cd .. &&

echo "Updating version..." &&
sed -i "s/pkgver=.*/pkgver=${pkgversion}/g" "PKGBUILD" &&
../mksrcinfo &&
rm -rf "osync" &&

[[ ! -z $yes ]] || (read -p "About to commit changes to AUR. Are you sure? (y/n) " -n 1 -r && echo "" &&
[[ $REPLY =~ ^[Yy]$ ]]) &&

echo "Committing changes to AUR..." &&
git add PKGBUILD .SRCINFO &&
git commit -qm "Updated version to ${pkgversion}" &&
git push -q origin master &&

cleanup &&
echo "Package updated successfully to version ${pkgversion}" || cleanup

exit 0
