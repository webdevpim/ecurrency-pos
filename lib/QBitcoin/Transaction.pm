package QBitcoin::Transaction;
use warnings;
use strict;

use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::ORM qw(find :types);

use constant FIELDS => {
    hash         => BINARY,
    block_height => NUMERIC,
    data         => BINARY,
};

my %TRANSACTION;

sub get_by_hash {
    my $class = shift;
    my ($tx_hash) = @_;

    return $TRANSACTION{$tx_hash} // $class->find(hash => $tx_hash);
}

sub serialize {
    my $self = shift;
    ...;
}

sub deserialize {
    my $self = shift;
    ...;
}

sub receive {
    my $self = shift;
    ...;
    $TRANSACTION{$self->hash} = $self;
    return 0;
}

1;
