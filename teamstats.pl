#!/usr/bin/env perl

use strict;
use warnings;
use v5.10;

use Path::Tiny;
use JSON::MaybeXS;
use Time::Moment;
use Try::Tiny;
use Template;
use Getopt::Long;
use Data::Dumper;


#=== globals =================================================================

my $js = JSON::MaybeXS->new(pretty => 1, utf8 => 1);
my $cfg;


#=== command line options ====================================================

my $cmd_retrieve = 1;           # retrieve remote logs
my $cmd_debug = 0;              # debug mode


#=== aux functions ===========================================================

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


#=== command-line processing ==================================================

GetOptions(
  'retrieve!' => \$cmd_retrieve,
  'debug!' => \$cmd_debug
);


#=== load configuration =======================================================

my $config_file = path('config.json');
$cfg = $js->decode($config_file->slurp_raw);

# convert match.start and match.end values into Time::Moment instances
foreach my $t (qw(start end)) {
  if(exists $cfg->{match}{$t}) {
    $cfg->{match}{$t} = Time::Moment->from_string($cfg->{match}{$t});
  }
}

#=== state initialization/loading ============================================

my $state_file = path($cfg->{state});
my $state = {};

if(-f $state_file) {
  say 'State file exists, loading';
  $state = $js->decode($state_file->slurp_raw());
} else {
  $state->{games} = [];
  $state->{milestones} = [];
}


#=== resolve "now" moment ====================================================

my $now = time();
my $end_of_tourney = $cfg->{match}{end}->epoch;
$now = $end_of_tourney if $now > $end_of_tourney;


#=== loading of logfiles =====================================================

if($cmd_retrieve) {

  my $logdir = path($cfg->{logdir});

  foreach my $server (keys %{$cfg->{servers}}) {

    say "Processing $server";

    foreach my $log (qw(log milestones)) {

      # get URL and localfile
      my $url = $cfg->{servers}{$server}{$log}{url};
      my $file = $logdir->child($cfg->{servers}{$server}{$log}{file});

      # get our last position in the file (or 0 if none)
      my $fpos = $state->{servers}{$server}{$log}{fpos} // 0;

      # retrieve new data from URL
      my $r = system(sprintf($cfg->{wget}, $file, $url));
      die "Failed to get $url" if $r;

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
          $row{$fv[0]} = $fv[1];
        }

        $count_total++;

        # check for team members, ignore all other entries
        next if !(grep { $_ eq $row{name} } @{$cfg->{match}{members}});

        # convert dates into epoch/human readble format and match time bracket
        my $tm_start = to_moment($row{start});
        $row{start_epoch} = $tm_start->epoch;
        next if $tm_start < $cfg->{match}{start};
        $row{start_fmt} = $tm_start->strftime('%Y-%m-%d %H:%M:%S');
        if($log eq 'log') {
          my $tm_end = to_moment($row{end});
          last if $tm_end >= $cfg->{match}{end};
          $row{end_epoch} = $tm_end->epoch;
          $row{end_fmt} = $tm_end->strftime('%Y-%m-%d %H:%M:%S');
          $row{dur_fmt} = format_duration($row{dur});
        } else {
          my $tm_time = to_moment($row{time});
          next if $tm_time < $cfg->{match}{start};
          last if $tm_time >= $cfg->{match}{end};
          $row{time_epoch} = to_moment($row{time})->epoch;
          $row{time_from_now} = $now - $row{time_epoch};
          $row{time_from_now_fmt} = format_duration($row{time_from_now});
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

  }

}

#=== processing of data ======================================================

my %data = (
  games => { all => $state->{games} },
  milestones => $state->{milestones},
  cfg => $cfg,
);

my $games = $state->{games};
my $milestones = $state->{milestones};

#--- list of won clan games --------------------------------------------------

my @won = sort {
  $a->{end_epoch} <=> $b->{end_epoch}
} grep {
  $_->{ktyp} eq 'winning'
} @$games;

$data{clan}{won} = \@won;

#--- list of won/all player games ---------------------------------------------

foreach my $pl (@{$cfg->{match}{members}}) {

  $data{players}{$pl}{won} = [
    sort {
      $a->{end_epoch} <=> $b->{end_epoch}
    } grep {
      $_->{ktyp} eq 'winning'
      && $_->{name} eq $pl
    } @$games
  ];

  $data{players}{$pl}{games} = [
    sort {
      $a->{end_epoch} <=> $b->{end_epoch}
    } grep {
      $_->{name} eq $pl
    } @$games
  ];

}

#--- recent clan games -------------------------------------------------------

if(@{$games} <= $cfg->{web}{clanrecent}) {
  $data{clan}{recent} = [ sort {
    $b->{end_epoch} <=> $a->{end_epoch}
  } @$games ];
} else {
  $data{clan}{recent} = [ ( sort {
    $b->{end_epoch} <=> $a->{end_epoch}
}

#--- create index of games by "start" field

my $games_by_start = $data{games}{by_start} = {};
foreach my $g (@{$games}) {
  $games_by_start->{$g->{start}} = $g;
  } @$games )[0..$cfg->{web}{clanrecent}] ];
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

my @clan_in_progress;

foreach my $pl (keys %{$data{players}}) {
  next if !exists $data{players}{$pl}{last_milestones};
  my @plr_in_progress;
  foreach my $srv (keys %{$data{players}{$pl}{last_milestones}}) {
    my $ms = $data{players}{$pl}{last_milestones}{$srv};
    if(!exists $games_by_start->{$ms->{start}}) {
      push(@plr_in_progress, $ms);
      push(@clan_in_progress, $ms);
    }
  }
  if(@plr_in_progress) {
    @plr_in_progress = sort {
      $a->{time_from_now} <=> $b->{time_from_now}
    } @plr_in_progress;
  }
  $data{players}{$pl}{in_progress} = \@plr_in_progress;
}

if(@clan_in_progress) {
  @clan_in_progress = sort {
    $a->{time_from_now} <=> $b->{time_from_now}
  } @clan_in_progress;
}

$data{clan}{in_progress} = \@clan_in_progress;

#--- generate list of games, milestones and used servers by players

my %games_by_players;
my %wins_by_players;
my %milestones_by_players;
my %servers_by_players;
my %player_dumps;

foreach my $plr (@{$cfg->{match}{members}}) {

  # games
  $games_by_players{$plr} = [ sort {
    $a->{end_epoch} <=> $b->{end_epoch}
  } grep {
    $_->{name} eq $plr
  } @$games ];

  # wins
  $wins_by_players{$plr} = [ grep {
    $_->{ktyp} eq 'winning'
  } @{$games_by_players{$plr}} ];

  # milestones
  $milestones_by_players{$plr} = [ sort {
    $a->{time_epoch} <=> $b->{time_epoch}
  } grep {
    $_->{name} eq $plr
  } @$milestones ];

  # servers used by player
  $servers_by_players{$plr} = {};
  $player_dumps{$plr} = {};
  foreach my $ms (@{$milestones_by_players{$plr}}) {
    next if $ms->{type} ne 'begin';
    $servers_by_players{$plr}{$ms->{server}}++;
  }
  $servers_by_players{$plr} = [ sort {
    $servers_by_players{$plr}{$b} cmp $servers_by_players{$plr}{$a}
  } keys %{$servers_by_players{$plr}} ];

  foreach my $server (@{$servers_by_players{$plr}}) {
    $player_dumps{$plr}{$server} = server_url($server, 'dump', $plr);

    $data{players}{$plr}{watchurl}{$server}
    = server_url($server, 'watch', $plr);
  }
}

$data{games}{by_players} = \%games_by_players;
$data{wins}{by_players} = \%wins_by_players;
$data{servers}{by_players} = \%servers_by_players;
$data{player_dumps} = \%player_dumps;

#--- games by turncount ------------------------------------------------------

$data{games}{turncount} = [
  sort {
    $a->{turn} <=> $b->{turn}
  } grep {
    $_->{ktyp} eq 'winning'
  } @$games
];

#--- games by realtime -------------------------------------------------------

$data{games}{realtime} = [
  sort {
    $a->{dur} <=> $b->{dur}
  } grep {
    $_->{ktyp} eq 'winning'
  } @$games
];

#--- games by turncount ------------------------------------------------------

$data{games}{score} = [
  sort {
    $b->{sc} <=> $a->{sc}
  } @$games
];

#--- debug output ------------------------------------------------------------

path("debug.$$")->spew(Dumper(\%data)) if $cmd_debug;


#=== generate HTML pages =====================================================

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

foreach my $pl (@{$cfg->{match}{members}}) {
  $data{player} = $pl;
  $tt->process(
    'player.tt',
    \%data,
    "$pl.html"
  ) or die;
}

#=== save state ==============================================================

if($cmd_retrieve) {
  say "Saving state";

  my $state_new = $state_file->sibling($state_file->basename . ".$$");
  $state_new->spew_raw($js->encode($state));
  $state_new->move($state_file);
}
