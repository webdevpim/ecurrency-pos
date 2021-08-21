package QBitcoin::Protocol::Common;
use warnings;
use strict;

use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::Peers;
use QBitcoin::Crypto qw(checksum32);

use constant ATTR => qw(
    greeted
    ip
    host
    port
    addr
    my_ip
    my_addr
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
    command
    last_recv_time
    ping_sent
);

mk_accessors(ATTR);

sub new {
    my $class = shift;
    my $args = @_ == 1 ? $_[0] : { @_ };
    my $self = bless $args, $class;
    $self->sendbuf = "";
    $self->recvbuf = "";
    $self->socket_fileno = fileno($self->socket) if $self->socket;
    return $self;
}

sub type {
    my $self = shift;
    return $self->isa('QBitcoin::Protocol') ? 'QBitcoin' :
           $self->isa('Bitcoin::Protocol')  ? 'Bitcoin'  :
           die "Unknown peer type " . ref($self) . "\n";
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
    $self->ping_sent = undef;
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
        $self->command = $command;
        if ($magic ne $self->MAGIC) {
            Errf("Incorrect magic: 0x%08X, expected 0x%08X", $magic, $self->MAGIC);
            # $self->abort("protocol_error");
            return -1;
        }
        if ($length + 24 > READ_BUFFER_SIZE) {
            Errf("Too long data packet for command %s, %u bytes", $command, $length);
            $self->abort("too_long_packet");
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
            $self->abort("bad_crc32");
            return -1;
        }
        my $func = "cmd_" . $command;
        if ($self->can($func)) {
            $self->last_recv_time = time();
            Debugf("Received [%s] from peer %s", $command, $self->ip);
            if ($command ne "version" && !$self->greeted) {
                Errf("command [%s] before greeting from peer %s", $command, $self->ip);
                $self->abort("protocol_error");
                return -1;
            }
            $self->$func($data) == 0
                or return -1;
        }
        else {
            Errf("Unknown command [%s] from peer %s", $command, $self->ip);
            $self->abort("unknown_command");
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
    return $self->send(pack("a4a12Va4", $self->MAGIC, $cmd, length($data), checksum32($data)) . $data);
}

1;
