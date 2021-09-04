package QBitcoin::Block::Stored;
use warnings;
use strict;

use Role::Tiny;
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::ORM qw(find replace delete);
use QBitcoin::ORM::Transaction;

use constant TABLE => 'block';

my $MAX_DB_HEIGHT;

sub store {
    my $self = shift;
    my $db_transaction = QBitcoin::ORM::Transaction->new;
    $self->replace(); # Save block first to satisfy foreign key
    foreach my $transaction (@{$self->transactions}) {
        $transaction->store();
    }
    $db_transaction->commit;
    $MAX_DB_HEIGHT = $self->height if !defined($MAX_DB_HEIGHT) || $MAX_DB_HEIGHT < $self->height;
}

sub on_load {
    my $self = shift;
    # Load transaction hashes
    my @transactions = QBitcoin::Transaction->fetch(block_height => $self->height);
    $self->{tx_hashes} = [ map { $_->{hash} } @transactions ];
    return $self;
}

sub transactions {
    my $self = shift;
    if (@_) {
        $self->transactions = $_[0];
    }
    elsif (!$self->{transactions}) {
        my @transactions = QBitcoin::Transaction->find(block_height => $self->height);
        $self->{transactions} = \@transactions;
        $_->add_to_block($self) foreach @transactions;
    }
    return $self->{transactions};
}

sub max_db_height {
    my $class = shift;
    if (@_) {
        $MAX_DB_HEIGHT = $_[0];
    }
    return $MAX_DB_HEIGHT // -1;
}

1;
