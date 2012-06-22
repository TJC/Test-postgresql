use strict;
use warnings;

use DBI;
use Test::PostgreSQL;

use Test::More tests => 3;

$ENV{PATH} = '/nonexistent';
@Test::PostgreSQL::SEARCH_PATHS = ();

ok(! defined $Test::PostgreSQL::errstr);
ok(! defined Test::PostgreSQL->new());
ok($Test::PostgreSQL::errstr);
