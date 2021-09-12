#! /usr/bin/env perl
use warnings;
use strict;
use feature 'state';

use FindBin '$Bin';
use lib ("$Bin/../lib", "$Bin/lib");

use Test::More;
use Test::MockModule;
use List::Util qw(sum0);
use JSON::XS;
use QBitcoin::Test::ORM;
use QBitcoin::Const;
BEGIN { no warnings 'redefine'; *QBitcoin::Const::UPGRADE_POW = sub () { 0 } };
use QBitcoin::Config;
use QBitcoin::Protocol;
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

sub mock_block_serialize {
    my $self = shift;
    varstr(encode_json({
        height      => $self->height+0,
        weight      => $self->weight+0,
        hash        => $self->hash,
        prev_hash   => $self->prev_hash,
        tx_hashes   => $self->tx_hashes,
        merkle_root => $self->merkle_root,
    }));
}

sub mock_block_deserialize {
    my $class = shift;
    my ($data) = @_;
    $class->new(decode_json($data->get_string));
}

my $block_module = Test::MockModule->new('QBitcoin::Block');
$block_module->mock('self_weight', \&mock_self_weight);
my $block_hash;
$block_module->mock('calculate_hash', sub { $block_hash });
$block_module->mock('serialize', \&mock_block_serialize);
$block_module->mock('deserialize', \&mock_block_deserialize);

my $peer = QBitcoin::Protocol->new(state => STATE_CONNECTED, ip => "127.0.0.1");

sub mock_self_weight {
    my $self = shift;
    return $self->{self_weight} //= !defined($self->weight) ? 10 :
        $self->prev_block ? $self->weight - $self->prev_block->weight : $self->weight;
}

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
        height       => $height,
        hash         => $hash,
        prev_hash    => $prev_hash,
        transactions => \@tx,
        weight       => $weight,
    );
    $block->add_tx($_) foreach @tx;
    $block->merkle_root = $block->calculate_merkle_root();
    my $block_data = $block->serialize;
    $block_hash = $block->hash;
    $peer->cmd_block($block_data);
}

my $stake_tx = make_tx(undef, -2);
my $test_tx = make_tx($stake_tx, 2);
my $tx = make_tx;
# height, hash, prev_hash, weight, $tx
send_block(0, "a0", undef, 50, $tx);
$peer->cmd_tx($tx->serialize);
$peer->cmd_tx($test_tx->serialize);
$peer->cmd_tx($stake_tx->serialize);
send_block(1, "a1", "a0", 100, $stake_tx, $test_tx);
$peer->cmd_tx($stake_tx->serialize);
$peer->cmd_tx($test_tx->serialize);

my $height = QBitcoin::Block->blockchain_height;
my $weight = QBitcoin::Block->best_weight;
my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
my $hash   = $block ? $block->hash : undef;
is($height,   1, "height");
is($hash,  "a1", "hash"  );
is($weight, 100, "weight");

done_testing();
