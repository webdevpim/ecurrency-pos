#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
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
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::TXO;
use QBitcoin::Generate;

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => '127.0.0.1');
my $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);
blockchain_synced(1);

sub send_tx {
    my $tx = make_tx();
    $connection->protocol->cmd_tx($tx->serialize . "\x00"x16);
    return $tx;
}

sub send_block {
    my ($height, $hash, $prev_hash, $weight, $tx) = @_;
    my $block = QBitcoin::Block->new(
        time         => GENESIS_TIME + $height * BLOCK_INTERVAL * FORCE_BLOCKS,
        hash         => $hash,
        prev_hash    => $prev_hash,
        transactions => [ $tx ],
        weight       => $weight,
    );
    $block->add_tx($tx);
    $block->merkle_root = $block->calculate_merkle_root();
    my $block_data = $block->serialize;
    block_hash($block->hash);
    $connection->protocol->cmd_block($block_data);
}

my $test_tx = send_tx();
# height, hash, prev_hash, weight, $tx
send_block(0, "a0", undef, 50, send_tx());
send_block($_, "a$_", "a" . ($_-1), $_*100, send_tx()) foreach (1 .. 10);
send_block(11, "a11", "a10", 1100, $test_tx);
send_block(11, "b11", "a10", 1150, send_tx());
block_hash("b12");
QBitcoin::Generate->generate(GENESIS_TIME + 12 * BLOCK_INTERVAL * FORCE_BLOCKS);
send_block($_, "b$_", "b" . ($_-1), $_*100+50, send_tx()) foreach (13 .. 20);

my $height = QBitcoin::Block->blockchain_height;
my $weight = QBitcoin::Block->best_weight;
my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
my $hash   = $block ? $block->hash : undef;
is($height,   20, "height");
is($hash,  "b20", "hash"  );
is($weight, 2050, "weight");

done_testing();
