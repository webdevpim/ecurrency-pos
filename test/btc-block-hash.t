#! /usr/bin/env perl
use warnings;
use strict;

use FindBin '$Bin';
use lib "$Bin/../lib";

use Test::More;
use QBitcoin::Crypto qw(hash256);

my $btc_block_header = {
  hash => "00000000000000000001c4245d08c882992ddf3876985931cdb0d561846b760f",
  confirmations => 1,
  height => 697199,
  version => 536870916,
  versionHex => "20000004",
  merkleroot => "f3342ef90b55916f3b839f7d768568d07a142a1baf3368f60fa3ffb709eda1aa",
  time => 1629729368,
  mediantime => 1629726388,
  nonce => 2054045039,
  bits => "1712180b",
  difficulty => 15556093717702.55,
  chainwork => "000000000000000000000000000000000000000020bfbc6dc747a8cfcaaf6c00",
  nTx => 3280,
  previousblockhash => "00000000000000000007531d2739b7ea2dc8450245c962081c3621086ee73d84",
};
my $data = pack("V", $btc_block_header->{version}) .
	reverse(pack("H*", $btc_block_header->{previousblockhash})) .
	reverse(pack("H*", $btc_block_header->{merkleroot})) .
    pack("V", $btc_block_header->{time}) .
    reverse(pack("H*", $btc_block_header->{bits})) .
    pack("V", $btc_block_header->{nonce});

is(unpack("H*", scalar reverse hash256($data)), $btc_block_header->{hash}, "hash matched");

done_testing;
