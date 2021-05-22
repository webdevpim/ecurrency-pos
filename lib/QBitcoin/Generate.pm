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
        foreach my $script (QBitcoin::OpenScript->script_for_address($my_address)) {
            foreach my $utxo (QBitcoin::TXO->find(open_script => $script, tx_out => undef)) {
                $utxo->add_my_utxo();
            }
        }
    }
    Infof("My UTXO loaded, total %u", scalar QBitcoin::TXO->my_utxo());
}

sub my_close_script {
    my $class = shift;
    my ($open_script) = @_;
    # TODO
    return scalar my_address();
}

sub sign_my_transaction {
    my $tx = shift;
    # TODO
}

sub generated_height {
    my $class = shift;
    return QBitcoin::Generate::Control->generated_height;
}

sub txo_confirmed {
    my ($txo) = @_;
    my $tx = QBitcoin::Transaction->get_by_hash($txo->tx_in)
        or die "No input transaction " . unpack("H*", substr($txo->tx_in, 0, 4)) . " for my utxo\n";
    return $tx->block_height;
}

sub make_stake_tx {
    my ($fee) = @_;

    my @my_txo = grep { txo_confirmed($_) } QBitcoin::TXO->my_utxo()
        or return undef;
    my $my_amount = sum map { $_->value } @my_txo;
    my ($my_address) = my_address(); # first one
    my $out = QBitcoin::TXO->new(
        value       => $my_amount + $fee,
        num         => 0,
        open_script => QBitcoin::OpenScript->script_for_address($my_address),
    );
    my $tx = QBitcoin::Transaction->new(
        in            => [ map { txo => $_, close_script => my_close_script($_->open_script) }, @my_txo ],
        out           => [ $out ],
        fee           => -$fee,
        received_time => time(),
    );
    $tx->hash = QBitcoin::Transaction->calculate_hash($tx->serialize);
    $tx->out->[0]->tx_in = $tx->hash;
    sign_my_transaction($tx);
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
    my $self_weight = 0;
    my @transactions = QBitcoin::Mempool->choose_for_block($stake_tx);
    if (@transactions && $transactions[0]->fee > 0) {
        return unless $stake_tx;
        my $fee = sum map { $_->fee } @transactions;
        # Generate new stake_tx with correct output value
        $stake_tx = make_stake_tx($fee);
        $stake_tx->out->[0]->save;
        $stake_tx->receive();
        $stake_tx->out->[0]->add_my_utxo();
        unshift @transactions, $stake_tx;
        $self_weight = $stake_tx->stake_weight($height)
            // return;
    }
    my $generated = QBitcoin::Block->new({
        height       => $height,
        weight       => $prev_block ? $prev_block->weight + $self_weight : $self_weight,
        self_weight  => $self_weight,
        prev_hash    => $prev_block ? $prev_block->hash : undef,
        transactions => \@transactions,
    });
    my $data = $generated->serialize;
    $generated->hash($generated->calculate_hash($data));
    QBitcoin::Generate::Control->generated_height($height);
    Debugf("Generated block height %u weight %u, %u transactions", $height, $generated->weight, scalar(@transactions));
    $generated->receive();
}

1;
