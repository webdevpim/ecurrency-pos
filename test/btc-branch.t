#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM qw(dbh);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Peer;
use QBitcoin::Connection;
use Bitcoin::Block;

#$config->{debug} = 1;

# hash, prev_hash, weight [, self_weight]
send_blocks([
    [ "a1", undef, 100 ],
    [ "a2", "a1",  100 ],
    [ "a3", "a2",  100 ],
], [ 2, "a3", 300 ]);

send_blocks([
    [ "a1", undef, 100 ],
    [ "a2", "a1",  100 ],
    [ "b3", "b2",  100 ],
], [ 1, "a2", 200 ]);

send_blocks([
    [ "a1", undef, 100 ],
    [ "a2", "a1",  100 ],
    [ "a3", "a2",  100 ],
    [ "b2", "a1",  110 ],
    [ "b3", "b2",   80 ],
], [ 2, "a3", 300 ]);

send_blocks([
    [ "a1", undef, 100 ],
    [ "b2", "a1",  110 ],
    [ "b3", "b2",   80 ],
    [ "a2", "a1",  100 ],
    [ "a3", "a2",  100 ],
], [ 2, "a3", 300 ]);

sub send_blocks {
    my ($blocks, $expect) = @_;

    state $peer = QBitcoin::Peer->get_or_create(type_id => PROTOCOL_BITCOIN, state => STATE_CONNECTED, ip => 'btc-test-node');
    state $n=1;
    subtest "branch " . $n++ => sub {
        # Create new blockchain from scratch for each send_blocks() call
        dbh->do("DELETE FROM `" . Bitcoin::Block->TABLE . "`");
        my $connection = QBitcoin::Connection->new(peer => $peer, state => STATE_CONNECTED);

        foreach my $block_data (@$blocks) {
            my $block = Bitcoin::Block->new(
                hash        => $block_data->[0],
                prev_hash   => $block_data->[1] // ZERO_HASH,
                bits        => int((29 << 24) + 0xffff / $block_data->[2] + 0.5),
                time        => time(),
                nonce       => 0,
                version     => 2,
                scanned     => 0,
                merkle_root => ZERO_HASH,
            );
            $connection->protocol->process_btc_block($block)
                && $block->create();
        }
        my ($best_block) = Bitcoin::Block->find(-sortby => 'height DESC', -limit => 1);
        my $height = $best_block ? $best_block->height : undef;
        my $hash   = $best_block ? $best_block->hash : undef;
        my $chaindifficulty = $best_block ? int($best_block->chainwork / 4295032833 + 0.5) : undef;

        is($height,          $expect->[0], "height");
        is($hash,            $expect->[1], "hash");
        is($chaindifficulty, $expect->[2], "chainwork");
    };
}

done_testing();
