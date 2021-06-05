package QBitcoin::Transaction::Signature;
use warnings;
use strict;

use JSON::XS;
use QBitcoin::MyAddress;
use QBitcoin::Log;
use QBitcoin::Script qw(pushdata);
use QBitcoin::Crypto qw(signature);
use Role::Tiny;

# useful links:
# https://bitcoin.stackexchange.com/questions/3374/how-to-redeem-a-basic-tx
# https://en.bitcoin.it/w/images/en/7/70/Bitcoin_OpCheckSig_InDetail.png
# https://developer.bitcoin.org/devguide/transactions.html
# https://gist.github.com/Sjors/5574485 (ruby)

my $JSON = JSON::XS->new->utf8(1)->convert_blessed(1)->canonical(1);

sub sign_data {
    my $self = shift;
    return $self->{sign_data} if defined $self->{sign_data};
    # All transaction inputs and outputs without close scripts
    # TODO: set binary data as for bitcoin
    my $data = {
        inputs  => [ map { unpack("H*", $_->{txo}->tx_in) . ":" . $_->{txo}->num } @{$self->in} ],
        outputs => [ map { value => $_->value+0, script => unpack("H*", $_->open_script) }, @{$self->out} ],
    };
    Debugf("sign data: %s", $JSON->encode($data));
    return $JSON->encode($data);
}

sub sign_transaction {
    my $self = shift;
    foreach my $in (@{$self->in}) {
        if (my $address = QBitcoin::MyAddress->get_by_script($in->{txo}->open_script)) {
            $in->{close_script} = $self->make_close_script($address);
        }
        else {
            Errf("Can't sign transaction: address for %s:%u is not my, script %s",
                $in->{txo}->tx_in_str, $in->{txo}->num, unpack("H*", $in->{txo}->open_script));
        }
    }
}

sub make_close_script {
    my $self = shift;
    my ($address) = @_;
    return pushdata(signature($self->sign_data, $address->privkey)) . pushdata($address->pubkey);
}

1;
