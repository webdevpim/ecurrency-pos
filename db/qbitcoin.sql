
CREATE TABLE `block` (
  height int unsigned NOT NULL PRIMARY KEY,
  hash binary(32) NOT NULL,
  weight bigint unsigned NOT NULL,
  prev_hash binary(32) DEFAULT NULL,
  merkle_root binary(32) NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS `hash` ON `block` (hash);

CREATE TABLE `transaction` (
  id int unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY,
  hash binary(32) NOT NULL,
  block_height int unsigned NOT NULL,
  size int unsigned NOT NULL,
  fee bigint signed NOT NULL,
  FOREIGN KEY (block_height) REFERENCES `block` (height) ON DELETE CASCADE
);
CREATE UNIQUE INDEX IF NOT EXISTS `hash` ON `transaction` (hash);
CREATE INDEX IF NOT EXISTS `block_height` ON `transaction` (block_height);

CREATE TABLE `tx_data` (
  id int unsigned NOT NULL PRIMARY KEY,
  data blob NOT NULL,
  FOREIGN KEY (id) REFERENCES `transaction` (id) ON DELETE CASCADE
);

-- Actually these are qbt addresses
CREATE TABLE IF NOT EXISTS `open_script` (
  id int unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY,
  data blob NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS `data` ON `open_script` (data);

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
CREATE UNIQUE INDEX IF NOT EXISTS `height` ON `btc_block` (height);
CREATE UNIQUE INDEX IF NOT EXISTS `hash`   ON `btc_block` (hash);
CREATE INDEX IF NOT EXISTS `scanned` ON `btc_block` (scanned);
