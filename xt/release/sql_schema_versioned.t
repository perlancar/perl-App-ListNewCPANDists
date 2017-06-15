#!perl

use 5.010;
use strict;
use warnings;

use App::ListNewCPANDists;
use Test::More 0.98;
use Test::SQL::Schema::Versioned;
use Test::WithDB::SQLite;

sql_schema_spec_ok(
    $App::ListNewCPANDists::db_schema_spec,
    Test::WithDB::SQLite->new,
);
done_testing;
