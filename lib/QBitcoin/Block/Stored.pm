package QBitcoin::Block::Stored;
use warnings;
use strict;

use Role::Tiny;
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::ORM qw(replace);
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
sub find {
    my $class = shift;
    if (wantarray) {
        my @blocks = QBitcoin::ORM::find($class, @_);
        $_->linked = 1 foreach @blocks;
        return @blocks;
    }
    else {
        my $block = QBitcoin::ORM::find($class, @_);
        $block->linked = 1 if $block;
        return $block;
    }
}

1;
