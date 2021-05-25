package QBitcoin::Peers;
use warnings;
use strict;

use QBitcoin::Const;

my %PEERS;

sub peers {
    return values %PEERS;
}

sub peer {
    my $class = shift;
    my ($ip) = @_;
    return $PEERS{$ip};
}

sub connected {
    my $class = shift;
    return grep { $_->state eq STATE_CONNECTED } $class->peers;
}

sub add_peer {
    my $class = shift;
    my ($peer) = @_;
    $PEERS{$peer->ip} = $peer;
}

sub del_peer {
    my $class = shift;
    my ($peer) = @_;
    delete $PEERS{$peer->ip};
}

1;
