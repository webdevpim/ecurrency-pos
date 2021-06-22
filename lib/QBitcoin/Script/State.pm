package QBitcoin::Script::State;
use warnings;
use strict;

use QBitcoin::Script::Const;

sub new {
    my $class = shift;
    my ($script, $tx_data) = @_;
    # script, stack, if-state, if-stack, tx-data
    return bless [$script, [], 1, [], $tx_data], $class;
}

sub script :lvalue { $_[0]->[0] }
sub stack   { $_[0]->[1] }
sub ifstate :lvalue { $_[0]->[2] }
sub ifstack { $_[0]->[3] }
sub tx_data { $_[0]->[4] }

sub set_ifstate {
    my ($self) = @_;
    $self->ifstate = !grep { !$_ } @{$self->ifstack};
}

sub ok {
    my $self = shift;
    my $stack = $self->stack;
    return (@$stack == 1 && $stack->[0] eq TRUE && !@{$self->ifstack});
}

1;
