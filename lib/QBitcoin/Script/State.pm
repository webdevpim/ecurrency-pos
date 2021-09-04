package QBitcoin::Script::State;
use warnings;
use strict;

use QBitcoin::Script::Const;

sub new {
    my $class = shift;
    my ($script, $tx, $input_num) = @_;
    # script, stack, if-state, if-stack, tx, input_num
    return bless [$script, [], 1, [], $tx, $input_num], $class;
}

sub script  :lvalue { $_[0]->[0] }
sub stack     { $_[0]->[1] }
sub ifstate :lvalue { $_[0]->[2] }
sub ifstack   { $_[0]->[3] }
sub tx        { $_[0]->[4] }
sub input_num { $_->[5] }

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
