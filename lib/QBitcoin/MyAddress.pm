package QBitcoin::MyAddress;
use warnings;
use strict;
use feature 'state';

use QBitcoin::Config;
use QBitcoin::Log;
use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::ORM qw(find :types);
use QBitcoin::Crypto qw(hash160 hash256 pubkey_by_privkey pk_import);
use QBitcoin::Address qw(wif_to_pk address_by_pubkey script_by_pubkey script_by_pubkeyhash);

use Exporter qw(import);
our @EXPORT_OK = qw(my_address);

use constant TABLE => 'my_address';

use constant FIELDS => {
    address     => STRING,
    private_key => STRING,
};

mk_accessors(qw(private_key));

sub my_address {
    my $class = shift // __PACKAGE__;
    state $address = [ $class->find() ];
    return wantarray ? @$address : $address->[0];
}

sub privkey {
    my $self = shift;
    return $self->{privkey} //= pk_import(wif_to_pk($self->private_key));
}

sub pubkey {
    my $self = shift;
    return $self->{pubkey} if $self->{pubkey};
    $self->privkey or return undef;
    return $self->{pubkey} = pubkey_by_privkey($self->privkey);
}

sub pubkeyhash {
    my $self = shift;
    return hash160($self->pubkey);
}

sub address {
    my $self = shift;
    # return $self->{address} ||= address_by_pubkey($self->pubkey // return undef);
    if (!$self->{addr}) {
        $self->{addr} = address_by_pubkey($self->pubkey // return undef);
        if ($self->{address} && $self->{address} ne $self->{addr}) {
            Errf("Mismatch my private key and address: %s != %s", $self->{addr}, $self->{address});
        }
    }
    return $self->{addr};
}

sub redeem_script {
    my $self = shift;
    my $main_script = script_by_pubkey($self->pubkey);
    return wantarray ? (
        $main_script,
        script_by_pubkeyhash($self->pubkeyhash),
    ) : $main_script;
}

sub scripthash {
    my $self = shift;
    return wantarray ? ( map { hash160($_), hash256($_) } $self->redeem_script ) : hash160(scalar $self->redeem_script);
}

sub get_by_hash {
    my $class = shift;
    my ($hash) = @_;
    state $my_hashes;
    if (!$my_hashes) {
        $my_hashes = {};
        foreach my $address (my_address()) {
            foreach my $scripthash ($address->scripthash) {
                $my_hashes->{$scripthash} = $address;
            }
        }
    }
    return $my_hashes->{$hash};
}

sub script_by_hash {
    my $self = shift;
    my ($scripthash) = @_;
    if (!$self->{script}) {
        $self->{script} = {};
        foreach my $redeem_script ($self->redeem_script) {
            $self->{script}->{hash160($redeem_script)} = $redeem_script;
            $self->{script}->{hash256($redeem_script)} = $redeem_script;
        }
    }
    return $self->{script}->{$scripthash};
}

1;
