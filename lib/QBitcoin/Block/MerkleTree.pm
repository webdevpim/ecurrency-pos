package QBitcoin::Block::MerkleTree;
use warnings;
use strict;

# https://en.bitcoinwiki.org/wiki/Merkle_tree

use QBitcoin::Crypto qw(hash256);
use Role::Tiny;

sub _merkle_hash {
    return hash256($_[0] lt $_[1] ? $_[0] . $_[1] : $_[1] . $_[0]);
}

sub _merkle_root {
    my ($level, $start, $hashes) = @_;
    my $cur_hash = $start < @$hashes ? $hashes->[$start] : $hashes->[-1];
    my $level_size = 1;
    for (my $cur_level = 0; $cur_level < $level; $cur_level++) {
        my $next_hash = $start < @$hashes ? _merkle_root($cur_level, $start + $level_size, $hashes) : $cur_hash;
        $cur_hash = _merkle_hash($cur_hash, $next_hash);
    }
    return $cur_hash;
}

sub calculate_merkle_root {
    my $self = shift;
    @{$self->transactions}
        or return "\x00" x 32;
    my @hashes = map { $_->hash } @{$self->transactions};
    my $level = 0;
    my $level_size = 1; # 2**$level
    my $cur_hash = $hashes[0];
    while ($level_size  < @hashes) {
        $cur_hash = _merkle_hash($cur_hash, _merkle_root($level, $level_size, \@hashes));
        ++$level;
        $level_size *= 2;
    }
    return $cur_hash;
}

1;
