package QBitcoin::Network;
use warnings;
use strict;

use Time::HiRes;
use Socket;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::Peer;
use QBitcoin::Connection;
use QBitcoin::ConnectionList;
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced);
use QBitcoin::Generate;
use QBitcoin::Produce;
use QBitcoin::RPC;

sub bind_addr {
    my $class = shift;

    my ($address, $port) = split(/:/, $config->{bind} // BIND_ADDR);
    $port //= $config->{port} // getservbyname(SERVICE_NAME, 'tcp') // PORT;
    return listen_socket($address, $port);
}

sub bind_rpc_addr {
    my $class = shift;

    my ($address, $port) = split(/:/, $config->{rpc} // RPC_ADDR);
    $port //= $config->{rpc_port} // getservbyname(SERVICE_NAME, 'tcp') // RPC_PORT;
    return listen_socket($address, $port);
}

sub listen_socket {
    my ($address, $port) = @_;
    my $bind_addr = sockaddr_in($port, inet_aton($address eq '*' ? "0.0.0.0" : $address));
    my $proto = getprotobyname('tcp');
    socket(my $socket, PF_INET, SOCK_STREAM, $proto)
        or die "Error creating socket: $!\n";
    setsockopt($socket, SOL_SOCKET, SO_REUSEADDR, 1)
        or die "setsockopt error: $!\n";
    bind($socket, $bind_addr)
        or die "bind $address:$port error: $!\n";
    listen($socket, LISTEN_QUEUE)
        or die "Error listen: $!\n";
    Infof("Accepting connections on %s:%s", $address, $port);
    return $socket;
}

sub connect_to {
    my $peer = shift;
    my $iaddr = $peer->ipv4
        or die "No ipv4 address for peer " . $peer->id . "\n";
    my $paddr = sockaddr_in($peer->port, $iaddr);
    my $proto = getprotobyname('tcp');
    socket(my $socket, PF_INET, SOCK_STREAM, $proto)
        or die "Error creating socket: $!\n";
    my $flags = fcntl($socket, F_GETFL, 0)
        or die "socket get fcntl error: $!\n";
    fcntl($socket, F_SETFL, $flags | O_NONBLOCK)
        or die "socket set fcntl error: $!\n";
    setsockopt($socket, SOL_SOCKET, O_NONBLOCK, 1)
        or die "setsockopt error: $!\n";
    my $connection = QBitcoin::Connection->new(
        peer      => $peer,
        socket    => $socket,
        state     => STATE_CONNECTING,
        direction => DIR_OUT,
    );
    connect($socket, $paddr);
    QBitcoin::ConnectionList->add($connection);
    Debugf("Connecting to %s peer %s:%u", $peer->type, $peer->id, $peer->port);
    $peer->update(update_time => time());
    return $connection;
}

sub main_loop {
    my $class = shift;
    my ($peer_hosts, $btc_nodes) = @_;

    local $SIG{PIPE} = 'IGNORE'; # prevent exceptions on write to socket which was closed by remote

    if ($config->{genesis}) {
        mempool_synced(1);
        blockchain_synced(1);
    }
    # Load last INCORE_LEVELS blocks from database
    while (1) {
        my $incorrect = 0;
        foreach my $block (reverse QBitcoin::Block->find(-sortby => "height DESC", -limit => 1)) {
            if ($incorrect) {
                Errf("Delete incorrect block descendant %s height %u", $block->hash_str, $block->height);
                $block->delete();
                next;
            }
            QBitcoin::Block->max_db_height($block->height);
            if ($block->receive(1) != 0) {
                Errf("Incorrect stored block %s height %u, delete", $block->hash_str, $block->height);
                $incorrect = 1;
                $block->delete();
                QBitcoin::Block->max_db_height($block->height - 1);
                next;
            }
            Debugf("Loaded block height %u", $block->height);
        }
        last if QBitcoin::Block->max_db_height >= 0 || !$incorrect;
    }
    # Load my UTXO
    if ($config->{generate}) {
        QBitcoin::Generate->load_utxo();
    }

    my $listen_socket = $class->bind_addr;
    my $listen_rpc    = $class->bind_rpc_addr;
    foreach my $peer_host ($config->get_all('peer')) {
        my $peer = QBitcoin::Peer->get_or_create(
            host    => $peer_host,
            type_id => PROTOCOL_QBITCOIN,
            pinned  => 1,
        );
    }
    foreach my $peer_host ($config->get_all('btcnode')) {
        my $peer = QBitcoin::Peer->get_or_create(
            host    => $peer_host,
            type_id => PROTOCOL_BITCOIN,
            pinned  => 1,
        );
    }

    my ($rin, $win, $ein);
    my $sig_killed;
    $SIG{TERM} = $SIG{INT} = sub { $sig_killed = 1 };

    while () {
        QBitcoin::Produce->produce() if $config->{produce} && mempool_synced() && blockchain_synced();
        my $timeout = SELECT_TIMEOUT;
        if ($config->{generate} && mempool_synced() && blockchain_synced()) {
            my $now = Time::HiRes::time();
            my $blockchain_height = QBitcoin::Block->blockchain_height // -1;
            my $time_next_block = time_by_height($blockchain_height + 1);
            if ($now + $timeout > $time_next_block) {
                $timeout = $time_next_block > $now ? $time_next_block - $now : 0;
            }
            my $generated_height = QBitcoin::Generate->generated_height;
            if (!$generated_height || $now >= time_by_height($generated_height + 1)) {
                QBitcoin::Generate->generate($now >= $time_next_block ? $blockchain_height + 1 : $blockchain_height);
            }
        }
        $rin = $win = $ein = '';
        vec($rin, fileno($listen_socket), 1) = 1 if $listen_socket;
        vec($rin, fileno($listen_rpc),    1) = 1 if $listen_rpc;

        call_qbt_peers();
        call_btc_peers();

        my @connections = QBitcoin::ConnectionList->list;
        foreach my $connection (@connections) {
            if ($connection->protocol->can('timeout')) {
                my $peer_timeout = $connection->protocol->timeout;
                if ($peer_timeout) {
                    $timeout = $peer_timeout if $timeout > $peer_timeout;
                }
                else {
                    Noticef("%s peer %s timeout", $connection->type, $connection->ip);
                    $connection->disconnect();
                    QBitcoin::ConnectionList->del($connection);
                    next;
                }
            }
            vec($rin, $connection->socket_fileno, 1) = 1 if length($connection->recvbuf) < READ_BUFFER_SIZE && $connection->state ne STATE_CONNECTING;
            vec($win, $connection->socket_fileno, 1) = 1 if $connection->sendbuf || $connection->state eq STATE_CONNECTING;
        }

        $ein = $rin | $win;
        my $nfound = select($rin, $win, $ein, $timeout);
        last if $sig_killed;
        next unless $nfound;
        if ($nfound == -1) {
            Errf("select error: %s", $!);
            last;
        }
        my $time = time();

        if ($listen_socket && vec($rin, fileno($listen_socket), 1) == 1) {
            my $peerinfo = accept(my $new_socket, $listen_socket);
            my ($remote_port, $peer_addr) = unpack_sockaddr_in($peerinfo);
            my $peer_ip = inet_ntoa($peer_addr);
            if (my $connection = QBitcoin::ConnectionList->get(PROTOCOL_QBITCOIN, IPV6_V4_PREFIX . $peer_addr)) {
                Warningf("Already connected with peer %s, status %s", $peer_ip, $connection->state);
                close($new_socket);
            }
            else {
                Infof("Incoming connection from %s", $peer_ip);
                # TODO: close listen socket if too many incoming connections; open again after disconnect some of them
                my $peer = QBitcoin::Peer->get_or_create(
                    ipv4    => $peer_addr,
                    host    => $peer_ip,
                    type_id => PROTOCOL_QBITCOIN,
                );
                # TODO: drop connection from peers with too low reputation (banned)
                my ($my_port, $my_addr) = unpack_sockaddr_in(getsockname($new_socket));
                my $my_ip = inet_ntoa($my_addr);
                my $connection = QBitcoin::Connection->new(
                    peer       => $peer,
                    socket     => $new_socket,
                    state_time => $time,
                    state      => STATE_CONNECTED,
                    port       => $remote_port,
                    my_ip      => $my_ip,
                    my_port    => $my_port,
                    my_addr    => IPV6_V4_PREFIX . $my_addr,
                    direction  => DIR_IN,
                );
                QBitcoin::ConnectionList->add($connection);
                $connection->protocol->startup();
                push @connections, $connection;
            }
        }
        if ($listen_rpc && vec($rin, fileno($listen_rpc), 1) == 1) {
            my $peerinfo = accept(my $new_socket, $listen_rpc);
            my ($remote_port, $peer_addr) = unpack_sockaddr_in($peerinfo);
            my $peer_ip = inet_ntoa($peer_addr);
            Debugf("Incoming RPC connection from %s", $peer_ip);
            my ($my_port, $my_addr) = unpack_sockaddr_in(getsockname($new_socket));
            my $my_ip = inet_ntoa($my_addr);
            my $connection = QBitcoin::Connection->new(
                type_id    => PROTOCOL_RPC,
                socket     => $new_socket,
                state      => STATE_CONNECTED,
                state_time => $time,
                host       => $peer_ip,
                ip         => $peer_ip,
                addr       => $peer_addr,
                port       => $remote_port,
                direction  => DIR_IN,
            );
            QBitcoin::ConnectionList->add($connection);
            $connection->protocol->startup();
            push @connections, $connection;
        }

        foreach my $connection (@connections) {
            my $was_traffic;
            if (vec($ein, $connection->socket_fileno, 1) == 1) {
                Warningf("%s peer %s disconnected", $connection->type, $connection->ip) unless $connection->type_id == PROTOCOL_RPC;
                $connection->disconnect();
                QBitcoin::ConnectionList->del($connection);
                next;
            }

            if (vec($rin, $connection->socket_fileno, 1) == 1) {
                my $n = sysread($connection->socket, my $data, READ_BUFFER_SIZE);
                if (!defined $n) {
                    if ($sig_killed) {
                        Notice("Killed by signal");
                        $connection->disconnect();
                        QBitcoin::ConnectionList->del($connection);
                        last;
                    }
                    elsif ($connection->state eq STATE_CONNECTING) {
                        Warningf("%s peer %s connection error: %s", $connection->type, $connection->ip, $!);
                        $connection->peer->failed_connect();
                    }
                    else {
                        Warningf("Read error from %s peer %s", $connection->type, $connection->ip);
                    }
                    $connection->disconnect();
                    QBitcoin::ConnectionList->del($connection);
                    next;
                }
                if ($n > 0) {
                    $connection->recvbuf .= $data;
                    $was_traffic = 1;
                }
                elsif ($n == 0) {
                    Warningf("%s peer %s closed connection", $connection->type, $connection->ip);
                    $connection->disconnect();
                    QBitcoin::ConnectionList->del($connection);
                    next;
                }
            }
            if (vec($win, $connection->socket_fileno, 1) == 1) {
                if ($connection->state eq STATE_CONNECTING) {
                    my $res = getsockopt($connection->socket, SOL_SOCKET, SO_ERROR);
                    my $err = unpack("I", $res);
                    if ($err != 0) {
                        local $! = $err;
                        Warningf("Connect to %s peer %s error: %s", $connection->type, $connection->ip, $!);
                        $connection->disconnect();
                        QBitcoin::ConnectionList->del($connection);
                        next;
                    }
                    $connection->state = STATE_CONNECTED;
                    $connection->state_time = time();
                    my ($my_port, $my_addr) = unpack_sockaddr_in(getsockname($connection->socket));
                    $connection->my_ip = inet_ntoa($my_addr);
                    $connection->my_port = $my_port;
                    $connection->my_addr = IPV6_V4_PREFIX . $my_addr,
                    Infof("Connected to %s peer %s", $connection->type, $connection->ip);
                    $connection->protocol->startup();
                    next;
                }
                my $n = syswrite($connection->socket, $connection->sendbuf, length($connection->sendbuf));
                if (!defined $n) {
                    if ($sig_killed) {
                        Notice("Interrupted by signal");
                        $connection->disconnect();
                        QBitcoin::ConnectionList->del($connection);
                        last;
                    }
                    Warningf("Write error to %s peer %s", $connection->type, $connection->ip);
                    $connection->disconnect();
                    QBitcoin::ConnectionList->del($connection);
                    next;
                }
                elsif ($n > 0) {
                    $connection->sendbuf = $n == length($connection->sendbuf) ? "" : substr($connection->sendbuf, $n);
                    $was_traffic = 1;
                    if (!$connection->sendbuf && $connection->type_id == PROTOCOL_RPC) {
                        $connection->disconnect();
                        QBitcoin::ConnectionList->del($connection);
                        next;
                    }
                }
            }
            # recvbuf may be not empty after skip some commands due to full sendbuf
            # in this case we will process recvbuf after sending some data from sendbuf without receiving anything new
            if ($was_traffic && $connection->recvbuf) {
                my $ret = $connection->protocol->receive();
                if ($ret != 0) {
                    if ($connection->peer && !$connection->greeted && $connection->direction == DIR_OUT) {
                        $connection->peer->failed_connect;
                    }
                    $connection->disconnect();
                    QBitcoin::ConnectionList->del($connection);
                    next;
                }
            }

            if ($connection->protocol->can('ping_sent') && $connection->protocol->last_recv_time + PEER_RECV_TIMEOUT < $time) {
                if (!$connection->protocol->ping_sent) {
                    $connection->protocol->send_message("ping", pack("Q", $time));
                    $connection->protocol->ping_sent = $time;
                }
                elsif ($connection->protocol->ping_sent + PEER_RECV_TIMEOUT < $time) {
                    Noticef("%s peer %s timeout, closing connection", $connection->type, $connection->ip);
                    $connection->disconnect();
                    QBitcoin::ConnectionList->del($connection);
                    next;
                }
            }
        }
    }
    return 0;
}

sub call_btc_peers {
    my @peers = grep { $_->is_connect_allowed } QBitcoin::Peer->find(type_id => PROTOCOL_BITCOIN)
        or return;
    foreach my $peer (@peers) {
        connect_to($peer);
    }
}

sub call_qbt_peers {
    my @peers = grep { $_->is_connect_allowed } QBitcoin::Peer->find(type_id => PROTOCOL_QBITCOIN)
        or return;
    my $found_pinned;
    foreach my $peer (grep { $_->pinned } @peers) {
        connect_to($peer);
        $found_pinned++;
    }
    @peers = grep { !$_->pinned } @peers if $found_pinned;
    my $connect_in = 0;
    my $connect_out = 0;
    foreach my $connection (grep { $_->type_id == PROTOCOL_QBITCOIN } QBitcoin::ConnectionList->list()) {
        $connection->direction == DIR_IN ? $connect_in++ : $connect_out++;
    }
    if ($connect_in + $connect_out < MIN_CONNECTIONS || $connect_out < MIN_OUT_CONNECTIONS) {
        my @peers = sort { $b->reputation <=> $a->reputation } @peers;
        while (@peers && ($connect_in + $connect_out < MIN_CONNECTIONS || $connect_out < MIN_OUT_CONNECTIONS)) {
            if (connect_to(shift @peers)) {
                $connect_out++;
            }
        }
    }
}

1;
