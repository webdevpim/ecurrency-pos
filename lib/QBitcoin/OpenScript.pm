package QBitcoin::OpenScript;
use warnings;
use strict;

use QBitcoin::ORM qw(find create :types);

use constant TABLE => 'open_script';
use constant FIELDS => {
    id   => NUMERIC,
    data => BINARY,
};

sub store {
    my $class = shift;
    my ($data) = @_;
    # I suppose find()+create() will be more quickly than "insert ignore" + "find" in most cases (when such script already stored)
    return $class->find(data => $data) // $class->create(data => $data);
}

1;
