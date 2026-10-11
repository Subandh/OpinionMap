
DROP TABLE IF EXISTS `ai_log`;
CREATE TABLE `ai_log` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `user_id` int(10) unsigned NOT NULL,
  `job_id` int(10) unsigned DEFAULT NULL,
  `kind` enum('insights','ask') NOT NULL,
  `ok` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_user_time` (`user_id`,`created_at`)
) ENGINE=InnoDB AUTO_INCREMENT=2 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
DROP TABLE IF EXISTS `auth_log`;
CREATE TABLE `auth_log` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `user_id` int(10) unsigned DEFAULT NULL,
  `username` varchar(50) NOT NULL,
  `event` enum('register','login_ok','login_fail','login_blocked','logout') NOT NULL,
  `ip` varchar(45) NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_user` (`user_id`),
  KEY `idx_created` (`created_at`)
) ENGINE=InnoDB AUTO_INCREMENT=31 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
DROP TABLE IF EXISTS `comments`;
CREATE TABLE `comments` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `job_id` int(10) unsigned NOT NULL,
  `source` enum('reddit','x') NOT NULL,
  `external_id` varchar(64) NOT NULL,
  `kind` enum('post','comment','tweet','reply') NOT NULL,
  `community` varchar(100) DEFAULT NULL,
  `body` mediumtext NOT NULL,
  `score` int(11) DEFAULT NULL,
  `created_at_src` datetime DEFAULT NULL,
  `url` varchar(500) DEFAULT NULL,
  `stance` enum('supportive','opposed','neutral') DEFAULT NULL,
  `sentiment_score` float DEFAULT NULL,
  `cluster_id` int(11) DEFAULT NULL,
  `outlier_score` float DEFAULT NULL,
  `is_outlier` tinyint(1) NOT NULL DEFAULT 0,
  `on_topic` tinyint(1) DEFAULT NULL,
  `topic_reason` varchar(12) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_job_src_ext` (`job_id`,`source`,`external_id`),
  KEY `idx_job` (`job_id`),
  CONSTRAINT `comments_ibfk_1` FOREIGN KEY (`job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=2329 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
DROP TABLE IF EXISTS `jobs`;
CREATE TABLE `jobs` (
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `topic` varchar(255) NOT NULL,
  `status` enum('queued','collecting','analyzing','done','failed') NOT NULL DEFAULT 'queued',
  `result_json` mediumtext DEFAULT NULL,
  `error_message` text DEFAULT NULL,
  `created_at` datetime DEFAULT current_timestamp(),
  `finished_at` datetime DEFAULT NULL,
  `message` varchar(255) DEFAULT NULL,
  `raw_file` varchar(255) DEFAULT NULL,
  `item_count` int(10) unsigned NOT NULL DEFAULT 0,
  `user_id` int(10) unsigned DEFAULT NULL,
  `ai_json` mediumtext DEFAULT NULL,
  `ai_model` varchar(60) DEFAULT NULL,
  `ai_at` datetime DEFAULT NULL,
  `apify_runs` varchar(500) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_jobs_user` (`user_id`)
) ENGINE=InnoDB AUTO_INCREMENT=9 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
DROP TABLE IF EXISTS `settings`;
CREATE TABLE `settings` (
  `name` varchar(40) NOT NULL,
  `value` varchar(255) NOT NULL,
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `updated_by` int(10) unsigned DEFAULT NULL,
  PRIMARY KEY (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
DROP TABLE IF EXISTS `users`;
CREATE TABLE `users` (
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `username` varchar(30) NOT NULL,
  `password_hash` varchar(255) NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `last_login_at` datetime DEFAULT NULL,
  `failed_logins` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `locked_until` datetime DEFAULT NULL,
  `role` enum('user','admin') NOT NULL DEFAULT 'user',
  `email` varchar(254) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_username` (`username`),
  UNIQUE KEY `users_email_unique` (`email`)
) ENGINE=InnoDB AUTO_INCREMENT=5 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


