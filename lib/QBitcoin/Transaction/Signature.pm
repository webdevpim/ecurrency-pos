package QBitcoin::Transaction::Signature;
use warnings;
use strict;

use QBitcoin::MyAddress;
use QBitcoin::Log;
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Crypto qw(signature);
use QBitcoin::RedeemScript;
use Role::Tiny;

# useful links:
# https://bitcoin.stackexchange.com/questions/3374/how-to-redeem-a-basic-tx
# https://en.bitcoin.it/w/images/en/7/70/Bitcoin_OpCheckSig_InDetail.png
# https://developer.bitcoin.org/devguide/transactions.html
# https://gist.github.com/Sjors/5574485 (ruby)

sub sign_transaction {
    my $self = shift;
    foreach my $num (0 .. $#{$self->in}) {
        my $in = $self->in->[$num];
        if (my $address = QBitcoin::MyAddress->get_by_hash($in->{txo}->scripthash)) {
            $self->make_sign($in, $address, $num);
        }
        else {
            Errf("Can't sign transaction: address for %s:%u is not my, scripthash %s",
                $in->{txo}->tx_in_str, $in->{txo}->num, unpack("H*", $in->{txo}->scripthash));
        }
    }
    $self->calculate_hash;
}

sub make_sign {
    my $self = shift;
    my ($in, $address, $input_num) = @_;

    my $redeem_script = QBitcoin::MyAddress->script_by_hash($in->{txo}->scripthash)
        or die "Can't get redeem script by hash " . unpack("H*", $in->{txo}->scripthash);
    my $signature = signature($self->sign_data($input_num), $address->privkey);
    $in->{txo}->redeem_script = $redeem_script;
    my $script_type = QBitcoin::RedeemScript->script_type($redeem_script);
    if ($script_type eq "P2PKH") {
        $in->{siglist} = [ $signature, $address->pubkey ];
    }
    elsif ($script_type eq "P2PK") {
        $in->{siglist} = [ $signature ];
    }
}

1;
