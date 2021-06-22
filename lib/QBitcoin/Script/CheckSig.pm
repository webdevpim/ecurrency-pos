package QBitcoin::Script::CheckSig;
use warnings;
use strict;

use Role::Tiny;
use QBitcoin::Crypto qw(check_sig);
use QBitcoin::Script::Const;

sub cmd_checksig($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack >= 2 or return 0;
    my $pubkey = pop @$stack;
    my $signature = pop @$stack;
    push @$stack, check_sig($state->tx->sign_data, $signature, $pubkey) ? TRUE : FALSE;
    return undef;
}

1;
