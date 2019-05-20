KNOWN ISSUES
------------

  - Cannot finish sync if one replica contains a directory and the other replica contains a file named the same way (Unix doesn't allow this)
  - Daemon mode monitors changes in the whole replica directories, without honoring exclusion lists
  - Soft deletion does not honor exclusion lists (ie soft deleted files will be cleaned regardless of any exlude pattern because they are in the deleted folder)
  - Colors don't work in mac shell
