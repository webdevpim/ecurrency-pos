package QBitcoin::Block::Serialize;
use warnings;
use strict;

use Role::Tiny;

# TODO: Change these stubs to correct serialize methods (to binary data)
use Digest::SHA qw(sha256);
use JSON::XS;

my $JSON = JSON::XS->new;

sub serialize {
    my $self = shift;

    return $self->{serialized} //=
        $JSON->encode({
            height       => $self->height,
            weight       => $self->weight,
            prev_hash    => $self->prev_hash,
            self_weight  => $self->self_weight,
            transactions => $self->tx_hashes,
            $self->received_from ? ( rcvd => $self->received_from->ip ) : (),
        });
}

sub deserialize {
    my $class = shift;
    my ($block_data) = @_;
    my $decoded = eval { $JSON->decode($block_data) };
    if (!$decoded) {
        Warningf("Incorrect block: %s", $@);
        return undef;
    }
    utf8::decode($decoded->{prev_hash});
    my $block = $class->new({
        height      => $decoded->{height},
        weight      => $decoded->{weight},
        prev_hash   => $decoded->{prev_hash},
        self_weight => $decoded->{self_weight},
        rcvd        => $decoded->{rcvd},
        tx_hashes   => $decoded->{transactions},
    });
    $block->hash = $block->calculate_hash;
    return $block;
}

sub calculate_hash {
    my $self = shift;
    # TODO: use packed binary $data
    my $data = join('|', $self->height, $self->weight, $self->prev_hash // "\x00"x8, @{$self->tx_hashes});
    return sha256($data);
}

1;
