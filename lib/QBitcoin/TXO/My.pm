package QBitcoin::TXO::My;
use warnings;
use strict;

use Role::Tiny;

use QBitcoin::Log;
use QBitcoin::OpenScript;
use QBitcoin::MyAddress qw(my_address);

my %MY_UTXO;

sub _in_key {
    my $self = shift;
    return $self->tx_in . $self->num;
}

sub add_my_utxo {
    my $self = shift;
    $MY_UTXO{$self->_in_key} = $self;
    Infof("Add my UTXO %s:%s %s coins", unpack("H*", substr($self->tx_in, 0, 4)), $self->num, $self->value);
}

sub del_my_utxo {
    my $self = shift;
    delete $MY_UTXO{$self->_in_key} &&
        Infof("Delete my UTXO %s:%s %s coins", unpack("H*", substr($self->tx_in, 0, 4)), $self->num, $self->value);
}

sub my_utxo {
    return values %MY_UTXO;
}

sub is_my {
    my $self = shift;
    foreach my $my_address (my_address()) {
        foreach my $script (QBitcoin::OpenScript->script_for_address($my_address)) {
            return 1 if $self->open_script eq $script;
        }
    }
    return 0;
}

1;
