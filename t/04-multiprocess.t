use strict;
use warnings;

use DBI;
use Test::More;
use Test::PostgreSQL;
use Test::SharedFork;

my $pgsql = Test::PostgreSQL->new()
    or plan skip_all => $Test::PostgreSQL::errstr;

plan tests => 3;

my $dbh;

ok($dbh = DBI->connect($pgsql->dsn), 'check if db is ready');
$dbh->disconnect;

unless (my $pid = Test::SharedFork::fork) {
    die "fork failed:$!"
        unless defined $pid;
    # child process
    ok($dbh = DBI->connect($pgsql->dsn), 'connect from child process');
    $dbh->disconnect;
    exit 0;
}

1 while wait == -1;

ok($dbh = DBI->connect($pgsql->dsn), 'connect after child exit');
$dbh->disconnect;

undef $pgsql;
