package QBitcoin::Script;
use warnings;
use strict;

use QBitcoin::Crypto qw(check_sig hash160);
use QBitcoin::Script::OpCodes;

use Exporter qw(import);
our @EXPORT_OK = qw(script_eval);

# bitcoin script
# https://en.bitcoin.it/wiki/Script
# https://wiki.bitcoinsv.io/index.php/Opcodes_used_in_Bitcoin_Script
# useful links:
# https://blockgeeks.com/guides/best-bitcoin-script-guide/
# https://komodoplatform.com/en/blog/bitcoin-script/
# https://hedgetrade.com/bitcoin-script-explained/
# https://bitcoin.stackexchange.com/questions/3374/how-to-redeem-a-basic-tx
# https://en.bitcoin.it/w/images/en/7/70/Bitcoin_OpCheckSig_InDetail.png
# https://developer.bitcoin.org/devguide/transactions.html
# https://academy.bit2me.com/en/what-is-bitcoin-script/# (?)

my @OP_CMD;

sub opcode_to_cmd {
    my ($opcode) = @_;
    $opcode =~ s/^OP_//;
    return "cmd_" . lc($opcode);
}

foreach my $opcode (keys %{&OPCODES}) {
    if (my $func = __PACKAGE__->can(opcode_to_cmd($opcode))) {
        $OP_CMD[OPCODES->{$opcode}] = $func;
    }
}
foreach my $opcode (keys %{&OPCODES}) {
    if (!__PACKAGE__->can(opcode_to_cmd($opcode))) {
        $OP_CMD[OPCODES->{$opcode}] //= sub { unimplemented($opcode, $@) };
    }
}
foreach my $opcode (0x01 .. 0x4b) {
    $OP_CMD[$opcode] = sub { cmd_pushdatan($opcode, @_) };
}

sub unimplemented {
    my ($opcode, $state) = @_;
    Infof("Unimplemented opcode 0x%02x", ord($opcode));
    return 0;
}

sub popint {
    my ($stack) = @_;
    @$stack or return undef;
    my $data = pop @$stack;
    my $l = length($data);
    if ($l == 1) {
        my $n = unpack("C", $data);
        return $n & 0x80 ? -($n ^ 0x80) : $n;
    }
    elsif ($l == 2) {
        my $n = unpack("v", $data);
        return $n & 0x8000 ? -($n ^ 0x8000) : $n;
    }
    elsif ($l == 4) {
        my $n = unpack("V", $data);
        return $n & 0x80000000 ? -($n ^ 0x80000000) : $n;
    }
    elsif ($l == 3) {
        my ($first, $last) = unpack("vC", $data);
        return $first & 0x8000 ? -(($first ^ 0x8000) << 8 | $last) : $first << 8 | $last;
    }
    else {
        return undef;
    }
}

sub pushint {
    my ($stack, $n) = @_;
    if ($n >= 0) {
        if ($n < 0x80) {
            push @$stack, pack("C", $n);
        }
        elsif ($n < 0x8000) {
            push @$stack, pack("v", $n);
        }
        elsif ($n < 0x800000) {
            push @$stack, pack("vC", $n >> 8, $n & 0xff);
        }
        elsif ($n < 0x80000000) {
            push @$stack, pack("V", $n);
        }
        elsif ($n < 0x80000000 << 8) {
            push @$stack, pack("VC", $n >> 8, $n & 0xff);
        }
        else {
            die "Error in script eval (too large int for push to stack)\n";
        }
    }
    else {
        if ($n > -0x80) {
            push @$stack, pack("C", 0x80 | -$n);
        }
        elsif ($n > -0x8000) {
            push @$stack, pack("v", 0x8000 | -$n);
        }
        elsif ($n > -0x800000) {
            push @$stack, pack("vC", 0x8000 | (-$n >> 8), -$n & 0xff);
        }
        elsif ($n > -0x80000000) {
            push @$stack, pack("V", 0x80000000 | -$n);
        }
        elsif ($n > -(0x80000000 << 8)) {
            push @$stack, pack("VC", 0x80000000 | (-$n >> 8), -$n & 0xff);
        }
        else {
            die "Error in script eval (too large int for push to stack)\n";
        }
    }
}

sub is_true {
    my ($data) = @_;
    return $data !~ /^\x80?\x00*\Z/;
}

sub cmd_pushdatan {
    my ($bytes, $state) = @_;
    my ($script, $stack, $ifstack) = @$state;
    length($state->[0]) >= $bytes
        or return 0;
    my $data = substr($state->[0], 0, $bytes, "");
    return if $ifstack->[0];
    push @$stack, $data;
    return undef;
}

sub cmd_dup {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    push @$stack, $stack->[0];
    return undef;
}

sub cmd_add {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    my $int1 = popint($stack) // return 0;
    my $int2 = popint($stack) // return 0;
    pushint($stack, $int1+$int2);
    return undef;
}

sub cmd_sub {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    my $int1 = popint($stack) // return 0;
    my $int2 = popint($stack) // return 0;
    pushint($stack, $int1-$int2);
    return undef;
}

sub cmd_return {
    # return if $state->[2]->[0]; # ifstack -- "return" cannot be inside "if" condition
    return 0;
}

sub cmd_verify {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    return @$stack && is_true(pop @$stack) ? undef : 0;
}

sub cmd_equial {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    @$stack >= 2 or return 0;
    $stack->[1] = $stack->[1] eq $stack->[0];
    pop @$stack;
    return undef;
}

sub cmd_false {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    push @$stack, "\x00";
    return undef;
}

sub cmd_equialverify {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    @$stack >= 2 or return 0;
    my $data1 = pop @$stack;
    my $data2 = pop @$stack;
    return $data1 eq $data2 ? undef : 0;
}

sub cmd_hash160 {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    @$stack >= 1 or return 0;
    $stack->[0] = hash160($stack->[0]);
    return undef;
}

sub cmd_checksig {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    @$stack >= 2 or return 0;
    my $signature = pop @$stack;
    my $pubkey = pop @$stack;
    push @$stack, check_sig($state->[3], $signature, $pubkey) ? "\x01" : "\x00";
}

sub script_eval {
    my ($script, $tx_data) = @_;
    my $state = [$script, [], [], $tx_data]; # script, stack, if-stack, tx-data
    while (length($state->[0])) {
        my $cmd_code = substr($state->[0], 0, 1, "");
        if (my $cmd_func = $OP_CMD[$cmd_code]) {
            my $res = $cmd_func->($state);
            return $res if defined $res;
        }
        else {
            return (0, "Invalid opcode");
        }
    }
    my $stack = $state->[1];
    return (@$stack == 1 && $stack->[0] eq "\x01");
}

1;
