package QBitcoin::Block::Stored;
use warnings;
use strict;

use Role::Tiny;
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::ORM qw(replace);

use constant TABLE => 'block';

sub store {
    my $self = shift;
    $self->replace();
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
