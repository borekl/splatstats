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
      && $_->{god} ne $god
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
      && $g->{type} =~ /^god\./
    } @{$data->{milestones}}
  ) {
    return 0
  } else {
    return 1
  }
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

#--- resolve "now" moment ----------------------------------------------------

my $now = time();
my $end_of_tourney = $cfg->{match}{end}->epoch;
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

#--- list of clan games sorted by end time -----------------------------------

$data{clan}{games} = [
  sort { $b->{end_epoch} <=> $a->{end_epoch} } @$games
];

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
    if(!exists $data{games}{by_start}{$ms->{start_epoch}}) {
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

#--- wins by xl --------------------------------------------------------------

$data{games}{xlwins} = [
  sort {
    if($a->{xl} == $b->{xl}) {
      $a->{turn} <=> $b->{turn}
    } else {
      $a->{xl} <=> $b->{xl}
    }
  } grep {
    $_->{ktyp} eq 'winning'
  } @$games
];

#--- first runes by xl -------------------------------------------------------

$data{games}{xlrunes} = [
  sort {
    if($a->{xl} == $b->{xl}) {
      $a->{turn} <=> $b->{turn}
    } else {
      $a->{xl} <=> $b->{xl}
    }
  } grep {
    $_->{type} eq 'rune'
    && $_->{urune} == 1
  } @$milestones
];

#--- runes -------------------------------------------------------------------

# runes collection status, both for individual players and clan as a whole

foreach my $ms (@$milestones) {
  next if $ms->{type} ne 'rune';
  $ms->{milestone} =~ /\b(\w+)\srune\b/;
  my $rune = $1;
  $data{clan}{runes}{$rune}++;
  $data{players}{$ms->{name}}{runes}{$rune}++;
}

#--- uniques -----------------------------------------------------------------

# uniques harvest sttus, both for individual players and clan as a whole

foreach my $ms (@$milestones) {
  next if $ms->{type} ne 'uniq';
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
  $data{clan}{uniques}{$unique}++;
  $data{players}{$ms->{name}}{uniques}{$unique}++;
}

#--- god maxpiety ------------------------------------------------------------

foreach my $ms (@$milestones) {
  next if $ms->{type} ne 'god.maxpiety';
  $data{clan}{godpiety}{$ms->{god}}++;
  $data{players}{$ms->{name}}{godpiety}{$ms->{god}}++;
}

#--- god won -----------------------------------------------------------------

# Xom and Gozag are won only when the player never worships any other god.
# Other gods are won when player reaches 6* piety and then wins

foreach my $g (@$games) {
  next if $g->{ktyp} ne 'winning';
  my $god = $g->{god};
  if(!$god) {
    if(check_atheist(\%data, $g)) {
      $data{clan}{godwin}{'No god'}++;
      $data{players}{$g->{name}}{godwin}{'No god'}++;
    }
  } elsif($god eq 'Xom' || $god eq 'Gozag') {
    if(check_god_exclusivity(\%data, $g)) {
      $data{clan}{godwin}{$god}++;
      $data{players}{$g->{name}}{godwin}{$god}++;
    }
  } else {
    if(check_god_maxpiety(\%data, $g)) {
      $data{clan}{godwin}{$god}++;
      $data{players}{$g->{name}}{godwin}{$god}++;
    }
  }
}

#--- best player games -------------------------------------------------------

# initialize the players.PLR.games.all lists
foreach my $plr (@{$cfg->{match}{members}}) {
  $data{players}{$plr}{games} = { all => [], by_score => [] };
}

# create per-player game lists
foreach my $g (@$games) {
  push(@{$data{players}{$g->{name}}{games}{all}}, $g);
}

# sort per-player game lists by score
foreach my $plr (@{$cfg->{match}{members}}) {
  $data{players}{$plr}{games}{by_score} =
  [ sort { $b->{sc} <=> $a->{sc} } @{$data{players}{$plr}{games}{all}} ]
}

#--- generation time

$now = Time::Moment->now_utc;
$data{gentime} = $now->strftime('%Y-%m-%d %H:%M:%S');

#--- tournament phase and future countdown targets

# following code find at what timepoint in relation to the tournament we are
# (before, during, after); and also creates a list (@count_to) of future
# countdown targets; if we are before the tournament, there are two targets
# (the start and the end), if we are during the tournament, then there is only
# one (the end); if we are after, there are none

my @count_to;

if($now < $cfg->{match}{start}) {
  $data{phase} = 'before';
  @count_to = @{$cfg->{match}}{'start','end'};
} elsif($cfg->{match}{end} <= $now) {
  $data{phase} = 'after';
} else {
  $data{phase} = 'during';
  @count_to = ($cfg->{match}{end});
}

#--- countdown

# format the actual countdown string for server-side rendered countdown and
# create list of countdown targets (in epoch format) for the front-side
# countdown JavaScript code

if($data{phase} ne 'after') {
  my ($dy, $h, $d, $s) = (
    $now->delta_days($count_to[0]),
    $now->delta_hours($count_to[0]) % 24,
    $now->delta_minutes($count_to[0]) % 60,
    $now->delta_seconds($count_to[0]) % 60,
  );

  if($dy) {
    $data{countdown} = sprintf('%dd, %02d:%02d:%02d', $dy, $h, $d, $s);
  } else {
    $data{countdown} = sprintf('%02d:%02d:%02d', $h, $d, $s);
  }
} else {
  $data{countdown} = sprintf('%02d:%02d:%02d', 0, 0, 0);
}
$data{count_to} = join(',', map { $_->epoch } @count_to);

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

$tt->process(
  'games.tt',
  \%data,
  'games.html'
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
