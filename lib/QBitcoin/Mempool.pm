package QBitcoin::Mempool;
use warnings;
use strict;

# It's not stack, it's queue

use QBitcoin::Const;
use QBitcoin::Log;

sub want_tx {
    my $class = shift;
    my ($size, $fee) = @_;
    # TODO
    return 1;
}

1;
