package QBitcoin::Network;
use warnings;
use strict;

use Time::HiRes;
use Socket;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::ProtocolState qw(mempool_synced blockchain_synced);
use QBitcoin::Protocol;
use QBitcoin::Generate;
use QBitcoin::Produce;
use QBitcoin::RPC;
use Bitcoin::Protocol;

sub bind_addr {
    my $class = shift;

    my ($address, $port) = split(/:/, $config->{bind_addr} // BIND_ADDR);
    $port //= $config->{port} // getservbyname(SERVICE_NAME, 'tcp') // PORT;
    return listen_socket($address, $port);
}

sub bind_rpc_addr {
    my $class = shift;

    my ($address, $port) = split(/:/, $config->{rpc_addr} // RPC_ADDR);
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
    my ($peer_host) = $peer->host;
    my ($addr, $port) = split(/:/, $peer_host);
    $port //= getservbyname(SERVICE_NAME, 'tcp') // $peer->PORT;
    my $iaddr = inet_aton($addr)
        or die "Unknown host: $addr\n";
    my $paddr = sockaddr_in($port, $iaddr);
    my $proto = getprotobyname('tcp');
    socket(my $socket, PF_INET, SOCK_STREAM, $proto)
        or die "Error creating socket: $!\n";
    my $flags = fcntl($socket, F_GETFL, 0)
        or die "socket get fcntl error: $!\n";
    fcntl($socket, F_SETFL, $flags | O_NONBLOCK)
        or die "socket set fcntl error: $!\n";
    setsockopt($socket, SOL_SOCKET, O_NONBLOCK, 1)
        or die "setsockopt error: $!\n";
    $peer->ip = inet_ntoa($iaddr);
    $peer->port = $port;
    $peer->addr = "\x00"x10 . "\xff\xff" . $iaddr;
    $peer->socket = $socket;
    $peer->socket_fileno = fileno($socket);
    $peer->state = STATE_CONNECTING;
    $peer->last_recv_time = time();
    connect($socket, $paddr);
    Debugf("Connecting to %s", $peer_host);
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
    foreach my $peer_host (@$peer_hosts) {
        my $peer = QBitcoin::Protocol->new(
            state_time => time(),
            host       => $peer_host,
            direction  => DIR_OUT,
        );
        connect_to($peer);
        QBitcoin::Peers->add_peer($peer);
    }
    foreach my $peer_host (@$btc_nodes) {
        my $peer = Bitcoin::Protocol->new(
            state_time => time(),
            host       => $peer_host,
            direction  => DIR_OUT,
        );
        connect_to($peer);
        QBitcoin::Peers->add_peer($peer);
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
        foreach my $peer (QBitcoin::Peers->peers) {
            if (!$peer->socket && $peer->state eq STATE_DISCONNECTED && $peer->direction eq DIR_OUT) {
                if (time() - $peer->state_time >= PEER_RECONNECT_TIME) {
                    connect_to($peer);
                }
            }
            $peer->socket or next;
            if ($peer->can('timeout')) {
                my $peer_timeout = $peer->timeout;
                if ($peer_timeout) {
                    $timeout = $peer_timeout if $timeout > $peer_timeout;
                }
                else {
                    Noticef("%s peer %s timeout", $peer->type, $peer->ip);
                    $peer->disconnect();
                    next;
                }
            }
            vec($rin, $peer->socket_fileno, 1) = 1 if length($peer->recvbuf) < READ_BUFFER_SIZE && $peer->state ne STATE_CONNECTING;
            vec($win, $peer->socket_fileno, 1) = 1 if $peer->sendbuf || $peer->state eq STATE_CONNECTING;
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
            if (my $peer = QBitcoin::Peers->peer($peer_ip, 'QBitcoin')) {
                Warningf("Already connected with peer %s, status %s", $peer_ip, $peer->state);
                close($new_socket);
            }
            else {
                Infof("Incoming connection from %s", $peer_ip);
                my ($my_port, $my_addr) = unpack_sockaddr_in(getsockname($new_socket));
                my $my_ip = inet_ntoa($my_addr);
                my $peer = QBitcoin::Protocol->new(
                    socket         => $new_socket,
                    state          => STATE_CONNECTED,
                    state_time     => $time,
                    host           => $peer_ip,
                    ip             => $peer_ip,
                    port           => $remote_port,
                    addr           => "\x00"x10 . "\xff\xff" . $peer_addr,
                    my_ip          => $my_ip,
                    my_port        => $my_port,
                    my_addr        => "\x00"x10 . "\xff\xff" . $my_addr,
                    direction      => DIR_IN,
                    last_recv_time => $time,
                );
                QBitcoin::Peers->add_peer($peer);
                $peer->startup();
            }
        }
        if ($listen_rpc && vec($rin, fileno($listen_rpc), 1) == 1) {
            my $peerinfo = accept(my $new_socket, $listen_rpc);
            my ($remote_port, $peer_addr) = unpack_sockaddr_in($peerinfo);
            my $peer_ip = inet_ntoa($peer_addr);
            Debugf("Incoming RPC connection from %s", $peer_ip);
            my ($my_port, $my_addr) = unpack_sockaddr_in(getsockname($new_socket));
            my $my_ip = inet_ntoa($my_addr);
            my $peer = QBitcoin::RPC->new(
                socket         => $new_socket,
                state          => STATE_CONNECTED,
                state_time     => $time,
                host           => $peer_ip,
                ip             => $peer_ip,
                port           => $remote_port,
                addr           => "\x00"x10 . "\xff\xff" . $peer_addr,
            );
            QBitcoin::Peers->add_peer($peer);
            $peer->startup();
        }

        foreach my $peer (QBitcoin::Peers->peers) {
            $peer->socket or next;
            if (vec($ein, $peer->socket_fileno, 1) == 1) {
                Warningf("Peer %s disconnected", $peer->ip) unless $peer->type eq "RPC";
                $peer->disconnect();
                next;
            }

            if (vec($rin, $peer->socket_fileno, 1) == 1) {
                my $n = sysread($peer->socket, my $data, READ_BUFFER_SIZE);
                if (!defined $n) {
                    if ($sig_killed) {
                        Notice("Killed by signal");
                        $peer->disconnect();
                        last;
                    }
                    elsif ($peer->state eq STATE_CONNECTING) {
                        Warningf("Peer connection error: %s", $!);
                    }
                    else {
                        Warningf("Read error from peer %s", $peer->ip);
                    }
                    $peer->disconnect();
                    next;
                }
                if ($n > 0) {
                    $peer->recvbuf .= $data;
                }
                elsif ($n == 0) {
                    Warningf("Peer %s closed connection", $peer->ip);
                    $peer->disconnect();
                    next;
                }
            }
            if (vec($win, $peer->socket_fileno, 1) == 1) {
                if ($peer->state eq STATE_CONNECTING) {
                    my $res = getsockopt($peer->socket, SOL_SOCKET, SO_ERROR);
                    my $err = unpack("I", $res);
                    if ($err != 0) {
                        local $! = $err;
                        Warningf("Connect to %s error: %s", $peer->ip, $!);
                        $peer->disconnect();
                        next;
                    }
                    $peer->state = STATE_CONNECTED;
                    $peer->state_time = time();
                    my ($my_port, $my_addr) = unpack_sockaddr_in(getsockname($peer->socket));
                    $peer->my_ip = inet_ntoa($my_addr);
                    $peer->my_port = $my_port;
                    $peer->my_addr = "\x00"x10 . "\xff\xff" . $my_addr,
                    Infof("Connected to %s", $peer->ip);
                    $peer->startup();
                    next;
                }
                my $n = syswrite($peer->socket, $peer->sendbuf, length($peer->sendbuf));
                if (!defined $n) {
                    if ($sig_killed) {
                        Notice("Interrupted by signal");
                        $peer->disconnect();
                        last;
                    }
                    Warningf("Write error to peer %s", $peer->ip);
                    $peer->disconnect();
                    next;
                }
                elsif ($n > 0) {
                    $peer->sendbuf = $n == length($peer->sendbuf) ? "" : substr($peer->sendbuf, $n);
                    if (!$peer->sendbuf && $peer->type eq "RPC") {
                        $peer->disconnect();
                        next;
                    }
                }
            }
            if ($peer->recvbuf) {
                my $ret = $peer->receive();
                if ($ret != 0) {
                    $peer->disconnect();
                    next;
                }
            }

            if ($peer->can('ping_sent') && $peer->last_recv_time + PEER_RECV_TIMEOUT < $time) {
                if (!$peer->ping_sent) {
                    $peer->send_message("ping", pack("Q", $time));
                    $peer->ping_sent = $time;
                }
                elsif ($peer->ping_sent + PEER_RECV_TIMEOUT < $time) {
                    Noticef("Peer %s timeout, closing connection", $peer->ip);
                    $peer->disconnect();
                    next;
                }
            }
        }
    }
    return 0;
}

1;
