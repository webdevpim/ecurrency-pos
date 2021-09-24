package QBitcoin::Block::MerkleTree;
use warnings;
use strict;

# https://en.bitcoinwiki.org/wiki/Merkle_tree

use QBitcoin::Const;
use QBitcoin::Crypto qw(hash256);
use Role::Tiny;

sub _merkle_hash {
    return hash256($_[0] . $_[1]);
}

sub _merkle_root {
    my ($level, $start, $hashes) = @_;
    my $cur_hash = $start < @$hashes ? $hashes->[$start] : $hashes->[-1];
    my $level_size = 1;
    for (my $cur_level = 0; $cur_level < $level; $cur_level++, $level_size *= 2) {
        my $next_hash = $start + $level_size < @$hashes ? _merkle_root($cur_level, $start + $level_size, $hashes) : $cur_hash;
        $cur_hash = _merkle_hash($cur_hash, $next_hash);
    }
    return $cur_hash;
}

sub calculate_merkle_root {
    my $self = shift;
    my $hashes = $self->tx_hashes;
    @$hashes
        or return ZERO_HASH;
    my $level = 0;
    my $level_size = 1; # 2**$level
    my $cur_hash = $hashes->[0];
    while ($level_size < @$hashes) {
        $cur_hash = _merkle_hash($cur_hash, _merkle_root($level, $level_size, $hashes));
        ++$level;
        $level_size <<= 1;
    }
    return $cur_hash;
}

sub merkle_path {
    my $self = shift;
    my ($tx_num) = @_;
    my $hashes = $self->tx_hashes;
    my $level = 0;
    my $level_size = 1; # 2**$level
    my @path;
    while ($level_size < @$hashes) {
        my $start = $level_size * ($tx_num & 1 ? $tx_num-1 : ($tx_num+1) * $level_size > $#$hashes ? $tx_num : $tx_num+1);
        push @path, _merkle_root($level, $start, $hashes);
        ++$level;
        $level_size <<= 1;
        $tx_num >>= 1;
    }
    return join "", @path;
}

sub check_merkle_path {
    my $self = shift;
    my ($hash, $tx_num, $merkle_path) = @_;

    my $cur_hash = $hash;
    my $hashlen = length($cur_hash);
    my $pathlen = length($merkle_path);
    my $ndx = 0;
    while ($ndx < $pathlen) {
        my $next_hash = substr($merkle_path, $ndx, $hashlen);
        $ndx += $hashlen;
        $cur_hash = _merkle_hash($tx_num & 1 ? ( $next_hash, $cur_hash ) : ( $cur_hash, $next_hash ));
        $tx_num >>= 1;
    }
    return $cur_hash eq $self->merkle_root;
}

1;
