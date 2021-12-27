#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::Protocol;
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::TXO;

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => IPV6_V4_PREFIX . pack("C4", split(/\./, "127.0.0.1")));
my $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);

sub send_block {
    my ($height, $hash, $prev_hash, $weight, @tx) = @_;
    my $block = QBitcoin::Block->new(
        time         => GENESIS_TIME + $height * BLOCK_INTERVAL * FORCE_BLOCKS,
        hash         => $hash,
        prev_hash    => $prev_hash,
        transactions => \@tx,
        weight       => $weight,
    );
    $block->add_tx($_) foreach @tx;
    $block->merkle_root = $block->calculate_merkle_root();
    my $block_data = $block->serialize;
    block_hash($block->hash);
    $connection->protocol->cmd_block($block_data);
}

sub pending_one {
    my $coinbase_tx = make_tx(undef, 0);
    my $test_tx = make_tx($coinbase_tx, 0);
    my $tx = make_tx;
    # height, hash, prev_hash, weight, $tx
    send_block(0, "a0", undef, 50, $tx);
    my $zero_ip = "\x00"x16;
    $connection->protocol->command = "tx";
    $connection->protocol->cmd_tx($tx->serialize . $zero_ip);
    $connection->protocol->cmd_tx($test_tx->serialize . $zero_ip);
    $connection->protocol->cmd_tx($coinbase_tx->serialize . $zero_ip);
    QBitcoin::Transaction->cleanup_mempool();
    send_block(1, "a1", "a0", 100, $coinbase_tx, $test_tx);
    $connection->protocol->cmd_tx($test_tx->serialize . $zero_ip);
    $connection->protocol->cmd_tx($coinbase_tx->serialize . $zero_ip);

    my $height = QBitcoin::Block->blockchain_height;
    my $weight = QBitcoin::Block->best_weight;
    my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
    my $hash   = $block ? $block->hash : undef;
    is($height,   1, "height");
    is($hash,  "a1", "hash"  );
    is($weight, 100, "weight");
    is(scalar(@{$block->transactions}), 2, "transactions");
}

sub pending_two {
    my $coinbase_tx = make_tx(undef, 0);
    my $tx = make_tx();
    my $test_tx = make_tx([ $coinbase_tx, $tx ], 0);
    # height, hash, prev_hash, weight, $tx
    my $zero_ip = "\x00"x16;
    $connection->protocol->command = "tx";
    $connection->protocol->cmd_tx($test_tx->serialize . $zero_ip);
    $connection->protocol->cmd_tx($coinbase_tx->serialize . $zero_ip);
    QBitcoin::Transaction->cleanup_mempool();
    send_block(1, "b1", "a0", 300, $coinbase_tx, $tx, $test_tx);
    $connection->protocol->cmd_tx($test_tx->serialize . $zero_ip);
    $connection->protocol->cmd_tx($tx->serialize . $zero_ip);
    $connection->protocol->cmd_tx($coinbase_tx->serialize . $zero_ip);

    my $height = QBitcoin::Block->blockchain_height;
    my $weight = QBitcoin::Block->best_weight;
    my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
    my $hash   = $block ? $block->hash : undef;
    is($height,   1, "height");
    is($hash,  "b1", "hash"  );
    is($weight, 300, "weight");
    is(scalar(@{$block->transactions}), 3, "transactions");
}

pending_one();
pending_two();
done_testing();
