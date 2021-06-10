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
    my $tx = QBitcoin::Transaction->get_by_hash($txo->tx_in)
        or die "No input transaction " . $txo->tx_in_str . " for my utxo\n";
    return $tx->block_height;
}

sub make_stake_tx {
    my ($fee) = @_;

    my @my_txo = grep { txo_confirmed($_) } QBitcoin::TXO->my_utxo()
        or return undef;
    my $my_amount = sum map { $_->value } @my_txo;
    my ($my_address) = my_address(); # first one
    my $out = QBitcoin::TXO->new_txo(
        value       => $my_amount + $fee,
        open_script => scalar(QBitcoin::OpenScript->script_for_address($my_address->address)),
    );
    my $tx = QBitcoin::Transaction->new(
        in            => [ map +{ txo => $_ }, @my_txo ],
        out           => [ $out ],
        fee           => -$fee,
        received_time => time(),
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
        $prev_block = QBitcoin::Block->best_block($height-1);
    }

    my $stake_tx = make_stake_tx(0);
    my @transactions = QBitcoin::Mempool->choose_for_block($stake_tx);
    if (@transactions && $transactions[0]->fee > 0) {
        return unless $stake_tx;
        my $fee = sum map { $_->fee } @transactions;
        # Generate new stake_tx with correct output value
        $stake_tx = make_stake_tx($fee);
        Infof("Generated stake tx %s with input amount %u, consume %u fee", $stake_tx->hash_str,
            sum(map { $_->{txo}->value } @{$stake_tx->in}), -$stake_tx->fee);
        QBitcoin::TXO->save_all($stake_tx->hash, $stake_tx->out);
        $stake_tx->receive();
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
    QBitcoin::Generate::Control->generated_height($height);
    Debugf("Generated block %s height %u weight %u, %u transactions",
        $generated->hash_str, $height, $generated->weight, scalar(@transactions));
    $generated->receive();
}

1;
