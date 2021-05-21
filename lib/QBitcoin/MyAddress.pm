package QBitcoin::MyAddress;
use warnings;
use strict;
use feature 'state';

use QBitcoin::Config;
use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::ORM qw(find :types);

use Exporter qw(import);
our @EXPORT_OK = qw(my_address);

use constant TABLE => 'my_address';

use constant FIELDS => {
    address     => STRING,
    private_key => STRING,
    pubkey_crc  => STRING,
};

mk_accessors(keys %{&FIELDS});

sub my_address {
    my $class = shift // __PACKAGE__;
    state $address = [ map { $_->address } $class->find() ];
    return wantarray ? @$address : $address->[0];
}

1;
