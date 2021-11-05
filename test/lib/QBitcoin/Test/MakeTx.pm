package QBitcoin::Test::MakeTx;
use warnings;
use strict;
use feature 'state';

use List::Util qw(sum);
use QBitcoin::TXO;
use QBitcoin::Transaction;
use QBitcoin::Script::OpCodes qw(:OPCODES);
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Crypto qw(hash160);

use Exporter qw(import);
our @EXPORT = qw(make_tx);

sub make_tx {
    my ($prev_tx, $fee) = @_;
    state $value = 10;
    state $tx_num = 1;
    $fee //= 0;
    $prev_tx = [ $prev_tx ] if $prev_tx && ref($prev_tx) ne 'ARRAY';
    my @in = $prev_tx ? map { $_->out->[0] } @$prev_tx : ();
    my $out_value = @in ? sum(map { $_->value } @in) : $value;
    my $script = op_pushdata(pack("v", $out_value - $fee)) . OP_DROP . OP_1;
    $_->{redeem_script} = op_pushdata(pack("v", $_->value)) . OP_DROP . OP_1 foreach @in;
    my $out = QBitcoin::TXO->new_txo( value => $out_value - $fee, scripthash => hash160($script), redeem_script => $script, num => 0 );
    my $tx = QBitcoin::Transaction->new(
        out => [ $out ],
        in  => [ map +{ txo => $_, siglist => [] }, @in ],
        $prev_tx ? () : ( coins_created => $out_value ),
    );
    $value += 10;
    $tx_num++;
    $tx->calculate_hash;
    my $num = 0;
    foreach my $out (@{$tx->out}) {
        $out->tx_in = $tx->hash;
        $out->num = $num++;
    }
    return $tx;
}

1;
