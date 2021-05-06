package QBitcoin::Network;
use warnings;
use strict;

use Time::HiRes;
use Socket;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::Protocol;

my %PEERS;

sub peers {
    return values %PEERS;
}

sub peer {
    my $class = shift;
    my ($ip) = @_;
    return $PEERS{$ip};
}

sub add_peer {
    my $class = shift;
    my ($peer) = @_;
    $PEERS{$peer->ip} = $peer;
}

sub del_peer {
    my $class = shift;
    my ($peer) = @_;
    delete $PEERS{$peer->ip};
}

sub listen_socket {
    my $class = shift;

    my $listen_port = $config->{port} // getservbyname(SERVICE_NAME, 'tcp') // PORT_P2P;
    my $my_addr = inet_aton($config->{bind_addr} // BIND_ADDR);
    my $bind_addr = sockaddr_in($listen_port, $my_addr);
    my $proto = getprotobyname('tcp');
    socket(my $listen_socket, PF_INET, SOCK_STREAM, $proto)
        or die "Error creating socket: $!\n";
    setsockopt($listen_socket, SOL_SOCKET, SO_REUSEADDR, 1)
        or die "setsockopt error: $!\n";
    bind($listen_socket, $bind_addr)
        or die "bind error: $!\n";
    listen($listen_socket, LISTEN_QUEUE)
        or die "Error listen: $!\n";
    Infof("Accepting connections on %s:%s", BIND_ADDR, $listen_port);
    return $listen_socket;
}

sub connect_to {
    my $peer = shift;
    my ($peer_host) = $peer->host;
    my ($addr, $port) = split(/:/, $peer_host);
    $port //= getservbyname(SERVICE_NAME, 'tcp') // PORT_P2P;
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
    $peer->socket = $socket;
    $peer->socket_fileno = fileno($socket);
    $peer->state = STATE_CONNECTING;
    connect($socket, $paddr);
    Debugf("Connecting to %s", $peer_host);
}

sub main_loop {
    my $class = shift;
    my @peer_hosts = @_;

    $QBitcoin::Protocol::synced = 1 if $config->{base};
    # Load last INCORE_LEVELS blocks from database
    foreach my $block (reverse QBitcoin::Block->find(-sortby => "height DESC", -limit => INCORE_LEVELS)) {
        $block->receive();
    }

    my $listen_socket = $class->listen_socket;
    foreach my $peer_host (@peer_hosts) {
        my $peer = QBitcoin::Protocol->new(
            state_time => time(),
            host       => $peer_host,
            direction  => DIR_OUT,
        );
        connect_to($peer);
        $class->add_peer($peer);
    }

    my ($rin, $win, $ein);
    my $sig_killed;
    $SIG{TERM} = $SIG{INT} = sub { $sig_killed = 1 };

    while () {
        my $timeout = SELECT_TIMEOUT;
        if ($config->{mining} && $QBitcoin::Protocol::synced) {
            my $now = Time::HiRes::time();
            my $blockchain_height = QBitcoin::Block->blockchain_height // -1;
            my $time_next_block = QBitcoin::Block->time_by_height($blockchain_height + 1);
            if ($now + $timeout > $time_next_block) {
                $timeout = $time_next_block > $now ? $time_next_block - $now : 0;
            }
            my $generated_height = QBitcoin::Block->generated_height;
            if (!$generated_height || $now >= QBitcoin::Block->time_by_height($generated_height + 1)) {
                QBitcoin::Block->generate($now >= $time_next_block ? $blockchain_height + 1 : $blockchain_height);
            }
        }
        $rin = $win = $ein = '';
        vec($rin, fileno($listen_socket), 1) = 1 if $listen_socket;
        foreach my $peer ($class->peers) {
            if (!$peer->socket) {
                if (time() - $peer->state_time >= PEER_RECONNECT_TIME) {
                    connect_to($peer);
                }
            }
            $peer->socket or next;
            vec($rin, $peer->socket_fileno, 1) = 1 if length($peer->sendbuf) < WRITE_BUFFER_SIZE && $peer->state ne STATE_CONNECTING;
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
        if ($listen_socket && vec($rin, fileno($listen_socket), 1) == 1) {
            my $peerinfo = accept(my $new_socket, $listen_socket);
            my ($remote_port, $peer_addr) = unpack_sockaddr_in($peerinfo);
            my $peer_ip = inet_ntoa($peer_addr);
            if (my $peer = $class->peer($peer_ip)) {
                Warningf("Already connected with peer %s, status %s", $peer_ip, $peer->state);
                close($new_socket);
            }
            else {
                Infof("Incoming connection from %s", $peer_ip);
                my $peer = QBitcoin::Protocol->new(
                    socket     => $new_socket,
                    state      => STATE_CONNECTED,
                    state_time => time(),
                    host       => $peer_ip,
                    ip         => $peer_ip,
                    direction  => DIR_IN,
                );
                $class->add_peer($peer);
                $peer->startup();
            }
        }
        foreach my $peer ($class->peers) {
            $peer->socket or next;
            if (vec($ein, $peer->socket_fileno, 1) == 1) {
                Warningf("Peer %s disconnected", $peer->ip);
                $peer->disconnect();
                next;
            }
            if (vec($rin, $peer->socket_fileno, 1) == 1) {
                my $n = sysread($peer->socket, my $data, READ_BUFFER_SIZE);
                if (!defined $n) {
                    if ($peer->state eq STATE_CONNECTING) {
                        Warningf("Peer connection error: %s", $!);
                    }
                    else {
                        Warningf("Read error from peer %s", $peer->ip);
                    }
                    $peer->disconnect();
                    next;
                }
                if ($n > 0) {
                    my $ret = $peer->receive($data);
                    if ($ret != 0) {
                        $peer->disconnect();
                        next;
                    }
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
                    Infof("Connected to %s", $peer->ip);
                    $peer->startup();
                    next;
                }
                my $n = syswrite($peer->socket, $peer->sendbuf, length($peer->sendbuf));
                if (!defined $n) {
                    Warningf("Write error to peer %s", $peer->ip);
                    $peer->disconnect();
                    next;
                }
                if ($n > 0) {
                    $peer->sendbuf = $n == length($peer->sendbuf) ? "" : substr($peer->sendbuf, $n);
                }
            }
        }
    }
    return 0;
}

1;
