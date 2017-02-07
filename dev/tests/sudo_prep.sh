#!/usr/bin/env bash

testUser=osyncsudo
testUserHome=/home/osyncsudo

function CreateUser {
	local remoteUser"${1}"

	if type getent > /dev/null 2>&1; then
		if ! getent passwd | grep "$remoteUser" > /dev/null; then
			echo "Manual creation of $remoteUser with homedir $remoteUserHome"
			if type adduser >/dev/null 2>&1; then
				adduser "$remoteUser"
			else
				echo "Cannot create user $remoteUser. Don't know what tool to use !"
			fi
		else
			echo "It seems that $remoteUser already exists"
		fi
	elif type dscl > /dev/null 2>&1; then
		if ! dscl . -search /Users name $remoteUser | grep "$remoteUser" > /dev/null; then
			echo "Manual creation of $remoteUser with homedir $remoteUserHome"
			dscl . -create /Users/$remoteUser
		else
			echo "It seems that $remoteUser already exists"
		fi
	else
		echo "Well, I don't know what tool to use to create that user for you"
	fi
}

function SetupSSH {
        local remoteUser="${1}"
        local homedir="${2}"

	if [ ! -d "$homedir/.ssh" ]; then
		mkdir "$homedir/.ssh"
		if  [ $? != 0 ]; then
			echo "Cannot create [$homedir/.ssh]."
			exit 1
		fi
	fi

	chmod 700 "$homedir/.ssh"
	if  [ $? != 0 ]; then
		echo "Cannot chmod [$homedir/.ssh]."
		exit 1
	fi

	chown $remoteUser "$homedir/.ssh"
	if  [ $? != 0 ]; then
		echo "Cannot chown [$homedir/.ssh]."
		exit 1
	fi

        echo -e  'y\n'| ssh-keygen -t rsa -b 2048 -N "" -f "$homedir/.ssh/id_rsa_local"
        if ! grep "$(cat $homedir/.ssh/id_rsa_local.pub)" "$homedir/.ssh/authorized_keys"; then
                cat "$homedir/.ssh/id_rsa_local.pub" >> "$homedir/.ssh/authorized_keys"
        fi
        chmod 600 "$homedir/.ssh/authorized_keys"
        chown $remoteUser "$homedir/.ssh/authorized_keys"
        chown $remoteUser "$homedir/.ssh/id_rsa_local"
        chown $remoteUser "$homedir/.ssh/id_rsa_local.pub"


        # Add localhost to known hosts so self connect works
        if [ -z "$(ssh-keygen -F localhost)" ]; then
                ssh-keyscan -H localhost >> "$homedir/.ssh/known_hosts"
        fi

	if [ -f "$homedir/.ssh/known_hosts" ]; then
	        chown $remoteUser "$homedir/.ssh/known_hosts"
	fi
}

function PrepareSudoers {
	local remoteUser="${1}"

	local bashPath
	local rsyncPath

	if ! type bash > /dev/null 2>&1; then
		echo "No bash available"
		exit 1
	else
		bashPath=$(type -p bash)
	fi

	if ! type rsync > /dev/null 2>&1; then
		echo "No rsync available"
		exit 1
	else
		rsyncPath=$(type -p rsync)
	fi

	RemoveSudoers $remoteUser

	if [ -f "/etc/sudoers" ]; then
		echo "$remoteUser ALL=NOPASSWD:SETENV:$rsyncPath,$bashPath" >> "/etc/sudoers"
		echo "Defaults:$remoteUser !requiretty" >> "/etc/sudoers"
	elif [ -f "/usr/local/etc/sudoers" ]; then
		echo "$remoteUser ALL=NOPASSWD:SETENV:$rsyncPath,$bashPath" >> "/usr/local/etc/sudoers"
		echo "Defaults:$remoteUser !requiretty" >> "usr/local/etc/sudoers"
	else
		echo "No sudoers file found."
		echo "copy the following lines to /etc/sudoers (or /usr/local/etc/sudoers) and adjust /usr/bin path to the target system"
		echo "$remoteUser ALL=NOPASSWD:SETENV:$rsyncPath,$bashPath"
		echo "Defaults:$remoteUser !requiretty"
	fi
}

function RemoveUser {
	local remoteUser="${1}"

	if type rmuser > /dev/null 2>&1; then
		rmuser -y $remoteUser
	elif type userdel > /dev/null 2>&1; then
		userdel -fr $remoteUser
	elif type dscl > /dev/null 2>&1; then
		dscl . -delete "Users/$remoteUser"
	else
		echo "Please remove $remoteUser manually"
	fi
}

function RemoveSudoers {
	local remoteUser="${1}"

	if [ -f "/etc/sudoers" ]; then
		cp "/etc/sudoers" "/etc/sudoers.old"
		grep -v "$remoteUser" "/etc/sudoers.old" > "/etc/sudoers"
	elif [ -f "/usr/local/etc/sudoers" ]; then
		cp "/usr/local/etc/sudoers" "/usr/local/etc/sudoers.old"
		grep -v "$remoteUser" "/usr/local/etc/sudoers.old" > "/usr/local/etc/sudoers"
	else
		echo "Please remove lines containing $remoteUser from sudoers file manualle"
	fi
}

if [ "$1" == "set" ]; then
	CreateUser "$testUser"
	SetupSSH "$testUser" "$testUserHome"
	PrepareSudoers "$testUser"
	echo ""
	echo "Now feel free to run osync sudo test with"
	echo "su osyncsudo"
	echo "SUDO_EXEC=yes osync.sh --initiator=/home/osyncsudo --target=ssh://osyncsudo@localhost:22//root/osync-tests --rsakey=/home/osyncsudo/.ssh/id_rsa_local"
	echo "Don't forget to run $0 unset later"


elif [ "$1" == "unset" ]; then
	RemoveUser "$testUser"
	RemoveSudoers "$testUser"
else
	echo "usage: $0 [set] [unset]"
fi


