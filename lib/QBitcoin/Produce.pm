package QBitcoin::Produce;
use warnings;
use strict;
use feature 'state';

# This module is for testing only!
# It generate random coinbase transactions (without inputs) and other mempool transactions

use List::Util qw(sum shuffle);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Transaction;
use QBitcoin::TXO;
use QBitcoin::OpenScript;
use QBitcoin::MyAddress qw(my_address);

use constant {
    MAX_MY_UTXO  => 8,
    MY_UTXO_PROB => 10 * BLOCK_INTERVAL, # probability 1/2 for generating 1 utxo per 10 blocks
    TX_FEE_PROB  =>  2 * BLOCK_INTERVAL, # probability 1/2 for generating 1 tx with fee >0 per 2 blocks
    TX_ZERO_PROB =>  2 * BLOCK_INTERVAL, # probability 1/2 for generating 1 tx with 0 fee per 2 blocks
    FEE_MY_TX    => 0.1,
};

sub produce {
    my $class = shift;
    my $time = time();
    state $prev_run = $time;
    return if $prev_run >= $time;
    my $period = ($time - $prev_run);
    $prev_run = $time;

    if (QBitcoin::TXO->my_utxo() < MAX_MY_UTXO) {
        my $prob = 1 - 1 / 2**($period / MY_UTXO_PROB);
        _produce_my_utxo() if $prob > rand();
    }
    {
        my $prob = 1 - 1 / 2**($period / TX_FEE_PROB);
        _produce_tx(0.1) if $prob > rand();
    }
    {
        my $prob = 1 - 1 / 2**($period / TX_ZERO_PROB);
        _produce_tx(0) if $prob > rand();
    }
}

sub _produce_my_utxo {
    my ($my_address) = my_address(); # first one
    state $last_time = 0;
    my $time = int(time()) - GENESIS_TIME;
    $last_time = $last_time < $time ? $time : $last_time+1;
    my $out = QBitcoin::TXO->new(
        value       => $last_time, # vary for get unique hash for each coinbase transaction
        num         => 0,
        open_script => QBitcoin::OpenScript->script_for_address($my_address, 1),
    );
    my $tx = QBitcoin::Transaction->new(
        in  => [],
        out => [ $out ],
        fee => 0,
    );
    $tx->hash = QBitcoin::Transaction->calculate_hash($tx->serialize);
    QBitcoin::Generate::sign_my_transaction($tx);
    $tx->out->[0]->tx_in = $tx->hash;
    $tx->out->[0]->save;
    $tx->size = length $tx->serialize;
    if ($tx->validate() != 0) {
        Errf("Produced incorrect coinbase transaction");
        return;
    }
    $tx->receive();
    $out->add_my_utxo();
    Noticef("Produced coinbase transaction %s", $tx->hash_out);
    return $tx;
}

sub _produce_tx {
    my ($fee_part) = @_;
    my @txo = shuffle(QBitcoin::TXO->find(tx_out => undef, -limit => 100))
        or return;
    @txo = splice(@txo, 0, 2);
    my $amount = sum map { $_->value } @txo;
    my $fee = int($amount * $fee_part);
    my $address = $txo[0]->open_script; # fake; out to the address from first input txo
    my $out = QBitcoin::TXO->new(
        value       => $amount - $fee,
        num         => 0,
        open_script => QBitcoin::OpenScript->script_for_address($address, 1),
    );
    my $tx = QBitcoin::Transaction->new(
        in  => [ map { txo => $_, close_script => $_->open_script }, @txo ],
        out => [ $out ],
        fee => $fee,
    );
    $tx->hash = QBitcoin::Transaction->calculate_hash($tx->serialize);
    QBitcoin::Generate::sign_my_transaction($tx); # fake; it's not my transaction
    $tx->out->[0]->tx_in = $tx->hash;
    $tx->out->[0]->save;
    $tx->size = length $tx->serialize;
    if ($tx->validate() != 0) {
        Errf("Produced incorrect transaction");
        return;
    }
    $tx->receive();
    if ($out->is_my) {
        $out->add_my_utxo();
    }
    Noticef("Produced transaction %s", $tx->hash_out);
    return $tx;
}

1;
