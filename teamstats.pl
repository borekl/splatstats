#!/usr/bin/env perl

use strict;
use warnings;
use v5.10;

use lib 'lib';

use Path::Tiny;
use JSON::MaybeXS;
use Time::Moment;
use Try::Tiny;
use Template;
use Getopt::Long;
use Data::Dumper;

use TeamStats::Config;

#=== globals ==================================================================

my $js = JSON::MaybeXS->new(pretty => 1, utf8 => 1);
my $cfg2 = TeamStats::Config->instance;
my $cfg = $cfg2->config;

#=== command line options =====================================================

my $cmd_retrieve = 1;           # retrieve remote logs
my $cmd_debug = 0;              # debug mode

#==============================================================================
# FUNCTIONS
#==============================================================================

# Convert time as saved in DCSS logfiles to Unix epoch time. DCSS
# "start"/"end" time specification is confusing: it looks like ISO 8601, but
# the T delimiter is missing, the 'S' at the end means who-knows-what and the
# month field is 0-based.

sub to_moment
{
  my $tm = shift;

  $tm =~ /^(\d{4})(\d{2})(\d{2})(\d{6})S$/;
  $tm = sprintf('%04d%02d%02dT%sZ', $1, $2+1, $3, $4);
  return Time::Moment->from_string($tm);
}

# format duration to human readable format

sub format_duration
{
  my $secs = shift;
  use integer;

  my $days = $secs / 86400;
  $secs %= 86400;

  my $hours = $secs / 3600;
  $secs %= 3600;

  my $minutes = $secs / 60;
  $secs %= 60;

  my $re = '';
  if($days) {
    $re = sprintf('%d, ', $days);
  }
  $re .= sprintf('%02d:%02d:%02d', $hours, $minutes, $secs);
  return $re;
}

# morgue url

sub morgue_url
{
  my $row = shift;
  my $server = $row->{server};
  my $player = $row->{name};

  # if dump url is not defined, do nothing
  return if(!exists $cfg->{servers}{$server}{morgue});
  my $template = $cfg->{servers}{$server}{morgue};

  # get formatted time
  return if !exists $row->{end};
  my $tm = to_moment($row->{end})->strftime('%Y%m%d-%H%M%S');

  # perform token replacement
  $template =~ s/%u/$player/g;
  $template =~ s/%d/$tm/g;

  # save and finsh
  $row->{dumpurl} = $template;
}

# in-progress dump
sub server_url
{
  my ($server, $item, $player) = @_;

  # return undef if dump URL is not defined
  return undef if !exists $cfg->{servers}{$server}{$item};
  my $template = $cfg->{servers}{$server}{$item};

  # perform token replacement
  $template =~ s/%u/$player/g;

  # finish
  return $template;
}

# check if given game reached maxpiety with the winning deity; this is the
# requirement for a game to count as "won with god" (excluding Xom/Gozag)

sub check_god_maxpiety
{
  my $data = shift;
  my $g = shift;
  my $god = $g->{god};

  if(
    grep {
      $_->{start_epoch} == $g->{start_epoch}
      && $_->{type} eq 'god.maxpiety'
    } @{$data->{milestones}}
  ) {
    return 1;
  } else {
    return undef;
  }
}

# check if given god was the only god worshipped in the game; this is the
# requirement for a game to count as won with either Xom or Gozag

sub check_god_exclusivity
{
  my $data = shift;
  my $g = shift;
  my $god = $g->{god};

  if(
    grep {
      $_->{start_epoch} == $g->{start_epoch}
      && $_->{type} =~ /^god\./
      && ($_->{god} && $_->{god} ne $god)
    } @{$data->{milestones}}
  ) {
    return 0;
  } else {
    return 1;
  }
}

# check if given game is atheist

sub check_atheist
{
  my $data = shift;
  my $g = shift;

  # some shortcuts can be made
  return 0 if
    $g->{cls} eq 'Berserker'
    || $g->{cls} eq 'Chaos Knight'
    || $g->{cls} eq 'Abyssal Knight';
  return 1 if $g->{race} eq 'Demigod';

  if(
    grep {
      $_->{start_epoch} == $g->{start_epoch}
      && $g->{type}
      && $g->{type} =~ /^god\./
    } @{$data->{milestones}}
  ) {
    return 0
  } else {
    return 1
  }
}

#==============================================================================
# MAIN
#==============================================================================

#=== command-line processing ==================================================

GetOptions(
  'retrieve!' => \$cmd_retrieve,
  'debug!' => \$cmd_debug
);

#=== load configuration =======================================================

say 'Configured clans: ', join(', ', $cfg2->clans);
say 'Configured players: ', join(', ', $cfg2->players);

#=== state initialization/loading ============================================

my $state_file = path($cfg->{state});
my $state = {};

if(-f $state_file) {
  print 'State file exists, loading ... ';
  $state = $js->decode($state_file->slurp_raw());
  say 'done'
} else {
  $state->{games} = [];
  $state->{milestones} = [];
}

#=== loading of logfiles =====================================================

my $logdir = path($cfg->{logdir});

foreach my $server (keys %{$cfg->{servers}}) {

  say "Processing $server";

  try {

    foreach my $log (qw(log milestones)) {

      # get URL and localfile
      my $url = $cfg->{servers}{$server}{$log}{url};
      my $file = $logdir->child($cfg->{servers}{$server}{$log}{file});

      # get our last position in the file (or 0 if none)
      my $fpos = $state->{servers}{$server}{$log}{fpos} // 0;

      # retrieve new data from URL
      if($cmd_retrieve) {
        my $r = system(sprintf($cfg->{wget}, $file, $url));
        die "Failed to get $url" if $r;
      }

      # open the file and seek into it
      open(my $fh, '<', $file) or die 'Failed to open ' . $file;
      seek($fh, $fpos, 0) if $fpos;

      # read the new data
      my ($count_total, $count_selected) = (0,0);
      while(my $line = <$fh>) {
        chomp $line;
        my %row;

        # following regex splits the line by ':' delimiter, but ignores '::',
        # which works as an escape to denote ':' in value
        foreach my $fv (split(/(?<!:):(?!:)/, $line)) {
          $fv =~ s/::/:/g;
          my @fv = split(/=/, $fv);
          $row{$fv[0]} = $fv[1] if $fv[0];
        }

        # rudimentary detection of malformed lines; 'v' field is the first one
        # so if some mangling happens, this is very likely to go missing
        next unless exists $row{v};

        $count_total++;

        # check for team members, ignore all other entries
        #next if !(grep { $_ eq $row{name} } @{$cfg->{match}{members}});
        next if !exists $row{name} || !$row{name};
        next if !exists $cfg2->plr_to_clan->{$row{name}};

        # add clan id to every row
        $row{clan} = $cfg2->plr_to_clan->{$row{name}};

        # convert dates into epoch/human readable format and match time bracket
        my $tm_start = to_moment($row{start});
        $row{start_epoch} = $tm_start->epoch;
        next if $tm_start < $cfg2->start;
        $row{start_fmt} = $tm_start->strftime('%Y-%m-%d %H:%M:%S');
        if($log eq 'log') {
          my $tm_end = to_moment($row{end});
          last if $tm_end >= $cfg2->end;
          $row{end_epoch} = $tm_end->epoch;
          $row{end_fmt} = $tm_end->strftime('%Y-%m-%d %H:%M:%S');
          $row{dur_fmt} = format_duration($row{dur});
        } else {
          my $tm_time = to_moment($row{time});
          next if $tm_time < $cfg2->start;
          last if $tm_time >= $cfg2->end;
          $row{time_epoch} = to_moment($row{time})->epoch;
          $row{milestone} =~ s/.$//;
        }

        # save server id
        $row{server} = $server;

        # get dump url
        morgue_url(\%row);

        $count_selected++;

        # store into state
        if($log eq 'log') {
          push(@{$state->{games}}, \%row);
        } else {
          push(@{$state->{milestones}}, \%row);
        }
      }

      printf(
        "  %d new lines (%d matched) in %s/%s\n",
        $count_total, $count_selected, $server, $log
      );

      # finish
      $fpos = tell($fh);
      $state->{servers}{$server}{$log}{fpos} = $fpos;
      close($fh);

    }

  };
}

#=== processing data ==========================================================

my %data = (
  cfg => $cfg,
  milestones => $state->{milestones}
);

my $games = $state->{games};
my $milestones = $state->{milestones};

#--- resolve "now" moment ----------------------------------------------------

my $now = $cfg2->now->epoch;
my $end_of_tourney = $cfg2->end->epoch;
$now = $end_of_tourney if $now > $end_of_tourney;

#--- add 'time_from_now' field to milestones

foreach my $ms (@$milestones) {
  $ms->{time_from_now} = $now - $ms->{time_epoch};
  $ms->{time_from_now_fmt} = format_duration($ms->{time_from_now});
}

#--- list of games indexed by start time -------------------------------------

foreach my $g (@$games) {
  $data{games}{by_start}{$g->{start_epoch}} = $g;
}

#--- list of all clan games sorted by end time --------------------------------

foreach my $clan ($cfg2->clans) {
  $data{clans}{$clan}{games}{all} = [
    sort { $b->{end_epoch} <=> $a->{end_epoch} }
    grep { $_->{clan} eq $clan } @$games
  ];
}

#--- list of won clan games --------------------------------------------------

foreach my $clan ($cfg2->clans) {
  my @wins = sort {
    $a->{end_epoch} <=> $b->{end_epoch}
  } grep {
    $_->{clan} eq $clan && $_->{ktyp} eq 'winning'
  } @$games;

  my @wins_allrune = sort {
    $a->{end_epoch} <=> $b->{end_epoch}
  } grep {
    $_->{urune} == 15
  } @wins;

  $data{clans}{$clan}{games}{wins} = \@wins;
  $data{clans}{$clan}{games}{wins_allrune} = \@wins_allrune;
}

#--- clan combos --------------------------------------------------------------

foreach my $clan ($cfg2->clans) {
  my %combos;
  foreach my $row (@{$data{clans}{$clan}{games}{wins}}) {
    $combos{ $row->{char} }++;
  }
  $data{clans}{$clan}{combos} = \%combos;
}

#--- clan ghost kills ---------------------------------------------------------

foreach my $clan ($cfg2->clans) {
  $data{clans}{$clan}{gkills} = grep {
    $_->{clan} eq $clan
    && $_->{type} eq 'ghost'
  } @$milestones;
}

#--- by-player stats ----------------------------------------------------------

foreach my $player ($cfg2->players) {

  # all games
  $data{players}{$player}{games}{all} = [
    sort {
      $a->{end_epoch} <=> $b->{end_epoch}
    } grep {
      $_->{name} eq $player
    } @$games
  ];

  # won games
  $data{players}{$player}{games}{wins} = [
    sort {
      $a->{end_epoch} <=> $b->{end_epoch}
    } grep {
      $_->{ktyp} eq 'winning'
    } @{$data{players}{$player}{games}{all}}
  ];

  # sort per-player game lists by score
  $data{players}{$player}{games}{by_score} = [
    sort {
      $b->{sc} <=> $a->{sc}
    } @{$data{players}{$player}{games}{all}}
  ];

  # milestones
  my @milestones_by_player = sort {
    $a->{time_epoch} <=> $b->{time_epoch}
  } grep {
    $_->{name} eq $player
  } @$milestones;

  # find all servers player has started a game on; we record number of games
  # player has started on each server and then create a sorted list; sorted
  # list is useful in the web where we can list most used servers first
  foreach my $ms (@milestones_by_player) {
    next if $ms->{type} ne 'begin';
    $data{players}{$player}{servers}{$ms->{server}}++;
  }
  $data{players}{$player}{servers} = [ sort {
    $data{players}{$player}{servers}{$b} cmp $data{players}{$player}{servers}{$a}
  } keys %{$data{players}{$player}{servers}} ];

  foreach my $server (@{$data{players}{$player}{servers}}) {
    $data{players}{$player}{dumps}{$server}
    = server_url($server, 'dump', $player);
    $data{players}{$player}{watch}{$server}
    = server_url($server, 'watch', $player);
  }
}

#--- last milestone per (player, server)

foreach my $ms (sort { $a->{time_epoch} <=> $b->{time_epoch} } @$milestones) {
  $data{players}{$ms->{name}}{last_milestones}{$ms->{server}} = $ms;
}

#--- in progress games

# to get games in progress, we scan the last milestone per (player, server)
# found in the previous step and see if there's corresponding game in the games
# log; if there isn't, the milestone belongs to an unfinished, on-going game
#
# The result of this code is stored in "clan.in_progress" and
# "player.PLR.in_progress". The stored entities are references to the last
# milestone entries of ongoing games.

foreach my $player ($cfg2->players) {

  # ignore players without any recorded milestones
  next if !exists $data{players}{$player}{last_milestones};

  # get player's clan association
  my $clan = $cfg2->plr_to_clan->{$player};

  # initialize in progress lists
  $data{players}{$player}{in_progress} = [];
  $data{clans}{$clan}{in_progress} = []
    if !exists $data{clans}{$clan}{in_progress};

  # iterate over servers player has milestones on
  foreach my $srv (keys %{$data{players}{$player}{last_milestones}}) {
    my $ms = $data{players}{$player}{last_milestones}{$srv};
    if(!exists $data{games}{by_start}{$ms->{start_epoch}}) {
      push(@{$data{clans}{$clan}{in_progress}}, $ms);
      push(@{$data{players}{$player}{in_progress}}, $ms);
    }
  }

  # sort current player's games in progress list
  $data{players}{$player}{in_progress} = [
    sort {
      $a->{time_from_now} <=> $b->{time_from_now}
    } @{$data{players}{$player}{in_progress}}
  ];

}

# sort all clans' games in progress list
foreach my $clan ($cfg2->clans) {
  $data{clans}{$clan}{in_progress} = [
    sort {
      $a->{time_from_now} <=> $b->{time_from_now}
    } @{$data{clans}{$clan}{in_progress}}
  ]
}

#--- best clan games ----------------------------------------------------------

foreach my $clan ($cfg2->clans) {
  # best turncount
  $data{clans}{$clan}{games}{wins_by_turncount} = [
    sort {
      $a->{turn} <=> $b->{turn}
    } grep {
      $_->{clan} eq $clan && $_->{ktyp} eq 'winning'
    } @$games
  ];
  # best realtime
  $data{clans}{$clan}{games}{wins_by_realtime} = [
    sort {
      $a->{dur} <=> $b->{dur}
    } grep {
      $_->{clan} eq $clan && $_->{ktyp} eq 'winning'
    } @$games
  ];
  # highest score
  $data{clans}{$clan}{games}{by_score} = [
    sort {
      $b->{sc} <=> $a->{sc}
    } grep {
      $_->{clan} eq $clan
    } @$games
  ];
  # lowest xl win
  $data{clans}{$clan}{games}{wins_by_xl} = [
    sort {
      if($a->{xl} == $b->{xl}) {
        $a->{turn} <=> $b->{turn}
      } else {
        $a->{xl} <=> $b->{xl}
      }
    }
    grep {
        $_->{clan} eq $clan && $_->{ktyp} eq 'winning'
    } @$games
  ];
  # lowest xl rune
  $data{clans}{$clan}{games}{by_xlrune} = [
    sort {
      if($a->{xl} == $b->{xl}) {
        $a->{turn} <=> $b->{turn}
      } else {
        $a->{xl} <=> $b->{xl}
      }
    } grep {
      $_->{clan} eq $clan
      && $_->{type} eq 'rune'
      && $_->{urune} == 1
    } @$milestones
  ];
}

#--- runes -------------------------------------------------------------------

# runes collection status, both for individual players and clan as a whole

foreach my $ms (@$milestones) {
  next if $ms->{type} ne 'rune';
  $ms->{milestone} =~ /\b(\w+)\srune\b/;
  my $rune = $1;
  my $clan = $cfg2->plr_to_clan->{$ms->{name}};
  $data{clans}{$clan}{runes}{$rune}++;
  $data{players}{$ms->{name}}{runes}{$rune}++;
}

#--- god maxpiety ------------------------------------------------------------

foreach my $ms (@$milestones) {
  next if $ms->{type} ne 'god.maxpiety';
  my $clan = $cfg2->plr_to_clan->{$ms->{name}};
  $data{clans}{$clan}{godpiety}{$ms->{god}}++;
  $data{players}{$ms->{name}}{godpiety}{$ms->{god}}++;
}

#--- god won -----------------------------------------------------------------

# Xom and Gozag are won only when the player never worships any other god.
# Other gods are won when player reaches 6* piety and then wins

foreach my $g (@$games) {
  next if $g->{ktyp} ne 'winning';
  my $god = $g->{god};
  my $clan = $cfg2->plr_to_clan->{$g->{name}};
  if(!$god) {
    if(check_atheist(\%data, $g)) {
      $data{clans}{$clan}{godwin}{'No god'}++;
      $data{players}{$g->{name}}{godwin}{'No god'}++;
    }
  } elsif($god eq 'Xom' || $god eq 'Gozag') {
    if(check_god_exclusivity(\%data, $g)) {
      $data{clans}{$clan}{godwin}{$god}++;
      $data{players}{$g->{name}}{godwin}{$god}++;
    }
  } else {
    if(check_god_maxpiety(\%data, $g)) {
      $data{clans}{$clan}{godwin}{$god}++;
      $data{players}{$g->{name}}{godwin}{$god}++;
    }
  }
}

#--- uniques -----------------------------------------------------------------

# uniques harvest status, both for individual players and clan as a whole

foreach my $clan ($cfg2->clans) {
  $data{clans}{$clan}{uniques} = {};
}

foreach my $player ($cfg2->players) {
  $data{players}{$player}{uniques} = {};
}

foreach my $ms (@$milestones) {
  next if $ms->{type} ne 'uniq';
  my $clan = $cfg2->plr_to_clan->{$ms->{name}};
  my $msg = $ms->{milestone};
  $msg =~ s/\d+-headed\s//;
  $msg =~ s/Royal Jelly/royal jelly/;
  $msg =~ /killed\s(.*)$/;
  my $unique = $1;
  next if !$unique;
  # mapping unique names
  $unique = $cfg->{game}{uniquesmap}{$unique} if (
    exists $cfg->{game}{uniquesmap}
    && exists $cfg->{game}{uniquesmap}{$unique}
  );
  $data{clans}{$clan}{uniques}{$unique}++;
  $data{players}{$ms->{name}}{uniques}{$unique}++;
}

#--- generation time, phase ---------------------------------------------------

$data{gentime} = $cfg2->now->strftime('%Y-%m-%d %H:%M:%S');
$data{phase} = $cfg2->phase;

#--- countdown

# format the actual countdown string for server-side rendered countdown and
# create list of countdown targets (in epoch format) for the front-side
# countdown JavaScript code

my @count_to = $cfg2->count_to;

if($data{phase} ne 'after') {
  use integer;

  my $s = $cfg2->now->delta_seconds($count_to[0]);
  my $d = $s / 86400; $s %= 86400;
  my $h = $s / 3600; $s %= 3600;
  my $m = $s / 60; $s %= 60;

  if($d) {
    $data{countdown} = sprintf('%dd, %02d:%02d:%02d', $d, $h, $m, $s);
  } else {
    $data{countdown} = sprintf('%02d:%02d:%02d', $h, $m, $s);
  }
} else {
  $data{countdown} = sprintf('%02d:%02d:%02d', 0, 0, 0);
}
$data{count_to} = join(',', map { $_->epoch } @count_to);


#=== generate HTML pages ======================================================

my $tt = Template->new(
  'OUTPUT_PATH' => $cfg->{htmldir},
  'INCLUDE_PATH' => 'templates',
  'RELATIVE' => 1
);

$tt->process(
  'index.tt',
  \%data,
  'index.html'
) or die;

foreach my $clan ($cfg2->clans) {
  $data{clan} = $clan;
  $data{clanname} = $cfg->{clans}{$clan}{name};
  $tt->process(
    'clan.tt',
    \%data,
    "clan-$clan.html"
  ) or die;

  $tt->process(
    'games.tt',
    \%data,
    "games-$clan.html"
  ) or die;
}

foreach my $player ($cfg2->players) {
  $data{player} = $player;
  $data{clan} = $cfg2->plr_to_clan->{$player};
  $data{clanname} = $cfg->{clans}{$data{clan}}{name};
  $tt->process(
    'player.tt',
    \%data,
    "$player.html"
  ) or die;
}

#=== save state ===============================================================

say "Saving state";

my $state_new = $state_file->sibling($state_file->basename . ".$$");
$state_new->spew_raw($js->encode($state));
$state_new->move($state_file);
