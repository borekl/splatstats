package TeamStats::Config;

use v5.10;
use warnings;
use integer;
use strict;

use Moo;
with 'MooX::Singleton';
use experimental 'signatures';

use Carp;
use JSON::MaybeXS;
use Path::Tiny qw(path);

#--- attributes ---------------------------------------------------------------

# configuration file
has config_file => (
  is => 'ro',
  default => 'config.json'
);

# parsed unprocessed configuration
has config => ( is => 'lazy' );

# tournament start/end
has start => ( is => 'lazy' );
has end => ( is => 'lazy' );

# player to clan index
has plr_to_clan => ( is => 'lazy');

#--- attribute builders -------------------------------------------------------

sub _build_config ($self)
{
  my $file = $self->config_file;
  croak "Configuration file '$file' cannot be found or read" unless -e $file;
  my $cfg = JSON->new->relaxed(1)->decode(path($file)->slurp);
  return $cfg;
}

sub _build_start ($self)
{
  my $cfg = $self->config;
  die 'Tournament start not defined' unless $cfg->{tournament}{start};
  return Time::Moment->from_string($cfg->{tournament}{start});
}

sub _build_end ($self)
{
  my $cfg = $self->config;
  die 'Tournament end not defined' unless $cfg->{tournament}{end};
  return Time::Moment->from_string($cfg->{tournament}{end});
}

sub _build_plr_to_clan ($self)
{
  my %player_index;

  foreach my $clan ($self->clans) {
    foreach my $player ($self->players) {
      $player_index{$player} = $clan;
    }
  }

  return \%player_index;
}

#--- methods ------------------------------------------------------------------

sub clans ($self)
{
  my $cfg = $self->config;
  return keys %{$cfg->{clans}};
}

sub players ($self, $clan=undef)
{
  my $cfg = $self->config;

  my @players;
  foreach my $cl ($self->clans) {
    next unless !$clan || $cl eq $clan;
    push(@players, @{$cfg->{clans}{$cl}{members}});
  }

  return @players;
}


#------------------------------------------------------------------------------

1;
