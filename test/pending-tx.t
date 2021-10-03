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
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::Generate;
use QBitcoin::Crypto qw(hash160);
use QBitcoin::Script::OpCodes qw(:OPCODES);
use Bitcoin::Serialized;

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => IPV6_V4_PREFIX . pack("C4", split(/\./, "127.0.0.1")));
my $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);

sub make_tx {
    my ($prev_tx, $fee) = @_;
    state $value = 10;
    state $tx_num = 1;
    my $val = $prev_tx ? $prev_tx->out->[0]->value : $value;
    $fee //= 0;
    my @out;
    my @in;
    push @in, { txo => $prev_tx->out->[0], siglist => [] } if $prev_tx;
    my $script = OP_1;
    my $out = QBitcoin::TXO->new_txo( value => $val - $fee, scripthash => hash160($script), redeem_script => $script, num => 0 );
    my $tx = QBitcoin::Transaction->new(
        out => [ $out ],
        in  => \@in,
        $prev_tx ? () : ( coins_created => $val ),
    );
    $value += 10;
    $tx_num++;
    $out->tx_in = $tx->calculate_hash;
    return $tx;
}

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

my $stake_tx = make_tx(undef, -2);
my $test_tx = make_tx($stake_tx, 2);
my $tx = make_tx;
# height, hash, prev_hash, weight, $tx
send_block(0, "a0", undef, 50, $tx);
my $zero_ip = "\x00"x16;
$connection->protocol->command = "tx";
$connection->protocol->cmd_tx($tx->serialize . $zero_ip);
$connection->protocol->cmd_tx($test_tx->serialize . $zero_ip);
$connection->protocol->cmd_tx($stake_tx->serialize . $zero_ip);
QBitcoin::Transaction->cleanup_mempool();
send_block(1, "a1", "a0", 100, $stake_tx, $test_tx);
$connection->protocol->cmd_tx($test_tx->serialize . $zero_ip);
$connection->protocol->cmd_tx($stake_tx->serialize . $zero_ip);

my $height = QBitcoin::Block->blockchain_height;
my $weight = QBitcoin::Block->best_weight;
my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
my $hash   = $block ? $block->hash : undef;
is($height,   1, "height");
is($hash,  "a1", "hash"  );
is($weight, 100, "weight");
is(scalar(@{$block->transactions}), 2, "transactions");

done_testing();
