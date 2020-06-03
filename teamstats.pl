#!/usr/bin/env perl

use strict;
use warnings;
use v5.10;

use Path::Tiny;


#=== configuration ===========================================================

my %cfg = (

  logdir => 'logs',

  wget => 'wget --connect-timeout=10 --dns-timeout=5 --read-timeout=60 -t 1 -c -q -O %s %s',

  servers => {
    
    cue => {
      log => {
        url => 'https://underhound.eu/crawl/meta/0.24/logfile',
        file => 'log.cue.24.games',
      },
      milestones => {
        url => 'https://underhound.eu/crawl/meta/0.24/milestones',
        file => 'log.cue.24.milestones',
      },
    }

  }

);


#=== processing of logfiles ==================================================

my $logdir = path($cfg{logdir});

foreach my $server (keys %{$cfg{servers}}) {

  say "Processing $server";

  foreach my $log (qw(log milestones)) {
  
    my $url = $cfg{servers}{$server}{$log}{url};
    my $file = $logdir->child($cfg{servers}{$server}{$log}{file});
  
    say $url;
    say $file;

    my $r = system(sprintf($cfg{wget}, $file, $url));
    die "Failed to get $url" if $r;
  }

}
