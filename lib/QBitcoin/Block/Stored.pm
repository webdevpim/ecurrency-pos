package QBitcoin::Block::Stored;
use warnings;
use strict;

use Role::Tiny;
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::ORM qw(find replace);
use QBitcoin::ORM::Transaction;

use constant TABLE => 'block';

sub store {
    my $self = shift;
    my $db_transaction = QBitcoin::ORM::Transaction->new;
    $self->replace(); # Save block first to satisfy foreign key
    foreach my $transaction (@{$self->transactions}) {
        $transaction->store($self->height);
    }
    $db_transaction->commit;
}

# All stored blocks are linked, it's only the best branch there
sub on_load {
    my $self = shift;
    $self->linked = 1;
    # Load transactions
    my @transactions = QBitcoin::Transaction->find(block_height => $self->height);
    $self->transactions = \@transactions;
    return $self;
}

1;
