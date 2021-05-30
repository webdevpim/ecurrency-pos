package QBitcoin::Crypto;
use warnings;
use strict;

use Exporter qw(import);

our @EXPORT_OK = qw(check_sig);

use Crypt::PK::ECC;

sub check_sig {
    my ($data, $signature, $pubkey) = @_;
    my $pub = Crypt::PK::ECC->import_key_raw($pubkey, 'secp256k1');
    return $pub->verify_message($signature, $data);
}

1;
