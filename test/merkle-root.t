#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib "$Bin/../lib";

use Test::More;
use Test::MockModule;

use QBitcoin::Transaction;
use QBitcoin::Block;

my $merkle_module = Test::MockModule->new('QBitcoin::Block::MerkleTree');
$merkle_module->mock('_merkle_hash', sub { "[$_[0]$_[1]]" });

merkle_root([], "\x00" x 32);
merkle_root(["a"], "a");
merkle_root([qw(a b)], "[ab]");
merkle_root([qw(a b c)], "[[ab][cc]]");
merkle_root([qw(a b c d)], "[[ab][cd]]");
merkle_root([qw(a b c d e)], "[[[ab][cd]][[ee][ee]]]");
merkle_root([qw(a b c d e f)], "[[[ab][cd]][[ef][ef]]]");
merkle_root([qw(a b c d e f g)], "[[[ab][cd]][[ef][gg]]]");
merkle_root([qw(a b c d e f g h i j k)], "[[[[ab][cd]][[ef][gh]]][[[ij][kk]][[ij][kk]]]]");

sub merkle_root {
    my ($hashes, $expect) = @_;

    my @tr = map { QBitcoin::Transaction->new(hash => $_) } @$hashes;
    my $block = QBitcoin::Block->new(transactions => \@tr);
    my $merkle_root = $block->calculate_merkle_root;
    is($merkle_root, $expect, @$hashes . " items");
}

done_testing();
