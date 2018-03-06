-- Copyright (C) 2016-2018 Dmitry Marakasov <amdmi3@amdmi3.ru>
--
-- This file is part of repology
--
-- repology is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- repology is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with repology.  If not, see <http://www.gnu.org/licenses/>.

--------------------------------------------------------------------------------
--
-- !!create_schema()
--
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- functions
--------------------------------------------------------------------------------

-- Simplifies given url so https://www.foo.com and foo.com are the same
-- - Removes schema
-- - Removes www
-- - Removes parameters
-- XXX: should lowercase as well?
CREATE OR REPLACE FUNCTION simplify_url(url text) RETURNS text AS $$
BEGIN
	RETURN regexp_replace(regexp_replace(url, '/?([#?].*)?$', ''), '^https?://(www\.)?', '');
END;
$$ LANGUAGE plpgsql IMMUTABLE RETURNS NULL ON NULL INPUT;

--------------------------------------------------------------------------------
-- DROPs
--------------------------------------------------------------------------------
DROP TABLE IF EXISTS packages CASCADE;
DROP TABLE IF EXISTS repositories CASCADE;
DROP TABLE IF EXISTS repositories_history CASCADE;
DROP TABLE IF EXISTS statistics CASCADE;
DROP TABLE IF EXISTS statistics_history CASCADE;
DROP TABLE IF EXISTS links CASCADE;
DROP TABLE IF EXISTS problems CASCADE;
DROP TABLE IF EXISTS reports CASCADE;
DROP TABLE IF EXISTS metapackages CASCADE;
DROP TABLE IF EXISTS dead_metapackages CASCADE;

--------------------------------------------------------------------------------
-- Main packages table
--------------------------------------------------------------------------------
CREATE TABLE packages (
	repo text NOT NULL,
	family text NOT NULL,
	subrepo text,

	name text NOT NULL,
	effname text NOT NULL,

	version text NOT NULL,
	origversion text,
	versionclass smallint,

	maintainers text[],
	category text,
	comment text,
	homepage text,
	licenses text[],
	downloads text[],

	flags smallint NOT NULL,
	shadow bool NOT NULL,
	verfixed bool NOT NULL,

	flavors text[],

	extrafields jsonb NOT NULL
);

CREATE INDEX ON packages(effname);

--------------------------------------------------------------------------------
-- Metapackages
--------------------------------------------------------------------------------
CREATE TABLE metapackages (
	effname text NOT NULL PRIMARY KEY,
	num_repos smallint NOT NULL,
	num_families smallint NOT NULL,
	num_repos_newest smallint NOT NULL,
	num_families_newest smallint NOT NULL,
	shadow_only boolean NOT NULL,
	has_related boolean NOT NULL DEFAULT false,
	first_seen timestamp with time zone NOT NULL,
	last_seen timestamp with time zone NOT NULL
);

CREATE INDEX ON metapackages(num_repos);
CREATE INDEX ON metapackages(num_families);
CREATE INDEX ON metapackages(shadow_only, num_families);
CREATE INDEX ON metapackages(first_seen);
CREATE INDEX metapackages_effname_trgm ON metapackages USING gin (effname gin_trgm_ops);

CREATE TABLE dead_metapackages (
	effname text NOT NULL PRIMARY KEY,
	shadow_only boolean NOT NULL,
	first_seen timestamp with time zone NOT NULL,
	last_seen timestamp with time zone NOT NULL
);

CREATE INDEX ON dead_metapackages(last_seen);

--------------------------------------------------------------------------------
-- Metapackages by repo/category/maintainer
--------------------------------------------------------------------------------

-- per-repository
CREATE MATERIALIZED VIEW repo_metapackages AS
SELECT
	repo,
	effname,
	count(*)::smallint AS num_packages,
	count(*) FILTER (WHERE versionclass = 1)::smallint AS num_packages_newest,
	count(*) FILTER (WHERE versionclass = 2)::smallint AS num_packages_outdated,
	count(*) FILTER (WHERE versionclass = 3)::smallint AS num_packages_ignored,
	count(*) FILTER (WHERE versionclass = 4)::smallint AS num_packages_unique,
	count(*) FILTER (WHERE versionclass = 5)::smallint AS num_packages_devel,
	count(*) FILTER (WHERE versionclass = 6)::smallint AS num_packages_legacy,
	count(*) FILTER (WHERE versionclass = 7)::smallint AS num_packages_incorrect,
	count(*) FILTER (WHERE versionclass = 8)::smallint AS num_packages_untrusted,
	count(*) FILTER (WHERE versionclass = 9)::smallint AS num_packages_noscheme,
	count(*) FILTER (WHERE versionclass = 10)::smallint AS num_packages_rolling,
	max(num_families) = 1 AS unique
FROM packages INNER JOIN metapackages USING(effname)
WHERE NOT shadow_only
GROUP BY effname,repo
WITH DATA;

CREATE UNIQUE INDEX ON repo_metapackages(repo, effname);
CREATE INDEX ON repo_metapackages(effname);

-- per-category
CREATE MATERIALIZED VIEW category_metapackages AS
SELECT
	category,
	effname,
	max(num_families) = 1 AS unique
FROM packages INNER JOIN metapackages USING(effname)
WHERE NOT shadow_only
GROUP BY effname,category
WITH DATA;

CREATE UNIQUE INDEX ON category_metapackages(category, effname);
CREATE INDEX ON category_metapackages(effname);

-- per-maintainer
CREATE MATERIALIZED VIEW maintainer_metapackages AS
SELECT
	unnest(maintainers) as maintainer,
	effname,
	count(1)::smallint AS num_packages,
	count(*) FILTER (WHERE versionclass = 1)::smallint AS num_packages_newest,
	count(*) FILTER (WHERE versionclass = 2)::smallint AS num_packages_outdated,
	count(*) FILTER (WHERE versionclass = 3)::smallint AS num_packages_ignored,
	count(*) FILTER (WHERE versionclass = 4)::smallint AS num_packages_unique,
	count(*) FILTER (WHERE versionclass = 5)::smallint AS num_packages_devel,
	count(*) FILTER (WHERE versionclass = 6)::smallint AS num_packages_legacy,
	count(*) FILTER (WHERE versionclass = 7)::smallint AS num_packages_incorrect,
	count(*) FILTER (WHERE versionclass = 8)::smallint AS num_packages_untrusted,
	count(*) FILTER (WHERE versionclass = 9)::smallint AS num_packages_noscheme,
	count(*) FILTER (WHERE versionclass = 10)::smallint AS num_packages_rolling
FROM packages
GROUP BY maintainer, effname
WITH DATA;

CREATE UNIQUE INDEX ON maintainer_metapackages(maintainer, effname);
CREATE INDEX ON maintainer_metapackages(effname);

--------------------------------------------------------------------------------
-- Maintainers
--------------------------------------------------------------------------------

-- XXX: kill this in favor of table
CREATE MATERIALIZED VIEW maintainers AS
SELECT *
FROM (
	SELECT
		unnest(maintainers) AS maintainer,
		count(1)::integer AS num_packages,
		count(DISTINCT effname)::integer AS num_metapackages,
		count(DISTINCT effname) FILTER(WHERE versionclass = 2)::integer AS num_metapackages_outdated,
		count(*) FILTER (WHERE versionclass = 1)::integer AS num_packages_newest,
		count(*) FILTER (WHERE versionclass = 2)::integer AS num_packages_outdated,
		count(*) FILTER (WHERE versionclass = 3)::integer AS num_packages_ignored,
		count(*) FILTER (WHERE versionclass = 4)::integer AS num_packages_unique,
		count(*) FILTER (WHERE versionclass = 5)::integer AS num_packages_devel,
		count(*) FILTER (WHERE versionclass = 6)::integer AS num_packages_legacy,
		count(*) FILTER (WHERE versionclass = 7)::integer AS num_packages_incorrect,
		count(*) FILTER (WHERE versionclass = 8)::integer AS num_packages_untrusted,
		count(*) FILTER (WHERE versionclass = 9)::integer AS num_packages_noscheme,
		count(*) FILTER (WHERE versionclass = 10)::integer AS num_packages_rolling
	FROM packages
	GROUP BY maintainer
) AS packages_subreq
LEFT JOIN (
	SELECT
		maintainer,
		json_object_agg(repo, numrepopkg) AS repository_package_counts,
		json_object_agg(repo, numrepometapkg) AS repository_metapackage_counts
	FROM (
		SELECT
			unnest(maintainers) AS maintainer,
			repo,
			count(*) AS numrepopkg,
			count(DISTINCT effname) AS numrepometapkg
		FROM packages
		GROUP BY maintainer, repo
	) AS repositories_subreq_inner
	GROUP BY maintainer
) AS repositories_subreq
USING(maintainer)
LEFT JOIN (
	SELECT
		maintainer,
		json_object_agg(category, numcatmetapkg) AS category_metapackage_counts
	FROM (
		SELECT
			unnest(maintainers) AS maintainer,
			category,
			count(DISTINCT effname) AS numcatmetapkg
		FROM packages
		WHERE category IS NOT NULL
		GROUP BY maintainer, category
	) AS categories_subreq_innser
	GROUP BY maintainer
) AS categories_subreq
USING(maintainer)
WITH DATA;

CREATE UNIQUE INDEX ON maintainers(maintainer);

--------------------------------------------------------------------------------
-- Per-repository and global statistics and their history
--------------------------------------------------------------------------------
CREATE TABLE repositories (
	name text NOT NULL PRIMARY KEY,

	num_packages integer NOT NULL DEFAULT 0,
	num_packages_newest integer NOT NULL DEFAULT 0,
	num_packages_outdated integer NOT NULL DEFAULT 0,
	num_packages_ignored integer NOT NULL DEFAULT 0,
	num_packages_unique integer NOT NULL DEFAULT 0,
	num_packages_devel integer NOT NULL DEFAULT 0,
	num_packages_legacy integer NOT NULL DEFAULT 0,
	num_packages_incorrect integer NOT NULL DEFAULT 0,
	num_packages_untrusted integer NOT NULL DEFAULT 0,
	num_packages_noscheme integer NOT NULL DEFAULT 0,
	num_packages_rolling integer NOT NULL DEFAULT 0,

	num_metapackages integer NOT NULL DEFAULT 0,
	num_metapackages_unique integer NOT NULL DEFAULT 0,
	num_metapackages_newest integer NOT NULL DEFAULT 0,
	num_metapackages_outdated integer NOT NULL DEFAULT 0,
	num_metapackages_comparable integer NOT NULL DEFAULT 0,

	last_update timestamp with time zone,

	num_problems integer NOT NULL DEFAULT 0,
	num_maintainers integer NOT NULL DEFAULT 0
);

-- repository_history
CREATE TABLE repositories_history (
	ts timestamp with time zone NOT NULL PRIMARY KEY,
	snapshot jsonb NOT NULL
);

-- statistics
CREATE TABLE statistics (
	num_packages integer NOT NULL DEFAULT 0,
	num_metapackages integer NOT NULL DEFAULT 0,
	num_problems integer NOT NULL DEFAULT 0,
	num_maintainers integer NOT NULL DEFAULT 0
);

INSERT INTO statistics VALUES(DEFAULT);

-- statistics_history
CREATE TABLE statistics_history (
	ts timestamp with time zone NOT NULL PRIMARY KEY,
	snapshot jsonb NOT NULL
);

--------------------------------------------------------------------------------
-- Links
--------------------------------------------------------------------------------
CREATE TABLE links (
	url text NOT NULL PRIMARY KEY,
	first_extracted timestamp with time zone NOT NULL,
	last_extracted timestamp with time zone NOT NULL,
	last_checked timestamp with time zone,
	last_success timestamp with time zone,
	last_failure timestamp with time zone,
	status smallint,
	redirect smallint,
	size bigint,
	location text
);

--------------------------------------------------------------------------------
-- Problems
--------------------------------------------------------------------------------
CREATE TABLE problems (
	repo text NOT NULL,
	name text NOT NULL,
	effname text NOT NULL,
	maintainer text,
	problem text NOT NULL
);

CREATE INDEX ON problems(effname);
CREATE INDEX ON problems(repo, effname);
CREATE INDEX ON problems(maintainer);

--------------------------------------------------------------------------------
-- Reports
--------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reports (
	id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
	created timestamp with time zone NOT NULL,
	effname text NOT NULL,
	need_verignore boolean NOT NULL,
	need_split boolean NOT NULL,
	need_merge boolean NOT NULL,
	comment text,
	reply text,
	accepted boolean
);

CREATE INDEX ON reports(effname);

--------------------------------------------------------------------------------
-- Url relations
--------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW url_relations AS
SELECT DISTINCT
	effname,
	simplify_url(homepage) AS url
FROM packages
WHERE homepage ~ '^https?://'
WITH DATA;

CREATE UNIQUE INDEX ON url_relations(effname, url);  -- we only need url here because we need unique index for concurrent refresh
CREATE INDEX ON url_relations(url);
