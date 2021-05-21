package QBitcoin::Mempool;
use warnings;
use strict;

# TODO: get transaction weight as fee*age, where age is (time() - $tx->received_time + NN), NN is ~ 10*BLOCK_INTERVAL
# Old transactions will have preferences, and all transactions will be confirmed at one time
# This allow to avoid drop old transactions from the tail of mempool queue
# but transactions with high fee will be confirmed immediately

# TODO: optimize these methods; keep mempool sorted and do not sort it each time

use QBitcoin::Const;
use QBitcoin::Log;

sub want_tx {
    my $class = shift;
    my ($size, $fee) = @_;
    # TODO
    # Consider mempool size and fee/size percentille
    return 1;
}

sub choose_for_block {
    my $class = shift;
    my ($stake_tx) = @_;
    my @mempool = sort { compare_tx($a, $b) } QBitcoin::Transaction->mempool_list()
        or return ();
    if (!$stake_tx) {
        # We can include only transactions with zero fee into block without stake transaction
        @mempool = grep { $_->fee == 0 } @mempool;
    }
    my $size = $stake_tx ? $stake_tx->size : 0;
    my $empty_tx = 0;
    for (my $i=0; $i<$#mempool; $i++) {
        $empty_tx++ if $mempool[$i]->fee == 0;
        $size += $mempool[$i]->size;
        if ($empty_tx > MAX_EMPTY_TX_IN_BLOCK || $size > MAX_BLOCK_SIZE - BLOCK_HEADER_SIZE) {
            @mempool = splice(@mempool, 0, $i);
            last;
        }
    }
    return @mempool;
}

sub compare_tx {
    return $b->fee*$a->size <=> $a->fee*$b->size ||
        $a->received_time <=> $b->received_time ||
        $a->hash cmp $b->hash;
}

1;
