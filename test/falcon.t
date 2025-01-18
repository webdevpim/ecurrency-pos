#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib "$Bin/../lib";

use Test::More;

use QBitcoin::Config;
use QBitcoin::Const;
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script qw(script_eval op_pushdata);
use QBitcoin::Crypto qw(signature hash256 generate_keypair);
use QBitcoin::Address qw(wallet_import_format);
use QBitcoin::MyAddress;

my $pk = generate_keypair(CRYPT_ALGO_FALCON);
my $myaddr = QBitcoin::MyAddress->new( private_key => wallet_import_format($pk->pk_serialize) );
my $sign_data = "\x55\xaa" x 700;
my $redeem_script = OP_DUP . OP_HASH256 . op_pushdata(hash256($myaddr->pubkey)) . OP_EQUALVERIFY . OP_CHECKSIG;
my $signature = signature($sign_data, $myaddr, CRYPT_ALGO_FALCON, SIGHASH_ALL);
my $siglist = [ $signature, $myaddr->pubkey ];
my $tx = TestTx->new(sign_data => $sign_data);
my $res = script_eval($siglist, $redeem_script, $tx, 0);
ok($res, "checksig");
my $pk2 = generate_keypair(CRYPT_ALGO_FALCON);
my $myaddr2 = QBitcoin::MyAddress->new( private_key => wallet_import_format($pk2->pk_serialize) );
my $siglist2 = [ $signature, $myaddr2->pubkey ];
$res = script_eval($siglist2, $redeem_script, $tx, 0);
ok(!$res, "checksig (incorrect pubkey)");
my $signature2 = signature($sign_data, $myaddr2, CRYPT_ALGO_FALCON, SIGHASH_ALL);
my $siglist3 = [ $signature2, $myaddr->pubkey ];
$res = script_eval($siglist3, $redeem_script, $tx, 0);
ok(!$res, "checksig (incorrect signature)");
done_testing();

package TestTx;
use warnings;
use strict;

use QBitcoin::Accessors qw(new);
sub sign_data { $_[0]->{sign_data} };

1;
