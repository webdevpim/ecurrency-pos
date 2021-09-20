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
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced btc_synced);
use QBitcoin::Block;
use QBitcoin::Transaction;
use QBitcoin::Peer;
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

sub type_id() { PROTOCOL_QBITCOIN }

sub startup {
    my $self = shift;
    my $version = pack("VQ<Q<a26", PROTOCOL_VERSION, PROTOCOL_FEATURES, time(), $self->pack_my_address);
    $self->send_message("version", $version);
    return 0;
}

sub pack_my_address {
    my $self = shift;
    return pack("Q<a16n", PROTOCOL_FEATURES, $self->connection->my_addr, $self->connection->my_port);
}

sub peer_id {
    my $self = shift;
    return $self->{peer_id} //= $self->peer->ip;
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
    $self->send_message("sendtx", $_) foreach @_;
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
    $self->peer->decrease_reputation;
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
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my $hash = unpack("a32", $data); # yes, it's copy of $data
    my $tx = QBitcoin::Transaction->get_by_hash($hash);
    if ($tx) {
        $self->send_message("tx", $tx->serialize . ($tx->received_from ? $tx->received_from->peer->ip : "\x00"x16));
    }
    else {
        Warningf("I have no transaction with hash %u requested by peer %s", $hash, $self->peer->id);
    }
    return 0;
}

sub cmd_ihavetx {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 32) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    blockchain_synced()
        or return 0;

    my $hash = unpack("a32", $data);
    if (QBitcoin::Transaction->check_by_hash($hash)) {
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
        Warningf("Bad block data length %u from peer %s", length($block_data), $self->peer->id);
        $self->abort("bad_block_data");
        return -1;
    }
    if (QBitcoin::Block->block_pool($block->height, $block->hash)) {
        Debugf("Received block %s already in block_pool", $block->hash_str);
        $self->syncing(0);
        if ($block->hash eq QBitcoin::Block->best_block($block->height)) {
            $self->request_new_block();
        }
        else {
            $self->request_new_block($block->height);
        }
        return 0;
    }
    if ($block->is_pending) {
        Debugf("Received block %s already pending, skip", $block->hash_str);
        $self->syncing(0);
        $self->request_new_block($block->height-1);
        return 0;
    }
    if ($block->height < (QBitcoin::Block->blockchain_height // -1)) {
        if (QBitcoin::Block->find(hash => $block->hash)) {
            Debugf("Received block %s already known, skip", $block->hash_str);
            $self->syncing(0);
            $self->request_new_block();
            return 0;
        }
    }

    $block->received_from = $self;
    $self->has_weight = $block->weight if ($self->has_weight // -1) < $block->weight;

    if ($block->height && !$block->prev_block_load) {
        if (QBitcoin::Block->is_pending($block->prev_hash)) {
            Debugf("Received block %s height %u has pending ancestor %s",
                $block->hash_str, $block->height, $block->hash_str($block->prev_hash));
            $block->load_transactions();
            $self->request_tx($block->pending_tx);
            $block->add_pending_block();
            return 0;
        }
        else {
            Debugf("Received block %s has unknown ancestor %s, request it",
                $block->hash_str, $block->hash_str($block->prev_hash));
            if ($block->height <= (QBitcoin::Block->blockchain_height // -1) - 3) {
                # deep rollback, request batch of new blocks using locators
                $self->request_blocks($block->height-1);
            }
            else {
                $block->load_transactions;
                $self->request_tx($block->pending_tx);
                $self->send_message("sendblock", pack("V", $block->height-1));
                $block->add_pending_block();
            }
            $self->syncing(1);
            return 0;
        }
    }

    $block->load_transactions($block);
    $self->syncing(0);
    if ($block->pending_tx) {
        $block->add_as_descendant();
        $self->request_tx($block->pending_tx);
    }
    else {
        $block->compact_tx();
        if ($block->receive() == 0) {
            $block = $block->process_pending();
            $self->request_new_block($block->height+1);
            return 0;
        }
        else {
            $block->drop_pending();
            return -1;
        }
    }
    return 0;
}

# Almost same as "block", but batch of blocks, and do not request next block after each processed
sub cmd_blocks {
    my $self = shift;
    my ($blocks_data) = @_;
    if (length($blocks_data) == 0) {
        Warningf("Bad (empty) blocks params from peer %s", $self->peer->id);
        $self->abort("incorrect_params");
        return -1;
    }
    my $data = Bitcoin::Serialized->new($blocks_data);
    my $num_blocks = unpack("C", $data->get(1));
    my $block;
    my $got_new;
    foreach my $num (1 .. $num_blocks) {
        my $prev_block = $block;
        $block = QBitcoin::Block->deserialize($data);
        if (!$block) {
            Warningf("Bad blocks data length from peer %s", $self->peer->id);
            $self->abort("bad_block_data");
            return -1;
        }
        Infof("Receive blocks height %u..%u", $block->height, $block->height+$num_blocks-1) if $num == 1;
        if (QBitcoin::Block->block_pool($block->height, $block->hash)) {
            Debugf("Received block %s height %u already in block_pool, skip", $block->hash_str, $block->height);
            next;
        }
        if ($block->is_pending) {
            Debugf("Received block %s height %u already pending, skip", $block->hash_str, $block->height);
            last;
        }
        if ($block->height < (QBitcoin::Block->blockchain_height // -1)) {
            if (QBitcoin::Block->find(hash => $block->hash)) {
                Debugf("Received block %s height %u already known, skip", $block->hash_str, $block->height);
                next;
            }
        }

        $block->received_from = $self;
        $self->has_weight = $block->weight if ($self->has_weight // -1) < $block->weight;

        if ($num > 1) {
            if ($block->prev_hash ne $prev_block->hash) {
                Warningf("Received blocks are not in chain from peer %s", $self->peer->id);
                $self->abort("bad_block_data");
                return -1;
            }
            if (!$block->prev_block_load) {
                # some of ancestor blocks are pending tx?
                $block->load_transactions();
                $self->request_tx($block->pending_tx);
                $block->add_pending_block();
                $got_new++;
                next;
            }
        }
        elsif ($block->height && !$block->prev_block_load) {
            if (QBitcoin::Block->is_pending($block->prev_hash)) {
                Debugf("Received block %s height %u has pending ancestor %s",
                    $block->hash_str, $block->height, $block->hash_str($block->prev_hash));
                $block->load_transactions();
                $self->request_tx($block->pending_tx);
                $block->add_pending_block();
                next;
            }
            else {
                Debugf("Received block %s height %u has unknown ancestor %s, request it",
                    $block->hash_str, $block->height, $block->hash_str($block->prev_hash));
                if ($block->height <= (QBitcoin::Block->blockchain_height // -1) - 3) {
                    # deep rollback, request batch of new blocks using locators
                    $self->request_blocks($block->height-1);
                }
                else {
                    $block->load_transactions();
                    $self->request_tx($block->pending_tx);
                    $self->send_message("sendblock", pack("V", $block->height-1));
                    $block->add_pending_block();
                }
                $self->syncing(1);
                return 0;
            }
        }

        $block->load_transactions();
        if ($block->pending_tx) {
            $self->request_tx($block->pending_tx);
            $block->add_as_descendant();
        }
        else {
            $block->compact_tx();
            if ($block->receive() == 0) {
                $block = $block->process_pending();
            }
            else {
                $block->drop_pending();
                return -1;
            }
        }
        $got_new++;
    }
    $self->syncing(0);
    if ($got_new) {
        if ($num_blocks == BLOCKS_IN_BATCH && $block->height < height_by_time(time())) {
            $self->send_message("getblks", pack("Vv", $block->height+1, 1) . $block->hash);
            $self->syncing(1);
        }
        elsif (!$block->is_pending) { # Do not request new blocks if we're waiting for requested transactions
            $self->request_new_block($block->height+1);
        }
    }
    else {
        $self->request_new_block();
    }
    return 0;
}

sub cmd_tx {
    my $self = shift;
    my ($tx_data) = @_;
    my $data = Bitcoin::Serialized->new($tx_data);
    my $tx = QBitcoin::Transaction->deserialize($data);
    if (!$tx || $data->length != 16) {
        $self->abort("bad_tx_data");
        return -1;
    }
    $tx->rcvd = $data->get(16);
    $tx->received_from = $self;
    if (!$tx->load_txo()) {
        $self->abort("bad_tx_data");
        return -1;
    }
    if ($tx->is_pending || $tx->is_known) {
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

    $tx->validate_hash() == 0
        or return -1;
    $tx->validate() == 0
        or return -1;
    $tx->receive() == 0
        or return -1;
    Debugf("Process tx %s fee %i size %u", $tx->hash_str, $tx->fee, $tx->size);
    if (defined(my $height = QBitcoin::Block->recv_pending_tx($tx))) {
        return -1 if $height == -1;
        # $self->request_new_block($height+1);
    }
    $tx->process_pending($self);
    if ($tx->fee >= 0) {
        if (blockchain_synced() && mempool_synced()) {
            # announce to other peers
            $tx->announce($self);
            if ($tx->fee > 0 || $tx->up) {
                $self->peer->add_reputation($tx->up ? 200 : 2);
                if ($tx->rcvd && $self->peer->ip ne $tx->rcvd && $tx->rcvd ne "\x00"x16) {
                    my $src_peer = QBitcoin::Peer->get_or_create(type_id => PROTOCOL_QBITCOIN, ip => $tx->rcvd);
                    $src_peer->add_reputation($tx->up ? 100 : 1);
                }
            }
        }
    }
    elsif (!$tx->in_blocks && !$tx->block_height) {
        Debugf("Ignore stake transactions %s not related to any known block", $tx->hash_str);
        $tx->drop();
    }
    return 0;
}

sub request_new_block {
    my $self = shift;
    my ($height) = @_;

    if (!$self->syncing) {
        my $best_weight = QBitcoin::Block->best_weight;
        my $best_height = QBitcoin::Block->blockchain_height // -1;
        my $current_height = height_by_time(time());
        $height //= $best_height+1;
        $height-- if $height > $current_height;
        if (($self->has_weight // -1) > $best_weight ||
            (($self->has_weight // -1) == $best_weight && $height > $best_height)) {
            # Should we request batch blocks if $self->has_weight == $best_weight?
            # If yes, it's possible to request the same batch in infinite loop when remote has no new blocks
            # If no, we will request long chain of empty blocks one-by-one
            # It seems we should not request_new_block after receiving batch without any new block
            if ($height < $current_height - 5 && ($self->has_weight // -1) > $best_weight) {
                $self->request_blocks($height);
                $self->syncing(1);
            }
            else {
                if (($self->has_weight // -1) > $best_weight) { # otherwise remote may have no such block, no syncing
                    $self->syncing(1);
                    Debugf("Remote %s have block weight more than our, request block %u", $self->peer->id, $height);
                }
                $self->send_message("sendblock", pack("V", $height));
            }
        }
    }
}

# Request batch of blocks using locators (hashes of our blocks in the best branch)
sub request_blocks {
    my $self = shift;
    my ($top_height) = @_;
    my @blocks = QBitcoin::Block->find(height => { '<=' => $top_height }, -sortby => 'height DESC', -limit => 10);
    my @locators = map { $_->hash } @blocks;
    my $low_height = $top_height;
    if (@locators) {
        my $step = 4;
        my $height = $blocks[-1]->height - $step;
        my @height;
        while ($height > 0 && @height < 32) {
            push @height, $height;
            $step *= 2;
            $step = BLOCK_LOCATOR_INTERVAL if $step > BLOCK_LOCATOR_INTERVAL;
            $height -= $step;
        };
        push @height, 0 if @height < 32;
        push @locators, map { $_->hash } QBitcoin::Block->find(-sortby => 'height DESC', height => \@height);
        $low_height = $height[-1];
    }
    Debugf("Request batch blocks between height %u and %u", $low_height, $top_height);
    $self->send_message("getblks", pack("Vv", $low_height, scalar(@locators)) . join("", @locators));
}

sub cmd_getblks {
    my $self = shift;
    my ($data) = @_;
    my $datalen = length($data);
    if ($datalen < 6) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my ($low_height, $locators) = unpack("Vv", substr($data, 0, 6));
    if ($datalen != 6+32*$locators) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my %locators = map { substr($data, 6+$_*32, 32) => 1 } 0 .. $locators-1;
    # Loop by incore levels is not good but better than loop by locators
    my $height;
    my $min_incore_height = QBitcoin::Block->min_incore_height;
    for ($height = QBitcoin::Block->blockchain_height; $height >= $min_incore_height; $height--) {
        my $block = QBitcoin::Block->best_block($height)
            or last;
        last if $locators{$block->hash};
    }
    my $sent = 0;
    my $response = "";
    if ($height < $min_incore_height) {
        # No matched blocks in memory pool, search by database
        my ($block) = QBitcoin::Block->find(hash => [ keys %locators ], -sortby => 'height DESC', -limit => 1);
        if ($block) {
            $height = $block->height;
        }
        else {
            # No block for any locator found, send only one block with $low_height for continue synchronization
            $block = QBitcoin::Block->best_block($low_height);
            if ($block) {
                Debugf("No block for any locator found, send block %s height %u", $block->hash_str, $block->height);
                $self->send_message("block", $block->serialize);
            }
            elsif ($block = QBitcoin::Block->find(height => $low_height)) {
                Debugf("No block for any locator found, send block %s height %u", $block->hash_str, $block->height);
                $self->send_message("block", $block->serialize);
            }
            else {
                Warningf("I have no block with height %u requested by peer %s", $height, $self->peer->id);
            }
            return 0;
        }
        foreach my $block (QBitcoin::Block->find(height => { '>' => $height }, -sortby => 'height ASC', -limit => BLOCKS_IN_BATCH)) {
            $response .= $block->serialize;
            $height = $block->height;
            $sent++;
        }
    }
    my $max_height = QBitcoin::Block->blockchain_height;
    while ($height++ < $max_height && $sent < BLOCKS_IN_BATCH) {
        my $block = QBitcoin::Block->best_block($height);
        if ($block) {
            $response .= $block->serialize;
            $sent++;
        }
        else {
            Warningf("Can't find best block height %u", $height--);
            last;
        }
    }
    if ($sent) {
        Infof("Send blocks height %u .. %u to %s", $height-$sent, $height-1, $self->peer->id);
        $self->send_message("blocks", pack("C", $sent) . $response);
    }
    return 0;
}

sub cmd_ihave {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 44) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
        $self->abort("incorrect_params");
        return -1;
    }
    my ($height, $weight, $hash) = unpack("VQ<a32", $data);
    if (time() < time_by_height($height)) {
        Warningf("Ignore too early block height %u from peer %s", $height, $self->peer->id);
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
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
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
        Warningf("I have no block with height %u requested by peer %s", $height, $self->peer->id);
    }
    return 0;
}

sub cmd_mempool {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 0) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
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
        Errf("Incorrect params from peer %s command %s: length %u", $self->peer->id, $self->command, length($data));
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
    Warningf("%s peer %s aborted connection", $self->type, $self->peer->id);
    return -1;
}

1;
