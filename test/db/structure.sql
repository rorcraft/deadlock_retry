DROP TABLE IF EXISTS `deadlock_models`;

CREATE TABLE `deadlock_models` (
  `id` int(11) NOT NULL auto_increment,
  `name` varchar(50) NULL,
  PRIMARY KEY  (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
