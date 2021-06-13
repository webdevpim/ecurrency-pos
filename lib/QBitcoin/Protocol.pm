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

use Tie::IxHash;
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::Crypto qw(checksum32);
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced);
use QBitcoin::Block;
use QBitcoin::Peers;
use QBitcoin::Mempool;
use QBitcoin::Transaction;

use constant ATTR => qw(
    greeted
    ip
    host
    port
    my_address
    my_port
    recvbuf
    sendbuf
    socket
    socket_fileno
    state
    direction
    state_time
    has_weight
    syncing
);

use constant {
    REJECT_INVALID => 1,
};

mk_accessors(ATTR);

my %PENDING_BLOCK;
tie(%PENDING_BLOCK, 'Tie::IxHash'); # Ordered by age
my %PENDING_TX_BLOCK;
my %PENDING_BLOCK_BLOCK;

sub new {
    my $class = shift;
    my $args = @_ == 1 ? $_[0] : { @_ };
    my $self = bless $args, $class;
    $self->sendbuf = "";
    $self->recvbuf = "";
    $self->socket_fileno = fileno($self->socket) if $self->socket;
    return $self;
}

sub disconnect {
    my $self = shift;
    if ($self->socket) {
        shutdown($self->socket, 2);
        close($self->socket);
        $self->socket = undef;
        $self->socket_fileno = undef;
    }
    if ($self->state eq STATE_CONNECTED) {
        Infof("Disconnected from peer %s", $self->ip);
        $self->greeted = undef;
    }
    $self->state_time = time();
    $self->state = STATE_DISCONNECTED;
    $self->sendbuf = "";
    $self->recvbuf = "";
    $self->has_weight = undef;
    $self->syncing = undef;
    QBitcoin::Peers->del_peer($self) if $self->direction eq DIR_IN;
    return 0;
}

sub receive {
    my $self = shift;
    while (length($self->sendbuf) < WRITE_BUFFER_SIZE) {
        length($self->recvbuf) >= 24 # sizeof(struct message_header)
            or return 0;
        my ($magic, $command, $length, $checksum) = unpack("a4a12Va4", substr($self->recvbuf, 0, 24));
        $command =~ s/\x00+\z//;
        if ($magic ne MAGIC) {
            Errf("Incorrect magic: 0x%08X, expected 0x%08X", $magic, $self->MAGIC);
            # $self->abort($command, "protocol_error");
            return -1;
        }
        if ($length + 24 > READ_BUFFER_SIZE) {
            Errf("Too long data packet for command %s, %u bytes", $command, $length);
            $self->abort($command, "too_long_packet");
            return -1;
        }
        # TODO: save state, to not process the same message header each time
        length($self->recvbuf) >= $length + 24
            or return 0;
        my $message = substr($self->recvbuf, 0, 24+$length, "");
        my $data = substr($message, 24);
        my $checksum32 = checksum32($data);
        if ($checksum ne $checksum32) {
            Errf("Incorrect message checksum, 0x%s != 0x%s", unpack("H*", $checksum), unpack("H*", $checksum32));
            $self->abort($command, "bad_crc32");
            return -1;
        }
        my $func = "cmd_" . $command;
        if ($self->can($func)) {
            Debugf("Received [%s] from peer %s", $command, $self->ip);
            if ($command ne "version" && !$self->greeted) {
                Errf("command [%s] before greeting from peer %s", $command, $self->ip);
                $self->abort($command, "protocol_error");
                return -1;
            }
            $self->$func($data) == 0
                or return -1;
        }
        else {
            Errf("Unknown command [%s] from peer %s", $command, $self->ip);
            $self->abort($command, "unknown_command");
            return -1;
        }
    }
}

sub send {
    my $self = shift;
    my ($data) = @_;

    if ($self->state ne STATE_CONNECTED) {
        Errf("Attempt to send to peer %s with state %s", $self->ip // "unknown", $self->state);
        return -1;
    }
    if ($self->sendbuf eq '' && $self->socket) {
        my $n = syswrite($self->socket, $data);
        if (!defined($n)) {
            Errf("Error write to socket: %s", $!);
            return -1;
        }
        elsif ($n > 0) {
            return 0 if $n == length($data);
            substr($data, 0, $n, "");
        }
        $self->sendbuf = $data;
    }
    else {
        $self->sendbuf .= $data;
    }
    return 0;
}

sub send_message {
    my $self = shift;
    my ($cmd, $data) = @_;
    Debugf("Send [%s] to peer %s", $cmd, $self->ip);
    return $self->send(pack("a4a12Va4", MAGIC, $cmd, length($data), checksum32($data)) . $data);
}

sub startup {
    my $self = shift;
    my $version = pack("VQ<Q<a26", $self->PROTOCOL_VERSION, $self->PROTOCOL_FEATURES, time(), $self->pack_my_address);
    $self->send_message("version", $version);
    return 0;
}

sub pack_my_address {
    my $self = shift;
    return pack("Q<a16n", $self->PROTOCOL_FEATURES, $self->my_address, $self->my_port);
}

sub cmd_version {
    my $self = shift;

    $self->send_message("verack", "");
    $self->greeted = 1;
    $self->request_mempool if blockchain_synced() && !mempool_synced();
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
    my ($cmd, $reason) = @_;
    $self->send_message("reject", pack("Ca*", $cmd) . pack("C", REJECT_INVALID) . pack("Ca*", $reason // "general_error"));
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
        Errf("Incorrect params from peer %s command %s: length %u", $self->ip, "sendtx", length($data));
        $self->abort("sendtx", "incorrect_params");
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
        Errf("Incorrect params from peer %s command %s: length %u", $self->ip, "ihavetx", length($data));
        $self->abort("ihavetx", "incorrect_params");
        return -1;
    }

    my $hash = unpack("a32", $data);
    blockchain_synced()
        or return 0;
    QBitcoin::Transaction->get_by_hash($hash)
        or return 0;
    $self->request_tx($hash);
    return 0;
}

sub cmd_block {
    my $self = shift;
    my ($block_data) = @_;
    my $block = QBitcoin::Block->deserialize($block_data);
    if (!$block) {
        $self->abort("block", "bad_block_data");
        return -1;
    }
    return 0 if QBitcoin::Block->block_pool($block->height, $block->hash);
    return 0 if $PENDING_BLOCK{$block->hash};

    $block->received_from = $self;

    if ($block->height && !$block->prev_block) {
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
    foreach my $hash (keys %$pending) {
        my $block_next = $PENDING_BLOCK{$hash};
        $block_next->prev_block($block);
        $self->_block_load_transactions($block_next);
        next if $block_next->pending_tx;
        delete $PENDING_BLOCK{$hash};
        Debugf("Process block %s height %u pending for received %s", $block_next->hash_str, $block_next->height, $block->hash_str);
        $block_next->compact_tx();
        if ($block_next->receive() == 0) {
            return $self->process_pending_blocks($block_next) // $block_next;
        }
        else {
            drop_pending_block($block_next);
            return undef;
        }
    }
    return $block;
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
        foreach my $tx_hash (keys %{$block->pending_tx}) {
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
    my $tx = QBitcoin::Transaction->deserialize($tx_data, $self);
    if (!defined $tx) {
        $self->abort("tx", "bad_tx_data");
        return -1;
    }
    elsif (!$tx) {
        # Ignore (skip) but do not drop connection, for example transaction already exists or has unknown input
        return 0;
    }
    $tx->receive() == 0
        or return -1;
    Debugf("Received tx %s fee %i size %u", $tx->hash_str, $tx->fee, $tx->size);
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
    if (blockchain_synced() && mempool_synced() && $tx->fee >= 0) {
        # announce to other peers
        $tx->announce($self);
    }
    $tx->process_pending($self);
    return 0;
}

sub request_new_block {
    my $self = shift;
    my ($height) = @_;

    if (!$self->syncing) {
        my $best_weight = QBitcoin::Block->best_weight;
        my $best_height = QBitcoin::Block->blockchain_height // -1;
        $height //= $best_height+1;
        $height = $best_height+1 if $height > $best_height+1;
        $height-- if $height > height_by_time(time());
        if ($self->has_weight > $best_weight ||
            $self->has_weight == $best_weight && $height > $best_height) {
            $self->send_message("sendblock", pack("V", $height));
            if ($self->has_weight > $best_weight) { # otherwise remote may have no such block, no syncing
                $self->syncing(1);
            }
        }
    }
}

sub cmd_ihave {
    my $self = shift;
    my ($data) = @_;
    if (length($data) != 44) {
        Errf("Incorrect params from peer %s command %s: length %u", $self->ip, "ihave", length($data));
        $self->abort("ihave", "incorrect_params");
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
    $self->request_new_block($height);
    return 0;
}

sub cmd_sendblock {
    my $self = shift;
    my $data = shift;
    if (length($data) != 4) {
        Errf("Incorrect params from peer %s cmd %s: length %u", $self->ip, "sendblock", length($data));
        $self->abort("sendblock", "incorrect_params");
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
        Errf("Incorrect params from peer %s cmd %s data size %u", $self->ip, "mempool", length($data));
        $self->abort("mempool", "incorrect_params");
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
        Errf("Incorrect params from peer %s cmd %s data size %u", $self->ip, "eomempool", length($data));
        $self->abort("eomempool", "incorrect_params");
        return -1;
    }
    $self->send_message("ping", pack("a8", "emempool"));
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
    mempool_synced(1) if $data eq "emempool";
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
