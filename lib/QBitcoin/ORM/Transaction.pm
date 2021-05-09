package QBitcoin::ORM::Transaction;
use warnings;
use strict;

use QBitcoin::Log;
use QBitcoin::ORM qw($DBH);

sub new {
    my $class = shift;
    die "Nested sql transactions\n" if $DBH;
    $DBH = open_db(1); # nocache, prevent keep opened transaction after commit() timeout or something like this
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
    Errf("Destroy sql transaction without commit");
    undef $DBH;
}

1;
