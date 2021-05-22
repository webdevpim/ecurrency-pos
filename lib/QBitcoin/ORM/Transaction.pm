package QBitcoin::ORM::Transaction;
use warnings;
use strict;

use QBitcoin::Log;
use QBitcoin::ORM qw($DBH open_db DEBUG_ORM);

sub new {
    my $class = shift;
    die "Nested sql transactions\n" if $DBH;
    $DBH = open_db(1);
    DEBUG_ORM && Debug("Start sql transaction");
    return bless {}, $class; # just guard object
}

sub commit {
    my $self = shift;
    die "commit without sql transaction\n" unless $DBH;
    $DBH->commit;
    DEBUG_ORM && Debug("Commit sql transaction");
    undef $DBH;
}

sub DESTROY {
    my $self = shift;
    Err("Destroy sql transaction without commit") if $DBH;
    undef $DBH;
}

1;
