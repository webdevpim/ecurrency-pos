package QBitcoin::Const;
use warnings;
use strict;

use constant GENESIS_BLOCK_HASH => "1234";

use constant QBITCOIN_CONST => {
    VERSION               => "0.1",
    BLOCK_INTERVAL        => 10, # sec
    GENESIS_TIME          => 1621573000,
    INCORE_LEVELS         => 60,
    MIN_FEE               => 0.00000001, # 1 satoshi
    MAX_VALUE             => 21000000 * 100000000, # 21M
    COMPACT_MEMORY        => 1,
    MAX_COMMAND_LENGTH    => 256,
    READ_BUFFER_SIZE      => 65536,
    WRITE_BUFFER_SIZE     => 8*1024*1024,
    PORT_P2P              => 9555,
    PORT_API              => 9556,
    SERVICE_NAME          => "qbitcoin",
    SELECT_TIMEOUT        => 10, # sec
    BIND_ADDR             => '*',
    LISTEN_QUEUE          => 5,
    PEER_RECONNECT_TIME   => 10,
    GENESIS_HASH          => pack('H*', GENESIS_BLOCK_HASH),
    GENESIS_HASH_HEX      => GENESIS_BLOCK_HASH,
    MAX_BLOCK_SIZE        => 8*1024*1024,
    BLOCK_HEADER_SIZE     => 200, # TODO: calculate precise value
    MAX_TX_SIZE           => 2*1024*1024,
    MAX_PENDING_BLOCKS    => 128,
    MAX_EMPTY_TX_IN_BLOCK => 1,
};

use constant STATE_CONST => {
    STATE_CONNECTED    => 'connected',
    STATE_CONNECTING   => 'connecting',
    STATE_DISCONNECTED => 'disconnected',
};

use constant DIR_CONST => {
    DIR_IN  => 'in',
    DIR_OUT => 'out',
};

use constant QBITCOIN_CONST;
use constant STATE_CONST;
use constant DIR_CONST;

use Exporter qw(import);
our @EXPORT = ( keys %{&QBITCOIN_CONST}, keys %{&STATE_CONST}, keys %{&DIR_CONST} );

1;
