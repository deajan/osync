osync
=====

A two way sync script based that adds script fault tolerance from obackup project.

## About

Having created obackup script in order to make reliable quick backups, i searched for a nice tool to handle two (or more) way sync scenarios in a reliable way.
While unison handles these scenarios, it's pretty messy to configure, slow and won't handle ACLs.
That's where bitpocket came handy, a nice script provided by sickill https://github.com/sickill/bitpocket.git
It's quick and small, but lacks some of the features i searched for like fault tolerance, stop and resume scenarios, and email warnings.

I then decided to write my own implementation of a two way rsync sync script, which would the features i wanted.

## Installation

Not even beta ready yet. The whole code is not stable at all.
Hopefully will work (more or less) by the end of July. I'm developping this in my free time.

## Author

Orsiris "Ozy" de Jong | ozy@badministrateur.com
