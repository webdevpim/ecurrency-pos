package QBitcoin::Generate::Control;
use warnings;
use strict;

my $GENERATED_TIME;

sub generated_time {
    my $class = shift;
    $GENERATED_TIME = $_[0] if @_;
    return $GENERATED_TIME;
}

sub generate_new {
    my $class = shift;
    undef $GENERATED_TIME;
}

1;
