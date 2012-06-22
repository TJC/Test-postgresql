#!perl
use strict;
use warnings;
use Test::PostgreSQL;
use Test::More tests => 3;

my $pgsql = Test::PostgreSQL->new;

my $dbh = DBI->connect($pgsql->dsn);
ok($dbh, "Connected to created database.");

my $t1 = time();

$pgsql->stop;

my $elapsed = time() - $t1;
diag("elapsed: $elapsed");

ok(1, "Reached point after calling stop()");

ok($elapsed <= 12, "Shutdown took less than 12 seconds.");

1;
