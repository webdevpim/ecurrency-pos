package QBitcoin::Generate;
use warnings;
use strict;
use feature 'state';

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
use QBitcoin::ValueUpgraded qw(level_by_total);
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
    my ($reward, $block_sign_data) = @_;

    my $my_address;
    if ($config->{sign_alg}) {
        foreach my $sign_alg (split(/\s+/, $config->{sign_alg})) {
            foreach my $addr (my_address()) {
                if (grep { $_ eq $sign_alg } $addr->algo) {
                    $my_address = $addr;
                    last;
                }
            }
            last if $my_address;
        }
    }
    $my_address //= (my_address())[0]
        or return undef;
    my @my_txo = grep { txo_confirmed($_) } QBitcoin::TXO->my_utxo();
    my $my_amount = sum0 map { $_->value } @my_txo;
    my $out = QBitcoin::TXO->new_txo(
        value      => $my_amount + $reward,
        scripthash => scalar(scripthash_by_address($my_address->address)),
    );
    my $tx = QBitcoin::Transaction->new(
        in              => [ map +{ txo => $_ }, @my_txo ],
        out             => [ $out ],
        fee             => -$reward,
        tx_type         => TX_TYPE_STAKE,
        block_sign_data => $block_sign_data,
        received_time   => time(),
    );
    $tx->sign_transaction();
    $tx->size = length $tx->serialize;
    return $tx;
}

sub genesis_time() {
    state $genesis_time = $config->{testnet} ? GENESIS_TIME_TESTNET : GENESIS_TIME;
    return $genesis_time;
}

sub generate {
    my $class = shift;
    my ($time) = @_;
    my $timeslot = timeslot($time);
    if ($timeslot < genesis_time) {
        die "Genesis time " . genesis_time . " is in future\n";
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
    my $upgraded_total = $prev_block ? $prev_block->upgraded : 0;
    my $upgrade_level = level_by_total($upgraded_total);
    foreach my $coinbase (QBitcoin::Coinbase->get_new($timeslot)) {
        # Create new coinbase transaction and add it to mempool (if it's not there)
        QBitcoin::Transaction->new_coinbase($coinbase, $upgrade_level);
    }
    # Just get upper limit for the stake tx size
    my $stake_tx = make_stake_tx("0e0", "");
    my $size = $stake_tx ? $stake_tx->size : 0;

    # TODO: add transactions from block of the same timeslot, it's not an ancestor
    my @transactions = QBitcoin::Mempool->choose_for_block($size, $timeslot, $height, $stake_tx && $stake_tx->in, $upgraded_total);
    if (!@transactions && ($timeslot - genesis_time) / BLOCK_INTERVAL % FORCE_BLOCKS != 0) {
        return;
    }

    my @coinbase = grep { $_->is_coinbase } @transactions;
    my $fee = sum0 map { $_->fee } grep { !$_->is_coinbase } @transactions;
    my $coinbase_fee = sum0 map { $_->fee } @coinbase;
    my $reward_block = QBitcoin::Block->reward($prev_block, $coinbase_fee);
    # Block reward if the block will be empty
    my $reward_empty = ($timeslot - genesis_time) % (BLOCK_INTERVAL * FORCE_BLOCKS) ? 0 : $reward_block;
    my $reward = $fee || @coinbase ? $reward_block + $fee : $reward_empty;

    if ($reward) {
        $stake_tx or return;
        if (!@{$stake_tx->in}) {
            # Genesis node can validate block with the very first coinbase transaction
            # or create genesis block without validation amount
            if (!$config->{genesis} || QBitcoin::Block->best_weight > 0) {
                return;
            }
        }
        if (UPGRADE_POW && $height == 0 && !$config->{regtest}) {
            # Genesis block should not have coinbase transactions
            @transactions = grep { !$_->is_coinbase } @transactions;
        }
        # Generate new stake_tx with correct output value
        my $block_sign_data = $prev_block ? $prev_block->hash : ZERO_HASH;
        $block_sign_data .= $_->hash foreach @transactions;
        $stake_tx = make_stake_tx($reward, $block_sign_data);
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
    $generated->receive() ? undef : $generated;
}

1;
