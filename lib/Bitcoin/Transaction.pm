package Bitcoin::Transaction;
use warnings;
use strict;

use QBitcoin::Accessors qw(mk_accessors new);
use QBitcoin::Crypto qw(hash256);

mk_accessors(qw(hash in out));

sub deserialize {
    my $class = shift;
    my ($tx_data) = @_;

    my $start_index = $tx_data->index;
    my ($version) = unpack("V", $tx_data->get(4)); # 1 or 2
    my $txin_count = $tx_data->get_varint();
    my $has_witness = 0;
    if ($txin_count == 0) {
        $has_witness = unpack("C", $tx_data->get(1)); # should be always 1
        $txin_count = $tx_data->get_varint();
    }
    my @tx_in;
    for (my $n = 0; $n < $txin_count; $n++) {
        my $prev_output = $tx_data->get(36); # (prev_tx_hash, output_index)
        # first 4 bytes of the script for coinbase tx block verion 2 are "\x03" and block height
        my $script = $tx_data->get_string();
        my $sequence = $tx_data->get(4);
        push @tx_in, {
            tx_out   => substr($prev_output, 0, 32),
            num      => unpack("V", substr($prev_output, 32, 4)),
            script   => $script,
            sequence => $sequence,
        },
    }
    my $txout_count = $tx_data->get_varint();
    my @tx_out;
    for (my $n = 0; $n < $txout_count; $n++) {
        my $value = unpack("Q<", $tx_data->get(8));
        my $open_script = $tx_data->get_string();
        push @tx_out, {
            value       => $value,
            open_script => $open_script,
        };
    }
    if ($has_witness) {
        foreach (my $n = 0; $n < $txin_count; $n++) {
            my $witness_count = $tx_data->get_varint();
            my @witness;
            foreach (my $k = 0; $k < $witness_count; $k++) {
                push @witness, $tx_data->get_string();
            }
            $tx_in[$n]->{witness} = \@witness;
        }
    }
    my $lock_time = unpack("V", $tx_data->get(4));
    my $end_index = $tx_data->index;
    $tx_data->index = $start_index; # rewind
    my $hash = reverse hash256($tx_data->get($end_index - $start_index));
    return $class->new(
        in   => \@tx_in,
        out  => \@tx_out,
        hash => $hash,
    );
}

1;
