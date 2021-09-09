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
use QBitcoin::Config;
use QBitcoin::Protocol;
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::Crypto qw(hash160);
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

my $transaction_module = Test::MockModule->new('QBitcoin::Transaction');
$transaction_module->mock('validate_coinbase', sub { 0 });
$transaction_module->mock('coins_created', sub { $_[0]->{coins_created} //= @{$_[0]->in} ? 0 : sum0(map { $_->value } @{$_[0]->out}) });
$transaction_module->mock('serialize_coinbase', sub { "\x00" });
$transaction_module->mock('deserialize_coinbase', sub { unpack("C", shift->get(1)) });

sub mock_self_weight {
    my $self = shift;
    return $self->{self_weight} //=
        $self->prev_block ? $self->weight - $self->prev_block->weight : $self->weight;
}

my $peer = QBitcoin::Protocol->new(state => STATE_CONNECTED, ip => '127.0.0.1');
# height, hash, prev_hash, $tx_num, weight [, self_weight]
send_blocks([ 0, "a0", undef, 0, 50 ]);
send_blocks(map [ $_, "a$_", "a" . ($_-1), 1, $_*100 ], 1 .. 20);
$peer->cmd_ihave(pack("VQ<a32", 20, 20*120-70, "\xaa" x 32));
send_blocks([ 5, "b5", "a4", 1, 450 ]);
send_blocks(map [ $_, "b$_", "b" . ($_-1), 1, $_*120-70 ], 6 .. 19);

sub send_blocks {
    my @blocks = @_;

    state $value = 10;
    foreach my $block_data (@blocks) {
        my $tx_num = $block_data->[3];
        my @tx;
        foreach (1 .. $tx_num) {
            my $tx = QBitcoin::Transaction->new(
                out           => [ QBitcoin::TXO->new_txo( value => $value, scripthash => hash160("txo_$tx_num") ) ],
                in            => [],
                coins_created => $value,
            );
            $value += 10;
            $tx->calculate_hash;
            $peer->cmd_tx($tx->serialize);
            push @tx, $tx;
        }

        my $block = QBitcoin::Block->new(
            height       => $block_data->[0],
            hash         => $block_data->[1],
            prev_hash    => $block_data->[2],
            transactions => \@tx,
            weight       => $block_data->[4],
            self_weight  => $block_data->[5],
        );
        $block->merkle_root = $block->calculate_merkle_root();
        my $block_data = $block->serialize;
        $block_hash = $block->hash;
        $peer->cmd_block($block_data);
    }
}

my $height = QBitcoin::Block->blockchain_height;
my $weight = QBitcoin::Block->best_weight;
my $block  = $height ? QBitcoin::Block->best_block($height) : undef;
my $hash   = $block ? $block->hash : undef;
is($height, 19,    "height");
is($hash,   "b19", "hash");
is($weight, 2210,  "weight");

send_blocks(map [ $_, "b$_", "b" . ($_-1), 1, $_*120-70 ], 21 .. 30);
send_blocks(map [ $_, "b$_", "b" . ($_-1), 1, $_*120-70 ], 20);
send_blocks(map [ $_, "b$_", "b" . ($_-1), 1, $_*120-70 ], 31 .. 35);
my $incore = QBitcoin::Block->min_incore_height;
is($incore, QBitcoin::Block->blockchain_height-INCORE_LEVELS+1, "incore levels");

done_testing();
