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
    push @$stack, check_tx_signature($pubkey, $signature, $state->tx, $state->input_num) ? TRUE : FALSE;
    return undef;
}

sub check_tx_signature {
    my ($pubkey, $signature, $tx, $input_num) = @_;
    return check_sig($tx->sign_data, $signature, $pubkey);
}

1;
