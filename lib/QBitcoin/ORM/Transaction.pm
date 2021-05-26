package QBitcoin::ORM::Transaction;
use warnings;
use strict;

use QBitcoin::Log;
use QBitcoin::ORM qw(dbh DEBUG_ORM);

my $SQL_TRANSACTION;

sub new {
    my $class = shift;
    die "Nested sql transactions\n" if $SQL_TRANSACTION;
    DEBUG_ORM && Debug("Start sql transaction");
    $SQL_TRANSACTION = 1;
    dbh->begin_work;
    return bless {}, $class; # just guard object
}

sub commit {
    my $self = shift;
    die "commit without sql transaction\n" unless $SQL_TRANSACTION;
    dbh->commit;
    DEBUG_ORM && Debug("Commit sql transaction");
    undef $SQL_TRANSACTION;
}

sub DESTROY {
    my $self = shift;
    Err("Destroy sql transaction without commit") if $SQL_TRANSACTION;
    undef $SQL_TRANSACTION;
}

1;
