use strict;
use warnings;

use DBI;
use Test::More;
use Test::PostgreSQL;

Test::PostgreSQL->new()
    or plan skip_all => $Test::PostgreSQL::errstr;

plan tests => 3;

my @pgsql = map {
    my $pgsql = Test::PostgreSQL->new();
    ok($pgsql);
    $pgsql;
} 0..1;
is(scalar @pgsql, 2);
