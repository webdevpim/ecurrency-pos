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
use QBitcoin::Transaction;
use QBitcoin::Protocol;
use QBitcoin::TXO;

#$config->{debug} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $peer = QBitcoin::Peer->new(type_id => PROTOCOL_QBITCOIN, ip => IPV6_V4_PREFIX . pack("C4", split(/\./, "127.0.0.1")));
my $connection = QBitcoin::Connection->new(state => STATE_CONNECTED, peer => $peer);

my $tx1 = make_tx(undef, -2);
my $tx2 = make_tx($tx1, 2);
my $tx3 = make_tx($tx2);
# height, hash, prev_hash, weight, $tx
my $zero_ip = "\x00"x16;
$connection->protocol->command = "tx";
$connection->protocol->cmd_tx($tx2->serialize . $zero_ip); # pending
$connection->protocol->cmd_tx($tx3->serialize . $zero_ip); # input from pending tx
foreach (1 .. MAX_PENDING_TX+1) {
    my $tx_prev = make_tx(undef, -2);
    my $tx_next = make_tx($tx_prev, 2);
    $connection->protocol->cmd_tx($tx_next->serialize . $zero_ip);
}
# $tx2 should be already dropped here, send it again
eval {
    $connection->protocol->cmd_tx($tx2->serialize . $zero_ip); # pending
};

ok(!$@, "Pending TX dropped correctly");

done_testing();
