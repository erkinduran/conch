-- `{{ id }}` becomes the auto-increment primary key of the configured driver
CREATE TABLE users (
	id {{ id }},
	name VARCHAR(100) NOT NULL,
	email VARCHAR(255) NOT NULL UNIQUE
);
