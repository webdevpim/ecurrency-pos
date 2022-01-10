#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use List::Util qw(sum0);
use Test::More;
use Test::MockModule;
use QBitcoin::Test::ORM;
use QBitcoin::Test::MakeTx;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::Mempool;

#$config->{debug} = 1;

my $txo_module = Test::MockModule->new('QBitcoin::TXO');
$txo_module->mock('check_script', sub { 0 });
my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => '127.0.0.1');
my $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);

sub send_tx {
    my @prev_tx = @_;
    my $tx = make_tx(\@prev_tx);
    $connection->protocol->command = "tx";
    $connection->protocol->cmd_tx($tx->serialize . "\x00"x16);
    return QBitcoin::Transaction->get($tx->hash);
}

my $tx1 = send_tx();
my $tx2 = send_tx();
my $tx3 = send_tx($tx1);
my $tx4 = send_tx($tx2, $tx3);

# Set $tx1 as spent confirmed
$tx1->block_height = 12;
$tx1->out->[0]->tx_out = "abcd";
# Set $tx2 as confirmed
$tx2->block_height = 12;

QBitcoin::Transaction->cleanup_mempool();

my @mempool = QBitcoin::Mempool->choose_for_block(0, 20, 0);

is(scalar(@mempool), 0, "transactions dropped");

done_testing();
