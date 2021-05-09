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

# >> mempool <txid> <fee>
# << sendtx <txid>
# >> tx <size>
# >> ...

# << sendmempool
# >> tx <size>
# >> ...
# >> tx <size>
# >> ...
# >> endmempool

# Send "sendmempool" to the first connected node after start, then (after get it) switch to "synced" mode

# If our last known block height less than height_by_time, then batch request all blocks with height from last known to max available

use Tie::IxHash;
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::ProtocolState qw(mempool_synced);
use QBitcoin::Block;
use QBitcoin::Peers;

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
);

mk_accessors(ATTR);

my %pending_blocks;
tie(%pending_blocks, 'Tie::IxHash'); # Ordered by age
my %pending_tx;

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
        $self->state_time = time();
        $self->greeted = undef;
    }
    $self->state = STATE_DISCONNECTED;
    $self->sendbuf = "";
    $self->recvbuf = "";
    QBitcoin::Peers->del_peer($self) if $self->direction eq DIR_IN;
    return 0;
}

sub receive {
    my $self = shift;
    my ($data) = @_;

    $self->recvbuf .= $data;
    while (1) {
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
    $self->send_line("sendmempool") if !mempool_synced() && $self->direction eq DIR_OUT;
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
    return 0 if $pending_blocks{$block->hash};
    $block->received_from = $self;
    foreach my $tx_hash (@{$block->tx_hashes}) {
        my $transaction = QBitcoin::Transaction->get_by_hash($tx_hash);
        if ($transaction) {
            $block->add_tx($transaction);
        }
        else {
            $block->pending_tx($tx_hash);
            $self->send_line("sendtx " . unpack("H*", $tx_hash));
        }
    }
    if ($block->pending_tx) {
        $pending_blocks{$block->hash} = $block;
        if (keys %pending_blocks > MAX_PENDING_BLOCKS) {
            my ($oldest_block) = values %pending_blocks;
            foreach my $tx_hash (@{$oldest_block->pending_tx}) {
                delete $pending_tx{$tx_hash}->{$oldest_block->hash};
                if (!%{$pending_tx{$tx_hash}}) {
                    delete $pending_tx{$tx_hash};
                }
            }
            delete $pending_blocks{$oldest_block->hash};
        }

        return 0;
    }
    else {
        $block->compact_tx();
        return $block->receive();
    }
}

sub cmd_tx {
    my $self = shift;
    my @args = @_;
    if (@args != 1 || ref($args[0]) || !defined($args[0]) || $args[0] !~ INT_POSITIVE_RE) {
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
    my $tx = QBitcoin::Transaction->deserialize($tx_data);
    if (!$tx) {
        $self->send_line("abort bad_tx_data");
        return -1;
    }
    $tx->receive() == 0
        or return -1;
    if (my $blocks = delete $pending_tx{$tx->hash}) {
        foreach my $block (values %$blocks) {
            $block->add_tx($tx);
            if (!$block->pending_tx) {
                delete $pending_blocks{$block->hash};
                $block->compact_tx();
                $block->receive();
            }
        }
    }
    return 0;
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
    if (time() < QBitcoin::Block->time_by_height($height)) {
        Warningf("Ignore too early block height %u from peer %s", $height, $self->ip);
        return 0;
    }
    QBitcoin::Block->declared_height($height);
    if ($height > (QBitcoin::Block->blockchain_height // -1)) {
        $self->send_line("sendblock " . ((QBitcoin::Block->blockchain_height // -1) + 1));
    }
    elsif ($weight > QBitcoin::Block->best_weight) {
        $self->send_line("sendblock $height");
    }
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
    if (!$block) {
        Warningf("I have no block with height %u requested by peer %s", $height, $self->ip);
    }
    else {
        my $data = $block->serialize;
        $self->send_line("block " . length($data) . " " . $block->height);
        $self->send($data);
    }
    return 0;
}

sub cmd_mempool {
    my $self = shift;
    ...;
    return 0;
}

sub cmd_sendtx {
    my $self = shift;
    ...;
    return 0;
}

sub cmd_sendmempool {
    my $self = shift;
    # TODO
    $self->send_line("endmempool") if mempool_synced();
    return 0;
}

sub cmd_endmempool {
    my $self = shift;
    if (@_) {
        Errf("Incorrect params from peer %s: [%s]", $self->ip, "endmempool " . join(' ', @_));
        $self->send_line("abort incorrect_params");
        return -1;
    }
    mempool_synced(1);
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
