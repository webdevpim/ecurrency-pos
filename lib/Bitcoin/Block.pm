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
    time        => TIMESTAMP,
    bits        => NUMERIC,
    nonce       => NUMERIC,
    scanned     => NUMERIC,
    hash        => BINARY,
    prev_hash   => BINARY,
    merkle_root => BINARY,
};
use constant PRIMARY_KEY => 'height';

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

sub hash_str {
    my $self = shift;
    return unpack("H*", substr($self->hash, 0, 4));
}

1;
