-- One database + least-privilege user per site.
-- This file is a TEMPLATE. scripts/new-site.sh generates a real
-- maria/init/<domain>.sql from it using .env secrets.

CREATE DATABASE IF NOT EXISTS `<domain>`
    CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '<domain>'@'%' IDENTIFIED BY '<password>';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, REFERENCES
    ON `<domain>`.* TO '<domain>'@'%';

FLUSH PRIVILEGES;