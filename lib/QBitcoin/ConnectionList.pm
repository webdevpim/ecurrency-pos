package QBitcoin::ConnectionList;
use warnings;
use strict;

use QBitcoin::Const;

my %CONNECTIONS; # by type and ip

sub list {
    return map { values %$_ } values %CONNECTIONS;
}

sub get {
    my $class = shift;
    my ($type, $ip) = @_;
    return $CONNECTIONS{$type}->{$ip};
}

sub connected {
    my $class = shift;
    my ($type) = @_;
    return grep { $_->state == STATE_CONNECTED } values %{$CONNECTIONS{$type}};
}

sub add {
    my $class = shift;
    my ($connection) = @_;
    $CONNECTIONS{$connection->type_id}->{$connection->id} = $connection;
}

sub del {
    my $class = shift;
    my ($connection) = @_;
    delete $CONNECTIONS{$connection->type_id}->{$connection->id};
}

1;
