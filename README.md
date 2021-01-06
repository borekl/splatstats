![Screenshot](https://i.imgur.com/zmP468V.png)

See more screenshots [here](https://imgur.com/a/b5ncZ9P)

----

# splatstats
DCSS Tournament TeamSplat Statistics

Simple clan scoreboard meant to supplement the official scoreboard, which is fairly incomplete at this moment. This is very quick and dirty effort as it was started mere two days before the tournament was to begin. The tournament was then pushed back one week, so there was little more time to finish it and add little polish. It is configured through the `config.json` file, which should be self-explanatory (example config is part of the repo).

The script keeps local data in `state.json` file. This is created on the first run, which will probably take quite long depending on the size of the logs. This is particularly true if you try to run this on the massive trunk logs -- in that case the ingestion can take an hour or longer. Subsequent runs retrieve only increments of the logs and will run much faster, so it's safe to invoke this every minute.

**Important!**  
During the ingestion of log entries the script adds some additional derived fields. One of them is "clan" field that holds clan identification. If this identifcation changes, you must delete `state.json` and reload entire logs again -- otherwise the stats generated will be incorrect.

## 0.26 update

For 0.26 tournament I have added the ability to maintain multiple clan statistics
pages.

## Installation

You will need reasonably recent perl (5.10 or newer, should be in any
non-ancient Linux distro). Additionally, following additional modules need to
be installed (use CPAN to install them):

* Path::Tiny
* JSON::MaybeXS
* Time::Moment
* Try::Tiny
* Template Toolkit 2

## Configuration

Refer to `config-example.json` and use it as a template to create your own
`config.json`. The various options are explained below:

`state`  
Filename of the state file, no need to change this.

`logdir`  
Directory where logfiles/milestone logs will be stored in

`htmldir`  
Directory where HTML files will be generated. HTML files are generated from
Template Toolkit 2 templates that is in the `templates` directory. You will
likely want to change few things in there, esp. the icon is not present in the
repo, so replace it with your own or remove altogether.

`wget`  
Command-line for wget. This is used to pull the logfiles from the game servers.

### `clans` section

This section defines your clans. The toplevel `clans` key expects clan id as
child keys. These keys will be used as filenames for the clan html files.

`clan.CLANID.name`  
Clan's displayed name.

`clan.CLANID.members`  
List of clan's members, captains should be the first.

### `web` section

`web.clanrecent`  
How many recent games should be showin the "Recent Games" section of a clan
page.

`web.plrrecent`  
How many recent games should be showin the "Recent Games" section of a player
page.

`web.best`  
How many best games to show in the "Best Games" section.

### `servers` section

`servers.SERVER.log.url`  
`servers.SERVER.milestones.url`  
URL of the server's game and milestones log.

`servers.SERVER.log.file`  
`servers.SERVER.milestones.file`  
Name of the local file in `logdir` directory.

`servers.SERVER.morgue`  
Morgue URL.

`servers.SERVER.dump`  
Game dump URL.

`servers.SERVER.watch`  
Webtiles watch URL.

### `game` section

This section defines game entities: runes, gods and uniques etc. There's no
need to change this - just use the example.
