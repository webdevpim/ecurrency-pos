package Bitcoin::Transaction;
use warnings;
use strict;

use QBitcoin::Accessors qw(mk_accessors new);

mk_accessors(qw(hash in out));

1;
