package QBitcoin::Block::Serialize;
use warnings;
use strict;

use Role::Tiny;

use QBitcoin::Const;
use QBitcoin::Crypto qw(hash256);
use Bitcoin::Serialized;

sub serialize {
    my $self = shift;

    return $self->{serialized} //=
        pack("VQ<", $self->height, $self->weight) .
        ( $self->prev_hash // ZERO_HASH ) .
        $self->merkle_root .
        pack("a16", $self->received_from ? $self->received_from->peer_id : "") .
        pack("v", scalar(@{$self->tx_hashes})) .
        join('', @{$self->tx_hashes});
}

sub deserialize {
    my $class = shift;
    my ($data) = @_;
    my $block = $class->new({
        height      => unpack("V",  $data->get(4) // return undef),
        weight      => unpack("Q<", $data->get(8) // return undef),
        prev_hash   => ( $data->get(32) // return undef ),
        merkle_root => ( $data->get(32) // return undef ),
        rcvd        => ( $data->get(16) // return undef ),
        tx_hashes   => [ map { $data->get(32) // return undef } 1 .. unpack("v", $data->get(2) // return undef) ],
    });
    $block->hash = $block->calculate_hash();
    $block->prev_hash = undef if $block->prev_hash eq ZERO_HASH;
    return $block;
}

sub calculate_hash {
    my $self = shift;
    my $data = ($self->prev_hash // ZERO_HASH) . $self->merkle_root .
        pack("VQ<", $self->height, $self->weight);
    return hash256($data);
}

1;
