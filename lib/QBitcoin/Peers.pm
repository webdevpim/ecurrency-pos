package QBitcoin::Peers;
use warnings;
use strict;

use QBitcoin::Const;

my %PEERS;

sub peers {
    return map { values %$_ } values %PEERS;
}

sub peer {
    my $class = shift;
    my ($ip, $type) = @_;
    return $PEERS{$type}->{$ip};
}

sub connected {
    my $class = shift;
    my ($type) = @_;
    return grep { $_->state eq STATE_CONNECTED } values %{$PEERS{$type}}
}

sub add_peer {
    my $class = shift;
    my ($peer) = @_;
    $PEERS{$peer->type}->{$peer->ip} = $peer;
}

sub del_peer {
    my $class = shift;
    my ($peer) = @_;
    delete $PEERS{$peer->type}->{$peer->ip};
}

1;
