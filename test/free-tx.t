#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Scalar::Util qw(weaken);
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

# Make TX stored in db, free from memory
my $tx = make_tx;
my $coinbase_tx = make_tx(undef, 0);
my $test_tx = make_tx($coinbase_tx, 0);
# height, hash, prev_hash, weight, $tx
send_block(0, "a0", undef, 50, $tx);
my $zero_ip = "\x00"x16;
$connection->protocol->command = "tx";
$connection->protocol->cmd_tx($coinbase_tx->serialize . $zero_ip);
$connection->protocol->cmd_tx($tx->serialize . $zero_ip);
$connection->protocol->cmd_tx($test_tx->serialize . $zero_ip);
send_block(1, "a1", "a0", 100, $coinbase_tx, $test_tx);
foreach my $n (2 .. 10) {
    QBitcoin::Block->store_blocks();
    send_block($n, "a$n", "a" . ($n-1), $n*100);
}
is(QBitcoin::Block->blockchain_height, 10, "Blockchain built");
is(QBitcoin::Transaction->get($test_tx), undef, "Transaction unloaded");

# Load test transaction
my $loaded_tx = QBitcoin::Transaction->get_by_hash($test_tx->hash);
ok($loaded_tx, "Transaction loaded");
my $tx_ref = $loaded_tx;
weaken($tx_ref);
my $in_ref = $loaded_tx->in->[0]->{txo};
weaken($in_ref);
my $out_ref = $loaded_tx->out->[0];
weaken($out_ref);
undef $loaded_tx;
is($tx_ref,  undef, "Transaction unloaded");
is($in_ref,  undef, "input unloaded");
is($out_ref, undef, "output unloaded");
is(QBitcoin::TXO->get({ tx_out => $coinbase_tx->hash, num => 0 }), undef, "input TXO unloaded");
is(QBitcoin::TXO->get({ tx_out => $test_tx->hash, num => 0 }), undef, "output TXO unloaded");

done_testing();
