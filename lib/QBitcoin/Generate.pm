package QBitcoin::Generate;
use warnings;
use strict;

use List::Util qw(sum);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Mempool;
use QBitcoin::Block;
use QBitcoin::OpenScript;
use QBitcoin::TXO;
use QBitcoin::Coinbase;
use QBitcoin::MyAddress qw(my_address);
use QBitcoin::Generate::Control;

my %MY_UTXO;

sub load_utxo {
    my $class = shift;
    foreach my $my_address (my_address()) {
        my @script_data = QBitcoin::OpenScript->script_for_address($my_address->address);
        if (my @script = QBitcoin::OpenScript->find(data => \@script_data)) {
            foreach my $utxo (grep { !$_->is_cached } QBitcoin::TXO->find(open_script => [ map { $_->id } @script ], tx_out => undef)) {
                $utxo->save();
                $utxo->add_my_utxo();
            }
        }
    }
    Infof("My UTXO loaded, total %u", scalar QBitcoin::TXO->my_utxo());
}

sub generated_height {
    my $class = shift;
    return QBitcoin::Generate::Control->generated_height;
}

sub txo_confirmed {
    my ($txo) = @_;
    my $block_height = QBitcoin::Transaction->check_by_hash($txo->tx_in)
        or die "No input transaction " . $txo->tx_in_str . " for my utxo\n";
    return $block_height >= 0;
}

sub make_stake_tx {
    my ($fee, $block_sign_data) = @_;

    my @my_txo = grep { txo_confirmed($_) } QBitcoin::TXO->my_utxo()
        or return undef;
    my $my_amount = sum map { $_->value } @my_txo;
    my ($my_address) = my_address(); # first one
    my $out = QBitcoin::TXO->new_txo(
        value       => $my_amount + $fee,
        open_script => scalar(QBitcoin::OpenScript->script_for_address($my_address->address)),
    );
    my $tx = QBitcoin::Transaction->new(
        in              => [ map +{ txo => $_ }, @my_txo ],
        out             => [ $out ],
        fee             => -$fee,
        block_sign_data => $block_sign_data,
        received_time   => time(),
    );
    $tx->sign_transaction();
    $tx->size = length $tx->serialize;
    return $tx;
}

sub generate {
    my $class = shift;
    my ($height) = @_;
    my $prev_block;
    if ($height > 0) {
        $prev_block = QBitcoin::Block->best_block($height-1)
            or die "No prev block height " . ($height-1) . " for generate";
    }

    my $stake_tx = make_stake_tx(0, "");
    my $size = $stake_tx ? $stake_tx->size : 0;
    foreach my $coinbase (QBitcoin::Coinbase->get_new($height)) {
        # Create new coinbase transaction and add it to mempool (if it's not there)
        QBitcoin::Transaction->new_coinbase($coinbase);
    }
    my @transactions = QBitcoin::Mempool->choose_for_block($size, $height);
    if (my $fee = sum map { $_->fee } @transactions) {
        return unless $stake_tx;
        # Generate new stake_tx with correct output value
        my $block_sign_data = $prev_block ? $prev_block->hash : ZERO_HASH;
        $block_sign_data .= $_->hash foreach @transactions;
        $stake_tx = make_stake_tx($fee, $block_sign_data);
        Infof("Generated stake tx %s with input amount %u, consume %u fee", $stake_tx->hash_str,
            sum(map { $_->{txo}->value } @{$stake_tx->in}), -$stake_tx->fee);
        QBitcoin::TXO->save_all($stake_tx->hash, $stake_tx->out);
        $stake_tx->validate() == 0
            or die "Incorrect generated stake transaction\n";
        $stake_tx->receive() == 0
            or die "Incorrect generated stake transaction\n";
        unshift @transactions, $stake_tx;
    }
    my $generated = QBitcoin::Block->new({
        height       => $height,
        prev_hash    => $prev_block ? $prev_block->hash : undef,
        transactions => \@transactions,
    });
    $generated->weight = $generated->self_weight + ( $prev_block ? $prev_block->weight : 0 );
    $generated->merkle_root = $generated->calculate_merkle_root();
    my $data = $generated->serialize;
    $generated->hash = $generated->calculate_hash();
    $generated->add_tx($_) foreach @transactions;
    QBitcoin::Generate::Control->generated_height($height);
    Debugf("Generated block %s height %u weight %u, %u transactions",
        $generated->hash_str, $height, $generated->weight, scalar(@transactions));
    $generated->receive();
}

1;
