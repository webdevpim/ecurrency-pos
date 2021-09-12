package QBitcoin::Block::Receive;
use warnings;
use strict;

use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Config;
use QBitcoin::TXO;
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced);
use QBitcoin::ConnectionList;
use QBitcoin::Generate::Control;
use Role::Tiny; # This is role for QBitcoin::Block;

# @block_pool - array (by height) of hashes, block by block->hash
# @best_block - pointers to blocks in the main branch
# @descendant - list of block descendants (including pending), as $descendant[$height]->{$prev_hash}->{$hash}

# Each block has attributes:
# - self_weight - weight calculated by the block contents
# - weight - weight of the branch ended with this block, i.e. self_weight of the block and all its ancestors

# We ignore blocks from peer which has weight less than our best branch
# Last INCORE_LEVELS levels keep in memory, and only then save to the database
# If we receive block with good weight (better than out best) but with unknown ancestor then
# request the ancestor and do not switch the best branch until we have completely linked branch and verify its weight

my @block_pool;
my @best_block;
my @descendant;
my $HEIGHT;
my $MIN_INCORE_HEIGHT;

END {
    # free structures
    undef @best_block;
    undef @descendant;
    undef @block_pool;
};

sub best_weight {
    return defined($HEIGHT) ? $best_block[$HEIGHT]->weight : -1;
}

sub blockchain_height {
    return $HEIGHT;
}

sub best_block {
    my $class = shift;
    my ($block_height) = @_;
    return $best_block[$block_height];
}

sub min_incore_height {
    return $MIN_INCORE_HEIGHT;
}

sub max_incore_height {
    return $#block_pool;
}

sub to_cache {
    my $self = shift;
    $block_pool[$self->height]->{$self->hash} = $self;
    $self->add_as_descendant();
    $MIN_INCORE_HEIGHT = $self->height if !defined($MIN_INCORE_HEIGHT) || $MIN_INCORE_HEIGHT > $self->height;
}

sub add_as_descendant {
    my $self = shift;
    $descendant[$self->height]->{$self->prev_hash}->{$self->hash} = $self if $self->prev_hash;
}

sub del_as_descendant {
    my $self = shift;
    delete $descendant[$self->height]->{$self->prev_hash}->{$self->hash} if $self->prev_hash;
}

sub descendants {
    my $self = shift;
    return $descendant[$self->height+1] && $descendant[$self->height+1]->{$self->hash} ? values %{$descendant[$self->height+1]->{$self->hash}} : ();
}

sub block_pool {
    my $class = shift;
    my ($block_height, $hash) = @_;
    return $block_pool[$block_height]->{$hash};
}

sub receive {
    my $self = shift;
    my ($loaded) = @_;

    return 0 if $block_pool[$self->height]->{$self->hash};
    if (my $err = $self->validate()) {
        Warningf("Incorrect block %s from %s: %s", $self->hash_str, $self->received_from ? $self->received_from->peer->id : "me", $err);
        # Incorrect block
        # NB! Incorrect hash is not this case, hash must be checked earlier
        # Drop descendants, it's not possible to receive correct block with the same hash
        $self->free_block();
        if ($self->received_from) {
            $self->received_from->peer->decrease_reputation();
            if ($self->received_from->connection) {
                $self->received_from->abort("invalid_block");
            }
        }
        return -1;
    }

    if (COMPACT_MEMORY) {
        if (defined($HEIGHT) && $best_block[$HEIGHT] && $self->weight < $best_block[$HEIGHT]->weight) {
            if (!$self->received_from || ($self->received_from->has_weight // -1) <= $best_block[$HEIGHT]->weight) {
                Debugf("Received block weight %Lu (remote has %Lu) not more than our best branch weight %Lu, ignore",
                    $self->weight, $self->received_from ? $self->received_from->has_weight // 0 : 0, $best_block[$HEIGHT]->weight);
                $self->free_block();
                return 0;
            }
        }
    }

    $self->to_cache;
    if ($self->prev_block_load) {
        $self->prev_block->next_block //= $self;
    }

    # zero weight for new block is ok, accept it
    if ($HEIGHT && ($self->weight < $best_block[$HEIGHT]->weight ||
        ($self->weight == $best_block[$HEIGHT]->weight && $self->branch_height <= $HEIGHT))) {
        my $has_weight = $self->received_from ? ($self->received_from->has_weight // -1) : -1;
        Debugf("Received block %s height %u from %s has too low weight for us: %Lu < %Lu",
            $self->hash_str, $self->height, $self->received_from ? $self->received_from->peer->id : "me",
            $self->weight, $best_block[$HEIGHT]->weight);
        return 0;
    }

    # We have candidate for the new best branch, validate it
    # Find first common block between current best branch and the candidate
    my $class = ref $self;
    my $new_best;
    for ($new_best = $self; $new_best->height > 0; $new_best = $new_best->prev_block) {
        # "root" best_block for this new branch must be already loaded
        my $best_block = $class->best_block($new_best->height-1);
        last if $best_block && $best_block->hash eq $new_best->prev_hash;
        $new_best->prev_block->next_block = $new_best;
    }
    if (defined($HEIGHT) && $new_best->height == 0) {
        die "Error receiving alternative branch";
    }
    # $new_best is first block in new branch after fork, i.e $new_nest->prev_block is in the current best branch
    if ($new_best->height < ($HEIGHT // -1)) {
        Infof("Check alternate branch started with block %s height %u with weight %Lu (current best weight %Lu)",
            $new_best->hash_str, $new_best->height, $self->weight, $self->best_weight);
    }

    # reset all txo in the current best branch (started from the fork block) as unspent;
    # then set output in all txo in new branch and check it against possible double-spend
    for (my $b = $class->best_block($HEIGHT // $new_best->height); $b && $b->height >= $new_best->height; $b = $b->prev_block_load) {
        $b->prev_block_load->next_block = $b;
        Debugf("Remove block %s height %u from the best branch", $b->hash_str, $b->height);
        foreach my $tx (reverse @{$b->transactions}) {
            $tx->unconfirm();
        }
    }
    for (my $b = $new_best; $b; $b = $b->next_block) {
        Debugf("Add block %s height %u to the best branch", $b->hash_str, $b->height);
        my $fail_tx;

        foreach my $tx (@{$b->transactions}) {
            if (defined($tx->block_height) && $tx->block_height != $b->height) {
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
                        $b->received_from ? $b->received_from->peer->id : "me");
                    $fail_tx = $tx->hash;
                    last;
                }
                elsif (my $tx_in = QBitcoin::Transaction->get($txo->tx_in)) {
                    # Transaction with this output must be already confirmed (in the same best branch)
                    # Stored (not cached) transactions are always confirmed, not needed to load them
                    if (!defined($tx_in->block_height)) {
                        Warningf("Unconfirmed input %s:%u for transaction %s, block from %s",
                            $txo->tx_in_str, $txo->num, $tx->hash_str,
                            $b->received_from ? $b->received_from->peer->id : "me");
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
                $txo->siglist = $in->{siglist};
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
                Warningf("Incorrect weight for block %s: %Lu != %Lu", $b->hash_str,
                    $b->weight, $self_weight + ( $b->prev_block ? $b->prev_block->weight : 0 ));
                $fail_tx = "block";
            }
        }

        if ($fail_tx) {
            # If we have tx included in two different blocks then process rollback until second tx occurence
            # It's not possible to include a tx twice in the same block, it's checked on block validation
            Debugf("Revert block %s height %u from best branch", $b->hash_str, $b->height);
            foreach my $tx (@{$b->transactions}) { # TODO: Do we need reverse order for unconfirm here?
                last if $fail_tx eq $tx->hash;
                $tx->unconfirm();
            }
            for (my $b1 = $b->prev_block; $b1 && $b1->height >= $new_best->height; $b1 = $b1->prev_block) {
                Debugf("Revert block %s height %u from the best branch", $b1->hash_str, $b1->height);
                foreach my $tx (reverse @{$b1->transactions}) {
                    $tx->unconfirm();
                }
            }

            my $old_best = $class->best_block($new_best->height);
            $old_best->prev_block->next_block = $old_best if $old_best && $old_best->prev_block;
            for (my $b1 = $old_best; $b1; $b1 = $b1->next_block) {
                Debugf("Return block %s height %u to the best branch", $b1->hash_str, $b1->height);
                foreach my $tx (@{$b1->transactions}) {
                    $tx->block_height = $b1->height;
                    foreach my $in (@{$tx->in}) {
                        my $txo = $in->{txo};
                        $txo->tx_out = $tx->hash;
                        $txo->siglist = $in->{siglist};
                        $txo->del_my_utxo if $txo->is_my;
                    }
                    foreach my $txo (@{$tx->out}) {
                        $txo->add_my_utxo if $txo->is_my && !$txo->spent_list;
                    }
                }
            }
            $b->drop_branch();
            if ($self->received_from) {
                $self->received_from->peer->decrease_reputation();
                if ($self->received_from->connection) {
                    $self->received_from->abort("incorrect_block");
                }
            }
            return -1;
        }
    }

    # set best branch
    $new_best->prev_block->next_block = $new_best if $new_best->prev_block;
    if ($new_best->height <= QBitcoin::Block->max_db_height && !$loaded) {
        # Remove stored blocks in old best branch to keep database blockchain consistent during saving new branch
        # and do not create huge sql transactions
        # TODO: implement ORM method delete_by(); QBitcoin::Block->delete_by(height => { '>' => $incore_height })
        for (my $n = QBitcoin::Block->max_db_height; $n >= $new_best->height; $n--) {
            QBitcoin::Block->new(height => $n)->delete;
        }
        QBitcoin::Block->max_db_height($new_best->height-1);
    }
    for (my $b = $new_best; $b; $b = $b->next_block) {
        $best_block[$b->height] = $b;
    }

    if ($self->received_from && $self->self_weight) {
        $self->received_from->peer->add_reputation(blockchain_synced() ? 1 : 0.01);
    }

    if (defined($HEIGHT) && $new_best->height <= $HEIGHT) {
        QBitcoin::Generate::Control->generate_new() if $new_best->height < $HEIGHT;
        Debugf("%s block height %u hash %s, best branch altered, weight %Lu, %u transactions",
            $self->received_from ? "received" : "loaded", $self->height,
            $self->hash_str, $self->weight, scalar(@{$self->transactions}));
    }
    else {
        Debugf("%s block height %u hash %s in the best branch, weight %Lu, %u transactions",
            $self->received_from ? "received" : "loaded", $self->height,
            $self->hash_str, $self->weight, scalar(@{$self->transactions}));
    }

    if (blockchain_synced() && ($self->received_from || time() >= time_by_height($self->height))) {
        # Do not announce old blocks loaded from the local database or generated
        $self->announce_to_peers();
    }

    if (defined($HEIGHT) && $self->height < $HEIGHT) {
        foreach my $n ($self->height+1 .. $HEIGHT) {
            delete $best_block[$n];
        }
        $HEIGHT = $self->height;
        blockchain_synced(0) unless $config->{genesis};
    }

    if ($self->height > ($HEIGHT // -1)) {
        # It's the first block in this level
        # Store and free old level (if it's in the best branch)
        $HEIGHT = $self->height;
        $self->check_synced();
        for (my $level = QBitcoin::Block->max_db_height + 1; $level <= $HEIGHT - INCORE_LEVELS; $level++) {
            $best_block[$level]->store();
        }
        if ($HEIGHT >= INCORE_LEVELS) {
            cleanup_old_blocks();
        }
    }

    return 0;
}

sub want_cleanup_branch {
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels
    my ($block) = @_;
    while (1) {
        return 0 if $block->received_from && $block->received_from->syncing;
        return 0 if $block->height > $HEIGHT - INCORE_LEVELS;
        my @descendants = $block->descendants;
        # avoid too deep recursion
        my $next_block = pop @descendants
            or last;
        foreach my $descendant (@descendants) {
            if (want_cleanup_branch($descendant)) {
                drop_branch($descendant);
            }
            else {
                return 0;
            }
        }
        $block = $next_block;
    }
    return 1;
}

sub cleanup_old_blocks {
    my $first_free_height = $HEIGHT - INCORE_LEVELS;
    for (my $free_height = $MIN_INCORE_HEIGHT; $free_height <= $first_free_height; $free_height++) {
        if ($free_height < $first_free_height) {
            foreach my $b (values %{$block_pool[$free_height+1]}) {
                next if $best_block[$free_height+1] && $b->hash eq $best_block[$free_height+1]->hash; # cleanup best branch after all other
                # cleanup only full branches; if prev_block has single descendant then this branch was already checked
                next if $b->prev_block && scalar($b->prev_block->descendants) == 1;
                drop_branch($b) if want_cleanup_branch($b);
            }
        }
        last if keys(%{$block_pool[$free_height]}) > 1;
        if ($best_block[$free_height]) {
            my @descendants = $best_block[$free_height]->descendants;
            if (@descendants > 1 || (@descendants == 1 && !$best_block[$free_height+1])) {
                last;
            }
            # we have only best block on this level without descendants in alternate branches, drop it and cleanup the level
            free_block($best_block[$free_height]);
            foreach my $descendant ($best_block[$free_height]->descendants) {
                $descendant->prev_block(undef);
            }
            delete $best_block[$free_height];
        }
        elsif (%{$block_pool[$free_height]}) {
            last;
        }
        delete $descendant[$free_height];
        delete $block_pool[$free_height];
        Debugf("Level %u cleared", $free_height);
        $MIN_INCORE_HEIGHT++;
    }
}

sub free_block {
    my ($block) = @_;

    Debugf("Free block %s height %u from memory cache", $block->hash_str, $block->height);
    $block->prev_block(undef);
    $block->next_block(undef);
    delete $block_pool[$block->height]->{$block->hash};
    $block->del_as_descendant();
    foreach my $tx (@{$block->transactions}) {
        $tx->del_from_block($block);
    }
    $block->drop_pending();
}

sub drop_branch {
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels
    my ($block) = @_;

    while (1) {
        free_block($block);
        my @descendants = $block->descendants
            or last;
        # loop instead of deep recursion for case only one descendant (long chain)
        my $next_block = pop @descendants;
        foreach my $descendant (@descendants) {
            $descendant->drop_branch(); # recursively
        }
        $block = $next_block;
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
    if (my $prev_block = $block_pool[$self->height-1]->{$self->prev_hash}) {
        $self->{prev_block} = $prev_block;
    }
    return $self->{prev_block};
}

sub prev_block_load {
    my $self = shift;
    return $self->{prev_block} if exists $self->{prev_block}; # undef means we have no such block
    return undef unless $self->height; # genesis block has no ancestors
    return $self->{prev_block} if $self->prev_block; # exists in block_pool
    my $class = ref($self);
    if (my $prev_block = $class->find(hash => $self->prev_hash)) {
        $prev_block->to_cache;
        $best_block[$prev_block->height] = $prev_block;
        $self->{prev_block} = $prev_block;
    }
    return $self->{prev_block};
}

# Call after successful block receive, best or not
sub check_synced {
    my $self = shift;
    # Is it OK to synchronize and request mempool from incoming peer?
    if ($self->received_from && $HEIGHT >= height_by_time(time()) && !blockchain_synced()) {
        Infof("Blockchain is synced");
        blockchain_synced(1);
        if (!mempool_synced()) {
            $self->received_from->request_mempool();
        }
    }
}

sub announce_to_peers {
    my $self = shift;

    foreach my $connection (QBitcoin::ConnectionList->connected(PROTOCOL_QBITCOIN)) {
        next if $self->received_from && $connection->peer->id eq $self->received_from->peer->id;
        next unless $connection->protocol->can('announce_block');
        $connection->protocol->announce_block($self);
    }
}

1;
