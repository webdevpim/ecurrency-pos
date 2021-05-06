package QBitcoin::Block::Receive;
use warnings;
use strict;

use Role::Tiny; # This is role for QBitcoin::Block;
use QBitcoin::Const;
use QBitcoin::Log;

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

sub best_weight {
    return defined($height) ? $best_block[$height]->weight : -1;
}

sub best_block {
    my $class = shift;
    my ($height) = @_;
    return $best_block[$height];
}

sub blockchain_height {
    return $height;
}

sub get_by_height {
    my $class = shift;
    my ($height) = @_;
    return $best_block[$height] // $class->find(height => $height);
}

sub receive {
    my $self = shift;

    return 0 if $block_pool[$self->height]->{$self->hash};
    if (my $err = $self->validate()) {
        Warningf("Incorrect block from %s: %s", $self->received_from ? $self->received_from->ip : "me", $err);
        # Incorrect block
        # NB! Incorrect hash is not this case, hash must be checked earlier
        # Drop descendants, it's not possible to receive correct block with the same hash
        if (my $descendants = $prev_block[$self->height+1]->{$self->hash}) {
            foreach my $descendant (values %$descendants) {
                $descendant->drop_branch();
            }
        }
        if ($self->received_from) {
            $self->received_from->decrease_reputation();
            $self->received_from->send_line("abort invalid_block");
        }
        return -1;
    }
    # Do we have a descendant for this block?
    my $new_weight = $self->weight;
    my $descendant;
    if ($prev_block[$self->height+1] && (my $descendants = $prev_block[$self->height+1]->{$self->hash})) {
        foreach my $descendant (values %$descendants) {
            if ($descendant->weight != $self->weight + $descendant->self_weight) {
                Warningf("Incorrect descendant weight %u != %u, drop it", $descendant->weight, $self->weight + $descendant->self_weight);
                $descendant->drop_branch();
            }
            elsif ($new_weight < $descendant->branch_weight) {
                $new_weight = $descendant->branch_weight;
                $self->next_block = $descendant;
            }
        }
    }
    if (COMPACT_MEMORY) {
        if (defined($height) && $best_block[$height] && $new_weight < $best_block[$height]->branch_weight) {
            Debugf("Received branch weight %u not more than our best branch weight %u, ignore",
                $new_weight, $best_block[$height]->branch_weight);
            return 0; # Not needed to drop descendants b/c there were dropped when weight of the current branch become more than their weight
        }
        if ($self->prev_hash && (my $alter_descendants = $prev_block[$self->height]->{$self->prev_hash})) {
            foreach my $alter_descendant (values %$alter_descendants) {
                if ($alter_descendant->branch_weight > $new_weight) {
                    Debugf("Alternative branch has waight %u more then received one %s, ignore",
                        $alter_descendant->branch_weight, $new_weight);
                    return 0;
                }
                Debugf("Drop alternative branch with weight %u less than new %s",
                    $alter_descendant->branch_weight, $new_weight);
                $alter_descendant->drop_branch();
            }
        }
    }
    if ($height && $self->height < $height && $self->received_from) {
        # Remove blocks received from this peer and not linked with this one
        # The best branch was changed on the peer
        foreach my $b (values %{$block_pool[$self->height+1]}) {
            next if $best_block[$b->height]->hash eq $b->hash;
            next if !$b->received_from;
            next if $b->received_from->ip ne $self->received_from->ip;
            next if $b->prev_hash eq $self->hash;
            Debugf("Remove orphan descendant %s height %s received from this peer %s",
                unpack("H*", substr($b->hash, 0, 4)), $b->height, $self->received_from->ip);
            $b->drop_branch();
        }
    }

    $block_pool[$self->height]->{$self->hash} = $self;
    $prev_block[$self->height]->{$self->prev_hash}->{$self->hash} = $self if $self->prev_hash;

    if ($self->prev_block) {
        $self->prev_block->next_block = $self;
    }
    elsif ($self->height) {
        Debugf("No prev block with height %s hash %s, request it", $self->height-1, unpack("H*", substr($self->prev_hash, 0, 4)));
        $self->received_from->send_line("sendblock " . ($self->height-1));
        return 0;
    }
    if (!$self->height || $self->prev_block->linked) {
        if ($self->set_linked() != 0) { # with descendants
            # Invalid branch (double-spent), dropped
            return 0;
        }
        if ($height && $self->branch_weight <= $best_block[$height]->weight) {
            return 0;
        }

        # set best branch
        for (my $b = $self; $b && (!$best_block[$b->height] || $best_block[$b->height]->hash ne $b->hash); $b = $b->prev_block) {
            $best_block[$b->height] = $b;
            if ($b->prev_block && (!$b->prev_block->next_block || $b->prev_block->next_block->hash ne $b->hash)) {
                $b->prev_block->next_block = $b;
            }
        }
        for (my $b = $self->next_block; $b; $b = $b->next_block) {
            $best_block[$b->height] = $b;
        }
        if (defined($height) && $self->height <= $height) {
            $self->generate_new();
            Infof("%s block height %s, best branch altered, weight %s hash %s",
                $self->received_from ? "received" : "loaded", $self->height, $self->weight,
                unpack("H*", substr($self->hash, 0, 4)));
        }
        else {
            Infof("%s block height %s in best branch, weight %s hash %s prev %s",
                $self->received_from ? "received" : "loaded", $self->height, $self->weight,
                unpack("H*", substr($self->hash, 0, 4)), unpack("H*", substr($self->prev_hash, 0, 4)));
        }
        if (!defined($height) || $self->height > $height) {
            # It's the first block in this level
            # Store and free old level (if it's linked and in best branch)
            $best_block[$self->height] = $self;
            $height //= -1;
            $height = $self->height;
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
                    }
                    foreach my $prev_hash (keys %{$prev_block[$free_height]}) {
                        delete $prev_block[$free_height]->{$prev_hash} unless %{$prev_block[$free_height]->{$prev_hash}};
                    }
                    if (!%{$block_pool[$free_height]}) {
                        $block_pool[$free_height] = undef;
                        $prev_block[$free_height] = undef;
                    }
                }
            }
        }
        $self->announce_to_peers();

        my $branch_height = $self->branch_height();
        if ($self->received_from && time() >= $self->time_by_height($branch_height+1)) {
            $self->received_from->send_line("sendblock " . ($branch_height+1));
        }
    }
    return 0;
}

sub prev_block {
    my $self = shift;
    if (@_) {
        if ($_[0]) {
            $_->[0]->hash eq $_->prev_hash
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
    my $self = shift;

    $self->prev_block(undef);
    delete $block_pool[$self->height]->{$self->hash};
    delete $prev_block[$self->height]->{$self->prev_hash}->{$self->hash};
    foreach my $descendant (values %{$prev_block[$self->height+1]->{$self->hash}}) {
        $descendant->drop_branch(); # recursively
    }
}

sub set_linked {
    my $self = shift;

    if ($self->validate_tx != 0) {
        $self->drop_branch;
        return -1;
    }
    $self->linked = 1;
    if ($prev_block[$self->height+1] && (my $descendants = $prev_block[$self->height+1]->{$self->hash})) {
        foreach my $descendant (values %$descendants) {
            $descendant->set_linked(); # recursively
        }
    }
    return 0;
}

sub announce_to_peers {
    my $self = shift;

    foreach my $peer (QBitcoin::Network->peers) {
        next if $self->received_from && $peer->ip eq $self->received_from->ip;
        $peer->send_line("ihave " . $self->height . " " . $self->weight);
    }
}

1;
