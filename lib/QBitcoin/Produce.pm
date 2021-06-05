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

sub probability {
    my ($period, $half_period) = @_;
    # If $period == $half, probability is 1/2
    return $period > $half_period ? 1 - 1 / 2**($period / $half_period) : $period / $half_period / 2;
}

sub produce {
    my $class = shift;
    my $time = time();
    state $prev_run = $time;
    return if $prev_run >= $time;
    my $period = ($time - $prev_run);
    $prev_run = $time;

    if (QBitcoin::TXO->my_utxo() < MAX_MY_UTXO) {
        my $prob = probability($period, MY_UTXO_PROB);
        _produce_my_utxo() if $prob > rand();
    }
    {
        my $prob = probability($period, TX_FEE_PROB);
        _produce_tx(0.03) if $prob > rand();
    }
    {
        my $prob = probability($period, TX_ZERO_PROB);
        _produce_tx(0) if $prob > rand();
    }
}

sub _produce_my_utxo {
    my ($my_address) = my_address(); # first one
    state $last_time = 0;
    my $time = time();
    my $age = int($time - GENESIS_TIME);
    $last_time = $last_time < $age ? $age : $last_time+1;
    my $out = QBitcoin::TXO->new_txo(
        value       => $last_time, # vary for get unique hash for each coinbase transaction
        open_script => scalar(QBitcoin::OpenScript->script_for_address($my_address->address)),
    );
    my $tx = QBitcoin::Transaction->new(
        in            => [],
        out           => [ $out ],
        fee           => 0,
        received_time => $time,
    );
    $tx->sign_transaction();
    QBitcoin::TXO->save_all($tx->hash, $tx->out);
    $tx->size = length $tx->serialize;
    if ($tx->validate() != 0) {
        Errf("Produced incorrect coinbase transaction");
        return;
    }
    $tx->receive();
    Noticef("Produced coinbase transaction %s", $tx->hash_str);
    $tx->announce();
    return $tx;
}

sub _produce_tx {
    my ($fee_part) = @_;

    my @txo = QBitcoin::TXO->find(tx_out => undef, -limit => 100);
    # Exclude loaded txo to avoid double-spend
    # b/c its may be included as input into another mempool transaction
    @txo = shuffle grep { !$_->is_cached } @txo
        or return;
    @txo = splice(@txo, 0, 2);
    $_->save foreach grep { !$_->is_cached } @txo;
    my $amount = sum map { $_->value } @txo;
    my $fee = int($amount * $fee_part);
    my $address = QBitcoin::MyAddress->get_by_script($txo[0]->open_script);
    my $out = QBitcoin::TXO->new_txo(
        value       => $amount - $fee,
        open_script => QBitcoin::OpenScript->script_for_address($address->address),
    );
    my $tx = QBitcoin::Transaction->new(
        in            => [ map { txo => $_, close_script => $_->open_script }, @txo ],
        out           => [ $out ],
        fee           => $fee,
        received_time => time(),
    );
    $tx->sign_transaction; # fake; it's not my transaction
    QBitcoin::TXO->save_all($tx->hash, $tx->out);
    $tx->size = length $tx->serialize;
    $_->del_my_utxo() foreach grep { $_->is_my } @txo;
    if ($tx->validate() != 0) {
        Errf("Produced incorrect transaction");
        return;
    }
    $tx->receive();
    Noticef("Produced transaction %s with fee %i", $tx->hash_str, $tx->fee);
    Debugf("Produced transaction inputs:");
    Debugf("  tx_in: %s, num: %u", $_->tx_in_str, $_->num) foreach @txo;
    $tx->announce();
    return $tx;
}

1;
