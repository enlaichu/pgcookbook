#!/bin/bash

# stat_statements.sh - query statistics monitoring script.
#
# The script connects to STAT_DBNAME, creates its own environment,
# pg_stat_statements and dblink extensions. When STAT_SNAPSHOT is not
# true it prints a top STAT_N queries statistics report for the period
# specified with STAT_SINCE and STAT_TILL. When STAT_ORDER is 0 - it
# prints the top most time consuming queries, 1 - the most often
# called, 2 - the most IO consuming ones. If STAT_SNAPSHOT is true
# then it creates a snapshot of current statements statistics, resets
# it to begin collecting another one and clean snapshots that are
# older than and period. If STAT_REPLICA_DSN is specified it performs
# the operation on this particular streaming replica. Do not put
# dbname in the STAT_REPLICA_DSN it will be substituted as
# STAT_DBNAME, automatically. Compatible with PostgreSQL >=9.2.
#
# Copyright (c) 2013-2015 Sergey Konoplev
#
# Sergey Konoplev <gray.ru@gmail.com>

source $(dirname $0)/config.sh
source $(dirname $0)/utils.sh

table_version=1
function_version=3

sql=$(cat <<EOF
DO \$do\$
DECLARE name text;
BEGIN
    IF
        NOT EXISTS (
            SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
    THEN
        CREATE EXTENSION pg_stat_statements;
    END IF;

    IF '$STAT_REPLICA_DSN' <> '' THEN
        IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'dblink') THEN
            CREATE EXTENSION dblink;
        END IF;
    END IF;

    IF
        (
            SELECT pg_catalog.obj_description(c.oid, 'pg_class')
            FROM pg_catalog.pg_class AS c
            JOIN pg_catalog.pg_namespace AS n ON n.oid = relnamespace
            WHERE nspname = 'public' AND relname = 'stat_statements'
        ) IS DISTINCT FROM '$table_version'
    THEN
        DROP TABLE IF EXISTS public.stat_statements;

        CREATE TABLE public.stat_statements AS
        SELECT
            NULL::text AS replica_dsn,
            NULL::timestamp with time zone AS created,
            *
        FROM pg_stat_statements LIMIT 0;

        COMMENT ON TABLE public.stat_statements IS '$table_version';

        CREATE INDEX stat_statements_replica_dns_created_idx
            ON public.stat_statements (replica_dsn, created);
        CREATE INDEX stat_statements_created_idx
            ON public.stat_statements (created);
    END IF;

    IF
        (
            SELECT pg_catalog.obj_description(p.oid, 'pg_proc')
            FROM pg_catalog.pg_proc AS p
            LEFT JOIN pg_catalog.pg_namespace AS n ON n.oid = pronamespace
            WHERE nspname = 'public' AND proname = 'stat_statements_get_report'
        ) IS DISTINCT FROM '$function_version'
    THEN
        FOR name IN
            SELECT p.oid::regprocedure
            FROM pg_catalog.pg_proc AS p
            LEFT JOIN pg_catalog.pg_namespace AS n ON n.oid = pronamespace
            WHERE nspname = 'public' AND proname = 'stat_statements_get_report'
        LOOP
            EXECUTE 'DROP FUNCTION ' || name;
        END LOOP;

        CREATE OR REPLACE FUNCTION public.stat_statements_get_report(
            i_replica_dsn text,
            i_since timestamp with time zone,
            i_till timestamp with time zone,
            i_n integer,
            i_order integer, -- 0 - time, 1 - calls, 2 - IO
            OUT o_position integer,
            OUT o_time numeric(18,3),
            OUT o_io_time numeric(18,3),
            OUT o_time_percent numeric(5,2),
            OUT o_io_time_percent numeric(5,2),
            OUT o_io_time_perc_rel numeric(5,2),
            OUT o_time_avg numeric(18,3),
            OUT o_io_time_avg numeric(18,3),
            OUT o_calls integer,
            OUT o_calls_percent numeric(5,2),
            OUT o_rows integer,
            OUT o_rows_avg numeric(18,3),
            OUT o_users text,
            OUT o_dbs text,
            OUT o_query text
        )
        RETURNS SETOF record LANGUAGE 'plpgsql' AS \$function\$
        BEGIN
            RETURN QUERY (
            WITH q1 AS (
                SELECT
                    sum(total_time) AS time,
                    sum(blk_read_time + blk_write_time) AS io_time,
                    sum(total_time) / sum(calls) AS time_avg,
                    sum(blk_read_time + blk_write_time) /
                        sum(calls) AS io_time_avg,
                    sum(rows) AS rows,
                    sum(rows) / sum(calls) AS rows_avg,
                    sum(calls) AS calls,
                    string_agg(usename, ' ') AS users,
                    string_agg(datname, ' ') AS dbs,
                    regexp_replace(
                        regexp_replace(query, '--(.*?$)', '-- [comment]', 'gm'),
                        E'\\\\/\\\\*(.*?)\\\\*\\\\/', '/* [comment] */', 'gs'
                    ) AS raw_query
                FROM public.stat_statements
                LEFT JOIN pg_catalog.pg_user ON userid = usesysid
                LEFT JOIN pg_catalog.pg_database ON dbid = pg_database.oid
                WHERE
                    replica_dsn = i_replica_dsn AND
                    created > i_since AND created <= i_till
                GROUP BY raw_query
                ORDER BY
                    CASE
                        WHEN i_order = 0 THEN sum(total_time)
                        WHEN i_order = 1 THEN sum(calls)
                        ELSE sum(blk_read_time + blk_write_time)
                    END DESC
            ), q2 AS (
                SELECT
                    time, io_time, time_avg, io_time_avg, rows, rows_avg, calls,
                    users, dbs,
                    CASE
                        WHEN sum(time) OVER () > 0 THEN
                            100 * time / sum(time) OVER ()
                        ELSE 0 END AS time_percent,
                    CASE
                        WHEN sum(time) OVER () > 0 THEN
                            100 * io_time / sum(time) OVER ()
                        ELSE 0 END AS io_time_percent,
                    CASE
                        WHEN sum(io_time) OVER () > 0 THEN
                            100 * io_time / sum(io_time) OVER ()
                        ELSE 0 END AS io_time_perc_rel,
                    100 * calls / sum(calls) OVER () AS calls_percent,
                    CASE
                        WHEN row_number() OVER () > i_n THEN 'other'
                        ELSE raw_query END AS query,
                    CASE
                        WHEN row_number() OVER () > i_n THEN i_n + 1
                        ELSE row_number() OVER () END AS row_number
                FROM q1
            )
            SELECT
                row_number::integer AS position,
                sum(time)::numeric(18,3) AS time,
                sum(io_time)::numeric(18,3) AS io_time,
                sum(time_percent)::numeric(5,2) AS time_percent,
                sum(io_time_percent)::numeric(5,2) AS io_time_percent,
                sum(io_time_perc_rel)::numeric(5,2) AS io_time_perc_rel,
                sum(time_avg)::numeric(18,3) AS time_avg,
                sum(io_time_avg)::numeric(18,3) AS io_time_avg,
                sum(calls)::integer AS calls,
                sum(calls_percent)::numeric(5,2) AS calls_percent,
                sum(rows)::integer AS rows,
                (
                    sum(rows)::numeric / sum(calls)
                )::numeric(18,3) AS rows_avg,
                nullif(array_to_string(
                    array(
                        SELECT DISTINCT unnest(
                            string_to_array(string_agg(users, ' '), ' '))
                    ), ', '
                )::text, '') AS users,
                nullif(array_to_string(
                    array(
                        SELECT DISTINCT unnest(
                            string_to_array(string_agg(dbs, ' '), ' '))
                    ), ', '
                )::text, '') AS dbs,
                nullif(query, '')::text
            FROM q2
            GROUP by query, row_number
            ORDER BY row_number);
        END \$function\$;

        FOR name IN
            SELECT p.oid::regprocedure
            FROM pg_catalog.pg_proc AS p
            LEFT JOIN pg_catalog.pg_namespace AS n ON n.oid = pronamespace
            WHERE nspname = 'public' AND proname = 'stat_statements_get_report'
        LOOP
            EXECUTE 'COMMENT ON FUNCTION ' || name ||
                    ' IS ''$function_version''';
        END LOOP;
    END IF;
END \$do\$;
EOF
)

error=$($PSQL -XAt -c "$sql" $STAT_DBNAME 2>&1) ||
    die "$(declare -pA a=(
        ['1/message']='Can not create environment'
        ['2m/detail']=$error))"

if $STAT_SNAPSHOT; then
    delete_sql=$(cat <<EOF
DELETE FROM public.stat_statements
WHERE created < now() - '$STAT_KEEP_SNAPSHOTS'::interval;
EOF
    )

    if [[ -z "$STAT_REPLICA_DSN" ]]; then
        sql=$(cat <<EOF
$delete_sql
INSERT INTO public.stat_statements
SELECT '', now(), * FROM pg_stat_statements;

SELECT pg_stat_statements_reset();
EOF
        )
    else
        sql=$(cat <<EOF
$delete_sql
INSERT INTO public.stat_statements
SELECT '$STAT_REPLICA_DSN', now(), * FROM dblink(
    '$STAT_REPLICA_DSN dbname=$STAT_DBNAME',
    'SELECT * FROM pg_stat_statements'
) AS s(
    userid oid,
    dbid oid,
    query text,
    calls bigint,
    total_time double precision,
    rows bigint,
    shared_blks_hit bigint,
    shared_blks_read bigint,
    shared_blks_dirtied bigint,
    shared_blks_written bigint,
    local_blks_hit bigint,
    local_blks_read bigint,
    local_blks_dirtied bigint,
    local_blks_written bigint,
    temp_blks_read bigint,
    temp_blks_written bigint,
    blk_read_time double precision,
    blk_write_time double precision
);

SELECT * FROM dblink(
    '$STAT_REPLICA_DSN dbname=$STAT_DBNAME',
    'SELECT pg_stat_statements_reset()'
) AS s(t text);
EOF
        )
    fi

    error=$($PSQL -XAt -c "$sql" $STAT_DBNAME 2>&1) ||
        die "$(declare -pA a=(
            ['1/message']='Can not make a snapshot'
            ['2m/detail']=$error))"

    info "$(declare -pA a=(
        ['1/message']='Snapshot has been made'))"
else
    [[ $STAT_ORDER -eq 0 ]] && order='time'
    [[ $STAT_ORDER -eq 1 ]] && order='calls'
    [[ $STAT_ORDER -eq 2 ]] && order='IO time'

    if [[ -z "$STAT_REPLICA_DSN" ]]; then
        message="Origin report ordered by $order"
    else
        message="Replica report for '$STAT_REPLICA_DSN' ordered by $order"
    fi

    sql=$(cat <<EOF
SELECT * FROM public.stat_statements_get_report(
    '$STAT_REPLICA_DSN', '$STAT_SINCE', '$STAT_TILL', $STAT_N, $STAT_ORDER)
EOF
    )

    src=$($PSQL -Xc "\copy ($sql) to stdout (NULL 'null')" $STAT_DBNAME 2>&1) ||
        die "$(declare -pA a=(
            ['1/message']='Can not get a report'
            ['2m/detail']=$src))"

    while IFS=$'\t' read -r -a l; do
        info "$(declare -pA a=(
            ['1/message']=$message
            ['2/position']=${l[0]}
            ['3/time']=${l[1]}
            ['4/io_time']=${l[2]}
            ['5/time_percent']=${l[3]}
            ['6/io_time_percent']=${l[4]}
            ['7/io_time_perc_rel']=${l[5]}
            ['8/time_avg']=${l[6]}
            ['9/io_time_avg']=${l[7]}
            ['10/calls']=${l[8]}
            ['11/calls_percent']=${l[9]}
            ['12/rows']=${l[10]}
            ['13/rows_avg']=${l[11]}
            ['14/users']=${l[12]}
            ['15/dbs']=${l[13]}
            ['16m/query']=${l[14]}))"
    done <<< "$src"
fi
