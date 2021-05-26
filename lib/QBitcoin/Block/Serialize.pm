package QBitcoin::Block::Serialize;
use warnings;
use strict;

use Role::Tiny;

# TODO: Change these stubs to effective serialize methods (to packed binary data)
use Digest::SHA qw(sha256);
use JSON::XS;

my $JSON = JSON::XS->new;

sub serialize {
    my $self = shift;

    return $self->{serialized} //=
        $JSON->encode({
            height       => $self->height,
            weight       => $self->weight,
            prev_hash    => $self->prev_hash ? unpack("H*", $self->prev_hash) : undef,
            transactions => [ map { unpack("H*", $_) } @{$self->tx_hashes} ],
            $self->received_from ? ( rcvd => $self->received_from->ip ) : (),
        }) . "\n";
}

sub deserialize {
    my $class = shift;
    my ($block_data) = @_;
    my $decoded = eval { $JSON->decode($block_data) };
    if (!$decoded) {
        Warningf("Incorrect block: %s", $@);
        return undef;
    }
    my $block = $class->new({
        height      => $decoded->{height},
        weight      => $decoded->{weight},
        prev_hash   => $decoded->{prev_hash} ? pack("H*", $decoded->{prev_hash}) : undef,
        rcvd        => $decoded->{rcvd},
        tx_hashes   => [ map { pack("H*", $_) } @{$decoded->{transactions}} ],
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
