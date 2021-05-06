package QBitcoin::Transaction;
use warnings;
use strict;

use QBitcoin::ORM;

use constant FIELDS => {
    hash         => BINARY,
    block_height => NUMERIC,
};

1;
