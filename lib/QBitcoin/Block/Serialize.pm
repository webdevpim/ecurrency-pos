package QBitcoin::Block::Serialize;
use warnings;
use strict;

use Role::Tiny;

# TODO: Change these stubs to correct serialize methods (to binary data)
use Digest::SHA qw(sha256);

sub serialize {
    my $self = shift;

    return join(' ', $self->height, $self->weight, $self->prev_hash ? unpack("H*", $self->prev_hash) : '', $self->self_weight) . "\n";
}

sub deserialize {
    my $class = shift;
    my ($block_data) = @_;
    my ($height, $weight, $prev_hash, $self_weight) = split(/\s+/, $block_data);
    return $class->new({
        height      => $height,
        weight      => $weight,
        prev_hash   => $prev_hash ? pack("H*", $prev_hash) : undef,
        hash        => $class->calculate_hash($block_data),
        self_weight => $self_weight,
    });
}

sub calculate_hash {
    my $class = shift;
    my ($data) = @_;
    return sha256($data);
}

1;
