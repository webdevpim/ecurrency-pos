package QBitcoin::Protocol;
use warnings;
use strict;

# TCP exchange with a peer
# Single connection
# Commands:
# >> version <options>
# << verack <options>
# >> ihave <height> <weight> <hash>
# << sendblock <height>
# >> block <size>
# >> ...
# >> end

# First "ihave" with the best existing height/weight send directly after connection from both sides

# >> ihavetx <txid> <size> <fee>
# << sendtx <txid>
# >> tx <size>
# >> ...

# << mempool
# >> ihavetx <txid> <size> <fee>
# >> ...
# >> eomempool

# Send "mempool" to the first connected node after start, then (after get it) switch to "synced" mode

# >> ping <payload>
# << pong <payload>
# Use "ping emempool" -> "pong emempool" for set mempool_synced state, this means all mempool transactions requested and sent

# If our last known block height less than height_by_time, then batch request all blocks with height from last known to max available

use parent 'QBitcoin::Protocol::Common';
use Tie::IxHash;
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced btc_synced);
use QBitcoin::Block;
use QBitcoin::Transaction;
use Bitcoin::Serialized;

use Role::Tiny::With;
with 'QBitcoin::Protocol::BTC' if UPGRADE_POW;

use constant {
    MAGIC             => "QBTC",
    PROTOCOL_VERSION  => 1,
    PROTOCOL_FEATURES => 0,
};

use constant {
    REJECT_INVALID => 1,
};

my %PENDING_BLOCK;
tie(%PENDING_BLOCK, 'Tie::IxHash'); # Ordered by age
my %PENDING_TX_BLOCK;
my %PENDING_BLOCK_BLOCK;

sub type() { "QBitcoin" }

sub startup {
    my $self = shift;
    my $version = pack("VQ<Q<a26", PROTOCOL_VERSION, PROTOCOL_FEATURES, time(), $self->pack_my_address);
    $self->send_message("version", $version);
    return 0;
}

sub pack_my_address {
    my $self = shift;
    return pack("Q<a16n", PROTOCOL_FEATURES, $self->my_addr, $self->my_port);
}

sub cmd_version {
    my $self = shift;

    $self->send_message("verack", "");
    $self->greeted = 1;
    $self->request_btc_blocks() if UPGRADE_POW && !btc_synced();
    $self->request_mempool if blockchain_synced() && !mempool_synced() && (!UPGRADE_POW || btc_synced());
    $self->announce_best_btc_block() if UPGRADE_POW;
    my $height = QBitcoin::Block->blockchain_height;
    if (defined($height)) {
        my $best_block = QBitcoin::Block->best_block($height);
        $self->announce_block($best_block);
    }
    return 0;
}

sub cmd_verack {
    my $self = shift;
    return 0;
}

sub request_tx {
    my $self = shift;
    my ($hash) = @_;
    $self->send_message("sendtx", $hash);
}

sub announce_tx {
    my $self = shift;
    my ($tx) = @_;
    $self->send_message("ihavetx", $tx->hash);
}

sub request_mempool {
    my $self = shift;
    $self->send_message("mempool", "");
}

sub abort {
    my $self = shift;
    my ($reason) = @_;
    $self->send_message("reject", pack("C/a*", $self->command) . pack("C", REJECT_INVALID) . pack("C/a*", $reason // "general_error"));
}

sub announce_block {
    my $self = shift;
    my ($block) = @_;
    $self->send_message("ihave", pack("VQ<a32", $block->height, $block->weight, $block->hash));
}

sub cmd_sendtx {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 32) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->ip, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my $hash = unpack("a32", $data); # yes, it's copy of $data
    my $tx = QBitcoin::Transaction->get_by_hash($hash);
    if ($tx) {
        $self->send_message("tx", $tx->serialize);
    }
    else {
        Warningf("I have no transaction with hash %u requested by peer %s", $hash, $self->ip);
    }
    return 0;
}

sub cmd_ihavetx {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 32) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->ip, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    blockchain_synced()
        or return 0;

    my $hash = unpack("a32", $data);
    if (QBitcoin::Transaction->get_by_hash($hash)) {
        return 0;
    }
    $self->request_tx($hash);
    return 0;
}

sub cmd_block {
    my $self = shift;
    my ($block_data) = @_;
    my $data = Bitcoin::Serialized->new($block_data);
    my $block = QBitcoin::Block->deserialize($data);
    if (!$block || $data->length) {
        Warningf("Bad block data length %u from peer %s", length($block_data), $self->ip);
        $self->abort("bad_block_data");
        return -1;
    }
    if (QBitcoin::Block->block_pool($block->height, $block->hash)) {
        Debugf("Received block %s already in block_pool, skip", $block->hash_str);
        $self->syncing(0);
        $self->request_new_block();
        return 0;
    }
    if ($PENDING_BLOCK{$block->hash}) {
        Debugf("Received block %s already pending, skip", $block->hash_str);
        $self->syncing(0);
        $self->request_new_block($block->height-1);
        return 0;
    }
    if ($block->height < (QBitcoin::Block->blockchain_height // -1)) {
        if (my $stored_block = QBitcoin::Block->find(hash => $block->hash)) {
            Debugf("Received block %s already known, skip", $block->hash_str);
            $stored_block->free_block();
            $self->syncing(0);
            $self->request_new_block();
            return 0;
        }
    }

    $block->received_from = $self;

    if ($block->height && !$block->prev_block_load) {
        Debugf("Received block %s has unknown ancestor %s, request it",
            $block->hash_str, $block->hash_str($block->prev_hash));
        $self->send_message("sendblock", pack("V", $block->height-1));
        $PENDING_BLOCK_BLOCK{$block->prev_hash}->{$block->hash} = 1;
        add_pending_block($block);
        $self->syncing(1);
        return 0;
    }

    $self->_block_load_transactions($block);
    if (!$block->pending_tx) {
        $self->syncing(0);
        $block->compact_tx();
        if ($block->receive() == 0) {
            $block = $self->process_pending_blocks($block);
            $self->request_new_block($block->height+1);
            return 0;
        }
        else {
            drop_pending_block($block);
            return -1;
        }
    }
    return 0;
}

sub process_pending_blocks {
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels
    my $self = shift;
    my ($block) = @_;

    my $pending = delete $PENDING_BLOCK_BLOCK{$block->hash}
        or return $block;
    # TODO: change recursion to loop by block chain to avoid too deep recursion
    my $ret_block = $block;
    foreach my $hash (keys %$pending) {
        my $block_next = $PENDING_BLOCK{$hash};
        $block_next->prev_block($block);
        $self->_block_load_transactions($block_next);
        next if $block_next->pending_tx;
        delete $PENDING_BLOCK{$hash};
        Debugf("Process block %s height %u pending for received %s", $block_next->hash_str, $block_next->height, $block->hash_str);
        $block_next->compact_tx();
        if ($block_next->receive() == 0) {
            $ret_block = $self->process_pending_blocks($block_next);
        }
        else {
            drop_pending_block($block_next);
        }
    }
    return $ret_block;
}

sub drop_pending_block {
    # and drop all blocks pending by this one
    no warnings 'recursion'; # recursion may be deeper than perl default 100 levels
    my ($block) = @_;

    Debugf("Drop pending block %s height %u", $block->hash_str, $block->height);
    if (my $pending = $PENDING_BLOCK_BLOCK{$block->hash}) {
        foreach my $next_block (keys %$pending) {
            drop_pending_block($PENDING_BLOCK{$next_block});
        }
    }
    if ($block->pending_tx) {
        foreach my $tx_hash (@{$block->pending_tx}) {
            delete $PENDING_TX_BLOCK{$tx_hash}->{$block->hash};
            if (!%{$PENDING_TX_BLOCK{$tx_hash}}) {
                delete $PENDING_TX_BLOCK{$tx_hash};
            }
        }
    }
    if ($block->height && $PENDING_BLOCK_BLOCK{$block->prev_hash}) {
        delete $PENDING_BLOCK_BLOCK{$block->prev_hash}->{$block->hash};
        if (!%{$PENDING_BLOCK_BLOCK{$block->prev_hash}}) {
            delete $PENDING_BLOCK_BLOCK{$block->prev_hash};
        }
    }
    $block->free_tx();
    delete $PENDING_BLOCK{$block->hash};
}

sub add_pending_block {
    my ($block) = @_;

    $PENDING_BLOCK{$block->hash} //= $block;

    if (keys %PENDING_BLOCK > MAX_PENDING_BLOCKS) {
        my ($oldest_block) = values %PENDING_BLOCK;
        drop_pending_block($oldest_block);
    }
}

sub _block_load_transactions {
    my $self = shift;
    my ($block) = @_;
    foreach my $tx_hash (@{$block->tx_hashes}) {
        my $transaction = QBitcoin::Transaction->get_by_hash($tx_hash);
        if ($transaction) {
            $block->add_tx($transaction);
        }
        else {
            $block->pending_tx($tx_hash);
            $PENDING_TX_BLOCK{$tx_hash}->{$block->hash} = 1;
            Debugf("Set pending_tx %s block %s", unpack("H*", substr($tx_hash, 0, 4)), $block->hash_str);
            $self->request_tx($tx_hash);
        }
    }
    if ($block->pending_tx) {
        add_pending_block($block);
        return 0;
    }
    return $block;
}

sub cmd_tx {
    my $self = shift;
    my ($tx_data) = @_;
    my $data = Bitcoin::Serialized->new($tx_data);
    my $tx = QBitcoin::Transaction->deserialize($data, $self);
    if (!defined $tx || $data->length) {
        $self->abort("bad_tx_data");
        return -1;
    }
    elsif (!$tx) {
        # Ignore (skip) but do not drop connection, for example transaction already exists or has unknown input
        return 0;
    }
    if ($self->process_tx($tx) == -1) {
        $self->abort("bad_tx_data");
        return -1;
    }
    return 0;
}

sub process_tx {
    my $self = shift;
    my ($tx) = @_;

    $tx->validate() == 0
        or return -1;
    $tx->receive() == 0
        or return -1;
    Debugf("Process tx %s fee %i size %u", $tx->hash_str, $tx->fee, $tx->size);
    if ($self->block_pending_tx($tx)) {
        return -1;
    }
    if ($tx->fee >= 0) {
        if (blockchain_synced() && mempool_synced()) {
            # announce to other peers
            $tx->announce($self);
        }
    }
    elsif (!$tx->in_blocks) {
        Debugf("Ignore stake transactions %s not related to any known block", $tx->hash_str);
        $tx->drop();
    }
    $tx->process_pending($self);
    return 0;
}

sub block_pending_tx {
    my $self = shift;
    my ($tx) = @_;
    if (my $blocks = delete $PENDING_TX_BLOCK{$tx->hash}) {
        foreach my $block_hash (keys %$blocks) {
            my $block = $PENDING_BLOCK{$block_hash};
            Debugf("Block %s is pending received tx %s", $block->hash_str, $tx->hash_str);
            $block->add_tx($tx);
            if (!$block->pending_tx && (!$block->height || !$PENDING_BLOCK_BLOCK{$block->prev_hash})) {
                delete $PENDING_BLOCK{$block->hash};
                $self->syncing(0);
                $block->compact_tx();
                if ($block->receive() == 0) {
                    $block = $self->process_pending_blocks($block);
                    $self->request_new_block($block->height+1);
                }
                else {
                    drop_pending_block($block);
                    return -1;
                }
            }
        }
    }
    return undef;
}

sub request_new_block {
    my $self = shift;
    my ($height) = @_;

    if (!$self->syncing) {
        my $best_weight = QBitcoin::Block->best_weight;
        my $best_height = QBitcoin::Block->blockchain_height // -1;
        $height //= $best_height+1;
        $height-- if $height > height_by_time(time());
        if (($self->has_weight // -1) > $best_weight ||
            (($self->has_weight // -1) == $best_weight && $height > $best_height)) {
            $self->send_message("sendblock", pack("V", $height));
            if (($self->has_weight // -1) > $best_weight) { # otherwise remote may have no such block, no syncing
                $self->syncing(1);
                Debugf("Remote %s have block weight more than our, request block %u", $self->ip, $height);
            }
        }
    }
}

sub cmd_ihave {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 44) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->ip, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my ($height, $weight, $hash) = unpack("VQ<a32", $data);
    if (time() < time_by_height($height)) {
        Warningf("Ignore too early block height %u from peer %s", $height, $self->ip);
        return 0;
    }
    if ($weight < ($self->has_weight // -1)) {
        Warningf("Remote %s decreases weight %u => %u", $self->has_weight, $weight);
        $self->syncing(0); # prevent blocking connection on infinite wait
    }
    $self->has_weight = $weight;
    if (!UPGRADE_POW || btc_synced()) {
        my $max_height = QBitcoin::Block->max_incore_height;
        $self->request_new_block($height > $max_height ? $max_height+1 : $height);
    }
    return 0;
}

sub cmd_sendblock {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 4) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->ip, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my $height = unpack("V", $data);
    my $block = QBitcoin::Block->best_block($height);
    if ($block) {
        $self->send_message("block", $block->serialize);
    }
    elsif ($block = QBitcoin::Block->find(height => $height)) {
        $self->send_message("block", $block->serialize);
        $block->free_block();
    }
    else {
        Warningf("I have no block with height %u requested by peer %s", $height, $self->ip);
    }
    return 0;
}

sub cmd_mempool {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 0) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->ip, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    foreach my $tx (QBitcoin::Transaction->mempool_list) {
        $self->announce_tx($tx);
    }
    $self->send_message("eomempool", "");
    return 0;
}

sub cmd_eomempool {
    my $self = shift;
    my $data = shift;
     if (length($data) != 0) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->ip, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    $self->send_message("ping", pack("a8", "emempool"));
    $self->ping_sent = time();
    return 0;
}

sub cmd_ping {
    my $self = shift;
    my ($data) = @_;
    $self->send_message("pong", $data);
    return 0;
}

sub cmd_pong {
    my $self = shift;
    my ($data) = @_;
    if ($data eq "emempool") {
        mempool_synced(1);
        Infof("Mempool is synced, %u transactions", scalar QBitcoin::Transaction->mempool_list());
    }
    $self->ping_sent = undef;
    return 0;
}

sub cmd_reject {
    my $self = shift;
    Warningf("Peer %s aborted connection", $self->ip);
    return -1;
}

sub decrease_reputation {
    my $self = shift;
    ...;
    return 0;
}

1;
