package QBitcoin::Peer;
use warnings;
use strict;

use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::Const;
use QBitcoin::Accessors qw(mk_accessors);
use QBitcoin::ORM qw(find update create :types);

use constant DEFAULT_INCREASE =>    1; # receive good new message (not empty block or transaction)
use constant DEFAULT_DECREASE =>  100; # one incorrect message is as 100 correct
use constant MIN_REPUTATION   => -400; # ban the peer if reputation less than this limit (after 4 bad message)

use constant TABLE => 'peer';
use constant PRIMARY_KEY => qw(ip port);
use constant FIELDS => {
    type            => NUMERIC,
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

mk_accessors(keys %{FIELDS()});

sub new {
    my $class = shift;
    my $attr = @_ == 1 ? $_[0] : { @_ };
    return bless $attr, $class;
}

sub get_or_create {
    my $class = shift;
    my $args = @_ == 1 ? $_[0] : { @_ };
    if (my ($peer) = $class->find(type => $args->{type}, ip => $args->{ip})) {
        return $peer;
    }
    return $class->create(
        type        => $args->{type},
        ip          => $args->{ip},
        create_time => time(),
        update_time => time(),
    );
}

sub add_reputation {
    my $self = shift;
    my $increment = shift // DEFAULT_INCREASE;

    my $reputation = $self->reputation_effective + $increment;
    $self->update(update_time => time(), reputation => $reputation);
}

sub decrease_reputation {
    my $self = shift;
    my $decrement = shift // DEFAULT_DECREASE;
    $self->add_reputation(-$decrement);
}

sub reputation_effective {
    my $self = shift;
    return $self->reputation * exp(($self->update_time - time()) / (3600*24*14)); # decrease in e time during 2 weeks
}

1;
