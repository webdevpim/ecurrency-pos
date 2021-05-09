package QBitcoin::Peers;
use warnings;
use strict;

my %PEERS;

sub peers {
    return values %PEERS;
}

sub peer {
    my $class = shift;
    my ($ip) = @_;
    return $PEERS{$ip};
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
