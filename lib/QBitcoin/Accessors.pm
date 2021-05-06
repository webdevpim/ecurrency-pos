package QBitcoin::Accessors;
use warnings;
use strict;

use Exporter qw(import);
our @EXPORT_OK = qw(
    new
    mk_accessors
);

sub new {
    my $class = shift;
    return bless { @_ == 1 ? %{$_[0]} : @_ }, $class;
}

sub mk_accessors {
    my $class = caller;

    no strict 'refs';
    foreach my $attr (@_) {
        my $glob_name = "${class}::$attr";
        *$glob_name = sub :lvalue {
            @_ == 1 ? $_[0]->{$attr}         :
            @_ == 2 ? $_[0]->{$attr} = $_[1] :
            die "Too many args for accessor [$attr] class [$class]";
        };
    }
}

1;
