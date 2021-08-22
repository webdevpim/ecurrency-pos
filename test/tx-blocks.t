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
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Protocol;
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::Generate;

#$config->{verbose} = 1;

my $protocol_module = Test::MockModule->new('QBitcoin::Protocol');
$protocol_module->mock('send_message', sub { 1 });

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('self_weight', \&mock_self_weight);
my $block_hash;
$block_module->mock('calculate_hash', sub { $block_hash });

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });

my $peer = QBitcoin::Protocol->new(state => STATE_CONNECTED, ip => '127.0.0.1');

sub mock_self_weight {
    my $self = shift;
    return $self->{self_weight} //= !defined($self->weight) ? 10 :
        $self->prev_block ? $self->weight - $self->prev_block->weight : $self->weight;
}

sub make_tx {
    state $value = 10;
    state $tx_num = 1;
    my $tx = QBitcoin::Transaction->new(
        out           => [ QBitcoin::TXO->new_txo( value => $value, open_script => "txo_$tx_num" ) ],
        in            => [],
        coins_created => $value,
    );
    $value += 10;
    $tx_num++;
    my $tx_data = $tx->serialize;
    $tx->hash = QBitcoin::Transaction::calculate_hash($tx_data);
    $peer->cmd_tx($tx_data);
    return $tx;
}

sub send_block {
    my ($height, $hash, $prev_hash, $weight, $tx) = @_;
    my $block = QBitcoin::Block->new(
        height       => $height,
        hash         => $hash,
        prev_hash    => $prev_hash,
        transactions => [ $tx ],
        weight       => $weight,
    );
    $block->add_tx($tx);
    $block->merkle_root = $block->calculate_merkle_root();
    my $block_data = $block->serialize;
    $block_hash = $block->hash;
    $peer->cmd_block($block_data);
}

my $test_tx = make_tx;
# height, hash, prev_hash, weight, $tx
send_block(0, "a0", undef, 50, make_tx);
send_block($_, "a$_", "a" . ($_-1), $_*100, make_tx) foreach (1 .. 10);
send_block(11, "a11", "a10", 1100, $test_tx);
send_block(11, "b11", "a10", 1150, make_tx);
$block_hash = "b12";
QBitcoin::Generate->generate(12);
send_block($_, "b$_", "b" . ($_-1), $_*100+50, make_tx) foreach (13 .. 20);

my $height = QBitcoin::Block->blockchain_height;
my $weight = QBitcoin::Block->best_weight;
my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
my $hash   = $block ? $block->hash : undef;
is($height,   20, "height");
is($hash,  "b20", "hash"  );
is($weight, 2050, "weight");

done_testing();
