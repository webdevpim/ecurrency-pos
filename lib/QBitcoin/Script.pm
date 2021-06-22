package QBitcoin::Script;
use warnings;
use strict;

use QBitcoin::Log;
use QBitcoin::Crypto qw(hash160);
use QBitcoin::Script::OpCodes qw(OPCODES :OPCODES);
use QBitcoin::Script::Const;
use QBitcoin::Script::State;

use Role::Tiny::With;
with 'QBitcoin::Script::CheckSig';

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

sub unpack_int($) {
    my ($data) = @_;
    defined($data) or return undef;
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

my %INT_2_1 = (
    add => sub { $a + $b },
    sub => sub { $a - $b },
);
my %BIN_1_1 = (
    hash160 => sub { hash160($a) },
);
my %PUSH_CONST = (
    false     => "",
    "1negate" => pack_int(-1),
    map { $_ => pack_int($_) } 1 .. 16,
);

my @OP_CMD;

sub opcode_to_cmd($) {
    my ($opcode) = @_;
    $opcode =~ s/^OP_//;
    return lc($opcode);
}

foreach my $opcode (keys %{&OPCODES}) {
    my $cmd = opcode_to_cmd($opcode);
    if (my $func = __PACKAGE__->can("cmd_$cmd")) {
        $OP_CMD[OPCODES->{$opcode}] = $func;
    }
    elsif ($INT_2_1{$cmd}) {
        $OP_CMD[OPCODES->{$opcode}] = sub {
            my ($state) = @_;
            return unless $state->ifstate;
            my $stack = $state->stack;
            @$stack >= 2 or return 0;
            local $a = unpack_int(pop @$stack) // return 0;
            local $b = unpack_int(pop @$stack) // return 0;
            push @$stack, pack_int($INT_2_1{$cmd}->());
            return undef;
        };
    }
    elsif ($BIN_1_1{$cmd}) {
        $OP_CMD[OPCODES->{$opcode}] = sub {
            my ($state) = @_;
            return unless $state->ifstate;
            my $stack = $state->stack;
            @$stack >= 2 or return 0;
            local $a = $stack->[-1];
            $stack->[-1] = $BIN_1_1{$cmd}->();
            return undef;
        };
    }
    elsif (exists $PUSH_CONST{$cmd}) {
        $OP_CMD[OPCODES->{$opcode}] = sub {
            my ($state) = @_;
            return unless $state->ifstate;
            push @{$state->stack}, $PUSH_CONST{$cmd};
            return undef;
        };
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
    my ($script, $stack, $ifstate) = @$state;
    length($script) >= $bytes
        or return 0;
    my $data = substr($state->script, 0, $bytes, "");
    return unless $ifstate;
    push @$stack, $data;
    return undef;
}

sub cmd_dup($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    push @$stack, $stack->[-1];
    return undef;
}

sub cmd_return($) {
    my ($state) = @_;
    return unless $state->ifstate;
    return 0;
}

sub cmd_if($) {
    my ($state) = @_;
    my $stack = $state->stack;
    @$stack or return 0;
    my $new_state = is_true(pop @$stack);
    push @{$state->ifstack}, $new_state;
    $state->ifstate &&= $new_state;
    return undef;
}

sub cmd_notif($) {
    my ($state) = @_;
    my $stack = $state->stack;
    @$stack or return 0;
    my $new_state = !is_true(pop @$stack);
    push @{$state->ifstack}, $new_state;
    $state->ifstate &&= $new_state;
    return undef;
}

sub cmd_else($) {
    my ($state) = @_;
    my $ifstack = $state->ifstack;
    @$ifstack or return 0;
    $ifstack->[-1] = !$ifstack->[-1];
    $state->set_ifstate();
    return undef;
}

sub cmd_endif($) {
    my ($state) = @_;
    my $ifstack = $state->ifstack;
    @$ifstack or return 0;
    pop @$ifstack;
    $state->set_ifstate();
    return undef;
}

sub cmd_verify($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    return @$stack && is_true(pop @$stack) ? undef : 0;
}

sub cmd_equal($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack >= 2 or return 0;
    my $data = pop @$stack;
    $stack->[-1] = $stack->[-1] eq $data;
    return undef;
}

sub cmd_equalverify($) {
    my ($state) = @_;
    return unless $state->ifstate;
    my $stack = $state->stack;
    @$stack >= 2 or return 0;
    my $data1 = pop @$stack;
    my $data2 = pop @$stack;
    return $data1 eq $data2 ? undef : 0;
}

sub execute {
    my ($state) = @_;
    while (length($state->script)) {
        my $cmd_code = substr($state->script, 0, 1, "");
        if (my $cmd_func = $OP_CMD[ord($cmd_code)]) {
            my $res = $cmd_func->($state);
            return $res if defined $res;
        }
        else {
            return 0; # Invalid opcode
        }
    }
    return undef;
}

sub script_eval($$$$) {
    my ($close_script, $open_script, $tx, $input_num) = @_;

    my $state = QBitcoin::Script::State->new($close_script, $tx, $input_num);
    my $res;
    $res = execute($state);
    return $res if defined($res);

    # should we check/clear the if-stack here?
    $state->script = $open_script;
    $res = execute($state);
    return $res if defined($res);

    return $state->ok;
}

1;
