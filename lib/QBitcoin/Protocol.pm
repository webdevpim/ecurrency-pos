package QBitcoin::Protocol;
use warnings;
use strict;

# TCP exchange with a peer
# Single connection
# Commands:
# >> qbtc <genesis-hash> <options>
# << qbtc <genesis-hash> <options>
# >> ihave <height> <weight>
# << sendblock <height>
# >> block <size>
# >> ...
# >> end

# First "ihave" with the best existing height/weight send directly after connection from both sides

# >> mempool <txid> <size> <fee>
# << sendtx <txid>
# >> tx <size>
# >> ...

# << sendmempool
# >> mempool <txid> <size> <fee>
# >> ...
# >> endofmempool

# Send "sendmempool" to the first connected node after start, then (after get it) switch to "synced" mode

# >> ping <payload>
# << pong <payload>
# Use "ping syncmempool" -> "pong syncmempool" for set mempool_synced state, this means all mempool transactions requested and sent

# If our last known block height less than height_by_time, then batch request all blocks with height from last known to max available

use Tie::IxHash;
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced);
use QBitcoin::Block;
use QBitcoin::Peers;
use QBitcoin::Mempool;
use QBitcoin::Transaction;

use constant INT_POSITIVE_RE => qw/^[1-9][0-9]*\z/;
use constant INT_UNSIGNED_RE => qw/^(?:0|[1-9][0-9]*)\z/;

use constant ATTR => qw(
    greeted
    ip
    host
    wait_data
    process_func
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
        if ($self->wait_data) {
            return 0 if length($self->recvbuf) < $self->wait_data;
            my $process_func = $self->process_func
                or die "Unknown process_func";
            $self->$process_func(substr($self->recvbuf, 0, $self->wait_data, "")) == 0
                or return -1;
            $self->wait_data = 0;
            $self->process_func(undef);
            next;
        }
        my $p = index($self->recvbuf, "\n");
        if ($p < 0) {
            if (length($self->recvbuf) > MAX_COMMAND_LENGTH) {
                Errf("Too long line from peer %s", $self->ip);
                $self->send_line("abort protocoll_error");
                return -1;
            }
            return 0;
        }
        my $str = substr($self->recvbuf, 0, $p+1, "");
        $str =~ s/\r?\n\z//;
        my ($cmd, @args) = split(/\s+/, $str);
        my $func = "cmd_" . $cmd;
        if ($self->can($func)) {
            Debugf("Received [%s] from peer %s", $str, $self->ip);
            if ($cmd ne "qbtc" && !$self->greeted) {
                Errf("command [%s] before greeting from peer %s", $cmd, $self->ip);
                $self->send_line("abort protocoll_error");
                return -1;
            }
            $self->$func(@args) == 0
                or return -1;
        }
        else {
            Errf("Unknown command [%s] from peer %s", $cmd, $self->ip);
            $self->send_line("abort unknown_command");
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

sub send_line {
    my $self = shift;
    my ($str) = @_;

    Debugf("Send [%s] to peer %s", $str, $self->ip);
    return $self->send($str . "\n");
}

sub startup {
    my $self = shift;
    $self->send_line("qbtc " . GENESIS_HASH_HEX) == 0
        or return -1;
    $self->send_line("sendmempool") if blockchain_synced() && !mempool_synced();
    my $height = QBitcoin::Block->blockchain_height;
    if (defined($height)) {
        my $best_block = QBitcoin::Block->best_block($height);
        $self->send_line("ihave " . $best_block->height . " " . $best_block->weight);
    }
    return 0;
}

sub cmd_block {
    my $self = shift;
    my @args = @_;
    if (@args != 2 || ref($args[0]) || !defined($args[0]) || $args[0] !~ INT_POSITIVE_RE) {
        Errf("Incorrect params from peer %s: [%s]", $self->ip, "block " . join(' ', @args));
        $self->send_line("abort incorrect_params");
        return -1;
    }
    my $size = $args[0];
    if ($size > MAX_BLOCK_SIZE) {
        Errf("Too large block %u bytes from peer %s", $size, $self->ip);
        $self->send_line("abort too_large_block");
        return -1;
    }
    $self->wait_data = $size;
    $self->process_func = 'process_block';
    return 0;
}

sub process_block {
    my $self = shift;
    my ($block_data) = @_;
    my $block = QBitcoin::Block->deserialize($block_data);
    if (!$block) {
        $self->send_line("abort bad_block_data");
        return -1;
    }
    return 0 if QBitcoin::Block->block_pool($block->height, $block->hash);
    return 0 if $PENDING_BLOCK{$block->hash};

    $block->received_from = $self;

    if ($block->height && !$block->prev_block) {
        $self->send_line("sendblock " . ($block->height-1));
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
    # TODO: move this to Block::Receive, take care about %PENDING_BLOCK and %PENDING_TX_BLOCK
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
            $self->send_line("sendtx " . unpack("H*", $tx_hash));
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
    my @args = @_;
    if (@args != 2 || ref($args[0]) || !defined($args[0]) || $args[0] !~ INT_POSITIVE_RE) {
        Errf("Incorrect params from peer %s: [%s]", $self->ip, "tx " . join(' ', @args));
        $self->send_line("abort incorrect_params");
        return -1;
    }
    my $size = $args[0];
    if ($size > MAX_TX_SIZE) {
        Errf("Too large tx %u bytes from peer %s", $size, $self->ip);
        $self->send_line("abort too_large_tx");
        return -1;
    }
    $self->wait_data = $size;
    $self->process_func = 'process_tx';
    return 0;
}

sub process_tx {
    my $self = shift;
    my ($tx_data) = @_;
    my $tx = QBitcoin::Transaction->deserialize($tx_data, $self);
    if (!defined $tx) {
        $self->send_line("abort bad_tx_data");
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
            $self->send_line("sendblock $height");
            if ($self->has_weight > $best_weight) { # otherwise remote may have no such block, no syncing
                $self->syncing(1);
            }
        }
    }
}

sub cmd_qbtc {
    my $self = shift;
    my ($genesis_hash, @options) = @_;
    if (!$genesis_hash || ref($genesis_hash) || $genesis_hash ne GENESIS_HASH_HEX) {
        Errf("Bad genesis hash from peer %s: %s, expected %s",
            $self->ip, $genesis_hash // '', GENESIS_HASH_HEX);
        $self->send_line("abort incorrect_genesis");
        return -1;
    }
    # Ignore options;
    $self->greeted = 1;
    return 0;
}

sub cmd_ihave {
    my $self = shift;
    my ($height, $weight) = @_;
    if (@_ != 2 || !defined($height) || ref($height) || $height !~ INT_UNSIGNED_RE || 
        !defined($weight) || ref($weight) || $weight !~ INT_UNSIGNED_RE) {
        Errf("Incorrect params from peer %s: [%s]", $self->ip, "ihave " . join(' ', @_));
        $self->send_line("abort incorrect_params");
        return -1;
    }
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
    my @args = @_;
    if (@args != 1 || ref($args[0]) || !defined($args[0]) || $args[0] !~ INT_UNSIGNED_RE) {
        Errf("Incorrect params from peer %s: [%s]", $self->ip, "sendblock " . join(' ', @args));
        $self->send_line("abort incorrect_params");
        return -1;
    }
    my $height = $args[0];
    my $block = QBitcoin::Block->best_block($height);
    if ($block) {
        my $data = $block->serialize;
        $self->send_line("block " . length($data) . " " . $block->height);
        $self->send($data);
    }
    else {
        Warningf("I have no block with height %u requested by peer %s", $height, $self->ip);
    }
    return 0;
}

sub cmd_mempool {
    my $self = shift;
    my ($hash, $size, $fee) = @_;
    if (@_ != 3 || !defined($hash) || ref($hash) ||
        !defined($size) || ref($size) || $size !~ INT_UNSIGNED_RE || $size == 0 ||
        !defined($fee)  || ref($fee)  || $fee  !~ INT_UNSIGNED_RE) {
        Errf("Incorrect params from peer %s: [%s]", $self->ip, "mempool " . join(' ', @_));
        $self->send_line("abort incorrect_params");
        return -1;
    }
    if (!blockchain_synced()) {
        return 0;
    }
    if (QBitcoin::Transaction->get_by_hash(pack("H*", $hash))) {
        return 0;
    }
    # Comparing floating points, it's ok, we can randomly accept or reject transaction with fee around lower limit
    # min_fee() returns -1 if mempool size less than limit
    QBitcoin::Mempool->want_tx($size, $fee)
        or return 0;
    $self->send_line("sendtx $hash");
    return 0;
}

sub cmd_sendtx {
    my $self = shift;
    my @args = @_;
    if (@args != 1 || ref($args[0]) || !defined($args[0])) {
        Errf("Incorrect params from peer %s: [%s]", $self->ip, "sendtx " . join(' ', @args));
        $self->send_line("abort incorrect_params");
        return -1;
    }
    my ($hash) = shift;
    my $tx = QBitcoin::Transaction->get_by_hash(pack("H*", $hash));
    if ($tx) {
        my $data = $tx->serialize;
        $self->send_line("tx " . length($data) . " " . $tx->hash_str);
        $self->send($data);
    }
    else {
        Warningf("I have no transaction with hash %u requested by peer %s", $hash, $self->ip);
    }
    return 0;
}

sub cmd_sendmempool {
    my $self = shift;
    if (@_) {
        Errf("Incorrect params from peer %s: [%s]", $self->ip, "sendmempool " . join(' ', @_));
        $self->send_line("abort incorrect_params");
        return -1;
    }
    foreach my $tx (QBitcoin::Transaction->mempool_list) {
        $self->send_line("mempool " . unpack("H*", $tx->hash) . " " . $tx->size . " " . $tx->fee);
    }
    $self->send_line("endofmempool") if mempool_synced();
    return 0;
}

sub cmd_endofmempool {
    my $self = shift;
    if (@_) {
        Errf("Incorrect params from peer %s: [%s]", $self->ip, "endofmempool " . join(' ', @_));
        $self->send_line("abort incorrect_params");
        return -1;
    }
    $self->send_line("ping syncmempool");
    return 0;
}

sub cmd_ping {
    my $self = shift;
    my @args = @_;
    if (@args != 1 || ref($args[0]) || !defined($args[0])) {
        Errf("Incorrect params from peer %s: [%s]", $self->ip, "ping " . join(' ', @args));
        $self->send_line("abort incorrect_params");
        return -1;
    }
    $self->send_line("pong $args[0]");
    return 0;
}

sub cmd_pong {
    my $self = shift;
    my @args = @_;
    if (@args != 1 || ref($args[0]) || !defined($args[0])) {
        Errf("Incorrect params from peer %s: [%s]", $self->ip, "pong " . join(' ', @args));
        $self->send_line("abort incorrect_params");
        return -1;
    }
    mempool_synced(1) if $args[0] eq "syncmempool";
    return 0;
}

sub decrease_reputation {
    my $self = shift;
    ...;
    return 0;
}

sub cmd_abort {
    my $self = shift;
    Warningf("Peer %s aborted connection", $self->ip);
    return -1;
}

1;
