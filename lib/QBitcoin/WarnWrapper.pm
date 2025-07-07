package QBitcoin::WarnWrapper;
use warnings;
use strict;

use QBitcoin::Log;

$SIG{__WARN__} = \&sigwarn; ## no critic

sub sigwarn {
    local $SIG{__WARN__} = 'DEFAULT';

    # Always one arg
    my $arg = shift;
    my $mes = ref $arg ? "Unexpected warning" : $arg;
    Err($mes);
    warn $arg if ref $arg;
}

1;
