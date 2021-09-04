package QBitcoin::Transaction::Signature;
use warnings;
use strict;

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

sub sign_data {
    my $self = shift;
    my ($input_num) = @_; # currently not used
    return $self->{sign_data} if defined $self->{sign_data};
    # Serialized transaction without input scripts
    local $self->{in} = [ map +{ %$_, close_script => "" }, @{$self->in} ];
    my $data = $self->serialize;
    if ($self->fee < 0) {
        # It's stake tx which signs block, add block info
        $data .= $self->block_sign_data;
    }
    return $self->{sign_data} = $data;
}

sub sign_transaction {
    my $self = shift;
    foreach my $num (0 .. $#{$self->in}) {
        my $in = $self->in->[$num];
        if (my $address = QBitcoin::MyAddress->get_by_script($in->{txo}->open_script)) {
            $in->{close_script} = $self->make_close_script($address, $num);
        }
        else {
            Errf("Can't sign transaction: address for %s:%u is not my, script %s",
                $in->{txo}->tx_in_str, $in->{txo}->num, unpack("H*", $in->{txo}->open_script));
        }
    }
    $self->hash //= QBitcoin::Transaction::calculate_hash($self->serialize);
}

sub make_close_script {
    my $self = shift;
    my ($address, $input_num) = @_;
    my $script = pushdata(signature($self->sign_data($input_num), $address->privkey)) . pushdata($address->pubkey);
    return $script;
}

1;
