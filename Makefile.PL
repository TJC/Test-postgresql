use strict;
use inc::Module::Install;

name 'Test-PostgreSQL';
all_from 'lib/Test/PostgreSQL.pm';

requires 'Class::Accessor::Lite';
requires 'Time::HiRes';
test_requires 'DBI';
test_requires 'DBD::Pg';
test_requires 'Test::SharedFork' => 0.06;

repository 'https://github.com/TJC/Test-postgresql';

license 'artistic_2';

WriteAll;
