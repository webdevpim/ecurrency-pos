package QBitcoin::ORM::Transaction;
use warnings;
use strict;

use QBitcoin::Log;
use QBitcoin::ORM qw($DBH open_db);

sub new {
    my $class = shift;
    die "Nested sql transactions\n" if $DBH;
    $DBH = open_db(1);
    return bless {}, $class; # just guard object
}

sub commit {
    my $self = shift;
    die "commit without sql transaction\n" unless $DBH;
    $DBH->commit;
    undef $DBH;
}

sub DESTROY {
    my $self = shift;
    Errf("Destroy sql transaction without commit") if $DBH;
    undef $DBH;
}

1;
