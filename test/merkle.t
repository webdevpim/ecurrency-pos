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
$merkle_module->mock('_merkle_hash', sub { '[' . shift . ']' });

check_merkle([], "\x00" x 32);
check_merkle(["a"], "a"); 
check_merkle([qw(a b)], "[ab]");
check_merkle([qw(a b c)], "[[ab][cc]]");
check_merkle([qw(a b c d)], "[[ab][cd]]");
check_merkle([qw(a b c d e)], "[[[ab][cd]][[ee][ee]]]");
check_merkle([qw(a b c d e f)], "[[[ab][cd]][[ef][ff]]]");

sub check_merkle {
    my ($hashes, $expect) = @_;

    my @tr = map { QBitcoin::Transaction->new(hash => $_) } @$hashes;
    my $block = QBitcoin::Block->new(transactions => \@tr);
    my $merkle_root = $block->calculate_merkle_root;
    is($merkle_root, $expect, @$hashes . " items");
}

done_testing();
