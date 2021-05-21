package QBitcoin::Generate::Control;
use warnings;
use strict;

my $GENERATED_HEIGHT;

sub generated_height {
    my $class = shift;
    $GENERATED_HEIGHT = $_[0] if @_;
    return $GENERATED_HEIGHT;
}

sub generate_new {
    my $class = shift;
    undef $GENERATED_HEIGHT;
}

1;
