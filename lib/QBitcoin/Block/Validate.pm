package QBitcoin::Block::Validate;
use warnings;
use strict;

# Check block chain
# Check block time
# Validate all transactions
# Amount of all commissions should be 0

use Time::HiRes;
use QBitcoin::Const;
use Role::Tiny;

sub validate {
    my $block = shift;

    my $now = Time::HiRes::time();
    $now >= $block->time
        or return "Block time " . $block->time . " is too early for now";
    if (!$block->prev_hash || $block->prev_hash eq ZERO_HASH) {
#        $block->hash eq GENESIS_HASH
#            or return "Incorrect genesis block hash " . unpack("H*", $block->hash) . ", must be " . GENESIS_HASH_HEX;
        return ""; # Not needed to validate genesis block with correct hash
    }
    if (!@{$block->transactions} && (timeslot($block->time) - GENESIS_TIME) / BLOCK_INTERVAL % FORCE_BLOCKS) {
        return "Empty block";
    }
    my $merkle_root = $block->calculate_merkle_root;
    $block->merkle_root eq $merkle_root
        or return "Incorrect merkle root " . unpack("H*", $block->merkle_root) . " expected " . unpack("H*", $merkle_root);
    my $fee = 0;
    my %tx_in_block;
    my $empty_tx = 0;
    foreach my $transaction (@{$block->transactions}) {
        if ($tx_in_block{$transaction->hash}++) {
            return "Transaction " . $transaction->hash_str . " included in the block twice";
        }
        if ($transaction->valid_for_block($block) != 0) {
            return "Transaction " . $transaction->hash_str . " can't be included in block " . $block->height;
        }
        # NB: we do not check that the $txin is unspent in this branch;
        # we will check this on include this block into the best branch
        if ($transaction->fee == 0) {
            if (@{$transaction->in} > 0) {
                if (++$empty_tx > MAX_EMPTY_TX_IN_BLOCK) {
                    return "Too many empty transactions";
                }
            }
        }
        else {
            $fee += $transaction->fee;
        }
    }
    $fee == 0
        or return "Total block fee is $fee (not 0)";
    return "";
}

sub validate_tx {
    my $self = shift;
    # TODO
    return 0;
}

1;
