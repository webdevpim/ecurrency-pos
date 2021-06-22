package QBitcoin::Script::Const;
use warnings;
use strict;

use Exporter qw(import);

use constant {
    FALSE => "\x00",
    TRUE  => "\x01",
};

our @EXPORT = qw(FALSE TRUE);

1;
