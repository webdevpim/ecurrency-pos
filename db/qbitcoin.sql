
CREATE TABLE `block` (
  height int unsigned NOT NULL PRIMARY KEY,
  hash binary(32) NOT NULL,
  weight bigint unsigned NOT NULL,
  prev_hash binary(32) DEFAULT NULL,
  merkle_root binary(32) NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS `block_hash` ON `block` (hash);

CREATE TABLE `transaction` (
  id integer NOT NULL AUTO_INCREMENT PRIMARY KEY, -- "integer" (signed) required for sqlite autoincrement
  hash binary(32) NOT NULL,
  block_height int unsigned NOT NULL,
  size int unsigned NOT NULL,
  fee bigint signed NOT NULL,
  FOREIGN KEY (block_height) REFERENCES `block` (height) ON DELETE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS `tx_hash` ON `transaction` (hash);
CREATE INDEX IF NOT EXISTS `tx_block_height` ON `transaction` (block_height);

CREATE TABLE `tx_data` (
  id int unsigned NOT NULL PRIMARY KEY,
  data blob NOT NULL,
  FOREIGN KEY (id) REFERENCES `transaction` (id) ON DELETE CASCADE
);

-- Actually these are qbt addresses
CREATE TABLE IF NOT EXISTS `open_script` (
  id integer NOT NULL AUTO_INCREMENT PRIMARY KEY,
  data blob NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS `open_script_data` ON `open_script` (data);

CREATE TABLE IF NOT EXISTS `txo` (
  value     bigint unsigned NOT NULL,
  num          int unsigned NOT NULL,
  tx_in        int unsigned NOT NULL,
  tx_out       int unsigned DEFAULT NULL,
  open_script  int unsigned NOT NULL,
  close_script blob DEFAULT NULL,
  PRIMARY KEY (tx_in, num),
  FOREIGN KEY (tx_in)       REFERENCES `transaction` (id) ON DELETE CASCADE,
  FOREIGN KEY (tx_out)      REFERENCES `transaction` (id) ON DELETE SET NULL,
  FOREIGN KEY (open_script) REFERENCES `open_script` (id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS `tx_out` ON `txo` (tx_out);

CREATE TABLE IF NOT EXISTS `my_address` (
  address     varchar(255) NOT NULL PRIMARY KEY,
  private_key varchar(255) NOT NULL, -- encrypted
  pubkey_crc  varchar(255) NOT NULL
);

CREATE TABLE `btc_block` (
  height int unsigned DEFAULT NULL,
  time int unsigned NOT NULL,
  bits int unsigned NOT NULL,
  nonce int unsigned NOT NULL,
  version int unsigned NOT NULL,
  chainwork double unsigned NOT NULL,
  scanned int unsigned NOT NULL,
  hash binary(32) NOT NULL,
  prev_hash binary(32) DEFAULT NULL,
  merkle_root binary(32) NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS `btc_height` ON `btc_block` (height);
CREATE UNIQUE INDEX IF NOT EXISTS `btc_hash`   ON `btc_block` (hash);
CREATE INDEX IF NOT EXISTS `scanned` ON `btc_block` (scanned);

CREATE TABLE `coinbase` (
  btc_block_height int unsigned DEFAULT NULL,
  btc_tx_num smallint unsigned DEFAULT NULL,
  btc_out_num smallint unsigned NOT NULL,
  btc_tx_hash binary(32) NOT NULL,
  merkle_path binary(512) NOT NULL, -- 16-level btree with 32-byte (256-bit) hashes
  btc_tx_data longblob NOT NULL, -- or 'blob' for sqlite
  value bigint unsigned NOT NULL,
  open_script int unsigned NOT NULL,
  tx_out int unsigned DEFAULT NULL,
  PRIMARY KEY (btc_tx_hash, btc_out_num),
  FOREIGN KEY (btc_block_height) REFERENCES `btc_block`   (height) ON DELETE RESTRICT, -- should never happens
  FOREIGN KEY (tx_out)           REFERENCES `transaction` (id)     ON DELETE SET NULL,
  FOREIGN KEY (open_script)      REFERENCES `open_script` (id)     ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS `coinbase_tx_out` ON `coinbase` (tx_out);
