package Bitcoin::Block;
use warnings;
use strict;

use QBitcoin::Log;
use QBitcoin::Accessors qw(new mk_accessors);
use QBitcoin::ORM qw(:types find create update delete);
use QBitcoin::Crypto qw(hash256);

use constant TABLE => 'btc_block';

use constant FIELDS => {
    version     => NUMERIC,
    height      => NUMERIC,
    time        => NUMERIC,
    bits        => NUMERIC,
    nonce       => NUMERIC,
    chainwork   => NUMERIC,
    scanned     => NUMERIC,
    hash        => BINARY,
    prev_hash   => BINARY,
    merkle_root => BINARY,
};
use constant PRIMARY_KEY => 'hash';

mk_accessors(keys %{&FIELDS});

sub calculate_hash {
    my $self = shift;
    my $data = pack("V", $self->version) . $self->prev_hash . $self->merkle_root .
        pack("VVV", $self->time, $self->bits, $self->nonce);
    return hash256($data);
}

sub deserialize {
    my $class = shift;
    my ($data) = @_;

    if ($data->length < 80) {
        Warningf("Incorrect serialized block header, length %u < 80", $data->length);
        return undef;
    }
    my ($version, $prev_block, $merkle_root, $timestamp, $bits, $nonce) = unpack("Va32a32VVV", $data->get(80));
    my $block = $class->new(
        version     => $version,
        prev_hash   => $prev_block,
        merkle_root => $merkle_root,
        time        => $timestamp,
        bits        => $bits,
        nonce       => $nonce,
    );
    $block->hash = $block->calculate_hash;
    return $block;
}

sub difficulty {
    my $self = shift;
    # https://bitcoin.stackexchange.com/questions/5838/how-is-difficulty-calculated
    # https://www.oreilly.com/library/view/mastering-bitcoin/9781491902639/ch08.html#difficulty_bits
    return 0xffff / ($self->bits & 0xffffff) * (1 << (8*(29 - ($self->bits >> 24))));
}

sub validate {
    my $self = shift;
    # compare hash with bits
    my $bits_coef = $self->bits & 0xffffff;
    my $bits_expo = $self->bits >> 24;
    my $zero_bytes = 32-$bits_expo;
    # hash must have first 8*(32-$bits_expo) zero bits
    substr($self->hash, -$zero_bytes) eq "\x00" x $zero_bytes
        or return 0;
    my $first4 = substr($self->hash, -$zero_bytes-4, 4);
    unpack("V", substr($self->hash, -$zero_bytes-4, 4)) < $bits_coef * 256
        or return 0;
    return 1;
}

sub hash_hex {
    my $self = shift;
    return unpack("H*", scalar reverse $self->hash);
}

sub prev_hash_hex {
    my $self = shift;
    return unpack("H*", scalar reverse $self->prev_hash);
}

1;
