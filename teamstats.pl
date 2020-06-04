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


#=== globals =================================================================

my $js = JSON::MaybeXS->new(pretty => 1, utf8 => 1);


#=== command line options ====================================================

my $cmd_retrieve = 1;           # retrieve remote logs


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


#=== command-line processing ==================================================

GetOptions('retrieve!' => \$cmd_retrieve);


#=== load configuration =======================================================

my $config_file = path('config.json');
my $cfg = $js->decode($config_file->slurp_raw);

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

        # convert dates into epoch format
        if($log eq 'log') {
          my $tm_start = to_moment($row{start});
          next if $tm_start < $cfg->{match}{start};
          $row{start_epoch} = $tm_start->epoch;
          my $tm_end = to_moment($row{end});
          next if $tm_end >= $cfg->{match}{end};
          $row{end_epoch} = $tm_end->epoch;
        } else {
          my $tm_time = to_moment($row{time});
          next if $tm_time < $cfg->{match}{start} || $tm_time >= $cfg->{match}{end};
          $row{time_epoch} = to_moment($row{time})->epoch;
        }

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
  games => $state->{games},
  milestones => $state->{milestones},
  cfg => $cfg,
);

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


#=== save state ==============================================================

if($cmd_retrieve) {
  say "Saving state";

  my $state_new = $state_file->sibling($state_file->basename . ".$$");
  $state_new->spew_raw($js->encode($state));
  $state_new->move($state_file);
}
