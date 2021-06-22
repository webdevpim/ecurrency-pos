#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib "$Bin/../lib";

use Test::More;

use QBitcoin::Config;
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script qw(script_eval pushdata);
use QBitcoin::Crypto qw(signature pubkey_by_privkey hash160);
use Crypt::PK::ECC;

$config->{verbose} = 0;

my @scripts_ok = (
    [ op_1      => OP_1 ],
    [ op_verify => OP_1 . OP_1 . OP_VERIFY ],
    [ op_if     => OP_1 . OP_IF . OP_1 . OP_VERIFY . OP_1 . OP_ENDIF ],
    [ op_ifif   => OP_0 . OP_IF . OP_0 . OP_VERIFY . OP_ELSE . OP_1 . OP_IF . OP_1 . OP_ELSE . OP_0 . OP_ENDIF . OP_ENDIF ],
);

my @scripts_fail = (
    [ empty       => "" ],
    [ empty_stack => OP_1 . OP_VERIFY ],
    [ return_1    => OP_1 . OP_RETURN ],
    [ with_stack  => OP_1 . OP_1 ],
    [ zero_stack  => OP_0 ],
    [ op_verify   => OP_0 . OP_1 . OP_VERIFY ],
    [ op_if       => OP_IF . OP_1 . OP_ENDIF ],
    [ op_if2      => OP_1 . OP_IF . OP_0 . OP_ELSE . OP_1 . OP_ENDIF ],
    [ op_ifif     => OP_1 . OP_1 . OP_IF . OP_ELSE . OP_IF . OP_ENDIF . OP_1 ],
);

foreach my $check_data (@scripts_ok) {
    my ($name, $script, $tx_data) = @$check_data;
    my $res = script_eval($script, "", $tx_data // "", 0);
    ok($res, $name);
}

foreach my $check_data (@scripts_fail) {
    my ($name, $script, $tx_data) = @$check_data;
    my $res = script_eval($script, "", $tx_data // "", 0);
    ok(!$res, $name);
}

my $pk = Crypt::PK::ECC->new();
$pk->generate_key(QBitcoin::Crypto->CURVE);
my $sign_data = "\x55\xaa" x 700;
my $pubkey = pubkey_by_privkey($pk);
my $open_script = OP_DUP . OP_HASH160 . pushdata(hash160($pubkey)) . OP_EQUALVERIFY . OP_CHECKSIG;
my $signature = signature($sign_data, $pk);
my $close_script = pushdata($signature) . pushdata($pubkey);
my $tx = TestTx->new(sign_data => $sign_data);
my $res = script_eval($close_script, $open_script, $tx, 0);
ok($res, "checksig");

done_testing();

package TestTx;
use warnings;
use strict;

use QBitcoin::Accessors qw(new);
sub sign_data { $_[0]->{sign_data} };

1;
