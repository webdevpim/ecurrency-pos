package QBitcoin::Block::Validate;
use warnings;
use strict;

# Check block chain
# Check block time
# Validate all transactions
# Amount of all commissions should be 0

use QBitcoin::Const;
use Role::Tiny;

sub validate {
    my $block = shift;

    my $now = time();
    $now >= __PACKAGE__->time_by_height($block->height)
        or return "Block height " . $block->height . " is too early for now";
    if ($block->height == 0) {
#        $block->hash eq GENESIS_HASH
#            or return "Incorrect genesis block hash " . unpack("H*", $block->hash) . ", must be " . GENESIS_HASH_HEX;
        return 0; # Not needed to validate genesis block with correct hash
    }
    my $fee = 0;
    foreach my $transaction (@{$block->transactions}) {
        foreach my $txin (@{$transaction->in}) {
            $txin->validate(); # is this txin exists and correctly signed (unlocked)?
            # is the utxo unspent in this branch (including this block)?
            ...;
            $fee += $txin->value;
        }
        foreach my $txout (@{$transaction->out}) {
            $txout->value < MAX_VALUE
                or return "Too large value in transaction output: " . $txout->value;
            $fee -= $txout->value;
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

sub time_by_height {
    my $class = shift;
    my ($height) = @_;

    return GENESIS_TIME + $height * BLOCK_INTERVAL;
}

1;
