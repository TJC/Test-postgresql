use strict;
use warnings;

use DBI;
use Test::More;
use Test::PostgreSQL;

my $pgsql = Test::PostgreSQL->new()
    or plan skip_all => $Test::PostgreSQL::errstr;

my $dsn = $pgsql->dsn;

is(
    $dsn,
    "DBI:Pg:dbname=test;host=127.0.0.1;port=@{[$pgsql->port]};user=postgres",
    'check dsn',
);

my $dbh = DBI->connect($dsn);
ok($dbh->ping, 'connected to PostgreSQL');
undef $dbh;

my $uri = $pgsql->uri;
like($uri, qr/^postgresql:\/\/postgres\@127.0.0.1/);

undef $pgsql;
ok(
    ! DBI->connect($dsn),
    "Removing variable causes shutdown of postgresql"
);

done_testing;
