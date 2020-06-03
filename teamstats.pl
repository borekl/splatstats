#!/usr/bin/env perl

use strict;
use warnings;
use v5.10;

use Path::Tiny;
use JSON::MaybeXS;


#=== globals =================================================================

my $js = JSON::MaybeXS->new(pretty => 1, utf8 => 1);


#=== configuration ===========================================================

my %cfg = (

  state => 'state.json',

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


#=== state initialization/loading ============================================

my $state_file = path($cfg{state});
my $state = {};

if(-f $state_file) {
  say 'State file exists, loading';
  $state = $js->decode($state_file->slurp_raw());
};


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


#=== save state ==============================================================

say "Saving state";

my $state_new = $state_file->sibling($state_file->basename . ".$$");
$state_new->spew_raw($js->encode($state));
$state_new->move($state_file);
