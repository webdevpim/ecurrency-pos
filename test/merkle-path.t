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
$merkle_module->mock('_merkle_hash', sub { substr(("[$_[0]$_[1]]" =~ s/\x00//gr) . "\x00" x 32, 0, 32) });

merkle_path(["a"]);
merkle_path([qw(a b)]);
merkle_path([qw(a b c)]);
merkle_path([qw(a b c d)]);
merkle_path([qw(a b c d e)]);
merkle_path([qw(a b c d e f)]);
merkle_path([qw(a b c d e f g)]);
merkle_path([qw(a b c d e f g h i j k)]);

sub merkle_path {
    my ($hashes) = @_;

    map { $_ = substr($_ . "\x00" x 32, 0, 32) } @$hashes;
    my @tr = map { QBitcoin::Transaction->new(hash => $_) } @$hashes;
    my $block = QBitcoin::Block->new(transactions => \@tr);
    my $block2 = QBitcoin::Block->new(merkle_root => $block->calculate_merkle_root);
    foreach my $n (0 .. $#$hashes) {
        my $merkle_path = $block->merkle_path($n);
        # print "Merkle path for " . ($hashes->[$n] =~ s/\x00//gr) . ": " . ($merkle_path =~ s/\x00+/|/gr) . "\n";
        ok($block2->check_merkle_path($hashes->[$n], $n, $merkle_path), "tx " . ($n+1) . "/" . @$hashes);
    }
}

done_testing();
