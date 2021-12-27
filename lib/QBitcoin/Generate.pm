package QBitcoin::Generate;
use warnings;
use strict;

use List::Util qw(sum0);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Config;
use QBitcoin::Mempool;
use QBitcoin::Block;
use QBitcoin::RedeemScript;
use QBitcoin::TXO;
use QBitcoin::Coinbase;
use QBitcoin::Address qw(scripthash_by_address);
use QBitcoin::MyAddress qw(my_address);
use QBitcoin::Transaction;
use QBitcoin::Generate::Control;

sub load_utxo {
    my $class = shift;
    foreach my $my_address (my_address()) {
        $class->load_address_utxo($my_address);
    }
}

sub load_address_utxo {
    my $class = shift;
    my ($my_address) = @_;
    my @scripthash = scripthash_by_address($my_address->address);
    my $count = 0;
    my $value = 0;
    # add cached utxo as my
    foreach my $scripthash (@scripthash) {
        foreach my $utxo (QBitcoin::TXO->get_scripthash_utxo($scripthash)) {
            # ignore unconfirmed utxo
            if (my $tx = QBitcoin::Transaction->get($utxo->tx_in)) {
                next unless $tx->block_height;
            }
            else {
                next if QBitcoin::Transaction->has_pending($utxo->tx_in);
            }
            $utxo->add_my_utxo();
            $count++;
            $value += $utxo->value;
        }
    }
    if (my @script = QBitcoin::RedeemScript->find(hash => \@scripthash)) {
        foreach my $utxo (grep { !$_->is_cached } QBitcoin::TXO->find(scripthash => [ map { $_->id } @script ], tx_out => undef)) {
            $utxo->save();
            $utxo->add_my_utxo();
            $count++;
            $value += $utxo->value;
        }
    }
    Infof("My UTXO for %s loaded, found %u with amount %lu", $my_address->address, $count, $value);
}

sub generated_time {
    my $class = shift;
    return QBitcoin::Generate::Control->generated_time;
}

sub txo_confirmed {
    my ($txo) = @_;
    my $block_height = QBitcoin::Transaction->check_by_hash($txo->tx_in)
        or die "No input transaction " . $txo->tx_in_str . " for my utxo\n";
    return $block_height >= 0;
}

sub make_stake_tx {
    my ($fee, $block_sign_data) = @_;

    my $total_fee = 0;
    my @out;
    my @my_txo;
    if (exists $fee->{""}) {
        @my_txo = grep { txo_confirmed($_) } QBitcoin::TXO->my_utxo();
        # It's possible to create stake tx without inputs if the block contains only coinbase and zero-fee tx
        return undef if !@my_txo && keys(%$fee) == 1; # No coinbase and no my txo -> no stake tx needed
        my $my_amount = sum0 map { $_->value } @my_txo;
        my ($my_address) = my_address(); # first one
        push @out, QBitcoin::TXO->new_txo(
            value      => $my_amount + $fee->{""},
            scripthash => scalar(scripthash_by_address($my_address->address)),
        );
        $total_fee += $fee->{""};
    }
    foreach my $fee_dst (sort grep { $_ ne "" } keys %$fee) {
        push @out, QBitcoin::TXO->new_txo(
            value      => $fee->{$fee_dst},
            scripthash => $fee_dst,
        );
        $total_fee += $fee->{$fee_dst};
    }
    my $tx = QBitcoin::Transaction->new(
        in              => [ map +{ txo => $_ }, @my_txo ],
        out             => \@out,
        fee             => -$total_fee,
        tx_type         => TX_TYPE_STAKE,
        block_sign_data => $block_sign_data,
        received_time   => time(),
    );
    $tx->sign_transaction();
    $tx->size = length $tx->serialize;
    return $tx;
}

sub generate {
    my $class = shift;
    my ($time) = @_;
    my $timeslot = timeslot($time);
    if ($timeslot < GENESIS_TIME) {
        die "Genesis time " . GENESIS_TIME . " is in future\n";
    }
    my $prev_block;
    my $height = QBitcoin::Block->blockchain_height() // -1;
    if ($height >= 0) {
        $prev_block = QBitcoin::Block->best_block($height)
            or die "No prev block height $height for generate";
        if (timeslot($prev_block->time) >= $timeslot) {
            if ($height == 0) {
                Debugf("Skip regenerating genesis block");
                return;
            }
            $height--;
            $prev_block = QBitcoin::Block->best_block($height)
                or die "No prev block height $height for generate";
            if (timeslot($prev_block->time) >= $timeslot) {
                Warningf("Skip generating blocks from far past, time %s", $time);
                return;
            }
        }
    }
    $height++;
    foreach my $coinbase (QBitcoin::Coinbase->get_new($timeslot)) {
        # Create new coinbase transaction and add it to mempool (if it's not there)
        QBitcoin::Transaction->new_coinbase($coinbase);
    }
    # Just get upper limit for stake tx size
    my @coinbase = UPGRADE_POW && UPGRADE_FEE ? QBitcoin::Mempool->coinbase_list($timeslot) : ();
    my $stake_tx = make_stake_tx({ "" => 0, map { $_->hash => 0 } @coinbase }, "");
    my $size = $stake_tx ? $stake_tx->size : 0;
    # TODO: add transactions from block of the same timeslot, it's not ancestor
    my @transactions = QBitcoin::Mempool->choose_for_block($size, $timeslot, $stake_tx && $stake_tx->in);
    if (!@transactions && ($timeslot - GENESIS_TIME) / BLOCK_INTERVAL % FORCE_BLOCKS != 0) {
        return;
    }
    my $fee = {};
    foreach my $tx (grep { $_->fee } @transactions) {
        $fee->{UPGRADE_POW && UPGRADE_FEE && $tx->up ? $tx->up->fee_dst($prev_block) // "" : ""} += $tx->fee;
    }
    if (%$fee) {
        return unless $stake_tx;
        if ($fee->{""} && !@{$stake_tx->in}) {
            # Genesis node can validate block with the very first coinbase transaction without validation amount
            if (!$config->{genesis} || QBitcoin::Block->best_weight) {
                return;
            }
        }
        # Generate new stake_tx with correct output value
        my $block_sign_data = $prev_block ? $prev_block->hash : ZERO_HASH;
        $block_sign_data .= $_->hash foreach @transactions;
        $stake_tx = make_stake_tx($fee, $block_sign_data);
        Infof("Generated stake tx %s with input amount %lu, consume %lu fee", $stake_tx->hash_str,
            sum0(map { $_->{txo}->value } @{$stake_tx->in}), -$stake_tx->fee);
        # It's possible that the $stake_tx has no my_txo, so it may be not unique, already received or pending
        # Ignore if already received; process if pending
        if (QBitcoin::Transaction->check_by_hash($stake_tx->hash)) {
            Warningf("Generated stake tx %s already known, skip block generation", $stake_tx->hash_str);
            return;
        }
        $_->{txo}->spent_add($stake_tx) foreach @{$stake_tx->in};
        QBitcoin::TXO->save_all($stake_tx->hash, $stake_tx->out);
        $stake_tx->validate() == 0
            or die "Incorrect generated stake transaction\n";
        $stake_tx->save() == 0
            or die "Incorrect generated stake transaction\n";
        $stake_tx->process_pending();
        if (defined(my $height = QBitcoin::Block->recv_pending_tx($stake_tx))) {
            Infof("Generated stake tx %s is pending by a block, process it and skip new block generation", $stake_tx->hash_str);
            if ($height != -1) {
                my $block = QBitcoin::Block->best_block($height);
                if (my $connection = $block->received_from) {
                    $connection->syncing(0);
                    $connection->request_new_block();
                }
                return;
            }
        }
        unshift @transactions, $stake_tx;
    }
    my $generated = QBitcoin::Block->new({
        height       => $height,
        time         => $time,
        prev_hash    => $prev_block ? $prev_block->hash : undef,
        transactions => \@transactions,
    });
    $generated->weight = $generated->self_weight + ( $prev_block ? $prev_block->weight : 0 );
    $generated->merkle_root = $generated->calculate_merkle_root();
    my $data = $generated->serialize;
    $generated->hash = $generated->calculate_hash();
    $generated->add_tx($_) foreach @transactions;
    QBitcoin::Generate::Control->generated_time($time);
    Debugf("Generated block %s height %u weight %Lu, %u transactions",
        $generated->hash_str, $height, $generated->weight, scalar(@transactions));
    $generated->receive();
}

1;
