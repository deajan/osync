osync
=====

A two way sync script based on rsync that merges obackup script fault tolerance with sync logic derived from bitpocket project.

## About

Having created obackup script in order to make reliable quick backups, i searched for a nice tool to handle two (or more) way sync scenarios in a reliable way.
While unison handles these scenarios, it's pretty messy to configure, slow and won't handle ACLs.
That's where bitpocket came handy, a nice script provided by sickill https://github.com/sickill/bitpocket.git
It's quick and small, but lacks some of the features i searched for like fault tolerance, stop and continue scenarios, and email warnings.

I then decided to merge my obackup codebase with bitpocket's sync core, osync was born.

## Installation

Not even beta ready yet. The whole code is not stable at all.
Hopefully will work by the end of July.

## Author

Orsiris "Ozy" de Jong | ozy@badministrateur.com
