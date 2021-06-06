package QBitcoin::Script;
use warnings;
use strict;

use QBitcoin::Log;
use QBitcoin::Crypto qw(check_sig hash160);
use QBitcoin::Script::OpCodes qw(OPCODES :OPCODES);

use Exporter qw(import);
our @EXPORT_OK = qw(script_eval pushdata);

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

use constant {
    FALSE => "\x00",
    TRUE  => "\x01",
};

my @OP_CMD;

sub opcode_to_cmd($) {
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
        $OP_CMD[OPCODES->{$opcode}] //= sub { unimplemented(OPCODES->{$opcode}, @_) };
    }
}
foreach my $opcode (0x01 .. 0x4b) {
    $OP_CMD[$opcode] = sub { cmd_pushdatan($opcode, @_) };
}

sub unimplemented($$) {
    my ($opcode, $state) = @_;
    Infof("Unimplemented opcode 0x%02x", $opcode);
    return 0;
}

sub unpack_int($) {
    my ($data) = @_;
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

sub pack_int($) {
    my ($n) = @_;
    if ($n >= 0) {
        if ($n < 0x80) {
            return pack("C", $n);
        }
        elsif ($n < 0x8000) {
            return pack("v", $n);
        }
        elsif ($n < 0x800000) {
            return pack("vC", $n >> 8, $n & 0xff);
        }
        elsif ($n < 0x80000000) {
            return pack("V", $n);
        }
        elsif ($n < 0x80000000 << 8) {
            return pack("VC", $n >> 8, $n & 0xff);
        }
        else {
            die "Error in script eval (too large int for push to stack)\n";
        }
    }
    else {
        if ($n > -0x80) {
            return pack("C", 0x80 | -$n);
        }
        elsif ($n > -0x8000) {
            return pack("v", 0x8000 | -$n);
        }
        elsif ($n > -0x800000) {
            return pack("vC", 0x8000 | (-$n >> 8), -$n & 0xff);
        }
        elsif ($n > -0x80000000) {
            return pack("V", 0x80000000 | -$n);
        }
        elsif ($n > -(0x80000000 << 8)) {
            return pack("VC", 0x80000000 | (-$n >> 8), -$n & 0xff);
        }
        else {
            die "Error in script eval (too large int)\n";
        }
    }
}

sub pushdata($) {
    my ($data) = @_;
    my $cmd;
    my $length = length($data);
    if ($length <= 0x4b) {
        $cmd = pack("C", $length);
    }
    elsif ($length <= 0xff) {
        $cmd = OP_PUSHDATA1 . pack("C", $length);
    }
    elsif ($length <= 0xffff) {
        $cmd = OP_PUSHDATA2 . pack("v", $length);
    }
    else {
        die "Too long data: $length bytes\n";
    }
    return $cmd . $data;
}

sub is_true($) {
    my ($data) = @_;
    return $data !~ /^\x80?\x00*\z/;
}

sub cmd_pushdatan($$) {
    my ($bytes, $state) = @_;
    my ($script, $stack, $ifstack) = @$state;
    length($state->[0]) >= $bytes
        or return 0;
    my $data = substr($state->[0], 0, $bytes, "");
    return if $ifstack->[0];
    push @$stack, $data;
    return undef;
}

sub cmd_dup($) {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    push @$stack, $stack->[-1];
    return undef;
}

sub cmd_add($) {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    my $int1 = unpack_int(pop @$stack) // return 0;
    my $int2 = unpack_int(pop @$stack) // return 0;
    push @$stack, pack_int($int1+$int2);
    return undef;
}

sub cmd_sub($) {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    my $int1 = unpack_int(pop @$stack) // return 0;
    my $int2 = unpack_int(pop @$stack) // return 0;
    push @$stack, pack_int($int1-$int2);
    return undef;
}

sub cmd_return($) {
    # return if $state->[2]->[0]; # ifstack -- "return" cannot be inside "if" condition
    return 0;
}

sub cmd_verify($) {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    return @$stack && is_true(pop @$stack) ? undef : 0;
}

sub cmd_equal($) {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    @$stack >= 2 or return 0;
    my $data = pop @$stack;
    $stack->[-1] = $stack->[-1] eq $data;
    return undef;
}

sub cmd_false($) {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    push @$stack, FALSE;
    return undef;
}

sub cmd_1($) {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    push @$stack, TRUE;
    return undef;
}

sub cmd_equalverify($) {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    @$stack >= 2 or return 0;
    my $data1 = pop @$stack;
    my $data2 = pop @$stack;
    return $data1 eq $data2 ? undef : 0;
}

sub cmd_hash160($) {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    @$stack >= 1 or return 0;
    $stack->[-1] = hash160($stack->[-1]);
    return undef;
}

sub cmd_checksig($) {
    my ($state) = @_;
    return if $state->[2]->[0]; # ifstack
    my $stack = $state->[1];
    @$stack >= 2 or return 0;
    my $pubkey = pop @$stack;
    my $signature = pop @$stack;
    push @$stack, check_sig($state->[3], $signature, $pubkey) ? TRUE : FALSE;
}

sub script_eval($$) {
    my ($script, $tx_data) = @_;
    my $state = [$script, [], [], $tx_data]; # script, stack, if-stack, tx-data
    while (length($state->[0])) {
        my $cmd_code = substr($state->[0], 0, 1, "");
        if (my $cmd_func = $OP_CMD[ord($cmd_code)]) {
            my $res = $cmd_func->($state);
            return $res if defined $res;
        }
        else {
            return (0, "Invalid opcode");
        }
    }
    my $stack = $state->[1];
    return (@$stack == 1 && $stack->[0] eq TRUE);
}

1;
