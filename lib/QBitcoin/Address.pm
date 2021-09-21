package QBitcoin::Address;
use warnings;
use strict;

# Private key format compatible with bitcoin; public key and address are not

use Math::GMPz;
use Encode::Base58::GMP qw(encode_base58 decode_base58);
use QBitcoin::Config;
use QBitcoin::Crypto qw(hash160 checksum32);
use QBitcoin::Script qw(op_pushdata);
use QBitcoin::Script::OpCodes qw(:OPCODES);

use constant MAGIC              => "1234";
use constant MAGIC_TESTNET      => "1235";
use constant MAGIC_LEN          => length(MAGIC);
use constant CHECKSUM_LEN       => 4;
use constant ADDRESS_RE         => qr/.*/; # TODO
use constant ADDRESS_TESTNET_RE => qr/.*/; # TODO

use Exporter qw(import);
our @EXPORT_OK = qw(
    wallet_import_format
    wif_to_pk
    address_by_pubkey
    validate_address
    pubhash_by_address
    script_by_pubkey
    script_by_pubkeyhash
    scripthash_by_address
    ADDRESS_RE
    ADDRESS_TESTNET_RE
);

# https://en.bitcoin.it/wiki/Wallet_import_format
sub address_version() {
    return $config->{testnet} ? "\xEF" : "\x80";
}

sub wallet_import_format($) {
    my ($private_key) = @_;

    my $data = address_version . $private_key;
    return encode_base58('0x' . unpack('H*', $data . checksum32($data)), 'bitcoin');
}

sub wif_to_pk($) {
    my ($private_wif) = shift;
    my $gmpz_obj = decode_base58($private_wif, 'bitcoin');
    my $bin = Math::GMPz::Rmpz_export(1, 1, 0, 0, $gmpz_obj);
    my $crc = substr($bin, -CHECKSUM_LEN, CHECKSUM_LEN, "");
    checksum32($bin) eq $crc
        or die "Incorrect checksum";
    substr($bin, 0, 1, "") eq address_version
        or die "Incorrect address version";
    return $bin;
}

# qbitcoin part, incompatible with bitcoin

sub magic() {
    return $config->{testnet} ? MAGIC_TESTNET : MAGIC;
}

sub script_by_pubkey {
    my ($public_key) = @_;
    return op_pushdata($public_key) . OP_CHECKSIG;
}

sub script_by_pubkeyhash {
    my ($publickeyhash) = @_;
    return OP_DUP . OP_HASH160 . op_pushdata($publickeyhash) . OP_EQUALVERIFY . OP_CHECKSIG;
}

sub address_by_hash($) {
    my ($scripthash) = shift;
    my $data = magic . $scripthash;
    return encode_base58("0x" . unpack("H*", $data . checksum32($data)), "bitcoin");
}

sub address_by_pubkey($) {
    my ($public_key) = shift;

    return address_by_hash(hash160(script_by_pubkey($public_key)));
}

sub validate_address($) {
    my ($address) = @_;

    return 0 unless $address;
    my $re = $config->{testnet} ? ADDRESS_TESTNET_RE : ADDRESS_RE;
    $address =~ $re
        or return 0;
    my $gmpz_obj = eval { decode_base58($address, 'bitcoin') };
    return 0 if $@;

    my $bin = Math::GMPz::Rmpz_export(1, 1, 0, 0, $gmpz_obj);
    my $crc = substr($bin, -CHECKSUM_LEN, CHECKSUM_LEN, "");
    checksum32($bin) eq $crc
        or return 0;
    return substr($bin, 0, MAGIC_LEN) eq magic;
}

sub scripthash_by_address($) {
    my ($address) = shift;

    # TODO: parse POW-addresses, fetch pubkeyhash and then create scripthash by the pubkeyhash
    my $gmpz_obj = decode_base58($address, 'bitcoin');
    my $bin = Math::GMPz::Rmpz_export(1, 1, 0, 0, $gmpz_obj);
    my $crc = substr($bin, -CHECKSUM_LEN, CHECKSUM_LEN, "");
    checksum32($bin) eq $crc
        or die "Incorrect address checksum\n";
    substr($bin, 0, MAGIC_LEN, "") eq magic
        or die "Incorrect address version\n";
    return $bin;
}

1;
