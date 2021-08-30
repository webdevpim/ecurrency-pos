package QBitcoin::RPC::Validate;
use warnings;
use strict;

use Role::Tiny;
use QBitcoin::RPC::Const;
use QBitcoin::Config;
use QBitcoin::Address;

my %SPEC = (
    height    => qr/^(?:0|[1-9][0-9]{0,9})\z/,
    blockhash => qr/^[0-9a-f]{64}\z/,
    txid      => qr/^[0-9a-f]{64}\z/,
    command   => qr/^[a-z]{2,64}\z/,
    verbosity => qr/^[12]\z/,
    verbose   => \&validate_boolean,
    address   => \&validate_address,
);

sub validate {
    my $self = shift;
    my @spec = split(/\s+/, $_[0]); 
    my $args = $self->args;

    if (@$args > @spec) {
        return $self->incorrect_params("Too many params", \@spec);
    }
    my $optional;
    for (my $i = 0; $i < @$args; $i++) {
        my $arg = $args->[$i];
        my $arg_name = $spec[$i];
        if (substr($arg_name, -1) eq '?') {
            $optional = 1;
        }
        elsif ($optional) {
            # Mandatory params cannot be after optional
            die "Incorrect params spec for " . $self->cmd;
        }
        my $spec_arg = $arg_name;
        $spec_arg =~ s/\?$//;
        $spec_arg =~ s@.*/@@;
        $arg_name =~ s@[:?/].*@@;
        if (my $rule = $SPEC{$spec_arg}) {
            if (ref($rule) eq 'Regexp') {
                $arg =~ $rule
                    or return $self->incorrect_params("Incorrect parameter '$arg_name'", \@spec);
            }
            elsif (ref($rule) eq 'CODE') {
                $rule->($args->[$i]) # arg may be modified by validation function
                    or return $self->incorrect_params("Incorrect parameter '$arg_name'", \@spec);
            }
            else {
                Warningf("Unknown type of validation rule for [%s]", $spec_arg);
            }
        }
        else {
            Warningf("No validation rule for [%s]", $spec_arg);
        }
    }
    for (my $i = @$args; $i < @spec; $i++) {
        next if substr($spec[$i], -1) eq '?';
        if ($optional) {
            die "Incorrect params spec for " . $self->cmd;
        }
        else {
            return $self->incorrect_params("Mandatory params missing", \@spec);
        }
    }
    return 0;
}

sub validate_boolean {
    my $value = $_[0];
    return 1 if ref($value) eq ref(FALSE);
    if (ref($value) eq "SCALAR") {
        $_[0] = $$value eq "1" ? TRUE : $$value eq "0" ? FALSE : return 0;
        return 1;
    }
    return 0 if ref($value);
    return 0 unless $value =~ /^(?:0|1|true|false)\z/;
    $value = 0 if $value eq "false";
    $_[0] = $value ? TRUE : FALSE;
    return 1;
}

sub validate_address {
    $_[0] =~ $config->{testnet} ? QBitcoin::Address->ADDRESS_TESTNET_RE : QBitcoin::Address->ADDRESS_RE;
}

sub incorrect_params {
    my $self = shift;
    my ($message, $spec) = @_;
    $self->response_error($message, ERR_INVALID_PARAMS, $self->brief($self->cmd) . "\n" . $self->help($self->cmd));
    return -1;
}

sub brief {
    my $self = shift;
    my ($cmd) = @_;
    my $spec = $self->params($cmd);
    my $params = $cmd;
    my $optional = 0;
    foreach my $arg (split(/\s+/, $spec)) {
        $params .= " ";
        if (substr($arg, -1) eq "?") {
            $params .= "[ ";
            $optional++;
        }
        $arg =~ s@[/:?].*@@;
        $params .= "<$arg>";
    }
    $params .= " " . "]" x $optional if $optional;
    return $params;
}

1;
