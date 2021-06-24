#! /usr/bin/env perl
use warnings;
use strict;

use Test::More;

use FindBin '$Bin';
use lib "$Bin/../lib";

use Bitcoin::Transaction;
use Bitcoin::Block;

# bitcoin testnet3, block 2000000
my @tx_hash = (
    "c55312dd5927bfb30e0a63956b3c83837718e3652c122f2ba8a80c1d405345a2",
    "e80587b13950900ba12ced29b50761815f3da37fd8998004d701ffddeb212936",
    "0931d995f2e84b610bfcc6e5a960dea3baee16229c156518d7fbaee4141d14ef",
);
my $merkle_root = "fdaded45771a3d432b61bd090e62ed09fcce712e8483da5789b82c96ea2bc8b6";
my @transactions = map { Bitcoin::Transaction->new({ hash => scalar reverse pack("H*", $_) }) } @tx_hash;
my $block = Bitcoin::Block->new({ transactions => \@transactions });
is(unpack("H*", scalar reverse $block->calculate_merkle_root), $merkle_root, scalar(@tx_hash) . " hashes");

# bitcoin testnet3, block 2006075
@tx_hash = (
    "b016ed07c66c88f8d172c3837dbbd56195daceee4191b2a1c87762d031c6422d",
    "69f65c1bfb51126270a25c2db724b87418a2b48e0a3b451d35fe27441d376807",
    "23838f671ca8d38a13ca2539ba9eb9cce6bf6d44a5a15212979f1dbc6e5d7cda",
    "5caaff5074af9338514da62b900b19061c9ea21ec2771e92e1b783a87011a5ff",
    "70b6f9e7ce33cba6065964d4082a2b43133505617c259002091bb9746a62d6ee",
    "08c651cc0d246fc5f59328e31faa6304dcb3814c9188469491facff055379b39",
    "1be05e24760fb76cf4c008ddf872ee3c718a27907c786158004453c9227c82a3",
    "10fa484d8b1bf52d776f6b7899bb196b2686285c4630c2aa6f825abaa9338efc",
    "1300344065b5287cbb25d9dfd55b6b1fad84ed8e65c3b330649a103ae09df5e2",
);
$merkle_root = "227fbdc9599c0b120898baaf3a171e3c1313c3c613654eb83070907353cbe053";
@transactions = map { Bitcoin::Transaction->new({ hash => scalar reverse pack("H*", $_) }) } @tx_hash;
$block = Bitcoin::Block->new({ transactions => \@transactions });
is(unpack("H*", scalar reverse $block->calculate_merkle_root), $merkle_root, scalar(@tx_hash) . " hashes");

# bitcoin testnet3 block 2006082 000000000000001a987046358a06ce78207131acc34e4e2860352fc304602a86
@tx_hash = (
    "4a0092b4dce3dce1f86952a28443a9538050835f33c566503663f59ddf996c72",
    "21110a54ef4370ba6388387ed4e484ed0bd16a750653967cfece289b55e30931",
    "8de59fa627fe32592d941eaffc4790ea6f3b27edfae06b081aafc3b6518a6e24",
    "500edb270eaab790102365e178d1634d439b295daa63597b9f250d094205e013",
    "a975f000b951608eee91a8126d20780ca473f8be296cc0eac821df8441654688",
    "9d009281167beebd743360e4ee82c130d5fa0148be035f0cad3ab098699af0a1",
    "f703556a1d95f0d6b5b41035098dc1fcd23f61b9367c6037c0bda338a71ee3d3",
    "715eefbeb940c262e3cc4557e99633efbe54ab3d2f3fd95732b7b58088178f2c",
    "b6f87e3d99233ac238dec6ae4c293e01eb5c55add5af4f8fbc9e8a010a3ee913",
    "e5a68d45a5d7e406b4113db3928e1812263ddfb51ea1e7552c34e233ebcfb198",
    "8afd0bb3db84d96e27302708e640a7e7ba5e64125eae31f425d160da772071f2",
);
$merkle_root = "adf076adba7f05284ed5443e39d8194e3e7e9be7659183668038005cfa3a9f84";
@transactions = map { Bitcoin::Transaction->new({ hash => scalar reverse pack("H*", $_) }) } @tx_hash;
$block = Bitcoin::Block->new({ transactions => \@transactions });
is(unpack("H*", scalar reverse $block->calculate_merkle_root), $merkle_root, scalar(@tx_hash) . " hashes");

# bitcoin testnet3 block 2006073
@tx_hash = (
    "971be4a725cf9c529ee7877aa58d9c09c2d57e90815364758d3fb2d11c3d57c8",
    "6576e01831b78734714d770fd3e8a6158062df371cd13dc2d911d5beaebdc39b",
    "03d2b95dbbc533392fe1076a954d05892b9a8198ae2a337546a3187c32c6af0e",
    "70b46fbaaa13b8509b00071f424185ae87b2b867e9ae151f4fdd0ed2d300bf93",
    "ebac573780697ca149d80b3c25bb07a62411355d8b2a02d94caf7f0cf981a435",
    "97a75464fa2ed45b5626bdb26ab9f2caf0ecd90e71c9434b81318bd5ac20e19d",
    "f8e5781fdbedf59d038e801f0ae30c1837147abd47c636940877354463996bed",
    "20bbfb32aa6a7ebaab26f1aaf028ad2c2b928e6aa49a59346c02e38af4e86332",
    "60d998cc53021ea2cbe67a59d4122cb308d2ccd5f460d9f653c2d7ac65f262d4",
    "e4a366959ef7d53ccb6950146493ddcf27701b4947d1053ef3e37f3deee08462",
    "25f8d8de646a48147a72bdde3a026022aee381ce8c5170692c493c5a8b27dd2f",
    "760f90041d86ab1570f22ae99af0e4de7aabb3afbc706780573b444c94860454",
    "c5114295d2f58b9485b0fef30b952353c8bfc699a1d0af051d513e16978e8048",
    "c497c19e8696d3d065f44201465bdc7c75d5b41b651eb28ffa538e7a70becd2b",
    "32a5bc67dcbd22d3f8f4ecad7d4151b6a2f46aa566258308e5c8a81b16c896e7",
    "50ef313aebaba6d1e4fffed88dd702e2e6f4f39d38707149a1469d613fccf93c",
    "9953ab95a11d0eaab36928eca21cc85335631debaa6147632d566807689b303b",
    "183d27bd23b2ae78536243adbf6655a76275df96951a70c987f747bf4708865a",
    "52b1acd982a939e1045ae4594d6f138476fc494b520800bb41ed0da01c751f12",
    "bc59d13c6544c0b9c545c2f91dd2c7549405ba6eccc73aa74f975d695b009161",
    "765983cac3509bb2513adf77be5bda69477c33188c42c786134c10fa43646132",
    "fc399046c2d597a42d7e1befaa5a4ad13a8933865d5054235592ee7e46eb4ae3",
    "db87c3d7aa0b698f342e8734927f1173eac5be52283be564bc8eb3aa02524921",
    "638a24646ce1bc5d7fe55bc80fdc643d39b0310d8a274987ed03f479c2b97c4e",
    "32917b1532ccb9d7ceaa82faf9a7569edbf8a9230971f32e4ae9053246b05dfd",
    "cb6a0077e1e070975a7753361ed39fcee0e01277d2bc8e2890131d138c3c2af7",
    "18d53bd8e088971a459f21f9ed89130573f7cb0476e41507f72d8d88d33160bb",
    "a0a24b702dbd386dcee55dc4b27ea6dcde6bed44054c4fac045e2f7db79e5c19",
    "0996b44ec991c9034085820c221b0bb9f2817fe7a9c9f38d81b82fcaf0cd52e3",
    "422618945a13d162188d7b686a3a55aa8063599bb285f63fe3798a235661651c",
    "225e23ccdc2cd159382881a15ba37e4eae81f0319a44ee503f396226faf0d365",
    "23ea4de2b2e69f06c579f1b0f4b9c3f086ba9a3154340ea8de2c05964a2d5340",
    "4e8dc92655624931fc919b11075328a234c75ad332277b178ec0f257cd95e1d9",
    "f677950636f5e9119f53f6bca2263e2cdca260d43313e68ea4e2f6c339aee4aa",
    "3c064af8fb961b47da6c4aa9e122edd379b20555fc764a3ce0a381a28b50c79e",
    "4dbfdc93178b732d64f7b970b70443a6072ff76bc9bcc94b0fc76e4d95e21610",
    "7b64202ac8c74125832d7558c46571a6ea3c1aadab27112a425153563ed05c33",
    "25723b61dd393dacb6ea809597329abc8700629141813eea023e96ecceef0d65",
    "ad01b8038e9c43fa5c2802ce931f73c6f49273a6dd85d2dd599649900bd6e368",
    "634a77bf21e5c29cf7df77b7b9b9c45f2c1e7ed7b20f02682be4672488ff6fb7",
    "7cc10c99409b667bf3cbadecae23266f8cd111de7b229fb95b984cf7f1225efb",
);
$merkle_root = "b4206b0a077fe1502e7cd0192ce5160024326b43922af03e583fa49c6e0e44dd";
@transactions = map { Bitcoin::Transaction->new({ hash => scalar reverse pack("H*", $_) }) } @tx_hash;
$block = Bitcoin::Block->new({ transactions => \@transactions });
is(unpack("H*", scalar reverse $block->calculate_merkle_root), $merkle_root, scalar(@tx_hash) . " hashes");

done_testing();
