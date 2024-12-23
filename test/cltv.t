#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use QBitcoin::Const;
BEGIN { no warnings 'redefine'; *QBitcoin::Const::MAX_EMPTY_TX_IN_BLOCK = sub () { 10 } };
use QBitcoin::Test::ORM;
use QBitcoin::Test::BlockSerialize;
use QBitcoin::Test::MakeTx;
use QBitcoin::Config;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::Protocol;
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::ProtocolState qw(blockchain_synced);
use QBitcoin::TXO;
use QBitcoin::Generate;
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Script::OpCodes qw(:OPCODES);

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

my $prev_tx;

sub send_tx {
    my ($script) = @_;
    my $tx = make_tx($prev_tx, 0, $script);
    $connection->protocol->command("tx");
    $connection->protocol->cmd_tx($tx->serialize . "\x00"x16);
    $prev_tx = $tx;
    return $tx;
}

sub send_block {
    my ($height, $hash, $prev_hash, $weight, $tx) = @_;
    my @tx = ref($tx) eq "ARRAY" ? @$tx : ($tx);
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
    $connection->protocol->command("block");
    $connection->protocol->cmd_block($block_data);
}

# 1. Send tx1 with limited output (min block 6) and tx2 with limit seq output (min seq blocks 3) in block 3
# 2. Send spend-tx1 in block 5; check that the block rejected
# 3. Send spend-tx2 in block 5; check that the block rejected
# 4. Send spend-tx1 and spend-tx2 in block 6; check that the block accepted
# 5. Switch branch to new block 4, spend txs go to mempool
# 6. Generate blocks 5 and 6; check that the both spend txs are in block 6
# 7. Switch branch to new block 3; tx1 and tx2 goes to mempool
# 8. Generate blocks 4, check that it contains tx1 and tx2
# 9. Generate blocks 5, 6 and 7; check that spend-tx1 is in block 6 and spend-tx2 is in block 7

# height, hash, prev_hash, weight, $tx
send_block(0, "a0", undef, 50, send_tx());
send_block(1, "a1", "a0", 100, send_tx());
send_block(2, "a2", "a1", 200, send_tx());
my $tx1 = send_tx(OP_6 . OP_CHECKLOCKTIMEVERIFY . OP_DROP . OP_TRUE);
my $spend_tx1 = send_tx();
$prev_tx = undef;
my $tx2 = send_tx(OP_3 . OP_CHECKSEQUENCEVERIFY . OP_DROP . OP_TRUE);
my $spend_tx2 = send_tx();
$prev_tx = undef;
send_block(3, "a3", "a2", 300, [ $tx1, $tx2 ]);
is(QBitcoin::Block->blockchain_height, 3, "limit transactions confirmed");
my $test_tx = send_tx();
send_block(4, "a4", "a3", 400, $test_tx);
send_block(5, "a5", "a4", 500, $spend_tx1);
is(QBitcoin::Block->blockchain_height, 4, "spend transaction 1 rejected");
send_block(5, "a5", "a4", 500, $spend_tx2);
is(QBitcoin::Block->blockchain_height, 4, "spend transaction 2 rejected");
send_block(5, "a5", "a4", 500, send_tx());
send_block(6, "a6", "a5", 600, [ $spend_tx1, $spend_tx2 ]);
is(QBitcoin::Block->blockchain_height, 6, "spend transactions confirmed");

send_block(4, "b4", "a3", 700, $test_tx);
is(QBitcoin::Block->blockchain_height, 4, "branch switched");

block_hash("b5");
QBitcoin::Generate->generate(GENESIS_TIME + 5 * BLOCK_INTERVAL * FORCE_BLOCKS);

block_hash("b6");
QBitcoin::Generate->generate(GENESIS_TIME + 6 * BLOCK_INTERVAL * FORCE_BLOCKS);

my $stx1 = QBitcoin::Transaction->get_by_hash($spend_tx1->hash);
my $stx2 = QBitcoin::Transaction->get_by_hash($spend_tx2->hash);

is($stx1 && $stx1->block_height, 6, "transaction 1 confirmed");
is($stx2 && $stx2->block_height, 6, "transaction 2 confirmed");

$prev_tx = undef;
send_block(3, "c3", "a2", 1000, send_tx());
block_hash("c4");
QBitcoin::Generate->generate(GENESIS_TIME + 4 * BLOCK_INTERVAL * FORCE_BLOCKS);

$stx1 = QBitcoin::Transaction->get_by_hash($tx1->hash);
$stx2 = QBitcoin::Transaction->get_by_hash($tx2->hash);
is($stx1 && $stx1->block_height, 4, "transaction 1 confirmed");
is($stx2 && $stx2->block_height, 4, "transaction 2 confirmed");

block_hash("c5");
QBitcoin::Generate->generate(GENESIS_TIME + 5 * BLOCK_INTERVAL * FORCE_BLOCKS);
block_hash("c6");
QBitcoin::Generate->generate(GENESIS_TIME + 6 * BLOCK_INTERVAL * FORCE_BLOCKS);
block_hash("c7");
QBitcoin::Generate->generate(GENESIS_TIME + 7 * BLOCK_INTERVAL * FORCE_BLOCKS);

$stx1 = QBitcoin::Transaction->get_by_hash($spend_tx1->hash);
$stx2 = QBitcoin::Transaction->get_by_hash($spend_tx2->hash);

is($stx1 && $stx1->block_height, 6, "transaction 1 confirmed");
is($stx2 && $stx2->block_height, 7, "transaction 2 confirmed");

done_testing();
