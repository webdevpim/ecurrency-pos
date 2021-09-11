package QBitcoin::Connection;
use warnings;
use strict;

use Socket;
use QBitcoin::Const;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::Protocol;
use QBitcoin::RPC;
use Bitcoin::Protocol;

mk_accessors(qw(peer ip socket state_time state port my_ip my_port my_addr direction));
mk_accessors(qw(protocol type sendbuf recvbuf socket_fileno));

use constant MODULE_BY_TYPE => {
    &PROTOCOL_QBITCOIN => "QBitcoin::Protocol",
    &PROTOCOL_BITCOIN  => "Bitcoin::Protocol",
    &PROTOCOL_RPC      => "QBitcoin::RPC",
};

sub new {
    my $class = shift;
    my $attr = @_ == 1 ? $_[0] : { @_ };
    my $self = bless $attr, $class;
    $attr->{type} //= $attr->{peer}->type if $attr->{peer};
    $attr->{ip}   //= $attr->{peer}->ip   if $attr->{peer};
    my $protocol_module = MODULE_BY_TYPE->{$attr->{type}}
        or die "Unknown connection type [$attr->{type}]";
    $self->protocol = $protocol_module->new(connection => $self);
    $self->sendbuf = "";
    $self->recvbuf = "";
    $self->socket_fileno = fileno($self->socket) if $self->socket;
    return $self;
}

sub host { shift->peer->host }
sub addr { shift->peer->addr }

sub disconnect {
    my $self = shift;
    if ($self->socket) {
        shutdown($self->socket, 2);
        close($self->socket);
        $self->socket = undef;
        $self->socket_fileno = undef;
    }
    if ($self->state == STATE_CONNECTED) {
        if ($self->peer) {
            Infof("Disconnected from %s peer %s", $self->type, $self->ip);
            # TODO: update peer data
        }
        elsif ($self->type == PROTOCOL_RPC) {
            Debugf("Disconnected from RPC API client %s", $self->ip);
        }
    }
    $self->state = STATE_DISCONNECTED;
    $self->sendbuf = "";
    $self->recvbuf = "";
    $self->protocol = undef;
    return 0;
}

sub send {
    my $self = shift;
    my ($data) = @_;

    if ($self->state == STATE_CONNECTED) {
        Errf("Attempt to send to %s peer %s with state %s", $self->type, $self->ip // "unknown", $self->state);
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

1;
