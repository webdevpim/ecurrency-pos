package QBitcoin::Block::MerkleTree;
use warnings;
use strict;

use QBitcoin::Crypto qw(hash256);
use Role::Tiny;

sub _merkle_hash {
    return hash256($_[0]);
}

sub _merkle_root {
    my $self = shift;
    my ($level, $start) = @_;
    my $cur_hash = $start < @{$self->transactions} ? $self->transactions->[$start]->hash : $self->transactions->[-1]->hash;
    my $level_size = 1;
    for (my $cur_level = 0; $cur_level < $level; $cur_level++) {
        my $next_hash = $start < @{$self->transactions} ? $self->_merkle_root($cur_level, $start + $level_size) : $cur_hash;
        $cur_hash = _merkle_hash($cur_hash . $next_hash);
    }
    return $cur_hash;
}

sub calculate_merkle_root {
    my $self = shift;
    @{$self->transactions}
        or return "\x00" x 32;
    my $level = 0;
    my $level_size = 1; # 2**$level
    my $cur_hash = $self->transactions->[0]->hash;
    while ($level_size  < @{$self->transactions}) {
        $cur_hash = _merkle_hash($cur_hash . $self->_merkle_root($level, $level_size));
        ++$level;
        $level_size *= 2;
    }
    return $cur_hash;
}

1;
