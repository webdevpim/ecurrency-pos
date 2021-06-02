package QBitcoin::Block::Receive;
use warnings;
use strict;

use Role::Tiny; # This is role for QBitcoin::Block;
use List::Util qw(min);
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Config;
use QBitcoin::TXO;
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced);
use QBitcoin::Peers;
use QBitcoin::Generate::Control;

# @block_pool - array (by height) of hashes, block by block->hash
# @best_block - pointers to blocks in the main branch
# @prev_block - get block by its "prev_block" attribute, split to array by block height, for search block descendants

# Each block has attributes:
# - self_weight - weight calculated by the block contents
# - weight - weight of the branch ended with this block, i.e. self_weight of the block and all its ancestors
# - branch_weight (calculated) - weight of the best branch contains this block, i.e. maximum weight of the block descendants

# We ignore blocks with branch_weight less than our best branch
# Last INCORE_LEVELS levels keep in memory, and only then save to the database
# If we receive block with good branch_weight (better than out best) but with unknown ancestor then
# request the ancestor and do not switch best branch until we have full linked branch and verify its weight

my @block_pool;
my @best_block;
my @prev_block;
my $height;

END {
    # free structures
    undef @best_block;
    undef @prev_block;
    undef @block_pool;
};

sub best_weight {
    return defined($height) ? $best_block[$height]->weight : -1;
}

sub blockchain_height {
    return $height;
}

sub best_block {
    my $class = shift;
    my ($block_height) = @_;
    return $best_block[$block_height] //
        ($block_height <= ($height // -1) - INCORE_LEVELS ? $class->find(height => $block_height) : undef);
}

sub block_pool {
    my $class = shift;
    my ($block_height, $hash) = @_;
    return $block_pool[$block_height]->{$hash};
}

sub receive {
    my $self = shift;

    return 0 if $block_pool[$self->height]->{$self->hash};
    if (my $err = $self->validate()) {
        Warningf("Incorrect block from %s: %s", $self->received_from ? $self->received_from->ip : "me", $err);
        # Incorrect block
        # NB! Incorrect hash is not this case, hash must be checked earlier
        # Drop descendants, it's not possible to receive correct block with the same hash
        if ($self->received_from) {
            $self->received_from->decrease_reputation();
            $self->received_from->send_line("abort invalid_block");
        }
        return -1;
    }

    if (COMPACT_MEMORY) {
        if (defined($height) && $best_block[$height] && $self->weight < $best_block[$height]->weight) {
            if (($self->received_from->has_weight // -1) <= $best_block[$height]->weight) {
                Debugf("Received block weight %u not more than our best branch weight %u, ignore",
                    $self->weight, $best_block[$height]->weight);
                return 0;
            }
        }
    }

    $block_pool[$self->height]->{$self->hash} = $self;
    $prev_block[$self->height]->{$self->prev_hash}->{$self->hash} = $self if $self->prev_hash;

    if ($self->prev_block) {
        $self->prev_block->next_block //= $self;
    }

    # zero weight for new block is ok, accept it
    if ($height && ($self->weight < $best_block[$height]->weight ||
        ($self->weight == $best_block[$height]->weight && $self->branch_height <= $height))) {
        my $has_weight = $self->received_from ? ($self->received_from->has_weight // -1) : -1;
        Debugf("Received block height %s from %s has too low weight for us",
            $self->height, $self->received_from ? $self->received_from->ip : "me");
        return 0;
    }

    # We have candidate for the new best branch, validate it
    # Find first common block between current best branch and the candidate
    my $class = ref $self;
    my $new_best;
    for ($new_best = $self; $new_best->prev_block; $new_best = $new_best->prev_block) {
        my $best_block = $class->best_block($new_best->height-1);
        last if !$best_block || $best_block->hash eq $new_best->prev_hash;
        $new_best->prev_block->next_block = $new_best;
    }
    if ($new_best->height < $height) {
        Infof("Check alternate branch started with block %s height %u with weight %u (current best weight %u)",
            $new_best->hash_str, $new_best->height, $self->weight, $self->best_weight);
    }

    # reset all txo in the current best branch (started from the fork block) as unspent;
    # then set output in all txo in new branch and check it against possible double-spend
    for (my $b = $class->best_block($height); $b && $b->height >= $new_best->height; $b = $b->prev_block) {
        $b->prev_block->next_block = $b if $b->prev_block;
        Debugf("Remove block %s height %s from best branch", $b->hash_str, $b->height);
        foreach my $tx (reverse @{$b->transactions}) {
            $tx->unconfirm();
        }
    }
    for (my $b = $new_best; $b; $b = $b->next_block) {
        Debugf("Add block %s height %s to best branch", $b->hash_str, $b->height);
        my $fail_tx;

        foreach my $tx (@{$b->transactions}) {
            if ($tx->block_height && $tx->block_height != $b->height) {
                Warningf("Transaction %s included in blocks %u and %u", $tx->hash_str, $tx->block_height, $b->height);
                $fail_tx = $tx->hash;
                last;
            }
            foreach my $in (@{$tx->in}) {
                my $txo = $in->{txo};
                # It's possible that $txo->tx_out already set for rebuild blockchain loaded from local database
                if ($txo->tx_out && $txo->tx_out ne $tx->hash) {
                    # double-spend; drop this branch, return to old best branch and decrease reputation for peer $b->received_from
                    Warningf("Double spend for transaction output %s:%u: first in transaction %s, second in %s, block from %s",
                        $txo->tx_in_str, $txo->num, $txo->tx_out_str, $tx->hash_str,
                        $b->received_from ? $b->received_from->ip : "me");
                    $fail_tx = $tx->hash;
                    last;
                }
                elsif (my $tx_in = QBitcoin::Transaction->get($txo->tx_in)) {
                    # Transaction with this output must be already confirmed (in the same best branch)
                    # Stored (not cached) transactions are always confirmed, not needed to load them
                    if (!$tx_in->block_height) {
                        Warningf("Unconfirmed input %s:%u for transaction %s, block from %s",
                            $txo->tx_in_str, $txo->num, $tx->hash_str,
                            $b->received_from ? $b->received_from->ip : "me");
                        $fail_tx = $tx->hash;
                        last;
                    }
                }
            }
            last if $fail_tx;
            $tx->block_height = $b->height;
            foreach my $in (@{$tx->in}) {
                my $txo = $in->{txo};
                $txo->tx_out = $tx->hash;
                $txo->close_script = $in->{close_script};
                $txo->del_my_utxo if $txo->is_my; # for stake transaction
            }
            foreach my $txo (@{$tx->out}) {
                $txo->add_my_utxo if $txo->is_my && !$txo->spent_list;
            }
        }

        if (!$fail_tx) {
            my $self_weight = $b->self_weight;
            if (!defined($self_weight)) {
                $fail_tx = "block"; # does not match any transaction hash
            }
            elsif ($self_weight + ( $b->prev_block ? $b->prev_block->weight : 0 ) != $b->weight) {
                Warningf("Incorrect weight for block %s: %u != %u", $b->hash_str,
                    $b->weight, $self_weight + ( $b->prev_block ? $b->prev_block->weight : 0 ));
                $fail_tx = "block";
            }
        }

        if ($fail_tx) {
            # If we have tx included in two different blocks then process rollback until second tx occurence
            # It's not possible to include a tx twice in the same block, it's checked on block validation
            Debugf("Revert block %s height %s from best branch", $b->hash_str, $b->height);
            foreach my $tx (@{$b->transactions}) { # TODO: Do we need reverse order for unconfirm here?
                last if $fail_tx eq $tx->hash;
                $tx->unconfirm();
            }
            for (my $b1 = $b->prev_block; $b1 && $b1->height >= $new_best->height; $b1 = $b1->prev_block) {
                Debugf("Revert block %s height %s from best branch", $b1->hash_str, $b1->height);
                foreach my $tx (reverse @{$b1->transactions}) {
                    $tx->unconfirm();
                }
            }

            for (my $b1 = $class->best_block($new_best->height); $b1; $b1 = $b1->next_block) {
                Debugf("Return block %s height %s to best branch", $b1->hash_str, $b1->height);
                foreach my $tx (@{$b1->transactions}) {
                    $tx->block_height = $b1->height;
                    foreach my $in (@{$tx->in}) {
                        my $txo = $in->{txo};
                        $txo->tx_out = $tx->hash;
                        $txo->close_script = $in->{close_script};
                        $txo->del_my_utxo if $txo->is_my;
                    }
                    foreach my $txo (@{$tx->out}) {
                        $txo->add_my_utxo if $txo->is_my && !$txo->spent_list;
                    }
                }
            }
            $b->drop_branch();
            if ($self->received_from) {
                $self->decrease_reputation;
                $self->received_from->send_line("abort incorrect_block");
            }
            return -1;
        }
    }

    # set best branch
    $new_best->prev_block->next_block = $new_best if $new_best->prev_block;
    if ($new_best->height < $height - INCORE_LEVELS) {
        # Remove stored blocks in old best branch to keep database blockchain consistent during saving new branch
        # and do not create huge sql transactions
        my $incore_height = min($new_best->height, $self->height - INCORE_LEVELS);
        # TODO: implement ORM method delete_by(); QBitcoin::Block->delete_by(height => { '>' => $incore_height })
        for (my $n = $height - INCORE_LEVELS; $n > $incore_height; $n--) {
            QBitcoin::Block->new(height => $n)->delete;
        }
    }
    for (my $b = $new_best; $b; $b = $b->next_block) {
        $best_block[$b->height] = $b;
        $b->store() if $b->height < $self->height - INCORE_LEVELS;
    }

    if (defined($height) && $new_best->height <= $height) {
        QBitcoin::Generate::Control->generate_new() if $new_best->height < $height;
        Debugf("%s block height %u hash %s, best branch altered, weight %u, %u transactions",
            $self->received_from ? "received" : "loaded", $self->height,
            $self->hash_str, $self->weight, scalar(@{$self->transactions}));
        if ($self->height < $height) {
            foreach my $n ($self->height+1 .. $height) {
                $best_block[$n] = undef;
            }
            $height = $self->height;
            blockchain_synced(0) unless $config->{genesis};
        }
    }
    else {
        Debugf("%s block height %u hash %s in best branch, weight %u, %u transactions",
            $self->received_from ? "received" : "loaded", $self->height,
            $self->hash_str, $self->weight, scalar(@{$self->transactions}));
    }

    if (blockchain_synced() && ($self->received_from || time() >= time_by_height($self->height))) {
        # Do not announce old blocks loaded from the local database or generated
        $self->announce_to_peers();
    }

    if ($self->height > ($height // -1)) {
        # It's the first block in this level
        # Store and free old level (if it's linked and in best branch)
        $height = $self->height;
        $self->check_synced();
        cleanup_old_blocks();
    }

    return 0;
}

sub cleanup_old_blocks {
    if ((my $first_free_height = $height - INCORE_LEVELS) >= 0) {
        if ($best_block[$first_free_height]) {
            $best_block[$first_free_height]->store();
            $best_block[$first_free_height] = undef;
        }
        # Remove linked blocks and branches with weight less than our best for all levels below $free_height
        # Keep only unlinked branches with weight more than our best and have blocks within last INCORE_LEVELS
        for (my $free_height = $first_free_height; $free_height >= 0; $free_height--) {
            last unless $block_pool[$free_height];
            foreach my $b (values %{$block_pool[$free_height]}) {
                if ($b->received_from && $b->received_from->syncing) {
                    next;
                }
                if ($b->branch_weight > $best_block[$height]->weight &&
                    $b->branch_height > $first_free_height) {
                    next;
                }
                delete $block_pool[$free_height]->{$b->hash};
                delete $prev_block[$free_height]->{$b->prev_hash}->{$b->hash} if $b->prev_hash;
                $b->next_block(undef);
                foreach my $b2 (values %{$prev_block[$free_height+1]->{$b->hash}}) {
                    $b2->prev_block(undef);
                }
                foreach my $tx (@{$b->transactions}) {
                    $tx->free();
                }
            }
            foreach my $prev_hash (keys %{$prev_block[$free_height]}) {
                delete $prev_block[$free_height]->{$prev_hash} unless %{$prev_block[$free_height]->{$prev_hash}};
            }
            if (!%{$block_pool[$free_height]}) {
                $prev_block[$free_height] = undef;
                $block_pool[$free_height] = undef;
            }
        }
    }
}

# Call after successful block receive, best or not
sub check_synced {
    my $self = shift;
    # Is it OK to synchronize and request mempool from incoming peer?
    if ($self->received_from && $height >= height_by_time(time()) && !blockchain_synced()) {
        Infof("Blockchain is synced");
        blockchain_synced(1);
        if (!mempool_synced()) {
            $self->received_from->send_line("sendmempool");
        }
    }
}

sub prev_block {
    my $self = shift;
    if (@_) {
        if ($_[0]) {
            $_[0]->hash eq $self->prev_hash
                or die "Incorrect block linking";
            return $self->{prev_block} = $_[0];
        }
        else {
            # It's not set "unexising" prev, it's free pointer which will be load again on demand
            delete $self->{prev_block}; # load again on demand
            return undef;
        }
    }
    return $self->{prev_block} if exists $self->{prev_block}; # undef means we have no such block
    return undef unless $self->height; # genesis block has no ancestors
    my $class = ref($self);
    return $self->{prev_block} //= $block_pool[$self->height-1]->{$self->prev_hash} //
        $class->find(hash => $self->prev_hash);
}

sub drop_branch {
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels
    my $self = shift;

    if ($self->prev_block) {
        if ($self->prev_block->next_block && $self->prev_block->next_block->hash eq $self->hash) {
            $self->prev_block->next_block = undef;
        }
    }
    $self->prev_block(undef);
    delete $block_pool[$self->height]->{$self->hash};
    delete $prev_block[$self->height]->{$self->prev_hash}->{$self->hash};
    foreach my $descendant (values %{$prev_block[$self->height+1]->{$self->hash}}) {
        $descendant->drop_branch(); # recursively
    }
}

sub announce_to_peers {
    my $self = shift;

    foreach my $peer (QBitcoin::Peers->connected) {
        next if $self->received_from && $peer->ip eq $self->received_from->ip;
        $peer->send_line("ihave " . $self->height . " " . $self->weight);
    }
}

1;
