# Sup-Notmuch

## What's here

This repository is a fork of [Jun Wu's Sup](https://github.com/quark-zju/sup) which was
in turn a fork of the [original Sup](https://github.com/sup-heliotrope/sup).  Jun Wu
replaced Xapian indexing with [notmuch](https://notmuchmail.org/) indexing. I am continuing that work, fixing bugs
and crashes, some of which may be due to changes in notmuch since 2017.  I'm also
reverting some of Jun Wu's changes, to restore some features that he deleted.

I have added two new configuration options (found in `~/.sup/config.yaml`):

* `:sent_folder`: a string containing the name of the mail folder to be used to store sent emails.
  If not specified, the default is `sent`.
* `:draft_folder`: a string containing the name of the mail folder to be used to store draft emails (i.e., composed but unsent emails)
  If not specified, the default is `draft`.

All of my changes are on the `notmuch` branch of this repository.  I
have tested is on Linux Mint 19 (based on Ubuntu 18.04), which uses
ruby version 2.5.1p57, and notmuch version 0.26.

To run it, use this command in the repository's top-level directory:

    ruby -I lib bin/sup

But first you'll want to set up notmuch and sup for receiving, sending, and indexing your mail:

## An example setup

In this example, I use fetchmail to fetch mail from my provider, which then
passes the mail off to notmuch for storing in a maildir.  I have set up notmuch
hooks to run fetchmail when sup runs `notmuch new`, and to tag the incoming messages based
on the sender.  Finally, I have set up sup to use `msmtp` to send outgoing mail.

### notmuch initial setup

By default, notmuch assumes that your primary maildir is $HOME/mail.  In this
example, I use subdirectories ("folders") of that directory for things like the inbox,
sent mail, and draft mail.

Before using notmuch the first time, use this command to create an initial configuration
file:

    notmuch setup

This creates a file `$HOME/.notmuch-config`.  I edited this file as follows:

* changed the `tags=unread;inbox;` line to `tags=new;`.  The reason for this will become
  clear later in the discussion about using a `post-new` hook to tag new email.

* removed `deleted;spam;` from the `exclude_tags` line.  This allows sup to search
  for deleted or spam emails.

I left the `path` value in the `[database]` section unchanged.  I used `maildirmake`
to create `$HOME/mail`, and to create the `sent`, `draft`, and `inbox` subdirectories
in that directory.

### fetchmail setup

My `~/fetchmailrc` looks something like this:

    poll mail.example.com port 995 with proto POP3 user 'me@example.com' pass 'mypassword' options ssl
      mda "notmuch insert --folder=inbox"

This setup uses POP3 to download the mails, which deletes the messages from the mail server.
Some users may want to use IMAP, so that the mails stay on the server.

Then I created a hook directory for notmuch:

    mkdir ~/mail/.notmuch

### notmuch hook setup

First, I created the directory `$HOME/mail/.notmuch/hooks`.  In that directory,
I created two executable (`chmod +x`) script, `pre-new` and `post-new`:

The `pre-new` script looks like this:

    #!/bin/sh
    fetchmail &>>/tmp/fetchmail.log
    exit 0

This script saves all fetchmail output in a log file for debugging purposes.  It also returns
an exit code of 0 in all cases.  This is necessary because fetchmail will return a non-zero exit code
if there is no new mail to fetch, and that will cause notmuch to fail.

Notmuch runs the this script before it scans the mail directory for new messages.

The `post-new` script looks like this:

    #!/bin/sh
    # immediately archive all messages from "me"
    #notmuch tag -new -- tag:new and from:me@example.com

    # delete all messages from a spammer:
    #notmuch tag +deleted -- tag:new and from:spam@spam.com

    # tag all messages from various mailing lists
    notmuch tag +geeks -- 'tag:new and to:geeks@lists.example.com'
    notmuch tag +nerds -- 'tag:new and to:nerds@lists.example.com'

    # tag message from specific recipients
    notmuch tag +orange -- 'tag:new and from:potus@whitehouse.gov'
    notmuch tag +mw -- 'tag:new and from:word@m-w.com'

    # finally, retag all "new" messages "inbox" and "unread"
    notmuch tag +inbox +unread -new -- tag:new

This script depends on new messages being tagged with the `new` tag.  As mentioned above,
this was accomplished with the `tags=new;` line in `$HOME/.notmuch-config`.

Notmuch runs this script after it has scanned the maildir for new messages.

### sup setup

To allow sup to display HTML-encoded emails, create the file `$HOME/.sup/hooks/mime-decode.rb`
that looks like this:

    unless sibling_types.member? "text/plain"
      case content_type
      when "text/html"
        `/usr/bin/w3m -dump -T #{content_type} '#{filename}'`
      end
    end

You can handle other mime types in this hook.

----

Below is Jun Wu's original README.

----

# Sup

Sup is a console-based email client for people with a lot of email.

![Screenshot](/screenshot/split-horizontal.png?raw=true)

## [notmuch](https://notmuchmail.org/) integration

The `notmuch` branch is a WORK-IN-PROGRESS to replace Sup's index backend with notmuch. It will reduce some features of Sup but would allow multiple Sup instances - Sup will be a "frontend" of notmuch.

Check the `forked` branch, or commit `35cf5cd61e` if you want to use Sup without notmuch.

## New features in this fork

- Basic mouse support.
- [Patchwork](http://jk.ozlabs.org/projects/patchwork/) integration. As the `.`, `o`, `x` in the screenshot, patch states can be easily observed.
- Async GUI editor support. You can edit multiple messages and browse other emails in Sup concurrently.
- Split view (experimental). By setting `:split_view` to `:vertical` or `:horizontal`, you can have more buffers in one screen.
- More flexible hooks. New hooks like `text-filter`, `collapsed-header` make things more flexible.
- Various fixes and improvements. For example, respect editor's exit code, no more "bundle exec", better cygwin support, etc. Read commit log for details.

## Installation

[See the wiki][Installation]

## Features / Problems

Features:

* GMail-like thread-centered archiving, tagging and muting
* [Handling mail from multiple mbox and Maildir sources][sources]
* Blazing fast full-text search with a [rich query language][search]
* Multiple accounts - pick the right one when sending mail
* [Ruby-programmable hooks][hooks]
* Automatically tracking recent contacts

Current limitations:

* Sup does in general not play nicely with other mail clients, not all
  changes can be synced back to the mail source. Refer to [Maildir Syncback][maildir-syncback]
  in the wiki for this recently included feature. Maildir Syncback
  allows you to sync back flag changes in messages and to write messages
  to maildir sources.

* Unix-centrism in MIME attachment handling and in sendmail invocation.

## Problems

Please report bugs to the [Github issue tracker](https://github.com/sup-heliotrope/sup/issues).

## Links

* [Homepage](http://sup-heliotrope.github.io/)
* [Code repository](https://github.com/sup-heliotrope/sup)
* [Wiki](https://github.com/sup-heliotrope/sup/wiki)
* IRC: [#sup @ freenode.net](http://webchat.freenode.net/?channels=#sup)
* Mailing list: supmua@googlegroups.com (subscribe: supmua+subscribe@googlegroups.com, archive: https://groups.google.com/d/forum/supmua )

## License

```
Copyright (c) 2013       Sup developers.
Copyright (c) 2006--2009 William Morgan.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301, USA.
```

[sources]: https://github.com/sup-heliotrope/sup/wiki/Adding-sources
[hooks]: https://github.com/sup-heliotrope/sup/wiki/Hooks
[search]: https://github.com/sup-heliotrope/sup/wiki/Searching-your-mail
[Installation]: https://github.com/sup-heliotrope/sup/wiki#installation
[ruby20]: https://github.com/sup-heliotrope/sup/wiki/Development#sup-014
[maildir-syncback]: https://github.com/sup-heliotrope/sup/wiki/Using-sup-with-other-clients
