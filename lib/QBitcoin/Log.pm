package QBitcoin::Log;
use warnings;
use strict;

use Exporter qw(import);
our @EXPORT = qw(Log);

use Sys::Syslog qw(:standard :macros);
use POSIX qw(strftime);
use Time::HiRes;

openlog('qbitcoin', 'nofatal,pid', LOG_LOCAL0) unless $ENV{LOG_STDOUT};

sub Logf {
    my ($prio, $format, @args) = @_;
    if ($ENV{LOG_STDOUT}) {
        my $t = Time::HiRes::time();
        printf "%s.%03d $format\n", strftime("%F %T", gmtime($t)), ($t-int($t)) * 1000, @args;
    }
    elsif (!$ENV{LOG_NULL}) {
        syslog($prio, $format, @args);
    }
}

sub Log {
    my ($prio, $line) = @_;

    defined($line) or die "Log line undefined";
    @_ == 2 or die "Extra params for Log";
    Logf($prio, '%s', $line);
}

# generate functions Debug(), Debugf(), Info(), Infof(), ...
foreach my $level (qw(debug info notice warning err crit)) {
    push @EXPORT, 'LOG_' . uc $level;
    my $func = ucfirst $level;
    my $funcf = $func . 'f';
    push @EXPORT, $func, $funcf;
    no strict 'refs';
    *$func = sub { Log($level, @_) };
    *$funcf = sub { Logf($level, @_) };
}

1;
