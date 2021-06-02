package QBitcoin::Block::Stored;
use warnings;
use strict;

use Role::Tiny;
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::ORM qw(find replace delete);
use QBitcoin::ORM::Transaction;

use constant TABLE => 'block';

sub store {
    my $self = shift;
    my $db_transaction = QBitcoin::ORM::Transaction->new;
    $self->replace(); # Save block first to satisfy foreign key
    foreach my $transaction (@{$self->transactions}) {
        $transaction->store();
    }
    $db_transaction->commit;
}

sub on_load {
    my $self = shift;
    # Load transactions
    my @transactions = QBitcoin::Transaction->find(block_height => $self->height);
    $self->transactions = \@transactions;
    return $self;
}

1;
