package QBitcoin::Crypto::Schnorr;
use warnings;
use strict;

use Crypt::PK::ECC::Schnorr;

use constant CRYPT_ECC_MODULE => 'Crypt::PK::ECC::Schnorr';

use parent 'QBitcoin::Crypto::ECC';

1;
