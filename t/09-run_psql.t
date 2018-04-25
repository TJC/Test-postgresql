use Test::More;

use strict;
use warnings;

use DBI;
use Test::PostgreSQL;
use Try::Tiny;

my $pg = try { Test::PostgreSQL->new() }
         catch { plan skip_all => $_ };

plan tests => 3;

ok defined($pg), "new instance created";

my @stmts = (
    q|CREATE TABLE foo (bar int)|,
    q|INSERT INTO foo (bar) VALUES (42)|,
);
eval {
    $pg->run_psql(
        '-c',
        q|'| . join( '; ', @stmts ) . q|'|,
    )
};

is $@, '', "run_psql no exception" . ($@ ? ": $@" : "");


my $dbh = DBI->connect($pg->dsn);
my @row = $dbh->selectrow_array('SELECT * FROM foo');

is_deeply \@row, [42], "seed values match";
