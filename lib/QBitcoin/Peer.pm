package QBitcoin::Peer;
use warnings;
use strict;

use Socket;
use QBitcoin::Const;
use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::ORM qw(update create :types);

use constant DEFAULT_INCREASE =>    1; # receive good new message (not empty block or transaction)
use constant DEFAULT_DECREASE =>  100; # one incorrect message is as 100 correct
use constant MIN_REPUTATION   => -400; # ban the peer if reputation less than this limit (after 4 bad message)

use constant TABLE => 'peer';
use constant PRIMARY_KEY => qw(type_id ip);
use constant FIELDS => {
    type_id         => NUMERIC,
    ip              => BINARY,
    port            => NUMERIC,
    create_time     => NUMERIC,
    update_time     => NUMERIC,
    software        => STRING,
    features        => NUMERIC,
    bytes_sent      => NUMERIC,
    bytes_recv      => NUMERIC,
    obj_sent        => NUMERIC,
    obj_recv        => NUMERIC,
    ping_min_ms     => NUMERIC,
    ping_avg_ms     => NUMERIC,
    reputation      => NUMERIC,
    failed_connects => NUMERIC,
    pinned          => NUMERIC,
};

mk_accessors(grep { $_ ne "reputation" } keys %{FIELDS()});

my @PEERS; # by type_id and ip

sub new {
    my $class = shift;
    my $attr = @_ == 1 ? $_[0] : { @_ };
    return bless $attr, $class;
}

sub type { PROTOCOL2NAME->{shift->type_id} }

sub load {
    my $class = shift;
    if (!@PEERS) {
        @PEERS[$_] = {} foreach (PROTOCOL_QBITCOIN, PROTOCOL_BITCOIN);
        foreach my $peer (QBitcoin::ORM::find($class)) {
            $PEERS[$peer->type_id]->{$peer->ip} = $peer;
        }
    }
}

sub get_or_create {
    my $class = shift;
    my $args = @_ == 1 ? $_[0] : { @_ };
    $args->{ip} //= IPV6_V4_PREFIX . $args->{ipv4} if $args->{ipv4};
    if ($args->{host} && !$args->{ip}) {
        my ($addr, $port) = split(/:/, $args->{host});
        my $iaddr = inet_aton($addr);
        if (!$iaddr) {
            Errf("Unknown host: %s", $addr);
            return 0;
        }
        $args->{ip} = IPV6_V4_PREFIX . $iaddr;
        $args->{port} = $port;
    }
    my $port = $args->{port} //
        getservbyname(lc PROTOCOL2NAME->{$args->{type_id}}, 'tcp') //
        ($args->{type_id} == PROTOCOL_QBITCOIN ? PORT : BTC_PORT);
    $class->load();
    if (my $peer = $PEERS[$args->{type_id}]->{$args->{ip}}) {
        $peer->update(port => $port) if $peer->port != $port;
        $peer->update(pinned => $args->{pinned}) if defined($args->{pinned}) && $args->{pinned} != $peer->pinned;
        return $peer;
    }
    return $PEERS[$args->{type_id}]->{$args->{ip}} = $class->create(
        type_id     => $args->{type_id},
        ip          => $args->{ip},
        port        => $port,
        create_time => time(),
        update_time => time(),
    );
}

sub get_all {
    my $class = shift;
    my ($type_id) = @_;
    $class->load();
    return values %{$PEERS[$type_id]};
}

sub id {
    my $self = shift;
    return $self->{id} //= $self->ipv4 ? inet_ntoa($self->ipv4) : unpack("H*", $self->ip); # TODO: ipv6
}

sub ipv4 {
    my $self = shift;
    return substr($self->ip, 0, length(IPV6_V4_PREFIX)) eq IPV6_V4_PREFIX ?
        substr($self->ip, length(IPV6_V4_PREFIX)) :
        return undef;
}

sub add_reputation {
    my $self = shift;
    my $increment = shift // DEFAULT_INCREASE;

    my $reputation = $self->reputation;
    Infof("Change reputation for peer %s: %u -> %u", $self->id, $reputation, $reputation + $increment);
    $reputation += $increment;
    $self->update(update_time => time(), reputation => $reputation);
}

sub decrease_reputation {
    my $self = shift;
    my $decrement = shift // DEFAULT_DECREASE;
    $self->add_reputation(-$decrement);
}

sub reputation {
    my $self = shift;
    if (@_) {
        $self->{reputation} = $_[0];
    }
    elsif ($self->{reputation}) {
        return $self->{reputation} * exp(($self->{update_time} - time()) / (3600*24*14)); # decrease in e times during 2 weeks
    }
    else {
        return 0;
    }
}

sub conn_state {
    my $self = shift;
    if (my $connection = QBitcoin::ConnectionList->get($self->type_id, $self->ip)) {
        return $connection->state;
    }
    else {
        return STATE_DISCONNECTED;
    }
}

sub is_connect_allowed {
    my $self = shift;
    return 0 if $self->conn_state != STATE_DISCONNECTED;
    if ($self->failed_connects) {
        my $period = $self->failed_connects >= 10 ? 10 * 2**10 : 10 * 2**$self->failed_connects;
        return 0 if time() - $self->update_time < $period;
    }
    return 1;
}

sub failed_connect {
    my $self = shift;
    $self->update(failed_connects => $self->failed_connects + 1);
    # failed connect does not decrease peer reputation, it may be good outgoing peer with limited incoming connections
}

sub recv_good_command {
    my $self = shift;
    my ($direction) = @_;

    $self->update(failed_connects => 0) if $direction == DIR_OUT && $self->failed_connects;
}

1;
