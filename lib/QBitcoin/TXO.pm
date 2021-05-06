package QBitcoin::TXO;
use warnings;
use strict;

use QBitcion::ORM;

use constant FIELDS => {
    value         => NUMERIC,
    num           => NUMERIC,
    tx_in         => REFERENCE('QBitcoin::Transaction'),
    tx_out        => ALLOW_NULL(REFERENCE('QBitcoin::Transaction')),
    lock_script   => BINARY,
    unlock_script => BINARY,
    data          => BINARY,
};

1;
