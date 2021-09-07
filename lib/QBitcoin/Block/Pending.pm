package QBitcoin::Block::Pending;
use warnings;
use strict;

use Tie::IxHash;
use QBitcoin::Const;
use QBitcoin::Log;
use Role::Tiny;

my %PENDING_BLOCK;
tie(%PENDING_BLOCK, 'Tie::IxHash'); # Ordered by age
my %PENDING_TX_BLOCK;
my %PENDING_BLOCK_BLOCK;

sub add_pending {
    my $self = shift;

    $PENDING_BLOCK{$self->hash} //= $self;

    if (keys %PENDING_BLOCK > MAX_PENDING_BLOCKS) {
        my ($oldest_block) = values %PENDING_BLOCK;
        $oldest_block->drop_pending();
    }
}

sub add_pending_block {
    my $self = shift;
    $PENDING_BLOCK_BLOCK{$self->prev_hash}->{$self->hash} = 1;
    $self->add_pending();
}

sub pending_descendants {
    my $self = shift;

    if (my $pending = $PENDING_BLOCK_BLOCK{$self->hash}) {
        return map { $PENDING_BLOCK{$_} } keys %$pending;
    }
    else {
        return ();
    }
}

sub drop_pending {
    my $self = shift;
    # and drop all blocks pending by this one
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels

    foreach my $next_block ($self->pending_descendants()) {
        # TODO: Change recursion to loop by block chain
        $next_block->drop_pending();
    }
    if ($PENDING_BLOCK{$self->hash}) {
        Debugf("Drop pending block %s height %u", $self->hash_str, $self->height);
        if ($self->pending_tx) {
            foreach my $tx_hash ($self->pending_tx) {
                delete $PENDING_TX_BLOCK{$tx_hash}->{$self->hash};
                if (!%{$PENDING_TX_BLOCK{$tx_hash}}) {
                    delete $PENDING_TX_BLOCK{$tx_hash};
                }
            }
        }
        if ($self->height && $PENDING_BLOCK_BLOCK{$self->prev_hash}) {
            delete $PENDING_BLOCK_BLOCK{$self->prev_hash}->{$self->hash};
            if (!%{$PENDING_BLOCK_BLOCK{$self->prev_hash}}) {
                delete $PENDING_BLOCK_BLOCK{$self->prev_hash};
            }
        }
        $self->free_tx();
        $self->del_as_descendant();
    }
    delete $PENDING_BLOCK{$self->hash};
}

sub process_pending {
    my $self = shift;
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels

    my $pending = delete $PENDING_BLOCK_BLOCK{$self->hash}
        or return $self;
    # TODO: change recursion to loop by block chain to avoid too deep recursion
    my $ret_block = $self;
    foreach my $hash (keys %$pending) {
        my $block_next = $PENDING_BLOCK{$hash};
        $block_next->prev_block($self);
        $block_next->add_as_descendant();
        next if $block_next->pending_tx;
        delete $PENDING_BLOCK{$hash};
        Debugf("Process block %s height %u pending for received %s", $block_next->hash_str, $block_next->height, $self->hash_str);
        $block_next->compact_tx();
        if ($block_next->receive() == 0) {
            $ret_block = $block_next->process_pending();
        }
        else {
            $block_next->drop_pending();
        }
    }
    return $ret_block;
}

sub is_pending {
    my $self = shift;
    return !!$PENDING_BLOCK{$self->hash};
}

sub recv_pending_tx {
    my $class = shift;
    my ($tx) = @_;
    my $height;
    if (my $blocks = delete $PENDING_TX_BLOCK{$tx->hash}) {
        foreach my $block_hash (keys %$blocks) {
            my $block = $PENDING_BLOCK{$block_hash};
            Debugf("Block %s is pending received tx %s", $block->hash_str, $tx->hash_str);
            $block->add_tx($tx);
            if (!$block->pending_tx && (!$block->height || !$PENDING_BLOCK_BLOCK{$block->prev_hash})) {
                delete $PENDING_BLOCK{$block->hash};
                $block->compact_tx();
                if ($block->receive() == 0) {
                    $block = $block->process_pending();
                    $height = $block->height if defined($height) && $height < $block->height;
                }
                else {
                    $block->drop_pending();
                    return -1;
                }
            }
        }
    }
    return $height;
}

sub load_transactions {
    my $self = shift;
    if (!$self->pending_tx) {
        foreach my $tx_hash (@{$self->tx_hashes}) {
            my $transaction = QBitcoin::Transaction->get_by_hash($tx_hash);
            if ($transaction) {
                $self->add_tx($transaction);
            }
            else {
                $self->pending_tx($tx_hash);
                $PENDING_TX_BLOCK{$tx_hash}->{$self->hash} = 1;
                Debugf("Set pending_tx %s block %s height %u", unpack("H*", substr($tx_hash, 0, 4)), $self->hash_str, $self->height);
            }
        }
        if ($self->pending_tx) {
            $self->add_pending();
        }
    }
    return ();
}

1;
