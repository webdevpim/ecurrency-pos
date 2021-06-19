package Bitcoin::Serialized;
use warnings;
use strict;

# Object with [ $data, $index ] to avoid rewrite long data during deserialize

sub new {
    my ($class, $data) = @_;
    bless [ $data, 0 ], $class;
}

sub data {
    $_[0]->[0];
}

sub index :lvalue {
    $_[0]->[1];
}

sub length {
    length($_[0]->[0]) - $_[0]->[1];
}

sub get {
    my ($self, $len) = @_;
    my $res = substr($self->[0], $self->[1], $len);
    $self->[1] += $len;
    return $res;
}

sub get_varint {
    my $self = shift;
    my $first = unpack("C", $self->get(1));
    # We do not check if $data has enough data, but if not we will fail on next step, get items
    return $first < 0xFD ? $first :
        $first == 0xFD ? unpack("v", $self->get(2)) :
        $first == 0xFE ? unpack("V", $self->get(4)) :
        unpack("Q<", $self->get(8));
}

sub get_string {
    my $self = shift;
    my $n = $self->get_varint();
    return $n ? $self->get($n) : "";
}

1;
