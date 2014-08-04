use strict;
use warnings;

# This test checks if we can operate on the old Test::postgresql namespace
# with the name shim..

use DBI;
use Test::More;
use Test::postgresql;

my $pgsql = Test::postgresql->new()
    or plan skip_all => "new() via old namespace failed with $Test::PostgreSQL::errstr";

my $dsn = $pgsql->dsn;

is(
    $dsn,
    "DBI:Pg:dbname=test;host=127.0.0.1;port=@{[$pgsql->port]};user=postgres",
    'check dsn',
);

my $dbh = DBI->connect($dsn);
ok($dbh->ping, 'connected to PostgreSQL via old namespace');
undef $dbh;

my $uri = $pgsql->uri;
like($uri, qr/^postgresql:\/\/postgres\@127.0.0.1/);

undef $pgsql;
ok(
    ! DBI->connect($dsn, undef, undef, { PrintError => 0 }),
    "Removing variable causes shutdown of postgresql via old namespace"
);

done_testing;
